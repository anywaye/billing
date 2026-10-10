# BRK-4R4 — the payload gap as it now stands

**Measured, not assumed.** Both gate environments, both numbers, and one correction
to the brief this packet was dispatched with.

---

## 1. The brief's premise is inverted, and the packet was already discharged

The brief describes one red: `PENDING_PAYLOAD_ALIGNMENT` records `email` and
`plan_name` as fields billing's payloads carry that core's schemas reject, and the
table no longer matches what the build emits.

The red was real. It is gone. It was closed by **`e9eefcc`** ("test(contract): the
payload gap core-w46 closed, recorded as closed"), which is one of the three commits
already on this branch when this session started, and which **has since been merged
to `master` and pushed** (`master` = `5ff48f2`, `origin/master` up to date with it,
as of 20:45 during this session; the branch `broker/billing-brk4` was deleted and
`/Users/kaka/Code/any/moon/wt/billing-brk4` was removed while I was working in it).

So the packet's substance is **done and merged**, and the two tables the brief asked
me to move already describe today's mismatches. What this session contributed is the
verification, the correction below, and the inventory in §4.

### What the red actually was, read from `44ca9f6`

`git show 44ca9f6:test/contract/outbox_envelope_contract_test.rb`:

```ruby
"billing.payment.succeeded" => { unexpected: %w[email] },
"billing.payment.failed"    => { unexpected: %w[email] },
"billing.subscription.started"  => { unexpected: %w[account_id currency email plan_id plan_name started_at], ... }
"billing.subscription.updated"  => { unexpected: %w[account_id currency email plan_id plan_name processor_subscription_id], ... }
"billing.subscription.canceled" => { unexpected: %w[account_id currency email plan_id plan_name processor_subscription_id], ... }
```

core's `b8ae8fb` (core-w46) declares both fields, so `payload_mismatches` — derived
from core's real schemas and the payloads this build emits — no longer contains
them, and the assertion's two-way set equality failed. That is the whole red.

### The correction

The brief reads the `e9eefcc` diff as removing fields from the payloads:

> `billing.payment.succeeded` and `.failed` — **`email` is gone** from the payload.
> `billing.subscription.started` / `.updated` / `.canceled` — **`plan_name` is gone**.

**Neither happened.** What `e9eefcc` removed was *entries in the recorded table*, not
fields on the wire. Verified in `app/` at this commit:

- `app/services/subscriptions/lifecycle.rb:362` — `"plan_name" => plan.name`, written
  unconditionally in `core_payload/1`, on all three subscription types.
- `app/services/subscriptions/lifecycle.rb:385` — `payload["email"] = customer.email
  if customer.email.present?`, absent-never-null, on all three subscription types.
- `app/services/webhooks/stripe_events.rb:300-309` — `with_recipient/1` merges
  `email` on the payment path by the same one indexed lookup on
  `customers.processor_customer_id`.

And core's `subscription.started` schema **requires** `plan_name`
(`"required" [..., "plan_name"]`) and declares `email` optional and never null, on
both payment types and all three subscription types.

So the direction of travel is the one the brief names as the alternative: **core
declared what billing was already sending.** No PII was withdrawn, and the guard in
the brief ("do NOT restore PII to satisfy a recorded gap") was never needed — there
was nothing to restore. This matters because the opposite reading invites exactly
the wrong fix: deleting `email`/`plan_name` from the payload builders would re-open
the gap in the *other* direction and would strip a consumer's only address.

---

## 2. The gate, from both environments

| | worktree | main checkout |
|---|---|---|
| path | `/Users/kaka/Code/any/moon/wt/billing-brk4` | `/Users/kaka/Code/any/moon/cafaye/billing` |
| commit | `5ff48f2` | `5ff48f2` |
| runs | **1175** | **1175** |
| assertions | **3747** | **3747** |
| failures / errors / skips | **0 / 0 / 0** | **0 / 0 / 0** |

Command, identical in both: `DATABASE_URL=postgres://billing:billing@localhost:15500/billing_brk4?sslmode=disable PARALLEL_WORKERS=1 bundle exec ./bin/rails test`

`tenancy-check .` (core's `harness/bin/tenancy-check`): **0 failures, 2 warnings** —
the same two warnings the previous relay recorded, both "I cannot see this"
(`tenancy.enumeration-partial`, 34 unclassifiable account-scoped sites;
`tenancy.scope-key-unused`), neither of which is new and neither of which moves the
exit code.

### The honest caveat on "both environments"

**The main checkout was not an independent environment for this measurement.** It was
on `44ca9f6` when I first read it (~20:25) and I confirmed the stale table there; at
**20:31:49** it was checked out to `5ff48f2`, and my two main-checkout gate runs were
started at 20:36:56 and 20:41:23 — both *after* that. So both numbers above are the
same commit measured twice, in two directories. The equivalence is real; the
independence is not, and I would rather say so than present it as a cross-check.

### The 9-run difference is now zero, and why

The brief predicts 1175 in the worktree and 1166 in the main checkout, the difference
being `test/contract/core_location_test.rb` (9 runs / 20 assertions), which only the
worktree has. That was true while main sat at `44ca9f6`. **It is no longer true**: the
main checkout is at `5ff48f2`, which contains `71d5d2b`, so `core_location_test.rb` is
on `master` and both counts are 1175. The 9-run difference was a *lag* difference, not
a location difference, and the merge closed it. If a future relay measures 1166, it is
looking at a checkout that has not caught up — which is the same signal BRK-4R2 was
about, one level down.

### One pre-existing environment quirk, verified not to change a result

Every `rails test` run in this worktree prints, before the run starts:

    bin/rails aborted!
    ActiveRecord::EnvironmentMismatchError: You are attempting to modify a database
    that was last run in `development` environment. … Tasks: TOP =>
    db:test:load_schema => db:test:purge => db:check_protected_environments

The suite then runs anyway. I checked the database rather than the message:
`ar_internal_metadata.environment` is `test` and `max(version)` in `schema_migrations`
is `20261006040000`, which is exactly `db/schema.rb`'s version. So the test database
holds the committed schema and the numbers above are sound. What the refused
`db:test:purge` means is that **the gate's schema-freshness step is inert in this
environment** — it never reloads `schema.rb`, so a stale schema would not be caught
by it. Worth a look sometime; not this packet's.

---

## 3. What I deliberately left alone

- **`PENDING_PAYLOAD_ALIGNMENT`** — unchanged. It already matches `payload_mismatches`
  exactly, in both directions, which is what the contract test asserts at
  `test/contract/outbox_envelope_contract_test.rb:308`. Nothing was cleared
  wholesale: the two `billing.plan.*` `entitlements` entries, the `missing:` sets
  (`customer_id kind processor processor_event_id` on `started`, `customer_id kind`
  on `updated`/`canceled`) and the other `unexpected:` fields
  (`account_id currency plan_id started_at` / `processor_subscription_id`) are all
  still there.
- **`cafaye.yml`'s mirror** — unchanged, and correct. Its bullet at lines 64-82 and
  the DECISION NEEDED at 98-110 describe exactly this state.
- **The payloads** — nothing restored or removed, §1.
- **core** — not touched. `b8ae8fb` already did the work.
- **No assertion weakened.** No guard edited, no threshold lowered, no skip widened.

### One finding worth acting on, and why I did not act on it

The brief says "The test asserts both places agree, so they must move together."
**No test does.** `cafaye.yml`'s mirror is *prose* inside a `# >` block; I searched
`test/` for any assertion comparing it to the Ruby table and found none. It cannot be
a structured key, either — core's manifest schema is closed with
`additionalProperties: false`, so `cafaye.yml` has no room for a machine-readable
mirror without a core change, which is out of bounds from a service worktree.

The consequence is the one that produced the brief's own confusion: the manifest can
describe a disagreement that has moved, and nothing notices.

The cheap guard is one test, in the file the table lives in: every event type named in
`PENDING_PAYLOAD_ALIGNMENT` must be named in `cafaye.yml`'s text. That is
one-directional and cannot be more — the manifest's prose names both the matching
types and the recorded ones, so *presence* is the only direction a text scan can
settle. It catches the realistic drift (a new debt entry added to the table and never
carried into the manifest) exactly as it is phrased. It would have to ship with the
`BASELINE_RUNS`/`BASELINE_ASSERTIONS` bump in `.github/workflows/ci.yml` in the same
commit, per AGENTS.md.

I did not write it, because **there was no longer anywhere to commit it**: the
worktree was removed and the branch deleted mid-session, and the only remaining
checkout is on `master`, which the manager owns and pushes. Per the quarterly
contract's Q2 rule, this report is the handoff instead.

---

## 4. Repos on this machine that read a sibling repo's files

The hazard `71d5d2b` closed is not billing's. Every worker gates in a worktree, a
worktree at `<root>/wt/<name>` has no `core` sibling, and a contract tier that reads
`../core` resolves to nothing and **skips wholesale while looking green**. BRK-4R2
measured exactly that in this repo. The same shape exists elsewhere:

| repo | what it reads | how it resolves | state |
|---|---|---|---|
| `billing` | core's schemas, catalog, `docs/event-naming.md` | `test/support/core_location.rb` — `CORE_PATH`, then `../core` beside `Rails.root`, then **core beside the primary worktree via `git worktree list --porcelain`** | **fixed** (`71d5d2b`). Both readers call it, so they cannot drift. |
| `cafaye-rb` | core's manifest schema (`test/contract/manifest_test.rb:158`), core's event schemas (`core_specs_test.rb:191`), core's schema+doc in `test/gate_declaration_self_test.sh:78` | `File.expand_path("../../../core", __dir__)`; only `core_specs_test.rb` has a `CORE_PATH` seam | **open.** `manifest_test.rb` has no seam at all and returns `nil` on `ENOENT` — the same "no problem" for a document never read. `gate_declaration_self_test.sh` symlinks `$REPO/../core` into a scratch copy, which works from the main checkout and nowhere else. Its own `REPORT-core-10.md` and `gate.yml:171` *name* the sibling path and stop there. |
| `muse` | core's schemas for its two parity tests | `MUSE_CORE_SCHEMAS=../core/schemas`, documented as assuming a workspace layout | **partially mitigated.** The variable is an explicit seam, but the default is a relative path and the docs say so; a worktree runs without it. `tests/gate_self_test.sh:85` is *already* worktree-aware — it tries `$ROOT/../core` then `$ROOT/../../core`. |
| `cafaye-ts` | core's `harness/bin/gate-check` | `test/gate_self_test.sh:141` tries `$ROOT/../core` then `$ROOT/../../core`, with a `CAFAYE_CORE` override | **already worktree-aware.** This is the pattern billing's `core_location.rb` should have borrowed in the first place. |
| `pantry` | core's manifest schema | **vendors a copy** and pins its digest in `vendir.lock.yml` | **immune**, and the only repo of the five that is. |
| `core` (itself) | `harness/cafaye_contract.py` takes `--core ../core` | explicit flag | fine — the caller names it. |

Two of these are the same defect billing just fixed: **`cafaye-rb`** (no seam on the
manifest schema, and a shell self-test that symlinks a sibling) and **`muse`** (a
parity tier that skips unset). `cafaye-ts`'s two-candidate loop is the ready-made
answer for both, and billing's `core_location.rb` is the more thorough one. I left
all of them alone: they are other repos' packets, and this brief's scope was billing's
table.

---

## 5. The successor's first move, if there is one

1. Read §1 and stop worrying about the red — it is merged.
2. Re-gate from *both* environments **before** deciding anything, and record each
   checkout's commit alongside its numbers. "Both green" at the same commit is a
   re-measurement, not a cross-check; the 9-run difference only appears while main
   lags, and it has now closed.
3. If you want the manifest-mirror guard from §3, it is one test plus a
   `BASELINE_RUNS`/`BASELINE_ASSERTIONS` bump, and it needs a worktree to live in.
