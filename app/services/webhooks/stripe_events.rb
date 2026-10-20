module Webhooks
  # Turns a verified processor payload into this service's own events.
  #
  # The two things it exists to guarantee:
  #
  #   * **Nothing is invented.** A field the processor did not send is absent from
  #     the normalized hash rather than defaulted. A webhook payload is the
  #     weakest input in the system — JSON from the internet, shaped by a third
  #     party — and a default that silently fills a gap is how a customer ends up
  #     on a plan nobody charged them for.
  #   * **The processor's shape stops here.** Everything downstream sees
  #     snake_case keys and integer minor units, so a second processor, or a
  #     change in the processor's payload, is a change in one file.
  #
  # Normalization is separate from emission on purpose: a normalized hash can be
  # asserted on directly, and the same hash feeds every event type that describes
  # the same underlying fact.
  #
  # Every event type below is a member of `OutboxEvent::TYPES` and a row in this
  # repository's `cafaye.yml`. A type that was not would be refused by the outbox
  # at the write, from inside a webhook, and answered 200 — an outage nobody sees
  # until a processor's dashboard does.
  module StripeEvents
    # The processor this build speaks. Not a parameter: a normalizer that takes an
    # arbitrary payload is one that will eventually be handed a payload whose
    # signature was never checked.
    PROCESSOR = "stripe"

    # A signed event whose shape we cannot use. Raised, not returned, so the
    # ingestion layer parks the row rather than emitting an event built from
    # whatever fields happened to be present.
    class UnprocessableEvent < Error; end

    # Reasons a received type produced no event. `ping` is Stripe's own
    # connectivity check: real, signed, and not a business fact. Its row is kept
    # — "the processor is talking to us and we are not acting on it" is worth
    # being able to query — but it must never reach the outbox.
    IGNORED_REASONS = { "ping" => "connectivity_check" }.freeze

    # The reason for a type that is simply not in the registry. Distinct from a
    # deliberate ignore so that "we chose to skip this" and "nobody has written a
    # mapping for this yet" stay tellable apart in the table.
    UNHANDLED = "unhandled_event_type"

    CHECKOUT_TYPE = "checkout.session.completed"

    # Processor event type to cafaye event type. Most are a fixed mapping.
    EVENT_TYPES = {
      "customer.subscription.created" => "billing.subscription.started",
      "customer.subscription.updated" => "billing.subscription.updated",
      "customer.subscription.deleted" => "billing.subscription.canceled",
      "invoice.paid" => "billing.payment.succeeded",
      "invoice.payment_failed" => "billing.payment.failed"
    }.freeze

    # The cafaye event type a normalized hash becomes. The only processor type
    # that is not a fixed mapping is a Checkout session, because it is only ever
    # emitted in payment mode — the subscription-mode case raises `Ignored` in the
    # normalizer rather than producing a second `billing.subscription.started`.
    def self.event_type_for(type, data)
      return "billing.payment.succeeded" if type == CHECKOUT_TYPE

      EVENT_TYPES.fetch(type)
    end

    # The subject an emission is correlated on, per core's envelope: the entity
    # the event is about, not the actor. This build has no subscriptions table and
    # no cafaye subscription id, so the only stable identifier a subscription or
    # payment event has is the processor's: the subscription id when the payload
    # carries one and the customer id otherwise. Recorded as a decision in
    # cafaye.yml; flipping it is this one line.
    def self.subject_for(data)
      data["subscription_id"] || data["customer_id"]
    end

    def self.object_of(payload)
      object = payload.dig("data", "object")
      raise UnprocessableEvent, "event has no data.object" unless object.is_a?(Hash)

      object
    end

    # The processor's timestamps are epoch seconds; the envelope wants RFC3339
    # UTC. A missing timestamp stays absent — it is not zero.
    def self.time_of(value)
      return if value.nil?

      Time.at(value).utc.iso8601
    end

    # The processor's own `created` is *not* in the normalized hash, and that is
    # deliberate. `Webhooks::Ingestion` computes it once and hands the same instant
    # to the handler and to the outbox row, so the event's `time` and the payload's
    # `started_at` cannot be two readings of one field. A third copy here would be
    # a third reading.

    # A money amount on the wire. `Billing::Money#to_h` is the platform's crossing shape,
    # so the normalized payload uses it verbatim rather than a key invented here
    # — an event payload that spelled money differently from every other boundary
    # would need a second reader forever. It also means a non-integer amount
    # raises rather than being rounded: a rounded payment is a bug that surfaces
    # in somebody's invoice.
    def self.money(amount, currency)
      return if amount.nil? || currency.blank?

      Billing::Money.new(amount, currency).to_h
    end

    def self.provenance(payload)
      { "processor" => PROCESSOR, "processor_event_id" => payload["id"] }
    end

    def self.subscription_of(payload)
      subscription = object_of(payload)
      item = subscription.dig("items", "data", 0) || {}
      price = item["price"] || {}

      provenance(payload).merge(
        "kind" => "subscription",
        "subscription_id" => subscription["id"],
        "customer_id" => subscription["customer"],
        # The link back to a cafaye customer, carried in the subscription's metadata
        # when the subscription was bought through our Checkout session. It is absent
        # for a subscription created directly in the processor's dashboard, and the
        # delivery is then recorded as `unknown_customer` rather than matched to
        # whoever happens to share an id.
        "cafaye_customer_id" => subscription.dig("metadata", "cafaye_customer_id"),
        "status" => subscription["status"],
        "quantity" => item["quantity"],
        "price_id" => price["id"] || subscription.dig("plan", "id"),
        "unit_amount" => money(price["unit_amount"] || subscription.dig("plan", "amount"), price["currency"] || subscription["currency"]),
        "current_period_start" => time_of(subscription["current_period_start"]),
        "current_period_end" => time_of(subscription["current_period_end"]),
        "cancel_at_period_end" => subscription["cancel_at_period_end"],
        "canceled_at" => time_of(subscription["canceled_at"]),
        "trial" => subscription["trial_start"].present?,
        # The trial's end in the shape core's payload schema wants it: a date-time,
        # or null while trialing with no end date.
        "trial_ends_at" => subscription["trial_start"].present? ? time_of(subscription["trial_end"]) : nil
      )
    end

    # **Every field here was re-measured against the live API on 2026-10-15,
    # and three of them had moved.** The committed fixtures carry the old
    # shape; a live `invoice.paid` (API 2026-03-25) carries:
    #
    #   * no `paid` boolean at all — its `status` is `"paid"`, so the
    #     recorder's screen on `paid` read nil and **recorded no charge for
    #     any real payment**. Both shapes are accepted now; the fixture
    #     proves the old one and the drill proves the new one.
    #   * no top-level `subscription` — it is
    #     `parent.subscription_details.subscription`, so the payment event's
    #     subject fell back to the customer id instead of the processor's
    #     subscription id.
    #   * no `charge` and no `payment_intent` on the object (see the
    #     recorder's `processor_charge_id`, which reads the invoice's own id
    #     when neither is present).
    def self.invoice_of(payload)
      invoice = object_of(payload)

      provenance(payload).merge(
        "kind" => "payment",
        "customer_id" => invoice["customer"],
        # The link back to the cafaye customer, from wherever the shape of the
        # day carries it. The first checkout's `invoice.paid` arrives **before**
        # `customer.subscription.created` — measured on this stack, 2026-10-16 —
        # so there is no subscription row yet to resolve the customer through,
        # and a customer created through `/v1` has no `processor_customer_id`
        # either. The Checkout session put this metadata on the subscription,
        # and reading it is the difference between a receipt and none.
        "cafaye_customer_id" => cafaye_customer_of(invoice),
        "subscription_id" => invoice["subscription"] || invoice.dig("parent", "subscription_details", "subscription"),
        "invoice_id" => invoice["id"],
        "payment_intent_id" => invoice["payment_intent"],
        "paid" => paid_invoice?(invoice),
        "amount" => money(settled_or_due(invoice), invoice["currency"]),
        "attempt_count" => invoice["attempt_count"],
        "next_payment_attempt" => time_of(invoice["next_payment_attempt"])
      )
    end

    # The cafaye reference, wherever the live shape carries it: the invoice's
    # own metadata, the subscription's (which the live shape nests under
    # `parent`), or the first line item's. Measured, 2026-10-16: the top level
    # is empty and the other two carry it.
    def self.cafaye_customer_of(invoice)
      invoice.dig("metadata", "cafaye_customer_id") ||
        invoice.dig("parent", "subscription_details", "metadata", "cafaye_customer_id") ||
        invoice.dig("lines", "data", 0, "metadata", "cafaye_customer_id")
    end
    private_class_method :cafaye_customer_of

    # Whether the processor says this invoice was paid. Two shapes, one fact:
    # the old fixture carries `paid`, the live one (`2026-03-25.dahlia`)
    # carries only `status`. `paid` and `settled_or_due` read this one
    # predicate, so the event and the recorded amount cannot disagree about
    # whether money moved.
    def self.paid_invoice?(invoice)
      invoice["paid"] == true || invoice["status"] == "paid"
    end
    private_class_method :paid_invoice?

    # The amount an invoice event is about. A paid invoice reports what was
    # collected; a failed one reports what could not be, which is `amount_due` and
    # *not* `amount_paid` — the failed fixture carries `amount_paid: 0`, and 0 is
    # truthy in Ruby, so the naive `amount_paid || amount_due` would report a
    # failed 29.00 charge as a settled 0.00. Billing::Money is not worth a clever
    # fallback.
    def self.settled_or_due(invoice)
      paid_invoice?(invoice) ? invoice["amount_paid"] : invoice["amount_due"]
    end
    private_class_method :settled_or_due

    # A checkout session is one event type with two meanings.
    #
    # In payment mode it is a charge, and a charge is a payment fact this service
    # must not lose: no invoice event exists for a one-time Checkout. It becomes
    # `billing.payment.succeeded`.
    #
    # In subscription mode it says nothing that `customer.subscription.created`
    # does not say a moment later, and the two arrive as separate deliveries with
    # separate envelope ids. Emitting both would state one fact twice, and a
    # consumer counting `billing.subscription.started` would count every Checkout
    # signup twice. So it is deliberately ignored, with the reason recorded, rather
    # than emitted and left for a consumer to deduplicate. See DECISION in cafaye.yml.
    def self.checkout_session_of(payload)
      session = object_of(payload)
      base = provenance(payload).merge("customer_id" => session["customer"])

      return payment_checkout(base, session) if session["mode"] == "payment"

      raise Ignored, "subscription_mode_is_restated_by_the_subscription_lifecycle"
    end

    def self.payment_checkout(base, session)
      base.merge(
        "kind" => "payment",
        "checkout_session_id" => session["id"],
        "payment_intent_id" => session["payment_intent"],
        "client_reference_id" => session["client_reference_id"],
        "paid" => session["payment_status"] == "paid",
        "amount" => money(session["amount_total"], session["currency"])
      )
    end
    private_class_method :payment_checkout

    # The registry and the normalizers are built from one table, so a type cannot
    # be normalizable but un-emittable, or vice versa.
    NORMALIZERS = {
      Subscriptions::Lifecycle::CREATED => method(:subscription_of),
      Subscriptions::Lifecycle::UPDATED => method(:subscription_of),
      Subscriptions::Lifecycle::DELETED => method(:subscription_of),
      "invoice.paid" => method(:invoice_of),
      "invoice.payment_failed" => method(:invoice_of),
      CHECKOUT_TYPE => method(:checkout_session_of)
    }.freeze

    # Two kinds of handler, and the difference is what the emission *is*.
    #
    # A subscription event applies to a row in this service, so the event type and
    # the subject are decided by what happened to that row and are not known until
    # it has been written. `Subscriptions::Lifecycle` is therefore the handler: it
    # writes the row and returns the emission for the change, inside the caller's
    # transaction. Its refusals are `Subscriptions::Refused`, which is translated
    # here into `Webhooks::Ignored` — the vocabulary the ingestion layer already
    # records on a delivery row and answers 200.
    #
    # A payment event has no row, so its type and subject come from the normalized
    # payload and the handler is a mapping and nothing more.
    HANDLERS = NORMALIZERS.keys.to_h do |type|
      handler = if Subscriptions::Lifecycle::TYPES.include?(type)
        ->(payload, event_time) { subscription_emission(type, payload, event_time) }
      else
        ->(payload, event_time) { payment_emission(type, payload, event_time) }
      end

      [ type, handler ]
    end.freeze

    def self.subscription_emission(type, payload, event_time)
      applied = Subscriptions::Lifecycle.new(data: normalize(payload), event_time: event_time).call(type)

      Emission.new(event_type: applied.event_type, subject: applied.subject, data: applied.data)
    rescue Subscriptions::Refused => e
      # A decision this service has made, recorded with its reason and answered 200.
      # Not a failure: an unknown customer, a plan we do not have, a delivery that
      # arrived before the one it depends on and a repeat of a state we already hold
      # are all conclusions, and a retry reaches the identical one.
      raise Ignored, e.reason
    end

    # A payment emission is a **mapping and a write**, in that order, and the
    # write is why this method still takes the raw payload after normalization
    # has already happened.
    #
    # `Subscriptions::Lifecycle` is the precedent for a handler that writes: the
    # handler is inside `Webhooks::Ingestion#emit`'s transaction, so a charge and
    # the `billing.payment.succeeded` event that describes it commit together or
    # not at all. That ordering is load-bearing and it is the reason the charge is
    # recorded here rather than by an `after_create` on the outbox row: a receipt
    # committed separately from the event is a receipt a consumer was never told
    # about, and a consumer reconciling events against receipts would be
    # permanently short one row with nothing to say which.
    def self.payment_emission(type, payload, event_time)
      data = normalize(payload)
      Charges::Recorder.new(data: data, payload: payload, event_time: event_time).record

      Emission.new(event_type: event_type_for(type, data), subject: subject_for(data), data: with_recipient(data))
    end
    private_class_method :payment_emission

    # The recipient fact: the cafaye customer's billing email, carried on the
    # payment events because the fleet's consumer cannot read it anywhere else.
    #
    # courier — the consumer that would mail a receipt for a settled charge and a
    # warning for a failed one — has no billing client and no billing tables
    # (REPORT-courier-consumer-invite-01.md §2.6: a consumer acts on the envelope
    # or refuses, and never looks up). An event with no address on it is an event
    # that is dropped, so every money event was a dead letter for the one consumer
    # that needed it. The parallel fix already exists on the identity side:
    # `identity.session.revoked` and `identity.user.created` carry a top-level
    # `email` for exactly this reason, and this field is named `email` to match
    # it — one fleet, one field name for the address a consumer cannot look up.
    #
    # ## What it costs, stated rather than hidden
    #
    # This is the one lookup the payment path makes that the normalizer does
    # not: one or two indexed reads per payment event — the cafaye id's primary
    # key first, the processor's id (unique, partial — billing-13) when the
    # event names one. The webhook path is not a user-facing request, and the
    # ingestion transaction is already writing three rows; a couple of indexed
    # reads are noise beside them. It is here because the alternative — a
    # receipt event with no address — is the gap this packet exists to close.
    #
    # ## Absent, never null
    #
    # A customer created in the processor's dashboard has no cafaye row, and a
    # cafaye customer created through `/v1` has no email until the client sets
    # one (`customers.email` is nullable on purpose). Both cases leave the field
    # **absent** rather than null, the same rule the normalizer applies to a field
    # the processor did not send: an event that promises a mail it cannot address
    # is worse than one that carries no address at all, and a consumer refuses
    # the latter by design.
    def self.with_recipient(data)
      email = recipient_email(data)
      email ? data.merge("email" => email) : data
    end

    # Resolved the way the charge recorder resolves the customer — the cafaye id
    # first, the processor's id second — and the order is the same measured fix
    # on the other half of the payment path (see `Charges::Recorder`): on an
    # account's FIRST payment the row has no `processor_customer_id` yet, because
    # Stripe creates its customer at the hosted checkout and the id is written
    # back by an event that lands around the same time. A lookup by the
    # processor's id alone therefore finds nothing on exactly the payment that
    # opens the relationship, and the receipt event goes out unaddressed — which
    # the fleet's consumer refuses by design (measured on the launch stack,
    # 2026-10-16: a real $49 first payment's event was refused ten times for a
    # missing address). The cafaye id is the one our own Checkout session put on
    # the subscription's metadata, so it is present on every event from this
    # service's checkout path; the processor's id remains the fallback for a
    # customer created in the dashboard.
    def self.recipient_email(data)
      customer = find_customer(data["cafaye_customer_id"]) || find_customer(data["customer_id"])
      customer&.email.presence
    end
    private_class_method :recipient_email

    def self.find_customer(identifier)
      return nil if identifier.blank?

      Customer.find_by(id: identifier) || Customer.find_by(processor_customer_id: identifier)
    end
    private_class_method :find_customer

    class << self
      # The handler for a processor event type, or nil when this build does not
      # act on it.
      def handler_for(type)
        HANDLERS[type]
      end

      # Why a type produced no event: a deliberate reason if we have one, the
      # generic unhandled reason otherwise.
      def ignored_reason(type)
        IGNORED_REASONS.fetch(type, UNHANDLED)
      end

      # The normalized hash for a payload, or nil for a type with no normalizer.
      # Public because it is the shape the tests assert on and the shape a future
      # replay tool would want to read back out of a stored payload.
      def normalize(payload)
        NORMALIZERS[payload["type"]]&.call(payload)
      end
    end
  end
end
