# The outbox: an event, written in the same transaction as the thing it
# describes.
#
# The row is the *state change*, not the message about it. It is inserted by
# `after_create`/`after_update` — deliberately not `after_commit`, because a
# separate transaction is a window in which the database says the customer
# exists and the event does not. A rollback of the record takes the event with
# it; a commit makes both durable together. That is the whole rule, and it is
# core's: docs/event-outbox.md.
#
# The column list below is core's contract, not a local invention: `id`,
# `event_type`, `source`, `subject`, `time`, `data`, `created_at`,
# `published_at`, `attempts`. What this packet does not build is the publisher
# loop that moves rows to NATS — anywaye has no broker wired up, and adding a
# queue is a dependency decision (AGENTS.md) that this packet does not get to
# make. `published_at` and `attempts` are therefore always null and always zero,
# which is a known gap and is written down in README.md rather than hidden by
# pretending the loop exists.
#
# `event_type` rather than `type` is not cosmetic: on any Active Record model a
# column named `type` is single-table inheritance, and a row whose value is
# `billing.customer.created` would send Rails looking for a class with that name.
# It is also what core's DDL says.
class CreateOutboxEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :outbox_events, id: :uuid do |t|
      # The envelope's `id`, generated before the insert and reused on every
      # retry, so a republish is the same id and a consumer's dedupe key dedupes.
      t.string :event_type, null: false
      t.string :source, null: false
      t.string :subject, null: false
      # `time` is when the state change happened — not when the row was inserted
      # and not when it is published. A row that sat unpublished for an hour
      # still reports the original time.
      t.column :time, :timestamptz, null: false
      t.jsonb :data, null: false
      t.column :published_at, :timestamptz
      t.integer :attempts, null: false, default: 0
      t.column :created_at, :timestamptz, null: false
    end

    # The publisher's only query, and the index core names for it. Partial,
    # because published rows are spent: indexing them would grow the index with
    # every event this service has ever published, forever, to serve a query
    # that filters them all out.
    add_index :outbox_events, :created_at, where: "published_at IS NULL", name: "outbox_events_unpublished_idx"

    # Per-entity ordering is the one ordering core guarantees, so this is the one
    # index the guarantee needs behind it.
    add_index :outbox_events, %i[subject created_at], name: "outbox_events_subject_created_at_idx"
  end
end
