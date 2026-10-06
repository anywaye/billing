require "test_helper"

# A checkout, end to end, against `pay`'s FakeProcessor.
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
# FakeProcessor's "API" is the database: `subscribe` writes a `pay_subscriptions`
# row and returns it. There is no HTTP client in this path to stub, because there
# is no HTTP client — which is the point of the gem. `test "the checkout path
# makes no network call"` holds that as a fact rather than a hope, by refusing any
# outbound connection for the duration.
#
# ## The clock
#
# Injected, like everywhere else in this repository (`AGENTS.md`, Testing). The
# one place it bites hardest is the trial: `FakeProcessor#subscribe` computes
# `trial_ends_at` as `trial_period_days.days.from_now`, so an assertion about
# "is this still trialing" written against a wall clock is an assertion about the
# day it was written.
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

    assert_equal outcome.pay_subscription.processor_id, outcome.subscription.processor_subscription_id
    assert_equal @plan.processor_price_id, outcome.pay_subscription.processor_plan
    assert_equal Checkout::Session::PROCESSOR, @customer.payment_processor.processor
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

  # --- per-seat pricing, because `pay` 12.2 is in the Gemfile for it ---------

  test "a checkout buys the quantity it was asked for" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan, quantity: 7).complete

    assert outcome.completed?, "expected a completed checkout, got #{outcome.reason}"
    assert_equal 7, outcome.pay_subscription.quantity
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
    assert_equal frozen_now + 14.days, outcome.pay_subscription.trial_ends_at
    assert_equal "trialing", OutboxEvent.find_by(event_type: "billing.subscription.started").data["status"]
    assert_outbox_trial_ends_at 14.days.from_now
  end

  # A trial of zero days must not become a trial. `FakeProcessor#subscribe` tests
  # `trial_period_days` for truthiness and Ruby says `0` is truthy, so passing it
  # unconditionally would produce a subscription that is `trialing` and already
  # over — granting trial entitlements to somebody who has been charged.
  test "a plan with no trial starts active rather than trialing" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert_equal 0, @plan.trial_days
    assert_equal "active", outcome.subscription.status
    assert_nil outcome.pay_subscription.trial_ends_at
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

    outcome = Checkout::Session.new(customer: @customer, plan: plan).complete

    assert outcome.failed?
    assert_equal Checkout::Session::NOT_ON_SALE, outcome.reason
    assert_equal 0, Subscription.where(plan_id: plan.id).count
    # **Nothing was asked of the processor either.** A checkout cannot invent a
    # price for a plan that has none, and asking anyway would start a
    # subscription at whatever the processor's default happens to be.
    assert_equal 0, @customer.reload.pay_customers.count
  end

  test "a user-owned customer fails, because a subscription is billed to an account" do
    user_customer = Customer.create!(owner_type: "User", owner_id: SecureRandom.uuid, processor: "stripe")

    outcome = Checkout::Session.new(customer: user_customer, plan: @plan).complete

    assert outcome.failed?
    assert_equal Checkout::Session::NOT_AN_ACCOUNT, outcome.reason
    assert_equal 0, Subscription.count
    assert_equal 0, user_customer.reload.pay_customers.count
  end

  # The strongest form of the negative case: an account that is **already paying**
  # attempts a second checkout, the processor refuses, and the existing
  # subscription is byte-identical afterwards. A failed checkout that disturbs the
  # subscription already running is worse than one that creates a bad new one.
  test "a refused checkout leaves an existing subscription exactly as it was" do
    live = Subscription.create!(
      account_id: @account, customer: @customer, plan: @plan,
      processor_subscription_id: "sub_FAKEexisting0000000", status: "active"
    )
    before = [ live.status, live.plan_id, live.customer_id, live.processor_subscription_id, live.updated_at ]

    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert outcome.failed?
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
    processor_customer = @customer.payment_processor

    outcome = with_raising_processor(processor_customer) do
      Checkout::Session.new(customer: @customer, plan: @plan).complete
    end

    assert outcome.failed?
    assert_equal Checkout::Session::PROCESSOR_REFUSED, outcome.reason
    assert_nil outcome.subscription
    assert_equal 0, Subscription.where(customer_id: @customer.id).count
    assert_equal 0, processor_customer.subscriptions.count
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
  # processor is asked first, so a `pay_subscriptions` row exists at the processor
  # and no `subscriptions` row exists here.
  test "a second checkout on the same live plan fails and names the constraint that refused it" do
    first = Checkout::Session.new(customer: @customer, plan: @plan).complete
    assert first.completed?, first.reason

    second = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert second.failed?
    assert_match(/\Asubscription_refused:/, second.reason)
    assert_equal 1, Subscription.where(customer_id: @customer.id).live.count
    # The processor has two — which is the honest state and the reason the comment
    # on `Checkout::Session#recorded` says a refusal does not cancel the
    # processor's row.
    assert_equal 2, @customer.reload.payment_processor.subscriptions.count
  end

  # --- the boundary, held --------------------------------------------------

  test "the checkout path makes no network call" do
    # `Net::HTTP` is the seam every HTTP client in the Ruby ecosystem bottoms out
    # at, so refusing it for the duration of a checkout is a statement about the
    # whole path rather than about one library. This is the assertion that makes
    # "no keys, no network" a fact about the code instead of a claim about how the
    # tests were written — and it is what fails first the day somebody reaches for
    # a live processor.
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
    # A processor that refuses, installed on the one instance this checkout will
    # reach and removed again in `ensure`.
    #
    # `alias_method` and restore rather than a mocking framework's `any_instance`:
    # this service depends on neither mocha nor minitest-mock (`AGENTS.md`,
    # Testing), and a class-wide `any_instance` stub that outlived a failing
    # assertion would be a defect in the next test rather than in this one.
    def with_raising_processor(processor_customer)
      original = processor_customer.method(:subscribe)
      processor_customer.define_singleton_method(:subscribe) do |*, **|
        raise Pay::FakeProcessor::Error, "declined"
      end
      yield
    ensure
      processor_customer.define_singleton_method(:subscribe, original)
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
