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

ActiveRecord::Schema[8.1].define(version: 2026_10_20_092000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "ask_tokens_transactions", force: :cascade do |t|
    t.bigint "token_wallet_id", null: false
    t.string "entry_type", null: false
    t.bigint "amount", null: false
    t.string "reason", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "balance", null: false
    t.datetime "expires_at"
    t.string "model_id"
    t.string "provider"
    t.bigint "input_tokens"
    t.bigint "output_tokens"
    t.bigint "cached_tokens"
    t.decimal "llm_cost_usd", precision: 12, scale: 8
    t.decimal "multiplier", precision: 6, scale: 4, default: "1.0", null: false
    t.string "cost_kind"
    t.string "unit_kind"
    t.bigint "units"
    t.datetime "created_at", null: false
    t.index ["entry_type"], name: "index_ask_tokens_transactions_on_entry_type"
    t.index ["expires_at"], name: "index_ask_tokens_transactions_on_expires_at"
    t.index ["token_wallet_id", "created_at"], name: "index_ask_tokens_transactions_on_token_wallet_id_and_created_at"
    t.index ["token_wallet_id"], name: "index_ask_tokens_transactions_on_token_wallet_id"
  end

  create_table "ask_tokens_wallets", force: :cascade do |t|
    t.string "owner_type", null: false
    t.bigint "owner_id", null: false
    t.bigint "balance", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id"], name: "idx_ask_tokens_wallets_owner", unique: true
    t.index ["owner_type", "owner_id"], name: "index_ask_tokens_wallets_on_owner"
  end

  create_table "charges", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "customer_id", null: false
    t.uuid "subscription_id"
    t.string "processor_charge_id", null: false
    t.integer "amount", null: false
    t.string "currency", limit: 3, null: false
    t.text "description", null: false
    t.timestamptz "paid_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "charges_anywaye_account_id_idx"
    t.index ["customer_id"], name: "index_charges_on_customer_id"
    t.index ["processor_charge_id"], name: "index_charges_on_processor_charge_id", unique: true
    t.index ["subscription_id"], name: "index_charges_on_subscription_id"
    t.check_constraint "amount >= 0", name: "charges_amount_not_negative"
    t.check_constraint "currency::text ~ '^[A-Z]{3}$'::text", name: "charges_currency_is_iso_4217"
  end

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
    t.check_constraint "\"interval\"::text = ANY (ARRAY['month'::character varying, 'year'::character varying, 'one_time'::character varying]::text[])", name: "plans_interval_known"
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
    t.index ["account_id"], name: "subscriptions_anywaye_account_id_idx"
    t.index ["customer_id"], name: "index_subscriptions_on_customer_id"
    t.index ["plan_id"], name: "index_subscriptions_on_plan_id"
    t.index ["processor_subscription_id"], name: "index_subscriptions_on_processor_subscription_id", unique: true
    t.check_constraint "status::text = ANY (ARRAY['trialing'::text, 'active'::text, 'past_due'::text, 'canceled'::text, 'unpaid'::text])", name: "subscriptions_status_known"
  end

  add_foreign_key "ask_tokens_transactions", "ask_tokens_wallets", column: "token_wallet_id"
  add_foreign_key "charges", "customers"
  add_foreign_key "charges", "subscriptions"
  add_foreign_key "subscriptions", "customers"
  add_foreign_key "subscriptions", "plans"
end
