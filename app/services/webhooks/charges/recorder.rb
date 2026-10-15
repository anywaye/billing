module Webhooks
  module Charges
    # Records the receipt for a payment the processor says succeeded.
    #
    # ## The rule this object exists to hold
    #
    # **A charge is recorded when money moved, and never when it did not.** The
    # only thing consulted is the processor's own `paid` on the normalised
    # payload, because a receipt is a claim that a customer paid, and only the
    # party that took the money can make that claim. Nothing in this file looks at
    # a cafaye request, a plan, a price, or an intent — a charge written from
    # anything but a settled processor payment would be a receipt for something
    # this service decided rather than something that happened.
    #
    # ## Why it is an object and not five methods on `StripeEvents`
    #
    # It has one caller and it is a `private_class_method` on a module whose job
    # is turning payloads into events. Burying the write there meant the write's
    # preconditions were spread across five predicates with no place to say what
    # happens when one of them is false — and the answer ("nothing is recorded,
    # and the event is still published") is the single most important thing
    # here. It gets a class, a doc comment and its own spec.
    #
    # ## The preconditions, and why each one skips rather than raises
    #
    # This is called from inside `Webhooks::Ingestion#emit`, between the
    # `ProcessorWebhook.transaction` opening and the outbox write. **Anything
    # raised here is caught by the ingestion layer's generic `StandardError`
    # branch and parks the delivery** — which would mean the *event* is lost too,
    # over a receipt that could not be written. A `NoMethodError` on a payload
    # missing an amount is a bug in this file, not a decision about the payment,
    # and a correct `billing.payment.succeeded` must not disappear because of it.
    #
    # So the payload is *screened* here, and each skip is recorded in the delivery's
    # own vocabulary rather than raised. Integrity failures are different and are
    # deliberately **not** caught: a uniqueness violation propagates so the
    # ingestion layer classifies it as `ignored:duplicate_delivery` on the
    # exception class it already classifies for every other race, rather than this
    # object inventing a second opinion about one.
    class Recorder
      def initialize(data:, payload:, event_time:)
        @data = data
        @payload = payload
        @event_time = event_time
      end

      # The Charge, or nil when the payment does not become one. Never raises for
      # a payload that cannot produce a receipt; see the class comment.
      def record
        return unless paid?
        return unless amount.positive?

        customer = resolved_customer
        return if customer.nil?

        account_id = resolved_account_id(customer)
        return if account_id.nil?

        ::Charge.create!(
          account_id: account_id,
          customer_id: customer.id,
          subscription_id: resolved_subscription&.id,
          processor_charge_id: processor_charge_id,
          amount: amount,
          currency: currency,
          description: description,
          paid_at: paid_at
        )
      end

      private
        attr_reader :data, :payload, :event_time

        # Did money move? The processor's own answer, read from the normalised
        # payload rather than the raw one so that the two can never disagree
        # about the same field — `Webhooks::StripeEvents.settled_or_due` has
        # already resolved `paid` into an amount that means the same thing.
        def paid?
          data["paid"] == true
        end

        # The processor's own money block, or an empty hash when the payload
        # carried no amount. An empty hash is what makes `amount` zero, which is
        # what makes `record` skip — so `currency` can never be asked a question
        # about a missing key, and there is no ordering between two guards to get
        # wrong.
        def money
          @money ||= data["amount"].is_a?(Hash) ? data["amount"] : {}
        end

        # The collected amount, in integer minor units, or 0 when the payload
        # carries no amount at all.
        #
        # **Zero and negative are both skipped, and negative is the interesting
        # one.** Stripe settles an invoice whose total is entirely covered by the
        # customer's credit balance with a *negative* `amount_paid`, and sends
        # `invoice.paid` for it. `Money` permits a negative amount — it has
        # `#negative?` — and `charges_amount_not_negative` would refuse the row,
        # so recording it would raise `RecordInvalid` from inside a webhook and
        # **park a correct `billing.payment.succeeded` over a receipt that should
        # not exist**. No money moved, so there is no charge; the event is a fact
        # about the account's balance and belongs to the event stream alone.
        def amount
          money["amount_minor"].to_i
        end

        def currency
          money["currency"]
        end

        # When the money moved: the processor's own instant.
        #
        # `Webhooks::Ingestion` reads the processor's `created` once and hands the
        # same value to the handler and the outbox row, so a charge and its event
        # cannot be two readings of one clock. `Time.current` here would be the
        # moment *this service* got round to writing the row, which is an arrival
        # time, and a receipt whose timestamp moves with the size of the queue is
        # not a record of when anyone was charged.
        def paid_at
          event_time
        end

        # The cafaye customer. A charge with no resolvable customer is not
        # recorded: the customer is the link back to the account, and
        # `belongs_to :customer` is required, so proceeding would raise over a
        # payment that was perfectly real. This is a known gap, not a rule — an
        # `invoice.paid` for a customer created in the processor's dashboard has
        # no cafaye customer, and its receipt is therefore not written.
        #
        # **The cafaye link is consulted first**, and the order is the fix for a
        # measured defect (2026-10-16): the first checkout's `invoice.paid`
        # arrives before `customer.subscription.created`, and a customer
        # created through `/v1` has no `processor_customer_id` until a
        # subscription event names one — so resolving by the processor's
        # customer id alone found nothing and the receipt for a real payment
        # was silently not written. The metadata the Checkout session set is
        # the id this service minted; the processor's id is the fallback.
        def resolved_customer
          @resolved_customer ||= find_customer(data["cafaye_customer_id"]) || find_customer(data["customer_id"])
        end

        def find_customer(identifier)
          return nil if identifier.blank?

          ::Customer.find_by(id: identifier) ||
            ::Customer.find_by(processor_customer_id: identifier)
        end

        # Whose charge this is, and the first question the tenancy rules ask.
        #
        # The subscription is consulted first and for a reason beyond specificity:
        # `subscriptions.account_id` is already the account the lifecycle
        # verified at the moment it wrote the row, and it is guarded against being
        # reassigned by `account_mismatch` (`AGENTS.md`, Subscriptions). It is the
        # most trustworthy single answer this service holds.
        #
        # A `User`-owned customer answers nothing — that is the rule
        # `Customer.for_account` encodes, and a receipt in no account is a receipt
        # nobody can read. `client_reference_id` is the last resort because it is
        # the one field a cafaye request put on the processor's session, and it is
        # shape-checked before use: an unchecked value from the processor's side
        # of a session would be a caller naming their own account, which is the
        # one thing `AGENTS.md` (Authorization) forbids outright.
        def resolved_account_id(customer)
          return account_of_subscription if account_of_subscription.present?
          return customer.owner_id if customer.owner_type == ::Subscription::BILLABLE_OWNER_TYPE
          return client_reference_id if account_shaped?(client_reference_id)

          nil
        end

        def account_of_subscription
          @account_of_subscription ||= resolved_subscription&.account_id
        end

        def resolved_subscription
          return nil if data["subscription_id"].blank?

          @resolved_subscription ||= ::Subscription.find_by(processor_subscription_id: data["subscription_id"])
        end

        def client_reference_id
          data["client_reference_id"]
        end

        def account_shaped?(value)
          value.present? && Identifiers::UUID.match?(value)
        end

        # What the customer was charged for, in words a person can read.
        #
        # The invoice's **line item** is the answer, not the invoice id: the
        # brief for a receipt is "what did I pay for", and `in_1PZQ…` does not
        # answer it while the fixture's own line item says `3 × Pro monthly`.
        #
        # Read off the **raw** payload on purpose. The normalised hash carries
        # only what `billing.payment.succeeded` publishes, core's payload schema
        # for that type has no description field, and adding one to satisfy a
        # receipt would change an event's shape — a contract change made by a
        # receipt. The raw payload is the processor's, read once, for this.
        #
        # Every fallback is the processor's own words or its own id. Nothing is
        # invented, which is the same rule the rest of the normaliser follows.
        def description
          line_description || invoice_number || checkout_label || "Charge #{data["payment_intent_id"]}"
        end

        def line_description
          lines = payload.dig("data", "object", "lines", "data")
          return nil unless lines.is_a?(Array)

          lines.filter_map { |line| line["description"].presence }.first
        end

        def invoice_number
          number = payload.dig("data", "object", "number")
          number.presence && "Invoice #{number}"
        end

        def checkout_label
          session_id = data["checkout_session_id"]
          session_id.presence && "Checkout #{session_id}"
        end

        # The processor's own id for the payment, which is what the UNIQUE index
        # dedupes a redelivery on and what a receipt cites.
        #
        # An invoice carries the charge object's id (`ch_…`). A one-time Checkout
        # session does not: the charge is created by the processor after the
        # session completes, and the session payload's only identifier for the
        # payment is the payment intent. So the intent is what is recorded there —
        # it is the processor's own unique id for that payment, no two payments
        # share one, and a redelivery of the same event carries the same value,
        # which is the property the index needs. The column is named for the
        # common case and holds the processor's id in both.
        # The processor's own id for this payment, and the live API left
        # three shapes to read it from. A subscription invoice used to carry
        # `charge`; a live one (API 2026-03-25) carries NEITHER `charge` NOR
        # `payment_intent` inline — measured on the drill's real invoice —
        # so the invoice's own id is the third fallback. It is unique per
        # invoice, stable across redeliveries, and the same identifier the
        # processor's dashboard shows for the payment.
        def processor_charge_id
          payload.dig("data", "object", "charge") || data["payment_intent_id"] || payload.dig("data", "object", "id")
        end
    end
  end
end
