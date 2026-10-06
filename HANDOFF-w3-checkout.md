# HANDOFF — W3 checkout (worker w3-checkout)

**Status: the packet's stated outcome is done, verified, and committed. Two things
are left undone on purpose and one number is unverified. Both are listed below.**

Branch `worker/w3-checkout`. Three commits, nothing pushed:

```
ef7f04a feat(deps): add the pay gem, and say why in the Gemfile
cdfd137 feat(checkout): a real checkout path on pay's FakeProcessor
129fe5c test(matrix,lint): classify the checkout path, and the counts that follow it
```

plus one uncommitted-at-the-time-of-writing changelog + CI-baseline commit; see
"Commits" below for the exact list.

---

## What the packet was for

`billing` had plans, customers and subscriptions, a webhook that records a
subscription, and **no way for a subscriber to start paying**. The brief decided
the dependency: the `pay` gem, for its `FakeProcessor` — a processor whose API is
the database, which is what makes a checkout path testable with no network, no
keys and no Stripe account.

## What is done and verified

**A checkout session is created and completed end to end against FakeProcessor,
and the subscription reflects it — verified, not assumed.**

`bundle exec rails test` — **1097 runs, 2798 assertions, 0 failures, 0 errors, 21
skips.** `bundle exec rubocop --parallel` — **135 files, no offenses.**

