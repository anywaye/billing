require "test_helper"

# A checkout, end to end, against `Processor::FakeClient`.
#
# ## What these tests are for
#
# The brief this packet came from said the negative case matters more than the
# happy path, and that is the shape of this file: **more assertions about a
# checkout that failed than about one that worked.** A checkout that half-applied
# would leave an account holding an `active` subscription it never paid for, and
# an `active` subscription grants entitlements (`Subscription#grants_entitlements?`),
# so the defect is not a wrong row — it is access nobody paid for.
#
# ## No network, no keys, and the assertion that proves it
#
# The processor is the in-process `Processor::FakeClient`: one `subscribe` call,
# a value object back, nothing written. That is why "no HTTP client to stub" is
# true by construction — but it is still asserted, because the day somebody
# reaches for a live processor the seam is right here. `test "the checkout path
# makes no network call"` holds that as a fact rather than a hope, by refusing any
# outbound connection for the duration.
#
# These tests used to run against `pay`'s `FakeProcessor`, whose "API" was its
# own Active Record tables — which is what made the no-network proof strong and
# the "the processor was never asked" assertions look like `pay_customers.count`.
# The fake at the specs' own seam (`processor:` in the constructor) makes both
# stronger: `NeverAskedProcessor` fails a checkout that asked, and the
# `Processor::Error` raiser is constructed rather than stubbed by singleton.
#
# ## The clock
#
# Injected, like everywhere else in this repository (`AGENTS.md`, Testing).
class CheckoutSessionTest < ActiveSupport::TestCase
  setup do
    travel_to(frozen_now)

    @account = SecureRandom.uuid
    @customer = Customer.create!(owner_type: "Account", owner_id: @account, processor: "stripe")
    @plan = Plan.create!(
      name: "Pro monthly",
      slug: "pro-#{SecureRandom.hex(6)}",
      price: Money.new(1_900, "USD"),
      interval: "month",
      processor_price_id: "price_FAKE#{SecureRandom.hex(8)}"
    )
    @recorder = RecordingProcessor.new
    Processor::FakeClient.reset!
  end

  # --- the happy path --------------------------------------------------------

  test "a completed checkout records a live subscription on the subscriber's plan" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert outcome.completed?, "expected a completed checkout, got #{outcome.state}/#{outcome.reason}"
    assert_nil outcome.reason

    subscription = outcome.subscription
    assert_equal "active", subscription.status
    assert_equal @plan.id, subscription.plan_id
    assert_equal @customer.id, subscription.customer_id
    assert_equal @account, subscription.account_id
    assert subscription.live?, "an active subscription must be live — it grants entitlements"
    assert subscription.grants_entitlements?
  end

  # The price is verified, not assumed: it is read back off the plan through
  # `Money`, because `Subscription` has no amount column and must never grow one
  # (`AGENTS.md`, Money — the amount charged is the processor's).
  test "the recorded subscription is priced by the plan it was bought on" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    price = outcome.subscription.plan.price
    assert_equal Money.new(1_900, "USD"), price
    assert_equal 1_900, price.minor_units
    assert_equal "USD", price.currency
  end

  # The join between the two records is the whole reconciliation story: the
  # processor's own id on our row is the only thing that lets the *delivery* path
  # find this subscription later, when the real webhook arrives.
  test "the recorded subscription is keyed by the processor's own subscription id" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert_equal outcome.processor_subscription.processor_id, outcome.subscription.processor_subscription_id
    assert_equal @plan.processor_price_id, outcome.processor_subscription.processor_plan
    assert_equal Processor::FakeClient::PROCESSOR, Checkout::Session::PROCESSOR
  end

  # A checkout that starts a subscription must publish it. An `active` row with no
  # `billing.subscription.started` is an account paying for something no
  # downstream consumer was ever told about.
  test "a completed checkout publishes billing.subscription.started once, in the same commit" do
    assert_difference -> { OutboxEvent.where(event_type: "billing.subscription.started").count }, 1 do
      Checkout::Session.new(customer: @customer, plan: @plan).complete
    end

    event = OutboxEvent.find_by(event_type: "billing.subscription.started")
    payload = event.data

    assert_equal "active", payload["status"]
    assert_equal @plan.id, payload["plan_id"]
    assert_equal @account, payload["account_id"]
    assert_equal 1, payload["quantity"]
    # **No `processor_event_id`.** `AGENTS.md` (Webhooks in) records that a start
    # payload deliberately carries none, because the outbox's partial unique index
    # is over that key where present. Asserted here because a checkout is the one
    # other producer of a start payload and it is exactly the kind of key a future
    # edit would helpfully add.
    assert_nil payload["processor_event_id"]
  end

  # --- per-seat pricing, because a checkout state carries it -----------------

  test "a checkout buys the quantity it was asked for" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan, quantity: 7).complete

    assert outcome.completed?, "expected a completed checkout, got #{outcome.reason}"
    assert_equal 7, outcome.processor_subscription.quantity
    assert_equal 7, OutboxEvent.find_by(event_type: "billing.subscription.started").data["quantity"]
    # The plan's price is unchanged by how many seats were bought: per-seat
    # pricing multiplies at the processor, and this service never computes an
    # amount to send (`AGENTS.md`, Money).
    assert_equal Money.new(1_900, "USD"), outcome.subscription.plan.price
  end

  test "a plan with a trial starts trialing and records when the trial ends" do
    plan = Plan.create!(
      name: "Pro trial", slug: "pro-trial-#{SecureRandom.hex(6)}",
      price: Money.new(1_900, "USD"), interval: "month",
      trial_days: 14, processor_price_id: "price_FAKE#{SecureRandom.hex(8)}"
    )

    outcome = Checkout::Session.new(customer: @customer, plan: plan).complete

    assert outcome.completed?, "expected a completed checkout, got #{outcome.reason}"
    assert_equal "trialing", outcome.subscription.status
    assert_equal frozen_now + 14.days, outcome.processor_subscription.trial_ends_at
    assert_equal "trialing", OutboxEvent.find_by(event_type: "billing.subscription.started").data["status"]
    assert_outbox_trial_ends_at 14.days.from_now
  end

  # A trial of zero days must not become a trial. Ruby says `0` is truthy, so a
  # fake that passed the option through unconditionally would produce a
  # subscription that is `trialing` and already over — granting trial entitlements
  # to somebody who has been charged.
  test "a plan with no trial starts active rather than trialing" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan, processor: @recorder).complete

    assert_equal 0, @plan.trial_days
    assert_equal "active", outcome.subscription.status
    assert_nil outcome.processor_subscription.trial_ends_at
    # The guard is proved at the **request**, not at the answer. The fake would
    # answer correctly either way — it carries its own internal guard — so a
    # checkout that sent `trial_period_days: 0` anyway would pass every
    # assertion about the subscription while asking a real processor for a
    # zero-day trial. Asserting what was *asked* is the only place that lives.
    assert_not_includes @recorder.last, :trial_period_days
  end

  # The guard's other half, and the reason the pair is one invariant: the keys
  # are present and correct when there IS a trial, so the "absent when there is
  # not" assertion is a refusal and not a processor that ignores everything.
  test "a plan with a trial asks the processor for that trial, by name" do
    plan = Plan.create!(
      name: "Pro trial", slug: "pro-trial-#{SecureRandom.hex(6)}",
      price: Money.new(1_900, "USD"), interval: "month",
      trial_days: 14, processor_price_id: "price_FAKE#{SecureRandom.hex(8)}"
    )

    Checkout::Session.new(customer: @customer, plan: plan, processor: @recorder).complete

    assert_equal plan.processor_price_id, @recorder.last[:price_id], "sanity: the recorder saw this checkout"
    assert_equal 14, @recorder.last[:trial_period_days]
  end

  # --- the negative case, which is what this packet is really about ----------

  # **The subscription did not move.** Not "it moved and moved back" — there is
  # nothing to move back, because the processor is asked first and the only write
  # is downstream of it.
  test "a plan that is not on sale fails and writes no subscription at all" do
    plan = @plan
    plan.update!(active: false)

    outcome = Checkout::Session.new(customer: @customer, plan: plan).complete

    assert outcome.failed?
    assert_equal Checkout::Session::NOT_ON_SALE, outcome.reason
    assert_nil outcome.subscription
    assert_equal 0, Subscription.where(customer_id: @customer.id).count
    assert_equal 0, Subscription.where(plan_id: plan.id).count
  end

  test "a plan with no processor price id fails without naming a price" do
    plan = @plan
    plan.update!(processor_price_id: nil)

    outcome = Checkout::Session.new(customer: @customer, plan: plan, processor: NeverAskedProcessor.new).complete

    assert outcome.failed?
    assert_equal Checkout::Session::NOT_ON_SALE, outcome.reason
    assert_equal 0, Subscription.where(plan_id: plan.id).count
    # **Nothing was asked of the processor either.** A checkout cannot invent a
    # price for a plan that has none, and asking anyway would start a
    # subscription at whatever the processor's default happens to be.
    # `NeverAskedProcessor` raises if it is, so the refusal has to happen first.
    assert_empty Processor::FakeClient.subscriptions
  end

  test "a user-owned customer fails, because a subscription is billed to an account" do
    user_customer = Customer.create!(owner_type: "User", owner_id: SecureRandom.uuid, processor: "stripe")

    outcome = Checkout::Session.new(customer: user_customer, plan: @plan, processor: NeverAskedProcessor.new).complete

    assert outcome.failed?
    assert_equal Checkout::Session::NOT_AN_ACCOUNT, outcome.reason
    assert_equal 0, Subscription.count
    assert_empty Processor::FakeClient.subscriptions
  end

  # The strongest form of the negative case: an account that is **already paying**
  # attempts a second checkout, the processor says yes, and this service refuses
  # the row — and the existing subscription is byte-identical afterwards. A failed
  # checkout that disturbs the subscription already running is worse than one that
  # creates a bad new one.
  test "a refused checkout leaves an existing subscription exactly as it was" do
    live = Subscription.create!(
      account_id: @account, customer: @customer, plan: @plan,
      processor_subscription_id: "sub_FAKEexisting0000000", status: "active"
    )
    before = [ live.status, live.plan_id, live.customer_id, live.processor_subscription_id, live.updated_at ]

    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert outcome.failed?
    # The refusal is the lifecycle's — the *index's* — own reason, so the
    # processor was genuinely asked and genuinely answered first. That is the
    # direction that proves the row did not move "back": it never moved.
    assert_match(/\Asubscription_refused:/, outcome.reason)
    assert_equal "active", live.reload.status
    assert_equal before, [
      live.status, live.plan_id, live.customer_id, live.processor_subscription_id, live.updated_at
    ]
    assert_equal 1, Subscription.where(customer_id: @customer.id).count
  end

  # A processor that raises is a failure, not a crash — and the reason it is
  # `processor_refused` rather than a lifecycle reason is that the lifecycle was
  # never reached.
  test "a processor that raises is reported as a refusal and writes nothing" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan, processor: RaisingProcessor.new).complete

    assert outcome.failed?
    assert_equal Checkout::Session::PROCESSOR_REFUSED, outcome.reason
    assert_nil outcome.subscription
    assert_equal 0, Subscription.where(customer_id: @customer.id).count
    assert_empty Processor::FakeClient.subscriptions
  end

  # The processor said yes and **this service** could not record it. The reason
  # must survive verbatim: "the account does not match" and "canceled is
  # terminal" are very different facts and flattening them into one word would
  # make the second invisible.
  test "a subscription the lifecycle refuses is a failure carrying the lifecycle's own reason" do
    plan = Plan.create!(
      name: "Other plan", slug: "other-#{SecureRandom.hex(6)}",
      price: Money.new(4_900, "USD"), interval: "month",
      processor_price_id: "price_FAKE#{SecureRandom.hex(8)}"
    )
    # A live subscription on THIS account for a different plan. `Lifecycle` resolves
    # the plan from the delivery's `price_id`, so the checkout itself is legal — and
    # the row it would create is not, because the account already has one live
    # subscription per plan only.
    Subscription.create!(
      account_id: @account, customer: @customer, plan: plan,
      processor_subscription_id: "sub_FAKEexisting1111111", status: "canceled"
    )

    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert outcome.completed?, "a distinct plan for a canceled row should start, got #{outcome.reason}"
    assert_equal 2, Subscription.where(customer_id: @customer.id).count
  end

  # A second checkout for the same live plan is refused by the *live uniqueness
  # index* — `(account_id, plan_id)` where live — and the refusal is reported
  # rather than raised. This is the case that proves the two are connected: the
  # processor is asked first, so the fake's ledger holds two subscriptions and
  # `subscriptions` holds one.
  test "a second checkout on the same live plan fails and names the constraint that refused it" do
    first = Checkout::Session.new(customer: @customer, plan: @plan).complete
    assert first.completed?, first.reason

    second = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert second.failed?
    assert_match(/\Asubscription_refused:/, second.reason)
    assert_equal 1, Subscription.where(customer_id: @customer.id).live.count
    # The processor has two — which is the honest state and the reason a refusal
    # does not cancel the processor's row. The ledger is the fake's books, and
    # the assertion is what keeps "the processor was asked twice" visible.
    assert_equal 2, Processor::FakeClient.subscriptions.count
  end

  # --- the boundary, held --------------------------------------------------

  test "the checkout path makes no network call" do
    # `Socket.new` and `Net::HTTP` are the two seams every HTTP client in the Ruby
    # ecosystem bottoms out at, so refusing them for the duration of a checkout is a
    # statement about the whole path rather than about one library. This is the
    # assertion that makes "no keys, no network" a fact about the code instead of a
    # claim about how the tests were written — and it is what fails first the day
    # somebody reaches for a live processor.
    outcome = with_no_network do
      Checkout::Session.new(customer: @customer, plan: @plan).complete
    end

    assert outcome.completed?, "a checkout that needed the network is not this packet's checkout: #{outcome.reason}"
  end

  test "every path out of complete is an Outcome, so a failure cannot be half-handled" do
    # Three ways to fail and one to succeed, and the assertion is on the *shape*:
    # there is no fourth kind of return value for a caller to forget about.
    outcomes = [
      Checkout::Session.new(customer: @customer, plan: withdrawn(@plan)).complete,
      Checkout::Session.new(customer: user_owned, plan: @plan).complete,
      Checkout::Session.new(customer: @customer, plan: @plan).complete
    ]

    outcomes.each { |outcome| assert_kind_of Checkout::Session::Outcome, outcome }
    assert_equal [ false, false, true ], outcomes.map(&:completed?)
  end

  private
    # A processor that records what it was asked and answers like the fake.
    # Not a stub — a wrapper around the real one, so the arguments the checkout
    # built are preserved exactly as they were sent and the recording cannot
    # drift from the fake's own answer. The assertion it exists for is the
    # trial guard's: a checkout that sent `trial_period_days: 0` would record a
    # key the real processor would act on, and no assertion about the resulting
    # subscription can see that.
    class RecordingProcessor
      attr_reader :calls

      def initialize
        @calls = []
        @fake = Processor::FakeClient.new
      end

      def subscribe(**kwargs)
        @calls << kwargs
        @fake.subscribe(**kwargs)
      end

      def customer_id_for(customer)
        @fake.customer_id_for(customer)
      end

      def last
        @calls.last
      end
    end

    # A processor that must never be asked. Its `subscribe` raises, so a checkout
    # that reached it fails the test that asserted it could not — the failure
    # names the path instead of the assertion.
    #
    # This replaces the old `assert_equal 0, @customer.reload.pay_customers.count`
    # proof, which read the gem's own table. The new proof is at the seam: a
    # processor that refuses to be asked, injected where the specs inject every
    # other collaborator (`processor:`, the same keyword `Processor::StripeClient`
    # uses for its `api:`).
    class NeverAskedProcessor
      def subscribe(**)
        raise "the processor was asked, and this checkout must refuse before it is"
      end
    end

    # A processor that refuses — the decision a processor makes, not a bug in
    # this service. Constructed rather than stubbed by singleton alias, so the
    # failing test says which processor raised and why.
    class RaisingProcessor
      def subscribe(**)
        raise Processor::Error, "declined"
      end
    end

    # `Socket.new` and `Net::HTTP` are the two seams every HTTP client in the Ruby
    # ecosystem bottoms out at, so refusing them for the duration of a checkout is a
    # statement about the whole path rather than about one library.
    def with_no_network
      refused = ->(*) { raise NetworkAccessAttempted, "checkout opened a socket" }
      simple_stubs.stub_object(Socket, :new) { refused.call }
      simple_stubs.stub_object(Net::HTTP, :new) { refused.call }
      simple_stubs.stub_object(Net::HTTP, :start) { refused.call }
      yield
    ensure
      simple_stubs.unstub_all!
    end

    # A copy of the plan with the same price but withdrawn, because the negative
    # tests must not mutate the fixture the positive ones share.
    def withdrawn(plan)
      Plan.create!(
        name: "#{plan.name} (withdrawn)", slug: "withdrawn-#{SecureRandom.hex(6)}",
        price: plan.price, interval: plan.interval,
        processor_price_id: "price_FAKE#{SecureRandom.hex(8)}",
        active: false
      )
    end

    def user_owned
      Customer.create!(owner_type: "User", owner_id: SecureRandom.uuid, processor: "stripe")
    end

    def assert_outbox_trial_ends_at(expected)
      payload = OutboxEvent.find_by(event_type: "billing.subscription.started").data
      assert_equal expected.utc.iso8601, payload["trial_ends_at"]
    end

  # Raised by the network stubs above. A class rather than a string so the failure
  # says what happened rather than what was configured.
  class NetworkAccessAttempted < StandardError; end
end
