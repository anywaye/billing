class CreateSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :subscriptions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :account_id, null: false

      t.references :customer, type: :uuid, null: false, foreign_key: true
      t.references :plan, type: :uuid, null: false, foreign_key: true

      t.string :processor_subscription_id, null: false

      t.string :status, null: false

      t.timestamptz :current_period_start
      t.timestamptz :current_period_end
      t.boolean :cancel_at_period_end, null: false, default: false
      t.timestamptz :canceled_at

      t.timestamptz :last_processor_event_at

      t.timestamps
    end

    add_index :subscriptions, :processor_subscription_id, unique: true

    add_index :subscriptions, %i[account_id plan_id],
      unique: true,
      where: "\"status\" <> 'canceled'",
      name: "subscriptions_live_account_plan_idx"

    add_check_constraint :subscriptions,
      "\"status\"::text = ANY (ARRAY['trialing'::text, 'active'::text, 'past_due'::text, 'canceled'::text, 'unpaid'::text])",
      name: "subscriptions_status_known"
  end
end
