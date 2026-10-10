# REPORT — BRK-4: billing's outbox publisher

**Branch:** `broker/billing-brk4`
**Gate:** `DATABASE_URL=… PARALLEL_WORKERS=1 mise exec -- bundle exec ./bin/rails test`
— **1166 runs / 3725 assertions / 0 failures / 0 errors / 21 skips**, baseline
1145 / 2919. The 21 skips are the pre-existing core-contract tier (no `core`
checkout beside this worktree and no `CORE_PATH` locally; CI checks core out and
fails on a single skip). **+21 runs / +445 assertions is mine, itemised in the
workflow's own header; no existing assertion moved.**

## What was built

Billing now drains `outbox_events` onto the fleet's NATS bus, and the three
files that do it are exactly the three things the shared gem says a service
owns. The claim, the envelope and the publish pass are **not** billing's:

- **`vendor/cafaye`** — a pinned copy of `cafaye-rb` at `5056500`
  ("Merge worker/cafaye-rb-ignore-01"), consumed as a `path:` gem. **Why
  vendored:** the gem is not on rubygems (`/api/v1/versions/cafaye.json` is a
  404; a name search returns `[]`) and `github.com/cafaye/cafaye-rb` is
  unreachable from this environment (`git ls-remote` answers "Repository not
  found"), so neither a released nor a git dependency resolves. This is the
  thing to fix **in cafaye-rb, not here**: publish the gem (or make the private
  repo reachable from CI) and replace the `path:` dependency fleet-wide.
  `vendor/cafaye/DIGESTS` pins every shipped file by sha256 and
  `test/contract/vendored_gem_test.rb` re-reads them **on every run, with no
  skip** — so the copy cannot drift silently, in CI or locally. The action item
  and the re-pin procedure are recorded in `vendor/cafaye/VENDORED.md`.
- **`app/services/outbox/nats_publisher.rb`** — the transport. One method:
  `publish(envelope)`. JetStream and not core NATS, because `published_at` is
  set from the broker's acknowledgement and only JetStream's `publish` blocks
  until the broker answers — marking on a core-NATS return would mark rows
  published the broker never stored. The publish is bounded by
  `PUBLISH_TIMEOUT` (10s, identity's `DefaultPublishTimeout`) because an
  unanswered publish must be a failure, not a wait. A broker that is down is an
  outage (the loop starts, publishes fail, rows accumulate and drain when it
  returns); a URL that does not parse is a boot failure.
- **`app/services/outbox/relay.rb`** — the loop. Fixed **one-second** poll
  (identity's `DefaultPollInterval`), batch **100** (the gem's
  `DEFAULT_BATCH_SIZE`, core's 100–500 at the low end), per-row failure
  isolation from the gem, `#stop` joins the thread and closes the transport
  from an `at_exit`. No `NoopPublisher` is wired anywhere: with no broker the
  rows stay and the boot log says so.
- **`config/initializers/outbox_relay.rb`** — the wiring. Starts the relay when
  `NATS_URL` is set, starts nothing when it is not, and is **inert in the test
  environment** — the suite boots this application once per parallel worker,
  and a developer with a local broker would otherwise publish fixture rows onto
  a real bus from inside a test run.

## The four "done" conditions

1. **With `NATS_URL` set, an unpublished row reaches the stream under a
   `billing.` subject, proved by a test asserting delivery.**
   `test/services/outbox/nats_publisher_test.rb` and `relay_test.rb` drive a
   real pass against `test/support/fake_nats_broker.rb` — an in-process broker
   speaking enough of the NATS protocol (INFO, PONG, SUB/PUB with a reply
   inbox, `MSG … +ACK`, and the `HMSG … 503` no-responders refusal) for the real
   `nats-pure` client to connect, request and be acknowledged. Ruby ships no
   embedded nats-server (identity's Go tests use one), so the broker is a double
   and everything else is real: the delivered subject is asserted equal to the
   event type, the delivered document is asserted equal to the envelope, and
   `published_at` is asserted null before the pass and set after.
2. **With `NATS_URL` unset, no loop starts and no row is marked.**
   `relay_test.rb` drives `Relay.start_from_environment(env: {})` and asserts
   nil, an empty broker, an unmarked row, and the boot-log sentence.
3. **No published event carries a processor secret or card data, asserted.**
   `test/services/outbox/published_payloads_test.rb` seeds **one row of every
   type in `OutboxEvent::TYPES` through its real emission path** (the two model
   callbacks plus five signed webhook fixtures through `Webhooks::Ingestion`),
   drains once, and scans every delivered document: no `sk_*`/`pk_*`/`whsec_`
   value, no card test number, no key named `secret|card|cvc|api_key|token|…`
   at any nesting — and the PII-shaped keys that exist are asserted as the
   closed set `email`, `name`, `owner`. `email` is core's own field on the money
   events; nothing else personal is on the bus.
4. **The gate exits 0 and the baseline moved with a measured reason.**
   1145→**1166 runs**, 2919→**3725 assertions** locally; CI's 1145/3280 →
   1166/3725 by the same delta, itemised in `.github/workflows/ci.yml`'s
   header. Two guards were additionally **seen red**: a tampered file in the
   vendored copy fails the DIGESTS test by name, and a relay that ignores the
   `NATS_URL` condition fails the no-broker test. Both were restored.

## Every event type billing publishes, and its subject

**The subject is the event type** — core's "no mapping table, no prefix
rewriting" — which is what the fleet's `billing.>` stream filter covers. The
envelope's `subject` *attribute* is a different field: the entity the event is
about (a billing uuid), carried inside the envelope and never on the wire.

| event type | NATS subject | written by |
|---|---|---|
| `billing.customer.created` | `billing.customer.created` | `Customer` after_create |
| `billing.plan.created` | `billing.plan.created` | `Plan` after_create |
| `billing.plan.updated` | `billing.plan.updated` | `Plan` after_update (only on a real change) |
| `billing.subscription.started` | `billing.subscription.started` | `Subscriptions::Lifecycle` (webhook `customer.subscription.created`, and the checkout path) |
| `billing.subscription.updated` | `billing.subscription.updated` | `Subscriptions::Lifecycle` (webhook `customer.subscription.updated`) |
| `billing.subscription.canceled` | `billing.subscription.canceled` | `Subscriptions::Lifecycle` (webhook `customer.subscription.deleted`) |
| `billing.payment.succeeded` | `billing.payment.succeeded` | `Webhooks::StripeEvents.payment_emission` (webhook `invoice.paid`), and the checkout path |
| `billing.payment.failed` | `billing.payment.failed` | `Webhooks::StripeEvents.payment_emission` (webhook `invoice.payment_failed`) |

`test/services/outbox/published_payloads_test.rb` asserts this table against
the bus as a set equality with `OutboxEvent::TYPES`, and the transport refuses
any type not prefixed `billing.` **before the wire**.

## Payloads that disagree with core — reported, not shipped around

**This packet changed no payload.** The disagreements below are the ones
billing's own contract test already records
(`test/contract/outbox_envelope_contract_test.rb:75`, `PENDING_PAYLOAD_ALIGNMENT`),
read before publishing, as the brief required. They are recorded here with the
file:line of the builder, because a publisher that emitted them is a publisher
that would make the disagreement visible to every consumer at once:

- **`billing.subscription.started`** — `app/services/subscriptions/lifecycle.rb`
  (the start payload). core's schema *requires* `customer_id`, `kind`,
  `processor`, `processor_event_id` and **rejects** `account_id`, `currency`,
  `email`, `plan_id`, `plan_name`, `started_at` under
  `additionalProperties: false`. Root cause, per core's own D10: core's
  subscription schemas describe the payload billing-03b emitted, and billing-04
  moved these events onto billing's own ids. Dropping `plan_id`/`account_id` to
  match core would emit a payload no consumer has agreed to; keeping them is
  why AGENTS.md says to prefer `GET /v1/subscriptions/{id}` over the event
  payload as the source of truth. The publisher does not rewrite the payload,
  so this is unchanged.
- **`billing.subscription.updated` / `.canceled`** — same builder. core requires
  `customer_id`, `kind`; billing sends `account_id`, `currency`, `email`,
  `plan_id`, `plan_name`, `processor_subscription_id`.
- **`billing.plan.created` / `.updated`** — `app/models/plan.rb` (`as_json`).
  billing carries `entitlements`, which core's plan schema does not name.
- **`billing.payment.succeeded` / `.failed`** — `app/services/webhooks/stripe_events.rb`
  (`payment_emission`). `PENDING_PAYLOAD_ALIGNMENT` records `email` as
  unexpected by core's schemas; the core checkout at `moon/cafaye/core` now
  *does* name `email` for both types, so that half is a stale pin in billing's
  contract test rather than a live disagreement. The contract tier cannot
  resolve it locally (no `core` beside the worktree) — **a successor with core
  on disk should re-run the contract tier and reconcile the table.**
- `billing.customer.created` (`app/models/customer.rb` `as_json`) **matches**
  core's schema exactly.

core owns the changes; per AGENTS.md, "fixing" this from here would mean either
editing core or emitting a payload no consumer agreed to.

## What was learned, and what the successor inherits

- **A row written ahead of the publisher's clock is not due.** The gem's claim
  evaluates `created_at + backoff <= now` against the publisher's injected
  clock, so a test that `travel_to`s its seed into the future has its rows
  silently skipped — measured as a pass claiming 3 of 8. My seed therefore
  writes at the suite's frozen instant (the assertions are over sets, not
  sequences). This is a real property of the schedule, not a test artefact:
  production rows are written with `Time.current` and due immediately at
  `attempts = 0`.
- **`PARALLEL_WORKERS=1` does nothing in this repository** —
  `test/test_helper.rb:98` hardcodes `parallelize(workers: :number_of_processors)`
  (8 on this machine). The suite is green at 8 workers on this branch; the
  segfault the brief warns about did not reproduce, but the env var is inert
  either way and worth knowing before trusting it.
- **The worktree was shared.** A manager recovery commit
  (`4d3a3dd`) salvaged my mid-session files while the previous attempt's
  endpoint failure was being retried, and another worker ran scratch tests in
  this tree during Q4 (since deleted, and excluded from my measurement). My
  commits after the recovery are `e685897` (delivery proof + digest manifest)
  and the docs/CI-baseline commit that follows this report.
- **Not built, deliberately:** no retention/pruning of `published_at` rows
  (README's known-gaps entry stands), no outbox metrics (metrics come from the
  collector's `spanmetrics`, per AGENTS.md), no consumer, and no core payload
  changes.