The 21 skips are the `test/contract/` tier, and they mean **there is no `core`
checkout in this worktree** (`AGENTS.md`, "The tier that skips without you
noticing"). That is not a pass-with-less-done claim: it is the documented
behaviour of this tier without `CORE_PATH`, and it is why the CI baseline below is
flagged as unverified.

`test/services/checkout/session_test.rb` — 16 runs, 68 assertions, **all passing**:

| what is held | test |
|---|---|
| completion records a live `active` subscription on the subscriber's plan | `a completed checkout records a live subscription…` |
| the price is read back off the plan as integer minor units + currency | `the recorded subscription is priced by the plan it was bought on` |
| the row is keyed by the processor's own subscription id (the delivery-path join) | `the recorded subscription is keyed by…` |
| `billing.subscription.started` is published **once**, with no `processor_event_id` | `a completed checkout publishes…` |
| per-seat `quantity` reaches the processor and the event | `a checkout buys the quantity it was asked for` |
| a trial starts `trialing` and records `trial_ends_at` | `a plan with a trial…` |
| a **zero**-day trial does not become a trial | `a plan with no trial starts active…` |

### The negative case, which the brief said matters more

**Six tests**, and they are more assertions than the happy path:

- a withdrawn plan → `plan_not_on_sale`, `Subscription.count == 0`, and the
  processor was never asked
- a plan with **no** `processor_price_id` → refused, and nothing was asked of the
  processor either — a checkout cannot invent a price
- a `User`-owned customer → `customer_not_an_account`, because a subscription is
  billed to an account
- **a refused checkout leaves an existing `active` subscription byte-identical**
  (`status`, `plan_id`, `customer_id`, `processor_subscription_id`, `updated_at`)
- a processor that raises → `processor_refused`, nothing written
- a second checkout on the same live plan → `subscription_refused:already_subscribed`,
  and the honest state is reported: the processor holds **two** subscriptions and
  this service holds **one**

Plus `every path out of complete is an Outcome, so a failure cannot be
half-handled`, which asserts the *shape* of the return rather than three
individual facts, and `the checkout path makes no network call`, which stubs
`Socket.new` and `Net::HTTP` for the duration of a real checkout.

### The design constraint that shaped it

**`Subscriptions::Lifecycle` is still the only writer of a `Subscription`.**
Completion builds the same normalised delivery a webhook would carry and hands it
to the lifecycle, so there is one state machine, one `Refused` vocabulary, one
`account_mismatch` guard and one answer to "what is this subscription's status".
A checkout that wrote the row itself would grant entitlements the moment the
*request* was accepted — the direction that costs money.

And **the processor is asked first, the row is written second**, so on the failure
path nothing was ever written. That is why the negative tests assert the
subscription did not move rather than that it moved back.

## Two findings, both measured

**1. `pay`'s own migration created `pay_customers.owner_id` as a bigint.**
`1_create_pay_tables.pay.rb` reads its key type from
`Rails.configuration.generators.options[:orm][:primary_key_type]`, which this
service does not set, and falls back to `:bigint`. Every uuid owner was cast:

```
Pay::Customer.pluck(:id, :owner_type, :owner_id)
# => [[29, "Customer", 0]]
```

All subscribers onto one row, with nothing raising. `20261006030000_pay_owner_ids_are_uuids`
changes both owner columns. This cost roughly 20 minutes of the hour and was worth
every one of them: without it the happy path "works" in a smoke script and is
silently wrong in production.

**2. `subscriptions_live_account_plan_idx` refuses the second live checkout as
`ActiveRecord::RecordNotUnique`, not as a `Subscriptions::Refused`.** So the
caller is written against the **outcome**, not against a named constraint — the
same shape `AGENTS.md` (Webhooks in) already records for the outbox index, where
"either a validation or an index may win the race".

## What is half-done, and why

**1. There is no HTTP route for checkout.** `POST /v1/checkouts` does not exist;
`Checkout::Session` is a service call. It is not in the brief's "Done means" list,
and adding it properly costs an `openapi/v1.yaml` operation + `operationId`, an
`info.version` bump, a `config/routes.rb` line, a
`test/contract/http_surface_contract_test.rb` entry, and a
`test/contract/tenant_isolation_matrix_test.rb` verdict — which is the better part
of an hour than it had left. **The successor should treat this as the next
packet**, and should settle the scoping question first: a checkout is written
*for an account* and must be resolved through `Customer.for_account`, or it is the
cross-tenant write that billing-13 closed.

**2. `pay`'s routes and mailers are switched off, not integrated.**
`config/initializers/pay.rb` sets `automount_routes = false`,
`enabled_processors = []` and `send_emails = false`. Each line is a refusal and
each is commented. The consequence to know: **`Processor::StripeClient` is still
this service's only Stripe path** and `pay` is not wired to it. Adding a live
processor means reconciling two Stripe clients, which is a decision, not a
config flip — and is explicitly a later packet per the brief.

**3. `BASELINE_RUNS`/`BASELINE_ASSERTIONS` are raised on a computed delta, not a
measured total.** Raised `1078/3082` → `1095/3157`; the delta (`+17` runs,
`+75` assertions, from the two files run on their own before and after) is exact,
but the **total** could not be measured because `core` is not on disk. If `gate`
fails on a different pair, this commit is wrong about arithmetic — fix the two
numbers in `.github/workflows/ci.yml`, nothing else.

## Currently-failing command

**None.** The full suite and the linter both pass, quoted above with their real
output. There is no red command to hand over.

The one thing that *would* fail here is the contract tier, and it fails by
**skipping**: 19 tests in `test/contract/` print
`skip("core is not on disk; set CORE_PATH to …")`. Fix by putting `core` beside
this worktree or setting `CORE_PATH`.

## What I deliberately did NOT do, and why

- **No live processor, no Stripe wiring.** The brief says so, and the reason
  survives the brief: a second Stripe client beside `Processor::StripeClient` is a
  decision nobody has made.
- **No HTTP route.** Above. The right place for it is a packet that can also
  answer "is a checkout account-scoped?", not one squeezed into the last minutes.
- **No `CheckoutSession` table.** A checkout is a request and its result, not a
  row somebody looks up later. A table here would be a second answer to "what is
  this subscriber's subscription?" next to the one `subscriptions` already gives.
- **No `current_period_start`/`_end`.** `FakeProcessor` publishes no period, and
  deriving one from `Plan#interval` would be this service inventing a billing
  period the processor never stated.
- **No new event type.** Checkout publishes `billing.subscription.started`, which
  is already in `OutboxEvent::TYPES`, `cafaye.yml` and core's catalog. Inventing
  a `billing.checkout.*` type would fail the contract tier for exactly the reason
  `AGENTS.md` says it should.
- **No `Charge`/receipt handling, no proration, no seat sync.** Not in this
  packet, and each is a downstream feature with its own brief.
- **No `config.generators.orm.active_record.primary_key_type`.** It would have
  fixed the uuid bug in one line but changes key types for every *generated*
  migration in the service — a much larger claim than this packet needs to make.
- **No repository-wide cleanup**, and no attempt to touch
  `docker-compose.yml`.

## Decisions, and why

- **`complete` returns an `Outcome`; there is no `Checkout::Refused`.**
  `Subscriptions::Refused` exists because a *verified processor event* could not
  be applied and the webhook must record the reason and answer 200. A checkout is
  a request with no delivery row and no retry. An exception is the easiest way to
  lose the negative case, so there is no exception.
- **A refused checkout does not cancel the processor's subscription.** It is the
  processor's record of what the customer agreed to; this service did not create
  it and cannot delete it. The honest state is "the processor has one and we do
  not", which is what the failure reports and what the test asserts.
- **No `processor_event_id` on a start payload.** The outbox's partial unique index
  is over `((data ->> 'processor_event_id'))` where present; a key here would make
  a start compete with deliveries for an index over a value that is not an event
  id. A checkout is not an event.
- **The reader for the processor customer is `customer.payment_processor` with an
  association fallback, and both halves are load-bearing.** `pay`'s reader creates
  the first `Pay::Customer` and decides which one this subscriber has; it ends in
  `reload_payment_processor`, whose return value is not the record, so it returns
  `nil` on a first checkout with the row written. It also drops the `has_one`
  reader's `force_reload` argument. Reaching past it straight to the association
  finds nothing on a first checkout, because nothing had created it. Both of these
  cost me a red test each; the comments are in `Checkout::Session#processor_customer`.

## Successor's first move

1. `cd /Users/kaka/Code/any/wt/billing-w3-checkout && bundle exec rails test` —
   expect **1097 runs / 2798 assertions / 0 failures / 21 skips**. The 21 skips
   are `core` being absent; that is the whole difference from CI's numbers.
2. Confirm `gate`'s baseline. If `.github/workflows/ci.yml`'s
   `BASELINE_RUNS`/`BASELINE_ASSERTIONS` disagree with the run, fix those two
   numbers and nothing else.
3. Then, for the next packet: `POST /v1/checkouts`, resolved through
   `Customer.for_account(token.account_id)` so a checkout can only ever be made
   for the caller's own account, with an `openapi/v1.yaml` operation, an
   `operationId`, an `info.version` bump, and entries in both the HTTP surface
   contract test and the tenant isolation matrix.