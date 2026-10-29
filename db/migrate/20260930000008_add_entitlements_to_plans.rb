class AddEntitlementsToPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :plans, :entitlements, :jsonb, null: false, default: {}
  end
end
