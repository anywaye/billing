# REPORT — billing-event-payloads-01: the recipient fact on the money events

**Branch:** `worker/billing-w43-eventpayloads`
**Gate:** `bin/prime` green — 1143 runs, 3278 assertions, 0 failures, 0 errors,
0 skips (raised from 1134/3264 in the same commit, as CI's equality check
requires).

## The gap

billing publishes the fleet's money events — `billing.payment.succeeded`,
`billing.payment.failed`, `billing.subscription.started/updated/canceled` — and
courier, the fleet's only consumer, would mail about every one of them: a
receipt for a succeeded payment, a warning for a failed one, a confirmation for
a subscription change. **None of the payloads carried an address to mail to.**
courier has no billing client and no billing tables; the fleet's consumer design
(`REPORT-courier-consumer-invite-01.md` §2.6) is that a consumer acts on the
envelope or refuses, and never looks up. Every money event was a dead letter.

The parallel fact was already fixed on the identity side:
`identity.session.revoked` and `identity.user.created` carry a top-level `email`
precisely because the consumer cannot read it anywhere else. billing's events
predated that discipline. This packet gives them the same treatment.

## What the customer row actually held

**`customers.email` — a real, deliverability-validated, client-settable billing
address.** Read before assuming, per the brief:

- The column exists (`db/schema.rb`): `t.string "email"`, **nullable**.
- `Customer#email_is_deliverable` validates it against
  `URI::MailTo::EMAIL_REGEXP` when present — a malformed address is a 422 naming
  the field, not a stored lie.
- It is settable through the API: `PATCH /v1/customers/:id` permits `email`
  (`app/controllers/v1/customers_controller.rb`). A customer created through
  `/v1` has no email until the client sets one; that is why the column is
  nullable.
- It is **not** the account owner's email and not a fact identity publishes —
  it is billing's own field on the pay-gem customer row, which is the row a
  charge is billed to. That is the right address for a receipt: it is the
  address the customer gave to be billed.

So the recipient fact was honestly available, and the packet did not stop at the
diagnosis.

## What each event now carries

| event | new field | source | cost |
|---|---|---|---|
| `billing.payment.succeeded` | `email` | `customers.email`, resolved by the processor's customer id | one indexed lookup (see below) |
| `billing.payment.failed` | `email` | same | same |
| `billing.subscription.started` | `email`, `plan_name` | the customer and plan the lifecycle already resolves | none — both in hand |
| `billing.subscription.updated` | `email`, `plan_name` | same | none |
| `billing.subscription.canceled` | `email`, `plan_name` | same | none |

`billing.customer.created` already carried `email` (via `Customer#as_json`) and
is unchanged. `billing.plan.*` are the catalogue, not mail events, and are
unchanged.

**The field is named `email`**, matching identity's events — one fleet, one
field name for the address a consumer cannot look up.

**It is absent, never null**, when there is no address to carry: a customer
created in the processor's dashboard has no cafaye row, and a cafaye customer
created through `/v1` has no email until the client sets one. Both cases omit
the field rather than promising a mail the event cannot address — a consumer
refuses an unaddressable event by design, and that refusal is the honest
outcome. The same rule the normalizer applies to a field the processor did not
send.

### The one query, stated rather than hidden

The payment events' builder (`Webhooks::StripeEvents.payment_emission`) is a
pure mapping from the processor payload; it had no cafaye customer in hand.
Carrying the email costs **one indexed lookup on `customers.processor_customer_id`
(unique, partial — billing-13) per payment event**, in
`StripeEvents.with_recipient`. The webhook path is not a user-facing request
and the ingestion transaction already writes three rows; one more indexed read
against a unique column is noise beside them. It is here because the
alternative — a receipt event with no address — is the gap this packet exists
to close. The cost is stated in the builder's comment, not buried.

A failed payment records no charge, so the `Charges::Recorder`'s own customer
resolution cannot be the one the event relies on — the event's builder
resolves for itself. The subscription events cost nothing extra: the lifecycle
has already resolved the customer and the plan when it builds the payload.

**No plan name on the payment events, deliberately.** The payment builder does
not have the plan in hand, and a one-time Checkout charge has no plan at all —
adding the field there would cost a second lookup and still be absent on the
Checkout shape. The receipt's `description` (the processor's own line-item
text, on the `Charge`) already answers "what was this for" for the receipt
route; the event payload keeps the load-bearing facts (amount, currency,
invoice/payment ids).

## The gap to core, recorded not matched

core's payload schemas are closed with `additionalProperties: false` and do
not declare `email` or `plan_name` for any of the five affected types. core is
read-only from a service worktree, so the gap is recorded in
`PENDING_PAYLOAD_ALIGNMENT` (five new entries, asserted in both directions) and
as a DECISION NEEDED in `cafaye.yml` — the same recorded-not-matched mechanism
as the `entitlements` gap on the plan events, and for the same reason: the two
ways to make the contract test green without a core change are both the spec
moving without a decision. The contract test's corpus customer now carries an
email, because the payment payloads are built by resolving that row.

## What moved in the repository

- `app/services/webhooks/stripe_events.rb` — `with_recipient`, called from
  `payment_emission` so no call site can forget the field.
- `app/services/subscriptions/lifecycle.rb` — `email` and `plan_name` in
  `core_payload`, which all three subscription events share.
- `test/contract/outbox_envelope_contract_test.rb` — corpus email, and
  `PENDING_PAYLOAD_ALIGNMENT` gains the five entries.
- `test/services/webhooks/stripe_events_test.rb` — four tests: the field on a
  settled payment, on a failed one, and absent for a customer with no address
  and for an unknown customer.
- `test/services/subscriptions/lifecycle_test.rb` — five tests: the email and
  the plan name on a start, on an update, on a cancellation, and the absent-
  not-null edge.
- `test/tenant/account_entry_point_matrix_test.rb` — the new lookup classified
  (45 data accesses now, was 44), and `stripe_events.rb` moved off
  `NO_DATA_ACCESS`: a file that performs a read does not belong among the files
  that perform none.
- `cafaye.yml` — the DECISION NEEDED above.
- `.github/workflows/ci.yml` — `BASELINE_RUNS`/`BASELINE_ASSERTIONS` raised
  1134/3264 → 1143/3278 in the same commit, itemised per file, as the equality
  check requires.

**Nothing existing was weakened.** The one assertion that changed shape is the
lifecycle's exact-key-set pin, which grew to include the two new fields — the
test doing its job. No event's timing, type, or reason changed; only what they
carry.

## The first move for the courier consumer

courier subscribes to the five money events and reads one field: `data.email`.
If it is present, it mails — a receipt for `billing.payment.succeeded`, a
payment-failure warning for `billing.payment.failed` (the payload's
`attempt_count` and `next_payment_attempt` are the warning's body), a
confirmation for the subscription events (`plan_name`, `amount`-less but with
`currency` and the period). If it is absent, it refuses, which is the designed
behavior for a customer with no address on file. No billing client, no billing
tables, no lookup — the envelope is the whole contract, which is what makes it
work.

The one thing courier cannot do yet is validate the payload against core's
schemas: the five types are published in a shape core's closed schemas reject,
recorded in `PENDING_PAYLOAD_ALIGNMENT` until core lands the schema update. A
consumer that validates against core's current schemas would reject every
receipt event billing publishes. That is core's to fix, and the DECISION NEEDED
in `cafaye.yml` is the action item.
