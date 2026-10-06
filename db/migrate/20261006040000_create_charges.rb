class CreateCharges < ActiveRecord::Migration[8.1]
  def change
    create_table :charges, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # The account being billed: identity's uuid, with no foreign key and no
      # association, for the same reason `subscriptions.account_id` has none —
      # the class it would associate to lives in another service. It is frozen
      # here at creation from the resolved customer or subscription, which is
      # itself a uuid that cannot be reassigned.
      t.uuid :account_id, null: false

      t.references :customer, type: :uuid, null: false, foreign_key: true
      t.references :subscription, type: :uuid, null: true, foreign_key: true

      # The processor's own id for the charge. UNIQUE, and that index is the
      # resolution mechanism: every event about a charge is looked up by it, so
      # two rows for one processor charge would be two answers to one question.
      t.string :processor_charge_id, null: false

      # The amount in integer minor units, and the currency. The same rule as
      # `plans.amount_cents` and `plans.currency`: money is integer minor units
      # and never a Float (AGENTS.md, Money).
      t.integer :amount, null: false
      t.string :currency, limit: 3, null: false

      # A human-readable description of what was charged, for the receipt.
      t.text :description, null: false

      # When the charge was paid. The processor's own timestamp, not the moment
      # this service wrote the row.
      t.timestamptz :paid_at, null: false

      t.timestamps
    end

    add_index :charges, :processor_charge_id, unique: true

    # The currency, inline rather than read from the model, so this migration
    # still means what it meant the day it ran.
    add_check_constraint :charges,
      "currency::text ~ '\\A[A-Z]{3}\\z'::text",
      name: "charges_currency_is_iso_4217"

    add_check_constraint :charges,
      "amount >= 0",
      name: "charges_amount_not_negative"
  end
end
