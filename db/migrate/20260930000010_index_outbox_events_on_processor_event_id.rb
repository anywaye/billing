# One processor event id, one outbox row.
#
# ## The duplicate this index makes impossible
#
# `Webhooks::Ingestion#call` is a check followed by an act: it reads
# `ProcessorWebhook#handled?` and, on `false`, writes the anywaye event and marks
# the delivery finished. The unique index on `processor_webhooks.stripe_event_id`
# makes two concurrent deliveries of one event id agree about *which row* they
# are working on — and that is not the same as agreeing about the answer.
# `handled?` reads a column neither thread has written yet, so under READ
# COMMITTED both read `nil`, both emit, and one Stripe event produces **two
# outbox rows with two different envelope ids**. core defines the envelope `id`
# as the dedupe key, so a consumer deduplicating on it cannot tell the second row
# from new information about a charge that already settled.
#
# A duplicate is therefore a *permitted state* of this table as it stood, and no
# amount of application-level checking fixes a permitted state under
# concurrency: the check and the act are separated by a window in which the
# database has no opinion. This index is the opinion. It holds under any
# interleaving, which is the property an application-level guard cannot have —
# a guard can only be right about the interleavings its author thought of.
#
# ## Why an index over `data` and not a column
#
# **The outbox column list is core's contract, not local.** core's
# `docs/event-outbox.md` says "the column list is the contract; the
# implementation is the service's business", and `AGENTS.md` repeats it: "If you
# change it, you are changing a contract." Adding a `processor_event_id` column
# would change it.
#
# The key is already in `data`, because core defines `data` as the payload and
# every webhook-emitted payload already carries `processor_event_id` — the
# processor's own id, put there by `Webhooks::StripeEvents.provenance`. So the
# index is a *functional* index over the existing column: no column added, no
# envelope attribute added (`to_envelope` is closed with
# `additionalProperties: false`, so a new column would not appear in the
# envelope either way, but a new column would still be a table this repository
# does not get to reshape).
#
# ## Partial, and why
#
# `WHERE data ->> 'processor_event_id' IS NOT NULL` leaves the three
# model-callback emissions — `billing.customer.created`, `billing.plan.created`,
# `billing.plan.updated` — entirely alone. Those are not the product of a
# processor delivery; they have no processor event id, and PostgreSQL's default
# `NULLS DISTINCT` would let them through anyway. Making the predicate explicit
# means the index does not carry an entry per callback event forever to enforce a
# rule that does not apply to them.
#
# ## What it does *not* cover, stated rather than left to be discovered
#
# `billing.subscription.started` does not carry `processor_event_id` in its
# payload, and deliberately so — the lifecycle's start payload is `core_payload`
# plus `started_at`, and `test/services/subscriptions/lifecycle_test.rb` asserts
# the absence. That event type is produced only by a write to `subscriptions`, so
# a second concurrent `customer.subscription.created` is refused there instead,
# and the outbox insert is never reached.
#
# Which refusal, though, is **not** settled by naming one index, and the
# measurement says so. `subscriptions` carries a uniqueness *validation* on
# `processor_subscription_id` in the model as well as a unique *index* over the
# same column, and a losing thread is refused by whichever it reaches first:
# over 60 barrelled duplicate creations on this branch the split was 57 index,
# 3 validation. Neither is individually sufficient to reason about — the
# duplicate is prevented as long as both are there, and dropping **every** index
# on `subscriptions` reopens it (two subscription rows, two
# `billing.subscription.started` events).
#
# So the property rests on more than one constraint, on a second table, and the
# ingestion layer is written against the *exception* rather than against a named
# index for that reason: `Webhooks::Ingestion` classifies a uniqueness failure
# and a unique-index violation as the same decision, because which one a thread
# hears is a scheduling accident. `test/services/webhooks/
# concurrent_delivery_test.rb` exercises both routes, and `REPORT-billing-09`
# records the measurement.
#
# Reversible: `add_index` in a `change` rolls back to `remove_index`, and
# `test/models/outbox_event_test.rb` runs the `down` and the `up` for real
# inside the suite rather than asserting that the migration is reversible.
class IndexOutboxEventsOnProcessorEventId < ActiveRecord::Migration[8.1]
  def change
    add_index :outbox_events, "((data ->> 'processor_event_id'))",
      unique: true,
      where: "data ->> 'processor_event_id' IS NOT NULL",
      name: "outbox_events_processor_event_id_idx"
  end
end
