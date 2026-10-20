require "test_helper"

# `IndexPlansOnProcessorPriceId` is reversible, and this is the test that takes it
# both ways.
#
# The shape is the one `CustomerProcessorCustomerIdMigrationTest` uses, and it is
# the one `outbox_processor_event_id_migration_test.rb` established: the file is
# separate because running a migration commits the enclosing transaction, and the
# middle step of the reversibility claim — the index down, the duplicate writable,
# the index back, the duplicate refused — is the only part that shows the index is
# what was doing the refusing.
#
# ## The model is kept out of it on purpose
#
# `Plan` carries a matching uniqueness **validation**, so a duplicate written
# through `Plan.create!` would be refused by the validation and never reach the
# index. Every row here is written with `insert_all!`, which goes straight to the
# database, so what is measured is the table's opinion.
#
# ## Why this one has a shape the customers test does not
#
# A collision on `processor_price_id` is a **pricing** defect, not only a lookup
# hazard: the two plans below charge different amounts, and a subscription billed
# against whichever one claimed the id is billed at a price this service never
# agreed to with the customer. So the rows are built with two prices on purpose,
# and one test asserts they still differ after the round trip — otherwise a
# collision here would be indistinguishable from a cosmetic one and the test
# would be asserting less than it looks like.
class PlanProcessorPriceIdMigrationTest < ActiveSupport::TestCase
  # Required, not autoloaded: the test runs the migration's own `change` in both
  # directions, so the class has to exist.
  require Rails.root.join("db/migrate/20260930000012_index_plans_on_processor_price_id").to_s

  INDEX = "plans_processor_price_id_idx".freeze

  # The migration commits, so this test cannot be inside a transaction that the
  # migration would then commit. See the class comment.
  self.use_transactional_tests = false

  setup do
    travel_to(frozen_now)
    Plan.delete_all
    OutboxEvent.delete_all
  end

  teardown do
    # **Rows first, index second, and the order is load-bearing.**
    #
    # A unique index cannot be created over data that already violates it, so a
    # teardown that restored the index before clearing the rows would fail on its
    # own leftovers — which is precisely what happened the first time this was
    # written, and it is the same refusal a deployment hits. The rows go, then the
    # index comes back.
    Plan.delete_all
    OutboxEvent.delete_all

    # The index is the suite's invariant, and a failed assertion partway through
    # leaves it down — so the next **file** would then be measuring a table this
    # service does not have. The teardown's job is "do not leave a mess"; the
    # setup's is "never trust what the last test left", and both are needed. See the
    # setup comment for the mutation that showed the teardown alone was not enough.
    reset_index
  end

  # A plan written through `POST /v1/plans` before it is ever put on sale has no
  # `price_`, and many plans are legitimately unsold at once.
  #
  # **What this does and does not prove, stated rather than implied.** It pins the
  # *behaviour* that matters: repeated nulls are permitted. It does **not** prove
  # the index is partial, because on a nullable column PostgreSQL's default
  # `NULLS DISTINCT` already permits that and a bare `unique` index would pass this
  # test too. The predicate is asserted in `db/schema.rb` and argued in the
  # migration; the behaviour that would actually break is a `NULLS NOT DISTINCT`
  # column or an array-backed unique constraint, and this is what catches those.
  test "many plans may carry no processor price id" do
    insert_plan_raw(processor_price_id: nil)
    insert_plan_raw(processor_price_id: nil)
    insert_plan_raw(processor_price_id: nil)

    assert_equal 3, Plan.where(processor_price_id: nil).count,
      "a plan with no processor price is the normal state of a row created through " \
      "`POST /v1/plans` — it is put on sale afterwards, or not at all. Refusing the " \
      "second of these would make the column unusable before a plan is ever sold."
  end

  # The claim the index exists to make, in both directions. Only the index differs
  # between the two halves: same class, same columns, same bypass of the model.
  test "with the index rolled back the duplicate is writable, and it is not once it returns" do
    contested = "price_FAKEreversibleAAAAAAAA"
    migrate(:down)
    insert_plan_raw(processor_price_id: contested, amount_cents: 1_900)
    insert_plan_raw(processor_price_id: contested, amount_cents: 49_000)

    assert_equal 2, Plan.where(processor_price_id: contested).count,
      "the index is down and the duplicate should be permitted"

    # A unique index cannot be created over data that already violates it, so the
    # duplicates go first. That refusal is the database being correct, and it is
    # the real-world repair: a deployed `plans` table holding two plans on one
    # `price_` has to have them resolved before this migration can be applied at
    # all. `REPORT-billing-13-fixes` names it as a deploy step.
    Plan.where(processor_price_id: contested).delete_all

    migrate(:up)
    insert_plan_raw(processor_price_id: contested, amount_cents: 1_900)

    assert_refused_by_constraint(
      "the restored index has to refuse the second plan on the same `price_`. A model " \
      "validation that fired here instead would mean this test was measuring the model, " \
      "and the index could be absent for all it knows."
    ) { insert_plan_raw(processor_price_id: contested, amount_cents: 49_000) }
  end

  # The reason this is a money defect, held as a fact about the stored rows rather
  # than as a claim in prose. The two plans differ by an order of magnitude, so a
  # resolution to the wrong one is a wrong charge and not a wrong label.
  #
  # The index is rolled back for the duration, because writing the collision is the
  # whole point and the index exists to refuse it. The teardown puts it back, and
  # *which* thing refused the write is proved in the test above rather than
  # assumed here.
  test "the two plans that would have claimed one price id still charge different amounts" do
    contested = "price_FAKEmoneyshapeAAAAAAAAA"
    migrate(:down)

    insert_plan_raw(processor_price_id: contested, amount_cents: 1_900)
    insert_plan_raw(processor_price_id: contested, amount_cents: 49_000)

    amounts = Plan.where(processor_price_id: contested).order(:amount_cents).pluck(:amount_cents)

    assert_equal [ 1_900, 49_000 ], amounts,
      "the two amounts are no longer different, so a collision on this column would be a " \
      "cosmetic lookup problem rather than a pricing one"
  end

  test "the migration rolls the index back, and back up again" do
    migrate(:down)

    refute_includes index_names, INDEX, "the index survived its own rollback"

    migrate(:up)

    assert_includes index_names, INDEX, "the index did not come back"
    assert_equal 1, index_names.count { |name| name == INDEX },
      "the migration added the index a second time rather than restoring it"
  end

  test "rolling back leaves the table's other rows untouched" do
    insert_plan_raw(processor_price_id: "price_FAKEsurvivorAAAAAAAA")
    insert_plan_raw(processor_price_id: "price_FAKEsurvivorBBBBBBBB")
    before = Plan.order(:id).pluck(:processor_price_id)

    migrate(:down)

    # Compared by **processor price id**, not by `created_at`: both rows are
    # written under a frozen clock, so their `created_at` values are equal and the
    # order falls to the uuid tiebreaker — which is random, and made this test fail
    # about half the time for a reason that has nothing to do with the migration.
    assert_equal 2, Plan.count
    assert_equal before.sort, Plan.order(:processor_price_id).pluck(:processor_price_id)
  end

  private
    def migrate(direction)
      migration = IndexPlansOnProcessorPriceId
      migration.verbose = false
      migration.migrate(direction)
    end

    # Remove whatever is there under this name, then run the migration's own `up`.
    # Idempotent, and it does not care what shape the thing it removed was — which
    # is the point. A guard of the form "is the index there and unique? if not, fix
    # it" would be cheaper, and would also repair the very thing a test is asserting
    # about.
    def reset_index
      ActiveRecord::Base.connection.remove_index(:plans, name: INDEX) if index_names.include?(INDEX)
      migrate(:up)
    end

    def index_definitions
      ActiveRecord::Base.connection.indexes("plans")
    end

    def index_names
      index_definitions.map(&:name)
    end

    # Straight to the database: no validation, no callback, no outbox event.
    def insert_plan_raw(processor_price_id:, amount_cents: 1_900)
      Plan.insert_all!([
        {
          id: SecureRandom.uuid,
          name: "Pro #{SecureRandom.hex(4)}",
          slug: "pro-#{SecureRandom.hex(6)}",
          processor_price_id: processor_price_id,
          amount_cents: amount_cents,
          currency: "USD",
          interval: "month",
          trial_days: 0,
          active: true,
          entitlements: {},
          created_at: frozen_now,
          updated_at: frozen_now
        }
      ])
    end
end
