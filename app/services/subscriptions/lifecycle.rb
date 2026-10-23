module Subscriptions
  # Raised when a verified processor event cannot be applied. It carries a
  # machine-readable `reason` and nothing else: the delivery row records the
  # reason, and the reason is the whole message a human gets.
  #
  # Deliberately *not* `Webhooks::Ignored`. The transport decides what to do with a
  # refusal — on the webhook path it is recorded and answered 200 — and this class
  # says only that the event could not be applied. Keeping them apart means the
  # domain does not know it is being called from a webhook, and a caller that
  # wanted a different answer could give one.
  class Refused < Error
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("refused: #{reason}")
    end
  end

  # Applies one verified processor event to the subscriptions table, and returns
  # the event that change produced.
  #
  # This is the **only** writer of a subscription's state and the only thing that
  # emits a subscription's events. There is no `after_update` on `Subscription` and
  # no branch of the API that changes a status: `POST /v1/subscriptions/:id/cancel`
  # asks the processor to cancel and waits for the webhook that follows, and the
  # row moves when the event arrives. One writer means there is one answer to "what
  # is this subscription's status", and it comes from the party that can bill.
  #
  # The event type is **derived from what happened to the row**, not taken from the
  # processor's event type. A deletion that arrives before its creation creates a
  # `canceled` row and is therefore a cancellation; an update that arrives first
  # would create an active row and be therefore a start. A mapping keyed on the
  # processor's type would publish `billing.subscription.updated` for a
  # subscription nobody has ever seen start.
  #
  # ## A deletion that arrives before its creation
  #
  # The one genuinely interesting case, and the reason the state machine is a table
  # rather than a `case`. A `customer.subscription.deleted` for a subscription this
  # service has never seen creates a `canceled` row rather than being dropped. It
  # is the only statement about that subscription that has arrived, and dropping it
  # would leave an active row — and active rows grant entitlements — for something
  # the processor says is gone. The `created` that follows is then refused by the
  # machine's terminal rule, so the subscription is never started and never grants
  # anything. A subscriber that was created and canceled inside one delivery window
  # ends up recorded as canceled, which is the truth.
  #
  # ## A delivery that predates the row is refused
  #
  # The terminal rule is about a *pair* of statuses, and it covers the one case
  # where this service knows the order for certain. Everything else is a
  # *sequence*: the processor does not promise delivery order, so a delivery can
  # arrive after a later one, and legality on its own would happily apply it. A
  # `past_due` subscription whose charge failed becomes `active` again, which
  # grants entitlements nobody is paying for — and a stale `cancel_at_period_end:
  # false` tells every downstream consumer a cancellation was called off.
  #
  # So the row remembers the processor's own timestamp for the delivery that last
  # wrote it, and a delivery strictly older than that is refused. `Refused` is the
  # right shape here: it is a decision this service made, the delivery row records
  # the reason, and the endpoint answers 200, because a processor that retries a
  # stale delivery reaches the identical conclusion.
  class Lifecycle
    # The reason a delivery is refused for arriving out of order. One word, like
    # the rest of them, because it is recorded on `processor_webhooks.error` where
    # the next reader is a human with a subscription id and nothing else.
    STALE_REASON = "stale_delivery".freeze

    # The reason a delivery is refused for naming an account the row is not on.
    #
    # This is the seventh refusal and the only one about **tenancy** rather than
    # about the row's own shape. The other six ask "can this delivery be applied
    # to this subscription?"; this one asks "whose subscription is it?" — and the
    # answer is not allowed to change.
    #
    # ## What it is refusing
    #
    # `attributes` writes `account_id: customer.owner_id` onto the row, and before
    # this rule it did so **without ever comparing it to the account already
    # there**. So a second delivery naming a different customer moved a live
    # subscription between accounts, and published the move as
    # `billing.subscription.updated` carrying the new account. `Subscription#account_is_the_customers_owner`
    # did not catch it, and could not: that rule is "a subscription's account is
    # its customer's", which the new account satisfied, and not "a subscription's
    # account does not move". This is finding F1 in
    # `REPORT-billing-12-isolation`.
    #
    # ## Why the refusal and not a correction
    #
    # Moving the subscription back would be this service inventing a fact, and the
    # status came with the delivery — a `canceled` this service never saw would
    # revoke entitlements a customer had paid for. A refusal records the decision
    # on the delivery row and answers 200, because a processor that retries it
    # reaches the identical conclusion. That is the same argument as
    # `stale_delivery`, and for the same reason.
    #
    # ## Where it sits in the order, and why
    #
    # After the state machine, after `no_subscription_to_update` and after
    # `stale_delivery`, because those are the rules a subscriber is relying on and
    # none of them should be reported as something incidental. A delivery that is
    # both out of order *and* cross-account is recorded as the out-of-order one, and
    # the honest reading of that row is the earlier problem.
    ACCOUNT_REASON = "account_mismatch".freeze

    # The three processor types this lifecycle acts on, and the anywaye event each
    # of them can become. The same three the outbox and the manifest declare, so a
    # type cannot be emitted that core's catalog does not list.
    CREATED = "customer.subscription.created".freeze
    UPDATED = "customer.subscription.updated".freeze
    DELETED = "customer.subscription.deleted".freeze

    TYPES = [ CREATED, UPDATED, DELETED ].freeze

    STARTED_EVENT = "billing.subscription.started".freeze
    UPDATED_EVENT = "billing.subscription.updated".freeze
    CANCELED_EVENT = "billing.subscription.canceled".freeze

    # The fields on the row a processor event can set. `last_processor_event_at` is
    # not one of them: it is this service's ordering bookkeeping and it changes on
    # every delivery, so counting it would report a change where none happened.
    STATE_ATTRIBUTES = %w[
      account_id customer_id plan_id status current_period_start current_period_end
      cancel_at_period_end canceled_at
    ].freeze

    # What the lifecycle produced: the row it wrote, the type to publish, the
    # payload, and the time the change happened. A value object so a handler cannot
    # emit half an event.
    Applied = Data.define(:subscription, :event_type, :data, :event_time) do
      # core's envelope `subject`: the entity the event is about. This service's own
      # subscription id, which is what lets a consumer join `started`, `updated` and
      # `canceled` without a lookup table — and which core's started schema says must
      # equal the payload's `subscription_id`.
      def subject
        subscription.id
      end
    end

    def initialize(data:, event_time:)
      @data = data
      @event_time = event_time
    end

    # => Applied. Raises `Refused` with a reason, which the webhook path records on
    # the delivery row and answers 200.
    def call(type)
      raise Refused, "unknown_subscription_event_type" unless TYPES.include?(type)

      subscription = Subscription.find_by(processor_subscription_id: processor_subscription_id)
      transition = StateMachine.new(subscription&.status, data.fetch("status"))

      # The machine first, and the reason it gives, because "nothing revives a
      # canceled subscription" is the rule a subscriber is relying on and it must
      # not be reported as something incidental.
      raise Refused, transition.reason unless transition.legal?

      # An update is not a creation. We do not know when this subscription started,
      # so publishing a start off an update would be a guess about a fact a consumer
      # would then rely on. The `created` that precedes it chronologically still
      # arrives.
      raise Refused, "no_subscription_to_update" if subscription.nil? && type == UPDATED

      # Then the one rule about arrival order rather than about status. Every pair
      # the machine allows is a pair the processor may deliver in either order, and
      # applying the older one last would move the row backwards.
      raise Refused, STALE_REASON if stale?(subscription)

      from = subscription&.status
      apply(subscription, from, transition)
    end

    private
      attr_reader :data, :event_time

      # Whether this delivery predates the one that last wrote the row.
      #
      # **Strictly older**, not "not newer". The processor's timestamps are epoch
      # seconds, so two genuinely different events routinely share one, and
      # refusing those would drop real deliveries. With no ordering information
      # between them the honest answer is last-write-wins, and `no_change_to_record`
      # already absorbs the repeats that would otherwise double-apply.
      #
      # A row with no `last_processor_event_at` is a row no delivery has written
      # yet, so it has nothing to be stale against. That is the case the deletion
      # arriving before its own creation depends on.
      def stale?(subscription)
        return false if subscription.nil? || subscription.last_processor_event_at.nil?

        event_time < subscription.last_processor_event_at
      end

      def processor_subscription_id
        data["subscription_id"]
      end

      def customer
        # The reference this service put in the subscription's metadata at Checkout
        # time, and the processor's own id for the customer. Both are consulted
        # because a customer created through /v1 has a null `processor_customer_id`
        # until its first subscription tells us what the processor calls it.
        resolve(
          data["anywaye_customer_id"] && Customer.find_by(id: data["anywaye_customer_id"]),
          Customer.find_by(processor_customer_id: data["customer_id"]),
          "unknown_customer"
        )
      end

      def plan
        resolve(Plan.find_by(processor_price_id: data["price_id"]), nil, "unknown_plan")
      end

      # A missing reference is a refusal, not a correction. A subscription this
      # service cannot attach to a customer and a plan of its own is not one it
      # bills, and inventing either would put a price on an account that never
      # asked for it.
      def resolve(found, fallback, reason)
        return found if found
        return fallback if fallback

        raise Refused, reason
      end

      def apply(subscription, from, transition)
        existed = !subscription.nil?

        # **Before `assign_attributes`**, because that is the statement which
        # overwrites the account, and a comparison made afterwards would compare
        # the new account with itself and always agree.
        #
        # Only for a row that already exists. A creation has no account to
        # disagree with, which is exactly what lets a `deleted` arriving before
        # its own `created` still create its `canceled` row — a rule that would
        # break here if the check were unconditional.
        raise Refused, ACCOUNT_REASON if existed && !same_account?(subscription)

        subscription ||= Subscription.new

        subscription.assign_attributes(attributes)
        raise Refused, "no_change_to_record" if existed && !changes_anything?(subscription)

        # The processor's own id for the customer, recorded the first time a
        # subscription event names one. A customer created through `/v1` has
        # none — the Checkout session creates the customer at the processor and
        # this is the first delivery that learns what the processor calls it —
        # and `POST …/upcoming_invoice` and `…/payment_method` both send it, so
        # without this write the two actions a customer uses most are refused
        # with a processor error for a customer the processor does know.
        backfill_processor_customer_id

        # The processor's own clock, not this service's. It is the only thing that
        # can tell a delivery that arrived late from one that arrived now, and it is
        # written in the same statement as the state so the two cannot disagree about
        # which event the row reflects.
        subscription.last_processor_event_at = event_time
        subscription.save!

        type = event_type(existed: existed, from: from)
        Applied.new(subscription, type, payload(subscription, type), event_time)
      end

      def changes_anything?(subscription)
        STATE_ATTRIBUTES.any? { |attribute| subscription.will_save_change_to_attribute?(attribute) }
      end

      # Records the processor's id for the customer, once, and never overwrites
      # one already there. The id is the event's own `customer`, and the customer
      # is the row `resolution` already resolved (by the anywaye reference in the
      # subscription's metadata, or by the processor id it already held).
      #
      # **Never overwrites, and the direction matters.** The column is one
      # customer's id at one processor, and a delivery that arrived later is not
      # a correction: the fake door's delivery carries the fake processor's
      # derived id, and letting it rewrite a real one was a measured defect
      # (2026-10-16) — the walk's receipt stopped resolving after its own
      # checkout. A customer another row already claims is left alone for the
      # same reason: `processor_customer_id` is unique, and a second anywaye
      # customer answering to one processor customer is a disagreement for a
      # human, not something a webhook settles.
      def backfill_processor_customer_id
        processor_id = data["customer_id"].to_s
        return if processor_id.blank?
        return if customer.processor_customer_id.present?
        return if Customer.where(processor_customer_id: processor_id).where.not(id: customer.id).exists?

        customer.update!(processor_customer_id: processor_id)
      end

      # Whether the delivery resolves to the account the row is already on.
      #
      # **The comparison the model could not make.**
      # `Subscription#account_is_the_customers_owner` answers "is this account
      # this customer's?", and after a reassignment the answer is yes — which is
      # why the defect survived it. The question here is the other one: has the
      # account *moved*? A row that already names an account, and a delivery that
      # resolves to another, are two accounts, and no amount of internal
      # consistency makes that one subscription.
      #
      # **There is no nil branch, and there is not one to write.** Both sides are
      # `null: false` — `subscriptions.account_id` and `customers.owner_id` — so
      # "both absent" is not a state this table can be in, and a guard for it
      # would be unreachable code that reads as if it were doing something. A nil
      # account is refused at the edge instead: the column's NOT NULL for a write
      # that skips the model, and `Subscription`'s presence validation for one that
      # does not. The same reasoning is why `Subscription#account_id` carries no
      # shape validation, and the comment on `Customer#owner_id` is the same note.
      def same_account?(subscription)
        subscription.account_id == customer.owner_id
      end

      def attributes
        {
          account_id: customer.owner_id,
          customer_id: customer.id,
          plan_id: plan.id,
          # The processor's own id, and the key every later delivery is resolved by.
          # It is not in `STATE_ATTRIBUTES`: it is set once, at creation, and never
          # changes — a subscription that changed processor id would be a different
          # subscription, and the unique index already says so.
          processor_subscription_id: processor_subscription_id,
          status: data.fetch("status"),
          current_period_start: parse_time(data["current_period_start"]),
          current_period_end: parse_time(data["current_period_end"]),
          # `== true` rather than the raw value, so a processor that sent the string
          # "false" leaves the flag off instead of making it truthy.
          cancel_at_period_end: data["cancel_at_period_end"] == true,
          canceled_at: parse_time(data["canceled_at"])
        }
      end

      # Derived from what happened to the row. A row that did not exist and is now
      # live has started; a row that has just become canceled has been canceled — and
      # that includes a row that was *born* canceled, which is what a deletion that
      # overtook its own creation produces. A row that is still live has been updated.
      def event_type(existed:, from:)
        return CANCELED_EVENT if terminal?(from: from, to: data.fetch("status"))
        return STARTED_EVENT unless existed

        UPDATED_EVENT
      end

      def terminal?(from:, to:)
        to == "canceled" && from != "canceled"
      end

      # The payload.
      #
      # All three carry billing's own ids — `subscription_id` is this row, and it
      # is the envelope's subject, so a consumer joins `started`, `updated` and
      # `canceled` on one key with no lookup table.
      #
      # **core's schemas for these three types describe a different payload, and
      # this is recorded rather than matched.** core-03 rewrote
      # `schemas/events/billing/subscription/started.schema.json` (D10) on the
      # grounds that "billing has no subscriptions table and cannot invent ids it
      # does not have" — which was true of billing-03b and stopped being true when
      # this table landed. Its `started`, `updated` and `canceled` schemas are the
      # processor-normalised shape, closed with `additionalProperties: false`, so
      # the anywaye ids below are exactly the fields core refuses and the `kind`,
      # `processor`, `processor_event_id` and `customer_id` it requires are exactly
      # the ones absent here. core's own D10 anticipates this — "when billing grows
      # a subscriptions table, the shape moves again … that is a second breaking
      # change" — and that change is core's, in a repository this service may only
      # read.
      #
      # So the difference is written down in `PENDING_PAYLOAD_ALIGNMENT` in
      # `test/contract/outbox_envelope_contract_test.rb` and in `anywaye.yml`, and
      # asserted in both directions. Matching core here instead would be one of the
      # two ways this service can change a published contract without anyone
      # deciding to: emit a payload no consumer has agreed to, or drop `plan_id`
      # and `account_id`, which are the two fields that make a subscription event
      # actionable at all. When core decides, the change lands here and in the
      # contract test together — not by one quietly drifting from the other.
      #
      # The asymmetry between the three is deliberate and still holds: a start also
      # carries `started_at`, and the other two carry the period, the cancellation
      # intent, the time it took effect, and the processor's own ids, because those
      # are the facts a consumer has to act on *those* events and a start has none
      # of them yet.
      def payload(subscription, type)
        core_payload(subscription).merge(type == STARTED_EVENT ? { "started_at" => started_at } : detail_payload)
      end

      def core_payload(subscription)
        payload = {
          "subscription_id" => subscription.id,
          "plan_id" => plan.id,
          # The plan's name beside its id. A mail about a subscription change has
          # to say which plan, and `plan_id` is a uuid no consumer can render into
          # words. The name is the plan's own, read from the row this builder has
          # already resolved, so it costs no query the payload was not already
          # making — the same reason `currency` is here.
          "plan_name" => plan.name,
          "account_id" => customer.owner_id,
          "status" => subscription.status,
          "currency" => plan.currency
        }
        # A field the processor did not send is absent rather than defaulted: a
        # default that silently fills a gap in the weakest input in the system is how
        # a customer ends up on a quantity nobody chose.
        payload["quantity"] = data["quantity"] if data["quantity"].is_a?(Integer)
        # core describes `trial_ends_at` as present only while the subscription is
        # trialing, and that is what it does here — a null when trialing with no end
        # date, absent otherwise.
        payload["trial_ends_at"] = data["trial_ends_at"] if subscription.status == "trialing"
        # The recipient fact, and the reason a consumer can mail a subscription
        # change with no billing client and no billing tables: the address is on
        # the envelope, because there is nowhere else it can be read from
        # (REPORT-courier-consumer-invite-01 §2.6). The customer is resolved for
        # this payload already, so the email costs no query the builder was not
        # already making. Absent — never null — when the customer has no address
        # on file: an event that promises a mail it cannot address is worse than
        # one that carries no address at all, and a consumer refuses the latter
        # by design. Named `email` to match identity's events, which carry the same
        # fact for the same reason.
        payload["email"] = customer.email if customer.email.present?
        payload
      end

      # `started_at` is on the start event only. core defines it as "when the
      # subscription became active, always equal to the envelope's time", which is
      # true of a start and false of an update — on an update the envelope's time is
      # when the *change* happened, and stamping it as the start would be a lie
      # about a fact a consumer renders a timeline from.
      def started_at
        event_time.utc.iso8601
      end

      def detail_payload
        {
          "current_period_start" => data["current_period_start"],
          "current_period_end" => data["current_period_end"],
          "cancel_at_period_end" => data["cancel_at_period_end"] == true,
          "canceled_at" => data["canceled_at"],
          "processor" => data["processor"],
          "processor_event_id" => data["processor_event_id"],
          "processor_subscription_id" => processor_subscription_id
        }
      end

      def parse_time(value)
        value.is_a?(String) ? Time.iso8601(value) : nil
      end
  end
end
