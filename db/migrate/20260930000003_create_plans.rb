# Plans: what can be bought, at what price, on what cadence.
#
# `amount_cents` is an INTEGER of minor units. The name says cents because the
# first processor is Stripe and Stripe speaks cents; the *value* is minor units
# of `currency`, so a JPY plan stores 500 in a column called amount_cents. The
# Ruby side never touches this column as a number — `Plan#price` is a `Money`
# and it is the only way an amount enters the model (see the AGENTS.md money
# rules). Money being an integer is enforced here by the column type, by a
# CHECK, and by the model, so a value that somehow arrives as a Float or a
# negative cannot be stored.
class CreatePlans < ActiveRecord::Migration[8.1]
  def change
    create_table :plans, id: :uuid do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :processor_product_id
      t.string :processor_price_id
      t.integer :amount_cents, null: false
      t.string :currency, limit: 3, null: false
      t.string :interval, null: false
      t.integer :trial_days, null: false, default: 0
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :plans, :slug, unique: true

    add_check_constraint :plans, "amount_cents >= 0", name: "plans_amount_cents_not_negative"
    add_check_constraint :plans, "trial_days >= 0", name: "plans_trial_days_not_negative"

    add_check_constraint :plans, "interval IN ('month', 'year', 'one_time')", name: "plans_interval_known"
  end
end
