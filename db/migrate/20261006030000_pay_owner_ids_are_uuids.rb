class PayOwnerIdsAreUuids < ActiveRecord::Migration[8.1]
  # **`pay`'s own migration got the owner's key type wrong for this service.**
  #
  # `1_create_pay_tables.pay.rb` asks `Rails.configuration.generators.options[:orm][:primary_key_type]`
  # for the key type and falls back to `:bigint` when it is not set. This service
  # has uuid primary keys (`db/schema.rb`, every table) and never set that
  # generator option, so `pay_customers.owner_id` and `pay_merchants.owner_id` were
  # created as **bigint**.
  #
  # The failure is silent and total. `Customer` is the owner, its id is a uuid, and
  # Postgres casts it: the row is written with `owner_id = 0` — every uuid collapsing
  # to the same integer — and `payment_processor`, which filters
  # `where(default: true)`, then finds nothing. Measured, not reasoned:
  #
  #     Pay::Customer.pluck(:id, :owner_type, :owner_id)
  #     # => [[29, "Customer", 0]]
  #
  # Every subscriber would share one processor customer, and the first checkout of
  # the second would bill the first's card. Nothing raises.
  #
  # **Why fix it here rather than set the generator option:** setting
  # `config.generators.orm.active_record.primary_key_type` would change key types
  # for every *generated* migration in this service, which is a much larger claim
  # than this packet needs to make. Two `change_column`s are the whole of the
  # defect.
  #
  # **Why `pay_merchants` too:** the same column, same wrong type, same migration.
  # This service has no merchant records — nothing is sold through it — but the
  # column is wrong for the same reason and fixing one half of an identical pair
  # is how the other half becomes a surprise.
  #
  # Inlined literals, no model constants (`AGENTS.md`, Conventions): the migration
  # keeps meaning what it meant the day it ran.
  def up
    change_column_null :pay_customers, :owner_id, false
    change_column :pay_customers, :owner_id, :uuid, using: "owner_id::text::uuid"

    change_column_null :pay_merchants, :owner_id, false
    change_column :pay_merchants, :owner_id, :uuid, using: "owner_id::text::uuid"
  end

  def down
    change_column :pay_customers, :owner_id, :bigint, using: "owner_id::text::bigint"
    change_column :pay_merchants, :owner_id, :bigint, using: "owner_id::text::bigint"
  end
end