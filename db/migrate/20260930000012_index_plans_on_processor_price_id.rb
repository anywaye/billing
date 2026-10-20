# One Stripe price id, one plan.
#
# ## The defect this closes
#
# The same shape as `IndexCustomersOnProcessorCustomerId`, one table over.
# `Subscriptions::Lifecycle#plan` resolves a subscription delivery by the
# processor's price id with `find_by` and no `ORDER BY`, so at most one plan may
# claim a given `price_`. Before this index nothing stopped two, and two of them
# is a **pricing** defect rather than a cosmetic one:
#
#     POST /v1/plans {"processor_price_id": "<a plan already in the catalogue's price id>", ...}
#     -> 201
#     -> a subscription billed against whichever plan claimed the id, at an amount
#        this service never agreed to with the customer
#
# `billing.subscription.started` then carries that plan's `currency` and says
# nothing about the one that was intended, so the wrong amount is not only
# charged but published.
#
# This one is a correctness defect rather than a tenancy one — a plan is
# catalogue, and the catalogue is shared on purpose — and the consequence is
# still the same shape. This is finding F3 in
# `REPORT-billing-12-isolation`.
#
# ## Partial, and why
#
# Exactly the reasoning on the customers index, for the same reason, and it is
# worth repeating rather than referring to: the rule is **"a value here is
# unique"**, not "this column is unique". A plan created through `/v1` before it
# is ever put on sale at Stripe has no `price_` yet, and many plans legitimately
# are in that state at once.
#
# A bare `unique` index would allow that only because PostgreSQL defaults to
# `NULLS DISTINCT`, which is a database default rather than a statement of this
# service's intent, and one that `NULLS NOT DISTINCT` (PostgreSQL 15) could
# quietly remove. The partial index does not depend on it: a null is not in the
# index, so there is no rule for it to satisfy.
#
# ## A deploy step, not a no-op
#
# A unique index cannot be created over data that already violates it, so a
# deployed `plans` table holding two plans on one `price_` has to have them
# resolved before this migration can be applied. `REPORT-billing-13-fixes`
# names it as a deploy step rather than pretending the migration is safe to run
# on a table that already has the defect.
#
# Reversible: `add_index` in a `change` rolls back to `remove_index`, and
# `test/models/plan_processor_price_id_migration_test.rb` takes it both ways.
class IndexPlansOnProcessorPriceId < ActiveRecord::Migration[8.1]
  def change
    add_index :plans, :processor_price_id,
      unique: true,
      where: "processor_price_id IS NOT NULL",
      name: "plans_processor_price_id_idx"
  end
end
