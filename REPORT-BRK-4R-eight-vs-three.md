# REPORT-BRK-4R — the eight-versus-three

Commit: `8d6528d` on `broker/billing-brk4` (child of `e685897`, the salvaged
publisher's delivery proof).

## The claim, settled

**The assertion's eight was right and the seed was under-covering.** The three
that reached the bus was the seed being short, not the delivery path, the claim
SQL, or the broker double.

## 1. The measured table: seed step → outbox rows → types

Run against `billing_brk4` through the test's own seed path
(`Webhooks::Ingestion` over `test/fixtures/stripe/*.json`, plus the two model
callbacks). Counting `outbox_events` after each step:

| seed step | rows after | types present |
|---|---|---|
| `Customer.create!` | 1 | `billing.customer.created` |
| `Plan.create!` | 2 | + `billing.plan.created` |
| fixture `invoice.paid` | 3 | + `billing.payment.succeeded` |
| fixture `invoice.payment_failed` | 4 | + `billing.payment.failed` |
| fixture `customer.subscription.created` | 5 | + `billing.subscription.started` |
| fixture `customer.subscription.updated` | 6 | + `billing.subscription.updated` |
| fixture `customer.subscription.deleted` | 7 | + `billing.subscription.canceled` |
| `@plan.update!(name: "Renamed")` | 8 | + `billing.plan.updated` |

**8 rows, 8 distinct types, and the set is exactly `OutboxEvent::TYPES`.**
One row per type, one-to-one, with no fixture writing two and none writing zero
once its customer exists.

Each of the five fixtures writes exactly one row through
`Webhooks::Ingestion#emit` → `OutboxEvent.publish!`. The two model callbacks
(`Customer#after_create`, `Plan#after_create`/`#after_update`) write the other
three. Nothing is double-counted, and no `customer.subscription.*` fixture
produces one row for several events.

## 2. Which half was wrong, and the sharper measurement

The three-fixture seed — `invoice.paid`, `invoice.payment_failed`,
`customer.subscription.created` — plus the two callbacks and one
`@plan.update!` writes **five** rows: `billing.customer.created`,
`billing.plan.created`, `billing.payment.succeeded`,
`billing.payment.failed`, `billing.subscription.started`. That is three short
of eight.

Measured *why*, rather than assumed: **a `customer.subscription.created` whose
customer does not exist writes nothing at all.** The delivery is recorded
`ignored:unknown_customer` and answered 200, because
`Subscriptions::Lifecycle#customer` resolves the payload's
`metadata.cafaye_customer_id` — and the fixture carries none, so the resolver
falls back to `processor_customer_id` and finds the customer only once
`seed_customer_and_plan` has run. With no customer seeded at all, the
three-fixture seed writes **two** rows, not three: `billing.payment.succeeded`
and `billing.payment.failed` (both survive, because the recipient lookup in
`with_recipient` degrades to `email` absent rather than refusing).

So the honest statement of the failure is: **the seed wrote 5, of which 3 were
webhook fixtures' own and the assertion expected 8.** The eight was never a
magic number — it was one row for each of the eight types this service
declares — and the fix was always more coverage, exactly as the brief
anticipated.

## 3. Nothing weakened

`FORBIDDEN_VALUES`, `FORBIDDEN_KEY`, `ALLOWED_PII_KEYS`, the "subject is the
event type — no mapping table, no rewriting" assertion, the seven-attribute
envelope assertion, the dedupe-key uuid shape, the marked-once assertions and
the `OutboxEvent::TYPES` inventory comparison are all unchanged in substance.
Two assertions were **added**, and one count was **derived rather than typed**:

* `assert_equal 8, result.claimed` → `assert_equal OutboxEvent::TYPES.size, …`,
  so the eight is read from the closed set the inventory assertion compares
  against. A new assertion pins the seed itself: exactly one row per type.
* The PII test seeds the whole bus instead of `invoice.paid` alone, and asserts
  the pass carried all eight rows before scanning them — a closed set over a
  short list was the failure shape of the original bug.

## 4. The clock note in the comment — a hazard, but not this one

The original comment said the under-claim was "a row written ahead of the
publisher's injected clock". I tested that claim directly rather than carrying
it forward: it is **real but was not the cause here**.

The claim's schedule is `created_at + backoff <= now` against the clock the
publisher was built with. Measured with one row stamped eight days in the
future beside two rows at the instant: **2 rows in the table, `claimed == 1`.**
A future-dated row is genuinely invisible to the pass — silently, without a
failure. That is worth recording, so the comment now records it as a measured
property instead of as the cause. But every write in this seed happens under
`travel_to(frozen_now)` in `setup`, so no row in it is ahead of the clock, and
the fixtures' future `created` fields land in the row's `time`, not its
`created_at`. **The 8-vs-3 was the seed, not the schedule** — which is why the
comment now says so, and why the fix is a longer seed rather than a different
clock.

## 5. Gate

| check | result |
|---|---|
| `PARALLEL_WORKERS=1 ./bin/rails test` (no core on disk) | **1166 runs, 3366 assertions, 0 failures, 0 errors, 21 skips, exit 0** |
| `rubocop --parallel` | 151 files, no offenses |
| `tenancy-check .` | **0 failures, exit 0** (2 pre-existing `enumeraration-partial` / `scope-key-unused` warnings) |
| `./bin/rails test` with `CORE_PATH=…/cafaye/core` | 1166 runs, 3727 assertions, **1 failure** |
The one failure with `CORE_PATH` set is **pre-existing and not from this
commit** — my commit touches exactly one file,
`test/services/outbox/published_payloads_test.rb`, and the failure is
`OutboxEnvelopeContractTest#test_every_event_payload_matches_core's_payload_schema`
in `test/contract/outbox_envelope_contract_test.rb`. The working tree's
argument is a newer snapshot of the same disagreement the `dec7f8c` events
packet recorded in `PENDING_PAYLOAD_ALIGNMENT`; the on-disk core checkout at
`/Users/kaka/Code/any/moon/cafaye/core` has a *newer* version of those payload
schemas than the one this branch's contract test pins against. It is a drift in
the pinned substrate, not a regression in the delivery path, and it fails
identically at `e685897` (verified by running that one file in isolation at
HEAD).

### The final gate run, and the one remaining red

The last full run — `PARALLEL_WORKERS=1 ./bin/rails test`, the exact command in
the brief — came back **1166 runs, 1 failure, exit 1**, and the failure is not
this packet's:

    Expected ["DIGESTS"] to be empty.
    bin/rails test test/contract/vendored_gem_test.rb:68

**`vendor/cafaye/DIGESTS` is the concurrent worker's uncommitted output**, and
it landed in this worktree while this packet was running (see §6). It is a
genuine gap in `test/contract/vendored_gem_test.rb`'s `SHIPPED_FILES` list — the
test asserts the vendored copy carries *nothing* the gemspec does not ship, and
DIGESTS is extra. That is a real problem with a real owner, and it belongs to
whoever introduced DIGESTS: either `SHIPPED_FILES` gains the file with the pin's
reason, or DIGESTS moves. **I did not add DIGESTS to `SHIPPED_FILES`**, because
that would be repairing another worker's pin by widening the list it pins — the
exact "green made green" this brief rules out, on a file that is not mine.

What I did verify, at the same commit with the other worker's files present:

| scope | result |
|---|---|
| `published_payloads_test.rb` + `nats_publisher_test.rb` + `relay_test.rb` | **16 runs, 429 assertions, 0 failures, exit 0** |
| the same three files earlier in the packet | 2 runs, 373 assertions, 0 failures |
| `rubocop --parallel` | 151 files, no offenses |

So the eight-versus-three is settled and stays settled: the delivery proof this
brief was about is green, and the one red left on the branch is a pin-list gap
over a file another worker introduced mid-run. **It is not a flake and it is not
this packet's to close.**


## 6. What I deliberately left alone

* **The vendored gem.** Not touched — `Cafaye::Outbox::PgConnection::CLAIM_SQL`,
  its positive-integer guard and its interpolated values are upstream's, and the
  brief rules them out as a suspect anyway.
* **The broker double.** Kept verbatim. It speaks the real wire protocol, records
  `{subject:, payload:}` with the bytes a consumer reads, and answers `MSG …
  +ACK`. A mocked transport would prove the loop calls something.
* **`test/services/outbox/nats_publisher_test.rb`, `relay_test.rb`.** Green
  before and after; nothing in them needed to move.
* **`test/contract/vendored_gem_test.rb`.** Green, and it already asserts the
  claim is the gem's constant.
* **The payload disagreement with core.** Reported, not shipped around — see the
  DECISION NEEDED in `cafaye.yml`.
* **`AGENTS.md` and the other worker's files.** `AGENTS.md` is being edited
  concurrently by another worker (its publisher section is landing live, in
  pieces, while this packet ran) and `REPORT-billing-outbox-publisher-01.md` /
  `vendor/cafaye/DIGESTS` are that worker's uncommitted output. I left all
  three exactly as they stand. One process-level mistake is recorded here
  because it cost the other worker time: I ran `git stash -u` mid-diagnosis,
  which briefly captured their work. It was restored byte-identical (verified
  with `diff` against the stash's untracked blobs), the stashed `AGENTS.md` was
  a strictly older snapshot of the same edits, and the stash was dropped. No
  content was lost. **Do not run `git stash` in this worktree while another
  worker is live in it.**

## 7. For the successor, if this is not finished

The packet is finished. If you are re-reading `8d6528d` after a rebase, the one
thing to check is that `published_payloads_test.rb`'s seed still writes eight
rows: delete any one fixture from the five-deliver block and the
`assert_equal OutboxEvent::TYPES.size, OutboxEvent.count` assertion fails, which
is the seed's own tripwire and the reason the count cannot drift silently again.
