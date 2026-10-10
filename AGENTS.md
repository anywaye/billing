# AGENTS.md — billing

This file is the contract an agent (or a new hire) reads before touching this
repository. If a rule is not written here, it is not a rule.

## What this service is

- **Name:** `billing` — the cafaye namespace name, the repository name, and the
  `source` on every event this service eventually publishes.
- **Language / toolchain:** Ruby 4.0.1 on Rails 8.1, API-only — pinned in
  `mise.toml`, `.ruby-version`, and the `ARG RUBY_VERSION` in the `Dockerfile`.
  Those three must agree in one commit.
- **Owns:** plans, subscriptions, prepaid credit, usage metering, and webhooks
  in. One responsibility: the platform's money.
- **Does not own:** who the caller is (`identity`), how mail reaches them
  (`courier`), what a `pantry` catalogue looks like. billing is a service behind
  the gateway, not a public door.
- **Upstream specs:** `core`'s `cafaye.yml` manifest schema, event envelope and
  payload schemas, and `docs/openapi-conventions.md` + `docs/event-outbox.md`.
  This repository is pinned to `core: ^0.2.0`. The spec is the source of truth;
  the code follows it, never the reverse. `cafaye.yml` carries `> DECISION
  NEEDED` callouts recording the obligations this worktree could not discharge —
  read them before changing the manifest, and do not delete one to make a
  complaint go away.
- **core is read-only from a service worktree.** When core is missing something
  this service owes it — a catalog row, a payload schema, a reserved error code —
  the obligation is recorded in `cafaye.yml` *and* asserted in `test/contract/`,
  and the action item is named in the worker report. Writing into core from here
  is out of bounds.

## What exists so far

The packets that changed what this service **is** are described below, oldest
first. Read the last one before touching `/v1`.

- **billing-01** was a scaffold: health probes and the money primitive. It
  exists so the shape was settled before the first price was modelled.
- **billing-02** is the billing domain v0: `customers` and `plans`, the `/v1`
  API over them, and a transactional outbox that writes
  `billing.customer.created`, `billing.plan.created` and `billing.plan.updated`
  in the same transaction as the change they describe. No Stripe call.
- **billing-03b** is the Stripe webhook: `POST /v1/webhooks/stripe`, signature
  verification over the raw body, and `processor_webhooks` as the
  at-most-once record of what arrived. It emits five more events —
  `billing.subscription.started|updated|canceled` and
  `billing.payment.succeeded|failed` — into **billing-02's** outbox.
- **billing-04** is the subscription lifecycle: the `subscriptions` table, the
  state machine that decides which transitions are possible, the `/v1`
  endpoints that buy a subscription and cancel one and move it between plans,
  and the three requests this service now makes *to* Stripe.
- **billing-05** is a reconciliation and nothing else: core shipped payload
  schemas for all eight published types and raised D10, and
  `test/contract/outbox_envelope_contract_test.rb` was the thing that noticed.
  No behaviour in `app/` changed except one comment. What it found is written
  down in `cafaye.yml` as a DECISION NEEDED — core's subscription schemas
  describe the payload billing-03b emitted, and billing-04 moved those events
  onto billing's own ids.
- **billing-07** is the document and the router, held to each other: one test
  that compares `(method, path)` in both directions, replaces a path-only
  comparison that could not see a verb, and found one operation
  (`PUT /v1/customers/{id}`) that was served and in no document. It removed that
  route rather than documenting it. No behaviour in `app/` changed.
- **billing-09** is a **duplicate-charge race and the constraint that closes it.**
  `Ingestion#call` was a check followed by an act, and two concurrent deliveries of
  one event id both read `handled?` as `false`, both emitted, and one Stripe event
  became two `billing.payment.succeeded` rows — two envelope ids, which core defines
  as the dedupe key, so a consumer cannot tell the duplicate from new information
  about money. A partial unique index over the outbox's `processor_event_id` makes
  the duplicate impossible under **any** interleaving, and a lost race is recorded as
  `ignored:duplicate_delivery` rather than parked as a failure. The regression test
  manufactures the interleaving with a two-party barrier — no sleep anywhere — and
  the property is shown to rest on **more than one constraint**, because a start
  payload deliberately carries no `processor_event_id`. The packet also found three
  test helpers delivering under an event id their own payload did not carry, which
  the new index turned from a silent lie into a loud failure, and a ~5% flake in
  which a losing delivery was parked as a failure because a model validation won
  the race instead of the index. See `REPORT-billing-09.md`, which also says what
  was not fixed.
- **billing-08** is hardening, and it is where the *recorded* gaps stop being
  prose. `test/contract/tenant_isolation_matrix_test.rb` enumerates every `/v1`
  operation the router serves and requires each one to be classified account-scoped
  or not, with a reason — so a route added tomorrow fails by name instead of
  joining an unauthenticated surface nobody decided the scope of.
  `test/integration/secrets_do_not_leak_test.rb` captures real log output from
  the **failure** paths and asserts a processor key, a signing secret and a
  customer email are absent from it, because no static analyser in the fleet
  finds a secret leaked at runtime. The controller stopped answering **500** to a
  signed body that is valid JSON but not an object — an array, a number, a
  string, a boolean or `null` — where the endpoint's own status table says a 5xx
  never is an answer. And the lifecycle's stale-delivery guard above landed here.

  Two judgement calls are recorded because they are the kind that rot. The
  tenant matrix asserted every entry is `unscoped` **as a set of the distinct
  verdicts**, not as a count, so the day a route is genuinely scoped the failure
  names the verdict that changed; and every entry carries a reason that is
  asserted to be non-empty, because `/v1/subscriptions` returning every row is a
  gap that arrived by nobody writing it down. **Both mechanisms did exactly what
  they were built for on billing-21**: the verdict changed and the matrix said so
  by name, and the reason column is what makes the four `catalogue` entries
  arguable rather than invisible.

- **billing-12** is tenant isolation, and it is the packet that **measured** the
  gap billing-08 recorded. `test/tenant/` is four files and one support module,
  `+62 runs / +230 assertions`, and **nothing in `app/` changed** — because the
  finding is that there is no account scoping here to make load-bearing, only a
  total absence of measurement over a surface sold as multi-tenant.

  What it holds, and each number is asserted rather than described: **14
  account-scoped routes** (read 4, list 3, write 3, update 4, delete 0) and **33
  account-scoped data accesses** in 31 methods (read 12, list 9, write 7, update
  5, delete 0), with **31 negative tests** over them (read 15, list 4, write 3,
  update 8, delete 1) out of **62 tests** in the directory. The rest are 20
  structural tripwires about the enumeration and 11 `meta:` tests about the files
  themselves; note that the two 31s are a coincidence and mean different things —
  one is a count of access sites in `app/`, the other of negative tests. The two
  layers of the packet's headline are counted separately on purpose, because a
  route and the method that serves it overlap and summing them produces one number
  that means nothing.

  Four things in it are worth knowing before you touch `app/`:

  * **The enumeration is derived, not maintained.**
    `account_entry_point_matrix_test.rb` scans `app/` for every data access,
    resolves each to the *method* it sits in (not the line — a comment would
    renumber every site below it), and compares the result against its table in
    **both directions**. A query nobody classified fails by name; a classified
    entry point whose method has gone away fails the other way. Seven of the 33
    are **declarations** — two `belongs_to`, five `scope` — counted because an
    association and a scope are both queries, and `scope :for_account` is the
    shape account scoping is most likely to arrive in.
  * **A 403 is structurally impossible here, and that is the check.**
    `Problem::CATALOG` is a frozen table and no entry has the status 403, so there
    is no code path to render one — the guarantee is a property of a **closed
    set**, not of a review. A second assertion scans `app/` for `403`,
    `forbidden` and `:unauthorized`, which catches a controller reaching past the
    catalog. **Absence, never refusal.** The 404 half was already right and is now
    pinned: a resource that does not exist and an id that *cannot* name one are
    the same seven-key answer on all three uuid-addressed resources.
  * **The gap is pinned as a tripwire that fires when it closes.** Four tests
    assert the surface is open — a customer and a subscription readable by uuid,
    a customer **writable** by uuid, an unscoped listing — and each is coupled to
    a count of account-constrained queries in `app/` that was **0 when written**.
    The day scoping lands, that count moves and **all four fail** saying to
    rewrite them as 404s. **It happened: billing-21, and all four fired.** They
    were rewritten rather than deleted, and the coupling was kept rather than
    dropped — `cross_account_web_test.rb`'s `meta:` test now asserts
    `account_scoped_queries > 0`, so the same tripwire now points the other way:
    if a later refactor drops every account scope, that test goes red.
  * **Three cross-tenant defects were found and reported, and billing-13 fixed
    them.** F1: a delivery reassigned a live subscription between accounts, because
    `Lifecycle#apply` wrote `account_id: customer.owner_id` and never compared it to
    the account already on the row. F2: `customers.processor_customer_id` was not
    unique and `POST`/`PATCH /v1/customers` both permitted it, which is what made
    F1 reachable through this service's own surface. F3: the same shape on
    `plans.processor_price_id`. See `REPORT-billing-12-isolation.md` for the
    before, and `REPORT-billing-13-fixes.md` for the after.

- **billing-13** is those three fixes, and it is the packet that turned billing-12's
  findings into refusals. `+37 runs / +126 assertions`, `950 runs / 2724
  assertions`, and the six findings tests are **rewritten rather than deleted**:
  same two accounts, same delivery, same `PATCH`, same pair of plans, with each
  assertion flipped from "the defect reproduces" to "the defect is refused". Three
  things in it are worth knowing before you touch the delivery path:

  * **A delivery may not change a subscription's account.**
    `Subscriptions::Lifecycle::ACCOUNT_REASON` is `"account_mismatch"`, the
    **seventh** `Refused` reason and the first about **tenancy** rather than about
    the row's shape. The comparison is one line in `Lifecycle#apply`, and it is
    **before `assign_attributes`** — a comparison after the overwrite compares the
    new account with itself and always agrees, which a mutation proved. It is also
    guarded by `existed &&`, because a first delivery has no account to disagree
    with and an unconditional check would break the deletion-arriving-before-its-
    creation rule. Recorded as `ignored:account_mismatch` and answered **200**.
    **The model's own validation could not have caught this**, and that is the
    reason the guard had to go in the only writer: `account_is_the_customers_owner`
    enforces "a subscription's account is its customer's", which is **true** after a
    reassignment.
  * **A processor customer id and a price id each belong to one row**, enforced by
    `customers_processor_customer_id_idx` and `plans_processor_price_id_idx`, with
    matching model validations so a collision is a **409 naming the field** rather
    than a raw index violation. **Both indexes are partial, and the reason is not
    stylistic**: the columns are nullable and legitimately so, so the rule is *a
    value here is unique*, and a bare `unique` index would allow the nulls only by
    way of PostgreSQL's `NULLS DISTINCT` default — a database default rather than a
    statement of intent, and one that `NULLS NOT DISTINCT` could remove. **A
    deploy step, not a no-op**: a table already holding the duplicates cannot be
    migrated, and the migration test asserts that refusal as behaviour.
  * **`/v1` was still unauthenticated and still unscoped when this packet landed,
    and that is what billing-21 changed.** 14 account-scoped routes and 33 data
    accesses carried **zero** account scopes, and the four `gap:` tripwires pinned
    the open surface. These three fixes make the *delivery path's* resolution
    unambiguous and immovable; they authorize nobody and they were never a
    substitute for scoping. Read the section on Authorization below, and note that
    the paragraph above describes the state billing-21 found rather than the state
    this repository is in now.

  **The two constraint tests are in files of their own** because running a
  migration commits the enclosing transaction, and **the index's shape is asserted
  in `test/tenant/`, not in them**: a file that rolls the index back and up
  *rebuilds* what it then measures, so a non-unique index was repaired by whichever
  test ran first and the assertion passed. A guard that only ever rebuilds what it
  measures cannot detect a wrong thing about it.

