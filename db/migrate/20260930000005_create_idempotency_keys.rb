# Idempotency keys: the record that a mutating POST already happened.
#
# core's openapi-conventions.md requires that a retriable POST accept
# `Idempotency-Key`, and that a replay with the same key *and the same body*
# return the original response. That needs somewhere to keep the response,
# which is what this is.
#
# `principal` is part of the unique key because the key is scoped to
# (endpoint, principal, key) — one caller's key must not replay another
# caller's response. In v0 the endpoints are unauthenticated (see README), so
# the principal is the constant below; it becomes the token's `sub` when the
# platform's authorization packet lands, and the unique index already covers it.
#
# `request_digest` is what makes "same key, same body" decidable. Storing the
# body itself would mean holding a request payload for 24 hours to compare it;
# a digest answers the only question anyone asks.
class CreateIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_keys, id: :uuid do |t|
      t.string :endpoint, null: false
      t.string :principal, null: false
      t.string :key, null: false
      t.string :request_digest, null: false
      t.integer :status, null: false
      t.text :response_body, null: false
      t.datetime :created_at, null: false
    end

    add_index :idempotency_keys, %i[endpoint principal key], unique: true
    add_index :idempotency_keys, :created_at
  end
end
