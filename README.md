# billing

`billing` is the cafaye service that owns money: plans, customers, subscriptions,
prepaid credit, usage metering, and webhooks coming in from a payment processor.
Every other cafaye service that charges someone — `parlor` at checkout, `muse`
when it meters a completion — accounts through this one.

**v0 is customers, plans, the subscription lifecycle and the Stripe webhook.** The
schema, the models, the `/v1` API and the transactional outbox exist and are
tested, a processor's signed event can be received, stored once, and turned into
one of this service's own events, and a customer can subscribe, move between
plans and be cancelled.

**This service now talks to Stripe, in exactly three ways.** `processor`,
`processor_product_id` and `processor_price_id` were all null in practice while it
only received; buying a plan, cancelling one and moving one are requests to the
processor, and a lifecycle that cannot make them is not a lifecycle. Every request
is one of the three methods on `Processor::StripeClient` and there is no other
`Stripe::` call in the repository — a claim that is checked by reading one file
rather than by trusting a sentence. No new dependency: the `stripe` gem was
already here for `Stripe::Webhook.construct_event`.

**A subscription's status is never decided by a request.** `POST
/v1/subscriptions` returns a Checkout URL and writes nothing; cancelling and
changing a plan ask the processor and return the row unchanged. The row moves when
`customer.subscription.*` arrives, and `billing.subscription.started` /
`.updated` / `.canceled` are published in the same transaction as that move.

```sh
$ curl -s localhost:3000/healthz
{"status":"ok"}

$ curl -s localhost:3000/readyz
{"status":"ok","checks":{"database":"ok"}}

$ curl -s -H "Authorization: Bearer $TOKEN" localhost:3000/v1/plans/pro-monthly
{"id":"…","name":"Pro monthly","slug":"pro-monthly","processor_product_id":null,
 "processor_price_id":null,"price":{"amount_minor":1900,"currency":"USD"},
 "interval":"month","trial_days":0,"active":true,"created_at":"…","updated_at":"…"}
```

and, when PostgreSQL is unreachable, `/readyz` answers
`503 {"status":"error","checks":{"database":"error"}}`.

## Money

`app/models/money.rb` is the seed of the platform-wide rule that money is
**integer minor units** and never a Float (`PLAN.md` §3). It is a frozen value
object: an integer amount, an ISO 4217 currency, and arithmetic that refuses
rather than guesses.

```ruby
Money.new(1050, "USD")                      #=> #<Money 10.50 USD>
Money.from_major("10.50", "usd")            #=> #<Money 10.50 USD>
Money.new(1050, "USD") + Money.new(50, "USD") #=> #<Money 11.00 USD>
Money.new(1050, "USD") * 3                  #=> #<Money 31.50 USD>
Money.new(1050, "USD").to_h                  #=> {"amount_minor"=>1050, "currency"=>"USD"}
```

What it will not do, and why each refusal is deliberate:

```ruby
Money.new(10.5, "USD")            #=> raises Money::InvalidAmountError
Money.from_major("10.505", "USD") #=> raises: would have to round
Money.from_major("10.5", "JPY")   #=> raises: JPY has no minor unit
Money.new(1, "USD") + Money.new(1, "EUR") #=> raises Money::CurrencyMismatchError
Money.new(2**63, "USD")           #=> raises Money::OverflowError
Money.new(100, "USD") - Money.new(250, "USD") #=> raises: a negative by subtraction
```

A Float cannot represent `0.10`, so it never carries an amount. Rounding is
never silent, because a rounded price is a bug that surfaces in somebody's
invoice. Mixing currencies is an error, because FX is a pricing decision rather
than an arithmetic one. Currencies whose minor unit is not `10^-2` — JPY and
KRW at zero decimals, KWD and the Gulf dinars at three — carry their real ISO
4217 exponent, which is the case a two-decimal assumption corrupts quietly.

The class comment has the reasoning in full; `AGENTS.md` has the rules.

### The wire

A price crosses the API as minor units and an integer, and nothing else:

```json
{ "price": { "amount_minor": 1900, "currency": "USD" } }
```

`{"amount_minor": 19.00}` and `{"amount_minor": "19.00"}` are both `422`. The
first has already lost the fact that it was nineteen dollars exactly; the second
would mean this API has two representations for an amount. `Plan#price` returns
a `Money` and `Plan#price=` accepts only a `Money`, so no code path writes
`amount_cents` without also writing the currency beside it.

The event payloads use the same representation, so an event and a response can
never disagree about what something costs.

