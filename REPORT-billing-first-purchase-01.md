# REPORT — the account selector walk, and the first purchase it made possible

Date: 2026-10-16. Scope: parlor's BFF exchange, identity's session→token
exchange, billing's webhook normalizer. Walked on the launch stack
(`kit/launch`, project `kit-launch-billing`, real Stripe test mode) with all
ten services healthy.

## What was walked

1. The team-account selector: `GET /v1/plans`, `/v1/subscriptions`,
   `/v1/charges` through parlor's BFF with `x-account-id` naming each of the
   caller's two accounts. The same session token returned the personal
   account's two subscriptions and charges, and the team's empty lists. A
   stranger's uuid answered 404 (`No such account is visible to you.`), a
   malformed value 400 (`x-account-id is not an account id.`), both before
   billing was dialed.
2. A real $49 team checkout, paid with a test card in the browser. Stripe's
   hosted page carried our `cancel_url` with `account=` intact; the webhook
   wrote subscription `sub_1URCjPCmN780pAiWor6nCnGD` (active, 4900 USD) and
   charge `in_1URCjNCmN780pAiWMWoH0Bxd` with `account_id` = the team, and
   backfilled `cus_VS6x3l4EsHvbxt` onto the customer row through the
   `client_reference_id` the checkout session carried.
3. A brand-new account's first purchase (`launch-two`), driven through the
   browser end to end — plans → checkout → Stripe → paid. The receipt
   arrived in mailpit and the payment event carried
   `email: owner+launch@cafaye.local`, resolved by the cafaye id because the
   customer row had no `processor_customer_id` at event time.

## Defects the walk found, and their fixes

**1. billing's recipient lookup missed every first payment** (fixed here).
`StripeEvents.with_recipient` resolved the email by
`processor_customer_id` alone. On an account's first payment the row has no
processor id yet — Stripe creates its customer at the hosted checkout and
the id is written back by a later event — so the lookup missed exactly the
payment that opens the relationship, the receipt event went out unaddressed,
and courier refused it ten times then dropped it (measured: the $49 team
payment's `billing.payment.succeeded`). The fix resolves the customer the
way `Charges::Recorder` already did — cafaye id first, processor id second —
and the matrix row moved with the lookup. Proven red without the fix
(`test/services/webhooks/stripe_events_test.rb`, the
`invoice.paid.live-first-checkout` fixture).

**2. parlor's checkout could not make a first purchase at all** (fixed in
parlor). The screen required an existing billing customer and nothing ever
created one, so a new account could browse plans and then dead-end at "This
account has no billing customer yet". The screen now creates the customer
row (`POST /v1/customers`, owner from the token, `processor_customer_id`
left null for Stripe to fill in through the session's reference) with the
signed-in buyer's email, because billing sounds the address on the event
and courier refuses an address-less one. The client's `CustomerCreate` type
was stale (billing 2.0.0 has no `owner` in the body) and is corrected.

**3. the post-payment landing asked billing with no credential** (fixed in
parlor). A fresh page load — precisely the redirect back from Stripe — made
its first billing call during hydration, before the session token was read,
so billing answered 401 and the screen latched "Billing could not be
reached" over data that a later successful load had already fetched.
Measured: three requests for one screen, one unauthenticated. The screens
now wait for the session to be known (`useBillingReady`), an answered load
clears an earlier failure, and the client is memoized per token so provider
re-renders stop re-firing every load effect.

**4. the subscriptions → charges link dropped the account** (fixed in
parlor). "See every charge" pointed at `/billing/charges` without
`?account=`, so a team's page led to the personal account's money history
one click later. The link now preserves the location's search.

## Deferred, captured here so they are not lost

* PDF receipts (`prawn`) for the receipt route; today it is HTML.
* `quantity` threaded through `Processor::StripeClient#create_checkout_session`
  (the fake door has it; the Stripe path sends 1).
* Retention for `outbox_events` and `idempotency_keys` (no cron exists; both
  grow forever).
* Historic `Charge` backfill for payments recorded before the recorder
  landed (db/seeds or a rake task).
* courier: `billing.payment.failed` warning mail and subscription
  started/updated/canceled confirmations — wired consumer, copy undecided.
* The live-mode door: live Stripe keys and a dashboard webhook endpoint are
  the operator's to provide; the code path is the same one walked here.
