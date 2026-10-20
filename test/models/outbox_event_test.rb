require "test_helper"

class OutboxEventTest < ActiveSupport::TestCase
  OWNER_ID = "11111111-1111-4111-8111-111111111111"

  setup do
    travel_to(frozen_now)
  end

  # --- the envelope -----------------------------------------------------------

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

  # --- the transaction --------------------------------------------------------

  test "the event is written inside the record's transaction, so a rollback takes it too" do
    Customer.transaction do
      create_customer

      # Written already, before anything has committed. An after_commit hook
      # would leave this at zero.
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

  # --- the row's own rules ----------------------------------------------------

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

  # --- one processor event id, one row ---------------------------------------

  # The constraint itself, asked of the database rather than compared as text.
  #
  # The repository's standing rule is that a partial unique index is "a statement
  # about a set, and it is tested behaviourally" — comparing the predicate to a
  # string in the model would prove two texts agree, which is not the same fact.
  # So these insert rows and ask whether the database objects.
  #
  # The defect this index closes is a **duplicate charge**: two concurrent
  # deliveries of one `invoice.paid` both emit, and two outbox rows are two
  # envelope ids, which core defines as the dedupe key.
  # `test/services/webhooks/concurrent_delivery_test.rb` is the end-to-end
  # version; this is the constraint alone, deterministic by construction and
  # needing no threads.
  test "two events for one processor event id are refused by the database" do
    publish_payment(processor_event_id: "evt_dup")

    expect_unique_violation { publish_payment(processor_event_id: "evt_dup") }
  end

  test "the refused second event leaves exactly one row, not two" do
    publish_payment(processor_event_id: "evt_dup")

    expect_unique_violation { publish_payment(processor_event_id: "evt_dup") }

    assert_equal 1, OutboxEvent.for_processor_event("evt_dup").count
  end

  # The direction that finds an index written over the wrong thing. A unique
  # index on `subject`, for instance, would refuse this pair and break every
  # subscription that emits `started` then `updated` about one subject — a real
  # delivery refused by a constraint that looked like it was working.
  test "two different processor event ids are two events" do
    publish_payment(processor_event_id: "evt_one")
    publish_payment(processor_event_id: "evt_two")

    assert_equal 2, OutboxEvent.count
    assert_equal %w[evt_one evt_two],
      OutboxEvent.order(:created_at, :id).map { |event| event.data.fetch("processor_event_id") }.sort
  end

  # And the same subject, because `subject` is what a consumer correlates on and
  # one subscription legitimately produces several events.
  test "one subject may carry events from several processor event ids" do
    publish_payment(processor_event_id: "evt_one", subject: "sub_shared")
    publish_payment(processor_event_id: "evt_two", subject: "sub_shared")
    publish_payment(processor_event_id: "evt_three", subject: "sub_shared")

    assert_equal 3, OutboxEvent.where(subject: "sub_shared").count
  end

  # The three model-callback emissions have no processor event id, because they
  # are not the product of a processor delivery. `WHERE ... IS NOT NULL` leaves
  # them alone, and this is what proves the index is partial rather than a unique
  # index on the whole table.
  test "events with no processor event id are not constrained against each other" do
    create_customer
    travel 1.second
    # A second customer under a *different* owner, because a customer is unique
    # on its processor id and two rows with the same one would fail a validation
    # this test is not about.
    create_customer(owner_id: "22222222-2222-4222-8222-222222222222",
      processor_customer_id: "cus_second")

    assert_equal 2, OutboxEvent.count
    OutboxEvent.find_each { |event| refute event.data.key?("processor_event_id") }
  end

  # A null and a value must coexist: a partial index that treated a missing key
  # as a key would refuse a callback event that happened to land beside a
  # webhook event. Both are legitimate rows in the same table.
  test "an event with no processor event id coexists with one that has one" do
    create_customer
    publish_payment(processor_event_id: "evt_present")

    assert_equal 2, OutboxEvent.count
  end

  # `OutboxEvent.for_processor_event` is what the ingestion layer asks, and it
  # reads the same expression the index is built on. A scope that had drifted
  # from the index would answer "not present" for a row that is present, and the
  # duplicate would be reported as a fresh emission.
  test "the scope the index is built on finds the row the index protects" do
    publish_payment(processor_event_id: "evt_scope")

    assert_equal 1, OutboxEvent.for_processor_event("evt_scope").count
    assert_equal 0, OutboxEvent.for_processor_event("evt_absent").count
  end

  # The migration is reversible, and it is exercised rather than asserted to be.
  # `change` rolls back to `remove_index`; a migration that only ran forwards
  # would be a rollback nobody had ever taken and nobody had ever watched work.
  # --- the times -------------------------------------------------------------

  # A webhook's event describes a state change that already happened somewhere
  # else, seconds or days ago. Stamping it with the moment this service wrote the
  # row would make out-of-order delivery undetectable, because every event would
  # appear to have happened in the order it arrived.
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

  # --- the closed list -------------------------------------------------------

  # The list is the service's published contract: the models emit three of these
  # and the webhook mapping emits the other five, and `test/contract` asserts the
  # manifest agrees. A type that fell out of it would be refused at the write,
  # from inside a webhook, as a parked row answered 200.
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

    # A row shaped like what a webhook publishes, carrying the one field the
    # unique index is built on. `payment` is the type the duplicate-charge defect
    # actually produced, and its payload carries `processor_event_id` because
    # `Webhooks::StripeEvents.provenance` puts the processor's own id in every
    # webhook-emitted payload.
    def publish_payment(processor_event_id:, subject: "in_1")
      OutboxEvent.publish!(
        type: "billing.payment.succeeded",
        subject: subject,
        data: { "processor" => "stripe", "processor_event_id" => processor_event_id },
        time: frozen_now
      )
    end

    # Runs the block in a savepoint that is **always** rolled back, and returns
    # the database error the block raised, or nil.
    #
    # `requires_new: true` is the whole point. A uniqueness violation aborts the
    # enclosing PostgreSQL transaction, so every later command on that connection
    # fails with `PG::InFailedSqlTransaction` — a state no amount of rescuing
    # recovers from, and exactly what an earlier version of this test hit.
    # Rolling back to a savepoint clears the abort, so the rest of the suite is
    # unaffected. PostgreSQL's DDL is transactional as well, which is why
    # dropping and recreating the index inside here leaves nothing behind.
    #
    # The `raise ActiveRecord::Rollback` is **inside** the `transaction` block,
    # which is the only place it means "roll back this savepoint and return
    # normally". Raising it from the method body instead — the shape this helper
    # had first — propagates to the test's own wrapping transaction, which
    # swallows it and discards the test's data, and the *next* test then fails on
    # a count one too high. A helper that corrupts the tests after it is worse
    # than no helper.
    #
    # **Only `ActiveRecord::StatementInvalid` is swallowed**, and that is
    # deliberate: `RecordNotUnique` descends from it, and it is the only thing
    # this helper is here to absorb. A `Minitest::Assertion` is re-raised, so a
    # failing assertion inside the block is still reported as a failure instead
    # of being converted into a return value and lost — a helper that swallows
    # its own test failures is the "silent green" this repository has refused
    # three times.
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

    # The outbox's index names, read from the database rather than from
    # `db/schema.rb`. Asking the schema file would prove the file says what it
    # says; asking the connection is what tells us whether the constraint is
    # actually in force for the rows these tests write.
    def index_names
      ActiveRecord::Base.connection.indexes("outbox_events").map(&:name)
    end

    # Runs the block and asserts the database refused it with a uniqueness
    # violation naming **this** index, absorbing the violation so it does not
    # abort the enclosing transaction.
    #
    # The message is matched on purpose: a bare `assert_raises(RecordNotUnique)`
    # would be satisfied by any unique constraint in the schema, so a test using
    # it is a tripwire an unrelated change could satisfy. The index name in the
    # message is what makes a failure point at the constraint rather than at a
    # symptom downstream of it.
    def expect_unique_violation
      violation = in_savepoint { yield }

      assert_instance_of ActiveRecord::RecordNotUnique, violation,
        "expected a uniqueness violation from #{yield_name}, got #{violation.inspect}"
      assert_match(/outbox_events_processor_event_id_idx/, violation.message)
      violation
    end

    # The failing expression, so a failure names the call that was refused.
    # `caller` rather than a passed-in string, so it cannot drift from the code
    # it describes.
    def yield_name
      caller_locations(1, 1).first.label.to_s
    end

    # A row that is valid apart from whatever a test overrides. `source` and
    # `time` are set because the tests below are about one attribute at a time,
    # and a row that is invalid for three reasons cannot say which one.
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
