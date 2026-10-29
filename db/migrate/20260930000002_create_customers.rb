# Customers: the billing-side record of something identity already knows about.
#
# `owner_type` + `owner_id` is a reference across a service boundary, not an
# association. identity owns `User` and `Account`; billing stores their uuids
# and deliberately declares no foreign key, because a foreign key to another
# service's table is a cross-database dependency that outlives the deployment
# that created it. The cost of that choice — a dangling reference is possible —
# is paid back by the validation that `owner_type` names an identity entity and
# `owner_id` is a uuid, and by the events a later packet will react to.
#
# A customer is billing's row, not the person. `processor_customer_id` is the
# Stripe-side id, and it is null in v0: this packet makes no Stripe call, so
# the column is reserved and honest about being empty.
class CreateCustomers < ActiveRecord::Migration[8.1]
  def change
    create_table :customers, id: :uuid do |t|
      t.string :owner_type, null: false
      t.uuid :owner_id, null: false
      t.string :processor, null: false
      t.string :processor_customer_id
      t.string :email
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :customers, %i[owner_type owner_id processor], unique: true

    add_check_constraint :customers, "processor IN ('stripe')", name: "customers_processor_known"
  end
end
