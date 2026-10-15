# REPORT — billing-fake-client-01: `pay` leaves, the fake moves in-house

**Status: done, g green, committed.** Branch `master`, two commits: the seam swap, then the gem's exit.

## What the packet was for

User directive, 2026-10-15: lift the `LAUNCH.md` freeze for billing (recorded in
`moon/LAUNCH.md` and `moon/FEATURE-PARITY.md`) and finish the service to first
charge. The first decision: **drop `pay` entirely** rather than keep it for
`FakeProcessor` or adopt it for production Stripe.

## The claim it rests on, and the evidence

**Billing's processor surface is one seam with two clients, and the fake has no
tables.** The checkout path never touches a network, a gem or a payment
processor; production Stripe remains `Processor::StripeClient`'s three methods
with no other `Stripe::` call in the repository.

Measured on this tree, `bin/prime`'s own steps on the shared cluster
(`cafaye-postgres-1`, port 15500, database `billing_test`):

| step | result |
|---|---|
| `bundle exec rails test` | **1176 runs, 3756 assertions, 0 failures, 0 errors, 0 skips** |
| `bundle exec rubocop --parallel` | **150 files inspected, no offenses detected** |
| `bundle exec brakeman --no-pager --quiet --exit-on-warn` | **No warnings found** |
| `bundle exec bundler-audit check --update` | **No vulnerabilities found** (1263 advisories, db updated 2026-10-10) |

## What changed

| before (`pay`) | after (`Processor::FakeClient`) |
|---|---|
| `Pay::FakeProcessor` writes six Active Record tables (`pay_customers`, `pay_subscriptions`, `pay_charges`, `pay_payment_methods`, `pay_merchants`, `pay_webhooks`) | one plain Ruby object; `subscribe` returns a frozen `ProcessorSubscription` value |
| `Customer#pay_customer` macro + `payment_processor` association reader, with the two-halves load-bearing read (`reload_payment_processor` returns nil on a first checkout) | nothing; the processor customer id is derived (`cus_fake_<customer id>`), never stored |
| `Outcome#pay_subscription` | `Outcome#processor_subscription` |
| `gem "pay", "~> 12.2"`; `config/initializers/pay.rb` (three refusals: no processors, no routes, no mailers) | gone; nothing to configure because nothing boots |
| four pay migrations, two calling `Pay::Adapter.json_column_type` and one calling `Pay::Customer.find_each` | deleted beside `20261015120000_drop_pay_tables.rb` (`if_exists: true`, irreversible down) |
| rescue `Pay::Error, ActiveRecord::RecordInvalid` in `subscribe` | rescue `Processor::Error` alone — the fake writes no rows, so a `RecordInvalid` escaping it would be this service's bug and must not be reported as a declined card |

**The 16 checkout specs were retargeted, not replaced** — same names, same
invariants, same negative-first shape. What changed is what they verify
*against*: `NeverAskedProcessor` and `RaisingProcessor` are constructed rather
than stubbed by singleton, and the two "nothing was asked of the processor"
assertions moved from `pay_customers.count` (the gem's own table) to the seam
(`assert_empty Processor::FakeClient.subscriptions` plus a processor that
raises if reached).

**`ProcessorSubscription`, not `Subscription`, and the reason is not
decoration.** A class named `Subscription` in this namespace would shadow the
model for every reader of the file. It is also the same distinction
`Charge`-versus-processor's-charge already makes in this service, stated once.

## Three things worth knowing before touching the checkout path

1. **The trial guard is proved at the request, not at the answer — and that was
   a real gap, found by mutation.** The fake carries its own internal guard, so
   breaking the `Session`'s guard left every assertion about the resulting
   subscription green while the request still carried `trial_period_days: 0`.
   The mutation confessed it: `plan.trial_days.to_i.positive? ? {…} : {}` →
   `{ trial_period_days: plan.trial_days }` ran 17 runs, 0 failures. The fix is
   `RecordingProcessor` (a wrapper around the real fake that keeps the kwargs it
   was handed) and two specs: the key is **absent** when there is no trial, and
   present and correct when there is. The same mutation now fails exactly
   `test_a_plan_with_no_trial_starts_active_rather_than_trialing`, and the
   revert restores green. **A guard the fake would have silently honoured
   anyway is a guard a real processor would not.**

2. **The tenant matrix caught a new data-access site, by name, and that is the
   matrix working.** `test/tenant/account_entry_point_matrix_test.rb` derives
   every access in `app/` and refused the new file's `Subscription.new`:
   `test_every_data_access_in_app_is_an_account-scoped_entry_point` failed
   naming `app/services/processor/fake_client.rb#subscribe (Subscription.new,
   write)`. Resolution: classify the file in `NO_DATA_ACCESS` with its reason
   (a frozen value, not the `subscriptions` table) — through the test, not
   around it — and rename the value to `ProcessorSubscription`, which removes
   the ambiguity permanently.

3. **Both floors in `gate.yml` were stale, and this packet raised them by
   measurement** — the fourth and fifth instances of the shape the file itself
   records: `lint` 142 → 150 (the truth had been 153; this packet's net is -3
   files) and `suite` 1134 → 1176 (the truth had been 1175 since the
   core-location packet; +1 run here is the request-level trial spec). CI's
   `BASELINE_RUNS`/`BASELINE_ASSERTIONS` moved with them in the same commits.
   A floor never blocks a merge, so every packet that lands invalidates one
   silently; the numbers are raised in the same commit as the measurement that
   replaces them.

## What this packet did not do

- **No VCR.** Nothing in this suite hits an API: the checkout path's network
  refusal is asserted by stubbing `Socket.new`/`Net::HTTP` (17 runs), and
  `Processor::StripeClient`'s specs drive `FakeStripeAPI` and assert on the
  arguments *built* through the injectable `api:` seam. VCR belongs in the
  packet that first needs real processor bytes — the E2E drill — and not here.
- **No live processor.** `pay`'s adapters were never enabled
  (`enabled_processors = []` was the whole configuration), and this packet adds
  none. A second processor is `Processor::PaddleClient` with the same three
  call shapes plus its own `/v1/webhooks/paddle` controller; `Lifecycle`, the
  outbox and the tenancy scopes are unchanged by that.
- **No pay tables in any deployed database, because no deployed database
  exists.** Billing has never shipped: no chart, no Argo `Application`, no host.
  The drop migration's `if_exists: true` makes it a no-op on a fresh prepare
  and a real drop on a local database; the `schema_migrations` rows the deleted
  migrations left behind are inert because Rails reads the tree, not the rows.
- **`POST /v1/checkouts` is still not a route.** That is the next packet.
