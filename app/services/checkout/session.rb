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
    # The processor this service checks out through.
    #
    # FakeProcessor only, and that is a packet boundary rather than a preference:
    # this class asks the processor for a subscription and nothing else, so
    # swapping in Stripe is a configuration change and not a rewrite. Live
    # processors are a later packet — see the comment on `Customer#pay_customer`
    # and `Processor::StripeClient`, which is still this service's Stripe path.
    PROCESSOR = "fake_processor".freeze

    # The subscription name every checkout buys under. `pay` groups a customer's
    # subscriptions by this string and `Pay::Customer#subscribed?` filters on it,
    # so it is a real key and not a label. `pay`'s own default is used rather than
    # a name of this service's inventing: one product, one name, and the value
    # lives in configuration (`config/initializers/pay.rb`) if there is ever a
    # second.
    PRODUCT_NAME = Pay.default_product_name

    # The reasons an outcome can be a failure. A closed list, for the reason every
    # closed list in this repository is closed: a reason somebody can read is a
    # reason a test can assert, and an unbounded one is a string that grows a
    # second answer whenever a new case is noticed.
    #
    #   * `plan_not_on_sale`       — the plan is withdrawn, or has no price id at
    #                                 the processor. There is nothing to subscribe
    #                                 to, and inventing a price for it here would
    #                                 be this service deciding an amount, which
    #                                 `AGENTS.md` (Money) forbids outright.
    #   * `customer_not_an_account` — a `User`-owned customer. Exactly the rule
    #                                 `Subscription::BILLABLE_OWNER_TYPE` already
    #                                 enforces on the row, checked here so the
    #                                 processor is never asked on behalf of a
    #                                 customer that could not hold the result.
    #   * `processor_refused`      — the processor declined, or the call raised.
    #   * `subscription_refused`    — the processor said yes and this service could
    #                                 not record it. The reason is the lifecycle's
    #                                 own, verbatim, because this service must not
    #                                 flatten "the account does not match" and
    #                                 "canceled is terminal" into one word.
    NOT_ON_SALE = "plan_not_on_sale".freeze
    NOT_AN_ACCOUNT = "customer_not_an_account".freeze
    PROCESSOR_REFUSED = "processor_refused".freeze
    SUBSCRIPTION_REFUSED = "subscription_refused".freeze

    # What a checkout did. A value object, so a handler cannot observe a
    # half-finished checkout: there is no object here that is neither complete
    # nor failed, and no object that is complete but has no subscription.
    #
    # `pay_subscription` is kept alongside `subscription` rather than thrown away
    # because they are two different records of two different parties: `pay`'s row
    # is the processor's, and this service's `Subscription` is its own. The
    # delivery path reconciles them by `processor_subscription_id`, and a checkout
    # that reported only one of them would hide which side moved.
    Outcome = Data.define(:state, :reason, :subscription, :pay_subscription) do
      def completed?
        state == :completed
      end

      def failed?
        state == :failed
      end
    end

    attr_reader :customer, :plan, :quantity

    # `quantity` is per-seat pricing, and it is validated here rather than at the
    # edge because this class is the edge for now — there is no HTTP door on
    # checkout in this build (see the class comment on the processor boundary).
    # `pay` 12.2 is the floor in the Gemfile precisely because its
    # `FakeProcessor#subscribe` is the first line that accepts a `quantity` at
    # all; an earlier one would have silently dropped it and every per-seat test
    # would have passed while charging for one seat.
    def initialize(customer:, plan:, quantity: 1)
      @customer = customer
      @plan = plan
      @quantity = quantity
    end

    # => Outcome. **Never raises for a business refusal**, and never returns
    # anything that is not an `Outcome`.
    def complete
      return failed(NOT_ON_SALE) unless on_sale?
      return failed(NOT_AN_ACCOUNT) unless account_owned?

      pay_subscription = subscribe
      return failed(PROCESSOR_REFUSED) if pay_subscription.nil?

      recorded(pay_subscription)
    end

    # Whether this plan can be bought at all right now.
    #
    # Both halves are refused together because they are one fact: **is this plan on
    # sale at the processor.** A withdrawn plan and a plan with no `price_` are the
    # same answer to a subscriber, and the second half is what keeps this service
    # from ever having to name a price — `Plan#price` is read for the response and
    # never sent, because the amount the customer is charged is the processor's
    # (`AGENTS.md`, Money: "no amount is ever computed to send to a processor").
    def on_sale?
      plan.active? && plan.processor_price_id.present?
    end

    # A `User`-owned customer is in no account, which is the same fact
    # `Subscription#account_is_the_customers_owner` refuses a row over. Asking the
    # processor to start a subscription we would then have to refuse to record
    # would leave a subscription at the processor that this service has no row
    # for — a live thing being billed with nothing granting entitlements.
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
      # The rescue is on `Pay::Error` and `ActiveRecord::RecordInvalid` rather than
      # on `StandardError`: a processor that refuses is a decision, and those two
      # are what every processor in `pay` raises for one. Rescuing `StandardError`
      # here would swallow a `NoMethodError` in this file and report it to the
      # caller as a declined card, which is the one thing a failure value must
      # never be.
      def subscribe
        processor_customer.subscribe(
          name: PRODUCT_NAME,
          plan: plan.processor_price_id,
          quantity: quantity,
          **trial_options
        )
      rescue Pay::Error, ActiveRecord::RecordInvalid
        nil
      end

      # **Only passed when there is a trial.** `FakeProcessor#subscribe` tests the
      # option for truthiness and Ruby says `0` is truthy, so passing
      # `trial_period_days: 0` would set `trial_ends_at` to the present moment and
      # produce a subscription that is `trialing` and already over. The `positive?`
      # is the guard, and it is the sort of thing that is invisible in a passing
      # test and wrong in a customer's invoice.
      def trial_options
        plan.trial_days.to_i.positive? ? { trial_period_days: plan.trial_days } : {}
      end

      # The processor's customer for this subscriber, created on first use.
      #
      # `payment_processor` is `pay`'s billable reader: it finds or creates the
      # `Pay::Customer` owned by this subscriber and marked default, so this is
      # the only place a processor customer is obtained and there is no second
      # lookup to disagree with it.
      def processor_customer
        # Read through the **association**, and that is load-bearing.
        # `Pay::Attributes::CustomerExtension#payment_processor` overrides the
        # `has_one` reader and ends in `reload_payment_processor`, whose return
        # value is not the record — so on the **first** checkout of a subscriber,
        # where the `Pay::Customer` is *created* by that reader rather than found,
        # it returns nil with the row written. It also drops the association
        # reader's own `force_reload` argument, so `payment_processor(true)` is an
        # ArgumentError.
        #
        # So the order is load-bearing and both halves are needed: `pay`'s reader is
        # the only thing that *decides* which processor customer this subscriber has
        # and creates the first one, and the association is the only way to read back
        # what it decided. Reaching past the reader straight to the association would
        # find nothing at all on a first checkout, because nothing had created it.
        customer.payment_processor || customer.association(:payment_processor).tap(&:reload).reader
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
      def recorded(pay_subscription)
        applied = nil

        # **One transaction for the row and the event.** This is the rule
        # `Webhooks::Ingestion#emit` already holds — the outbox row and the change
        # it describes commit together or not at all — and a checkout that wrote the
        # subscription outside it would open the window that rule exists to close:
        # a database that says the subscription is `active` and an outbox with no
        # `billing.subscription.started` for it, which is an account paying for
        # something no downstream consumer was ever told about.
        #
        # `OutboxEvent.publish!` is called directly rather than through
        # `Webhooks::Ingestion`, because there is no delivery to ingest: there is no
        # `processor_webhooks` row and nothing to mark handled. It is the same
        # writer, which is the property that matters — there is exactly one outbox
        # and one envelope builder (`AGENTS.md`, Events).
        Subscription.transaction do
          applied = Subscriptions::Lifecycle.new(
            data: delivery(pay_subscription),
            event_time: pay_subscription.created_at
          ).call(Subscriptions::Lifecycle::CREATED)

          OutboxEvent.publish!(
            type: applied.event_type,
            subject: applied.subject,
            data: applied.data,
            time: pay_subscription.created_at
          )
        end

        Outcome.new(
          state: :completed,
          reason: nil,
          subscription: applied.subscription,
          pay_subscription: pay_subscription
        )
      rescue Subscriptions::Refused => refusal
        failed(SUBSCRIPTION_REFUSED, reason_detail: refusal.reason, pay_subscription: pay_subscription)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # **The index, not the machine.** `subscriptions_live_account_plan_idx` is a
        # partial unique index over `(account_id, plan_id)` while the subscription is
        # live, so a second checkout of the same plan for the same account is
        # refused by PostgreSQL and arrives here as `RecordNotUnique` — a
        # `Subscriptions::Refused` with a name, not an exception the domain chose to
        # raise. This is the same shape `AGENTS.md` (Webhooks in) records for the
        # outbox index: either a validation or an index may win the race, so the
        # caller is written against the **outcome** and not against a named
        # constraint.
        failed(SUBSCRIPTION_REFUSED, reason_detail: "already_subscribed", pay_subscription: pay_subscription)
      end

      def failed(reason, reason_detail: nil, pay_subscription: nil)
        Outcome.new(
          state: :failed,
          reason: reason_detail ? "#{reason}:#{reason_detail}" : reason,
          subscription: nil,
          pay_subscription: pay_subscription
        )
      end

      # The normalised delivery, in exactly the shape `Webhooks::StripeEvents`
      # produces — because `Lifecycle` is written against that shape and this
      # class is deliberately not a second normaliser.
      #
      # `cafaye_customer_id` is this service's own id for the customer, and it is
      # the field `Lifecycle#customer` prefers over the processor's id, because a
      # customer created through `/v1` has a null `processor_customer_id` until its
      # first subscription tells us what the processor calls it. Sending it means
      # the checkout path and the delivery path resolve the same row the same way.
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
      # guessed.** `FakeProcessor` does not compute a period, and deriving one from
      # `Plan#interval` here would be this service inventing a billing period the
      # processor never stated. A subscription whose period the processor has not
      # published has no period recorded, and `Lifecycle#parse_time` turns an
      # absent value into nil without inventing one.
      def delivery(pay_subscription)
        {
          "subscription_id" => pay_subscription.processor_id,
          "status" => status_for(pay_subscription),
          "cafaye_customer_id" => customer.id,
          "customer_id" => processor_customer.processor_id,
          "price_id" => plan.processor_price_id,
          "quantity" => quantity,
          "trial_ends_at" => pay_subscription.trial_ends_at&.utc&.iso8601,
          "cancel_at_period_end" => false,
          "canceled_at" => nil,
          "processor" => PROCESSOR
        }.compact
      end

      # What the processor says the subscription is, not what this service would
      # like it to be.
      #
      # A trial is `trialing` **only while it is running**: `Pay::Subscription#on_trial?`
      # is false once `trial_ends_at` is in the past, and a checkout that recorded
      # `trialing` for a trial that ended an hour ago would grant trial
      # entitlements to a customer who has been charged.
      def status_for(pay_subscription)
        pay_subscription.on_trial? ? "trialing" : "active"
      end
  end
end
