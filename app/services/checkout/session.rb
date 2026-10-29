module Checkout
  # A checkout session: the act of starting a subscription, as a value.
  #
  # ## The shape of the thing
  #
  # `complete` takes a `Customer` (this repository's word for a subscriber — the
  # owner of a billing relationship, either a `User` or an `Account`) and a `Plan`,
  # asks the processor to start the subscription, and then records what the
  # processor said. There is no `CheckoutSession` table, because a checkout is
  # not a thing anybody looks up later: it is a request and its result.
  #
  # ## The processor, and which one it is
  #
  # This checkout goes through `Processor::FakeClient` — the in-process fake
  # whose books live in memory. It used to go through `pay`'s `FakeProcessor`,
  # whose books were six Active Record tables; that gem and its tables are gone
  # (`20261015120000_drop_pay_tables.rb`), because a payment abstraction with a
  # STI schema is not what a service whose live Stripe surface is three methods
  # on `Processor::StripeClient` needs. `pay_customer` and `Pay::Customer` are
  # gone with it: the fake has no customer row, only a derived id, and
  # `customer_id_for` is where that happens.
  #
  # The production door is a different one, and this class must not grow it:
  # `POST /v1/subscriptions` asks `Processor::StripeClient` for a hosted Checkout
  # session and writes nothing. A checkout that talked to Stripe here would be
  # a second path with a second answer to "what is this subscription's status".
  #
  # ## The rule this class exists to hold
  #
  # **`Subscriptions::Lifecycle` is still the only writer of a `Subscription`, and
  # this class does not become a second one.**
  #
  # It is very tempting for a checkout to write the row itself — it has the
  # customer, the plan, the processor's subscription id and the status, and one
  # `save!` would do it. That would break the rule the whole service is built on
  # (`AGENTS.md`, Subscriptions: "this service never decides what a subscription's
  # status is"), and it would do so in the most expensive direction: a checkout
  # that granted entitlements the moment the *request* was accepted, with nothing
  # from the party that can actually bill.
  #
  # So completion builds the **same normalised delivery a webhook would carry**
  # and hands it to `Lifecycle`, which owns the state machine, the uniqueness
  # rules, the `account_mismatch` refusal and the outbox event. Two entry points,
  # one writer, one answer to "what is this subscription's status".
  #
  # ## Why the ordering is what it is
  #
  # The processor is asked **first** and the row is written **second**, and that
  # order is the negative case this packet is really about. If the row were
  # written first and the processor refused, the failure would need a rollback to
  # undo it — and a rollback is a claim that nothing was written, which is exactly
  # the claim a crash, a nested transaction or a later `after_commit` can make
  # false. Here, on the failure path, **nothing was ever written**: there is
  # nothing to roll back because the only write is downstream of the only call
  # that can fail. `test/services/checkout/session_test.rb` asserts the
  # subscription did not move, rather than asserting that it moved back.
  class Session
    PROCESSOR = Processor::FakeClient::PROCESSOR

    NOT_ON_SALE = "plan_not_on_sale".freeze
    NOT_AN_ACCOUNT = "customer_not_an_account".freeze
    PROCESSOR_REFUSED = "processor_refused".freeze
    SUBSCRIPTION_REFUSED = "subscription_refused".freeze

    Outcome = Data.define(:state, :reason, :subscription, :processor_subscription) do
      def completed?
        state == :completed
      end

      def failed?
        state == :failed
      end
    end

    attr_reader :customer, :plan, :quantity

    # `quantity` is per-seat pricing, and it is validated here rather than at
    # the edge because this class is the edge for now — the checkout door this
    # service serves (`POST /v1/checkouts`) hands the value through, and the
    # fake multiplies nothing: the seats are the processor's to price.
    #
    # `processor` is the seam. The specs pass a recorder, a raiser or a
    # refusing processor and assert on what was *asked*; the default is the
    # fake. The shape mirrors `Processor::StripeClient`'s `api:` keyword for
    # the same reason: a hand-written double of the checkout path is a second
    # implementation of it.
    def initialize(customer:, plan:, quantity: 1, processor: Processor::FakeClient.new)
      @customer = customer
      @plan = plan
      @quantity = quantity
      @processor = processor
    end

    # => Outcome. **Never raises for a business refusal**, and never returns
    # anything that is not an `Outcome`.
    def complete
      return failed(NOT_ON_SALE) unless on_sale?
      return failed(NOT_AN_ACCOUNT) unless account_owned?

      subscription = subscribe
      return failed(PROCESSOR_REFUSED) if subscription.nil?

      recorded(subscription)
    end

    # Whether this plan can be bought at all right now.
    #
    # Both halves are refused together because they are one fact: **is this plan on
    # sale at the processor.** A withdrawn plan and a plan with no `price_` are the
    # same answer to a subscriber, and the second half is what keeps this service
    # from ever having to name a price — `Plan#price` is read for the response and
    # never sent, because the amount the customer is charged is the processor's
    # (`AGENTS.md`, Billing::Money: "no amount is ever computed to send to a processor").
    def on_sale?
      plan.active? && plan.processor_price_id.present?
    end

    # A `User`-owned customer is in no account, which is the same fact
    # `Subscription#account_is_the_customers_owner` refuses a row over. Asking
    # the processor to start a subscription we would then have to refuse to
    # record would leave a subscription at the processor that this service has
    # no row for — a live thing being billed with nothing granting
    # entitlements.
    def account_owned?
      customer.owner_type == Subscription::BILLABLE_OWNER_TYPE
    end

    private
      # The one call that can fail before anything is written, and the only place
      # an exception is rescued. It is rescued **here** rather than around the whole
      # of `complete` so that a refusal from `Subscriptions::Lifecycle` keeps its
      # own reason instead of being flattened into `processor_refused` — the two
      # mean very different things to whoever reads the failure.
      #
      # The rescue is on `Processor::Error` alone, and that is deliberate. The old
      # line also rescued `ActiveRecord::RecordInvalid`, because `pay`'s
      # `FakeProcessor` wrote rows and a uniqueness validation was one of the ways
      # it could refuse. This processor writes nothing: an `ActiveRecord::RecordInvalid`
      # escaping it would be a bug in this service, and rescuing it here would
      # report that bug as a declined card — the one thing a failure value must
      # never be.
      def subscribe
        @processor.subscribe(**request_kwargs)
      rescue Processor::Error
        nil
      end

      # The key is **absent** when there is no trial, and not present-with-nil.
      # A processor receiving `trial_period_days: nil` reads a key it may act
      # on, and the guard's whole job is that a checkout with no trial asks for
      # no trial. Recorded by the specs at the request, not at the answer.
      def request_kwargs
        {
          price_id: plan.processor_price_id,
          quantity: quantity,
          price: plan.price,
          interval: plan.interval
        }.merge(trial_kwargs)
      end

      def trial_kwargs
        plan.trial_days.to_i.positive? ? { trial_period_days: plan.trial_days } : {}
      end

      # Hand the processor's answer to the one writer of a `Subscription`.
      #
      # `Subscriptions::Lifecycle` raises `Refused` for the cases it is built for
      # — a canceled row, an account that does not match, a delivery that records
      # no change — and that is caught and returned as a failure. It is caught here
      # rather than left to propagate because a caller of `complete` asked "did
      # this subscription start?", and an exception would answer a different
      # question: an exception says "this service broke", and none of these reasons
      # is a bug.
      #
      # The processor's row survives a refusal, deliberately. It is the processor's
      # record of what the customer agreed to at the processor, this service did
      # not create it and cannot delete it, and quietly cancelling it behind the
      # customer's back would be this service taking an action nobody asked for.
      # Reconciling it is the delivery path's job, and until that arrives the
      # honest state is "the processor has one and we do not", which is what the
      # failure outcome reports.
      def recorded(subscription)
        applied = nil

        Subscription.transaction do
          applied = Subscriptions::Lifecycle.new(
            data: delivery(subscription),
            event_time: subscription.created_at
          ).call(Subscriptions::Lifecycle::CREATED)

          OutboxEvent.publish!(
            type: applied.event_type,
            subject: applied.subject,
            data: applied.data,
            time: subscription.created_at
          )
        end

        Outcome.new(
          state: :completed,
          reason: nil,
          subscription: applied.subscription,
          processor_subscription: subscription
        )
      rescue Subscriptions::Refused => refusal
        failed(SUBSCRIPTION_REFUSED, reason_detail: refusal.reason, processor_subscription: subscription)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        failed(SUBSCRIPTION_REFUSED, reason_detail: "already_subscribed", processor_subscription: subscription)
      end

      def failed(reason, reason_detail: nil, processor_subscription: nil)
        Outcome.new(
          state: :failed,
          reason: reason_detail ? "#{reason}:#{reason_detail}" : reason,
          subscription: nil,
          processor_subscription: processor_subscription
        )
      end

      # The normalised delivery, in exactly the shape `Webhooks::StripeEvents`
      # produces — because `Lifecycle` is written against that shape and this
      # class is deliberately not a second normaliser.
      #
      # `anywaye_customer_id` is this service's own id for the customer, and it is
      # the field `Lifecycle#customer` prefers over the processor's id, because a
      # customer created through `/v1` has a null `processor_customer_id` until its
      # first subscription tells us what the processor calls it. Sending it means
      # the checkout path and the delivery path resolve the same row the same way.
      # The processor's own customer id is still carried beside it, because a webhook
      # carries one and a delivery with the same shape is a delivery the lifecycle
      # reads the same way.
      #
      # **No `processor_event_id`, on purpose.** `AGENTS.md` (Webhooks in) records
      # that a start payload deliberately carries none, and the reason survives
      # here: the outbox's partial unique index is over
      # `((data ->> 'processor_event_id'))` where that key is present, and a key
      # here would make a start compete with deliveries for that index over a
      # value that is not an event id at all. A checkout is not an event; it is the
      # thing that caused one.
      #
      # `current_period_start` and `current_period_end` are **absent rather than
      # guessed.** The fake does not compute a period, and deriving one from
      # `Plan#interval` here would be this service inventing a billing period the
      # processor never stated. A subscription whose period the processor has not
      # published has no period recorded, and `Lifecycle#parse_time` turns an
      # absent value into nil without inventing one.
      def delivery(subscription)
        {
          "subscription_id" => subscription.processor_id,
          "status" => status_for(subscription),
          "anywaye_customer_id" => customer.id,
          "customer_id" => @processor.customer_id_for(customer),
          "price_id" => plan.processor_price_id,
          "quantity" => quantity,
          "trial_ends_at" => subscription.trial_ends_at&.utc&.iso8601,
          "cancel_at_period_end" => false,
          "canceled_at" => nil,
          "processor" => PROCESSOR
        }.compact
      end

      # What the processor says the subscription is, read off its answer rather
      # than decided here. `AGENTS.md` (Subscriptions) says this service never
      # decides a subscription's status, and a local re-derivation is exactly
      # that decision wearing a costume: re-computing `trialing` from
      # `trial_ends_at` reads as the same answer the processor gives, until the
      # day they disagree — and then this service's guess would be the one
      # recorded. The processor's own status is the only one that goes on the
      # wire and the only one that reaches the row.
      def status_for(subscription)
        subscription.status
      end
  end
end
