# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_06_030000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "customers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "owner_type", null: false
    t.uuid "owner_id", null: false
    t.string "processor", null: false
    t.string "processor_customer_id"
    t.string "email"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "processor"], name: "index_customers_on_owner_type_and_owner_id_and_processor", unique: true
    t.index ["processor_customer_id"], name: "customers_processor_customer_id_idx", unique: true, where: "(processor_customer_id IS NOT NULL)"
    t.check_constraint "processor::text = 'stripe'::text", name: "customers_processor_known"
  end

  create_table "idempotency_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "endpoint", null: false
    t.string "principal", null: false
    t.string "key", null: false
    t.string "request_digest", null: false
    t.integer "status", null: false
    t.text "response_body", null: false
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_idempotency_keys_on_created_at"
    t.index ["endpoint", "principal", "key"], name: "index_idempotency_keys_on_endpoint_and_principal_and_key", unique: true
  end

  create_table "outbox_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "event_type", null: false
    t.string "source", null: false
    t.string "subject", null: false
    t.timestamptz "time", null: false
    t.jsonb "data", null: false
    t.timestamptz "published_at"
    t.integer "attempts", default: 0, null: false
    t.timestamptz "created_at", null: false
    t.index "((data ->> 'processor_event_id'::text))", name: "outbox_events_processor_event_id_idx", unique: true, where: "((data ->> 'processor_event_id'::text) IS NOT NULL)"
    t.index ["created_at"], name: "outbox_events_unpublished_idx", where: "(published_at IS NULL)"
    t.index ["subject", "created_at"], name: "outbox_events_subject_created_at_idx"
  end

  create_table "pay_charges", force: :cascade do |t|
    t.bigint "customer_id", null: false
    t.bigint "subscription_id"
    t.string "processor_id", null: false
    t.integer "amount", null: false
    t.string "currency"
    t.integer "application_fee_amount"
    t.integer "amount_refunded"
    t.jsonb "metadata"
    t.jsonb "data"
    t.string "stripe_account"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "type"
    t.jsonb "object"
    t.index ["customer_id", "processor_id"], name: "index_pay_charges_on_customer_id_and_processor_id", unique: true
    t.index ["subscription_id"], name: "index_pay_charges_on_subscription_id"
  end

  create_table "pay_customers", force: :cascade do |t|
    t.string "owner_type"
    t.uuid "owner_id", null: false
    t.string "processor", null: false
    t.string "processor_id"
    t.boolean "default"
    t.jsonb "data"
    t.string "stripe_account"
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "type"
    t.jsonb "object"
    t.index ["owner_type", "owner_id", "deleted_at"], name: "pay_customer_owner_index", unique: true
    t.index ["processor", "processor_id"], name: "index_pay_customers_on_processor_and_processor_id", unique: true
  end

  create_table "pay_merchants", force: :cascade do |t|
    t.string "owner_type"
    t.uuid "owner_id", null: false
    t.string "processor", null: false
    t.string "processor_id"
    t.boolean "default"
    t.jsonb "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "type"
    t.index ["owner_type", "owner_id", "processor"], name: "index_pay_merchants_on_owner_type_and_owner_id_and_processor"
  end

  create_table "pay_payment_methods", force: :cascade do |t|
    t.bigint "customer_id", null: false
    t.string "processor_id", null: false
    t.boolean "default"
    t.string "payment_method_type"
    t.jsonb "data"
    t.string "stripe_account"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "type"
    t.index ["customer_id", "processor_id"], name: "index_pay_payment_methods_on_customer_id_and_processor_id", unique: true
  end

  create_table "pay_subscriptions", force: :cascade do |t|
    t.bigint "customer_id", null: false
    t.string "name", null: false
    t.string "processor_id", null: false
    t.string "processor_plan", null: false
    t.integer "quantity", default: 1, null: false
    t.string "status", null: false
    t.datetime "current_period_start", precision: nil
    t.datetime "current_period_end", precision: nil
    t.datetime "trial_ends_at", precision: nil
    t.datetime "ends_at", precision: nil
    t.boolean "metered"
    t.string "pause_behavior"
    t.datetime "pause_starts_at", precision: nil
    t.datetime "pause_resumes_at", precision: nil
    t.decimal "application_fee_percent", precision: 8, scale: 2
    t.jsonb "metadata"
    t.jsonb "data"
    t.string "stripe_account"
    t.string "payment_method_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "type"
    t.jsonb "object"
    t.index ["customer_id", "processor_id"], name: "index_pay_subscriptions_on_customer_id_and_processor_id", unique: true
    t.index ["metered"], name: "index_pay_subscriptions_on_metered"
    t.index ["pause_starts_at"], name: "index_pay_subscriptions_on_pause_starts_at"
  end

  create_table "pay_webhooks", force: :cascade do |t|
    t.string "processor"
    t.string "event_type"
    t.jsonb "event"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "plans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "processor_product_id"
    t.string "processor_price_id"
    t.integer "amount_cents", null: false
    t.string "currency", limit: 3, null: false
    t.string "interval", null: false
    t.integer "trial_days", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "entitlements", default: {}, null: false
    t.index ["processor_price_id"], name: "plans_processor_price_id_idx", unique: true, where: "(processor_price_id IS NOT NULL)"
    t.index ["slug"], name: "index_plans_on_slug", unique: true
    t.check_constraint "NOT entitlements ? 'features'::text OR jsonb_typeof(entitlements -> 'features'::text) = 'array'::text", name: "plans_entitlements_features_is_array"
    t.check_constraint "NOT entitlements ? 'limits'::text OR jsonb_typeof(entitlements -> 'limits'::text) = 'object'::text", name: "plans_entitlements_limits_is_object"
    t.check_constraint "\"interval\"::text = ANY (ARRAY['month'::character varying::text, 'year'::character varying::text, 'one_time'::character varying::text])", name: "plans_interval_known"
    t.check_constraint "amount_cents >= 0", name: "plans_amount_cents_not_negative"
    t.check_constraint "jsonb_typeof(entitlements) = 'object'::text", name: "plans_entitlements_is_object"
    t.check_constraint "trial_days >= 0", name: "plans_trial_days_not_negative"
  end

  create_table "processor_webhooks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "processor", null: false
    t.string "stripe_event_id", null: false
    t.string "type", null: false
    t.jsonb "payload", default: {}, null: false
    t.timestamptz "processed_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["processed_at"], name: "processor_webhooks_unprocessed_idx", where: "(processed_at IS NULL)"
    t.index ["stripe_event_id"], name: "index_processor_webhooks_on_stripe_event_id", unique: true
    t.check_constraint "processor::text = 'stripe'::text", name: "processor_webhooks_processor_known"
  end

  create_table "subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "customer_id", null: false
    t.uuid "plan_id", null: false
    t.string "processor_subscription_id", null: false
    t.string "status", null: false
    t.timestamptz "current_period_start"
    t.timestamptz "current_period_end"
    t.boolean "cancel_at_period_end", default: false, null: false
    t.timestamptz "canceled_at"
    t.timestamptz "last_processor_event_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "plan_id"], name: "subscriptions_live_account_plan_idx", unique: true, where: "((status)::text <> 'canceled'::text)"
    t.index ["customer_id"], name: "index_subscriptions_on_customer_id"
    t.index ["plan_id"], name: "index_subscriptions_on_plan_id"
    t.index ["processor_subscription_id"], name: "index_subscriptions_on_processor_subscription_id", unique: true
    t.check_constraint "status::text = ANY (ARRAY['trialing'::text, 'active'::text, 'past_due'::text, 'canceled'::text, 'unpaid'::text])", name: "subscriptions_status_known"
  end

  add_foreign_key "pay_charges", "pay_customers", column: "customer_id"
  add_foreign_key "pay_charges", "pay_subscriptions", column: "subscription_id"
  add_foreign_key "pay_payment_methods", "pay_customers", column: "customer_id"
  add_foreign_key "pay_subscriptions", "pay_customers", column: "customer_id"
  add_foreign_key "subscriptions", "customers"
  add_foreign_key "subscriptions", "plans"
end