### The only place this service compares two prices

`Subscriptions::PlanChange` decides when a move to a different plan takes effect,
and **the only arithmetic in it is a comparison of two `Money` values.** There is
no credit, no refund, no prorated figure and no annualisation in that file, and
the specs assert the absence of the keys that would carry one.

> **A more expensive plan takes effect immediately** and the processor bills the
> difference (`proration_behavior: always_invoice`). The customer asked for more
> service, and delivering it at the end of the period would mean they used it for
> free in between.
>
> **A cheaper or equally priced plan takes effect at the end of the current
> period**, with nothing carried forward (`proration_behavior: none`). Nobody is
> refunded for a plan they are already leaving, and a credit computed here would
> be a figure this service did not keep.

Two comparisons are refused rather than guessed. Different **currencies**, because
FX is a pricing decision and `Money` will not compare across them. Different
**intervals**, because ten dollars a month against a hundred a year is not a
cheaper plan — it is a different unit, and multiplying one by twelve to compare
them is computing money nobody asked for.

Cancelling asks the processor for no refund and no proration at all, for the same
reason: the credit for three unused weeks is the processor's to compute.

`app/services/subscriptions/plan_change.rb` is held to 100% line and branch
coverage along with `money.rb`; see [Tests](#tests).

## API

`openapi/v1.yaml` is the contract. It is written against core's
`docs/openapi-conventions.md`, which is where the rules below come from.

| | |
| --- | --- |
| `POST /v1/customers` · `GET /v1/customers` | create and page through customers |
| `GET /v1/customers/:id` · `PATCH /v1/customers/:id` | read and update by uuid |
| `POST /v1/plans` · `GET /v1/plans` | create and page through plans |
| `GET /v1/plans/:slug` | read by the public handle |
| `PATCH /v1/plans/:id` | write by uuid |
| `POST /v1/subscriptions` | start one: a Checkout URL, not a subscription |
| `GET /v1/subscriptions` · `GET /v1/subscriptions/:id` | page and read |
| `POST /v1/subscriptions/:id/cancel` | ask the processor to cancel |
| `POST /v1/subscriptions/:id/change_plan` | ask the processor to move it |
| `GET /v1/subscriptions/:id/entitlements` | what the plan grants, right now |
| `GET /v1/charges/:id` | the receipt for one charge, as HTML, scoped by the token's account |

The plans asymmetry is deliberate: a slug can be changed by the very request
being made, and a mutable handle is not a safe thing to address a mutation by.
Each endpoint answers 404 for the other's identifier.

**The table is the whole surface, and a test says so.** `PUT /v1/customers/:id`
is not in it and is not served: an update here is a partial update — every field
optional, `owner` and `processor` not updatable at all — so there is no
whole-resource replacement behind a `PUT` to describe. `test/contract/http_surface_contract_test.rb`
compares the document and `config/routes.rb` as sets of `(method, path)` in both
directions, so an operation in one and not the other fails by name.

**None of the subscription endpoints decides a subscription's state.** `POST
/v1/subscriptions` writes nothing — a subscription does not exist until the
payment completes, and a row for one that does not would be a sixth status
meaning "we asked", which is a state no processor can report — so the 201 carries
the session and no `Location`. Cancelling and changing a plan return the row
*unchanged*, because a response claiming the cancellation had happened would be a
lie about a state this service does not own. The row moves when the processor's
webhook says it did, and the matching event is published in the same transaction.

`change_plan` is the one exception and says why: its response also carries
`plan_change`, saying whether the move takes effect `immediately` or at
`period_end`. That is the timing rule — **an upgrade is invoiced now, a downgrade
or a lateral move lands at the renewal** — and without it a client would have no
way to tell a caller that a downgrade is scheduled rather than applied. It is not
state; the subscription's own fields have not moved.

**Every `/v1` operation requires a bearer token, and every customer and
subscription operation is scoped by the account it names.** Two environment
variables, `BILLING_IDENTITY_ISSUER` and `BILLING_IDENTITY_AUDIENCE`, are what a
deployment sets; the token is an RS256 JWT from `identity`, verified locally
against the published JWKS at `{issuer}/.well-known/jwks.json` and cached by `kid`
for five minutes.

| | |
| --- | --- |
| no token, or one this service refused | **401** `unauthorized` — one fixed body, so which of signature / expiry / issuer / audience was wrong is not something a caller learns by trying |
| no issuer or audience configured, or `identity` unreachable | **503** `unavailable` — ours, not the caller's; a 401 here would tell someone holding a valid token to go and rotate it |
| another account's resource | **404** — the same answer a uuid that names nothing gets. Never a 403. |

**An unconfigured deployment is locked, not open.** Every `/v1` request answers 503
when no issuer is configured. That is the property the whole thing exists to hold:
a self-hosted billing API whose authentication quietly degrades open because nobody
filled in an environment variable is the failure it prevents, and the direction that
matters is the one that refuses.

Three consequences worth stating plainly, because they are breaking:

- `GET /v1/customers` and `GET /v1/subscriptions` return **this account's** rows.
- `POST /v1/customers` **ignores `owner_type`/`owner_id` in the body**. The owner is
  the token's account. A `User`-owned customer is therefore no longer creatable
  through `/v1`: which account a user belongs to is identity's fact, no event
  carrying it is in this build's `consumes`, and a row with no tenant has nobody to
  scope it to.
- **`Idempotency-Key` is scoped to the caller's `sub`** as well as to the endpoint.
  Two tenants choosing the same uuid no longer share one namespace, so a replay
  cannot return another caller's stored response.

`/v1/webhooks/stripe` is not part of this. Its sender is a payment processor and it
authenticates by signature over the raw body; it declares `security: []` and must
never grow a token check, because a `Bearer` there would be a second, weaker trust
path to the same door. That is structural rather than a convention — the token check
is a filter on the `/v1` client base controller, which the webhook controller does not
inherit from — and `test/authentication/principal_lock_test.rb` reads the boundary
from the router's own table rather than from this paragraph.

### Breaking change

`openapi/v1.yaml` is at **2.0.0** and the prefix is still `/v1`. That is a judgement
call and it is recorded rather than made quietly. Core's rule is that a breaking
change gets a new prefix *beside* the old one, so the old contract keeps being
served — and that is exactly what cannot be done here: the old `/v1` answers every
request without a token, so "keep serving `/v1` for compatibility" is "keep the
vulnerability", and a second prefix over one open door is one open door. The major
bump plus this note is the signal instead, and `info.version` is what every client
generator reads.

Errors are `application/problem+json` — RFC 9457 with core's extensions, built
in one place (`app/lib/problem.rb`) so no controller can invent its own:

```json
{
  "type": "https://errors.cafaye.com/validation_failed",
  "title": "Validation failed",
  "status": 422,
  "detail": "slug can't be blank; price must be an object with an integer amount_minor and a three-letter currency",
  "instance": "/v1/plans",
  "code": "validation_failed",
  "trace_id": "0af7651916cd43dd8448eb211c80319c",
  "errors": [ { "field": "price", "code": "invalid_format" } ]
}
```

`X-Trace-Id` is on every response and repeated in the body of every error.
Collections are cursor-paged (`data` + `page`, default 25, capped at 100, cursors
expire after 24 hours). `POST` accepts `Idempotency-Key`; a replay with the same
body returns the original response with `Idempotency-Replayed: true`, and a
replay with a different body is a `409`. A duplicate customer or slug is a `409`
rather than a `422`: the request was well-formed, it just collides.

## Events

Eight events, all three-segment and prefixed with this service's own name, as
core v0.2 requires. Three come from the models, five from the processor:

| Type | Subject | When |
| --- | --- | --- |
| `billing.customer.created` | the customer | a customer is created |
| `billing.plan.created` | the plan | a plan becomes billable |
| `billing.plan.updated` | the plan | a plan changes |
| `billing.subscription.started` | the subscription | a subscription became active, or started on a trial |
| `billing.subscription.updated` | the subscription | the subscription is still live and something about it changed |
| `billing.subscription.canceled` | the subscription | a cancellation **took effect** |
| `billing.payment.succeeded` | the payment | a charge settled |
| `billing.payment.failed` | the payment | a charge was declined or errored |

They are written to `outbox_events` **in the same transaction** as the change
they describe — from `after_create`/`after_update` for the three model events,
and for the five processor events in the same transaction that marks the delivery
finished and, for the three subscription events, writes the subscription row.
Never `after_commit`, and never a background job: a separate transaction is a
window in which the database says the thing happened and the event does not. A
rollback takes the event with it. The column list is core's contract
(`core: docs/event-outbox.md`); `id` is the envelope's `id`, generated before the
insert so a republish is the same id.

`billing.plan.updated` is emitted only when a field actually changed. A `PATCH`
that sets a field to the value it already holds is not a state change, and an
event that says otherwise teaches a consumer to expect updates that carry no
update.

### The subscription events do not map one-to-one

**The three cafaye types are chosen from what a delivery did to the row**, not
from which processor event carried it. That is what makes out-of-order delivery
safe, and it is worth spelling out because a reader looking for a mapping table
will not find one:

| Delivery | The row | Published |
| --- | --- | --- |
| `customer.subscription.created` | did not exist, is live | `…started` |
| `customer.subscription.updated` | existed, still live, something changed | `…updated` |
| `customer.subscription.updated` | existed, is now canceled | `…canceled` |
| `customer.subscription.deleted` | existed, is now canceled | `…canceled` |
| `customer.subscription.deleted` | **did not exist** | `…canceled`, and a canceled row |
| `customer.subscription.created` | **existed and is canceled** | nothing — refused |
| any | reported a state it already holds | nothing — refused |
| any | cannot be attached to a customer and a plan of ours | nothing — refused |

The two bold rows are the ones that make the table worth having.

A deletion that arrives *before* its own creation is the only statement about
that subscription that has arrived, and dropping it would leave an **active**
subscription row — and an active row grants entitlements — for something the
processor says is gone. So it is kept, as a canceled row that grants nothing, and
the creation that follows is refused because `canceled` is terminal. billing-03b
published both events and left the active row; that was the bug this fixes.

A refusal is recorded on the delivery row with its reason and answered 200. The
reasons are `unknown_customer`, `unknown_plan`, `no_subscription_to_update`,
`canceled_is_terminal`, `no_change_to_record`, `stale_delivery` and
`account_mismatch`, and "we refused this" is a query rather than an absence.
`account_mismatch` is the only one about **tenancy** rather than about the row's
own shape: a delivery naming a customer on a *different* account than the row is
on is refused rather than applied, so a subscription cannot be moved between
accounts by a delivery. See `REPORT-billing-13-fixes.md`.

There is deliberately no `billing.customer.updated`: core's catalog has no row
for it, and a service that publishes a type the catalog does not list is a
service whose manifest is lying. The API can still change a customer's email
and nothing downstream is told. That gap belongs to whoever owns the catalog.

## Webhooks in

`POST /v1/webhooks/stripe` receives Stripe's events and applies them. It is the
only place a subscription's state changes.

**The signature is checked against the raw bytes.** `Stripe::Webhook.construct_event`
over `request.raw_post`, never over a re-serialized parse. A body that does not
verify is refused with a 400 and **stored nowhere**: an unverified payload is not
an event, and writing one would put an attacker's JSON in the row a human reads
when something is wrong.

**A replay is a non-event.** Delivery is at-least-once, so the same event id will
arrive again — immediately, or a day later. `processor_webhooks.stripe_event_id`
is `UNIQUE`, and that index is the correctness mechanism rather than a query aid:
two concurrent deliveries of one event produce one row, one `processed_at`, and
one `billing.payment.succeeded`. The outbox row and the marking are a single
commit, so a process that died between them cannot leave an event published with
a row that still looks unfinished.

**The processor's own timestamp is the event's `time`**, not the moment this
service received it. That is what makes an out-of-order delivery detectable: two
events stamped on arrival would appear to have happened in the order they
arrived.

```json
{ "id": "evt_1PZQaBcDeFgHiJkLmNoPqR4", "type": "invoice.paid", "data": { "object": { "amount_paid": 8700, "currency": "usd" } } }
```

```json
{ "type": "billing.payment.succeeded", "subject": "sub_1PZQaBcDeFgHiJkLmNoPqR1",
  "data": { "kind": "payment", "amount": { "amount_minor": 8700, "currency": "USD" },
            "processor": "stripe", "processor_event_id": "evt_1PZQaBcDeFgHiJkLmNoPqR4" } }
```

The processor's shape stops at the normalizer. Everything downstream is
snake_case with integer minor units, and nothing that has not been sent is
defaulted — a webhook payload is the weakest input in the system, and a default
that silently fills a gap is how a customer ends up on a plan nobody charged
them for.

core now ships a payload schema for **all eight** of these types. The three
subscription events **do not satisfy theirs**: core's D10 rewrote those schemas
on the grounds that billing has no subscriptions table, which was true when core
read billing-03b and stopped being true when billing-04 added one. They are
recorded as a known issue below rather than matched, because matching core would
mean either dropping `plan_id` and `account_id` — the two fields that make a
subscription event actionable — or publishing a shape no consumer has agreed to.
`test/contract/` fails the day core settles it, in either direction.

**Every terminal outcome is a 200.** A replay, an event type this build has no
mapping for, a type it deliberately ignores (`ping`; a subscription-mode
Checkout session, which restates `customer.subscription.created`), and an event
whose mapping raised are all recorded and all answered 200. A 5xx would teach
Stripe to retry a decision this service has already made and would hide a parked
row behind a timeout. `processor_webhooks.error` is the record:

| `error` | Meaning |
| --- | --- |
| `NULL` | the event became an event |
| `ignored:<reason>` | understood, deliberately not acted on |
| `failed:<class>: <message>` | parked for a human |

A 503 rather than a 400 is the answer when no signing secret is configured: that
is this service's misconfiguration, and telling Stripe its signature was bad
would send an operator looking in the wrong place. The cause is logged; the body
says only `unavailable`.

**A subscription event also writes the subscription.** `Subscriptions::Lifecycle`
is the only writer of that table and the only thing that emits its events, and it
runs inside the transaction that marks the delivery finished — so the row, the
event and the receipt commit or roll back together. The handler is handed the
processor's own event time as well as the payload, so the event's `time` and the
payload's `started_at` are one instant read once rather than two readings that
could drift.

**A payment event also writes a charge, when money moved.** `Webhooks::Charges::Recorder`
is the only writer of the `charges` table, and it runs in the same transaction for
the same reason: a receipt committed separately from the `billing.payment.succeeded`
event that describes it is a receipt a consumer was never told about. The
processor's own `paid` and `amount` are the only things consulted — a failed, zero
or negative settlement records nothing, and the event is still published. The
receipt is read back through `GET /v1/charges/:id`, scoped by the token's account.

Nothing here is token-authenticated, and nothing here may become so — the sender
is a processor, not a cafaye client. A `Bearer` on this path would be a second,
weaker trust path to the same door.

## Known gaps

Written down rather than hidden. Each one is a decision this packet did not get
to make, not an oversight.

- **Authentication is on; authorization is one claim wide.** Every `/v1` request
  carries a verified principal and every customer and subscription query is scoped
  by the account in its token, so no caller reaches another account's row. Nothing
  narrower than that is checked. There is no capability model — no
  `plans:write` scope, no per-account plan override, no distinction between an
  account's member and its owner — because billing has no scope vocabulary to check
  against, and a scope invented here would be a scope nothing else in the fleet
  grants. **The one place that bites is the plan catalogue's writes**: any
  authenticated account may create, change or delete a platform-wide plan, because
  plans are the fleet's catalogue and not an account's. `Principal#scope_set`
  parses the token's `scope` claim and nothing reads it yet. Closing this is a
  decision about what a plan write is for, not a missing line, and it is recorded
  as a DECISION NEEDED in `cafaye.yml`.
- **Plans are not account-scoped, deliberately.** `GET /v1/plans` returns the whole
  catalogue to any authenticated caller. A plan is a price every account can
  subscribe to, so scoping the listing to one account's rows would return an empty
  collection to a caller who has subscribed to nothing — a real 404-shaped wrong
  answer rather than an open door. `test/contract/tenant_isolation_matrix_test.rb`
  carries a third verdict, `catalogue`, for exactly these four routes, and asserts
  it as a *set of distinct verdicts* rather than as a count, so the day a plan route
  becomes scoped the failure names the verdict that changed.
- **No publisher loop.** The outbox table and the transactional insert are here;
  the process that moves rows to NATS is not. `published_at` is therefore always
  null and `attempts` always zero, and `outbox_events` grows without bound. This
  is the one gap that is a real operational risk rather than a missing
  convenience: until a publisher exists, nothing consumes these events.
- **No retention.** `IdempotencyKey#expired` and `OutboxEvent#unpublished` exist
  to be pruned on a schedule; nothing schedules them. core is explicit that an
  unpruned outbox is the largest table in the database.
- **`billing.plan.updated` has no catalog row in core.** See `cafaye.yml`.
- **No payload schemas in core for six of the eight events.** core's outbox
  checklist asks for `data` to be validated against
  `schemas/events/<service>/<entity>/<action>.schema.json`; core ships two
  payload schemas in total and one of them is billing's.
  `test/contract/` enforces the rule for every event that has one, and fails the
  day core lands another — so the accounting is a test, not a claim.
- **Cursors are not signed.** They are base64url and opaque, which is all core
  requires, but nothing stops a client crafting one. It can only ask for a
  different page of a collection it can already read — the collection is already
  scoped to the caller's own account, so a forged cursor can only reach the reader's
  own rows or a page that names a position in them. Signing needs a secret this
  service does not have.
- **Three problem codes are not in core's reserved list**: `bad_request`,
  `cursor_invalid`, `cursor_expired`. See `cafaye.yml`.
- **The unique-index race is handled but untested.** A `RecordNotUnique` that
  slips past the validations is a `409`, which is right; proving it needs two
  concurrent writers, so no spec covers that line.
- **core's payload schemas and the three subscription events disagree, and the
  disagreement is recorded rather than paid for.** core-03 shipped a payload
  schema for all eight types. `billing.customer.created` and both
  `billing.payment.*` payloads satisfy theirs. `billing.plan.created` and
  `billing.plan.updated` satisfy theirs except for `entitlements`, which core's
  plan schema does not name. The three `billing.subscription.*` payloads do not:
  core's D10 rewrote those schemas because "billing has no subscriptions table",
  which was true of billing-03b and stopped being true when billing-04 added one,
  so they describe the processor-normalised payload this build replaced. The
  difference is in `PENDING_PAYLOAD_ALIGNMENT` in
  `test/contract/outbox_envelope_contract_test.rb`, asserted in both directions,
  and it is a DECISION NEEDED in `cafaye.yml`: core owns the second breaking
  change its own D10 anticipates. Matching core from here would mean emitting a
  payload no consumer has agreed to, or dropping `plan_id` and `account_id` — the
  two fields that make a subscription event actionable.
- **`PENDING_ID_PATTERNS` is empty.** core's D10 removed the `sub_…` / `pln_…` /
  `acc_…` patterns from the started schema, and removed `plan_id` and
  `account_id` as properties entirely, so there is nothing for this service's uuids
  to fail to match. The table stays as a constant and the contract test derives
  the gap from core's files, because a table iterated zero times would exit 0
  having proved nothing.
- **A processor customer id and a price id each belong to one row.**
  `customers.processor_customer_id` and `plans.processor_price_id` carry unique
  indexes over their non-null values, and both `POST` and `PATCH` answer **409
  naming the field** when a client claims one another row already holds. Without
  them a delivery could resolve to either of two accounts' rows — a
  `find_by` with no `ORDER BY` decides nothing when two rows answer to one id —
  and a subscription could be billed against a plan at a price nobody agreed to.
  These make the *delivery path* resolve deterministically, which is a separate
  guarantee from authorizing the caller: `Lifecycle`'s `find_by` has one answer
  instead of an arbitrary one. The caller's own side is closed by the account scope
  on every query — a client can no longer reach the other row to claim its id.
- **A subscription created directly in the processor's dashboard is not tracked.**
  It carries no cafaye customer id, so the delivery is recorded as
  `ignored:unknown_customer` and answered 200. Matching it to whoever happens to
  share an id would be a guess about whose money it is.
- **A processor status this service does not model is parked, not coerced.**
  `incomplete`, `incomplete_expired` and `paused` are all refused with the reason
  on the delivery row. A row that said `active` for a subscription the processor
  calls `incomplete` would grant entitlements nobody paid for; the five statuses
  this service stores are the ones a flat plan bought through Checkout actually
  reports.

## Health

Two probes, with different jobs, because conflating them causes restart storms:

- `GET /healthz` — liveness. Answers as long as the process serves requests. It
  touches no dependency on purpose: a liveness check that fails when the
  database is slow takes the whole fleet down to fix one slow box.
- `GET /readyz` — readiness. Runs `SELECT 1` on a leased connection and answers
  `503` with a JSON body when the database cannot answer, so the load balancer
  stops sending traffic. The underlying error is logged and never returned: the
  body is read by anything that can reach the port.

Both are integration-tested, including the database-down path, which is
exercised by faking the leased connection rather than by pulling a plug.

## Running it

Ruby 4.0.1 and PostgreSQL 17. Nothing else — the dependency floor is Rails'
defaults plus `pg`.

```sh
mise install            # or use any Ruby 4.0.1
bin/prime               # bundle, db:prepare, rubocop, rails test — the gate, and what CI runs
bin/dev                 # kit's stack: postgres, NATS, Redis, the collector, and Grafana
bin/dev stack           # which bytes of kit this worktree runs, and the merged compose result
bin/rails server        # http://localhost:3000, against whatever database you have
```

`bin/prime` is the gate. If you already have a PostgreSQL on the machine, skip
`bin/dev` entirely: `config/database.yml` connects over the local socket as the
current user.

**`bin/dev` is kit's script, verbatim**, and it brings up kit's shared stack
rather than a stack of this repository's own. `kit.ref` pins the commit those
bytes come from, and `docker-compose.yml` is an OVERRIDE merged beside it: this
service, its database name and role, and the crash layer. There is no `db:`
service in it any more and no collector configuration — see
[Observability](AGENTS.md#observability) for why the collector's file is never a
service's to own.

Point the app at a database elsewhere with `DATABASE_URL`, the same variable CI
uses:

```sh
DATABASE_URL=postgres://billing@localhost:5432 bin/rails db:prepare
```

## Tests

```sh
bin/rails test                      # the whole suite
bin/rails test test/models/money_test.rb
```

Minitest, no test framework gem. Clocks are injected with ActiveSupport's
`travel_to` rather than read, so no assertion depends on the day it was written.

**The money paths are held to 100% line and branch coverage**, measured with the
standard library's `Coverage` so the gate costs nothing. The measurement runs in a
subprocess that starts coverage *before* the application boots and eager-loads it
inside the measurement window — measuring from inside the suite would report a
file as covered when the corpus had merely autoloaded it, which is a gate that
passes for the wrong reason. Two things keep the gate honest: a spec asserts that
a corpus which reaches almost nothing is *reported* uncovered, and another
partitions every file that touches money into "is a money path" and "has money in
it", so a new one cannot be added ungated. The second group's entry points are
asserted behaviourally, so "not in the gate's list" never quietly comes to mean
"not covered".

`test/contract/` is the half of the suite that reads `core`: it checks the
emitted envelopes against core's real `event-envelope.schema.json`, checks that
the patterns this service validates with accept exactly the strings core's do,
and checks that `cafaye.yml` and the code agree about which events exist. It
skips, loudly, when `core` is not on disk; set `CORE_PATH` to point it elsewhere.

Beside it, `test/contract/http_surface_contract_test.rb` checks the *other* half
of the contract, and reads nothing but this repository: it compares
`openapi/v1.yaml` and `config/routes.rb` as sets of `(method, path)`, in both
directions, so a client generated from the document cannot call an operation the
service does not serve and the service does not serve one the document does not
declare. Every route that is deliberately not a client operation — the probes,
the `exceptions_app` targets, the ActionCable mount, the routes Rails engines
contribute — is named in that test with the reason it is not one, and a route
that is neither declared nor named fails. It holds the fifteen `operationId`s a
generator turns into method names, and it runs with or without `core` beside it.

**A skip here is a missing checkout, not a pass, and CI treats it as one.**
Measured on master, same commit, twice: with `core` readable the whole suite is
**763 runs, 2100 assertions, 0 skips**, and with it unreadable it is **763 runs,
1757 assertions, 20 skips** — the same run count, the same exit code, green
either way, and 343 assertions of contract checking simply not done. A second
test reads core too (`subscription_delivery_test.rb`, against the events courier
needs) and skips the same way. CI checks `cafaye/core` out of the repository
itself and **fails the build on a single skipped test**.
`.github/workflows/ci.yml` calls
`cafaye/kit/.github/workflows/ci.reusable.yml@master` and then runs the half kit
cannot own; `bin/prime` is the gate in both, and the suite is held at master's
**763 runs / 2100 assertions** at `e63bb7a`.

## Layout

```
app/controllers/v1/                 customers, plans and subscriptions
app/controllers/webhooks/           inbound from a processor: raw body, signature
app/controllers/concerns/            trace id, problem+json, cursor paging, idempotency
app/controllers/errors_controller.rb what Rails raises into
app/models/customer.rb               owner_type + owner_id, one per processor
app/models/plan.rb                   price is a Money or it is not a price
app/models/subscription.rb           one account on one plan; the status is the
                                     processor's statement and nothing else
app/models/processor_webhook.rb      what a processor sent, stored once
app/models/outbox_event.rb           the event, and the envelope it becomes
app/services/webhooks/               store once, normalize, emit — in that order
app/services/subscriptions/          the lifecycle: state machine, plan-change rule
app/services/processor/              the three requests this service makes
app/lib/problem.rb                   the one error shape
app/lib/money_params.rb              the only place a request becomes an amount
lib/kit/telemetry.rb                 the span-attribute ALLOWLIST, and the ONE recorder
lib/middleware/request_telemetry.rb  the request span, the route TEMPLATE, the 404
openapi/v1.yaml                      the HTTP contract
test/contract/                       the checks against core, and the HTTP one
test/observability/                  the redaction boundary, and its proof
kit.ref                              the pinned kit commit `bin/dev` fetches
cafaye.yml                           the manifest
```

## Running it

Two environment variables are needed for the webhook to answer at all:

| Variable | Meaning |
| --- | --- |
| `STRIPE_WEBHOOK_SECRET` | the endpoint's signing secret. Unset, every request is a 503 `unavailable` rather than a 400, because that is this service's misconfiguration and not the sender's. |
| `STRIPE_WEBHOOK_SECRETS` | a comma-separated list, for a rotation. A signature that verifies under any configured secret is accepted. |
| `STRIPE_WEBHOOK_TOLERANCE` | seconds, default 300. The window in which a captured request stays replayable. |

And one that is needed for nothing: observability is **on by default**, so this
variable only matters if you are pointing billing at a backend you already run.

| Variable | Meaning |
| --- | --- |
| `BILLING_OTEL_ENDPOINT` | the OTLP endpoint, default `http://otel-collector:4318` — which is the collector that ships with kit's stack. **The only contract** (core D16), so a self-hoster on Datadog or Grafana Cloud sets this one variable and kit's stack goes quiet. Unset costs spans and nothing else: no queue, no retry loop, no dial at boot. |
| `BILLING_OTEL_DISABLED` | set to anything, and telemetry is not installed at all. The startup line says so and names the reason. |
| `BILLING_TENANT_ID` | the `tenant_id` **resource** attribute. Never a span attribute — see [Observability](AGENTS.md#observability). Unset by default, because an empty one is a second service row in every collector's service list. |
| `DEPLOYMENT_ENVIRONMENT` | the `deployment.environment` resource attribute; an enum in core's schema, so there is no fourth spelling to invent. |
| `OTEL_SERVICE_VERSION` | the `service.version` resource attribute. Omitted rather than defaulted when unset. |

The exported spans carry **four attributes and no others**: the method, the status
code, the route template and a closed-vocabulary `error.type`. No path, no query
string, no headers, no email, no price, no exception message. The proof is
`test/observability/canary_test.rb`, which plants a canary in every field a caller
controls and raises if it finds one in anything exported, and the allowlist it is
checked against is `Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES` — one list, one
recorder, and `test/observability/allowlist_test.rb` fails if a name carrying a
word that means content ever gets onto it.

Nothing is stubbed in the specs: the suite signs committed fixture bytes with a
constant that is a credential for nothing and exercises the real verification
path, so there is no network in `bin/rails test`.

## Conventions

Read `AGENTS.md` before changing anything here. It is the contract: money is
integer minor units, time is UTC, IDs are opaque strings, lockfiles are never
edited as a side effect, and nothing is copied out of `moon/refs/`.

## License

**Business Source License 1.1.** See [LICENSE](LICENSE) — the parameters are
Licensor `Cafaye`, Licensed Work `billing`, Additional Use Grant `None`,
Change Date `2030-10-10`, Change License `Apache License, Version 2.0`.

**It was MIT, and this is a deliberate move down, not a drift.** billing's
`LICENSE` held a plain MIT grant until this packet. OPS-D2 splits the fleet:
the framework (`core`, `caf`, `kit`, `pantry`) stays permissive, the **services
move to a Business Source Licence** — free to run, free to self-host, never to
offer a competing service (`CAFAYE-OPS.md`, OPS-D2). billing is a service, so its
grant moved with the policy rather than being left to contradict it.

**Anyone who already holds a copy keeps the grant it was published under.** A
copy of this repository taken while `LICENSE` said MIT is still MIT, and this
change takes nothing away from whoever holds it. What has changed is the grant a
copy taken from today forward carries. OPS-D3's rule is that a published grant
is superseded out loud rather than quietly, because a repo whose grant quietly
contradicts the policy is worse than either licence (`CAFAYE-OPS.md`, OPS-D3 and
risk 8).

What BSL means for a caller, stated plainly: **calling billing over HTTP changes
nothing about your licence.** Nothing here is linked into a consumer's process
and no source is copied into one. What it does forbid is offering a competing
service built from this code — the "the mint is the moat" half of OPS-D2, the
same rule `conductor` and the artifact distribution are closed under. Everyone
may run it and self-host it.
