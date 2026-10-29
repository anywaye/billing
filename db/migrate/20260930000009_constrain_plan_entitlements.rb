class ConstrainPlanEntitlements < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :plans, "jsonb_typeof(entitlements) = 'object'",
      name: "plans_entitlements_is_object"

    add_check_constraint :plans,
      "NOT (entitlements ? 'features') OR jsonb_typeof(entitlements -> 'features') = 'array'",
      name: "plans_entitlements_features_is_array"

    add_check_constraint :plans,
      "NOT (entitlements ? 'limits') OR jsonb_typeof(entitlements -> 'limits') = 'object'",
      name: "plans_entitlements_limits_is_object"
  end
end
