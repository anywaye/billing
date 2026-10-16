module Processor
  # The processor that is a fake — and the only reason this class exists.
  #
  # ## What this replaces, and why it is gone
  #
  # This class was `pay`'s `FakeProcessor`: a gem whose "API" was a set of Active
  # Record tables (`pay_customers`, `pay_subscriptions`, `pay_charges`,
  # `pay_payment_methods`, `pay_merchants`, `pay_webhooks`), which is what made a
  # checkout path testable end to end with no network, no keys and no Stripe
  # account. The gem is gone (`Gemfile` has no `pay` line; the tables are dropped
  # by `20261015120000_drop_pay_tables.rb`), for the reasons its own exit report
  # records: it brought six Active Record tables, STI `type` columns and a
  # bigint-owner-id landmine to a service whose processor surface is three
  # methods on `Processor::StripeClient`, and its "more processors" adapters were
  # never enabled (`enabled_processors = []` was the whole configuration).
  #
  # ## What this is
  #
  # A processor with the single call this service's checkout path makes, and no
  # persistence. `subscribe` answers with a value object and records it in a
  # PROCESS-LOCAL ledger so the specs can still assert the honest two-sided
  # state ("the processor has two, this service holds one") that the old
  # `pay_subscriptions` rows made visible. Nothing else learns about it: it
  # writes no table, opens no socket, and dies with the process.
  #
  # ## The seam
  #
  # The same shape `Processor::StripeClient` established: `Processor::Error` is
  # the base, a refusal is one class, and no method computes an amount. The
  # subscription this returns carries a processor's own id and a `processor_plan`
  # price id — the two fields `Checkout::Session#delivery` hands to
  # `Subscriptions::Lifecycle` — and nothing else. It is deliberately NOT a
  # `StripeClient` implementation: the fake answers from parameters, the real
  # client answers from Stripe, and a pretend Stripe would eventually be invoked
  # by a spec that believes it.
  class FakeClient
    # The name this processor answers to, and the value the checkout path puts
    # in a delivery's `processor` field. It was `Checkout::Session::PROCESSOR`
    # while the processor lived in the `pay` gem; it is here now because the
    # name and the client are one fact again.
    PROCESSOR = "fake_processor".freeze

    # A processor refused. One class for every refusal, whatever the call — the
    # same rule `Processor::StripeClient::RequestFailed` follows, so a caller
    # rescues `Processor::Error` and has caught a processor problem and not an
    # unrelated bug.
    class Error < ::Processor::Error; end

    # The prefix of every subscription id this processor mints, and the one
    # way a caller can tell whose a subscription is without a column for it.
    #
    # The symlink is real rather than clever: the fleet's test support already
    # spells this prefix out as "the marker" (`test/support/two_accounts.rb`:
    # "`FAKE` is in the prefix of every processor id"), and a caller that needs
    # to know which processor owns a row needs the same marker the specs have
    # been reading for a year. `owns?` is that question, asked once.
    #
    # There is no `processor` column on `subscriptions`: what the fake writes
    # is its own id, and a column would be a second place for the two to
    # disagree about which processor holds a row.
    SUBSCRIPTION_PREFIX = "sub_FAKE"

    # Whether the subscription under this processor's own id is one it minted.
    def self.owns?(processor_subscription_id)
      processor_subscription_id.to_s.start_with?(SUBSCRIPTION_PREFIX)
    end

    # What `subscribe` answers. A frozen value object rather than an Active
    # Record row: the old `Pay::Subscription` was a database row, and a row is
    # a second writer of state this service does not own.
    #
    # The name is the point and not decoration. It is `ProcessorSubscription`
    # and not `Subscription` for two reasons. It **is** the processor's
    # subscription — the fake's answer about what the processor said, which is
    # a different fact from billing's own `Subscription` row and travels beside
    # it in the `Outcome`. And a class named `Subscription` in this namespace
    # would shadow the model for every reader of this file, which is the exact
    # confusion this service's `Charge`-versus-processor's-charge distinction
    # exists to prevent. The fields are the ones `Checkout::Session#delivery`
    # reads and nothing else:
    #
    #   * `processor_id` — the processor's own id for this subscription, unique
    #     per subscribe, and the join key the delivery path uses.
    #   * `processor_plan` — the price the subscription was started on, echoed
    #     back unsullied: the checkout asked for a price id, not an amount.
    #   * `quantity` — seats, an integer, never multiplied into anything here.
    #   * `status` — `trialing` while a trial is running, `active` after.
    #   * `trial_ends_at` — when a trial ends, or nil when there is no trial.
    #   * `created_at` — the instant the processor said yes, taken once here
    #     rather than read twice, so the event's `time` and the payload's
    #     `trial_ends_at` cannot drift apart.
    #   * `price` and `interval` — the fake's price book for THIS subscription,
    #     passed by the checkout and read back only by `upcoming_invoice`. A
    #     subscription the fake started without them projects nothing.
    ProcessorSubscription = Data.define(
      :processor_id, :processor_plan, :quantity, :status, :trial_ends_at, :created_at,
      :price, :interval
    ) do
      # A trial is running **only while it is running**. A `trial_ends_at` in
      # the past means the trial is over, and a checkout that reported
      # `trialing` for one would grant trial entitlements to a customer who has
      # been charged. This is the same rule the old
      # `Pay::Subscription#on_trial?` held, stated rather than inherited.
      def on_trial?
        trial_ends_at.present? && trial_ends_at.future?
      end
    end

    # The projection's shape, and the reason each field is here is the same
    # reason `ProcessorSubscription` is a value and not a row: these are the
    # accessors `V1::SubscriptionsController#upcoming_invoice_response` reads,
    # and a processor — real or fake — answers through them or the controller
    # grows a branch. `tax` is deliberately absent: it is the one figure the
    # *caller* derives from `total - total_excluding_tax`, for display, and the
    # processor stating an invented zero would be this fake having an opinion.
    InvoicePreview = Data.define(
      :period_end, :currency, :lines, :subtotal, :total_excluding_tax, :total
    )

    PreviewLine = Data.define(
      :description, :period, :quantity, :pricing, :amount, :currency
    )

    # A period answers `.start` and `.end` because that is what a processor's own
    # line-item period answers, and the controller's builder reads it the same way
    # whichever processor is behind the call.
    PreviewPeriod = Data.define(:start, :end)

    # **The pricing shape is Stripe's 2025 shape, and that is deliberate.**
    # The controller's builder reads `line.pricing.unit_amount_decimal` — a
    # decimal string — because the real API stopped exposing a `price` object
    # on a line item, and a fake that answered the old shape would be a
    # second vocabulary for one field: the dev door and CI would exercise a
    # builder that cannot read what production sends.
    PreviewPricing = Data.define(:unit_amount_decimal)

    # The ledger, and it exists for one assertion.
    #
    # The old `pay_subscriptions` table made the two-sided state of a refused
    # second checkout visible: the processor held two subscriptions and this
    # service held one, which is the honest report `HANDOFF-w3-checkout.md`
    # recorded. A fake with no ledger makes "the processor was asked twice"
    # unassertable, and the assertion is the thing that stops this class from
    # quietly becoming a mock. The ledger is also where an upcoming-invoice
    # projection is read back from: the projection is a statement about a
    # subscription this processor holds, and a fake that answered from
    # anything else would be answering about a subscription it does not have.
    #
    # It is PROCESS-LOCAL on purpose. Parallel test workers are separate
    # processes (Rails forks them, and each forks after this class is loaded),
    # so a worker's ledger is its own. There is no table here and there must
    # never be one: a fake whose books outlive the process is a fake somebody
    # will debug.
    class << self
      def subscriptions
        @subscriptions ||= []
      end

      def record(subscription)
        subscriptions << subscription
      end

      def reset!
        @subscriptions = nil
      end
    end

    # Starts a subscription. The only call the checkout path makes.
    #
    # `price_id` is the plan's `processor_price_id` — the processor's own id for
    # a price — and never an amount: "the checkout sends no amount to anybody"
    # is a rule of this service (`AGENTS.md`, Money), and the fake honouring it
    # is the same rule holding on the dev side.
    #
    # `trial_period_days` is passed only when it is positive. Passing zero
    # would set `trial_ends_at` to the present moment, and a trial that is
    # already over is a subscription that reports `active` with a `trialing`
    # sticker on it. This is the same guard the old `FakeProcessor#subscribe`
    # needed, for the same reason its tests had: Ruby says `0` is truthy.
    #
    # `price` and `interval` are the fake's own price book, and they exist for
    # one call: `upcoming_invoice` projects what a renewal will charge, and a
    # processor with no price book has no projection to give. They are taken
    # from the plan the checkout bought and never used by `subscribe` itself.
    def subscribe(price_id:, quantity: 1, trial_period_days: nil, price: nil, interval: nil)
      price_id = price_id.to_s.strip
      raise Error, "the plan has no processor_price_id, so there is nothing to subscribe to" if price_id.empty?

      created_at = Time.current
      trial_days = trial_period_days.to_i
      trial_ends_at = trial_days.positive? ? created_at + trial_days.days : nil

      subscription = ProcessorSubscription.new(
        processor_id: "#{SUBSCRIPTION_PREFIX}#{SecureRandom.hex(12)}",
        processor_plan: price_id,
        quantity: Integer(quantity),
        status: (trial_ends_at.present? ? "trialing" : "active"),
        trial_ends_at: trial_ends_at,
        price: price,
        interval: interval,
        created_at: created_at
      )

      self.class.record(subscription)
      subscription
    end

    # The processor's own id for this subscriber, derived rather than stored.
    #
    # The delivery path resolves a customer by billing's own id first
    # (`cafaye_customer_id`, which is what a checkout path can always supply),
    # so this only needs to be deterministic and obviously fake — stable so a
    # second checkout of the same customer talks about the same processor
    # customer, `fake` so nobody mistakes one for a captured production value.
    #
    # The old `pay` reader created a `Pay::Customer` row for this. That row is
    # the landmine this class exists to leave behind: nothing here writes a
    # customer to a database, and there is no second lookup to disagree with
    # the one `customers.processor_customer_id` column already provides.
    def customer_id_for(customer)
      "cus_fake_#{customer.id}"
    end

    # The processor's projection of the next invoice: what a renewal will
    # charge, answered from this processor's own books.
    #
    # ## Why the projection has a shape of its own
    #
    # `upcoming_invoice_response` on the subscriptions controller reads the
    # accessors a real invoice carries — `period_end`, `currency`, `lines` with
    # their `price.unit_amount`, the two subtotals — and it must not know which
    # processor is behind the call. So this returns a value object with exactly
    # those accessors, and the controller's builder is one code path for both.
    #
    # ## Where the figures come from, and the one that is computed
    #
    # `unit_amount` is the plan's price, carried from checkout; `amount` is the
    # unit amount times the seats, because a projection of a per-seat plan that
    # showed the unit price alone would understate the bill. That multiplication
    # is the processor's arithmetic about the processor's own price — the same
    # direction as the `tax` display delta the controller computes from two of
    # Stripe's figures, and not the thing `AGENTS.md` (Money) forbids: no
    # figure is computed here to send to a processor, and none is persisted.
    #
    # The period is the interval the plan was bought on, and a plan on no
    # interval — a one-off — projects nothing: there is no renewal to charge
    # for, and inventing one would be this processor stating a period it never
    # stated.
    def upcoming_invoice(processor_subscription_id:, processor_customer_id:)
      subscription = self.class.subscriptions.find { |record| record.processor_id == processor_subscription_id }
      raise Error, "no subscription #{processor_subscription_id} has been started on this processor" if subscription.nil?
      raise Error, "that subscription was started with no price, so there is nothing to project" if subscription.price.nil?
      raise Error, "that plan has no interval, so it has no renewal to project" if subscription.interval.blank? || subscription.interval == "one_time"

      amount = subscription.price.minor_units * subscription.quantity

      InvoicePreview.new(
        period_end: Time.current + interval_length(subscription.interval),
        currency: subscription.price.currency,
        lines: [
          PreviewLine.new(
            description: "Fake processor subscription to #{subscription.processor_plan}",
            period: PreviewPeriod.new(
              start: Time.current,
              end: Time.current + interval_length(subscription.interval)
            ),
            quantity: subscription.quantity,
            pricing: PreviewPricing.new(unit_amount_decimal: subscription.price.minor_units.to_s),
            amount: amount,
            currency: subscription.price.currency
          )
        ],
        subtotal: amount,
        total_excluding_tax: amount,
        total: amount
      )
    end

    private
      def interval_length(interval)
        interval == "year" ? 1.year : 1.month
      end
  end
end
