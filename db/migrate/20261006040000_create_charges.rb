class CreateCharges < ActiveRecord::Migration[8.1]
  def change
    create_table :charges, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :account_id, null: false

      t.references :customer, type: :uuid, null: false, foreign_key: true
      t.references :subscription, type: :uuid, null: true, foreign_key: true

      t.string :processor_charge_id, null: false

      t.integer :amount, null: false
      t.string :currency, limit: 3, null: false

      t.text :description, null: false

      t.timestamptz :paid_at, null: false

      t.timestamps
    end

    add_index :charges, :processor_charge_id, unique: true

    add_check_constraint :charges,
      "currency::text ~ '^[A-Z]{3}$'::text",
      name: "charges_currency_is_iso_4217"

    add_check_constraint :charges,
      "amount >= 0",
      name: "charges_amount_not_negative"
  end
end
