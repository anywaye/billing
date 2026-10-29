require "test_helper"

class CustomerProcessorCustomerIdMigrationTest < ActiveSupport::TestCase
  require Rails.root.join("db/migrate/20260930000011_index_customers_on_processor_customer_id").to_s

  INDEX = "customers_processor_customer_id_idx".freeze

  self.use_transactional_tests = false

  setup do
    travel_to(frozen_now)
    Customer.delete_all
    OutboxEvent.delete_all
  end

  teardown do
    Customer.delete_all
    OutboxEvent.delete_all

    reset_index
  end

  test "many rows may hold no processor customer id" do
    insert_customer_raw(owner_id: account, processor_customer_id: nil)
    insert_customer_raw(owner_id: account, processor_customer_id: nil)
    insert_customer_raw(owner_id: account, processor_customer_id: nil)

    assert_equal 3, Customer.where(processor_customer_id: nil).count,
      "a customer with no processor id is the normal state of a row created through " \
      "`POST /v1/customers`. Refusing the second of these would make the column " \
      "unusable for exactly the rows that have not reached the processor yet."
  end

  test "with the index rolled back the duplicate is writable, and it is not once it returns" do
    contested = "cus_FAKEreversibleBBBBBBBBBBB"
    migrate(:down)
    insert_customer_raw(owner_id: account, processor_customer_id: contested)
    insert_customer_raw(owner_id: account, processor_customer_id: contested)

    assert_equal 2, Customer.where(processor_customer_id: contested).count,
      "the index is down and the duplicate should be permitted"

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

  test "rolling back leaves the table's other rows untouched" do
    insert_customer_raw(owner_id: account, processor_customer_id: "cus_FAKEsurvivorAAAAAAAA")
    insert_customer_raw(owner_id: account, processor_customer_id: "cus_FAKEsurvivorBBBBBBBB")
    before = Customer.order(:id).pluck(:processor_customer_id)

    migrate(:down)

    assert_equal 2, Customer.count
    assert_equal before.sort, Customer.order(:processor_customer_id).pluck(:processor_customer_id)
  end

  private
    def migrate(direction)
      migration = IndexCustomersOnProcessorCustomerId
      migration.verbose = false
      migration.migrate(direction)
    end

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

    def account
      SecureRandom.uuid
    end

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
