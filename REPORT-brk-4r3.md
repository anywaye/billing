# REPORT — BRK-4R3: landing the salvage, and the equivalence that is the deliverable

Branch `broker/billing-brk4` (recreated from master after the manager's merge),
worktree `/Users/kaka/Code/any/moon/wt/billing-brk4`. Base `44ca9f6`.
Four commits, all merged into master as a fast-forward: `e9eefcc`, `71d5d2b`,
`25d2da1`, `5ff48f2`. This report is the fifth commit, landed after the merge
because the worktree it was first written in was removed underneath this relay
while the last measurement was still running.

## The measurement that is the packet

Same commit, same code, both checkouts, sequential runs against the same
PostgreSQL, `PARALLEL_WORKERS=1`, one suite at a time:

| | runs | assertions | failures | errors | skips |
|---|---|---|---|---|---|
| worktree, `44ca9f6`, before | 1174 | 3746 | 0 | 0 | **21** |
| main checkout, `44ca9f6`, before | 1174 | 3746 | **1** | 0 | 0 |
| worktree, after | **1175** | **3747** | 0 | 0 | **0** |
| main checkout, after | **1175** | **3747** | 0 | 0 | **0** |

Both trees now give one number. `tenancy-check .` — 0 failures, 2 pre-existing
warnings. `rubocop --parallel` — 153 files, no offenses. `brakeman` — no
warnings. `bundler-audit` — no advisories. `test/contract` on its own: 68 runs
/ 479 assertions / 0 skips. `test/authentication` on its own: 68 runs / 184
assertions / 0 skips. Both are the figures `.github/workflows/ci.yml` asserts.

## 1. What this packet was, and what the previous relay left

The brief dispatched me to land an interrupted relay's work and close the red
it found. What I found was further along than "dirty with salvage": the salvage
had been committed as `71d5d2b` while I was reading, and `25d2da1` — the
previous relay's full report, `REPORT-brk-4r2.md` — appeared at 20:13, minutes
into this session. **I judged that work, verified it independently, kept it, and
finished from there.** Nothing of it was wrong; what was wrong was three
numbers in two documents, which is what this packet's own rule says to fix.

The mechanism, re-verified before I touched anything:

* Both readers that touch core's files answered "where is core" as
  `Rails.root.join("..", "core")`. That resolves beside the **main** checkout
  and **nothing** from a worktree — a worktree lives at `<root>/wt/billing-<name>`
  and has no `core` sibling. `outbox_envelope_contract_test.rb`'s `setup`
  skips 20 tests; `subscription_delivery_test.rb` skips one more; **21 = the
  worktree's exact count**, and the whole payload contract was among them.
* The fix is `test/support/core_location.rb`: one resolution order used by both
  readers — `CORE_PATH`/`CORE_SPECS_PATH` (CI's seam), `../core` beside
  `Rails.root` (the main checkout), then **core beside the primary worktree**
  found through `git worktree list --porcelain`. The skip is not weakened and
  not deleted: a repository cloned on its own still skips, because answering
  "no problem" for a schema never read is the outcome a contract test exists to
  prevent.
* `test/contract/core_location_test.rb` asserts the resolution works with
  nothing configured, from this directory, and pins the two bugs the module had
  on first write (`Pathname.new("")` expanding to the working directory; a
  reader handed `nil` raising instead of skipping).

I verified each claim myself rather than reading it forward: the resolution
order by reading the module, the counts by running the tiers, the bugs by
reading the tests that pin them.

## 2. The brief's hypothesis, probed again, and still wrong

The brief's reading of the diff was stated as a plausible reading: billing
moved *toward* core's schema by dropping `email` from the payment events and
`plan_name` from the subscription events. **It did not.** `app/` has zero diff
against `44ca9f6` in this packet. I verified the direction independently, by
two routes:

* **The emitter.** `app/services/webhooks/stripe_events.rb:301-308`
  (`with_recipient`, one indexed lookup on `customers.processor_customer_id`,
  merged absent-never-null) and `app/services/subscriptions/lifecycle.rb:362,385`
  (`core_payload` writes `plan_name` unconditionally and `email` when present).
  Both fields are still on every money event.
* **core's schemas on disk.** Commit `b8ae8fb` (core-w46, *"billing's money
  events: declare the recipient and the plan name"*) declares them **the way
  billing already sends them**: `email` OPTIONAL and NEVER NULL on all five
  money events, `plan_name` REQUIRED and non-empty on the three subscription
  events. So the mismatch closed **from the core side** — the schema moved to
  fit the publisher, which is the direction core's D10/D39 argument anticipates.

So the recorded gap shrank the honest way, and `PENDING_PAYLOAD_ALIGNMENT`
went from **7 entries to 5**: the two `billing.payment.*` entries are gone
because those events now match core's schemas **exactly** (including the D11
`oneOf` over the invoice-backed and Checkout-backed shapes), and the three
subscription entries lost `email` and `plan_name` from their `unexpected`
lists while keeping the D10 disagreement (`kind`, `customer_id` missing;
`account_id`, `currency`, `plan_id`, `processor_subscription_id` unexpected).
`entitlements` on the two plan events is unchanged. The two entries could be
**deleted rather than emptied** because the test derives its expectations from
what the corpus actually emits and compares as a set — an entry for a type that
matches would fail the comparison, not describe it.

`cafaye.yml`'s recipient-fact DECISION NEEDED was rewritten rather than
deleted: it now records that core discharged the action item, that nothing was
removed from a payload, and that the PII position is unchanged. Nothing was
restored, no schema was edited, no assertion weakened, no test skipped.

## 3. The three numbers that were wrong, and the one measurement that fixes them

The previous relay's mechanism landed with the workflow's numbers and left two
documents describing the gate in older voices — the estimate-before-the-run
failure `44ca9f6`'s header warns about, arriving one commit later:

| document | said | measured |
|---|---|---|
| `AGENTS.md`, CI table | whole suite `998 / 2842`, contract tier `45 / 400` | **1175 / 3747**, contract tier **68 / 479** |
| `AGENTS.md`, equality bullet | "950 / 2724 … now 998 / 2842" | 1145 / 2919 on the worktree → **1175 / 3747, one number in both places** |
| `CHANGELOG.md` | `1174 / 3744`, "8 tests" | **1175 / 3747**, the file has 9 runs and 20 assertions |

`5ff48f2` corrects all three against the measured gate. A document that names
a number the workflow no longer asserts is a second gate, and a second gate is
a second thing to be wrong.

## 4. The interference, and how the last measurement was made honest

Two things happened to this relay mid-run, and both belong in the record
because both could have produced a false result:

* **I broke my own rule first.** While gathering tier evidence I ran
  `test/contract` and `test/authentication` concurrently with each other and
  with the first main-checkout gate — three suites against one database,
  against AGENTS.md's explicit "one checkout, one suite". The first
  main-checkout gate reported **1 failure**: the duplicate-charge race test
  counted 3 outbox rows for `evt_1PZQaBcDeFgHiJkLmNoPqR4`, which is the
  `invoice.paid` fixture's own event id — an id the concurrently-running
  contract corpus ingests. The failure was my protocol error, not a defect:
  the same code had passed green in the worktree minutes earlier with no
  concurrent writer. One earlier run of mine, launched without `mise exec` and
  without `PARALLEL_WORKERS=1`, also segfaulted its 8 pg workers and left a
  parent hung in the DRb reaper loop; that parent was killed, and the crash
  wrote no rows.
* **The environment was also foul.** `db:test:prepare` had been refusing to
  purge, because the shared test database carried an `ar_internal_metadata`
  stamp of `development` — left by an earlier prepare, in force for every run
  in this session's logs. With the stamp corrected to `test`
  (`db:environment:set`, the remedy the error itself names), each gate now
  purges and reloads, so one run's leftovers cannot become the next run's
  failure. **That is a hygiene fix the packet needed regardless of my own
  mistake**, and it is why the failure above is not reproducible now.

The final table at the top of this report is from sequential runs with no other
test process alive, against a database that purged at the start of each.

* **The manager merged and the worktree was removed underneath me.** Between
  the last two measurements, `broker/billing-brk4` was fast-forwarded into
  master and the worktree was deleted — while this relay was mid-gate. The
  draft of this report was **uncommitted and was lost with the directory**,
  which is the quarterly contract's "a tree with no commit in it is a tree
  nobody can recover", paid for in full and recorded here rather than quietly
  rewritten. The commits were safe (refs live in the repository, not the
  worktree), the merge is verified, and the worktree has been recreated at its
  original path on a recreated `broker/billing-brk4` at master so the two-tree
  equivalence above could be measured on the merged tree and a successor has
  somewhere to stand.

## 5. The fleet-wide hazard, named

This is not a billing defect. **Every worker on this machine gates in a
worktree, and a worktree has no `core` sibling.** Any repository that reads a
sibling's schemas from a fixed path inherits the trap by writing the identical
line. Measured across `/Users/kaka/Code/any/moon/cafaye`:

| repo | what it reads | what a worktree gets |
|---|---|---|
| **billing** | core's envelope + 8 payload schemas + catalog | **21 silent skips** — fixed by this packet |
| **cafaye-rb** | `test/contract/core_specs_test.rb` and `manifest_test.rb` read `../../../core/schemas/…` | no skip, but the comparison silently degrades: the pinned copy in `test/fixtures/core_envelope.rb`, and baked-in defaults in the manifest check |
| **muse** | `MUSE_CORE_SCHEMAS` gates `test_contracts.py`, `test_error_vocabulary.py`, `test_openapi.py` | **`pytest.skip` when the variable is unset** — the same silent skip, one env var over |
| **cafaye-ts** | `test/gate_self_test.sh` searches `"$ROOT/../core" "$ROOT/../../core"` | fails loudly (exit 2) when neither holds core — and its second candidate happens to resolve from a worktree under `wt/` |
| identity, parlor, website, cafaye-py | `../core/schemas/cafaye.manifest.schema.json` in `cafaye.yml` **comments** (an operator-run one-liner) | not a suite, so no silent green — but the documented path misleads an operator in a worktree |
| kit | carries `core/` **inside** the repository | not affected |
| courier, conductor | prose references to core's contract; no runtime reads | not affected |
| pantry | `registry/services/*/cafaye.yml`, `vendir.lock.yml` — vendir **snapshots**, not live reads | not affected |
| gateway, darkroom, docs, caf, oauth-stub | no runtime reads of core's schemas found | not affected |

The shape of the fix for the others is the one already written here, and it is
deliberately small: resolve core **through the primary worktree** rather than
through a sibling path, keep the explicit env seam first, and keep the skip for
a repository that genuinely has no core. **cafaye-rb is the most urgent of the
rest because it is the gem billing vendors** (`vendor/cafaye`), so the same
contract is being read at both layers, and billing's copy is now the safer of
the two.

**A fleet-wide packet is owed and is not this one.** The brief said to name it;
naming it is the action taken.

## 6. What I deliberately left alone

* **`app/` — zero diff.** No field restored, no field removed, no payload
  edited. A consumer needing `email` on a money event is a schema change in
  core's own packet, not a read-only service worktree's to make.
* **core's schemas — not edited.** The gap closed from core's side already;
  editing from a service worktree is out of bounds and would have hidden the
  real story.
* **The contract test — not deleted, not skipped, not weakened.** The only
  `skip` lines in the diff are the two pre-existing ones, unchanged in
  behaviour. `PENDING_PAYLOAD_ALIGNMENT` was not emptied: 5 entries remain and
  each is still derived-and-compared in both directions.
* **`test/support/core_location.rb` — kept as committed.** I verified it
  rather than rewriting it: the resolution order, the `nil`-not-`""` return,
  the `schemas/` + `cafaye.yml` identification, and the fallback that keeps a
  standalone checkout's skip reachable are all asserted, and all true.
* **The 2 pre-existing `tenancy-check` warnings** (`enumeration-partial`,
  `scope-key-unused`) — pre-existing on `44ca9f6`, unchanged, and not this
  packet's to settle. `0 failures` is the gate the brief set.
* **The `/v1` authorization tier's stale number** (66/180, measured 68/184
  since `504de05`) and the contract tier's stale number (52/420, measured
  68/479) were repaired by the previous relay, with the measurements recorded
  in the workflow. I re-ran both tiers to confirm the new numbers rather than
  reading them forward.
* **`Gemfile.lock` — untouched.** The previous relay's bundle activity
  installed what the lock already specified; the lock has no diff.
* **The other relay's session.** A second dispatch (BRK-4R4) was running in
  this worktree concurrently for part of this hour. I did not kill, revert, or
  reorder anything of its; when its processes ended, the evidence above was
  gathered with no other test process alive, and the database stamp that made
  concurrent pollution *sticky* was corrected.

## Deliverables

* `e9eefcc` — the payload gap core-w46 closed, recorded as closed
  (`PENDING_PAYLOAD_ALIGNMENT`, `cafaye.yml`, `CHANGELOG.md`).
* `71d5d2b` — a worktree finds core (`test/support/core_location.rb`,
  `test/contract/core_location_test.rb`, both readers rewired, `AGENTS.md`,
  `CHANGELOG.md`, and the three CI baseline numbers raised with the tests that
  moved them).
* `25d2da1` — the previous relay's report, `REPORT-brk-4r2.md`.
* `5ff48f2` — this packet's correction: the three stale numbers in `AGENTS.md`
  and `CHANGELOG.md`, measured, not guessed. **All four merged into master.**
* this report — the fifth commit, on the recreated branch.
