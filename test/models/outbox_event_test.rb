require "test_helper"

class OutboxEventTest < ActiveSupport::TestCase
  OWNER_ID = "11111111-1111-4111-8111-111111111111"

  setup do
    travel_to(frozen_now)
  end


  test "a created customer emits billing.customer.created" do
    customer = create_customer

    event = only_event

    assert_equal "billing.customer.created", event.event_type
    assert_equal "billing", event.source
    assert_equal customer.id, event.subject
  end

  test "a created plan emits billing.plan.created" do
    create_plan

    assert_equal "billing.plan.created", only_event.event_type
  end

  test "an updated plan emits billing.plan.updated" do
    plan = create_plan
    last_event
    travel 1.second

    plan.update!(name: "Pro monthly, annually")

    assert_equal 2, OutboxEvent.count
    assert_equal "billing.plan.updated", last_event.event_type
    assert_equal plan.id, last_event.subject
  end

  test "an update that changes nothing emits nothing, because nothing happened" do
    plan = create_plan
    last_event

    plan.update!(name: plan.name)

    assert_equal 1, OutboxEvent.count
  end

  test "a created plan does not also emit an update" do
    create_plan

    assert_equal [ "billing.plan.created" ], OutboxEvent.order(:created_at).pluck(:event_type)
  end

  test "the envelope is the shape core's schema describes" do
    customer = create_customer

    assert_equal(
      {
        "specversion" => "1.0",
        "id" => only_event.id,
        "type" => "billing.customer.created",
        "source" => "billing",
        "subject" => customer.id,
        "time" => frozen_now.iso8601,
        "data" => customer.as_json
      },
      only_event.to_envelope
    )
  end

  test "the event id is a uuid, because consumers deduplicate on it" do
    create_customer
    create_customer(owner_id: "22222222-2222-4222-8222-222222222222")

    assert_match Identifiers::UUID, only_event.id
    assert_equal 2, OutboxEvent.pluck(:id).uniq.size
  end

  test "the event time is the state change, not the transport" do
    create_customer

    assert_equal frozen_now, only_event.time
  end

  test "the payload carries money as minor units" do
    create_plan

    assert_equal({ "amount_minor" => 1900, "currency" => "USD" }, only_event.data.fetch("price"))
  end


  test "the event is written inside the record's transaction, so a rollback takes it too" do
    Customer.transaction do
      create_customer

      assert_equal 1, OutboxEvent.count

      raise ActiveRecord::Rollback
    end

    assert_equal 0, Customer.count
    assert_equal 0, OutboxEvent.count
  end

  test "a rejected record emits nothing" do
    assert_no_difference("OutboxEvent.count") do
      assert_not Customer.new(owner_type: "User", owner_id: nil, processor: "stripe").save
    end
  end


  test "an event type is the three-segment form this service publishes" do
    event = build_event(event_type: "customer.created")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :event_type
  end

  test "an event type is one of the types this service publishes" do
    event = build_event(event_type: "billing.invoice.created")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :event_type
  end

  test "an event subject is the entity id and is required" do
    event = build_event(subject: nil)

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :subject
  end

  test "an event subject cannot smuggle transport metadata into the envelope" do
    event = build_event(subject: "a b c")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :subject
  end

  test "an event payload is an object" do
    event = build_event(data: "created")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :data
  end


  test "two events for one processor event id are refused by the database" do
    publish_payment(processor_event_id: "evt_dup")

    expect_unique_violation { publish_payment(processor_event_id: "evt_dup") }
  end

  test "the refused second event leaves exactly one row, not two" do
    publish_payment(processor_event_id: "evt_dup")

    expect_unique_violation { publish_payment(processor_event_id: "evt_dup") }

    assert_equal 1, OutboxEvent.for_processor_event("evt_dup").count
  end

  test "two different processor event ids are two events" do
    publish_payment(processor_event_id: "evt_one")
    publish_payment(processor_event_id: "evt_two")

    assert_equal 2, OutboxEvent.count
    assert_equal %w[evt_one evt_two],
      OutboxEvent.order(:created_at, :id).map { |event| event.data.fetch("processor_event_id") }.sort
  end

  test "one subject may carry events from several processor event ids" do
    publish_payment(processor_event_id: "evt_one", subject: "sub_shared")
    publish_payment(processor_event_id: "evt_two", subject: "sub_shared")
    publish_payment(processor_event_id: "evt_three", subject: "sub_shared")

    assert_equal 3, OutboxEvent.where(subject: "sub_shared").count
  end

  test "events with no processor event id are not constrained against each other" do
    create_customer
    travel 1.second
    create_customer(owner_id: "22222222-2222-4222-8222-222222222222",
      processor_customer_id: "cus_second")

    assert_equal 2, OutboxEvent.count
    OutboxEvent.find_each { |event| refute event.data.key?("processor_event_id") }
  end

  test "an event with no processor event id coexists with one that has one" do
    create_customer
    publish_payment(processor_event_id: "evt_present")

    assert_equal 2, OutboxEvent.count
  end

  test "the scope the index is built on finds the row the index protects" do
    publish_payment(processor_event_id: "evt_scope")

    assert_equal 1, OutboxEvent.for_processor_event("evt_scope").count
    assert_equal 0, OutboxEvent.for_processor_event("evt_absent").count
  end


  test "the time can be the state change's own, not the moment of the write" do
    event = OutboxEvent.publish!(
      type: "billing.payment.succeeded",
      subject: "pi_1",
      data: {},
      time: Time.utc(2026, 10, 7, 4, 0, 0)
    )

    assert_equal Time.utc(2026, 10, 7, 4, 0, 0), event.time
  end

  test "the time falls back to now for a change this service just made" do
    event = OutboxEvent.publish!(type: "billing.payment.failed", subject: "pi_1", data: {})

    assert_equal frozen_now, event.time
  end

  test "a caller that passes no time and one that passes an explicit time differ" do
    travel 1.hour do
      assert_not_equal(
        OutboxEvent.publish!(type: "billing.payment.failed", subject: "pi_1", data: {}).time,
        OutboxEvent.publish!(type: "billing.payment.failed", subject: "pi_2", data: {}, time: frozen_now).time
      )
    end
  end


  DECLARED_TYPES = %w[
    billing.customer.created
    billing.payment.failed
    billing.payment.succeeded
    billing.plan.created
    billing.plan.updated
    billing.subscription.canceled
    billing.subscription.started
    billing.subscription.updated
  ].freeze

  test "the declared types are the three-segment types this build emits" do
    assert_equal DECLARED_TYPES.sort, OutboxEvent::TYPES.sort
  end

  DECLARED_TYPES.each do |type|
    test "#{type} is a type this service publishes" do
      event = build_event(event_type: type)

      assert event.valid?, event.errors.full_messages.join("; ")
    end
  end

  test "a type from the catalog this build does not publish is still refused" do
    event = build_event(event_type: "billing.payment.refunded")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :event_type
  end

  private
    def create_customer(overrides = {})
      Customer.create!({ owner_type: "User", owner_id: OWNER_ID, processor: "stripe" }.merge(overrides))
    end

    def create_plan(overrides = {})
      Plan.create!({
        name: "Pro monthly",
        slug: "pro-monthly",
        price: Billing::Money.new(1900, "USD"),
        interval: "month"
      }.merge(overrides))
    end

    def only_event
      OutboxEvent.last
    end

    def last_event
      OutboxEvent.order(:created_at, :id).last
    end

    def publish_payment(processor_event_id:, subject: "in_1")
      OutboxEvent.publish!(
        type: "billing.payment.succeeded",
        subject: subject,
        data: { "processor" => "stripe", "processor_event_id" => processor_event_id },
        time: frozen_now
      )
    end

    def in_savepoint
      raised = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        begin
          yield
        rescue ActiveRecord::StatementInvalid => e
          raised = e
        end
        raise ActiveRecord::Rollback
      end
      raised
    end

    def index_names
      ActiveRecord::Base.connection.indexes("outbox_events").map(&:name)
    end

    def expect_unique_violation
      violation = in_savepoint { yield }

      assert_instance_of ActiveRecord::RecordNotUnique, violation,
        "expected a uniqueness violation from #{yield_name}, got #{violation.inspect}"
      assert_match(/outbox_events_processor_event_id_idx/, violation.message)
      violation
    end

    def yield_name
      caller_locations(1, 1).first.label.to_s
    end

    def build_event(overrides = {})
      OutboxEvent.new({
        event_type: "billing.customer.created",
        source: OutboxEvent::SERVICE,
        subject: OWNER_ID,
        time: frozen_now,
        data: {}
      }.merge(overrides))
    end
end