billing-05 changes a claim the earlier packets made, so it is stated plainly:
**this service now talks to Stripe.** It did not, and saying so was true when it
was written. A subscription is bought through a Checkout Session, cancelled by
asking Stripe to cancel, and moved between plans by asking Stripe to move it; a
lifecycle that cannot make those three requests is not a lifecycle. The claim
that replaces it is narrower and checkable by reading one file: **every request
this service makes to Stripe is one of the three methods on
`Processor::StripeClient`, and there is no other `Stripe::` call in the
repository.** No new dependency — the `stripe` gem was already here, for
`Stripe::Webhook.construct_event`.

- **billing-21** is the lock on the door, and it is the packet that closed the gap
  billing-12 measured. `test/authentication/` is two files and `+64 runs / +175
  assertions`, and `+14` files change under `app/`, `openapi/`, `test/` and the
  three documents. Read the **Authorization** section below before touching any
  `/v1` controller; the four things below are the ones that will surprise you.

  * **A tenant concept DOES exist, and it was already here.** billing-12 recorded
    14 account-scoped routes and 33 data accesses over
    `subscriptions.account_id` and `customers.owner_type` + `customers.owner_id`.
    That is the tenant, and nothing had to be invented for this packet — the
    missing piece was only ever that no query was *scoped* by it. `Plan` is the
    exception and it is deliberate: a plan is the platform catalogue, it has no
    account column, and it is not one.
  * **The account is a CLAIM and never a parameter.** `Principal.build` refuses a
    token whose `account_id` is not a uuid, `POST /v1/customers` ignores
    `owner_type`/`owner_id` in the body, and `CustomerUpdate` no longer permits
    them either. A caller that could name its account in the request could name
    somebody else's, and this service has no way to tell the difference.
  * **A `User`-owned customer is in no account and is therefore invisible to
    `/v1`.** Not "refused" — invisible, because `Customer.for_account` matches
    `owner_type: "Account"`. A row with no tenant has nobody to scope it to, and
    which account a user belongs to is identity's fact, not a body's.
  * **The four `gap:` tripwires fired, and they were rewritten rather than
    deleted.** billing-12 coupled each to a count of account-constrained queries
    that was `0`, precisely so they would fail on the day scoping landed. Same two
    accounts, same requests, each assertion flipped from "the surface is open" to
    "the surface refuses". The coupling was **kept** rather than dropped: the meta
    test now asserts `account_scoped_queries == 4` exactly, so dropping either
    `for_account` scope is a failure rather than a silent narrowing.
  * **Two of this packet's own guards were wrong on first write, and mutation
    caught both.** A scan for `/\bJWT\./` does not match `JWT::JWK`, so a file
    doing exactly what it forbids passed; and `account_scoped_queries > 0` with an
    unanchored `scope :for_account` **prefix** could not be moved by the very
    change it watches for. Both are fixed, and both are reported in
    `REPORT-billing-21-authorization.md` and in `CHANGELOG.md`. Read that before
    writing a guard here — the first draft of either passed.

- **billing-receipts-01** is the charge and the receipt: what a customer was
  charged, and the page that shows it. `+39 runs / +107 assertions`,
  `1134 runs / 3264 assertions`, and seven files under `app/`, `openapi/`,
  `test/` and the three documents. Three things in it are worth knowing before
  you touch the delivery path:

  * **A charge is recorded when money moved, and never when it did not.** The
    recorder is hooked into `payment_emission`, inside the ingestion transaction,
    so a charge and its event commit together. The processor's own `paid` and
    `amount` are the only things consulted: a failed payment, a zero-amount
    settlement, a negative one and a payment for an unknown customer all record
    nothing, and the event is still published.
  * **`processor_charge_id` is UNIQUE**, and that index is the resolution
    mechanism for a redelivery. A one-time Checkout payment carries no charge
    object, so the payment intent is recorded there.
  * **The receipt is HTML, and every interpolated value is escaped.** The
    description is the processor's own text — an invoice line item's description
    — and a price named `<script>` at the processor must not execute in a page
    served from this origin. The document is marked `html_safe` only after the
    values are escaped, because `render html:` escapes its argument by default.

