require "test_helper"

# `IndexOutboxEventsOnProcessorEventId` is reversible, and this is the test that
# takes it both ways.
#
# ## Why it is not in `outbox_event_test.rb`
#
# Because running a migration **commits the enclosing transaction**. A migration
# wraps its work in its own `ddl_transaction`, so the `down` here ends the
# test's transaction and every row the test had written becomes durably
# committed — which is how a first version of this, run inside
# `outbox_event_test.rb`, left an outbox row behind and made the *next* test
# fail on a count one too high. Four unrelated failures, none of which was about
# this test.
#
# The separation is the safety property, not a matter of taste. This is the only
# file in the repository that turns transactional tests off for that reason, and
# it is also the only one that *has* to: a constraint test that asserts an index
# exists is a comment, and one that runs the migration backwards is a test.
#
# ## What "reversible" has to mean here
#
# Not that the migration has no `up` method. `change` rolling back to
# `remove_index` is a claim about Rails, and this is the assertion that the claim
# holds **against this database**: the index goes, the duplicate the index exists
# to prevent becomes writable again, and the index comes back and refuses it
# once more. The middle step matters most — it is what shows the constraint is
# what was doing the refusing, rather than a validation on the model.
class OutboxProcessorEventIdMigrationTest < ActiveSupport::TestCase
  # Required, not autoloaded: the test runs the migration's own `change` in both
  # directions, so the class has to exist.
  require Rails.root.join("db/migrate/20260930000010_index_outbox_events_on_processor_event_id").to_s

  INDEX = "outbox_events_processor_event_id_idx".freeze

  # The migration commits, so this test cannot be inside a transaction that the
  # migration would then commit. See the class comment.
  self.use_transactional_tests = false

  setup do
    travel_to(frozen_now)
    OutboxEvent.delete_all
  end

  teardown do
    # The index is the suite's invariant. Whether or not this test finished, the
    # next test must find the database as it expects to find it — and asking the
    # connection is the only way to know, because a failed assertion partway
    # through leaves the index down.
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

  # The reversibility claim, taken in three steps so each step is separately
  # falsifiable. A single assertion that the index is there after an up/down pair
  # would pass if the `down` had done nothing and the `up` had added a second
  # index under a different name.
  test "the migration rolls the index back, and back up again" do
    migrate(:down)

    refute_includes index_names, INDEX, "the index survived its own rollback"

    migrate(:up)

    assert_includes index_names, INDEX, "the index did not come back"
    assert_equal 1, index_names.count { |name| name == INDEX },
      "the migration added the index a second time rather than restoring it"
  end

  # The step that shows the constraint is what refuses. With the index down, the
  # duplicate is writable; with it up, it is not. Nothing else in the model
  # changed between the two halves — same class, same validations, same payload.
  test "with the index rolled back the duplicate is writable, and it is not once it returns" do
    migrate(:down)
    publish_twice("evt_reversible")
    assert_equal 2, OutboxEvent.for_processor_event("evt_reversible").count,
      "the index is down and the duplicate should be permitted"

    # A unique index cannot be created over data that already violates it, so the
    # duplicates have to go first. That refusal is the database being correct,
    # and it is the real-world repair too: a deployed table holding duplicates
    # has to have them resolved before this migration can be applied at all.
    # `REPORT-billing-09` names that as a deploy step rather than pretending
    # the migration is safe to run on a table that already has the bug.
    OutboxEvent.for_processor_event("evt_reversible").delete_all

    migrate(:up)
    publish_once("evt_restored")

    assert_raises_in_savepoint { publish_once("evt_restored") }
  end

  # `change` is reversible only if the operations in it are, and the failure mode
  # of an unreversible one is a rollback that raises halfway and leaves the table
  # in a state nobody designed. Asserting the rollback is *clean* — no rows lost,
  # no rows duplicated — is what a deployment actually depends on.
  test "rolling back leaves the table's other rows untouched" do
    publish_once("evt_survivor_a")
    publish_once("evt_survivor_b")
    before = OutboxEvent.order(:created_at, :id).pluck(:id)

    migrate(:down)

    # Compared by **primary key**, not by `created_at`. Both rows are written
    # under a frozen clock, so their `created_at` values are equal and the order
    # falls to the uuid tiebreaker — which is random, and made this test fail
    # about half the time for a reason that has nothing to do with the migration.
    # The repository's rule: a test asserting on ordering gives each row its own
    # instant, or it asserts on identity.
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

    # A uniqueness violation aborts the enclosing PostgreSQL transaction, after
    # which every later command on that connection fails with
    # `PG::InFailedSqlTransaction`. A savepoint absorbs it, and the trick lives in
    # `test/support/constraint_refusals.rb` because billing-13's two index tests
    # need the same thing — see that file for why it is shared rather than copied.
    def assert_raises_in_savepoint(&block)
      assert_refused_by_constraint(
        "expected the restored index to refuse the duplicate",
        &block
      )
    end
end
