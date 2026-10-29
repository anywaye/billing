# Processor webhooks: a payment processor's event, as received.
#
# The table exists for one property — a replay is a non-event — and everything
# about its shape serves that. Delivery is at-least-once, so the same event id
# arrives again, immediately or a day later, and the second arrival must not
# produce a second `billing.payment.succeeded` with a second envelope id. The
# unique index on `stripe_event_id` is what turns that second arrival into a
# lookup.
#
# The payload is stored before anything tries to interpret it, and stored
# verbatim. A payload this build could not process is still the raw material for
# a replay by hand once the mapping is fixed, and a normalized hash would be the
# wrong thing to replay: it is the *processor's* bytes that the mapping is a claim
# about.
#
# `processed_at` is `timestamptz` like every other instant here, and NULL means
# "received, not finished" — the only state a crash can leave behind, and the
# one worth alerting on.
#
# `stripe_event_id` is named for the processor rather than being a
# (processor, event_id) pair. Stripe is the only processor in this build, and a
# second one gets its own column: a polymorphic pair would let one processor's
# ids be unique against its own while colliding with another's, which is a
# constraint that can be added to a table and cannot be removed from a table
# that already holds the data.
class CreateProcessorWebhooks < ActiveRecord::Migration[8.1]
  def change
    create_table :processor_webhooks, id: :uuid do |t|
      t.string :processor, null: false

      t.string :stripe_event_id, null: false

      t.string :type, null: false

      t.jsonb :payload, null: false, default: {}
      t.column :processed_at, :timestamptz
      t.text :error

      t.timestamps
    end

    add_index :processor_webhooks, :stripe_event_id, unique: true, name: "index_processor_webhooks_on_stripe_event_id"

    add_index :processor_webhooks, :processed_at, where: "processed_at IS NULL", name: "processor_webhooks_unprocessed_idx"

    add_check_constraint :processor_webhooks, "processor IN ('stripe')", name: "processor_webhooks_processor_known"
  end
end
