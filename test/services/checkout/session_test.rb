require "test_helper"

class CheckoutSessionTest < ActiveSupport::TestCase
  setup do
    travel_to(frozen_now)

    @account = SecureRandom.uuid
    @customer = Customer.create!(owner_type: "Account", owner_id: @account, processor: "stripe")
    @plan = Plan.create!(
      name: "Pro monthly",
      slug: "pro-#{SecureRandom.hex(6)}",
      price: Billing::Money.new(1_900, "USD"),
      interval: "month",
      processor_price_id: "price_FAKE#{SecureRandom.hex(8)}"
    )
    @recorder = RecordingProcessor.new
    Processor::FakeClient.reset!
  end


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

  test "the recorded subscription is priced by the plan it was bought on" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    price = outcome.subscription.plan.price
    assert_equal Billing::Money.new(1_900, "USD"), price
    assert_equal 1_900, price.minor_units
    assert_equal "USD", price.currency
  end

  test "the recorded subscription is keyed by the processor's own subscription id" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert_equal outcome.processor_subscription.processor_id, outcome.subscription.processor_subscription_id
    assert_equal @plan.processor_price_id, outcome.processor_subscription.processor_plan
    assert_equal Processor::FakeClient::PROCESSOR, Checkout::Session::PROCESSOR
  end

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
    assert_nil payload["processor_event_id"]
  end


  test "a checkout buys the quantity it was asked for" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan, quantity: 7).complete

    assert outcome.completed?, "expected a completed checkout, got #{outcome.reason}"
    assert_equal 7, outcome.processor_subscription.quantity
    assert_equal 7, OutboxEvent.find_by(event_type: "billing.subscription.started").data["quantity"]
    assert_equal Billing::Money.new(1_900, "USD"), outcome.subscription.plan.price
  end

  test "a plan with a trial starts trialing and records when the trial ends" do
    plan = Plan.create!(
      name: "Pro trial", slug: "pro-trial-#{SecureRandom.hex(6)}",
      price: Billing::Money.new(1_900, "USD"), interval: "month",
      trial_days: 14, processor_price_id: "price_FAKE#{SecureRandom.hex(8)}"
    )

    outcome = Checkout::Session.new(customer: @customer, plan: plan).complete

    assert outcome.completed?, "expected a completed checkout, got #{outcome.reason}"
    assert_equal "trialing", outcome.subscription.status
    assert_equal frozen_now + 14.days, outcome.processor_subscription.trial_ends_at
    assert_equal "trialing", OutboxEvent.find_by(event_type: "billing.subscription.started").data["status"]
    assert_outbox_trial_ends_at 14.days.from_now
  end

  test "a plan with no trial starts active rather than trialing" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan, processor: @recorder).complete

    assert_equal 0, @plan.trial_days
    assert_equal "active", outcome.subscription.status
    assert_nil outcome.processor_subscription.trial_ends_at
    assert_not_includes @recorder.last, :trial_period_days
  end

  test "a plan with a trial asks the processor for that trial, by name" do
    plan = Plan.create!(
      name: "Pro trial", slug: "pro-trial-#{SecureRandom.hex(6)}",
      price: Billing::Money.new(1_900, "USD"), interval: "month",
      trial_days: 14, processor_price_id: "price_FAKE#{SecureRandom.hex(8)}"
    )

    Checkout::Session.new(customer: @customer, plan: plan, processor: @recorder).complete

    assert_equal plan.processor_price_id, @recorder.last[:price_id], "sanity: the recorder saw this checkout"
    assert_equal 14, @recorder.last[:trial_period_days]
  end


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

  test "a refused checkout leaves an existing subscription exactly as it was" do
    live = Subscription.create!(
      account_id: @account, customer: @customer, plan: @plan,
      processor_subscription_id: "sub_FAKEexisting0000000", status: "active"
    )
    before = [ live.status, live.plan_id, live.customer_id, live.processor_subscription_id, live.updated_at ]

    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert outcome.failed?
    assert_match(/\Asubscription_refused:/, outcome.reason)
    assert_equal "active", live.reload.status
    assert_equal before, [
      live.status, live.plan_id, live.customer_id, live.processor_subscription_id, live.updated_at
    ]
    assert_equal 1, Subscription.where(customer_id: @customer.id).count
  end

  test "a processor that raises is reported as a refusal and writes nothing" do
    outcome = Checkout::Session.new(customer: @customer, plan: @plan, processor: RaisingProcessor.new).complete

    assert outcome.failed?
    assert_equal Checkout::Session::PROCESSOR_REFUSED, outcome.reason
    assert_nil outcome.subscription
    assert_equal 0, Subscription.where(customer_id: @customer.id).count
    assert_empty Processor::FakeClient.subscriptions
  end

  test "a subscription the lifecycle refuses is a failure carrying the lifecycle's own reason" do
    plan = Plan.create!(
      name: "Other plan", slug: "other-#{SecureRandom.hex(6)}",
      price: Billing::Money.new(4_900, "USD"), interval: "month",
      processor_price_id: "price_FAKE#{SecureRandom.hex(8)}"
    )
    Subscription.create!(
      account_id: @account, customer: @customer, plan: plan,
      processor_subscription_id: "sub_FAKEexisting1111111", status: "canceled"
    )

    outcome = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert outcome.completed?, "a distinct plan for a canceled row should start, got #{outcome.reason}"
    assert_equal 2, Subscription.where(customer_id: @customer.id).count
  end

  test "a second checkout on the same live plan fails and names the constraint that refused it" do
    first = Checkout::Session.new(customer: @customer, plan: @plan).complete
    assert first.completed?, first.reason

    second = Checkout::Session.new(customer: @customer, plan: @plan).complete

    assert second.failed?
    assert_match(/\Asubscription_refused:/, second.reason)
    assert_equal 1, Subscription.where(customer_id: @customer.id).live.count
    assert_equal 2, Processor::FakeClient.subscriptions.count
  end


  test "the checkout path makes no network call" do
    outcome = with_no_network do
      Checkout::Session.new(customer: @customer, plan: @plan).complete
    end

    assert outcome.completed?, "a checkout that needed the network is not this packet's checkout: #{outcome.reason}"
  end

  test "every path out of complete is an Outcome, so a failure cannot be half-handled" do
    outcomes = [
      Checkout::Session.new(customer: @customer, plan: withdrawn(@plan)).complete,
      Checkout::Session.new(customer: user_owned, plan: @plan).complete,
      Checkout::Session.new(customer: @customer, plan: @plan).complete
    ]

    outcomes.each { |outcome| assert_kind_of Checkout::Session::Outcome, outcome }
    assert_equal [ false, false, true ], outcomes.map(&:completed?)
  end

  private
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

    class NeverAskedProcessor
      def subscribe(**)
        raise "the processor was asked, and this checkout must refuse before it is"
      end
    end

    class RaisingProcessor
      def subscribe(**)
        raise Processor::Error, "declined"
      end
    end

    def with_no_network
      refused = ->(*) { raise NetworkAccessAttempted, "checkout opened a socket" }
      simple_stubs.stub_object(Socket, :new) { refused.call }
      simple_stubs.stub_object(Net::HTTP, :new) { refused.call }
      simple_stubs.stub_object(Net::HTTP, :start) { refused.call }
      yield
    ensure
      simple_stubs.unstub_all!
    end

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

  class NetworkAccessAttempted < StandardError; end
end
