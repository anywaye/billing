# One Stripe customer id, one billing customer.
#
# ## The defect this closes
#
# `Subscriptions::Lifecycle#customer` resolves a subscription delivery by the
# processor's own customer id, with `find_by` and no `ORDER BY`. For that lookup
# to have one answer, at most one row may claim a given `cus_`. Before this
# index nothing stopped two, and two of them is not a slow query — it is a
# question with two answers:
#
#     PATCH /v1/customers/{the caller's own row} {"processor_customer_id": "<another account's cus_>"}
#     -> 200
#     -> two rows now answer to one cus_
#
# `CustomerUpdate` closes `owner` and `processor` — the two columns the existing
# `(owner_type, owner_id, processor)` index is built on — and permits
# `processor_customer_id`, which makes that one column the whole of the attack
# surface. With two rows claiming the id, which account a delivery about the
# victim's subscription is billed to is **not decided by the data**, and
# `IndexCustomersOnProcessorCustomerId` is what makes it decided.
#
# This is finding F2 in `REPORT-billing-12-isolation`.
#
# ## Partial, and why it is partial rather than a bare `unique`
#
# The column is nullable and *legitimately* so: a customer created through
# `/v1` has no `cus_` until its first subscription tells this service what the
# processor calls it, and the comment on `Lifecycle#customer` says so. So the
# rule is not "this column is unique". It is **"a value here is unique"** — and
# a null means *not yet known at this processor*, which many rows may be at once.
#
# A bare `unique` index would happen to allow that, because PostgreSQL's default
# is `NULLS DISTINCT` and a null never equals a null. That is the wrong reason to
# depend on: `NULLS NOT DISTINCT` is a PostgreSQL 15 feature a future migration
# could set on this column for some unrelated reason, and it would turn every
# `/v1`-created customer into a collision. The partial index does not have that
# dependency at all — a null is not **in** the index, so there is no rule for a
# null to satisfy or to break, whatever the column's null semantics are.
#
# The same reasoning is why `outbox_events_processor_event_id_idx` is partial, and
# for the same reason: a key the value did not carry must not be constrained by
# a rule about keys that carry it.
#
# ## What it costs, and what it does not buy
#
# The index is proportional to the rows that actually claim a processor id,
# rather than carrying an entry for every customer forever to enforce a rule
# that does not apply to them.
#
# It does not make `/v1` account-scoped, and it is not a substitute for that.
# Uniqueness says one row per id; it does not say the *caller* may not read
# another's row, and the surface here is still open by the recorded gap in
# `AGENTS.md`. What it removes is the one route by which a caller could make the
# delivery path itself resolve another account's row.
#
# ## A deploy step, not a no-op
#
# A unique index cannot be created over data that already violates it, so a
# deployed `customers` table holding duplicates has to have them resolved before
# this migration can be applied at all. That refusal is the database being
# correct. `REPORT-billing-13-fixes` names it as a deploy step.
#
# Reversible: `add_index` in a `change` rolls back to `remove_index`, and
# `test/models/customer_processor_customer_id_migration_test.rb` runs the `down`
# and the `up` for real, in a file of its own because running a migration commits
# the enclosing transaction.
class IndexCustomersOnProcessorCustomerId < ActiveRecord::Migration[8.1]
  def change
    add_index :customers, :processor_customer_id,
      unique: true,
      where: "processor_customer_id IS NOT NULL",
      name: "customers_processor_customer_id_idx"
  end
end
