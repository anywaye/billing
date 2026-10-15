# REPORT — billing-e2e-01: the first charge, walked end to end

**Status: done, gated, committed.** The loop a stranger walks is one test in
the suite, not a script somebody ran once.

## What the drill is

`test/integration/first_charge_test.rb` — the whole service in one test, in
the order a customer experiences it:

```
plan with a processor price  ->  customer for an account
  -> POST /v1/checkouts       (the dev door: the subscription appears NOW)
  -> POST /v1/webhooks/stripe (a real fixture, signature verified)
  -> a charge row, the receipt, the projection, the entitlements
```

and the two things that make it a *service* rather than a demo: the
subscription is written by `Subscriptions::Lifecycle` on both paths — one
writer, one state machine, one outbox — and
`billing.subscription.started` is published exactly once.

## What it proved, and the three facts it found on the way

**1. The payment event's subject is the FIXTURE's subscription id, not the
checkout's.** `invoice.paid.json` names `sub_1PZQaBcDeFgHiJkLmNoPqR1`; the
fake door minted `sub_FAKE<random>` for the checkout's subscription. That is
the loop's honest shape rather than a defect: the charge resolves by the
processor's **customer** id — which both the fixture and this checkout's
customer carry — so a payment for a subscription row this service never saw
still records honestly, and the subject is what the processor said. The
subscription events and the payment events are joined by different keys on
purpose (`cafaye.yml`'s billing-04 subject decision): a consumer holding the
subscription event joins the payment event by the processor's id in the
payload, and the charge row is keyed by the processor's own charge id.

**2. The receipt renders no email and no account id.** The first draft of the
test asserted "buyer@example.com" on the receipt and failed. The receipt's
shape is the processor's description, the amount, the charge id and the
receipt's own id — it is addressed by being scoped, not by naming who is
looking at it. The assertion became a refutation: no email, no account.

**3. The checkout was deciding a status the processor already reports — and
the mutation that found it ran 0 failures.** `Checkout::Session#status_for`
re-derived `trialing` from `trial_ends_at` instead of reading the
subscription's own `status`. That is `AGENTS.md` (Subscriptions) — "this
service never decides what a subscription's status is" — being broken in the
dev door: the re-derivation reads as the same answer the processor gives,
until the day they disagree, and then this service's guess would be the one
recorded. The red-proof was the tell: substituting a `canceled` status into
the fake changed nothing, because nothing read the field. Status is now read
off the processor's answer, the fake's trial computation is load-bearing, and
the same mutation fails **12 tests and 2 errors**; the revert restores green.

## The loop's failure direction

The second test in the file is the half-applied checkout, because that is
the one defect that grants access nobody paid for: the account already holds
one live subscription on the plan, the door refuses, the existing row is
byte-identical, and the processor holds two subscriptions while this service
holds one — the honest two-sided state, asserted through the fake's ledger.

## What is deliberately not in the drill

- **No live Stripe.** The API double (`FakeStripeAPI`) answers the projection;
  the signature in the webhook leg is computed over the committed fixture's
  own bytes with a checked-in secret that is a credential for nothing. The
  real-Stripe test-mode leg is an operator's `stripe listen --forward-to`
  away, and the seam it goes through is the one this test exercises.
- **No gateway or identity.** The drill starts with a token minted the way
  every request spec mints one; the tenancy contradiction is its own packet's
  subject, not this loop's.

## Gate

`bundle exec rails test`: **1211 runs, 0 failures, 0 errors, 0 skips** (the
full suite; this test is +2 runs / +45 assertions in it). rubocop, brakeman,
bundler-audit all clean. The mutation above is the drill's red proof.
