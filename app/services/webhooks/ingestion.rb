module Webhooks
  # The boundary between a verified processor payload and this service's own
  # events. One object, one job: store what arrived, act on it exactly once, and
  # record how it went.
  #
  # Three properties, each of which is a test in test/services/webhooks:
  #
  #   * **At most once per processor event id.** A replay is a lookup, not a
  #     second emission. Delivery is at-least-once, so replays are ordinary
  #     operation, and the second `billing.payment.succeeded` is not a harmless
  #     duplicate — it is a second envelope id, which a consumer deduplicating on
  #     that id cannot tell from new information about money.
  #
  #   * **The event and the receipt of it are one commit.** The outbox row and
  #     the `processed_at` that says this delivery is finished are written in the
  #     same transaction, so there is no window in which one exists without the
  #     other. A process that died between two transactions would leave a row
  #     that looks unfinished, and the next delivery would emit a second event
  #     for a charge that already settled.
  #
  #   * **Never raise for a payload we have stored.** An unknown type, a
  #     deliberately ignored type, and an event whose mapping raised are all
  #     terminal states recorded on the row. A processor that retries a 5xx
  #     retries the identical payload and reaches the identical outcome, so the
  #     retry buys nothing and hides a parked row behind a timeout. The failure is
  #     raised at the edge, with the identifier needed to find the row.
  #
  #   * **Refuse a bad input before it becomes a row.** An unknown processor, a
  #     missing event id and a missing type are programming errors, not processor
  #     behaviour, and nobody can retry them into success.
  #
  # ## At most once, under concurrency
  #
  # `call` is a check followed by an act, and the first version of that sequence
  # was correct only when deliveries did not overlap:
  #
  # ```ruby
  # webhook = ProcessorWebhook.ingest(...)
  # return webhook if webhook.handled?   # the read
  # dispatch(webhook)                    # ... and the write
  # ```
  #
  # The unique index on `processor_webhooks.stripe_event_id` makes two concurrent
  # deliveries of one event id agree about *which row* they hold — and agreeing
  # about the row is not agreeing about the answer. `handled?` reads a column that
  # neither thread has written yet, because each is about to write it. Under READ
  # COMMITTED neither sees the other's uncommitted work, so both read `nil`, both
  # dispatch, and one Stripe event produces two outbox rows with two envelope
  # ids. That is a duplicate charge event, and it is the defect
  # `test/services/webhooks/concurrent_delivery_test.rb` reproduces.
  #
  # The fix is not a smarter check but a constraint that makes the duplicate
  # state *impossible*: a unique index on the outbox's processor event id
  # (`IndexOutboxEventsOnProcessorEventId`). It holds under any interleaving,
  # which is the property an application-level guard cannot have — a guard is only
  # ever right about the interleavings its author imagined.
  #
  # The loser of that race is not an error. It is a delivery that arrived, was
  # understood, and was deliberately not acted on because a concurrent request
  # for the same event id already published the event — so it is recorded as
  # `ignored:duplicate_delivery` and answered 200, alongside the other decisions
  # this layer already records. Parking it as `failed:` would put a row in front of
  # a human at 3am for an event that is published and correct.
  class Ingestion
    DUPLICATE_REASON = "duplicate_delivery".freeze

    def initialize(processor:, event_id:, type:, payload:)
      @processor = processor
      @event_id = event_id
      @type = type
      @payload = payload
    end

    # Returns the stored record whatever became of the event, so a caller can log
    # the outcome without querying for it. It never raises for a payload that is
    # now on disk.
    def call
      webhook = ProcessorWebhook.ingest(processor: processor, event_id: @event_id, type: @type, payload: payload)
      return webhook if webhook.handled?

      dispatch(webhook)
      webhook
    end

    private
      attr_reader :payload, :processor

      def dispatch(webhook)
        handler = Webhooks::StripeEvents.handler_for(webhook.type)
        return webhook.ignore!(Webhooks::StripeEvents.ignored_reason(webhook.type)) if handler.nil?

        emit(webhook, handler)
      end

      def emit(webhook, handler)
        ProcessorWebhook.transaction do
          emission = handler.call(payload, event_time)
          OutboxEvent.publish!(
            type: emission.event_type,
            subject: emission.subject,
            data: emission.data,
            time: event_time
          )
          webhook.handled!
        end
      rescue Ignored => e
        webhook.ignore!(e.reason)
      rescue ActiveRecord::RecordNotUnique => e
        duplicate_delivery? ? webhook.ignore!(DUPLICATE_REASON) : park(webhook, e)
      rescue ActiveRecord::RecordInvalid => e
        uniqueness_race?(e) ? webhook.ignore!(DUPLICATE_REASON) : park(webhook, e)
      rescue StandardError => e
        park(webhook, e)
      end

      # Whether the unique violation that just rolled back was the same fact
      # arriving twice, read back from committed state rather than inferred from
      # the constraint's name.
      #
      # The two measured duplicate routes are the only ones that answer yes:
      #
      #   * the outbox already holds a row for this event id — the payment and
      #     subscription-updated events carry `processor_event_id`, so this is the
      #     row their racing delivery lost to;
      #   * the subscriptions table already holds the subscription this event
      #     names — `customer.subscription.created`'s outbox payload
      #     deliberately carries no `processor_event_id`, so its race is lost at
      #     the subscription's own `INSERT` instead.
      #
      # A unique violation that is neither — today, the live-uniqueness index
      # refusing a different subscription for an account that already has one on
      # the plan — is a second real fact this service declined to store, and it
      # parks.
      def duplicate_delivery?
        return true if OutboxEvent.where("data ->> 'processor_event_id' = ?", @event_id).exists?
        return false unless @type.to_s.start_with?("customer.subscription.")

        subscription_id = payload.dig("data", "object", "id")
        subscription_id.present? && Subscription.exists?(processor_subscription_id: subscription_id)
      end

      # Whether a validation failure is the duplicate the constraint above
      # already records, rather than something this service got wrong.
      #
      # `:taken` is the error type Rails' uniqueness validation raises, so this
      # asks the record what went wrong instead of inferring it from the class of
      # the exception — which is the only reason this is narrow.
      def uniqueness_race?(error)
        record = error.record
        record.is_a?(ActiveRecord::Base) && record.errors.any? { |problem| problem.type == :taken }
      end

      # The one path that puts a row in front of a human, so it is the one place
      # that logs, and it logs the identifier needed to find the row and nothing
      # about the payload: the body can carry a customer email, and a signing
      # failure's message is not this service's to print.
      def park(webhook, exception)
        Rails.logger.error(
          "processor webhook #{processor} #{webhook.stripe_event_id} failed: #{exception.class}: #{exception.message}"
        )
        webhook.fail!(exception)
      end

      # The state change's own time, not the arrival time. A row that sat
      # unpublished for an hour must still report when the change happened, and an
      # out-of-order delivery is only detectable by a consumer if this is not
      # `Time.current`.
      #
      # Computed once here and handed to the handler as well, because a handler that
      # publishes an event about a subscription has to put the same instant in the
      # event's `time` and in the payload's `started_at` — core's schema requires the
      # two to be equal — and two readings of the same field is how they drift.
      def event_time
        created = payload["created"]
        created.present? ? Time.at(created).utc : Time.current
      end
  end
end
