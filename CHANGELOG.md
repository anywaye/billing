# Changelog

All notable changes to billing are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Billing's first tenancy declaration.** `tenancy.yml` at the repository root,
  checked by `core/harness/bin/tenancy-check .` against
  `core/schemas/tenant-isolation.schema.json`. It declares **five entry points**
  — `customer-read`, `customer-write`, `subscription-read`,
  `subscription-write` and `charge-read` — each enforced on the line of the
  `for_account` scope that scopes it (`app/models/customer.rb:95`,
  `app/models/subscription.rb:94`, `app/models/charge.rb:49`) and each proved by
  the three-arm denial shape: `no-identity` (the principal lock's router-derived
  refusal table), `other-account` (a valid credential for a different account,
  answered 404 and compared byte for byte against a uuid naming nothing), and
  `own-account` (the caller's own row's own value, so a service returning
  nothing to everybody cannot pass).

  `rls.databaseEnforced: false` with an empty table list is the truth and is a
  claim rather than a gap: no migration in this tree carries a policy, an enable
  bit or a definer function, and the day one does, `tenancy.rls-undeclared` is a
  failure.

  **Not declared, on purpose:** the `plans` catalogue (a plan has no `account_id`
  column — it is what an account may buy, not what an account owns), the Stripe
  webhook (scoped by the processor's ids and authenticated by signature), the
  lifecycle's resolution of a processor id to a row, the denormalised
  `account_id` stamps `Lifecycle#apply` and the charge recorder write, and
  `delete` (this service serves no such route on `/v1`).

  The checker reads SQL, so it classifies zero sites in a Rails tree and reports
  `tenancy.enumeration-partial` (34 named lines, verified by hand against the
  four kinds of site they are) and `tenancy.scope-key-unused` as **warnings**.
  `tenancy-check .` reports 0 failures, exit 0.

- Two named refusals in `test/authentication/principal_lock_test.rb` —
  `patching a customer` and `reading a receipt` — because the declaration's
  `no-identity` arm for `customer-write` and `charge-read` points at that table
  and the two operations were not in it. The baseline moves 1143/3278 ->
  1145/3280 in the same commit.

### Added

- **The recipient fact on the money events, and the plan's name on the
  subscription events.** billing publishes the fleet's money events and courier —
  the fleet's only consumer — would mail about every one of them: a receipt for a
  succeeded payment, a warning for a failed one, a confirmation for a subscription
  change. None of the payloads carried an address to mail to, and courier has no
  billing client and no billing tables, so every money event was a dead letter.
  This packet puts the fact on the envelope, the same treatment identity's
  `session.revoked` and `user.created` already carry.

  - **`billing.payment.succeeded` and `billing.payment.failed` carry the
    customer's billing email**, resolved in `Webhooks::StripeEvents.with_recipient`
    from the processor's own customer id — one indexed lookup on
    `customers.processor_customer_id` (unique since billing-13), per payment
    event, stated in the builder's comment rather than hidden. A failed payment
    records no charge, so the recorder's own resolution cannot be the one the
    event relies on; the event's builder resolves for itself.
  - **`billing.subscription.started/updated/canceled` carry the same email and
    the plan's name beside `plan_id`.** The customer and the plan are already
    resolved when the lifecycle builds the payload, so both fields cost no query
    the builder was not already making. A mail about a plan change has to say
    which plan, and a uuid does not say it.
  - **The field is named `email`, matching identity's events** — one fleet, one
    field name for the address a consumer cannot look up. It is **absent, never
    null**, when the customer has no address on file or no cafaye row at all: an
    event that promises a mail it cannot address is worse than one that carries
    no address, and a consumer refuses the latter by design.
  - **The gap to core is recorded, not matched.** core's payload schemas are
    closed with `additionalProperties: false` and do not declare either field, so
    `PENDING_PAYLOAD_ALIGNMENT` gains the five entries and `cafaye.yml` a
    DECISION NEEDED — the same recorded-not-matched mechanism as `entitlements`,
    and the same reason: core is read-only from a service worktree. The contract
    test's corpus customer carries an email, because the payment payloads are
    built by resolving that row.

- **Charges and receipts: what a customer was charged, and the page that shows
  it.** A user who pays could not see what they paid for — there was no `Charge`
  model, no receipt, no route. This packet adds the record and the read path.

  - **`Charge` records a settled payment, and never a failed or pending one.**
    The recorder is hooked into `Webhooks::StripeEvents.payment_emission`, inside
    the ingestion transaction, so a charge and the `billing.payment.succeeded`
    event that describes it commit together. The processor's own `paid` and
    `amount` are the only things consulted: a failed payment, a zero-amount
    settlement and a negative one all record nothing.
  - **`GET /v1/charges/{id}` renders the receipt as a self-contained HTML
    document**, scoped by the token's account — a cross-tenant read is a 404,
    byte for byte the answer a uuid naming nothing gets. Every interpolated
    value is HTML-escaped without exception, because the description is the
    processor's own text and a price named `<script>` must not execute in a page
    served from this origin.
  - **`processor_charge_id` is UNIQUE**, and that index is the resolution
    mechanism for a redelivery: two rows for one processor charge would be two
    answers to one question, and a customer would be charged twice on paper. A
    one-time Checkout payment carries no charge object, so the payment intent is
    recorded there — it is the processor's own unique id for that payment.

- **A checkout path, end to end, on `pay`'s FakeProcessor.** billing could model a
  subscription and receive the webhook that records one, but nothing a subscriber
  could actually *do* to start paying: no session, no completion, no positive
  path at all. The `pay` gem is added for one reason and it is in the `Gemfile`
  comment — FakeProcessor is a processor whose API is the database, so a checkout
  can be exercised with no network, no keys and no Stripe account. A checkout
  path whose only proof is a Stripe test key is a checkout path nobody can run in
  CI.

  - **`Checkout::Session#complete` returns an `Outcome` on every path and raises
    for no business refusal.** The negative case is the one this packet is really
    about — a declined checkout that half-applied leaves an account holding an
    `active` subscription it never paid for, and an active subscription *grants
    entitlements* — and an exception is the easiest way to lose it, because
    "the caller forgot to rescue" and "the caller handled it" are indistinguishable
    from a return value. `app/services/checkout.rb` deliberately contains no class.
  - **The processor is asked first and the row is written second.** On the failure
    path **nothing was ever written**, so there is nothing to roll back; a rollback
    is a claim that nothing was written, which is what a crash or a later
    `after_commit` can make false. The negative specs assert the subscription did
    not move rather than that it moved back.
  - **`Subscriptions::Lifecycle` is still the only writer of a `Subscription`.**
    Completion builds the same normalised delivery a webhook would carry and hands
    it to the lifecycle, so there is one state machine, one `Refused` vocabulary
    and one answer to "what is this subscription's status". A checkout that wrote
    the row itself would grant entitlements the moment the *request* was accepted.
  - **`current_period_start`/`_end` are absent rather than guessed.**
    `FakeProcessor` publishes no period, and deriving one from `Plan#interval`
    would be this service inventing a billing period. No amount is computed to
    send to a processor, per `AGENTS.md`.
  - **Per-seat pricing rides through `quantity`**, and `pay` 12.2 is the Gemfile
    floor because it is the first line whose `FakeProcessor#subscribe` accepts a
    quantity at all. A trial of **zero** days does not become a trial:
    `FakeProcessor` tests `trial_period_days` for truthiness and `0` is truthy in
    Ruby, so the option is only passed when positive.

- **`pay`'s own migration created `pay_customers.owner_id` as a bigint.** The gem
  reads its key type from a Rails *generator* option this service never set, so it
  fell back to `:bigint` — and every uuid owner was cast to `owner_id = 0`, all of
  them onto one row. Measured, not reasoned: `Pay::Customer.pluck(:id, :owner_id)`
  returned `[[29, "Customer", 0]]`. Every subscriber would have shared one
  processor customer, and the first checkout of the second would have billed the
  first's card, with nothing raising. `20261006030000_pay_owner_ids_are_uuids`
  fixes both owner columns rather than setting the generator option, which would
  change key types for every generated migration in the service.

- **`app/services/checkout/session.rb` is in `MIXED_MONEY_FILES`.** The inventory
  test puts it there: the word is in the column name `processor_price_id`, not in
  a decision about an amount. Its entry point is asserted behaviourally — the
  delivery carries no amount field at all, and the per-seat quantity is an
  `Integer` count rather than a multiplied price.

### Fixed

- **`test/tenant/account_entry_point_matrix_test.rb` counts.** `Checkout::Session#recorded`
  is the second writer of an account's subscription events and is classified with
  its kind and what it touches; the derived counts move to 36 accesses in 34
  methods under 35 keys, writes 7 → 8.

### Added

- **`/v1` requires an identity JWT, and every customer and subscription query is
  scoped by the account in it.** billing was the last purchasable service whose
  client surface answered every caller: `GET /v1/customers` returned every row,
  `POST /v1/subscriptions` took a `customer_id` in the body, and `README.md` said
  out loud "the endpoints are open anyway". billing-12 measured the gap (14
  account-scoped routes, 33 data accesses, **zero** account scopes) and this
  packet closes it.

  - **`app/services/identity/token_verifier.rb` is the only place a JWT is read in
    this repository.** RS256 pinned as a constant and read from the *token's own
    protected header* before any network call, so an `alg: none` token and an
    HS256 token signed with the published public key are refused without aiming
    traffic at identity. The key set is fetched from `{issuer}/.well-known/jwks.json`,
    cached by `kid` for five minutes, and an unknown `kid` gets **one** forced
    refresh per cache window — claimed *before* the fetch, because a budget
    recorded on completion is a budget twenty-five concurrent requests all
    believe is unspent. A failed fetch keeps the last good set rather than
    replacing it with an outage.
  - **It fails closed, and that is the property the whole thing exists to hold.**
    No issuer or no audience configured answers **503**; identity unreachable
    answers **503**; no token, a malformed one, a wrong-algorithm one, an expired
    one, or one issued to somebody else answers **401**. There is no branch
    anywhere in `AuthenticatesPrincipal` that lets a request through without a
    verified principal — no default account, no "auth is off in development", no
    rescue that renders a 200. A self-hosted billing API that quietly degrades open
    because nobody filled in an environment variable is the failure this removes,
    and the direction that matters is the one that refuses.
  - **The boundary is a `before_action` on `V1::BaseController`, not a middleware
    and not a path check.** `Webhooks::BaseController` does not inherit it, cannot
    reach it, and `raise_on_missing_callback_actions` stops a future controller in
    that namespace from skipping the filter by not naming an action. A
    path-prefixed check gets "all of `/v1`" wrong in the direction that matters: it
    would put a token requirement on `/v1/webhooks/stripe`, whose sender is a
    processor and whose credential is a signature — core's conventions forbid a
    JWT there, and a `Bearer` on that path would be a second, weaker trust path to
    the same door. `test/authentication/principal_lock_test.rb` reads the boundary
    **from the router's own table** rather than from a list of paths, so it is the
    route set that is checked and not this paragraph.
  - **Authorization, not just authentication.** `Customer.for_account` and
    `Subscription.for_account` are the tenancy scopes and every `/v1` query names
    one. Cross-tenant read and cross-tenant write are both **404** — the same
    seven-key answer a uuid naming nothing gets — so `Problem::CATALOG` still has
    no 403 and nothing added one. A `User`-owned customer is in no account and is
    therefore invisible to `/v1`, which is a consequence worth stating rather than
    a bug: which account a user belongs to is identity's fact and no event
    carrying it is in this build's `consumes`.
  - **`openapi/v1.yaml` is at 2.0.0 and tells the truth.** `security:
    [{bearerToken: []}]` with a declared `bearerToken` scheme, `Unauthorized` and
    `CallerIdentityUnavailable` referenced by all fourteen client operations,
    `security: []` on the webhook, and the "declared, and empty" note deleted — a
    document that admits it describes no authorization is a document that describes
    an open door. `CustomerCreate` no longer *requires* `owner`, because the owner
    is no longer from the body.

  **Three breaking consequences, stated rather than discovered:**

  | | |
  | --- | --- |
  | `POST /v1/customers` ignores `owner_type`/`owner_id` in the body | the owner is the token's account. A `User`-owned customer is no longer creatable through `/v1` |
  | `Idempotency-Key` is scoped to the caller's `sub` | core scopes a key to `(endpoint, principal, key)`; two tenants choosing the same uuid no longer share one namespace, so a replay cannot return another caller's stored response. `IdempotencyKey::PRINCIPAL` is no longer a constant and `IdempotentRequests#idempotency_principal` raises rather than defaulting to `"anonymous"` |
  | a listing returns one account's rows | `GET /v1/customers` and `GET /v1/subscriptions` return **this account's** rows, and an account's listing holds at most one customer per `(owner_type, owner_id, processor)` |

  **The `/v1` prefix is deliberately unchanged, and that is a judgement call rather
  than an oversight.** Core's rule is that a breaking change gets a new prefix
  *beside* the old one so the old contract keeps being served — and that is exactly
  what cannot be done here: the old `/v1` answers every request without a token, so
  "keep serving `/v1` for compatibility" is "keep the vulnerability", and a second
  prefix over one open door is one open door. The major bump plus this note is the
  signal instead, and `info.version` is the field every client generator reads.

  **One gem, with its cause: `jwt ~> 3.3`.** This is the first non-observability
  dependency this service has taken. Same reasoning as `stripe`: this is the one
  place a forged credential must never be believed, and a hand-rolled verifier is
  how `alg: none` and HS256-signed-with-the-public-key get through. The gem does
  the signature; `TokenVerifier` does the platform's rules about *which*
  signatures, and nothing about what the claims mean.

  **What is a finding rather than a fix.** Plans are the platform catalogue, so the
  four plan routes are authenticated but **not** account-scoped, and
  `test/contract/tenant_isolation_matrix_test.rb` carries a third verdict,
  `catalogue`, for exactly them. The consequence is that **any authenticated
  account may write the catalogue** — create, change or delete a plan everybody
  subscribes to. Nothing checks a capability for it, because billing has no scope
  vocabulary to check against and a scope invented here would be one nothing else
  in the fleet grants. `Principal#scope_set` parses the token's `scope` claim and
  nothing reads it yet. This is a DECISION NEEDED in `cafaye.yml` and a known gap
  in `README.md`, and closing it is a decision about what a catalogue write is for
  rather than a missing line.

  The four `gap:` tripwires in `test/tenant/cross_account_web_test.rb` were
  **rewritten rather than deleted**: same two accounts, same requests, each
  assertion flipped from "the surface is open" to "the surface refuses". They were
  pinned to fail when scoping lands, and they have now been seen firing.

- **`LICENSE`: billing is MIT.** billing shipped no licence file, which is not
  "unlicensed, therefore free" — it is **all rights reserved**, the default
  copyright position when a public repository grants nothing. README.md said so
  out loud and pointed at a file that did not exist; it now points at one that
  does.

  billing publishes no gem (no gemspec, and the Gemfile has no `gemspec`
  directive), so there is no package metadata field to reconcile and the
  `LICENSE` file is the entire grant.

  The copyright line matches the three repositories that already shipped a
  licence exactly: `Copyright (c) 2026 cafaye`.

- **billing emits OpenTelemetry spans into the collector that ships with kit's
  stack.** `BILLING_OTEL_ENDPOINT` is the only contract (core D16) and it is **on
  by default** — unset, it is `http://otel-collector:4318` — so a developer running
  `bin/rails server` and a deployer both get traces without assembling anything.
  Before this, a deployed billing produced no traces, no request timings and no
  error spans, and the collector kit ships had nothing to receive.

  - **One span per request, `billing.http.request`, `kind: :server`**, carrying the
    method, the status, and — where one exists — the **route template**.
  - **`http.route` is the template, from the ROUTER'S OWN TABLE.** The lookup is
    `[verb, controller, action]` → template, derived from
    `Rails.application.routes.routes`, not a hand-written list of fourteen routes:
    a second list of what the router serves is a second answer to a question
    `test/contract/http_surface_contract_test.rb` already exists to keep honest.
    A template has one value per endpoint and a concrete path has one per request,
    and kit's collector derives metrics with a `spanmetrics` connector that mints a
    series per distinct value — so a path here would be a metric-series explosion
    and a content leak in one move.
  - **A 404 carries NO route at all.** The path of an unmatched request is
    caller-controlled text; the 404 status is the answer.
  - **Only 5xx is an error span.** A 404 and a 422 are this service REFUSING a
    caller, which is this service working. An error rate that counts them is a
    function of how much guessing the internet absorbs, and an alert on it pages
    somebody to switch off the protection doing its job.
  - **Four span attributes, and no others: the method, the status code, the route
    template, and a CLOSED-vocabulary `error.type`.** Each is bounded rather than
    merely allowed, and the list is the whole redaction boundary. No path, no query
    string, no headers, no email, no price, no tenant, no exception message.
  - **`tenant_id` is a RESOURCE attribute**, never a span attribute — on a span it
    is unbounded cardinality by another name.
  - **A raised exception's message and stacktrace are NOT on the span**, and that is
    why the middleware calls `start_span` and finishes the span itself rather than
    using `tracer.in_span`: `in_span` calls `span.record_exception(e)` by default,
    which attaches the class name, the message and the backtrace as a span **EVENT**,
    and an event is exported. An exception message in this service is built three
    frames up from what a caller sent.
  - **W3C trace context is honoured**, so an inbound `traceparent` becomes the
    span's parent and the collector shows one trace per CALLER rather than one per
    request. `Baggage` is deliberately **not** installed: it propagates
    caller-chosen key/value pairs into a downstream service's context, which is one
    more thing to allowlist for no property anybody asked for.
  - **Metrics come from the collector's `spanmetrics` connector, which runs after
    redaction** — so a derived metric can never carry a dimension the allowlist
    stripped, and there is no second definition of the same series in the fleet.
  - **Logs cost nothing.** compose's `logging:` driver ships the container's stdout
    to the collector's `syslog/crash` receiver, which makes a panic a log record
    with a `service.name` on it and adds no per-language dependency to the Gemfile.
- **THE REDACTION PROOF, and it fails when the boundary leaks.**
  `test/observability/canary_test.rb` plants a canary in every field a caller
  controls — a request body, a path, a slug, a query string, four headers, a signed
  webhook body, a malformed `traceparent` — drives REAL requests through the REAL
  router, and **raises `THE REDACTION BOUNDARY LEAKED`** if it finds the string in
  anything exported.
  - **Every absence assertion is paired with a presence one**, through
    `TestSpans.rendered!/0`, which RAISES on an empty export. A boundary that
    deletes everything passes "no canary" and is useless, and three separate
    exporter-contract mistakes did exactly that while this was being written — an
    `export/1` where the callback is `export(span_datas, timeout:)`,
    `SUCCESS` resolved as an inherited constant when
    `OpenTelemetry::SDK::Trace::Export::SUCCESS` is a sibling namespace, and a batch
    appended as one value. All three are swallowed by
    `SimpleSpanProcessor#on_finish`'s rescue, so all three leave the suite green.
  - **The redaction tier has its own CI step and its own count** (48 / 118), because
    a suite that exported nothing would satisfy every assertion in the file: a
    runner where `config.x.telemetry.exporter` came out as something other than
    `test`, or where a workflow-wide `env:` set `BILLING_OTEL_DISABLED`, would
    otherwise produce a green whole suite with the proof never executed.
- **Two gems, with their cause:** `opentelemetry-sdk` (1.13.1) and
  `opentelemetry-exporter-otlp` (0.37.0), in **every** group including test.
  Without them billing cannot emit a span at all. Deliberately **not** added:
  `opentelemetry-exporter-otlp-metrics` (metrics come from the collector),
  `opentelemetry-instrumentation-rails` and `-rack` (their `use_all!` records
  `http.target`, `url.full`, `url.query` and request headers as its own attributes
  — depending on the engine to strip them would make this boundary ONE control
  where this repository insists on TWO, which is why the middleware is hand-rolled),
  and any log SDK (logs are the container's stdout).
- **kit adoption, through kit.** `kit.ref` pins the commit, `bin/dev` is **kit's
  own script verbatim**, and `docker-compose.yml` is an OVERRIDE on kit's stack
  instead of a file that carried its own `postgres:17-alpine` service. No collector
  configuration (kit derives the redaction allowlist from core's schemas, and a
  service that owned that file would be shipping a telemetry boundary nobody
  derived), no postgres container of its own, and no `depends_on: otel-collector`
  — nothing but the collector may be in a readiness path.
- **`bin/migrate`**, so `bin/dev` has a migration step to call. It is
  `bundle exec rails db:prepare`, and the reason it is not left to kit's
  `bin/rails db:prepare` fallback is in its header: on a machine where bundler
  installs into its own `libexec/gems`, `bin/rails` cannot find the gems.
- **`gate.yml`: this repository's gate is now declared, and `bin/prime` refuses
  an unpinned Ruby.** billing was one of the six cafaye services with no gate
  declaration, so a developer here could run `bin/prime`, see green, and learn
  nothing about whether the gate could detect anything. `gate.yml` is written
  against `core/schemas/gate.schema.json` and checked by
  `core/harness/gate_check.py`; `gate.command` is `bin/prime`, `gate.miseTask` is
  `prime` (which already resolved to the same file), and six proofs say what
  "the gate ran" looks like — the pinned toolchain, `bundle install`,
  `db:prepare`, rubocop's file count, the suite's summary line, and the gate's
  own last line. Every floor was measured on this commit, never guessed, and no
  floor carries a margin.

  Two of the six proofs are numeric and they are independent on purpose, which
  is a measured decision rather than a stylistic one. guard measured the
  near-miss this is copied from: a `pass` floor set with a margin of five stayed
  **green** through the deletion of a five-test file, and only a second
  `files` floor caught it. Deleting `test/integration/health_test.rb` here — 5
  tests, referenced by nothing, touching no money — is caught twice:

  ```
  FAIL gate.floor: proof 'lint'  reported 92  and the declaration's floor is 93
  FAIL gate.floor: proof 'suite' reported 758 and the declaration's floor is 763
  ```

  **The `0 skips` in the suite proof is the load-bearing part of this entry, and
  it is a finding rather than tidiness.** Measured here, same commit, same
  command, twice:

  | `CORE_PATH` | result | `bin/prime` |
  |---|---|---|
  | a core checkout | `763 runs, 2100 assertions, 0 failures, 0 errors, 0 skips` | `prime ok`, exit 0 |
  | pointing at nothing | `763 runs, 1757 assertions, 0 failures, 0 errors, 20 skips` | `prime ok`, exit 0 |

  Same run count, same exit code, **343 assertions of contract checking not
  done** — the contract tier skips rather than fails when it cannot read core's
  schemas, which is correct for a standalone checkout and wrong for a green
  badge. Pinning `0 skips` makes that a `gate.proof-missing`, so the declared
  gate is red without a core checkout, and `external` carries a `filesystem`
  requirement naming `CORE_PATH` with the measured symptom as its `unmet`.

  `bin/prime` gains the toolchain half of that story. It used to satisfy
  `require ruby` with *any* interpreter and print `ruby --version`; with macOS's
  system Ruby first on `PATH` the run died four lines later on
  `Could not find 'bundler' (4.0.18) (Gem::GemNotFoundException)` — a red that
  names a gem, nowhere near the toolchain that is wrong, and the 4.0.1 pin
  appears in no line of it. It now reads `.ruby-version`, compares, and exits
  **127** naming both numbers before a gem is touched. `.ruby-version` is the
  same file mise, `ruby/setup-ruby` and the `pins` CI job read, so there is
  still one copy of the number.

  `script/gate_declaration_self_test.sh` breaks the declaration five times on
  purpose and asserts the checker goes red **and names the finding** —
  `bin/prime` replaced by `exit 0` (six `gate.proof-missing`), a deleted test
  file (two `gate.floor`), a floor raised past the count (`gate.floor`),
  `bin/prime` deleted (`gate.command-missing` + `gate.entrypoint-missing`), and
  a `ruby` answering 3.4.2 (`gate.nonzero` at exit 127, with the message itself
  asserted rather than just the status). 181s, sequential, every breakage
  reverted, and a final control that re-runs the check so a script that damages
  the tree it is testing cannot report success.

  That last control was itself wrong on first write, and the fix is part of this
  entry. It compared the restored files against `HEAD`, which cannot tell a
  restore that **failed** apart from a file the operator had legitimately edited
  but not yet committed — both are "the tree differs from `HEAD`", so running
  the script on a worktree with uncommitted work reported a false failure
  against a perfectly intact restore. Measured, not hypothesised: an edit to
  `gate.yml`'s prose made all five cases pass and the control fail, with a diff
  that was exactly the operator's own edit and nothing the script had broken.
  It now compares `cmp`-byte-exactly against the copies the script took at the
  start of the run, which is the invariant actually being tested ("the script put
  back what it took out"), checks `bin/prime`'s executable bit separately because
  that is the one property a restore can lose without changing a byte, and
  reports a dirty `gate.yml` as a note rather than a failure. Proven able to
  still fail: with one byte appended to `bin/prime` immediately before the final
  comparison, the control answered `FAIL: bin/prime is not the file this script
  saved` and exited 1. A check that cannot fail is not a check, and that applied
  to the control as much as to the five cases.

  Measured with `gate-check --prove`: `0 failures, 3 warnings`, and the three
  warnings are `gate.requirement-unproven` for `mise`, `git` and `bundle` —
  bare-name requirements the checker deliberately does not run, which is the
  documented tri-state contract and not a defect. `REPORT-billing-10-gate.md`
  records the pass and skip counts per tier, the two environment-gated tiers by
  variable name, and three open items this packet deliberately did not change.

### Fixed

- **billing's `fsync=off` was deleting the cluster's connection budget, and the
  comment above it said it was only adding an optimisation.** The override was a
  scalar:

  ```yaml
  command: "-c fsync=off"
  ```

  Compose's `command` REPLACES rather than merges, and it replaces the whole
  value whatever shape that value has — so this did not add `fsync=off` to kit's
  command, it deleted it. Measured on the merged config rather than inferred:

  ```console
  $ docker compose -f kit/…/docker-compose.yml -f ./docker-compose.yml config
  …
    command:
      - -c
      - fsync=off
  ```

  kit ships `["postgres", "-c", "max_connections=${KIT_POSTGRES_MAX_CONNECTIONS:-200}"]`,
  and both of those are gone: the `postgres` entrypoint argument, and the
  connection budget kit raises **so that one cluster can carry the whole fleet**.

  The second is the one that matters here. The budget for nine services is
  `(9 tenants x 10) + 8 = 98`, which sits comfortably inside 200 and does **not**
  fit inside Postgres's default 100 alongside kit's reserved slots. So the
  override did not merely lose a tuning knob — it removed the headroom the
  shared-cluster plan depends on, and only for whichever service overrides
  `command` at all, which is the kind of asymmetry that arrives as a mystery
  under load rather than as a defect.

  The comment above the line already knew `command` was a scalar and replaced
  rather than appended, and drew the wrong conclusion from it — treating the
  replacement as harmless because the *intent* was an addition. It is now a list
  that repeats kit's own arguments, and that repetition is the cost of compose
  having no merge for this key.

  Verified on the running cluster rather than on the merged YAML alone:
  `show max_connections` returns **200** with billing's `fsync=off` in place.

- **`core`'s payload schemas grew a `$comment`, and billing's contract test
  answered a documentation change as a contract change.** core now records on
  each of its 22 payload schemas a `$comment` naming the commit the shape was
  transcribed from. `$comment` is a JSON Schema 2020-12 *metadata* keyword —
  §8.3 requires a validator to ignore it — so this is not a change to any
  payload's shape at all.

  billing reads core's schemas with a deliberately closed vocabulary
  (`UNDERSTOOD_KEYWORDS`), where an unmodelled keyword is a **raise** rather than
  a skip, and its drift test holds that vocabulary against every keyword core
  uses. That design did exactly its job: it reported the new keyword, by name,
  once.

  ```
  Failure: OutboxEnvelopeContractTest#test_every_keyword_core's_payload_schemas_use_is_one_this_validator_understands
  core's payload schemas now use ["$comment"], which this validator does not model
  ```

  `$comment` is now listed as understood, alongside `title` and `description`,
  which are already there for the same reason. Two consequences worth stating,
  because "understood" is the word that hides both:

  - **It is ignored, not honoured.** A test asserts this in both directions and
    at both schema positions — a comment claiming a valid payload is invalid, and
    a comment excusing a breaching one, change no verdict. The dangerous patch
    here is not the one that breaks; it is the one that makes a prose note an
    oracle, and it would fail *open*.
  - **The closed set did not weaken.** Every check dispatches on the keyword it
    knows, so a listed keyword nothing dispatches on cannot contribute a breach.
    The drift test still fires on the next keyword core starts *constraining*
    with.

  Both positions are covered because root-level coverage alone was measured to be
  insufficient: `violations` receives the root schema and then each property's
  constraint, so a patch honouring comments in the root walk passes every
  root-level assertion while leaving the per-field level open — which is the
  level a per-field comment would actually arrive at. `ONE_OF_BRANCH_KEYWORDS`
  carries `$comment` for the same reason: metadata is ignorable at every position
  in a schema document, and a `oneOf` branch is a position.

  This was pre-existing on `master` (`7251993`) and had nothing to do with the
  shared-cluster work in `d95fb54`; it was found while reviewing that commit's
  gate, which is why it is recorded here separately rather than folded into it.

- **The two numeric floors in `gate.yml` were 187 runs below the truth, and the
  declaration's own self-test could not tell.** The packet wrote the merge
  obligation into a comment — *"WHEN billing-09-race MERGES, raise this and
  `BASELINE_RUNS` together in that commit, or in the merge"* — and CI's
  `BASELINE_RUNS` was raised to 950 by billing-13 while `gate.yml` still said
  763. Measured on the merged tree: **950 runs / 2724 assertions**, 109 files
  linted, so both floors moved to the measured numbers.

  **What the stale floor did, rather than what it failed to prevent.** With the
  suite floor at 763 on a tree running 950, self-test case 2 —
  `rm test/integration/health_test.rb`, the exact five-test file deletion the
  packet designed to be caught by *both* numeric floors — reported **exit 0**.
  The deletion left 945 runs against a floor of 763, so neither floor moved and
  the declaration certified a suite that had just lost five tests. A floor that
  is too *low* is not a safe floor; it is a check that has stopped checking, and
  it is invisible because floors never block a merge, so nothing goes red to say
  so.

  **The self-test caught it, which is the whole argument for shipping one.**
  The control was green, cases 1, 4 and 5 were green, and cases 2 and 3 were
  the two reds that should not have been red. That is the packet's own
  mechanism reporting a real defect in its own arithmetic, and the fix
  (measure, do not predict) is the fix the comment had already prescribed.

- **Self-test case 3 no longer hardcodes the floor it raises.** It read
  `minimum: 763` and replaced it with `764`, so when the real floor moved to 950
  the sed edited a line that no longer existed and **the case reported green
  while proving nothing about floors** — the worst failure mode a self-test has,
  since a green that means nothing is believed. It now reads the current floor
  out of `gate.yml` and raises *that*, and fails loudly if it cannot find one.
  This is D9's exact defect (the same number written down in two files and
  correct in neither) found by the case that exists to check floors.

  Measured on the way: `[0-9]\+` is not valid in a POSIX BRE, so BSD sed —
  what macOS ships — matched nothing and exited 0. The fail-loudly branch is what
  turned that into `CASE COULD NOT RUN` rather than a silent no-op.

- **The three cross-tenant defects billing-12 proved are now closed: a delivery
  can no longer move a subscription between accounts, and a processor customer id
  or price id can no longer be claimed twice.** `+37 runs / +126 assertions`
  (913 → 950 runs, 2598 → 2724 assertions), and the six findings tests in
  `test/tenant/cross_account_findings_test.rb` are **rewritten rather than
  deleted**: same two accounts, same delivery, same `PATCH`, same pair of plans,
  with each assertion flipped from "the defect reproduces" to "the defect is
  refused". See `REPORT-billing-13-fixes.md` for the before/after of each.

  | finding | before | after |
  |---|---|---|
  | **F1** | a delivery naming another account's customer moved a live subscription between accounts and published it as `billing.subscription.updated` | refused as `ignored:account_mismatch`, answered **200**, no row change, no event |
  | **F2** | two customers could answer to one `cus_`, so a delivery's account was undecided | `customers_processor_customer_id_idx` is unique over the non-null values; a colliding `POST`/`PATCH` is a **409 naming `processor_customer_id`** |
  | **F3** | two plans could claim one `price_`, so a subscription could be billed at an unagreed amount | `plans_processor_price_id_idx`, and a **409 naming `processor_price_id`** |

  **`account_mismatch` is the seventh `Subscriptions::Refused` reason** and the
  first about tenancy rather than about the row's shape. It is recorded on the
  delivery row and answered 200, because a refused delivery is a decision and not
  an error: the processor would retry a 4xx, reach the identical conclusion, and
  the row already carries the reason. The comparison lives in
  `Subscriptions::Lifecycle#apply`, before `assign_attributes` and only for a row
  that already exists — a first delivery has no account to disagree with, which is
  what lets a deletion arriving before its own creation still create its
  `canceled` row.

  **Both indexes are partial, and the reason is not stylistic.** The columns are
  nullable and legitimately so — a customer created through `/v1` has no `cus_`
  until a subscription tells this service what the processor calls it — so the
  rule is *a value here is unique*, not *this column is unique*. A bare `unique`
  index would allow the nulls by way of PostgreSQL's `NULLS DISTINCT` default, and
  that is a database default rather than a statement of intent; the partial index
  does not depend on it, because a null is not **in** the index.

  **`openapi/v1.yaml` gains a 409 on `PATCH /v1/customers/{id}`** and
  `info.version` moves to 1.3.0 — that operation could not answer a conflict
  before, and a response the document does not list is a document lying about its
  own surface. The other three writes could already answer 409 and now say which
  collision they report. No operation was added, removed or changed, so the `/v1`
  prefix is untouched.

  **No existing webhook test broke.** A guard that turns green tests red would
  have been a test encoding the defect; none was, and the report says what changed
  in the two files that did move.

### Changed

- **The tests that asserted `/v1` is open were the bug, and they were changed
  deliberately.** Four characterisation tests in
  `test/tenant/cross_account_web_test.rb` were written by billing-12 to pin the
  open surface: a customer and a subscription readable by uuid, a customer
  **writable** by uuid, an unscoped listing. Each was coupled to a count of
  account-constrained queries in `app/` that was `0`, so the day scoping landed
  they would all four fail saying to rewrite them as 404s. **That day is this
  commit**, and they are rewritten rather than deleted: same two accounts, same
  requests, each assertion flipped from "the defect reproduces" to "the defect is
  refused".

  One thing in that file could not be left as it was. Its 403 audit scans `app/`
  for `403`, `forbidden` and `:unauthorized`, and the new code in
  `authenticates_principal.rb` *explains* the rule in prose containing the word
  "forbidden" — a scanner that trips on a comment is a scanner that must be
  silenced by deleting the explanation, which is backwards. It now skips comment
  lines and scans `403|forbidden`, and the file's own header says why the scan
  exists: `Problem::CATALOG` is a closed set with no 403 in it, so the guarantee is
  a property of the catalog and the scan is what catches a controller reaching
  past it.

- **Two guards in this packet were wrong on first write, and both were caught by
  mutation rather than by review.** Both are reported because "I broke it on
  purpose and it noticed" and "I think it would notice" are different claims, and
  in both cases the first claim was false.

  | guard as written | mutation | result |
  |---|---|---|
  | `test/authentication/token_verifier_test.rb` scanned `app/` and `lib/` for `/\bJWT\./` | a file referencing `JWT::JWK` | **not caught** — `JWT::JWK` contains no `JWT.`, so a file doing precisely what the guard forbids passed. Now matches `/\bJWT\b/`, and fires naming the file and line |
  | `cross_account_web_test.rb`'s meta test asserted `account_scoped_queries > 0` | rename `Subscription.for_account` to `for_account_disabled` | **not caught**, and it could not have been: the count's own regex was `scope :for_account`, an unanchored **prefix**, so the rename left the count at 2 and green. Now `assert_equal 4` and the regex is word-anchored; verified to fail on losing **either** scope |

  The second one is the more interesting and the more embarrassing. The guard was
  a tripwire *pointing backwards* — it existed to notice the day scoping
  disappeared — and it was written so that the disappearance it was watching for
  could not move it. `> 0` asked "is any scoping left?" when the question worth
  asking is "is **this** scoping left?", and a refactor deleting one of two
  scopes leaves the file asserting a boundary the code no longer has.

- **`ACCESS_EXPRESSIONS` in the entry-point matrix gained two `for_account`
  patterns.** `test/tenant/account_entry_point_matrix_test.rb` derives the
  enumeration of account-scoped data accesses by scanning `app/` and resolving
  each access to the method it sits in. Adding a scope made five reads vanish
  from the scan — not because they stopped being queries but because the scanner
  did not know the shape — so the scanner was taught the shape. The counts moved
  from 33 to 35 accesses (reads stay at 12, lists 9 → 11) and are asserted, which
  is the point: an enumeration that silently shrinks is worse than no enumeration.

- **`test/support/identity_helpers.rb` holds a real 2048-bit RSA key and signs
  real tokens.** The stub replaces the *fetch*, never the verification, so a spec
  cannot pass by arranging a principal: a token with a broken signature, a wrong
  `kid` or a past `exp` is refused by the same `JWT.decode` call production uses.
  `ActionDispatch::IntegrationTest` gets an `Authorization` header by default and
  `acts_as(account)` / `without_token!` are the two verbs — which means a spec that
  forgets to think about authentication still runs, and the ones that mean to
  exercise it have to say so.

- **The subscription-fixture helpers no longer default to one processor id.**
  `create_stripe_plan` and `create_stripe_customer` in
  `test/support/stripe_subscription_fixtures.rb` handed every row the same
  `price_`/`cus_`, which is precisely finding F2 and F3's shape: two rows claiming
  one processor id. Nothing was *arranging* a collision — it was an artifact of a
  shared default — and the two new unique indexes turned 85 passing tests in
  `test/requests/v1/subscriptions_test.rb` into 85 errors. **The first call in a
  test still gets the committed fixtures' id**, which is load-bearing: it is what
  the subscription fixtures carry and what a delivery resolves through. A separate
  euro-currency plan in that file was also claiming the USD plan's `price_`, which
  is incoherent on its face and now has an id of its own.
  `test/coverage/fixture_processor_ids_check_test.rb` holds the two id lists in
  step, and holds the regression: two customers and two plans in one test get two
  ids each and are both written.

### Added

- **Tenant isolation, enumerated and held: 14 account-scoped routes and 33
  account-scoped data accesses, with 31 negative tests over them.**
  `test/tenant/` is four new files and one new support module, `+62 runs /
  +230 assertions`, and it changes **nothing in `app/`**. The service has no
  tenant-isolation defect introduced by this packet because it introduces no
  behaviour at all; what it does is make the shape of the gap total, measured,
  and asserted, so that the day account scoping lands there is a list to work
  through rather than a hole to discover.

  **The enumeration is derived, not maintained.** `test/tenant/account_entry_point_matrix_test.rb`
  scans `app/` for every data access, resolves each to the method it sits in, and
  compares the result against its table in **both directions**: a query nobody
  classified fails by name, and a classified entry point whose method has gone
  away fails the other way. The numbers are the packet's headline and each is
  asserted —

  | | |
  |---|---|
  | **Account-scoped routes** | **14** — read 4, list 3, write 3, update 4, delete 0 |
  | **Account-scoped data accesses** | **33** in 31 methods, under 32 keys — read 12, list 9, write 7, update 5, delete 0 |
  | **Tests added under `test/tenant/`** | **62** — 31 negative, 20 structural tripwires, 11 bookkeeping |
  | **Negative tests, by operation** | **31** — read 15, list 4, write 3, update 8, delete 1 |
  | **`403` responses found on an invisible resource** | **0** |
  | **`403` responses added** | **0** |
  | **Cross-tenant defects found and reported, not fixed** | **3** |

  The 62 is the whole directory and the 31 is the cross-account part of it; the
  rest is 20 structural tripwires about the enumeration and 11 tests about the
  test files themselves (`meta:`), and each of those three numbers is asserted by
  the file it belongs to. Note the two 31s are a coincidence and mean different
  things — one counts access sites in `app/`, the other counts negative tests.

  **Delete is zero, and that is a fact rather than a gap in the table.** Nothing
  in `app/` destroys a row and the router serves no `DELETE` under `/v1`, so there
  is no delete to scope — the shape darkroom-09 called "scopes its reads and
  forgets its deletes" is *not* this one. Both halves are asserted: adding a
  `destroy` fails two tests, and adding a `DELETE` route fails a third.

  **`403` could not be an enumeration oracle here, and that is now structural
  rather than a promise.** `Problem::CATALOG` is a frozen table and no entry in it
  has the status 403, so this service has no way to emit one; a controller that
  named one anyway would be caught by a second assertion that reads `app/`. The
  brief's rule — absence, never refusal — is enforced in both directions and both
  are proven by mutation.

  **The 404 shape was already right, and is now pinned.** A resource that does not
  exist and an identifier that *cannot* name one are the same answer, byte for
  byte: `V1::BaseController#uuid_param!` decides before the query, and
  `render_not_found` renders one fixed sentence. The three uuid-addressed
  resources each assert it, plus the plan slug path. `instance` echoes the
  caller's own request path, which discloses nothing the caller did not send; the
  assertion is on the whole key set precisely so a second, more specific `detail`
  — the shape of a real oracle — fails here.

  **Three cross-tenant defects, reported rather than fixed, because each is a
  change to money and none can be discharged inside this packet.** They are
  asserted as findings in `test/tenant/cross_account_findings_test.rb`, so each is
  a tripwire that fires **when it is fixed**:

  - **F1 — a delivery reassigns a live subscription between accounts.**
    `Subscriptions::Lifecycle#apply` writes `account_id: customer.owner_id` onto
    the row it is updating and never compares it to the account already there, so
    a second delivery resolving a different customer moves a live subscription
    from one account to another and publishes the move as
    `billing.subscription.updated`. The existing guard,
    `Subscription#account_is_the_customers_owner`, still passes: the new account
    does belong to the new customer. What it cannot see is that the account
    *changed*.
  - **F2 — `customers.processor_customer_id` is not unique, and the API lets a
    caller set it.** `POST`/`PATCH /v1/customers` both permit the column on a
    client's *own* row, and `Lifecycle#customer` resolves it with `find_by`, so
    two accounts can answer to one `cus_` id and the lookup has no `ORDER BY` to
    break the tie. This is what makes F1 reachable through this service's own
    surface rather than only through a processor dashboard.
  - **F3 — `plans.processor_price_id` is not unique**, the same shape one table
    over, so a subscription is billed against whichever plan claimed the price id.

  All three are counted and named in the findings file and written up in
  `REPORT-billing-12-isolation.md` with the fix each one needs.

  **Fifteen mutations, every one of which turns a test red**, reported in the
  report rather than claimed. The set includes the three fixes: landing F1's guard,
  F2's uniqueness rule or F3's turns the corresponding finding red with a message
  saying to delete it and replace it. That direction is the one that matters — a
  finding test that survives its own fix is a test nobody will trust the next
  time.

  `test/support/two_accounts.rb` holds the two accounts every spec compares
  against, with `cus_FAKE…` / `sub_FAKE…` / `price_FAKE…` / `evt_FAKE…` ids so a
  fixture cannot be mistaken for a captured production value. Its
  `#fingerprint` exists because the cross-account specs must be able to say "this
  row did not change" **without printing the row**: a `sha256` per row answers
  that, and `drifted_ids` then names which ids moved rather than what they held.

  No change to `bin/prime`, `docker-compose.yml` or any other gate input.

### Changed

- **CI's asserted suite size is raised to 913 runs / 2598 assertions.** Adding a
  test turns the `gate` job red until `BASELINE_RUNS`/`BASELINE_ASSERTIONS` are
  raised in the same commit, which is the intended direction; the header's
  per-packet itemisation gains the `+62 / +230` line for this packet. Two
  pre-existing drifts in that header are **noted, not corrected** — the three
  per-packet deltas sum to 147 rather than 150, and billing-08's claimed 45/99
  does not match its own bullets — because correcting a threshold and correcting
  the prose about it are separate jobs and this one raised. The one exception is
  the webhook tier's step name, which said 147 while the assertion directly below
  it (and `bin/rails test` on those five files) says 162; the assertion is right
  and the name was corrected, because a step name that reads like a measurement
  and is not one is worse than a wrong one.

- **One postgres image across the platform: `postgres:17` → `postgres:17-alpine`.**
  `docker-compose.yml` and the `gate` job's `services:` block both named
  `postgres:17`, the debian build. Both now name `postgres:17-alpine`, the tag
  every running database container on the machine already uses and the smallest
  current-major variant — **291MB against 477MB**. The other postgres images had
  been dropped from the local docker cache, so the debian tag had to be re-pulled
  in full on the next `compose up` to start a database that was already here at
  291MB.

  What the smaller build changes, measured rather than assumed. Alpine 3.24 on
  musl 1.2.6; `pg_database` reports `datcollate`/`datctype` of `en_US.utf8` with
  `datlocprovider = 'c'`, which *reads* like glibc but is not: a sort through the
  default collation returns byte order —
  `'Apple,Banana,Zebra,_under,apple,apple2,banana,cherry'` — identical to an
  explicit `COLLATE "C"` and different from `en-US-x-icu`, where a glibc-built
  postgres:17 with the same `LANG` sorts case- and accent-insensitively. **No test
  in this repository depends on it.** Every ordered read is
  `order(created_at:, id:)` — a `timestamptz` and a `uuid` — in
  `CursorPaging#paginate` and `OutboxEvent.oldest_first`, and no spec sorts a text
  column. That is a property of the code, not of the pin, and it is the first
  thing to re-check if a later packet adds a `name` or `slug` to an ordering.

  Authentication defaults are unchanged: `POSTGRES_HOST_AUTH_METHOD: trust` is
  explicit and honoured identically on both builds. The data directory is still
  `/var/lib/postgresql/data`, confirmed by booting it — that default moves in
  PostgreSQL 18, so it is the major bump and not this pin that makes that line
  worth re-reading.

  A **`pins` step now fails the build when the two disagree**, which is what
  "one image" means as an invariant rather than as a one-time edit. It reads each
  pin out of its file by pattern and requires a full `major` or `major-variant`
  tag, so `postgres`, `postgres:latest` and a deleted pin all fail rather than
  reading as agreement. Proven by mutation: reverting compose alone, both a bare
  `postgres` and a `:latest` pin, and a removed pin each fail by name.

  The two `postgres:17` mentions lower down in this file are billing-01's
  historical entries and are left as written — a changelog records what a release
  shipped, and rewriting that is not this packet's business.

- **CI now calls kit's reusable workflow, and holds master's suite size.**
  `.github/workflows/ci.yml` replaces the Rails-generated workflow with
  `uses: cafaye/kit/.github/workflows/ci.reusable.yml@master` and
  `language: ruby` — the fleet's first Ruby adopter of it — plus the half kit
  cannot own: a `gate` job that runs `bin/prime` against a real PostgreSQL, a
  `security` job for `brakeman` and `bundler-audit`, and a `pins` job that
  checks the Ruby number agrees across `.ruby-version`, `mise.toml` and the
  `Dockerfile`, that the `uses:` path is the one that resolves, and that no
  secret is anywhere in the workflow.

  The `gate` job is the load-bearing part, and it exists for one specific
  reason. `test/contract/outbox_envelope_contract_test.rb` **skips every test in
  the file** when core's schema is not readable. Measured on this commit:

  | `CORE_PATH` | result |
  |---|---|
  | `CORE_PATH` set to a core checkout | 19 runs, 339 assertions, 0 skips |
  | `CORE_PATH` pointing at nothing | 19 runs, 0 assertions, **19 skips** |

  and the whole-suite summary line reads the same in both cases. So CI checks
  `cafaye/core` out of the repository itself — public, `schemas` and `docs`
  only, at `master` rather than a pinned SHA, because a pinned ref would blind
  the one guard that exists to catch a change in core — and **fails the build on
  a single skipped test**. A suite that reports `0 assertions; 19 skipped` has
  verified nothing, and a green badge is a claim.

  A **second** test read core and did not say so.
  `test/integration/subscription_delivery_test.rb` asserted against
  `Rails.root.join("..", "core")` with no seam at all, so it passed on a
  developer machine with the repositories side by side and raised
  `Errno::ENOENT` on a CI runner, which has one checkout and no sibling — the
  gate would have been red on its first run. It reads `CORE_PATH` now, and
  `gate` sets that variable on the job rather than on one step.

  The gate also pins the suite by **equality** against master's
  `763 runs / 2100 assertions / 0 failures / 0 errors / 0 skips` at `e63bb7a`,
  and asserts three tiers by name and count — the whole `test/contract`
  directory (26), the webhook tier (138) and the money-path coverage gate (5).
  The contract tier is named as a directory, not as a file list, because
  billing-07 moved three of its tests into `http_surface_contract_test.rb` and a
  file list read that relocation as a deletion. These are decrease detectors,
  not targets: adding a test turns CI red until the number is raised in the same
  commit, which is the intended direction.

  The `ruby (kit)` job fails on two steps — kit's `ruby` job declares no
  service container, so `bundle exec rake` cannot reach a database, and it runs
  `rake coverage`, which this service deliberately does not have — and
  `continue-on-error` absorbs them. `gate`, `security` and `pins` are the
  required checks; the condition for retiring `continue-on-error` is written
  into the workflow.

  **No behaviour in `app/` changed.**

- **The outbox contract test now describes the world core shipped in core-03.**
  core added a payload schema for all eight of this service's published types and
  raised **D10**, a breaking spec change that removed the `sub_…` / `pln_…` /
  `acc_…` patterns from `billing.subscription.started`. On billing master with
  the new core, `test/contract/outbox_envelope_contract_test.rb` reported two
  failures and three errors.

  * `PENDING_ID_PATTERNS` is **empty**. D10 closed all three recorded entries from
    the core side: `subscription_id` no longer declares a `pattern`, and
    `plan_id` and `account_id` are no longer declared as properties at all. A
    field core does not constrain cannot have an unclosed gap against it.
  * The two tests that iterated that table no longer do. They **derive** the gap
    from core's files and compare. An empty table iterated zero times exits 0
    having checked nothing, which is the failure PLAN.md §1 forbids, so the work
    is now over core's schemas rather than over a constant.
  * `NO_PAYLOAD_SCHEMA_YET` is **empty**: core-03 answered all eight. It is
    written out rather than derived, because the subtraction that used to stand in
    for "core has a schema" would now have hidden the entries core-03 opened.
  * The payload validator reads every keyword core declares rather than `type`
    alone — `enum`, `const`, `pattern`, `minLength`, `minimum`, `format`, nested
    `properties` and core's D11 `oneOf` — and **raises** on a keyword it does not
    model. Before, it would have reported "no problem" for five constraints it
    never read. A new drift test walks every keyword core uses and fails once, by
    name, when a shape appears the validator does not model.
  * `value_is_type?` understands a JSON Schema **type array**, so core's
    `["string", "null"]` is a disjunction and not an unknown type name. Its `else`
    still raises, and a test exercises that branch so it cannot quietly become a
    permissive `rescue`. `integer` stays Integer-only and `number` is modelled:
    a Float is never an amount in this service.
  * Every emitted envelope is checked, not the first with a matching type.
    `billing.payment.succeeded` has two shapes under D11 and the uuid tiebreaker
    was choosing which one to verify, on every run.
  * The corpus and the behaviour-not-text comparison survive, retargeted at the
    two constraints where core and this service each hold a pattern of their own:
    `Plan::SLUG_PATTERN` against core's `slug` pattern, and
    `Money::CURRENCY_FORMAT` against core's `^[A-Z]{3}$`.

  **No behaviour in `app/` changed.** The only change outside the test and the
  manifest is one stale comment in `Subscriptions::Lifecycle#payload`, which
  described core's pre-core-03 payload schema.

- **The HTTP document and the router are now held to each other by method *and*
  path, in both directions.** `test/contract/http_surface_contract_test.rb`
  replaces a path-only comparison that could not see a verb. It reads the
  document, the manifest and the route set — nothing from `core` — so it runs on a
  checkout that has no `core` beside it, which the spec it replaced did not
  (that one sits behind a `setup` that skips).

  * Every `(method, path)` in `openapi/v1.yaml` is served, and every
    `(method, path)` the router serves is either in the document or named on an
    exclusion list with the reason it is not a client operation. A route that is
    neither fails, so the list cannot grow an endpoint nobody argued about; an
    exclusion for a route that has gone away fails the other way, so a stale one
    cannot quietly cover whatever is added at that path next.
  * The exclusions are keyed by method **and** path and replace a
    `start_with?("/v1")` filter, which excluded the probes, the `exceptions_app`
    targets and every Rails engine route *incidentally* and could not see a verb
    on a `/v1` path.
  * Every operation is required to have an `operationId` and no `operationId`
    may be used twice, and the fifteen are pinned — a generator turns these into
    method names, so a duplicate or a rename is a compile error in a customer's
    language.
  * A route drawn `via: :all` has no verb constraint at all, so it is excluded
    under each of the seven methods rather than under a verb that is not a
    method, and a test reads that back out of the router.

  The `info.version` pin and the `exposes.api` manifest check moved to the same
  file, because they read the document rather than core. Both are unchanged: the
  version is still a pin and not a value derived from the document. The document
  is now read with `safe_load_file`, as the manifest beside it already was.

- **`info.description` now describes the document that exists.** It said the
  document "describes the v0 surface" while `info.version` read 1.1.0, and it
  promised prepaid credit, usage metering and invoices, which are not built. It
  describes the operations that are here and names what is deliberately not —
  the probes, the `exceptions_app` targets, the Rails engine routes, the
  features still to come — so *absent* and *forgotten* read differently. The
  header gains note 5, which states the rule above.

  `info.version` moves 1.1.0 → **1.2.0** for this: no operation moved, so the
  `/v1` prefix is untouched, and core's checklist asks for the bump if anything
  else in the document did — prose included.

### Fixed

- **One Stripe event id could produce two `billing.payment.succeeded` events.**
  A duplicate charge, and the most expensive defect this service has found.
  `Webhooks::Ingestion#call` is a check followed by an act — it reads
  `ProcessorWebhook#handled?` and, on `false`, writes the cafaye event and marks
  the delivery finished. The unique index on `processor_webhooks.stripe_event_id`
  makes two concurrent deliveries of one event id agree about *which row* they
  hold, and that is not the same as agreeing about the answer: `handled?` reads
  `processed_at`, a column neither thread has written yet, because each is about
  to write it. Under READ COMMITTED neither sees the other's uncommitted work, so
  both read `nil`, both dispatch, and one event becomes two.

  Two rows are two envelope ids, and core defines the envelope `id` as the dedupe
  key — **a consumer deduplicating on it cannot tell the duplicate from new
  information about somebody's money.**

  The fix is a constraint rather than a better check, because a duplicate was a
  *permitted state* of `outbox_events` and no application-level guard fixes a
  permitted state under concurrency. `20260930000010` adds a **partial unique
  index over the payload's `processor_event_id`**:

  ```sql
  create unique index outbox_events_processor_event_id_idx
    on outbox_events ((data ->> 'processor_event_id'))
    where data ->> 'processor_event_id' is not null;
  ```

  It is a functional index over an existing column rather than a new one on
  purpose: **the outbox column list is core's contract, not local** (core's
  `docs/event-outbox.md`: "the column list is the contract"), and the key is
  already in `data` because `Webhooks::StripeEvents.provenance` puts the
  processor's own id in every webhook-emitted payload. No column added, no
  envelope attribute added. The `WHERE` clause leaves the three model-callback
  emissions alone — they are not the product of a delivery and have no such key.

  `Ingestion` gained `DUPLICATE_REASON` and a `rescue ActiveRecord::RecordNotUnique`
  branch that records `ignored:duplicate_delivery`. Without it the loser was
  parked as `failed:ActiveRecord::RecordNotUnique…` — a row in front of a human
  for an event that is published and correct.

  **The constraint does not close every route, and that is recorded rather than
  left to be discovered.** `billing.subscription.started` deliberately carries no
  `processor_event_id` (the lifecycle's start payload is `core_payload` plus
  `started_at`, and the lifecycle spec asserts the key's absence), so a duplicate
  `customer.subscription.created` never reaches the outbox — the second `INSERT`
  into `subscriptions` is refused first.

  **Which** refusal is a scheduling accident, and the first draft of this entry
  got it wrong. `subscriptions` carries a uniqueness *validation* on
  `processor_subscription_id` in the model **and** a unique *index* over the same
  column, and either thread can be refused by either. Measured over 60 barrelled
  duplicate creations: **57 refused by the index, 3 by the validation.** So the
  honest statement is that the duplicate is prevented while the validation and the
  index are both present — dropping either *alone* still prevented it, while
  dropping *every* index on `subscriptions` reopened it outright (two subscription
  rows, two `billing.subscription.started` events). The ingestion layer is
  therefore written against the **exception**, not against a named constraint, and
  this entry claims no single index.

  The stale-delivery guard from this same release is **not** part of this fix and
  does not substitute for it: both deliveries carry the same processor timestamp,
  so both are current and both pass it. Ordering and at-most-once are different
  guarantees. Both are kept.

- **A lost race was parked as a failure about 5% of the time, and is now always
  recorded as a decision.** `Ingestion` classifies a uniqueness *failure* and a
  unique-index *violation* as the same fact — both mean "a concurrent delivery of
  this event id already acted on it" — so both record
  `ignored:duplicate_delivery` and answer 200. Before this, `rescue
  ActiveRecord::RecordNotUnique` covered only the index: when the model's own
  uniqueness validation won the race instead, the loser fell through to
  `rescue StandardError` and was parked as
  `failed:ActiveRecord::RecordInvalid: Validation failed: Processor subscription
  has already been taken`. Measured **3 in 60** barrelled duplicate creations.

  That is a row in front of a human at 3am for an event that is published and
  perfectly correct, and it was a **5% flake in the regression test that exists
  to catch exactly this**, which is why it was not left as a known race.

  The classification is deliberately on the *error* (Rails' `:taken`) and not on
  the exception class: a `RecordInvalid` carrying any other validation failure is
  a bug in this service and still parks. Both directions are separate tests in
  `ingestion_test.rb`, so widening the rescue into a blanket one fails rather
  than being argued about. After the change, 60 of 60 barrelled duplicate
  creations recorded `ignored:duplicate_delivery` and **zero** were parked.

- **Three test helpers delivered under an event id their own payload did not
  carry.** `stripe_controller.rb` hands `Ingestion` `event_id: payload["id"]` and
  `Webhooks::StripeEvents.provenance` reads that same field to stamp the emitted
  event, so in production the delivery and its body cannot disagree about which
  event this is. `ingestion_test.rb`, `lifecycle_test.rb` and
  `subscription_delivery_test.rb` each varied the delivery's id while leaving the
  body's at the fixture's, so events were published claiming to be the same one.

  Nothing caught it, because nothing could: the outbox was permitted to hold two
  rows with the same provenance, and `test_every_live_status_may_be_canceled`
  asserted "every live status may be canceled" while three of its four deliveries
  were silently doing nothing. The new index turns it into a hard failure rather
  than a comment, and each helper now merges the id into the body. A test in each
  file pins the invariant, and it was seen red first —
  `["evt_a", "evt_b"]` against `["evt_1PZQaBcDeFgHiJkLmNoPqR4"]`.

- **A signed webhook body that is valid JSON but not an object was answered
  500.** An array, a bare number, a string, a boolean or `null` are all valid
  JSON over a perfectly good signature, and all of them are not an event.
  `Stripe::Webhook.construct_event` builds a `Stripe::Event` out of the parsed
  body and reaches an array as something it has no accessor for, so it raised
  `TypeError` or `NoMethodError` rather than the `SignatureVerificationError` the
  rescue clause named — and the endpoint's own status table says a 5xx never is
  an answer, because a 5xx teaches a processor to retry a decision that cannot
  change. The shape is now decided in the controller, where the payload is
  parsed, and the six shapes are asserted to answer the same 400 with the same
  problem body as a body that is not JSON at all.

  The `rescue` for the gem's own shape assumptions is **scoped to the
  verification call** and cannot swallow anything from the ingestion layer
  below it, and the loop's own `SignatureVerificationError` stays first and
  stays a `next` — a secret that simply does not match is a candidate failure
  and not an error.

- **A delivery that predated the one that last wrote the subscription was
  applied.** The state machine's rule is about a *pair* of statuses and covers
  the one order this service knows for certain. Everything else is a *sequence*,
  and the processor does not promise delivery order, so a
  `customer.subscription.updated` it retried an hour late landed on a row it had
  already moved past: a `past_due` subscription whose charge failed became
  `active` again, which grants entitlements nobody is paying for, and a late
  `cancel_at_period_end: false` told every downstream consumer a cancellation
  had been called off.

  `Subscriptions::Lifecycle::STALE_REASON` refuses a delivery **strictly older**
  than `last_processor_event_at`, the processor's own timestamp for the delivery
  that last wrote the row. Strictly, and not "not newer": those timestamps are
  epoch seconds, two genuinely different events routinely share one, and
  refusing those would drop real deliveries. A row with no recorded timestamp
  has nothing to be stale against, which is the case a deletion arriving before
  its own creation depends on. Refusals are recorded as
  `ignored:stale_delivery` and answered 200, because a processor retrying a
  stale delivery reaches the identical conclusion.

  The seven tests pin **both** directions, because the guard's whole value is
  that it refuses a delivery it should refuse and accepts one it should accept.
  Two mutations were run: `<=` instead of `<` goes red on
  `a delivery at the same processor timestamp is not stale`, which is the
  mistake a naive implementation makes; and removing the guard call goes red on
  five, including `Expected "past_due" Actual: "active"` and a third
  `billing.subscription.updated` event.

- **`PUT /v1/customers/{id}` was served and was in no document.** The check that
  compared the document with the router read **paths only** and filtered the
  router with `start_with?("/v1")`, so `resources`' two verbs for one `update`
  were one path on each side and it reported agreement.

  The route is removed rather than documented. `V1::CustomersController#update`
  is a partial update — `CustomerUpdate` has every field optional and is closed,
  and `owner`/`processor` are not updatable because they are the key the
  uniqueness rule is built on — so a `PUT` describing it would be a document
  claiming a whole-resource replacement this service does not implement.
  `config/routes.rb` now spells the customer routes out, as it already did for
  plans and subscriptions. This is a narrowing of the served surface and nothing
  in `openapi/v1.yaml` declared it, so no operation changed and the `/v1` prefix
  is untouched.

### Added

- **`test/services/webhooks/concurrent_delivery_test.rb`** — the deterministic
  regression test for the duplicate-payment race, and the reason the fix is
  trustworthy. **No sleep, no retry and no loosened assertion anywhere in it.**

  The interleaving is *manufactured*, not hoped for: `ProcessorWebhook#handled?`
  is the mouth of the check-then-act window, and a two-party barrier
  (`Mutex` + `ConditionVariable`, no timeout) holds both threads in it until both
  have arrived. Without that, "two threads, same event id" is a *probable*
  duplicate, and a test asserting a probable outcome is a flake generator.
  **Twelve consecutive runs, 10 runs / 24 assertions / 0 failures / 0 errors /
  0 skips, every one** — and that stability is a *result*, not an accident: it is
  what fixing the 3-in-60 classification flake above bought. The file is also now
  in the `gate` job's **webhook tier**, so the regression is gated by name rather
  than only counted in the whole suite.

  Two things about it are not obvious and both were learned the hard way:

  - **The gate is installed with `alias_method`, not `prepend`.** Ruby cannot
    un-prepend a module, and a file-scope `prepend` in a test would change every
    other test in the suite for the rest of the run. The original is restored in
    `ensure`.
  - **The query cache is dropped before any count is read.** Active Record's
    query cache is on in the test environment, cleared between tests but **not
    within one**, and every count here is taken on the main thread *after* the
    worker threads have committed. Nothing a worker thread did invalidates
    anything this thread read earlier, so counts came back stale — `0` for a table
    holding a committed row, and one run reporting `4 outbox rows` where there
    were `2`. A count that cannot see the rows it is counting is a tripwire wired
    to nothing, and this is the one file where a green count would have meant
    nothing at all.

  It also carries the negative controls: two *different* event ids must still be
  two events (an index over the wrong expression would refuse a subscription's
  `started` then `updated` while looking like it worked), and the start payload
  is asserted to carry no `processor_event_id`, so it cannot silently become the
  thing the other half tests.

- **`test/models/outbox_processor_event_id_migration_test.rb`** takes the new
  migration **down and back up for real**. The middle step is the one that
  matters: with the index down the duplicate is writable, and with it up it is
  not, with nothing else in the model changed between the halves — which is what
  shows the constraint is what refuses, rather than a model validation.

  It is a separate file for a safety reason, not a taste one: **running a
  migration commits the enclosing transaction**, so a reversibility test inside
  `outbox_event_test.rb` made every row it had written durable and broke four
  unrelated tests with counts one too high. Its `teardown` restores the index
  unconditionally, because a failed assertion partway through would otherwise
  leave the index down for the whole suite.

- **`test/contract/tenant_isolation_matrix_test.rb`** enumerates every `/v1`
  operation the router serves and requires each one to be classified as
  account-scoped or not, in **both** directions, with a reason. Every entry is
  `unscoped` on this commit, and that word is load-bearing: it is what makes
  "this route touches another tenant's data" distinguishable from "this route
  does not". It asserts the verdicts as a **set** rather than as a count, so the
  day a route is genuinely scoped the failure names the verdict that changed
  instead of reporting a number that moved.

  It lives in `test/contract/` rather than beside the envelope spec because that
  file skips when `core` is not on disk, and a check that hides behind a skip is
  not a check. This one reads the router, the models and the README, none of
  which is core.

- **`test/integration/secrets_do_not_leak_test.rb`** captures real log output
  from the **failure** paths — a processor refusal, an unconfigured signing
  secret, a rejected signature, a parked delivery, a rendered problem body — and
  asserts that a processor API key, a Stripe signing secret, the signature header
  itself and a customer email are all absent. It renders the failures rather than
  the happy path, because the failure path is where leaks live: nobody logs a
  value on the way in and everybody logs the exception on the way out.

  The file's own existence is the finding. The fleet measured it: **no
  off-the-shelf static analyser finds a secret leaked at runtime** — zero of 268
  Semgrep rules intersect CWE-532, gosec has no `*ast.CallExpr` case, Bandit is
  `ast.Constant`-only. Every one of those tools finds a *constant* that looks
  like a credential, which is not the same question. Every value in the file is
  a literal that is a credential for nothing.

### Known issues

- **The three `billing.subscription.*` payloads are published in a shape core's
  payload schemas reject.** core's D10 rewrote those schemas because "billing has
  no subscriptions table and cannot invent ids it does not have" — true of
  billing-03b, and not true of billing-04, which added the table and moved the
  subscription events onto billing's own ids (`subscription_id` is
  `Subscription#id`, which is also the envelope's subject, alongside `plan_id`,
  `account_id`, `currency`, `started_at` and `processor_subscription_id`). core's
  schemas are the processor-normalised shape billing-03b emitted and are closed
  with `additionalProperties: false`.

  Recorded in `PENDING_PAYLOAD_ALIGNMENT` and asserted in both directions, and
  raised as a DECISION NEEDED in `cafaye.yml`. core's own D10 names this as the
  second breaking change and core is read-only from a service worktree, so it is
  core's to make. Matching core from here would mean either emitting a payload no
  consumer has agreed to or dropping `plan_id` and `account_id`, which are the
  two fields that make a subscription event actionable.
- **core's `billing.plan.*` schemas do not name `entitlements`,** which
  billing-04 added to `Plan#as_json`. Same reasoning: a missing constraint in a
  core schema, recorded rather than worked around, because removing the field
  from the payload is a contract change and `Plan#as_json` is also the HTTP
  response shape.
- **`core: ^0.2.0` is pinned to the last released spec.** core's D10 is marked
  Breaking and is still in core's `[Unreleased]`, so there is no `0.3.0` to pin
  to. `^0.2.0` excludes it, so the day core tags it every service in the fleet
  has to move at once — a service whose CI resolves core would otherwise resolve
  a different core than the one this contract test reads off disk.

Billing domain v0, in three packets. **billing-02**: customers and plans — the
schema, the models, the `/v1` API, and the transactional outbox. **billing-03b**:
the Stripe webhook — a signed inbound event, stored once, turned into one of
this service's own events. **billing-04**: the subscription lifecycle — a
customer subscribes, moves between plans, and is cancelled, with the whole
state machine driven by the webhook and no status decided by a request.

billing-04 changes one claim the earlier packets made. "This service receives
from Stripe and does not talk to it" was true and is no longer: a subscription
is bought through a Stripe Checkout Session, cancelled by asking Stripe to
cancel, and moved between plans by asking Stripe to move it. The claim that
replaces it is narrower and checkable — **every request this service makes to
Stripe is one of the three methods on `Processor::StripeClient`, and there is no
other `Stripe::` call in the repository.** No new dependency: the `stripe` gem
was already here, for `Stripe::Webhook.construct_event`.

### Added

- **`subscriptions`** — id uuid, `account_id` (identity's uuid, no foreign key and
  no association, for the same reason `customers.owner_id` has none),
  `customer_id` and `plan_id` (real foreign keys), `processor_subscription_id`
  (**UNIQUE**, and that index is the resolution mechanism rather than a query aid —
  every event about a subscription is looked up by it), `status`, the current
  period, `cancel_at_period_end`, `canceled_at`, and `last_processor_event_at` —
  the processor's own `created` for the last event applied, which is the only way a
  delivery that arrived late can be told from one that arrived now. `timestamptz`
  for the instants.
  `UNIQUE [account_id, plan_id] WHERE status <> 'canceled'`: one *live*
  subscription per account and plan, because `canceled` is the only terminal
  status, and a customer who cancels and returns has to be able to subscribe to
  the same plan again.
- **`Subscriptions::StateMachine`** — the lifecycle as one pure object. The whole
  legal/illegal grid is a single table, so the set of *impossible* transitions is
  readable rather than inferred from conditionals. There is one rule and the rest
  of the lifecycle is ordinary code: **`canceled` is terminal, and nothing leaves
  it.** A status the processor uses and this service does not model
  (`incomplete`, `incomplete_expired`, `paused`) is refused by the constructor
  rather than coerced — a row that said `active` for a subscription the processor
  calls `incomplete` would grant entitlements nobody paid for.
- **`Subscriptions::Lifecycle`** — the **only** writer of a subscription's state and
  the only thing that emits its events. No `after_update` on `Subscription`, and no
  branch of the API that changes a status: cancelling and changing a plan both ask
  the processor and wait for the webhook. One writer means one answer to "what is
  this subscription's status", and it comes from the party that can bill.
  The event type is derived from *what the delivery did to the row* rather than
  from the processor's event type, which is what makes out-of-order delivery safe.
- **`Subscriptions::PlanChange`** — when a move to a different plan takes effect.
  **A more expensive plan takes effect immediately and the processor bills the
  difference; a cheaper or equally priced one takes effect at the end of the
  current period, with nothing carried forward.** The only arithmetic in the object
  is a comparison of two `Money` values; there is no credit, no refund, no prorated
  figure and no annualisation, so there is nothing in it that could disagree with
  the processor's books. Cross-currency and cross-interval comparisons are refused
  rather than guessed: ten dollars a month against a hundred a year is not a cheaper
  plan, it is a different unit.
- **`Processor::StripeClient`** — the whole outbound surface to Stripe: a Checkout
  session, a plan change and a cancellation. It sends a `proration_behavior` and
  never an amount; it asks for no refund and no proration on a cancellation,
  because the credit for an unused period is the processor's to compute and a refund
  calculated here would be a figure this service did not keep. The `api` keyword is
  the seam the specs replace, so a spec exercises this class's own argument
  building rather than a parallel implementation of it. A missing `STRIPE_API_KEY`
  is a `503` and never a `4xx`: it is this service's misconfiguration, and telling
  a caller its request was wrong when the service cannot reach Stripe at all sends
  an operator looking in the wrong place.
- **`plans.entitlements`** — jsonb, `{}` by default: what buying a plan grants.
  An object with at most `features` and `limits`, so a reader never has to ask
  whether a key it does not know is one it should honour. A limit is a *count*,
  never an amount: there is no currency in that object, deliberately. The shape is
  closed in `Plan` and the top level is held by three `CHECK` constraints, because
  a public field that consumers gate features on should not be a shape every reader
  guesses at.
- **`GET /v1/subscriptions/:id/entitlements`** — what the plan grants, and whether
  this subscription is granting it. A `canceled` subscription grants nothing
  (`features: []`, `limits: {}`); a `past_due` or `unpaid` one still grants,
  because the processor's grace period is a product decision and not this service's
  to take away.
- **`POST /v1/subscriptions`** — creates a Stripe Checkout Session and returns its
  URL. **It writes no subscription**, deliberately: a subscription does not exist
  until the payment completes, and a row for one that does not would be a sixth
  status meaning "we asked", which is a state no processor can report. The 201
  carries the session and no `Location`, because there is no resource to point at;
  the row appears when `customer.subscription.created` arrives.
- **`POST /v1/subscriptions/:id/cancel`** and
  **`POST /v1/subscriptions/:id/change_plan`** — ask the processor to act and
  return. Neither moves the local row, because a response claiming a cancellation
  had happened would be a lie about a state this service does not own.
  `at_period_end` is a required boolean: the caller chooses, and this service does
  not inherit a processor's default on its behalf. A `past_due` subscription cannot
  be cancelled at the end of a period it is not going to be charged for, and is a
  422 rather than a silent immediate cancellation. `change_plan` is the one place
  that returns something other than the row — a `plan_change` object saying whether
  the move takes effect immediately or at the period end — because without it a
  client cannot tell a caller that a downgrade is scheduled rather than applied.
- **A real coverage gate for the money paths.** `Coverage.start` runs *before* the
  application boots and the app is eager-loaded inside the measurement window,
  because measuring from inside the suite would report a file as covered when the
  corpus had merely autoloaded it. The gate's own honesty is asserted: a corpus
  that reaches almost nothing must be reported uncovered, and a method nothing calls
  must fail it. A second test partitions every file that touches money into money
  paths and files with money in them, so a new one cannot be added ungated — and
  the mixed files' money entry points are asserted behaviourally, so "not in the
  gate's list" never quietly means "not covered".

### Changed

- **`billing.subscription.started` now satisfies core's payload schema.** The gap
  `PENDING_PAYLOAD_ALIGNMENT` tracked since billing-03b is closed: a started event
  is now built to core's eight fields and nothing else, because that schema is
  closed with `additionalProperties: false`. What replaces it is smaller and is
  tracked in its own set: core asks for `sub_`/`pln_`/`acc_` prefixed ULIDs and
  this service's ids are uuids. Changing them is a breaking change to a contract
  several services already read, so it is a platform decision — and the contract
  test now asserts the disagreement in both directions, so a payload that starts
  matching fails rather than sitting there.
- **A subscription event's `subject` is billing's own `Subscription#id`**, not the
  processor's. This is the flip billing-03's `DECISION NEEDED` recommended landing
  with the table, and it is what lets a consumer join `started`, `updated` and
  `canceled` on one key with no lookup table. Payment events keep the processor's
  id, because an invoice references a subscription rather than being one.
- **Two assertions in the webhook integration spec changed, on purpose.** billing-03b
  asserted that a `customer.subscription.deleted` arriving before its
  `created` still emitted an event for each. That left an **active** subscription
  row — and an active row grants entitlements — for something the processor said
  was gone. billing-04 keeps the deletion as a canceled row, which grants nothing,
  and refuses the creation that follows. The endpoint's answer is unchanged: both
  deliveries are `200`.
- `Webhooks::Ingestion` passes the processor's event time to the handler as well as
  to the outbox row, so an event's `time` and its payload's `started_at` are one
  instant read once. The ingestion layer itself is otherwise unchanged; the ordering
  it already had is what puts the domain write and the event in one commit.
- `openapi/v1.yaml` is at `1.1.0` and `Plan#as_json` carries `entitlements`. Both
  are non-breaking additions under the same `/v1` prefix, which is core's rule.
- `cafaye.yml`'s `DECISION NEEDED` notes are updated rather than accumulated: the
  `subject` decision is closed, and a new one records that this service now talks
  to Stripe, with the narrower claim that replaces the old one.

### Not done

- **`billing.subscription.past_due` is not published.** It is in core's catalog and
  a failed charge is the obvious trigger for it, but this build reports arrears as a
  change to the subscription's status in `billing.subscription.updated` and states
  the failed charge in `billing.payment.failed`. Whether that is one event or two is
  a question about what a consumer does with them; a manager who wants the second
  type needs a row agreed in core first, and the mapping is then one line.
- **A subscription created directly in Stripe's dashboard is recorded as
  `ignored:unknown_customer`, not tracked.** It carries no cafaye customer id, and
  matching it to whoever shares an id would be a guess about whose money it is.
- **No trials, no usage-based and no seat-based billing.** Only the flat plan
  lifecycle the packet asked for. A `quantity` is reported in the event payload
  where the processor sends one, and is not a column, because nothing here can act
  on it.
- **The publisher loop still does not exist.** `published_at` is always null and
  nothing consumes these events, including courier.

### Added (billing-02 and billing-03b)

- **`customers`** — id uuid, `owner_type` + `owner_id` (a reference to identity's
  `User` or `Account`, stored as a uuid with **no foreign key and no Active
  Record association**, because the class it would associate to lives in another
  service), `processor`, `processor_customer_id`, `email`, `metadata` jsonb,
  timestamps. `UNIQUE [owner_type, owner_id, processor]`, so one owner has one
  customer per processor and a processor migration does not collide on the way
  there.
- **`plans`** — id uuid, `name`, `slug` (unique, kebab-case), `processor_product_id`,
  `processor_price_id`, `amount_cents` (integer, `CHECK >= 0`), `currency`,
  `interval`, `trial_days`, `active`, timestamps. `amount_cents` is an integer of
  **minor units**, not of cents: the name is left as the packet specified it and
  a JPY plan stores 500 in a column called `amount_cents`, which is a naming
  smell recorded rather than silently renamed.
- **`Plan#price` / `Plan#price=`** — the only way an amount enters the model.
  The reader returns a `Money`; the writer accepts nothing else and raises
  `Money::InvalidAmountError` for a bare integer. The two columns are
  `amount_cents` and `currency`, and no code path writes one without the other.
- **`outbox_events`** — core's column list, in core's DDL shape: `id` (the
  envelope's `id`, generated before the insert so a republish dedupes),
  `event_type`, `source`, `subject`, `time`, `data` jsonb, `created_at`,
  `published_at`, `attempts`, with `timestamptz` for the instants and the
  partial index on `(created_at) WHERE published_at IS NULL` that core's
  publisher query needs. Inserted by `after_create`/`after_update`, so the event
  and the change it describes commit or roll back together; a test asserts this
  by rolling back inside a transaction and checking that both rows are gone.
- **Eight events, three-segment and service-prefixed as core v0.2 requires**.
  Three from the models — `billing.customer.created`, `billing.plan.created`,
  `billing.plan.updated`, which fires only when a field actually changed — and
  five from the Stripe webhook mapping: `billing.subscription.started`,
  `billing.subscription.updated`, `billing.subscription.canceled`,
  `billing.payment.succeeded`, `billing.payment.failed`. `cafaye.yml` and
  `OutboxEvent::TYPES` hold the same eight, and `test/contract/` fails if either
  drifts, so a type cannot be emitted without a manifest row or advertised
  without an emitter.
- **The `/v1` API** — `POST/GET /v1/customers`, `GET/PATCH /v1/customers/:id`,
  `POST/GET /v1/plans`, `GET /v1/plans/:slug`, `PATCH /v1/plans/:id`. Request
  specs written first and shown failing, covering round-trips, the error
  envelope, `409` on a uniqueness collision, `422` on a bad field, cursor paging
  and idempotent replay.
- **`application/problem+json` for every non-2xx**, RFC 9457 with core's
  extensions, built in one place (`app/lib/problem.rb`) so no controller can
  invent a shape. Includes the paths Rails raises into — an unknown `/v1` path
  and an unhandled failure are problem+json too, via
  `config.exceptions_app`, instead of the HTML page Rails would otherwise
  return.
- **`X-Trace-Id` on every response** and in the body of every error, core's rule.
  It is set from the `after_action` *and* from the error renderer, because
  `rescue_from` runs outside the callback chain: without the second call every
  rescued response — every 404, 409 and 422 — would ship without the id support
  starts from.
- **Cursor pagination** on both collections (`data` + `page`, default 25, capped
  at 100, keyset on `(created_at, id)`, 24-hour expiry returning `400
  cursor_expired` rather than silently restarting at page one).
- **`Idempotency-Key` on both POSTs**, backed by an `idempotency_keys` table
  scoped to (endpoint, principal, key) with a request digest, so a replay with
  the same body returns the original response and `Idempotency-Replayed: true`,
  and a replay with a different body is a `409 idempotency_key_reused`. Only
  successful responses are remembered: a frozen 422 would lock a client out for
  24 hours for fixing nothing.
- **`openapi/v1.yaml`** — the HTTP contract, and `cafaye.yml` now declares it
  plus the published event types. This closes the `> DECISION NEEDED` that
  billing-01 recorded about the absent `exposes`.
- **`test/contract/`** — checks the emitted envelopes against core's real
  `event-envelope.schema.json` (reading core, not paraphrasing it), checks that
  the event-type and subject patterns this service validates with accept
  exactly the strings core's accept, and checks that the manifest and the code
  agree about which events exist and that the OpenAPI document is where the
  manifest says it is.

The following are packet **billing-03b**, the Stripe webhook. It receives; it
never calls.

- **The `stripe` gem (`~> 19.6`)** — the first dependency beyond Rails'
  defaults and `pg`, and the only one. This build uses exactly one thing from
  it: `Stripe::Webhook.construct_event`, the signature verification. The
  signature scheme (HMAC-SHA256 over `timestamp.body`, with a tolerance window)
  is the processor's contract, so re-implementing it would have been a
  hand-rolled crypto path in the one place a forged amount must never be
  believed. No API client, no OAuth, no outbound request. `Gemfile.lock` was
  changed in its own commit for this.
- **`POST /v1/webhooks/stripe`** — the one authenticated path in this service,
  authenticated by signature rather than by token. Verified with
  `Stripe::Webhook.construct_event` over `request.raw_post` and nothing else; a
  body that does not verify is a `400` and is **stored nowhere**. A verified body
  that is not an event is also a `400`, and a missing signing secret is a `503`
  rather than a `400`, because that is this service's misconfiguration and
  reporting it as a bad signature sends an operator looking in the wrong place —
  the cause is logged, the body says only `unavailable`. Every other outcome is
  a `200`. Declared in `openapi/v1.yaml` under its own `webhooks` tag, and a
  test asserts the manifest's `exposes.api` document declares the path that
  `config/routes.rb` serves.
- **`processor_webhooks`** — the at-most-once record of what a processor sent.
  `processor`, `stripe_event_id` (**UNIQUE**), `type`, `payload` jsonb stored
  verbatim, `processed_at` `timestamptz` (NULL meaning "received, not finished",
  the only state a crash leaves), `error` text, timestamps. Plus a partial index
  on the unfinished rows — the question this table gets asked first — and a
  `CHECK` on the processor, written out in the migration rather than read from
  the model so the migration keeps meaning what it meant the day it ran.
  `ProcessorWebhook.ingest` turns the unique conflict back into a lookup, so two
  concurrent deliveries of one event produce one row.
- **`Webhooks::Ingestion`** — the boundary: store what arrived, act on it exactly
  once, record how it went. The outbox row and the `processed_at` that says the
  delivery is finished are **one commit**, so there is no window in which a
  consumer can see the event while the row still looks unfinished — and no
  process that dies between them can leave a published event that a redelivery
  would duplicate.
- **`Webhooks::StripeEvents`** — the processor's shape stops here. One registry
  builds both the handler table and the event-type table, so a type cannot be
  normalizable but un-emittable, or vice versa. Nothing is defaulted: a field
  the processor did not send is absent from the normalized hash rather than
  invented, because a webhook payload is the weakest input in the system and a
  silent default is how a customer ends up on a plan nobody charged them for.
  Amounts cross as `Money#to_h` — `{"amount_minor", "currency"}`, the platform's
  single wire shape for money — so a non-integer raises here rather than being
  rounded.
- **Nine committed Stripe fixtures** under `test/fixtures/stripe`. The webhook
  specs post the committed bytes, signed with a constant that is a credential for
  nothing, and assert against the real verification path: no network, no stubbed
  verifier. The fixtures' `created` timestamps are what the event-time
  assertions derive from, so a fixture edited without its tests failing is a
  fixture nobody looked at.
- **`config/database.yml` names its databases per checkout.** Worktrees run side
  by side, and two sharing one database name is not a near-miss: one worktree's
  `db:migrate` silently applies the other's migrations, `db/schema.rb` ends up
  holding tables neither branch has committed, and the suite passes against a
  schema the code does not describe. The name is derived from the directory, so a
  plain `billing/` checkout still gets `billing_development`;
  `BILLING_DATABASE_NAME` overrides it. CI sets `DATABASE_URL` and never reads
  it. Not part of the webhook, and not part of the outbox reconciliation — it is
  what made this worktree's gate runnable while two sibling worktrees shared a
  PostgreSQL on :5432.
- **`openapi/v1.yaml` is the union, not a replacement.** billing-02's customers
  and plans paths, schemas and responses are untouched; the webhook arrives as a
  new `webhooks` tag, one path, one header parameter, two schemas and two
  responses. Every problem body it declares is the same
  `application/problem+json` from `app/lib/problem.rb` the rest of the service
  returns — the parallel branch carried its own renderer and it is **not** in the
  tree, because a second error shape on one service is distinguishable only by
  which controller answered.

### Changed

- **The outbox row and the `processed_at` that marks a delivery finished are now
  one transaction** (packet billing-03b). The parallel branch wrote them as two,
  which is a window in which a process that dies leaves a row looking unfinished
  with the event already published — and the next delivery then emits a *second*
  `billing.payment.succeeded` with a second envelope id for one charge, the exact
  duplicate the table exists to prevent. A `before_update` that raises is the
  reachable stand-in for that process death, and three specs hold the property:
  a marking that cannot be written leaves no event behind it, leaves the row
  visibly unfinished, and the next delivery completes it exactly once.
- **`db/schema.rb` is one coherent schema**: `customers`, `plans`,
  `idempotency_keys`, `outbox_events`, `processor_webhooks` and `subscriptions`,
  at version `20260930000009`. Both branches created their own `outbox_events`
  migration; billing-02's is the one that stands, and each later packet adds a
  table or a constraint rather than a second definition of anything.

- `core: ^0.1.0` → `^0.2.0` in `cafaye.yml`. Spec v0.2 made three-segment event
  types mandatory, which is a breaking manifest change, and core's own
  guidance is to move the pin in the same commit as the rename.
- `config.consider_all_requests_local` is `false` in the test environment, not
  the generated `true`. With it on, the debug middleware intercepts every error
  response and returns its own HTML page, so no spec could see the thing this
  service promises. This does not make a bug quiet: `show_exceptions =
  :rescuable` still raises anything unexpected, so an unanticipated exception
  fails the suite rather than becoming a 500 the specs have to assert.
- `README.md` and `AGENTS.md` rewritten. Both described a repository with no
  billing logic in it.
- `OutboxEvent.publish!` takes a `time:` keyword (packet billing-03b). The
  default is unchanged, so the model-callback path is exactly as it was, but a
  webhook's event now carries the **processor's** timestamp rather than the
  moment this service wrote the row. A row that sat unpublished for an hour must
  still report when the change happened, and it is the only way an out-of-order
  delivery is detectable: two events stamped on arrival appear to have happened
  in the order they arrived.
- `OutboxEvent::TYPES` and `cafaye.yml`'s `exposes.events` went from three types
  to eight (packet billing-03b). The list is now closed in the enforcement
  direction too — a type that is not on it cannot be written at all, which is
  what stops a mapping from parking every delivery as a failure.

### Notes

- **Money at the boundary.** A price arrives as `{"amount_minor": <integer>,
  "currency": "XXX"}` and nothing else. A float and a decimal string are both
  `422`: the float has already lost the fact that it was nineteen dollars
  exactly, and the string would mean this API has two representations for an
  amount. Refused in `MoneyParams`, which is a plain module with no Rails
  dependency, so the rule is unit-shaped rather than controller-shaped.
- **A 422 names `price`, never `amount_cents`.** The client never sends the
  columns, it sends the field they are stored in, so a model error about a column
  is re-reported against the field the caller used — and never twice for one
  problem.
- **Rails `enum` was rejected for `processor` and `interval`.** An enum raises
  `ArgumentError` on an unknown value, which at an HTTP boundary is a `500` for
  something the client got wrong. They are string columns with an inclusion
  validation plus a `CHECK` constraint, so the database still refuses any value
  the model would not have written, and the client gets a `422` naming the field.
- **The outbox column is `event_type`, not `type`.** On any Active Record model
  a column named `type` is single-table inheritance, and a row whose value is
  `billing.customer.created` sends Rails looking for a class with that name. It
  is also what core's DDL says.
- **Migrations do not read model constants.** The `CHECK` constraints inline
  `'stripe'` and `'month', 'year', 'one_time'` rather than reading
  `Customer::PROCESSORS` and `Plan::INTERVALS`, because a migration has to keep
  meaning what it meant the day it ran, even after the model moves on.
- Clocks are injected with `travel_to`, never read. Every timestamp assertion in
  the suite derives from one constant in `test/support/test_support.rb`.
- **`processor_webhooks.type` is the processor's type, not an STI column**
  (packet billing-03b), so the model sets `self.inheritance_column = nil`. That
  line is load-bearing rather than tidiness: without it every `find` on the table
  tries to resolve `customer.subscription.updated` to a class and raises — which
  is how a table storing a third party's type strings breaks an ordinary query.
- **The unique index on `stripe_event_id` is the correctness mechanism, not a
  query aid** (packet billing-03b). It is declared explicitly in the migration
  rather than as `index: true` on the column, and `ingest` catches the conflict
  and returns the row the winner stored. A `500` there would tell Stripe to
  redeliver, which is the one thing guaranteed to race again.
- **Every terminal webhook outcome is a `200`** (packet billing-03b): a replay,
  an unmapped type, a deliberate ignore, and a mapping that raised are all
  recorded and all answered 200. A `5xx` would teach Stripe to retry a decision
  this service has already made, and would hide a parked row behind a timeout.
  `processor_webhooks.error` is the record: `ignored:<reason>` for a decision,
  `failed:<class>: <message>` for a row parked for a human, NULL `processed_at`
  for the one state a crash leaves.
- **A failed invoice reports `amount_due`, not `amount_paid`** (packet
  billing-03b). The obvious `amount_paid || amount_due` is wrong: the failed
  fixture carries `amount_paid: 0`, and `0` is truthy in Ruby, so it would report
  a failed 29.00 charge as a settled 0.00. Money is not worth a clever fallback.
- **Nothing on the webhook is token-authenticated, and nothing there may become
  so** (packet billing-03b). The sender is a processor, not a cafaye client. A
  `Bearer` on that path would be a second, weaker trust path to the same door.

### Not in this release

- **No publisher loop.** The outbox table and the transactional insert are here;
  the process that moves rows to NATS is not. `published_at` is always null,
  `attempts` always zero, and nothing consumes these events yet. This is the one
  gap that is an operational risk rather than a missing convenience, and it is
  the first thing the next packet should close.
- **No authorization.** No endpoint reads a token, because core's JWKS
  verification is not in this repository yet. The `/v1` surface is open and
  `GET /v1/customers` returns every customer, because with no token there is no
  `account_id` to scope a query by. Noted in README under "Known gaps".
- No subscriptions, no Stripe API calls, no invoices, no metered usage, no
  prepaid credit, no `pay_*` tables. Those are later packets and each needs its
  own brief — with the user reviewing the diff, since this is the service that
  holds the money. The webhook is the **report** of a state change, not the
  state: nothing in this packet writes a subscription or a payment, and
  `subject` is therefore the processor's own id (recorded as a `> DECISION
  NEEDED` in `cafaye.yml`; flipping it is one line in
  `Webhooks::StripeEvents.subject_for`).
- **The webhook receives and never calls.** `processor`,
  `processor_product_id` and `processor_price_id` are still stored and returned
  and still null in practice. There is no client, no OAuth, and no outbound
  request to Stripe anywhere in this repository.
- `checkout.session.completed` in payment mode becomes
  `billing.payment.succeeded`, because no invoice event exists for a one-time
  Checkout and that charge must not be lost. A **subscription-mode** session is
  deliberately ignored, with the reason recorded: it restates
  `customer.subscription.created` a moment later as a separate delivery with a
  separate envelope id, and emitting both would state one fact twice, so a
  consumer counting `billing.subscription.started` would count every Checkout
  signup twice.
- `billing.plan.updated` has no catalog row in core, and core has no payload
  schema for any event except one. Both gaps are recorded in `cafaye.yml` and
  enforced against this repository by `test/contract/` — asserted **as sets**,
  not subtracted from the failures, so a payload that starts matching still has
  to be deleted from the list deliberately. `billing.subscription.started` is
  published even though it does not satisfy core's payload schema: the catalog
  row exists, the envelope is core-shaped, and a payload a consumer cannot yet
  read is a gap in core rather than a reason to stop publishing. Concretely, core
  requires `plan_id` and `account_id` as `pln_…` and `acc_…` values and is
  closed over eight fields; this build has no subscriptions table, `Plan#id` is a
  uuid, and the normalized payload carries eleven keys core does not name. The
  difference is recorded as a `> DECISION NEEDED` in `cafaye.yml`; closing it is
  a core-side decision plus a subscriptions table.
- The cursor is unsigned, the unique-index race path is handled but not
  covered by a spec, and idempotency keys are never pruned. All three are listed
  in README under "Known gaps".

### Known gaps (observability)

- **billing cannot emit a metric gauge**, so a stalled outbox relay is invisible on
  the metrics signal and shows up only as a flat trace count. The alternative would
  be a service-side meter, and the metrics signal was deliberately left to the
  collector's `spanmetrics` connector so that it runs *after* redaction.
- **`SimpleSpanProcessor` exports on the request thread.** Its own documentation
  warns against production use and the warning is real. It is the deliberate trade
  in a service whose request volume is a Stripe webhook and a handful of reads, and
  the OTLP exporter has no retry queue and a short timeout, so a collector that is
  down costs a failed export rather than a slow request. A service that outgrew it
  would move to `BatchSpanProcessor` with a bounded queue — one line in
  `Kit::TracerInstaller`.
- **There is one span per request and nothing finer.** No span wraps a subscription
  lifecycle, a webhook ingestion or an outbox emission, so "how long did the
  processor call take" is not answerable from a trace. Each would be a child span
  started where the work happens, and none exists yet.
- **`BILLING_OTEL_DISABLED` switches telemetry off entirely**, and the only thing
  that says so is one startup log line. There is no metric for it, because a metric
  asserting that telemetry is off is a metric nobody is looking at.

### Changed

- **`LICENSE` is a Business Source License 1.1, and it was MIT.** OPS-D2 splits the
  fleet — the framework (`core`, `caf`, `kit`, `pantry`) stays permissive, the
  **services move to a Business Source Licence**: free to run, free to self-host,
  never to offer a competing service (`CAFAYE-OPS.md`, OPS-D2). billing is a
  service, so its grant moved with the policy in one commit rather than being left
  to contradict it. The move down is recorded here because OPS-D3's rule is that a
  superseded grant is superseded *out loud*: a repo whose grant quietly changes
  while its policy changed looks like a bait-and-switch to whoever read the old one,
  and the ambiguity is worse than either licence (`CAFAYE-OPS.md`, OPS-D3 and the
  risk-8 entry).

  The parameters are Licensor `Cafaye`, Licensed Work `billing`, Additional Use
  Grant `None`, Change Date `2030-10-10` — four years out, the fleet's fixed
  wording — and Change License `Apache License, Version 2.0`. The body is the
  reference BSL 1.1 text, so a diff between two cafaye services shows only the
  `Licensed Work` line.

  **Anyone who already holds a copy keeps the grant it was published under.** A
  copy taken while `LICENSE` said MIT is still MIT and this change takes nothing
  from whoever holds it; what changes is the grant a copy taken from today forward
  carries. `README.md`'s licence section says the same thing where a reader looks
  first.

  **No manifest field moved, because billing has none to move.** `cafaye.yml`
  declares no licence key and none can be added: core's manifest schema is a closed
  object — `additionalProperties: false` with no licence property among its twelve
  top-level keys (`core/schemas/cafaye.manifest.schema.json:7-9`, and core is
  read-only from a service worktree). billing also publishes no gem — no gemspec,
  and the `Gemfile` carries no `gemspec` directive — so there is no package
  metadata field to reconcile either. That is the same fact the MIT landing
  recorded (`CHANGELOG.md:260`): `LICENSE` and `README.md` are the entire grant,
  and both now agree.


## [0.1.0] - 2026-09-30

The v0 scaffold (packet billing-01). Structure before features: the shape every
later billing packet builds on, with no billing logic in it.

### Added

- Rails 8.1.4 API-only application on Ruby 4.0.1, PostgreSQL adapter, Kamal and
  Thruster for deploys. `Gemfile` dependency floor is Rails' defaults plus `pg`.
- `HealthController` with two probes that answer different questions. `GET
  /healthz` is liveness and touches no dependency, so a slow database cannot
  trigger a restart storm; `GET /readyz` runs `SELECT 1` on a leased connection
  and answers `503 {"status":"error","checks":{"database":"error"}}` when the
  database cannot answer, logging the cause and returning it to nobody.
  Integration-tested on all three paths, including the database-down path, which
  is exercised by faking the leased connection.
- `Money` (`app/models/money.rb`), the seed of the platform rule that money is
  integer minor units and never a Float. A frozen value object of an integer
  amount plus an ISO 4217 currency, with the real exponents for zero-decimal
  (JPY, KRW, VND) and three-decimal (KWD, BHD, OMR) currencies. It refuses rather
  than guesses: a Float amount, a sub-minor-unit amount that would have to be
  rounded, a fractional currency, arithmetic across two currencies, a negative
  result from a subtraction, a non-integer quantity, and any value outside the
  PostgreSQL bigint range. 97 table-driven cases, 100% line and branch coverage
  on the file.
- `db/migrate/20260930000001_init.rb` — a deliberate no-op. The schema lands with
  the Phase 3 packets; `db/schema.rb` is committed so a clean checkout can run
  the suite.
- `bin/prime` as the gate (`bundle install`, `db:prepare`, `rubocop`,
  `rails test`), `mise.toml` pinning Ruby 4.0.1 with the tasks, and
  `docker-compose.yml` running postgres:17 with a healthcheck. The Ruby version
  is written in exactly three places — `mise.toml`, `.ruby-version`, and the
  `Dockerfile` build arg — and they must move in one commit.
- `cafaye.yml`, validated against `core`'s frozen manifest schema. It declares
  identity, language, the `^0.1.0` core constraint, and the SSH remote. It has
  no `exposes`, which is a recorded gap rather than a judgement: that needs an
  OpenAPI 3.1 document, and specs are manager-owned. Marked in the file with a
  `> DECISION NEEDED` callout pointing at `core`'s
  `examples/valid/ruby-api.cafaye.yml`.
- `AGENTS.md` and this changelog, so the conventions that keep money correct are
  written down before the first price is modelled rather than after.

### Notes

- minitest 6 removed `Object#stub` (it moved to the `minitest-mock` gem). Rather
  than add a gem to reach it, `test/test_helper.rb` exposes
  `with_lease_connection`, which wraps the stub registry ActiveSupport already
  ships.
- CI runs Brakeman, `bundler-audit`, RuboCop and the suite. Nothing was
  disabled to make it green. Its PostgreSQL service is pinned to `postgres:17` to
  match `docker-compose.yml`.
- CI calls `cafaye/kit/.github/workflows/ci.reusable.yml@master`, which is kit's
  path and not the one an earlier note here named. kit-04 moved the file: GitHub
  documents that subdirectories of `.github/workflows` are not supported, so
  `cafaye/kit/workflows/ci.reusable.yml@master` resolved to nothing and no
  repository in the fleet was calling it. The `ruby` job is expected to be red
  on two steps for reasons that live in kit's file — `bundle exec rake` with no
  database, and `bundle exec rake coverage` against a task this service does not
  have — and the workflow's header names both with the errors reproduced.
  Everything load-bearing is in `gate`.

### Not in this release

No metered usage, no prepaid credit, no `pay_*` tables, and no publisher loop.
Those are later packets and each needs its own brief — with the user reviewing the
diff, since this is the service that holds the money.
