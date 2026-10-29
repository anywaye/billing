require "test_helper"

class Subscriptions::LifecycleTest < ActiveSupport::TestCase
  OTHER_ACCOUNT = "22222222-2222-4222-8222-222222222222".freeze

  setup do
    travel_to(frozen_now)
    @customer = create_customer
    @plan = create_plan(price: 1900, price_id: "price_1PZQaBcDeFgHiJkLmNoPqR2")
  end

  SUBSCRIPTION_EVENTS = %w[
    billing.subscription.started
    billing.subscription.updated
    billing.subscription.canceled
  ].freeze

  def events
    OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS)
  end

  def event_types
    events.order(:created_at, :id).pluck(:event_type)
  end


  test "a subscription starting creates one row" do
    apply("customer.subscription.created")

    assert_equal 1, Subscription.count
  end

  test "a subscription starting is attributed to the processor's customer and plan" do
    apply("customer.subscription.created")

    subscription = Subscription.sole
    assert_equal @customer, subscription.customer
    assert_equal @plan, subscription.plan
  end

  test "a subscription starting carries the account being billed" do
    apply("customer.subscription.created")

    assert_equal @customer.owner_id, Subscription.sole.account_id
  end

  test "a subscription starting is recorded under the processor's own id" do
    apply("customer.subscription.created")

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", Subscription.sole.processor_subscription_id
  end

  test "a subscription starting records the processor's id for a customer that had none" do
    body = JSON.parse(stripe_fixture("customer.subscription.created"))
    body.dig("data", "object")["metadata"] = { "anywaye_customer_id" => @customer.id }
    @customer.update!(processor_customer_id: nil)

    Webhooks::Ingestion.new(processor: :stripe, event_id: body["id"], type: body["type"], payload: body).call

    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", @customer.reload.processor_customer_id
  end

  test "a subscription starting takes the status the processor reported" do
    apply("customer.subscription.created")

    assert_equal "active", Subscription.sole.status
  end

  test "a subscription starting takes the period the processor reported" do
    apply("customer.subscription.created")

    subscription = Subscription.sole
    assert_equal Time.utc(2026, 9, 30, 4, 0, 0), subscription.current_period_start
    assert_equal Time.utc(2026, 10, 30, 4, 0, 0), subscription.current_period_end
  end

  test "a subscription starting is not already canceled" do
    apply("customer.subscription.created")

    assert_nil Subscription.sole.canceled_at
  end

  test "a trialing subscription is stored as trialing" do
    apply("customer.subscription.created", status: "trialing")

    assert_equal "trialing", Subscription.sole.status
  end

  test "a subscription that cannot be resolved to a local customer is recorded and refused" do
    @customer.update!(processor_customer_id: "cus_someone_else")

    record = apply("customer.subscription.created")

    assert_equal 0, Subscription.count
    assert_equal "ignored:unknown_customer", record.error
  end

  test "a subscription that cannot be resolved to a local plan is recorded and refused" do
    @plan.update!(processor_price_id: "price_gone")

    record = apply("customer.subscription.created")

    assert_equal 0, Subscription.count
    assert_equal "ignored:unknown_plan", record.error
  end

  test "a delivery naming a customer on another account is recorded and refused" do
    setup_subscription(status: "active")
    other = create_customer(account_id: OTHER_ACCOUNT)

    record = apply("customer.subscription.updated", customer: other)

    assert_equal "ignored:account_mismatch", record.error
  end

  test "a delivery naming a customer on another account changes no column" do
    setup_subscription(status: "active")
    before = Subscription.sole.attributes
    other = create_customer(account_id: OTHER_ACCOUNT)

    apply("customer.subscription.updated", customer: other)

    assert_equal before, Subscription.sole.reload.attributes
  end

  test "a delivery naming a customer on another account publishes nothing" do
    setup_subscription(status: "active")
    before = events.pluck(:event_type)
    other = create_customer(account_id: OTHER_ACCOUNT)

    apply("customer.subscription.updated", customer: other)

    assert_equal before, events.pluck(:event_type)
  end

  test "a first delivery is not an account mismatch, because there is no account yet to disagree with" do
    other = create_customer(account_id: OTHER_ACCOUNT)

    record = apply("customer.subscription.created", customer: other)

    assert_nil record.error
    assert_equal OTHER_ACCOUNT, Subscription.sole.account_id,
      "a subscription created for a customer is billed to that customer's own account"
  end

  test "a delivery naming the account the row is already on is applied, not refused" do
    setup_subscription(status: "active")

    record = apply("customer.subscription.updated", status: "past_due", customer: @customer)

    assert_nil record.error
    assert_equal "past_due", Subscription.sole.status,
      "the same account arriving again must not be mistaken for a cross-account delivery"
  end

  test "a status this service does not model is recorded and refused" do
    record = apply("customer.subscription.created", status: "incomplete")

    assert_equal 0, Subscription.count
    assert_equal "failed:ArgumentError: unknown target status \"incomplete\"", record.error
  end


  test "a start emits billing.subscription.started" do
    apply("customer.subscription.created")

    assert_equal "billing.subscription.started", events.sole.event_type
  end

  test "a start is correlated on this service's own subscription, not the processor's id" do
    apply("customer.subscription.created")

    assert_equal Subscription.sole.id, events.sole.subject
  end

  test "a start's payload names the subscription the envelope is about" do
    apply("customer.subscription.created")

    assert_equal events.sole.subject, events.sole.data.fetch("subscription_id")
  end

  test "a start's payload names the plan and the account, as core's schema requires" do
    apply("customer.subscription.created")

    data = events.sole.data
    assert_equal @plan.id, data.fetch("plan_id")
    assert_equal @customer.owner_id, data.fetch("account_id")
  end

  test "a start's payload says the status is one core's schema allows for a start" do
    apply("customer.subscription.created")

    assert_includes %w[active trialing], events.sole.data.fetch("status")
  end

  test "a start's payload carries the quantity the processor reported" do
    apply("customer.subscription.created")

    assert_equal 2, events.sole.data.fetch("quantity")
  end

  test "a start's payload carries the currency the plan is priced in" do
    apply("customer.subscription.created")

    assert_equal "USD", events.sole.data.fetch("currency")
  end

  test "a start's payload carries the customer's billing email" do
    apply("customer.subscription.created")

    assert_equal "billing@example.com", events.sole.data.fetch("email")
  end

  test "a start's payload carries the plan's name beside its id" do
    apply("customer.subscription.created")

    assert_equal @plan.name, events.sole.data.fetch("plan_name")
  end

  test "a subscription event for a customer with no address carries no email" do
    @customer.update!(email: nil)
    apply("customer.subscription.created")

    refute_includes events.sole.data.keys, "email"
  end

  test "a start's payload carries exactly the fields the builder writes" do
    apply("customer.subscription.created")

    assert_equal(
      %w[account_id currency email plan_id plan_name quantity started_at status subscription_id].sort,
      events.sole.data.keys.sort
    )
  end

  test "a start's payload carries no processor provenance" do
    apply("customer.subscription.created")

    refute_includes events.sole.data.keys, "processor"
    refute_includes events.sole.data.keys, "processor_event_id"
  end

  test "a start's payload carries the time the subscription started, which is the envelope's own time" do
    apply("customer.subscription.created")

    event = events.sole
    assert_equal Time.utc(2026, 9, 30, 4, 0, 0).iso8601, event.data.fetch("started_at")
    assert_equal event.time.utc.iso8601, event.data.fetch("started_at")
  end

  test "a start's payload carries no trial end, because the subscription is not on one" do
    apply("customer.subscription.created", status: "active")

    refute_includes events.sole.data.keys, "trial_ends_at"
  end

  test "a trialing start's payload carries the trial end as a date-time or null" do
    apply("customer.subscription.created", status: "trialing", trial_end: 1793332800)

    value = events.sole.data.fetch("trial_ends_at")
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, value)
  end

  test "a trialing start with no trial end says so, rather than omitting the field" do
    apply("customer.subscription.created", status: "trialing", trial_end: nil)

    assert_nil events.sole.data.fetch("trial_ends_at")
  end


  test "the same delivery twice leaves one row and one event" do
    apply("customer.subscription.created")
    apply("customer.subscription.created")

    assert_equal 1, Subscription.count
    assert_equal 1, events.count
  end

  test "the same delivery twice leaves the row exactly as it was" do
    apply("customer.subscription.created")
    before = Subscription.sole.attributes
    apply("customer.subscription.created")

    assert_equal before, Subscription.sole.attributes
  end

  test "the same delivery twice leaves the event exactly as it was" do
    apply("customer.subscription.created")
    before = events.sole.attributes
    apply("customer.subscription.created")

    assert_equal before, events.sole.attributes
  end

  test "a second event reporting the state we already hold changes nothing" do
    apply("customer.subscription.created")
    before = Subscription.sole.attributes

    record = apply("customer.subscription.updated", event_id: "evt_a_second_time", quantity: 2, cancel_at_period_end: false)

    assert_equal before, Subscription.sole.attributes
    assert_equal "ignored:no_change_to_record", record.error
    assert_equal 1, events.count
  end

  test "a no-op update is recorded as processed, not left unfinished" do
    apply("customer.subscription.created")

    record = apply("customer.subscription.updated", event_id: "evt_a_second_time", quantity: 2, cancel_at_period_end: false)

    assert_predicate record, :handled?
  end


  test "an update changes the row it names" do
    apply("customer.subscription.created")
    apply("customer.subscription.updated", quantity: 3)

    assert_equal true, Subscription.sole.cancel_at_period_end
  end

  test "an update's payload carries the period it covers" do
    apply("customer.subscription.created")
    apply("customer.subscription.updated", quantity: 3)

    assert_equal "2026-10-30T04:00:00Z", events.order(:created_at, :id).last.data.fetch("current_period_end")
  end

  test "an update's payload carries the processor's own event id" do
    apply("customer.subscription.created")
    apply("customer.subscription.updated", quantity: 3)

    assert_equal "evt_1PZQaBcDeFgHiJkLmNoPqR2", events.order(:created_at, :id).last.data.fetch("processor_event_id")
  end

  test "an emitted update names the id its delivery was ingested under" do
    apply("customer.subscription.created", event_id: "evt_provenance_start")
    apply("customer.subscription.updated", event_id: "evt_provenance_update", quantity: 3)

    assert_equal "evt_provenance_update",
      ActiveRecord::Base.uncached { events.order(:created_at, :id).last.data.fetch("processor_event_id") }
  end

  test "an update's payload says which plan the subscription is now on" do
    apply("customer.subscription.created")
    team = create_plan(price: 4900, price_id: "price_1PZQaBcDeFgHiJkLmNoPqR4")

    apply("customer.subscription.updated", quantity: 3, price_id: team.processor_price_id)

    assert_equal team.id, events.order(:created_at, :id).last.data.fetch("plan_id")
  end

  test "an update's payload carries the customer's email and the plan's name" do
    apply("customer.subscription.created")
    team = create_plan(price: 4900, price_id: "price_1PZQaBcDeFgHiJkLmNoPqR4")

    apply("customer.subscription.updated", quantity: 3, price_id: team.processor_price_id)

    data = events.order(:created_at, :id).last.data
    assert_equal "billing@example.com", data.fetch("email")
    assert_equal team.name, data.fetch("plan_name")
  end

  test "an update emits billing.subscription.updated" do
    apply("customer.subscription.created")
    apply("customer.subscription.updated", quantity: 3)

    assert_equal [ "billing.subscription.started", "billing.subscription.updated" ], event_types
  end

  test "an update is correlated on the same subscription as the start" do
    apply("customer.subscription.created")
    apply("customer.subscription.updated", quantity: 3)

    assert_equal [ Subscription.sole.id ], events.pluck(:subject).uniq
  end

  test "an update moves the subscription onto the plan the processor named" do
    apply("customer.subscription.created")
    team = create_plan(price: 4900, price_id: "price_1PZQaBcDeFgHiJkLmNoPqR4")

    apply("customer.subscription.updated", quantity: 3, price_id: team.processor_price_id)

    assert_equal team, Subscription.sole.plan
  end

  test "an update whose plan this service does not have is recorded and refused, and changes nothing" do
    apply("customer.subscription.created")
    before = Subscription.sole.attributes

    record = apply("customer.subscription.updated", quantity: 3, price_id: "price_gone")

    assert_equal before, Subscription.sole.attributes
    assert_equal "ignored:unknown_plan", record.error
  end

  test "an update for a subscription this service has never seen is recorded and refused" do
    record = apply("customer.subscription.updated")

    assert_equal 0, Subscription.count
    assert_equal "ignored:no_subscription_to_update", record.error
  end

  RECOVERY_CASES = {
    "past_due recovers to active" => { from: "past_due", to: "active" },
    "unpaid recovers to active" => { from: "unpaid", to: "active" },
    "active falls into arrears" => { from: "active", to: "past_due" },
    "active falls behind entirely" => { from: "active", to: "unpaid" },
    "a trial converts to active" => { from: "trialing", to: "active" }
  }.freeze

  RECOVERY_CASES.each do |name, transition|
    test "#{name}" do
      apply("customer.subscription.created", status: transition[:from])
      apply("customer.subscription.updated", event_id: "evt_#{transition[:to]}", status: transition[:to], quantity: 2)

      assert_equal transition[:to], Subscription.sole.status
    end
  end


  test "a cancellation ends the subscription" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")

    assert_equal "canceled", Subscription.sole.status
  end

  test "a cancellation records when it took effect" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")

    assert_equal Time.utc(2026, 11, 14, 4, 0, 0), Subscription.sole.canceled_at
  end

  test "a cancellation emits billing.subscription.canceled" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")

    assert_equal [ "billing.subscription.started", "billing.subscription.canceled" ], event_types
  end

  test "a canceled payload carries the customer's email and the plan's name" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")

    data = events.order(:created_at, :id).last.data
    assert_equal "billing@example.com", data.fetch("email")
    assert_equal @plan.name, data.fetch("plan_name")
  end

  test "cancelling at period end is an update, not a cancellation" do
    apply("customer.subscription.created")
    apply("customer.subscription.updated", cancel_at_period_end: true)

    assert_equal "active", Subscription.sole.status
    assert_equal [ "billing.subscription.started", "billing.subscription.updated" ], event_types
  end

  test "a subscription cancelled at period end stops granting entitlements when it ends" do
    apply("customer.subscription.created")
    apply("customer.subscription.updated", cancel_at_period_end: true)

    assert_predicate Subscription.sole, :grants_entitlements?

    apply("customer.subscription.deleted", event_id: "evt_the_period_ended")

    refute_predicate Subscription.sole, :grants_entitlements?
  end

  test "every live status may be canceled" do
    Subscription::LIVE_STATUSES.each do |status|
      setup_subscription(status: status, processor_id: "sub_from_#{status}", plan: create_plan(price: 1900, price_id: "price_#{status}"))
      apply("customer.subscription.deleted", event_id: "evt_cancel_from_#{status}", processor_id: "sub_from_#{status}", price_id: "price_#{status}")

      assert_equal "canceled", Subscription.find_by(processor_subscription_id: "sub_from_#{status}").status
    end
  end


  test "a canceled subscription is never made active again" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")
    record = apply("customer.subscription.updated", event_id: "evt_late_update", status: "active", quantity: 3)

    assert_equal "canceled", Subscription.sole.status
    assert_equal "ignored:canceled_is_terminal", record.error
  end

  test "a canceled subscription is never made live again by a start" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")
    record = apply("customer.subscription.created", event_id: "evt_late_start", status: "active")

    assert_equal "canceled", Subscription.sole.status
    assert_equal "ignored:canceled_is_terminal", record.error
  end

  test "a canceled subscription is not given a second cancellation event" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")
    before = events.pluck(:id)
    apply("customer.subscription.deleted", event_id: "evt_deleted_twice")

    assert_equal before, events.pluck(:id)
  end

  test "nothing an update says revives a canceled subscription" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")
    Subscription::LIVE_STATUSES.each do |status|
      record = apply("customer.subscription.updated", event_id: "evt_revive_#{status}", status: status, quantity: 3)

      assert_equal "ignored:canceled_is_terminal", record.error
      assert_equal "canceled", Subscription.sole.status
    end
  end


  test "a deletion arriving before its creation is accepted" do
    record = apply("customer.subscription.deleted")

    assert_predicate record, :handled?
    assert_equal 1, Subscription.count
  end

  test "a deletion arriving before its creation leaves a canceled row, not an active one" do
    apply("customer.subscription.deleted")

    assert_equal "canceled", Subscription.sole.status
  end

  test "a deletion arriving before its creation emits the cancellation, because that is the fact" do
    apply("customer.subscription.deleted")

    assert_equal "billing.subscription.canceled", events.sole.event_type
  end

  test "the creation that follows a deletion does not start the subscription" do
    apply("customer.subscription.deleted")
    apply("customer.subscription.created")

    assert_equal "canceled", Subscription.sole.status
    assert_equal [ "billing.subscription.canceled" ], event_types
  end

  test "a deletion arriving before its creation never grants entitlements" do
    apply("customer.subscription.deleted")
    apply("customer.subscription.created")

    refute_predicate Subscription.sole, :grants_entitlements?
  end

  test "a cancellation for a plan this service does not have is recorded and refused" do
    @plan.update!(processor_price_id: "price_gone")

    record = apply("customer.subscription.deleted")

    assert_equal 0, Subscription.count
    assert_equal "ignored:unknown_plan", record.error
  end

  test "an update arriving before its creation does not create the subscription" do
    record = apply("customer.subscription.updated", quantity: 3)

    assert_equal 0, Subscription.count
    assert_equal "ignored:no_subscription_to_update", record.error
  end

  test "an update arriving before its creation does not stop the creation that follows" do
    apply("customer.subscription.updated", event_id: "evt_early_update", quantity: 3)
    apply("customer.subscription.created")

    assert_equal "active", Subscription.sole.status
    assert_equal [ "billing.subscription.started" ], event_types
  end

  test "out-of-order deliveries each keep the time the processor reported" do
    apply("customer.subscription.created")
    apply("customer.subscription.deleted")

    started, canceled = events.order(:created_at, :id).to_a
    assert_equal Time.utc(2026, 9, 30, 4, 0, 0), started.time
    assert_equal Time.utc(2026, 11, 14, 4, 0, 0), canceled.time
  end



  test "a delivery older than the one that last wrote the row is refused" do
    apply("customer.subscription.created", created: EARLIEST, event_id: "evt_order_start")
    apply("customer.subscription.updated", event_id: "evt_order_past_due", created: NEWER, status: "past_due")
    record = apply("customer.subscription.updated", event_id: "evt_order_stale", created: OLDER, status: "active")

    assert_equal "ignored:stale_delivery", record.error
  end

  test "a delivery older than the one that last wrote the row does not move the status" do
    apply("customer.subscription.created", created: EARLIEST, event_id: "evt_order_start")
    apply("customer.subscription.updated", event_id: "evt_order_past_due", created: NEWER, status: "past_due")
    apply("customer.subscription.updated", event_id: "evt_order_stale", created: OLDER, status: "active")

    assert_equal "past_due", Subscription.sole.status
  end

  test "a refused stale delivery leaves the ordering record where the newer delivery put it" do
    apply("customer.subscription.created", created: EARLIEST, event_id: "evt_order_start")
    apply("customer.subscription.updated", event_id: "evt_order_past_due", created: NEWER, status: "past_due")
    apply("customer.subscription.updated", event_id: "evt_order_stale", created: OLDER, status: "active")

    assert_equal Time.at(NEWER).utc, Subscription.sole.last_processor_event_at
  end

  test "a refused stale delivery emits no event" do
    apply("customer.subscription.created", created: EARLIEST, event_id: "evt_order_start")
    apply("customer.subscription.updated", event_id: "evt_order_past_due", created: NEWER, status: "past_due")
    apply("customer.subscription.updated", event_id: "evt_order_stale", created: OLDER, status: "active")

    assert_equal [ "billing.subscription.started", "billing.subscription.updated" ], event_types
  end

  test "a refused stale delivery does not clear a cancellation the newer delivery recorded" do
    apply("customer.subscription.created", created: EARLIEST, event_id: "evt_order_start")
    apply("customer.subscription.updated", event_id: "evt_order_cancelling", created: NEWER,
      cancel_at_period_end: true)
    apply("customer.subscription.updated", event_id: "evt_order_stale", created: OLDER,
      cancel_at_period_end: false)

    assert_equal true, Subscription.sole.cancel_at_period_end
  end

  test "a delivery at the same processor timestamp is not stale" do
    apply("customer.subscription.created", created: NEWER, event_id: "evt_order_same_a")
    record = apply("customer.subscription.updated", event_id: "evt_order_same_b", created: NEWER, quantity: 7)

    assert_predicate record, :handled?
    assert_nil record.error
    assert_equal [ "billing.subscription.started", "billing.subscription.updated" ], event_types
  end

  test "a first delivery is never stale" do
    record = apply("customer.subscription.deleted", created: EARLIEST, event_id: "evt_order_first_deleted")

    assert_predicate record, :handled?
    assert_equal "canceled", Subscription.sole.status
  end


  test "a failure to emit leaves no row behind" do
    with_refused_emission { apply("customer.subscription.created") }

    assert_equal 0, Subscription.count
  end

  test "a failure to emit is parked on the delivery, with the class that caused it" do
    with_refused_emission { apply("customer.subscription.created") }

    record = ProcessorWebhook.sole
    assert_predicate record, :handled?
    assert record.error.start_with?("failed:ActiveRecord::StatementInvalid:"),
      "expected a parked row, got: #{record.error.inspect}"
  end

  test "a failure to emit emits nothing" do
    with_refused_emission { apply("customer.subscription.created") }

    assert_equal 0, events.count
  end

  test "a delivery that was parked as failed is not retried as new work" do
    with_refused_emission { apply("customer.subscription.created") }
    apply("customer.subscription.created")

    assert_equal 0, Subscription.count
    assert_equal 0, events.count
    assert_equal 1, ProcessorWebhook.count
  end

  test "a delivery that died before its receipt was written leaves no row" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { apply("customer.subscription.created") }
    end

    assert_equal 0, Subscription.count
    assert_equal 0, events.count
  end

  test "a delivery that died before its receipt was written is visibly unfinished" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { apply("customer.subscription.created") }
    end

    record = ProcessorWebhook.sole
    assert_nil record.processed_at
    assert_nil record.error
  end

  test "a delivery whose receipt never landed is processed again and emits once" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { apply("customer.subscription.created") }
    end

    apply("customer.subscription.created")

    assert_equal 1, Subscription.count
    assert_equal 1, events.count
    assert_predicate ProcessorWebhook.sole, :handled?
  end

  private
    def apply(fixture, overrides = {})
      travel_to(frozen_now + next_delivery) { ingest(fixture, overrides) }
    end

    def next_delivery
      @deliveries = @deliveries.to_i + 1
    end

    def ingest(fixture, overrides = {})
      body = payload_for(fixture, overrides)

      Webhooks::Ingestion.new(
        processor: :stripe,
        event_id: overrides[:event_id] || body["id"],
        type: body["type"],
        payload: body
      ).call
    end

    def payload_for(fixture, overrides = {})
      body = JSON.parse(stripe_fixture(fixture))
      subscription = body.dig("data", "object")

      body["created"] = overrides[:created] if overrides.key?(:created)

      body["id"] = overrides[:event_id] if overrides.key?(:event_id)

      if (status = overrides[:status])
        subscription["status"] = status
        subscription["canceled_at"] = 1794628800 if status == "canceled"
      end

      if overrides.key?(:quantity)
        subscription.dig("items", "data", 0)["quantity"] = overrides[:quantity]
      end

      if overrides.key?(:cancel_at_period_end)
        subscription["cancel_at_period_end"] = overrides[:cancel_at_period_end]
      end

      if overrides.key?(:trial_end)
        subscription["trial_end"] = overrides[:trial_end]
        subscription["trial_start"] = overrides[:trial_end] ? 1790740800 : nil
      end

      if overrides[:processor_id]
        subscription["id"] = overrides[:processor_id]
      end

      if overrides[:price_id]
        subscription.dig("items", "data", 0)["price"]["id"] = overrides[:price_id]
      end

      if (customer = overrides[:customer])
        subscription["customer"] = customer.processor_customer_id
        subscription["metadata"] = { "anywaye_customer_id" => customer.id }
      end

      body
    end

    def setup_subscription(status:, processor_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", plan: @plan)
      Subscription.create!(
        account_id: @customer.owner_id,
        customer: @customer,
        plan: plan,
        processor_subscription_id: processor_id,
        status: status
      )
    end

    def create_customer(account_id: "11111111-1111-4111-8111-111111111111")
      @customers_created = (@customers_created || 0) + 1
      fixture_id = "cus_R1pQKz9xLp2mN4vB6yH8jL0"

      Customer.create!(
        owner_type: "Account",
        owner_id: account_id,
        processor: "stripe",
        processor_customer_id: @customers_created == 1 ? fixture_id : "cus_FAKEother#{format('%016d', @customers_created)}",
        email: "billing@example.com"
      )
    end

    def create_plan(price:, price_id:)
      @plans_created = (@plans_created || 0) + 1
      Plan.create!(
        name: "Plan #{@plans_created}",
        slug: "plan-#{@plans_created}",
        price: Billing::Money.new(price, "USD"),
        interval: "month",
        processor_price_id: price_id
      )
    end

    REFUSE_TO_EMIT = ->(_event) { raise ActiveRecord::StatementInvalid, "delivery lost while emitting" }

    def with_refused_emission
      OutboxEvent.set_callback(:create, :before, REFUSE_TO_EMIT)
      yield
    ensure
      OutboxEvent.skip_callback(:create, :before, REFUSE_TO_EMIT)
    end

    REFUSE_TO_MARK = ->(_record) { raise ActiveRecord::StatementInvalid, "connection lost while writing" }

    def with_refused_marking
      ProcessorWebhook.set_callback(:update, :before, REFUSE_TO_MARK)
      yield
    ensure
      ProcessorWebhook.skip_callback(:update, :before, REFUSE_TO_MARK)
    end
end