- **billing-outbox-publisher** is the drain: `outbox_events` now **leaves the
  table**. The claim, the envelope and the publish pass are the fleet's shared
  gem (`Cafaye::Outbox`, vendored at `vendor/cafaye` because the gem is
  unpublished and github is unreachable from here — `VENDORED.md` records the
  pin and `DIGESTS` holds it); billing adds exactly the three things the gem
  says a service owns — `Outbox::NatsPublisher` (the transport, one method,
  JetStream so `published_at` is set from the broker's ack), `Outbox::Relay`
  (the loop: fixed one-second poll, batch 100, no wired Noop) and
  `config/initializers/outbox_relay.rb` (starts on `NATS_URL`, inert without
  it, inert in the test suite). The **subject is the event type** — core's "no
  mapping table, no prefix rewriting" — so `billing.subscription.started` goes
  to `billing.subscription.started`, which the fleet's `billing.>` stream
  covers. Delivery is proved end to end against an in-process broker double
  (`test/support/fake_nats_broker.rb`), including that **no published payload
  carries a processor secret, a card, or PII beyond the `email` core's schemas
  name**. Two things this packet deliberately did **not** do: it did not add a
  `cafaye` gem dependency from rubygems or git (neither is reachable), and it
  did not touch the subscription payloads' known disagreement with core's
  schemas — that is core's change to make, and it is reported rather than
  shipped around. See `REPORT-billing-outbox-publisher-01.md`.

There are no invoices, no usage metering, no prepaid credit yet. Do not read
their absence as something to fix in a side patch; those are later packets with
their own briefs. The publisher loop is no longer one of the missing pieces.

## Layout

```
billing/
├── mise.toml               # toolchain pins + the tasks (mise run prime)
├── bin/prime               # the gate: bundle, db:prepare, rubocop, rails test
├── bin/dev                 # kit's, VERBATIM: fetch kit.ref, merge with our override, up
├── bin/migrate             # `bundle exec rails db:prepare`, and why kit needs this file
├── kit.ref                 # the pinned kit commit the local stack comes from
├── docker-compose.yml      # an OVERRIDE on kit's stack: this service, our database,
│                            #   our crash layer. No collector config, no own postgres.
├── Dockerfile              # ruby slim, multi-stage, non-root, via Kamal/Thruster
├── cafaye.yml              # the manifest; DECISION NEEDED notes are load-bearing
├── openapi/v1.yaml         # the HTTP contract, and what `exposes.api` points at
├── app/
│   ├── controllers/
│   │   ├── health_controller.rb       # /healthz, /readyz
│   │   ├── errors_controller.rb       # what Rails raises into
│   │   ├── concerns/                  # trace id, problem+json, paging, idempotency,
│   │   │                              #   and the principal lock on /v1
│   │   ├── v1/                        # customers, plans, subscriptions — all scoped
│   │   └── webhooks/                  # signed inbound, from a processor not a client
│   ├── lib/
│   │   ├── problem.rb                 # the one error shape
│   │   ├── principal.rb               # the caller: sub, account_id, scopes
│   │   ├── money_params.rb            # the only place a request becomes an amount
│   │   └── identifiers.rb             # the uuid shape, in one place
│   ├── models/
│   │   ├── money.rb                   # the money primitive
│   │   ├── customer.rb                # owner_type + owner_id, one per processor
│   │   ├── plan.rb                    # price is a Money or it is not a price
│   │   ├── subscription.rb            # a status this service did not decide
│   │   ├── processor_webhook.rb       # what a processor sent, stored once
│   │   └── outbox_event.rb            # the event, and the envelope it becomes
│   └── services/
│       ├── identity.rb                # the three refusals: ours, ours, the caller's
│       ├── identity/
│       │   └── token_verifier.rb      # the ONLY place a JWT is read
│       ├── processor/
│       │   └── stripe_client.rb       # the three requests this service makes
│       ├── subscriptions/             # the lifecycle, as three pure objects
│       │   ├── state_machine.rb       # which transitions are possible
│       │   ├── plan_change.rb         # when a move takes effect
│       │   └── lifecycle.rb           # the only writer of a subscription
│       └── webhooks/                  # verify, store, normalize, emit — in that order
│           └── ingestion.rb           # store, act once, and what a lost race records
│       └── outbox/                    # the publisher: transport, loop — and nothing else
│           ├── nats_publisher.rb      # one method: put this envelope on the bus
│           └── relay.rb               # the fixed one-second poll, tied to the process
├── lib/
│   ├── kit/
│   │   ├── telemetry.rb               # the span-attribute ALLOWLIST and the ONE recorder
│   │   ├── exporter.rb                # which exporter, from a CLOSED vocabulary
│   │   └── tracer_installer.rb        # the provider, the processor, the propagator
│   └── middleware/
│       └── request_telemetry.rb       # the request span, the route TEMPLATE, the 404
├── test/
│   ├── authentication/                # THE LOCK, and the verifier behind it
│   │   ├── token_verifier_test.rb     # the real crypto, only the FETCH stubbed: 28
│   │   └── principal_lock_test.rb     # the boundary, from the router's own table: 36
│   ├── contract/                      # the checks against core, and the HTTP one
│   │   ├── http_surface_contract_test.rb # the document and the router, by method and path
│   │   ├── outbox_envelope_contract_test.rb # the envelope and the payloads, against core
│   │   └── core_location_test.rb     # core is found, from a worktree, with nothing set
│   ├── coverage/                      # the money-path coverage gate, and its inventory
│   │   └── fixture_processor_ids_check_test.rb # the fake processor and the helpers agree
│   ├── integration/                   # health, and the webhook's HTTP edge
│   ├── models/                        # minitest, table-driven
│   │   ├── outbox_processor_event_id_migration_test.rb # reversibility, run for real
│   │   ├── customer_processor_customer_id_migration_test.rb # ditto, for the cus_ index
│   │   └── plan_processor_price_id_migration_test.rb       # ditto, for the price_ index
│   ├── observability/                 # the redaction boundary, and its proof
│   │   ├── allowlist_test.rb          # the allowlist itself: 12 tests
│   │   ├── telemetry_test.rb          # the contract, the resource, the wiring: 8
│   │   ├── request_span_test.rb       # the span, through the real router: 16
│   │   └── canary_test.rb             # THE PROOF: a canary in every caller field: 12
│   ├── requests/v1/                   # the API specs
│   ├── services/                      # the lifecycle, the client, the webhook mapping
│   │   ├── webhooks/
│   │   │   └── concurrent_delivery_test.rb  # the duplicate-charge race, deterministically
│   │   └── outbox/                    # the publisher: delivery, the loop, what reaches the bus
│   │       ├── nats_publisher_test.rb  # the transport and one pass, against the broker double
│   │       ├── relay_test.rb           # the loop, the fixed poll, and the NATS_URL condition
│   │       └── published_payloads_test.rb # the inventory, and the no-secret proof
│   ├── support/                       # shared helpers: frozen clock, fake Stripe, two accounts
│   │   ├── two_accounts.rb            # the pair every isolation spec compares against
│   │   ├── identity_helpers.rb        # a real RSA key; only the FETCH is stubbed
│   │   ├── core_location.rb           # WHERE CORE IS — and the worktree hazard it closes
│   │   ├── fake_nats_broker.rb        # an in-process broker: INFO, PONG, PUB → ack or 503
│   │   ├── test_span_exporter.rb      # the exporter that records instead of sending
│   │   └── test_spans.rb              # reading those spans, and RAISING on empty
│   └── tenant/                        # the tenant boundary, enumerated and held
│       ├── account_entry_point_matrix_test.rb # every account-scoped access, derived from app/
│       ├── cross_account_delivery_test.rb     # the boundaries that hold, against Postgres
│       ├── cross_account_web_test.rb          # the 404 shape, and the 403 audit
│       └── cross_account_findings_test.rb     # the three cross-tenant defects, as refusals
├── .github/workflows/ci.yml           # calls kit's reusable workflow, plus the gate
├── CHANGELOG.md                       # every notable change, per Keep a Changelog
├── REPORT-billing-09.md               # the race: evidence, fix, and what was not fixed
├── REPORT-billing-12-isolation.md     # the tenant boundary: the count, and three findings
├── REPORT-billing-13-fixes.md         # F1, F2, F3 closed: before, after, and eight mutations
└── REPORT-billing-21-authorization.md # the lock: built, verified, and the claim mismatch
```

## Commands

Run these; do not improvise equivalents.

| Task | Command |
|------|---------|
| Prime the worktree | `bin/prime` (or `mise run prime`) |
| Prime without lint or tests | `bin/prime --fast` |
| Run the test suite | `bin/rails test` |
| Run one file | `bin/rails test test/models/money_test.rb` |
| Run the linter | `bin/rubocop --parallel` |
| Security scan | `bin/bundler-audit check --update` and `bin/brakeman --no-pager` |
| Start the stack (database + collector + traces) | `bin/dev` |
| Resolve which bytes of kit this worktree runs | `bin/dev stack` |
| Stop it, keeping the data | `bin/dev down` |
| Everything CI runs | `bin/prime`, plus `bin/bundler-audit check --update` and `bin/brakeman --no-pager --quiet --exit-on-warn` (`mise run security`) |

## Authorization

`/v1` requires an RS256 JWT from `identity`, verified locally against the
published JWKS, and **every customer and subscription query is scoped by the
account in that token.** Four files and four rules, and the rules are the
section:

- **`app/services/identity/token_verifier.rb` is the ONLY place a JWT is read.**
  Not one of several; there is no second verifier, no plug that can be swapped out,
  and `test/authentication/token_verifier_test.rb` holds the list of callers. A
  second trust path to `/v1` is the thing this whole design exists to prevent —
  the webhook already teaches the opposite lesson, one door and one credential.
- **The algorithm is a constant, read from the token's own protected header
  before anything is fetched.** `ALGORITHM = "RS256"`, checked against the header,
  never against a hint the caller supplies. An `alg: none` token and an HS256
  token signed with the published public key are both refused **without a network
  call**, which is the sharpest thing in the verifier and the reason the header
  is parsed first. Widening to ES256 is a one-line change and must not be made
  before identity publishes ES256 keys.
- **It fails CLOSED, and that is the property the section exists for.** No issuer
  or no audience configured → **503**. identity unreachable → **503**. No token,
  malformed, wrong algorithm, unknown `kid`, expired, wrong audience → **401**.
  There is no branch in `AuthenticatesPrincipal` that lets a request through
  without a verified principal: no default account, no "authentication is off in
  development", no rescue that renders a 200. A self-hosted billing API that
  quietly degrades open because nobody filled in an environment variable is the
  failure this removes, and **the direction that matters is the one that refuses.**
- **The lock is a `before_action` on `V1::BaseController`, and it is structural
  rather than a convention.** `Webhooks::BaseController` does not inherit it and
  cannot reach it, and `raise_on_missing_callback_actions` stops a future
  controller in that namespace from skipping the filter by not naming an action.
  Do not move it into middleware and do not "helpfully" widen it to a path
  prefix: `/v1/webhooks/stripe`'s sender is a processor and its credential is a
  signature, core forbids a JWT there, and a `Bearer` on that path would be a
  second, weaker trust path to the same door.

Two environment variables, `BILLING_IDENTITY_ISSUER` and
`BILLING_IDENTITY_AUDIENCE`, and **an unset one locks `/v1` rather than serving
it.** That is deliberate and it is tested; do not add a development default
issuer, because a test that passes in development and a self-hosted deployment
that serves an open API are the same defect wearing two hats.

**The 401 body is one fixed sentence** and names none of the four things that can
be wrong — signature, expiry, issuer, audience. Which one it was goes to the log
with the trace id. A caller must not be able to learn that a signature was valid
by being told the audience was wrong, and `detail` on a problem document is free
text, so the specificity lives in exactly one place.

### Authorization, not only authentication

The token names an account and every query is scoped by it. That is a tenancy
answer, and it is the whole of what this packet added — there is **no capability
model**, and adding one is a decision rather than a missing line:

- `Customer.for_account` matches `owner_type: "Account"` and the token's
  `owner_id`. A `User`-owned customer is in **no** account and is therefore
  invisible to `/v1`, not refused by it: a row with no tenant has nobody to scope
  it to, and which account a user belongs to is identity's fact.
- `Subscription.for_account` matches `account_id`.
- **A cross-tenant read and a cross-tenant write are both 404** — the same answer
  a uuid that names nothing gets. `Problem::CATALOG` still has no 403 and this
  packet did not add one; see the Contracts section.
- `Principal#account_id` is **required**, and a token whose `account_id` is not a
  uuid is refused at the door. "No account" and "an account I could not read" must
  not both be answers to the same request.
- **The account is a claim and never a parameter.** `POST /v1/customers` ignores
  `owner_type`/`owner_id` in the body and `CustomerUpdate` no longer permits
  them. A caller that could name its account in the request could name somebody
  else's, and nothing in this service could tell the difference.
- `Idempotency-Key` is scoped to `(endpoint, sub, key)`. `IdempotencyKey::PRINCIPAL`
  is no longer a constant and `IdempotentRequests#idempotency_principal` raises
  rather than defaulting to `"anonymous"` — a default there is an unauthenticated
  namespace invented by a default value.

**Plans are the exception, and the exception is deliberate.** A plan is the
platform's catalogue — a price any account can subscribe to — so the four plan
routes are authenticated and **not** account-scoped, and
`test/contract/tenant_isolation_matrix_test.rb` carries a third verdict,
`catalogue`, for exactly them. Scoping the catalogue listing to one account's rows
would answer an empty collection to a caller who has subscribed to nothing, which
is a wrong answer rather than a safe one. **The consequence is that any
authenticated account may write the catalogue**, because no capability check
exists for it: `Principal#scope_set` parses the token's `scope` claim and nothing
reads it. That gap is recorded in `cafaye.yml` and `README.md`; do not close it by
inventing a scope string nothing in the fleet grants.

## Money

`app/models/money.rb` is the seed of the platform-wide rule that **money is
integer minor units** and never a Float. Read its class comment before changing
it. The rules that are not negotiable:

- Amounts are integers of minor units. A Float is rejected on the way in, not
  converted — `0.1` cannot represent a dime, so it never carries an amount.
- Nothing rounds. `Money.from_major("10.505", "USD")` raises
  `Money::InvalidAmountError`. A silently rounded price is a bug that surfaces
  in somebody's invoice, which is the worst place to find one.
- Every operation is range-checked against the PostgreSQL bigint bounds, so an
  unstorable value is refused at the edge instead of at the database.
- Mixing currencies is an error, never a conversion. FX is a pricing decision.
- Quantities are integers and go on the right: `price * 3`, never `3 * price`.
- Store and transmit `minor_units` and `currency`. A major-unit decimal is a
  display format; `Money#to_major` exists for interop and must not be persisted.
- **The wire carries minor units and an integer, and one representation only.**
  `{"amount_minor": 1900, "currency": "USD"}`. A Float and a decimal string are
  both refused at the edge by `app/lib/money_params.rb`, which is a plain module
  with no Rails dependency. Do not add a second accepted shape to be helpful.
- `Plan#price` returns a `Money` and `Plan#price=` accepts only a `Money`.
  `amount_cents` and `currency` are written by that setter and by nothing else.
  A 422 about an amount names `price` — the field the client sent — and never
  the columns underneath it.

- **No amount is ever computed to send to a processor.** A plan change sends a
  `proration_behavior`; a cancellation sends an id and a boolean. The credit for
  an unused period is the processor's, and a figure calculated in Ruby and sent to
  Stripe would be a figure this service did not keep — the two would eventually
  disagree, in a customer's invoice. `Processor::StripeClient` has no accessor
  for a credit, a refund or a prorated amount, and the specs assert the *absent*
  keys as well as the present ones.

### The gate on the money paths

Money paths are held to **100% line and branch coverage** (PLAN §3), measured
with Ruby's standard library `Coverage` so the gate costs no gem. Two files are
in the list: `app/models/money.rb` and `app/services/subscriptions/plan_change.rb`
— the primitive, and the only place in the repository that *compares* two
amounts.

Four things about how that gate runs are not incidental, and each was a bug first:

- **`Coverage.start` runs before the application boots, and the app is
  eager-loaded inside the measurement window.** Measuring from inside the minitest
  process reports a file as covered when the corpus merely autoloaded it, because
  `Coverage` records only what executes after it starts. A gate that passes for
  the wrong reason is worse than no gate.
- **The measurement runs in a subprocess**, with a report path unique per run.
  The suite runs in parallel, and two workers sharing one path would read each
  other's coverage — one of them asserting numbers that belonged to a different
  corpus.
- **The gate's honesty is asserted.** `test/coverage/money_paths_coverage_test.rb`
  measures a corpus that reaches almost nothing and requires it to be *reported*
  uncovered, and requires a full corpus and a minimal one to differ.
- **The list itself is checked against the repository.**
  `test/coverage/money_path_inventory_test.rb` partitions every file under `app/`
  that touches money into "is a money path" and "has money in it", so a new money
  path cannot be added ungated. The second group carries a *reason* that is
  asserted to still hold, and its money entry points are asserted behaviourally —
  so "not in the gate's list" never quietly comes to mean "not covered". A file
  that contradicts its reason belongs in the first group or in neither.

## Events

The rules are core's, in `core: docs/event-outbox.md` and
`docs/event-naming.md`. What is not negotiable here:

- An event is written in **the same transaction** as the change it describes,
  from `after_create`/`after_update` — never `after_commit`, and never a
  background job. A separate transaction is a window in which the database says
  the plan exists and the event does not.
- The type is `<service>.<entity>.<action>`, three segments, prefixed with this
  service's own name (core v0.2, D1). `OutboxEvent::TYPES` and `cafaye.yml`'s
  `exposes.events` are the same list, and `test/contract/` fails if they drift.
- A type is not published unless core's catalog has a row for it. An event with
  no catalog row is a manifest that lies to whoever generates an SDK from it.
- The outbox column list is core's, not local. If you change it, you are
  changing a contract.
- **There is one outbox.** `app/models/outbox_event.rb` is it, for every
  producer in this service. A webhook publishes through `OutboxEvent.publish!`
  like a model callback does; a second table, a second envelope builder or a
  second `to_envelope` is a second answer to a question a consumer asks once.
- **A subscription event's type is derived from what the delivery did to the
  row**, not from which processor event carried it. This is the one place the
  "same type, same vocabulary" rule needs explaining rather than restating, and
  it is what makes out-of-order delivery safe.
- **The publisher loop that moves rows to NATS exists**: `Outbox::Relay`,
  started by `config/initializers/outbox_relay.rb` when `NATS_URL` names a
  broker, and not started when it does not. It drains through
  `Cafaye::Outbox`'s claim — `for update skip locked`, bounded, in `created_at`
  order — so N replicas can run it against one table, and it marks a row
  published **from the broker's ack and never before**. The subject on the wire
  is the event type, which is what the fleet's `billing.>` stream covers.
  Delivery is at-least-once and the row's id is the envelope's id, so a
  republish after a crash between the ack and the mark dedupes at the consumer.
  With no broker the rows simply stay unpublished: that accumulation is the
  honest state, and the boot log names it rather than leaving an operator to
  wonder.

## Subscriptions

The lifecycle is three objects, and which one you are editing tells you which
rules you are about to break.

- **`Subscriptions::StateMachine`** is pure: a from-status and a to-status in, an
  answer out, no database and no clock. **The whole legal/illegal grid is one
  table**, so the set of *impossible* transitions is readable rather than inferred
  from conditionals. There is one rule and everything else is ordinary code:
  **`canceled` is terminal, and nothing leaves it.** A status the processor uses
  and this service does not model is refused by the constructor — a row that said
  `active` for a subscription the processor calls `incomplete` would grant
  entitlements nobody paid for.
- **`Subscriptions::PlanChange`** compares two prices and decides when a move
  takes effect. An upgrade is invoiced immediately; a downgrade or a lateral move
  lands at the renewal. Cross-currency and cross-interval comparisons are refused
  rather than guessed. It has no amount in it at all.
- **`Subscriptions::Lifecycle`** is the **only** writer of a subscription's state
  and the only thing that emits its events. There is no `after_update` on
  `Subscription` and no branch of the API that changes a status. Do not add one:
  the processor is the party that can bill, and a local row that disagreed with it
  would grant entitlements nobody is paying for.

Two rules that are not obvious and that the specs exist to hold:

- **A deletion arriving before its creation creates a `canceled` row.** It is the
  only statement about that subscription that has arrived, and dropping it would
  leave an *active* row — and an active row grants entitlements — for something
  the processor says is gone. The `created` that follows is then refused by the
  terminal rule. billing-03b published both events and left the active row; that
  was the bug this rule fixes.
- **A delivery that changes nothing is refused, not published.**
  `no_change_to_record` — otherwise a processor that repeats itself under a fresh
  event id produces updates that carry no update, and a consumer counting plan
  changes stops meaning anything.
- **A delivery that predates the one that last wrote the row is refused.**
  `stale_delivery`. The state machine's rule is about a *pair* of statuses and
  covers the one order this service knows for certain. Everything else is a
  *sequence*, and the processor does not promise delivery order, so a
  `customer.subscription.updated` the processor retried an hour late lands on a
  row it has already moved past. `last_processor_event_at` records the
  processor's own timestamp for the delivery that last wrote the row, and a
  delivery **strictly older** than it is refused — *strictly*, because those
  timestamps are epoch seconds, two genuinely different events routinely share
  one, and refusing those would drop real deliveries. A row with no recorded
  timestamp has nothing to be stale against, which is the case a deletion
  arriving before its own creation depends on. Without this, a `past_due`
  subscription whose charge failed becomes `active` again, which grants
  entitlements nobody is paying for, and a late `cancel_at_period_end: false`
  tells every consumer a cancellation was called off.

  **This is not the same guarantee as at-most-once, and neither replaces the
  other.** `stale_delivery` refuses a delivery that arrived *late*; two
  deliveries of *one* event id that arrive *together* are both current, both
  pass it, and only the outbox's unique index on the processor event id
  separates them. See "Webhooks in" below.

Every refusal raises `Subscriptions::Refused`, which the webhook layer records as
`ignored:<reason>` and answers 200. The reasons are part of the contract:
`unknown_customer`, `unknown_plan`, `no_subscription_to_update`,
`canceled_is_terminal`, `no_change_to_record`, `stale_delivery`,
`account_mismatch`.

**`account_mismatch` is the seventh and the only one about tenancy.** The other six
ask "can this delivery be applied to this subscription?"; this one asks "whose
subscription is it?" and the answer is not allowed to change. A delivery whose
resolved customer belongs to a **different account** than the row is on is refused
rather than applied, in `Lifecycle#apply` and **before** `assign_attributes`. Two
details are load-bearing and both were proven by a mutation: it must be *before*
the overwrite, or it compares the new account with itself and always agrees; and
it must be guarded by the row **existing**, or it breaks the
deletion-arriving-before-its-creation rule. The model's
`account_is_the_customers_owner` cannot do this job — after a reassignment the new
account genuinely belongs to the new customer, so that rule passes. See
`REPORT-billing-13-fixes.md`.

## Charges and receipts

A `Charge` is billing's own record of a payment, distinct from `Pay::Charge` (the
processor's record). The rule the whole surface turns on: **a charge is recorded
when a payment succeeds, and never when it fails or is pending.** The processor
says so on a signed webhook, and the `charges` table is the record of what it
said. There is no code path that writes a charge from a cafaye request.

- **`Webhooks::Charges::Recorder` is the only writer of a `Charge`.** It is
  called from `payment_emission`, inside the ingestion transaction, so a charge
  and the `billing.payment.succeeded` event that describes it commit together.
  It screens the payload rather than raising: a failed payment, a zero-amount
  settlement, a negative one and a payment for an unknown customer all record
  nothing, and the event is still published. Integrity failures propagate so the
  ingestion layer classifies them as `ignored:duplicate_delivery`.
- **`processor_charge_id` is UNIQUE**, and that index is the resolution mechanism
  for a redelivery. A one-time Checkout payment carries no charge object, so the
  payment intent is recorded there — it is the processor's own unique id for
  that payment.
- **`GET /v1/charges/{id}` renders the receipt as a self-contained HTML
  document**, scoped by the token's account. A cross-tenant read is a 404 — the
  same answer a uuid naming nothing gets. Every interpolated value is
  HTML-escaped without exception, because the description is the processor's own
  text and a price named `<script>` must not execute in a page served from this
  origin. The document is marked `html_safe` only after the values are escaped.
- **`account_id` is denormalised onto the charge** at recording time, from the
  resolved subscription or customer, so the receipt route can scope by it
  without a join — the same reason `subscriptions.account_id` is denormalised.

## Webhooks in

A processor's event arrives signed, is stored verbatim, is acted on at most
once, and leaves as one of this service's own events. It may also *write*: a
subscription event applies to the subscriptions table, inside the same
transaction that marks the delivery finished. The rules:

- **The signature is over the raw bytes.** `request.raw_post`, never `params`
  and never a re-serialized parse — the digest is computed over
  `<timestamp>.<raw body>`, so a re-serialization produces a different digest
  and rejects every real delivery. `Stripe::Webhook.construct_event` does the
  verification; nothing here re-implements the scheme.
- **An unverified body is stored nowhere.** It is not an event, and writing one
  would put an attacker's JSON in the row a human reads when something is wrong.
- **`stripe_event_id` is UNIQUE, and that index is the correctness mechanism**,
  not a query aid. `ProcessorWebhook.ingest` turns the resulting conflict back
  into a lookup, so two concurrent deliveries of one event produce one row.
- **The UNIQUE index on that row is not, by itself, at-most-once — and the gap
  between the two cost this service a duplicate charge.** It makes two concurrent
  deliveries of one event id agree about *which row* they hold; it does not make
  them agree about the answer. `Ingestion#call` reads `handled?` and then acts,
  and `handled?` reads a column neither thread has written yet, so under READ
  COMMITTED both read `nil` and both emit.
  **At-most-once therefore rests on a second constraint, in the outbox:**
  `outbox_events_processor_event_id_idx`, a partial unique index over
  `((data ->> 'processor_event_id'))` where that key is present. It is an index
  over an existing column and not a new one **because the outbox column list is
  core's contract** — core's `docs/event-outbox.md` says "the column list is the
  contract", and the key is already in `data` because `provenance` puts the
  processor's own id in every webhook-emitted payload.
  A duplicate refused by that index is recorded as `ignored:duplicate_delivery`,
  **not** as `failed:` — the event exists, written by the request that won, and
  parking it would put a row in front of a human for a correct event.
  And the property is **more than one constraint, and not on this table alone**:
  a start payload deliberately carries no `processor_event_id`, so a duplicate
  `customer.subscription.created` never reaches the outbox index — the second
  `INSERT` into `subscriptions` is refused first. **Which** refusal is a
  scheduling accident, not a fact to write down: `subscriptions` carries a
  uniqueness *validation* on `processor_subscription_id` in the model and a
  unique *index* over the same column, and either thread can be refused by
  either. Measured on this branch over 60 barrelled duplicate creations: **57
  refused by the index, 3 by the validation.** Neither is individually
  sufficient to reason about — dropping either one alone still prevented the
  duplicate, while dropping *every* index on `subscriptions` reopened it (two
  subscription rows, two `billing.subscription.started` events). So the honest
  statement is that the duplicate is prevented as long as the model's validation
  and the table's index are both there, and the ingestion layer is therefore
  written against the **exception**, not against a named constraint.
- **A uniqueness failure and a unique-index violation are one fact, and
  `Ingestion` classifies them as the decision they are** —
  `ignored:duplicate_delivery`, answered 200, never `failed:`. Before this, 3
  deliveries in 60 were parked for a human over an event that was published and
  perfectly correct, purely because a validation won the race instead of an
  index. The classification is on the *error* (`:taken`), not the exception
  class, because a `RecordInvalid` with no uniqueness error in it is a bug in
  this service and still belongs in front of a human —
  `ingestion_test.rb` holds both directions as their own tests, so widening the
  rescue into a blanket one fails rather than being argued about.
- **A delivery's id and the payload that arrived with it are one value.**
  `stripe_controller.rb` passes `event_id: payload["id"]`, and
  `Webhooks::StripeEvents.provenance` reads that same field to stamp the emitted
  event, so in production the two cannot disagree. A test helper that varies the
  delivery's id while leaving the body's id at the fixture's is arranging a state
  Stripe never sends — and the outbox index above makes it fail loudly instead of
  publishing two events that both claim to be the same one. Three helpers did
  this; the one-line merge is in each, and a test pins the invariant.
  `test/services/webhooks/concurrent_delivery_test.rb` holds all of it, and
  `AGENTS.md`'s rule on concurrency tests below is written because of it.
- **The outbox row and the `processed_at` that marks the delivery finished are
  one commit.** If they were two, a process that died between them would leave a
  row that looks unfinished with the event already published, and the next
  delivery would emit a *second* `billing.payment.succeeded` with a second
  envelope id for one charge. Do not move `handled!` out of the transaction.
- **A replay, an unknown type, a deliberate ignore and a failed mapping are all
  200.** Each is recorded and terminal, and a retry reaches the identical
  outcome. A 5xx teaches a processor to retry a decision already made, and hides
  a parked row behind a timeout. `processor_webhooks.error` is the record:
  `ignored:<reason>` for a decision, `failed:<class>: <message>` for a row
  parked for a human, NULL `processed_at` for the one state a crash leaves.
- **A missing signing secret is a 503, not a 400.** It is our
  misconfiguration and saying the signature was invalid sends an operator
  looking in the wrong place. The cause is logged; the body says only
  `unavailable`.
- **Nothing here is token-authenticated, and nothing here may become so.** The
  sender is a processor, not a cafaye client. A `Bearer` on this path would be a
  second, weaker trust path to the same door.
- The webhook is **not** the state. Nothing here writes a subscription or a
  payment; it writes the receipt and the event. The tables for that are a later
  packet, and until they exist `subject` is the processor's own id — recorded as
  a DECISION in `cafaye.yml`, and changed by one line in
  `Webhooks::StripeEvents.subject_for`.

## Observability

OpenTelemetry, in this service rather than only in kit's toolkit, and **on by
default in every environment**: unset, `BILLING_OTEL_ENDPOINT` is the collector
that ships with kit's stack. A developer running `bin/rails server` and a deployer
both get traces without assembling anything, and a self-hoster already running a
backend sets one variable and kit's stack goes quiet. That is the whole of core
D16, and it is a *default* rather than a production-only switch because a
production-only switch is a no-op everywhere it is actually used — including in
this repository's own suite, where every redaction assertion would then pass
having proved nothing.

**One span per request, `billing.http.request`**, recorded by
`lib/middleware/request_telemetry.rb`. `kind: :server`, the method, the status, and
— where one exists — the **route template**.

**One span-attribute allowlist, in `Kit::Telemetry`, and it is a choke point
rather than a convention.** Every attribute goes through `Kit::Telemetry.record/2`,
which drops anything not on `ALLOWED_SPAN_ATTRIBUTES`. The realistic failure is not
an attacker: it is a well-meaning engineer in six months adding
`span.set_attribute("customer.email", customer.email)` because it would help debug
a subscription, in the service whose rows carry a customer's email, a processor id
and a price in minor units. **Do not call `span.set_attribute` directly** — a
`set_attribute` on a span billing owns bypasses the allowlist by exactly as much as
the engine will later strip, which is to say it succeeds. Four names are allowed
and each is bounded rather than merely allowed:

| name | why it is bounded |
|---|---|
| `http.request.method` | eight values in HTTP/1.1, nine in HTTP/2 |
| `http.response.status_code` | an integer, bounded by the protocol |
| `http.route` | **one value per endpoint**, because it is the template |
| `error.type` | a CLOSED vocabulary of three, this service's own |

Three properties of the middleware are decisions rather than conventions, and each
has a test that fails when it stops holding:

- **`http.route` is the template, from the ROUTER'S OWN TABLE.** A template has one
  value per endpoint; a concrete path has one per request, and kit's collector
  derives metrics with a `spanmetrics` connector that mints a series per distinct
  value. The lookup is `[verb, controller, action]` → template, derived from
  `Rails.application.routes.routes` — not a hand-written list of fourteen routes,
  which would be a second answer to "what does the router serve" and would rot the
  way `test/contract/http_surface_contract_test.rb` exists to prove a list rots.
  **A 404 carries NO route at all**: the path of an unmatched request is
  caller-controlled text, so recording it is the cardinality bomb and the content
  leak in one move. The 404 status is the answer.
- **Only 5xx is an error span.** A 401 or a 404 is this service REFUSING a caller,
  which is this service working; an error rate that counts them is a function of
  how much guessing the internet absorbs, and an alert on it pages somebody to
  switch off the protection doing its job.
- **A raised exception's MESSAGE and STACKTRACE are not on the span.** That is why
  the middleware calls `start_span` and finishes the span itself rather than using
  `tracer.in_span`: `in_span` calls `span.record_exception(e)` by default, which
  attaches the class name, the message and the backtrace as a span **EVENT**, and
  an event is exported. An exception message here is built three frames up from what
  a caller sent — `test/integration/secrets_do_not_leak_test.rb` exists because that
  is where leaks live, and the span is a second place the same string would land.
  The status description is `RequestTelemetry::FAILURE_DESCRIPTION`, a constant,
  for the same reason `Problem::INTERNAL_DETAIL` is one.

**Metrics come from the collector's `spanmetrics` connector, not from billing**, and
so do the logs:

- **No `opentelemetry-exporter-otlp-metrics`.** The connector derives metrics from
  spans *after* redaction, so a derived metric can never carry a dimension the
  allowlist stripped, and there is no second definition of the same series anywhere
  in the fleet. The cost is stated rather than hidden: **billing cannot emit a
  gauge**, so "the outbox relay has stalled" is visible only as a flat trace count.
- **No `opentelemetry-instrumentation-rails` / `-rack`.** `use_all!` records
  `http.target`, `url.full`, `url.query` and request headers as its own span
  attributes. Those are exactly the values a redacting collector strips, so
  depending on the engine to strip them would make billing's boundary ONE control
  where this repository insists on TWO. The middleware is hand-rolled for that
  reason and for no other.
- **Logs are the container's stdout.** compose's `logging:` driver ships them to the
  collector's `syslog/crash` receiver, which makes a panic a log record with a
  `service.name` on it and adds no per-language dependency to the `Gemfile`.

### The redaction proof, and what makes it a proof

`test/observability/canary_test.rb` plants a canary in every field a caller
controls — a request body, a path, a slug, a query string, four headers, a signed
webhook body, a malformed `traceparent` — drives REAL requests through the REAL
router, and **raises `THE REDACTION BOUNDARY LEAKED`** if it finds the string in
anything exported. It is a test that fails when the boundary leaks, which is the
only shape a redaction proof can have.

**Every absence assertion in it is paired with a presence one**, through
`TestSpans.rendered!/0`, which RAISES on an empty export. A boundary that deletes
everything passes "no canary" and is useless, and that is not hypothetical: three
separate exporter-contract mistakes did exactly this while this telemetry was being
written, each of which left the suite green —

- an exporter implementing `export(span_datas)` where the callback is
  `export(span_datas, timeout:)`; `SimpleSpanProcessor#on_finish` rescues
  everything and hands the `ArgumentError` to `OpenTelemetry.handle_error`, which
  logs it and continues;
- `SUCCESS` resolved as an unqualified constant from a subclass, where
  `OpenTelemetry::SDK::Trace::Export::SUCCESS` is a **sibling namespace**, not an
  inherited one — the same rescue, the same silence;
- a batch appended as one value, putting an Array of `SpanData` where every reader
  expects a span.

All three are written down in `test/support/test_span_exporter.rb`, next to the
class, because the next person to touch it will be near all three.

**The redaction tier has its own CI step** and its own count. It exists because a
suite that exported nothing would otherwise satisfy every assertion in the file:
`config.x.telemetry.exporter` could come out as something other than `test`, or a
workflow-wide `env:` could set `BILLING_OTEL_DISABLED`, and the whole-suite baseline
would still read green with the proof never executed. The step's equality check and
its zero-skips check are both guards against that, and both were proven able to
fail — see `CHANGELOG.md`.

### Fault injections this packet recorded

Every guard above was broken on purpose, and each one is a claim about a mutation
rather than about the code:

| mutation | caught by |
|---|---|
| `route_template` returning `env["PATH_INFO"]` instead of the template | `request_span_test.rb` — 3 failures; the concrete uuid appears in the export |
| a `span.set_attribute` that bypasses `record/2`, with the canary in the query string | `canary_test.rb` — **THE REDACTION BOUNDARY LEAKED** |
| `"billing.customer.email"` added to `ALLOWED_SPAN_ATTRIBUTES` | `allowlist_test.rb` — both the content-word test and the pinned list |
| `mark_error`'s threshold moved from 500 to 400 | `request_span_test.rb` — 2 failures, the 404 and the 422 |
| `span.record_exception` re-enabled in the rescue | `request_span_test.rb` — the message, the class and the stacktrace are on the span as an EVENT |

**One injection did NOT bite and is recorded because it is instructive.** Recording
the status code *before* `@app.call` returned changed nothing: Rack returns the
status, so the second write simply overwrites the first. In Go the equivalent trap
is real — `http.ResponseWriter` latches its status at `WriteHeader`, so reading it
early reads a 200 forever — and `identity`'s telemetry tests hold that one. The
difference is a property of the two runtimes, and the asymmetry is why the same
"read the status after" rule is enforced by a test in one service and merely
explained in the other.

### The kit adoption

`kit.ref` pins the kit commit, `bin/dev` is **kit's own script verbatim**, and
`docker-compose.yml` is an OVERRIDE on kit's stack: it names this service, its
database and its crash layer, and it carries **no collector configuration**, **no
postgres container of its own**, and **no `depends_on: otel-collector`**. That file
holds the redaction allowlist, which kit derives from core's schemas; a service
that owned it would be shipping a telemetry boundary nobody derived. Nothing but
the collector may be in a readiness path, because a service that waits for the
collector serves no traffic while the collector is down — strictly worse than
serving traffic with no traces, and it teaches people to switch telemetry off.

`bin/migrate` exists for one line of real content and the reason is in its header:
kit's `bin/dev` falls back to `bin/rails db:prepare`, and on a machine where
bundler installs into its own `libexec/gems` that fallback cannot find the gems.
`bin/migrate` is the FIRST probe kit reaches for, and it is `bundle exec rails
db:prepare`.

## CI

`.github/workflows/ci.yml` has four jobs, and **the job names are the claims** —
a green tick over unnamed steps is a green tick over an unknown amount of work,
and in this repository the unknown is load-bearing.

| job | what it is |
|-----|------------|
| `ruby (kit)` | `uses: cafaye/kit/.github/workflows/ci.reusable.yml@master` with `language: ruby`. The shared half. Fails on two steps, absorbed by `continue-on-error` — see below. |
| `gate` | THE gate. `bin/prime` against a real Postgres, every environment-gated tier forced on and counted, and `git diff --exit-code`. Four tiers are named: the whole suite (998 / 2842 by equality), the redaction tier (48 / 118), the contract tier (45 / 400) and the webhook tier (163). |
| `security` | `brakeman` and `bundler-audit`, with no database. |
| `pins` | One Ruby number in three files, the documented `uses:` path, and no secret in the file. No toolchain, so it fails in seconds. |

Four things that are not obvious and that the file argues in full:

- **`bin/prime` is the gate, in CI and locally.** Not a hand-assembled list of
  its four steps. A shared workflow that retyped them would be a second gate, and
  a second gate is a second thing to be wrong.
- **A caller cannot give a reusable workflow a database.** GitHub allows only
  `name`, `uses`, `with`, `secrets`, `strategy`, `needs`, `if`, `concurrency`
  and `permissions` on a job that calls one, so `services:` is unreachable from
  a caller. That, and the tier counts and the lockfile, are why the companion
  jobs exist at all.
- **`ruby (kit)` fails on two steps, and `continue-on-error` absorbs them.**
  `bundle exec rake` is `rails test` and kit's `ruby` job declares no service
  container, so it dies with `ActiveRecord::DatabaseConnectionError`; and
  `bundle exec rake coverage` is a task this service does not have and should
  not want, because the coverage gate here is `MoneyPathsCoverageTest` and it
  runs inside `bin/prime`. Both errors are reproduced in the file's header.
  The failures are visible and non-blocking, and `gate`, `security` and `pins`
  are the required checks — a job that is expected to be red and is not marked
  for it makes the whole workflow red, and a workflow that is always red is one
  whose red means nothing. `continue-on-error` outlives the gap only if nobody
  deletes it, so the condition for retiring it is written into the file: kit's
  `ruby` job grows a `services`/`env` seam, **and** `rake coverage` exists here
  or kit stops running it.
- **The suite size is held by equality, not as a floor.** `950 runs / 2724
  assertions / 0 skips` is the number asserted at the top of the workflow on this
  branch, which is billing-13's three cross-tenant fixes on top of billing-08's
  hardening, billing-09's race fix and billing-12's tenant isolation. master at
  `8bbbcec` was `913 / 2598` and master at `e63bb7a` was `763 / 2100`; both
  differences are itemised in the workflow's own header so a reviewer does not have
  to reconstruct them.
  A floor would accept a suite that lost 200 tests, and the tests it would lose
  first are the money arithmetic and the webhook signatures. Adding a test turns
  CI red until
  `BASELINE_RUNS`/`BASELINE_ASSERTIONS` are raised **in the same commit** — that
  is the intended direction, and lowering one is not. They were 950 / 2724 and are
  now **998 / 2842**, and the whole of that difference is the 48 tests and 118
  assertions in `test/observability/`, itemised in the workflow's own header.

  **The tiers are measured by directory, and `test_helper.rb` requires all of
  `test/support/**/*.rb`** — so a `_test.rb` file living in `test/support/` joins
  **every** CI tier that names any other path. A file placed there inflated the
  contract tier's 45 runs to 53 and the webhook tier's 150 to 159, for a file that
  belonged to neither. **Put a test in the directory of the thing it tests.**
  `test/support/` is for modules, and a module there is what every other test file
  is entitled to load. The same mechanism is why the webhook tier asserts five
  files' worth of tests while listing four: `concurrent_delivery_test.rb` arrives
  through that require rather than by being listed.

### The tier that skips without you noticing

`test/contract/outbox_envelope_contract_test.rb` reads core's real schemas and
**skips every test in the file** when it cannot read them, printing
`skip("core is not on disk; set CORE_PATH to …")`. Measured on this branch, same
commit, same code, with `CORE_PATH` pointed at a checkout and then at nothing:

| `CORE_PATH` | `test/contract` (the tier) | whole suite |
|---|---|---|
| a core checkout | 45 runs, 400 assertions, 0 skips | 950 runs, 2724 assertions, 0 skips |
| pointing at nothing | 45 runs, 61 assertions, **19 skips** | 950 runs, 2381 assertions, **20 skips** |

(Re-measured on this branch, by moving `../core` aside rather than by reading the
old row forward. The contract tier is **unchanged** at 45 / 400 — billing-13 added
nothing under `test/contract/` but a version pin — so the 19 skips are the same 19.)

**Same run count, same exit code, and 343 assertions of contract checking simply
not done.** A green run that did not notice would have reported "the outbox
contract holds" while having checked nothing at all. The whole `test/contract`
directory is the tier; it is named as a directory rather than a file list because
billing-07 moved three tests into `http_surface_contract_test.rb` and a file list
read that relocation as a deletion — and because billing-08 added
`tenant_isolation_matrix_test.rb`, which does not read core at all and therefore
must not be reachable through a path that skips.

A second test reads core and did not say so: `subscription_delivery_test.rb`
asserted against `Rails.root.join("..", "core")` with no seam at all, so a
developer with the repositories side by side passed and **a CI runner raised
`Errno::ENOENT` before asserting anything**. It reads `CORE_PATH` now, and
`gate` sets that variable on the job rather than on one step, because a variable
set per step is a variable the second reader does not get.

So:

- **locally**, a `19 skipped` in the contract tier, or a skipped test named
  "both events courier needs have a row in core's catalog", is a missing core
  checkout, not a pass. Put `core` next to this worktree, or set `CORE_PATH`.
- **in CI**, `gate` checks `cafaye/core` out of the repository itself and
  **fails the build on a single skipped test**. `cafaye/core` is public, so no
  token is involved, and the ref is `master` rather than a pinned SHA on purpose:
  this tier exists to catch a change in core, and a pinned ref would blind it.

### The worktree that could not see the tier, and no longer cannot

**A worktree never could, and that is a fleet-wide hazard, not a billing one.**
Both files above answered "where is core" as `Rails.root.join("..", "core")`,
which resolves beside the **main** checkout — at `<root>/billing`/`<root>/core` —
and resolves to *nothing* from a worktree, which lives at `<root>/wt/billing-<name>`
and has no `core` sibling. So every worker on this machine, gating in a
worktree, ran a suite that silently skipped the whole contract tier and reported
0 failures. **BRK-4R2 measured exactly that: the worktree reported 21 skips and a
pass; the merged tree, on the same commit with the same code, reported 0 skips
and one failure.** The red was never in the merge. It was in the environment —
20 skipped tests in `outbox_envelope_contract_test.rb` plus the 21st in
`subscription_delivery_test.rb`, and among them the one payload contract test in
this repository. A green that was made green.

**The resolution is one answer, in `test/support/core_location.rb`.** The order
is `CORE_PATH`/`CORE_SPECS_PATH` (CI's seam, unchanged), then `../core` beside
`Rails.root` (the main checkout, which is what the documents describe), then
**core beside the primary worktree**, found through `git worktree list
--porcelain` — so a worktree resolves the same core its main checkout does. Both
readers call it, so they cannot drift, and `test/contract/core_location_test.rb`
asserts that it resolves **with nothing configured**, from this directory. Do not
shorten the resolution back to the sibling path: that test goes red, which is
the point.

Three things about that module are load-bearing and each is asserted rather than
commented:

- **`primary_worktree` returns `nil`, never `Pathname.new("")`.** An empty
  Pathname expands to the process's working directory, which is a real directory
  and which carries a `cafaye.yml` — so an empty lookup validated as "found" and
  handed the caller the worktree itself, where there are no `schemas/`. That bug
  was written, and it was invisible until the skip was looked at, and it is the
  same failure the module exists to prevent, one level down.
- **A directory is core only if it holds `schemas/` and a `cafaye.yml`.** A
  `cafaye.yml` alone is what a failed lookup lands on.
- **The skip is not weakened and not deleted.** A repository cloned on its own
  has no core beside it and no `CORE_PATH`, and answering "no problem" for a
  schema never read is the outcome a contract test exists to prevent.
  `checkout` returns `nil` there and the callers still skip.

The consequence in the workflow is that **the local and CI baseline numbers are
now one number.** They used to differ by 361 assertions, which were the
core-contract tier's, absent locally because a worktree skipped them. `BASELINE_`
is the same figure in both places now, so a local run reporting a different count
from CI's is a run that is missing the tier.

### The other environment-gated tier

`config/environments/test.rb` sets `config.eager_load = ENV["CI"].present?`.
GitHub Actions always exports `CI`, so the suite eager-loads the whole
application in CI and not locally — which means "the application loads" is
checked in CI by an *implicit* convention. `gate` sets `CI` explicitly and has a
step that fails if `config.eager_load` is false, or if `eager_load!` loaded
fewer files than `app/**/*.rb` contains (38 on this commit).

### Secrets

No processor key is in the repository, in CI configuration, or in any log. The
suite generates its own Stripe signing secret per run
(`StripeWebhookHelpers::WEBHOOK_SECRET` in `test/test_helper.rb`, a credential
for nothing) and talks to `FakeStripeAPI`, never to Stripe. The `gate` job
asserts `STRIPE_API_KEY` and `STRIPE_WEBHOOK_SECRET` are absent from the
environment, and the `pins` job fails the build if the workflow file ever gains a
`${{ secrets.… }}` reference, a Stripe key, a signing secret or a PEM header.

## Testing

- Tests are written **first**, and shown failing before the implementation.
- **A tripwire that has never been seen red is a check that has never been
  tested.** Every drift check here is proven by a mutation that makes it fail and
  by the output that says so — and the mutation is reported, because "I broke it
  on purpose and it noticed" and "I think it would notice" are different claims.
  The direction of the failure matters too: a comparison that stops at the first
  of two directions hides the second behind it, and one of the two is often the
  one that finds the bug.
- **Clocks are injected, never read.** `travel_to(frozen_now)` and derive the
  expected string from `TestSupport::FrozenClock::NOW`. An assertion containing
  a wall-clock timestamp is a test that fails on a different day than it was
  written. Production code calls `Time.current`; that is the seam.
- A test that creates rows to assert on *ordering* gives each row its own
  instant. Otherwise the order falls to the uuid tiebreaker, which is random, and
  "newest first" becomes an assertion about uuid generation.
- No sleeps, no raised retries, no loosened assertions. A flaky test is
  attributed before it is fixed: failing test → can this diff reach that
  surface → measure the baseline at a clean HEAD.
- **A concurrency test manufactures its interleaving; it never waits for one.**
  Two threads doing the same thing at the same time is a *probable* race, and a
  test asserting a probable outcome is a flake generator that passes on a fast
  machine and fails on a loaded one. The window is entered on purpose: a
  two-party barrier (`Mutex` + `ConditionVariable`, **no timeout** — a timeout
  here is a sleep with a nicer name, and it turns a deadlock into a flake) holds
  both threads inside the check-then-act window until both have arrived.
  Three things this repository has already had to learn, all of them from
  `test/services/webhooks/concurrent_delivery_test.rb`:
  - **A thread's commit does not invalidate the main thread's query cache.**
    Active Record's cache is on in the test environment, cleared between tests
    but *not within one*, and every count is taken on the main thread after the
    workers committed. Counts came back stale — `0` for a table holding a
    committed row. The cache is dropped once, after the last commit, and counts
    read through `uncached`.
  - **`prepend` cannot be undone.** A file-scope `prepend` in a test changes
    every other test in the suite for the rest of the run; install a gate with
    `alias_method` on the class and restore it in `ensure`.
  - **Running a migration commits the enclosing transaction**, so a
    reversibility test inside a transactional test class makes its own rows
    durable and breaks unrelated tests. It gets its own file.
- **Threads need their own connections, so the test that uses them cannot be
  transactional** — it would assert against an empty database while the workers
  wrote real committed rows. The cost is rows that outlive the test, so the
  teardown clears every table the path writes, in both directions (children
  before parents), and the list of tables is written down rather than left as a
  blanket truncation. Two classes in this repository do this, each for a stated
  reason.
- The database-down path is exercised for real, not asserted about: fake the
  leased connection with `with_lease_connection` in `test/test_helper.rb`.
  minitest 6 removed `Object#stub` (it moved to the `minitest-mock` gem, which
  this service does not depend on), so that helper wraps the stub registry
  ActiveSupport already ships. Do not reintroduce the removed API.
- A contract check against `core` reads core's files rather than paraphrasing
  them, and compares **behaviour** rather than text. Comparing a `Regexp#source`
  to a pattern string looked equivalent and was not: Ruby's regexp optimiser
  reports different sources for the same pattern in different processes.
- **A validator that skips a constraint it does not understand reports "no
  problem" for a document it never checked.** That is the failure a contract test
  exists to prevent, so the payload validator in `test/contract/` has a closed
  vocabulary — `UNDERSTOOD_KEYWORDS`, `JSON_TYPES`, `UNDERSTOOD_FORMATS` — and
  raises on anything outside it. A drift test walks every keyword core actually
  uses and fails once, by name, when a shape appears the validator does not model.
  Do not widen a check into a `rescue`, and do not turn the raise into a `return
  true`: a breach reported as clean is worse than a breach reported as a crash.
- **A recorded-debt table may never become the thing being iterated.** An empty
  table exits 0 having checked nothing, which is a skipped test in everything but
  name. Every table in `test/contract/` is therefore *derived* from core's files
  and compared, so the work is over core and not over the constant.
- Raising a threshold is allowed. Lowering one, or adding an inline lint
  disable to make a build green, is not.
- A gap that cannot be closed in this worktree is recorded in code, not skipped
  quietly — see `PENDING_CORE_CATALOG_ROWS` and `PENDING_PAYLOAD_ALIGNMENT` in the
  contract spec. Both are asserted **as sets**, not subtracted from the failures:
  subtracting would let a payload that starts matching sit there forever.
- A webhook spec posts **committed fixture bytes**, signed with a constant that
  is a credential for nothing, and asserts against the real verification path. No
  network, no stubbed verifier. The fixtures' `created` timestamps are what the
  event-time assertions are derived from, so a fixture edited without its tests
  failing is a fixture nobody looked at. `construct_event` appears nowhere under
  `test/`, and the `gate` job in CI fails the build if it ever does.
- **`rails test` runs in parallel workers, and each worker gets its own
  database.** `test_helper.rb` calls `parallelize(workers: :number_of_processors)`,
  so a run creates `<database>_0` … `-7` beside the base database and eight
  workers never share one. The number of workers changes the wall clock and
  nothing else — the same tests and assertions with one worker or eight, verified
  both ways on this packet — which is why the gate counts tests and never
  seconds.
  What parallel workers do **not** protect against is two `rails test` processes
  in the *same* worktree — they race on the same per-worker databases, and a
  per-checkout database name separates worktrees from each other, not processes
  from each other. One checkout, one suite.
- **A worker that dies abnormally makes the suite hang, not fail.** Rails runs
  the parallel workers over DRb and
  `ActiveSupport::Testing::Parallelization::Server#shutdown` waits with
  `while active_workers?; sleep 0.1; end` for each one to deregister. A worker
  killed before it can deregister is never reaped and the parent spins in that
  sleep at teardown — **after** printing the summary line. So a green
  `823 runs, 0 failures` summary followed by nothing is that, not a pass.
  Nothing
  suppresses it: the job times out and goes red, and the count guard never
  runs. Do not "fix" it with retries; find the worker that died.

## Conventions

- **Never** edit `Gemfile.lock` as a side effect. A lockfile change is its own
  commit with its own reason. `bin/prime` only ever runs `bundle install`.
- **Never** copy code from `moon/refs/` into this repository. `jumpstart-pro` is
  a licensed product and the shallow clones are behavioral references only;
  every line here is written from scratch (PLAN §2).
- **Never** add a gem without saying so in the PR body. Rails defaults and `pg`
  are the current floor; a new dependency is a decision, not a convenience. Three
  have been added since, each with its cause in the `Gemfile`'s own comment:
  `opentelemetry-sdk` and `opentelemetry-exporter-otlp` (without them billing
  cannot emit a span at all and the collector kit ships has nothing to redact, so
  they are the floor rather than a choice among alternatives — see
  [Observability](#observability)), and `jwt` (billing-21, and the reason is the
  same as `stripe`'s: this is the one place a forged credential must never be
  believed, and a hand-rolled verifier is how `alg: none` and
  HS256-signed-with-the-public-key get through — see
  [Authorization](#authorization)). **What was NOT added is as load-bearing**, and
  each is named where it was refused: no `-metrics`, no `-instrumentation-rails`,
  no `-instrumentation-rack`, no log SDK, and **no JWT library beyond `jwt`** —
  core's JWKS verification is not a gem to add, it is `guard`'s job, and billing
  reading a token is a dependency on identity's *published keys*, which is what it
  does.
  (This is why there is no JSON Schema validator, no outbox gem and no HTTP
  client: each would have been one, and each was refused.)
- Errors are raised at the boundary with the identifier needed to find the
  failing row, not just a message — and a failure message never returns to an
  HTTP caller. `/readyz` logs the database error and answers a generic 503, and
  `Problem::INTERNAL_DETAIL` is a constant for the same reason.
- Every non-2xx is `application/problem+json`, built by `app/lib/problem.rb`.
  Never render an error body any other way, and never let Rails render one:
  `config.exceptions_app = routes` is what makes a 404 on an unknown path and a
  500 on a bug problem+json too.
- `rescue_from` runs *outside* the `after_action` chain. Anything a rescue
  handler renders must set its own headers — this is why `render_problem` calls
  `set_trace_id_header` and does not rely on the callback.
- Rails `enum` is not used on request-shaped columns. It raises `ArgumentError`
  on an unknown value, which at an HTTP boundary is a 500 for something the
  client got wrong. Use an inclusion validation plus a `CHECK` constraint: the
  database still refuses what the model would not have written, and the client
  gets a 422 naming the field.
- Migrations do not read model constants. Inline the literal, so the migration
  keeps meaning what it meant the day it ran.
- A column named `type` is single-table inheritance on any Active Record model.
  `processor_webhooks.type` is the processor's own type string, so the model sets
  `self.inheritance_column = nil`. That line is load-bearing, not tidiness:
  without it every `find` on the table tries to resolve
  `customer.subscription.updated` to a class and raises.
- **A partial unique index is a statement about a set of statuses, and it is
  tested behaviourally.** `subscriptions` is unique on `(account_id, plan_id)`
  *where the subscription is live*, because `canceled` is the only terminal status
  and a customer who cancels and returns has to be able to subscribe to the same
  plan again. Comparing the index's predicate to a string in the model would prove
  two texts agree, which is not the same fact; the specs insert two rows per
  status pair and ask whether the database objects. **Both accounts in
  `test/support/two_accounts.rb` deliberately share one plan**, because with a plan
  each, `(account_id, plan_id)` would be satisfied by `plan_id` alone and a
  dropped `account_id` from the index would go unnoticed.
- **A partial unique index is also the honest way to say "a value here is
  unique", on a nullable column.** `customers.processor_customer_id` and
  `plans.processor_price_id` are unique **where not null**, because a customer
  created through `/v1` has no `cus_` and a plan not yet on sale has no `price_` —
  many rows are legitimately in that state at once. A bare `unique` index would
  allow that only by way of PostgreSQL's `NULLS DISTINCT` default, and that is a
  **database default rather than a statement of intent**: `NULLS NOT DISTISTINCT`
  (PostgreSQL 15) is a feature a future migration could set for an unrelated
  reason, and it would turn every not-yet-on-sale row into a collision. The
  partial index has no such dependency, because a null is not *in* the index.
  **And the test does not overclaim**: the null-rows test proves repeated nulls are
  permitted, which is not the same as proving the predicate — a bare `unique`
  index would pass it too. The comments in both migrations say so.
- **A test that rebuilds what it measures cannot detect a wrong thing about
  it.** The two index migration tests roll the index back and up to prove the
  `down` works, so an assertion *inside* them about the index's shape read an index
  the file had just created itself — a non-unique index was repaired by whichever
  test ran first and the assertion passed. The observation lives in
  `test/tenant/cross_account_findings_test.rb`, which never mutates the schema.
- **A cross-account spec must not print the other account's row.** "This write
  changed nothing over there" is naturally written by comparing the records, and
  on failure that dumps a whole other account's subscription, price and status
  into CI output. `TwoAccounts#fingerprint` is a per-row `sha256` for that
  reason: it says *byte-identical* without saying what the bytes were, and
  `drifted_ids` names **which** ids moved. It is a hash keyed by id, not one
  digest over a set — on a String, `before[record.id]` is a substring search,
  `nil` for every uuid, so every row reports as drifted and the assertion is true
  on every run including the runs it exists to catch. The HTTP specs use
  `include?` with a sentence in the message rather than `assert_includes body,
  sentinel`, for the same reason, and use **two** sentinels: writing a row the
  value it already holds is a no-op, and a no-op cannot distinguish "the write
  reached the other account" from "the write reached nobody".
- **A data access added to `app/` is an entry point and fails the matrix by
  name.** `test/tenant/account_entry_point_matrix_test.rb` scans `app/` and
  compares the result against its table in both directions, so a new query does
  not ship unclassified. The key is `path` + **method**, not line, so a comment
  does not renumber the table — and the **kind** is part of the key, because
  `Lifecycle#apply` both creates a row and writes to one and a
  `(path, method)` key alone would have to pick between them and undercount. An
  association and a `scope` are both queries and both count, **but only when the
  declaring class holds tenant data** — which is checked on the *declaring class*
  read out of the file, so `IdempotencyKey#scope :expired` stays out and the
  three-model tenant-data pin stays true.
- **A `uuid` column casts before a validation sees it.** `"not-a-uuid"` assigned to
  a `uuid` attribute becomes `nil`, so a shape validation on such a column is
  unreachable code that reads as if it were doing something. `Subscription#account_id`
  deliberately has none, and the presence validation is what reports the problem.
  (`Customer#owner_id` has one and it is equally unreachable — noted, not changed:
  it is not this packet's model to refactor.)
- **Every problem in a request body is reported at once.** A client that sent
  three wrong fields gets three failures, not the first one three times. That is
  why `V1::SubscriptionsController#refuse` *records* and the action renders once,
  and it is the same rule `render_validation_failure` already follows for a
  model's own errors.
- **A processor's message never returns to a caller.** It is logged with the
  identifier that was refused, and the body says only what this service knows: a
  503 for a processor it cannot reach, a 422 naming the plan. The processor's
  internal text is the processor's to decide who sees it.
- Time is UTC, and stored `timestamptz` where the column is an instant. IDs are
  opaque strings. `db/schema.rb` is committed.
- A webhook's event carries the **processor's** timestamp in `time`, not the
  moment this service wrote the row. `OutboxEvent.publish!` takes `time:` for
  exactly this; a model callback omits it and gets `Time.current`. An event
  stamped on arrival makes out-of-order delivery undetectable, because every
  event then appears to have happened in the order it arrived.

## Contracts

- The two probes are infrastructure, not contract surface. They are not in
  `cafaye.yml`'s `exposes` and must not grow query parameters, auth, or a
  versioned payload — an uptime monitor is the only reader.
- `openapi/v1.yaml` is the HTTP contract, `/v1` on every path and `info.version`
  present (core v0.2, D4). `cafaye.yml`'s `exposes.api` points at it, and
  `test/contract/` fails if the file is not there.
- Every endpoint and event this service publishes is validated against `core`'s
  specs in `test/contract/`. Never hand-write a response shape the OpenAPI
  document does not describe.
- **`/v1` requires a bearer token, and every customer and subscription query is
  scoped by the account it names.** billing-12 measured the gap — 14
  account-scoped routes and 33 data accesses carrying **zero** account scopes — and
  billing-21 closed it. `openapi/v1.yaml` is at **2.0.0** under an **unchanged
  `/v1` prefix**, and the version bump is the signal; see the Authorization section
  for why a second prefix could not be served beside it, and `cafaye.yml` for the
  DECISION NEEDED that records it. `GET /v1/customers` and
  `GET /v1/subscriptions` return **this account's** rows, and a cross-tenant read
  or write is a **404**. A `User`-owned customer is in no account and is therefore
  invisible to `/v1`: which account a user belongs to is identity's fact, and no
  event carrying it is in this build's `consumes`.

  **The three cross-tenant defects billing-12 found on the delivery path — F1, F2
  and F3 — are fixed** (`REPORT-billing-13-fixes.md`; the before is
  `REPORT-billing-12-isolation.md`). **Read both before adding a field to
  `CustomerUpdate` or `PlanUpdate`.** `processor_customer_id` and
  `processor_price_id` are still permitted on the client's **own** row precisely
  because `owner` and `processor` are not — and they were the whole of F2's and
  F3's attack surface. **Both are now unique**, so a client claiming one another
  row holds gets a **409 naming the field** and nothing is written. That is a
  *determinism* guarantee on the delivery path — with the column unique,
  `Lifecycle`'s `find_by` has one answer instead of an arbitrary one — and it
  remains separate from authorizing the caller, which is the account scope on
  every query.
- **A 403 is never the answer here, and the vocabulary enforces it.**
  `Problem::CATALOG` is a frozen table with **no entry of status 403**, so this
  service has no code path to render one; the guarantee is a property of a closed
  set rather than of a review, and `test/tenant/cross_account_web_test.rb` also
  scans `app/` for `403` and `forbidden`. **A resource the caller cannot see must
  be indistinguishable from one that does not exist** — a 403 says "this exists,
  you may not have it", which is an enumeration oracle. Absence, or a nil at the
  query. Do not add a 403 to this service. A 404 *is* the answer for another
  account's resource, and the difference from the pre-billing-21 case is the whole
  point: then there was no caller to compare against, so a 404 would have refused
  a legitimate request and broken every client while pretending to be a security
  fix. There is a caller now, so absence is enforceable and 403 is redundant.

  That scan **skips comment lines**, and that is not tidiness: the new code
  *explains* this rule in prose containing the word "forbidden", and a scanner
  whose only remedy is deleting the explanation is backwards.
- **`/v1/webhooks/stripe` is the one path that is not JWT-authenticated, and it is
  not an oversight.** It authenticates the *processor*, not a cafaye client, by
  signature over the raw body. It is declared in `openapi/v1.yaml` under the
  `webhooks` tag with its own `200`/`400`/`503` responses and **`security: []`**,
  which is a declaration and not a default: an operation that inherits the
  document's `bearerToken` requirement would be telling a processor to send a
  token it does not have. `test/authentication/principal_lock_test.rb` reads the
  boundary from the router's own table, so a controller added to that namespace
  cannot pick up the token filter by accident. Its dedupe key is the processor's
  event id enforced by a unique
  index, not an `Idempotency-Key` header, and it takes no query parameters. A
  test asserts the manifest's `exposes.api` document declares the path that
  `config/routes.rb` serves.
- Every event type the webhook mapping can produce is in `OutboxEvent::TYPES`
  and in `cafaye.yml`. A type that is not would be refused at the write, from
  inside a processor request, and answered 200 — an outage visible only in the
  processor's dashboard. `test/contract/` and the webhook specs both assert it.
- **The three subscription events are published in a shape core's payload schemas
  reject, and that is recorded rather than matched.** core-03 shipped a payload
  schema for all eight types. For `billing.plan.*` this service now satisfies
  them except for `entitlements`, which core's plan schema does not name. For
  `billing.subscription.*` the disagreement is larger: core's D10 rewrote those
  three schemas on the grounds that "billing has no subscriptions table", which
  was true of billing-03b and stopped being true when billing-04 added one and
  moved the events onto billing's own ids. They are recorded in
  `PENDING_PAYLOAD_ALIGNMENT` and asserted in **both** directions, and named as a
  DECISION NEEDED in `cafaye.yml`. Do not "fix" this by editing the payload:
  matching core means either emitting a payload no consumer has agreed to or
  dropping `plan_id` and `account_id`, which are the two fields that make a
  subscription event actionable. core owns the change; see core's own D10, which
  names it as the second breaking change.
- **`PENDING_ID_PATTERNS` is empty, and the test that held it is derived.**
  core's D10 removed the `sub_…` / `pln_…` / `acc_…` patterns, so a field core
  does not constrain has no unclosed gap against it. The table may not become the
  thing that is iterated: a table iterated zero times exits 0 having checked
  nothing, so the contract test *derives* the gap from core's files and compares.
  New debt goes in the table; the assertion reads core, not the table.
- **`billing.subscription.updated`, not `.changed`.** The action vocabulary in
  core's `docs/event-naming.md` is a closed list for v0 and `changed` is not on
  it; `billing.subscription.updated` is, and it is already in core's catalog. The
  vocabulary core has fixed is the vocabulary used here. If the manager disagrees
  it is one constant, `Subscriptions::Lifecycle::UPDATED_EVENT`, and a catalog
  row agreed first.
- **Every `(method, path)` in `openapi/v1.yaml` is served, and every
  `(method, path)` the router serves is in the document or named with a reason.**
  `test/contract/http_surface_contract_test.rb` compares the two as sets, in both
  directions, so an operation added to one and not the other fails **by name**
  rather than describing an API nobody can call. Three things about it are not
  incidental:
  - **It is keyed by method as well as path.** The check it replaced compared
    paths and filtered the router with `start_with?("/v1")`, so `resources`'
    two verbs for one `update` — `PATCH` and `PUT` — were one path on each side
    and it reported agreement. `PUT /v1/customers/{id}` was served, and in no
    document.
  - **The exclusions are named, not filtered.** Every route that is not a client
    operation is keyed by method and path with the reason it is not one, and a
    route that is neither declared nor excluded fails. Otherwise the list rots
    silently and grows a `/internal` nobody argued about — and an exclusion for a
    route that has gone away fails the other way, so a stale one cannot quietly
    cover whatever is added at that path next.
  - **It runs without `core`.** `test/contract/outbox_envelope_contract_test.rb`
    skips when `core` is not on disk, and a check behind that skip is not a
    check. The document checks live beside it because they read the document, the
    manifest and the route set, none of which is core.
- **Every operation has an `operationId`, and no `operationId` is used twice.**
  A generator turns these into method names and nothing else, so a duplicate or
  a missing one is a compile error in a customer's language, discovered by them.
  The fifteen are pinned rather than derived, which is what makes a rename fail
  here: the count is not asserted, the list is, so a removal and an addition are
  different failures.
- **An update is a `PATCH`, and there is no `PUT`.** `resources` draws both verbs
  for one action, and a whole-resource replacement is not what any update here
  is: `CustomerUpdate` is closed, and `owner`/`processor` are not updatable at all
  because they are the key the uniqueness rule is built on — and, since billing-21,
  because the owner is the token's account rather than anything a client names.
  `config/routes.rb` therefore spells the customer routes out, as it already did
  for plans and subscriptions. Documenting the `PATCH`'s behaviour under a `PUT`
  would be a document lying about its own semantics — which is the thing the check
  above exists to prevent.
- **`info.version` is pinned, not derived, and the prefix is a separate question.**
  A non-breaking addition bumps only `info.version`; core's checklist asks for the
  bump if anything else in the document moved, prose included. A test that read the
  version out of the document and compared it with itself would pass every
  document ever written, so the number is written down here and asserted.
  **billing-21 raised it to `2.0.0` and left `/v1` alone**, and that is the one
  place the usual rule does not apply: the break cannot be mitigated by serving
  the old prefix beside the new one, because the old prefix is an unauthenticated
  door and "keep serving `/v1` for compatibility" is "keep the vulnerability".
  The reasoning is in the Authorization section, in `README.md`, and as a DECISION
  NEEDED in `cafaye.yml`; do not "fix" the prefix without reading all three.
- **Every client operation declares `bearerToken`, and the webhook declares
  `security: []`.** `test/contract/http_surface_contract_test.rb` asserts both, so
  an operation added without a security requirement — or the webhook picking one
  up from the document's root — fails by name. This is the check that stops the
  document and the code drifting apart on the one property that decides whether a
  surface is a door or a wall.
- Breaking a contract is a major version plus a migration note in `README.md`
  and `CHANGELOG.md`, reviewed by a human — not a patch.

## Before you open a PR

- [ ] `bin/prime` is green from a clean worktree
- [ ] New behavior has a test that fails without it
- [ ] A span attribute is added to `Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES` **and**
      to `test/observability/allowlist_test.rb`'s pinned list in the same commit, and
      its name survives the content-word test — a name that names content fails there
- [ ] Nothing sets a span attribute except through `Kit::Telemetry.record/2`, and a
      500's span still carries no exception event, no exception message and no
      stacktrace
- [ ] Money changes keep 100% line and branch coverage on every file in
      `MoneyPathsCoverageTest::MONEY_PATHS`, and a file that touches money is in
      that list or in `MIXED_MONEY_FILES` with a reason that still holds
- [ ] A new subscription status is added to the state machine's table, the model's
      set, the migration's `CHECK` and the spec that asserts the grid — the test
      that covers every status fails if any of the four is missing
- [ ] Anything published is in `cafaye.yml`, in `OutboxEvent::TYPES`, and in
      core's catalog — or the gap is written down in both places
- [ ] A new `Refused` reason is added to the list in **Subscriptions** above, to
      `README.md`, and asserted by a test that names it on the delivery row
- [ ] A new unique index is **partial where the column is nullable**, and its
      migration test proves the index refuses the duplicate with the model
      bypassed — plus a test that repeated nulls are still writable
- [ ] A data access added to `app/` is classified in
      `test/tenant/account_entry_point_matrix_test.rb`, with its kind and what it
      touches — and a `scope` or association added to a tenant model is too
- [ ] A new test file is in the directory of the thing it tests, and **not** in
      `test/support/`, which is auto-required into every CI tier
- [ ] `openapi/v1.yaml`'s `info.version` is raised, and any response the code can
      now answer is declared on the operation that can answer it
- [ ] A new `/v1` operation declares `bearerToken` and is scoped by the token's
      account — or is listed as `catalogue` in the tenant matrix **with a reason**,
      and a catalogue route that WRITES is a capability gap written down rather
      than silently unenforced
- [ ] A new controller under `app/controllers/v1/` inherits the principal lock, and
      a new one under `app/controllers/webhooks/` does not — the boundary is read
      from the router's table, so "I put it in the right namespace" is checked
- [ ] Nothing added a 403, and nothing made an unauthenticated surface *look*
      closed with a 404: absence, never refusal
- [ ] Every guard in this packet has been seen red, and the mutation is reported
      — "I broke it on purpose and it noticed" and "I think it would notice" are
      different claims
- [ ] Lint and security scans are green, and nothing was disabled to get there
- [ ] `AGENTS.md` still describes the repository as it now is
- [ ] `CHANGELOG.md` has an entry
