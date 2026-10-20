# frozen_string_literal: true

class CreateAskTokensTables < ActiveRecord::Migration[7.0]
  def change
    create_table :ask_tokens_wallets do |t|
      t.references :owner, polymorphic: true, null: false
      t.bigint :balance, null: false, default: 0
      t.timestamps
    end
    add_index :ask_tokens_wallets, %i[owner_type owner_id], unique: true,
      name: "idx_ask_tokens_wallets_owner"

    create_table :ask_tokens_transactions do |t|
      t.references :token_wallet, null: false, foreign_key: { to_table: Ask::Tokens::Rails.config.wallets_table }
      t.string :entry_type, null: false
      t.bigint :amount, null: false
      t.string :reason, null: false
      t.jsonb :metadata, null: false, default: {}
      t.bigint :balance, null: false
      t.datetime :expires_at
      # Billing detail the ActiveRecord store lifts out of :metadata when
      # present. Columns exist so ledgers can be summed and grouped (model
      # spend, margin) without JSON casts.
      t.string :model_id
      t.string :provider
      t.bigint :input_tokens
      t.bigint :output_tokens
      t.bigint :cached_tokens
      t.decimal :llm_cost_usd, precision: 12, scale: 8
      t.decimal :multiplier, precision: 6, scale: 4, default: 1.0, null: false
      t.string :cost_kind          # llm, messaging, voice, storage
      t.string :unit_kind          # tokens, messages, minutes
      t.bigint :units
      t.datetime :created_at, null: false
    end
    add_index :ask_tokens_transactions, %i[token_wallet_id created_at]
    add_index :ask_tokens_transactions, :entry_type
    add_index :ask_tokens_transactions, :expires_at
  end
end
