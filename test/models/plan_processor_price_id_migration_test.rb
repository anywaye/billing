require "test_helper"

class PlanProcessorPriceIdMigrationTest < ActiveSupport::TestCase
  require Rails.root.join("db/migrate/20260930000012_index_plans_on_processor_price_id").to_s

  INDEX = "plans_processor_price_id_idx".freeze

  self.use_transactional_tests = false

  setup do
    travel_to(frozen_now)
    Plan.delete_all
    OutboxEvent.delete_all
  end

  teardown do
    Plan.delete_all
    OutboxEvent.delete_all

    reset_index
  end

  test "many plans may carry no processor price id" do
    insert_plan_raw(processor_price_id: nil)
    insert_plan_raw(processor_price_id: nil)
    insert_plan_raw(processor_price_id: nil)

    assert_equal 3, Plan.where(processor_price_id: nil).count,
      "a plan with no processor price is the normal state of a row created through " \
      "`POST /v1/plans` — it is put on sale afterwards, or not at all. Refusing the " \
      "second of these would make the column unusable before a plan is ever sold."
  end

  test "with the index rolled back the duplicate is writable, and it is not once it returns" do
    contested = "price_FAKEreversibleAAAAAAAA"
    migrate(:down)
    insert_plan_raw(processor_price_id: contested, amount_cents: 1_900)
    insert_plan_raw(processor_price_id: contested, amount_cents: 49_000)

    assert_equal 2, Plan.where(processor_price_id: contested).count,
      "the index is down and the duplicate should be permitted"

    Plan.where(processor_price_id: contested).delete_all

    migrate(:up)
    insert_plan_raw(processor_price_id: contested, amount_cents: 1_900)

    assert_refused_by_constraint(
      "the restored index has to refuse the second plan on the same `price_`. A model " \
      "validation that fired here instead would mean this test was measuring the model, " \
      "and the index could be absent for all it knows."
    ) { insert_plan_raw(processor_price_id: contested, amount_cents: 49_000) }
  end

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

    assert_equal 2, Plan.count
    assert_equal before.sort, Plan.order(:processor_price_id).pluck(:processor_price_id)
  end

  private
    def migrate(direction)
      migration = IndexPlansOnProcessorPriceId
      migration.verbose = false
      migration.migrate(direction)
    end

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
