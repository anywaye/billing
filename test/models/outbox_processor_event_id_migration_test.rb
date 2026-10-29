require "test_helper"

class OutboxProcessorEventIdMigrationTest < ActiveSupport::TestCase
  require Rails.root.join("db/migrate/20260930000010_index_outbox_events_on_processor_event_id").to_s

  INDEX = "outbox_events_processor_event_id_idx".freeze

  self.use_transactional_tests = false

  setup do
    travel_to(frozen_now)
    OutboxEvent.delete_all
  end

  teardown do
    restore_index
    OutboxEvent.delete_all
  end

  test "the index is in the database before this test touches anything" do
    assert_includes index_names, INDEX,
      "the suite ran against a database without the index, so every test below " \
      "would be measuring nothing"
  end

  test "the index is unique, and not merely present" do
    index = ActiveRecord::Base.connection.indexes("outbox_events").find { |i| i.name == INDEX }

    assert_predicate index, :unique,
      "a non-unique index over the processor event id documents the key without " \
      "enforcing it, which is a comment rather than a constraint"
  end

  test "the migration rolls the index back, and back up again" do
    migrate(:down)

    refute_includes index_names, INDEX, "the index survived its own rollback"

    migrate(:up)

    assert_includes index_names, INDEX, "the index did not come back"
    assert_equal 1, index_names.count { |name| name == INDEX },
      "the migration added the index a second time rather than restoring it"
  end

  test "with the index rolled back the duplicate is writable, and it is not once it returns" do
    migrate(:down)
    publish_twice("evt_reversible")
    assert_equal 2, OutboxEvent.for_processor_event("evt_reversible").count,
      "the index is down and the duplicate should be permitted"

    OutboxEvent.for_processor_event("evt_reversible").delete_all

    migrate(:up)
    publish_once("evt_restored")

    assert_raises_in_savepoint { publish_once("evt_restored") }
  end

  test "rolling back leaves the table's other rows untouched" do
    publish_once("evt_survivor_a")
    publish_once("evt_survivor_b")
    before = OutboxEvent.order(:created_at, :id).pluck(:id)

    migrate(:down)

    assert_equal 2, OutboxEvent.count
    assert_equal before, OutboxEvent.order(:id).pluck(:id)
    assert_equal %w[evt_survivor_a evt_survivor_b],
      OutboxEvent.pluck(:data).map { |data| data.fetch("processor_event_id") }.sort
  end

  private
    def migrate(direction)
      migration = IndexOutboxEventsOnProcessorEventId
      migration.verbose = false
      migration.migrate(direction)
    end

    def restore_index
      return if ActiveRecord::Base.connection.indexes("outbox_events").any? { |index|
        index.name == INDEX && index.unique
      }

      migrate(:up)
    end

    def index_names
      ActiveRecord::Base.connection.indexes("outbox_events").map(&:name)
    end

    def publish_once(processor_event_id)
      OutboxEvent.publish!(
        type: "billing.payment.succeeded",
        subject: "in_1",
        data: { "processor" => "stripe", "processor_event_id" => processor_event_id },
        time: frozen_now
      )
    end

    def publish_twice(processor_event_id)
      publish_once(processor_event_id)
      publish_once(processor_event_id)
    end

    def assert_raises_in_savepoint(&block)
      assert_refused_by_constraint(
        "expected the restored index to refuse the duplicate",
        &block
      )
    end
end
