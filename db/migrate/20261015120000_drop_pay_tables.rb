# `pay` leaves, and its six tables with it.
#
# The gem is gone from the Gemfile, and with it `FakeProcessor` — the reason it
# was here. What replaces it is `Processor::FakeClient`, which is a plain Ruby
# object with a process-local ledger and no table at all, so the checkout path
# keeps its no-network proof without six Active Record tables, STI `type`
# columns and a `pay_customers.owner_id` column that was created as a bigint and
# had to be migrated to uuid by `20261006030000_pay_owner_ids_are_uuids.rb`.
#
# **Why the four creating migrations are deleted and not kept as history.**
# They are not runnable without the gem — `20261006024249` and
# `20261006024251` call `Pay::Adapter.json_column_type`, and `20261006024250`
# calls `Pay::Customer.find_each` — so a `db:migrate` from zero would die naming
# a class that no longer exists. Keeping them would also mean a fresh database
# is built by creating six tables and then dropping them, which is not a schema,
# it is a pantomime. And there is no deployed database to reconcile: billing has
# never shipped to a live environment (no chart, no Application, no host), so
# the only `schema_migrations` that ever recorded these versions are local dev
# and CI databases, where the versions are inert leftovers — an orphan row in
# `schema_migrations` is a fact about a migration that is no longer in the tree,
# and Rails reads the tree, not the rows. The tables' history is in
# `CHANGELOG.md`, where a reader is told it happened, and in
# `REPORT-billing-fake-client-01.md`, which carries the diff.
#
# **Why `down` is irreversible.** Recreating these tables would mean vendoring
# pay's schema by hand — a copy that would drift from the gem's own the moment
# either moved — and a `down` that recreates *something* is a `down` that lies.
# The tables are recreated by re-adding the gem, if that is ever decided.
class DropPayTables < ActiveRecord::Migration[8.1]
  PAY_TABLES = %w[
    pay_charges
    pay_payment_methods
    pay_subscriptions
    pay_customers
    pay_merchants
    pay_webhooks
  ].freeze

  def up
    PAY_TABLES.each do |table|
      drop_table table, if_exists: true
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "the pay tables are dropped because the pay gem is gone; recreating them " \
      "would mean hand-copying a schema only the gem can own"
  end
end
