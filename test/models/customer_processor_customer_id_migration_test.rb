require "test_helper"

# `IndexCustomersOnProcessorCustomerId` is reversible, and this is the test that
# takes it both ways.
#
# ## Why it is a file of its own
#
# Because running a migration **commits the enclosing transaction**. A migration
# wraps its work in its own `ddl_transaction`, so the `down` here ends the test's
# transaction and every row it had written becomes durably committed — which is
# how the first version of this, run inside `outbox_event_test.rb`, left an outbox
# row behind and made the *next* test fail on a count one too high. This is the
# safety property, not a matter of taste: a constraint test that asserts an index
# exists is a comment, and one that runs the migration backwards is a test.
#
# ## What "reversible" has to mean here
#
# Not that the migration has no `up` method. `change` rolling back to
# `remove_index` is a claim about Rails, and this is the assertion that the claim
# holds **against this database**: the index goes, the duplicate the index exists
# to prevent becomes writable again, and the index comes back and refuses it once
# more. The middle step is the one that matters — it is what shows the *index* is
# what was doing the refusing.
#
# ## The model is kept out of it on purpose
#
# `Customer` carries a matching uniqueness **validation**, so a test that wrote
# the duplicate through `Customer.create!` would be refused by the validation and
# would never reach the index — proving nothing about the constraint, and passing
# on a build where the migration had been rolled back. Every duplicate below is
# written with `insert_all!`, which goes straight to the database and skips
# validations and callbacks, so what is being measured is the table's opinion and
# not the model's.
class CustomerProcessorCustomerIdMigrationTest < ActiveSupport::TestCase
  # Required, not autoloaded: the test runs the migration's own `change` in both
  # directions, so the class has to exist.
  require Rails.root.join("db/migrate/20260930000011_index_customers_on_processor_customer_id").to_s

  INDEX = "customers_processor_customer_id_idx".freeze

  # The migration commits, so this test cannot be inside a transaction that the
  # migration would then commit. See the class comment.
  self.use_transactional_tests = false

  setup do
    travel_to(frozen_now)
    Customer.delete_all
    OutboxEvent.delete_all
  end

  teardown do
    # **Rows first, index second, and the order is load-bearing.** A unique index
    # cannot be created over data that already violates it, so restoring the index
    # before clearing the rows would fail on this file's own leftovers — which is
    # what happened the first time it was written, and it is the same refusal a
    # deployment hits on a table that already holds the defect.
    Customer.delete_all
    OutboxEvent.delete_all

    # The index is the suite's invariant, and a failed assertion partway through
    # leaves it down — so the next **file** would measure a table this service does
    # not have. The teardown's job is "do not leave a mess"; the setup's is "never
    # trust what the last test left", and both are needed. See the setup comment for
    # the mutation that showed the teardown alone was not enough.
    reset_index
  end

  # A customer with no processor id yet is the normal state of a row created
  # through `POST /v1/customers` — the processor tells us the id, not the other
  # way round — and many rows are legitimately in that state at once.
  #
  # **What this does and does not prove, stated rather than implied.** It pins the
  # *behaviour* that matters: repeated nulls are permitted. It does **not** prove
  # the index is partial, because on a nullable column PostgreSQL's default
  # `NULLS DISTINCT` already permits that and a bare `unique` index would pass this
  # test too. The predicate is asserted in `db/schema.rb` and argued in the
  # migration; the behaviour that would actually break is a `NULLS NOT DISTINCT`
  # column or an array-backed unique constraint, and this is what catches those.
  test "many rows may hold no processor customer id" do
    insert_customer_raw(owner_id: account, processor_customer_id: nil)
    insert_customer_raw(owner_id: account, processor_customer_id: nil)
    insert_customer_raw(owner_id: account, processor_customer_id: nil)

    assert_equal 3, Customer.where(processor_customer_id: nil).count,
      "a customer with no processor id is the normal state of a row created through " \
      "`POST /v1/customers`. Refusing the second of these would make the column " \
      "unusable for exactly the rows that have not reached the processor yet."
  end

  # The claim the index exists to make, in both directions, with the same class,
  # the same columns and the same bypass of the model on either side of the
  # migration. Only the index differs.
  test "with the index rolled back the duplicate is writable, and it is not once it returns" do
    contested = "cus_FAKEreversibleBBBBBBBBBBB"
    migrate(:down)
    insert_customer_raw(owner_id: account, processor_customer_id: contested)
    insert_customer_raw(owner_id: account, processor_customer_id: contested)

    assert_equal 2, Customer.where(processor_customer_id: contested).count,
      "the index is down and the duplicate should be permitted"

    # A unique index cannot be created over data that already violates it, so the
    # duplicates have to go first. That refusal is the database being correct,
    # and it is the real-world repair too: a deployed `customers` table holding
    # two rows on one `cus_` has to have them resolved before this migration can be
    # applied at all. `REPORT-billing-13-fixes` names that as a deploy step.
    Customer.where(processor_customer_id: contested).delete_all

    migrate(:up)
    insert_customer_raw(owner_id: account, processor_customer_id: contested)

    assert_refused_by_constraint(
      "the restored index has to refuse the second row on the same `cus_`. A model " \
      "validation that fired here instead would mean this test was measuring the model, " \
      "and the index could be absent for all it knows."
    ) { insert_customer_raw(owner_id: account, processor_customer_id: contested) }
  end

  test "the migration rolls the index back, and back up again" do
    migrate(:down)

    refute_includes index_names, INDEX, "the index survived its own rollback"

    migrate(:up)

    assert_includes index_names, INDEX, "the index did not come back"
    assert_equal 1, index_names.count { |name| name == INDEX },
      "the migration added the index a second time rather than restoring it"
  end

  # `change` is reversible only if the operations in it are, and the failure mode
  # of an unreversible one is a rollback that raises halfway and leaves the table
  # in a state nobody designed. Asserting the rollback is *clean* — no rows lost,
  # no rows duplicated — is what a deployment actually depends on.
  test "rolling back leaves the table's other rows untouched" do
    insert_customer_raw(owner_id: account, processor_customer_id: "cus_FAKEsurvivorAAAAAAAA")
    insert_customer_raw(owner_id: account, processor_customer_id: "cus_FAKEsurvivorBBBBBBBB")
    before = Customer.order(:id).pluck(:processor_customer_id)

    migrate(:down)

    # Compared by **processor id**, not by `created_at`: both rows are written
    # under a frozen clock, so their `created_at` values are equal and the order
    # falls to the uuid tiebreaker — which is random, and made this test fail
    # about half the time for a reason that has nothing to do with the migration.
    assert_equal 2, Customer.count
    assert_equal before.sort, Customer.order(:processor_customer_id).pluck(:processor_customer_id)
  end

  private
    def migrate(direction)
      migration = IndexCustomersOnProcessorCustomerId
      migration.verbose = false
      migration.migrate(direction)
    end

    # Remove whatever is there under this name, then run the migration's own `up`.
    # Idempotent, and it does not care what shape the thing it removed was — which
    # is the point. A guard of the form "is the index there and unique? if not, fix
    # it" would be cheaper, and would also repair the very thing a test is asserting
    # about.
    def reset_index
      ActiveRecord::Base.connection.remove_index(:customers, name: INDEX) if index_names.include?(INDEX)
      migrate(:up)
    end

    def index_definitions
      ActiveRecord::Base.connection.indexes("customers")
    end

    def index_names
      index_definitions.map(&:name)
    end

    # A **fresh account per call**, and that is not tidiness. `customers` already
    # carries a unique index over `(owner_type, owner_id, processor)`, so two rows
    # on one account are refused by *that* index before the new one is consulted —
    # and a test for this index that was refused by the other one would prove
    # nothing. Distinct accounts per row is the F2 shape anyway: the defect was
    # two accounts claiming one `cus_`, never two rows on one account.
    def account
      SecureRandom.uuid
    end

    # Straight to the database: no validation, no callback, no outbox event. The
    # point of this helper is that a duplicate is **not** refused by the model, so
    # the only thing left that can refuse it is the index.
    def insert_customer_raw(owner_id:, processor_customer_id:)
      Customer.insert_all!([
        {
          id: SecureRandom.uuid,
          owner_type: "Account",
          owner_id: owner_id,
          processor: "stripe",
          processor_customer_id: processor_customer_id,
          metadata: {},
          created_at: frozen_now,
          updated_at: frozen_now
        }
      ])
    end
end
