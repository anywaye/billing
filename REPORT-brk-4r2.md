# REPORT — BRK-4R2: the merged-tree red, and the gate that hid it

Branch `broker/billing-brk4`, worktree `/Users/kaka/Code/any/moon/wt/billing-brk4`.
Base `44ca9f6`. Two commits: `e9eefcc`, `71d5d2b`. **Not merged, not pushed.**

| | runs | assertions | failures | errors | skips |
|---|---|---|---|---|---|
| worktree, `44ca9f6`, before | 1174 | 3746 | 0 | 0 | **21** |
| main checkout, `44ca9f6`, before | 1174 | 3746 | **1** | 0 | 0 |
| worktree, after | **1175** | **3747** | 0 | 0 | **0** |
| main checkout, after | **1175** | **3747** | 0 | 0 | **0** |

`tenancy-check .` — 0 failures, 2 pre-existing warnings, unchanged.
`rubocop --parallel` — 153 files, no offenses.

---

## 1. Why 21 skipped on the worktree and 0 on the merged tree

**The mechanism: a path that resolves beside the main checkout and nowhere else.**

Both readers that touch core's files answered "where is core" as a hardcoded
sibling path — `Rails.root.join("..", "core")`. That is correct for the main
checkout, which sits at `<root>/billing` beside `<root>/core`. **A worktree lives
at `<root>/wt/billing-<name>` and has no `core` sibling**, so the path does not
exist, the read raises `Errno::ENOENT`, and `setup` in
`test/contract/outbox_envelope_contract_test.rb` skips the whole class. The
second reader, `test/integration/subscription_delivery_test.rb`, had the same
path spelled out inline.

The files:

| file | line | what |
|---|---|---|
| `test/contract/outbox_envelope_contract_test.rb` | `setup` → `skip unless schema` | **20 tests** |
| `test/integration/subscription_delivery_test.rb` | `test "both events courier needs have a row in core's catalog"` | **1 test** |

20 + 1 = **21**, which is the worktree's count exactly. The merged tree had core
on disk, so 0 skips — and the same code failing the one payload test.

**The two checkouts are the same commit (`44ca9f6`), same HEAD, both clean, same
`git worktree list` line 1.** So the red was never in the merge. It was in the
environment, and the worktree's green was a green that was made green — not by
anyone dishonestly, by a `default_core_path` that is a fact about a *main*
checkout held by a *worktree*.

**Why this is fleet-wide.** Every worker on this machine gates in a worktree; a
worktree has no `core` sibling; the contract tier skips wholesale and reports
0 failures. Every other service that reads core's schemas inherits the identical
trap by writing the identical line. The 21 skipped tests are the whole payload
contract, the envelope schema grammar, the id-pattern gaps and the schema-keyword
drift check — the entire tier core's fork of this repository was built to run.

### The fix

`test/support/core_location.rb` — one resolution, shared by both readers, so
they cannot drift:

1. `CORE_PATH` / `CORE_SPECS_PATH` — CI's seam, unchanged and first.
2. `../core` beside `Rails.root` — the main checkout, kept because the documents
   describe it.
3. **core beside the primary worktree**, found through
   `git worktree list --porcelain`. This is the new line and the whole point.

The **skip is not weakened and not removed.** A repository cloned on its own has
no core beside it and no `CORE_PATH`, and answering "no problem" for a schema
never read is exactly the outcome a contract test exists to prevent —
`checkout` still returns `nil` there and the callers still skip. What changed is
that a worktree is no longer *accidentally* in that state.

`test/contract/core_location_test.rb` (8 tests) asserts the resolution works
**with nothing configured, from this directory**, and pins two bugs the module
had on first write, both of which read as correct:

* **`primary_worktree` returned `Pathname.new("")`.** An empty Pathname expands
  to the process's working directory — a real directory, and in this repository
  one carrying a `cafaye.yml` — so a failed lookup validated as **"found"** and
  answered the worktree itself, where there are no `schemas/`. Same failure the
  module exists to prevent, one level down. Now returns `nil`, never `""`.
* **A reader handed `nil` does not skip.** `File.join(nil, "schemas/…")` raises
  `TypeError`, so "this tier could not check anything" became "this tier is
  broken" and the deliberate skip was **unreachable**. Caught by the mutation
  that removed the worktree candidate — the file erroring rather than skipping
  is not what anybody goes looking for. `path_for` now falls back to where we
  looked, which is either core or a path that does not exist; the latter is what
  a reader's `rescue Errno::ENOENT` needs to reach its own `skip(...)`.

### The mutation, and the number it printed

Dropping the `core_beside_primary_worktree` candidate (the worktree line) turned
`test/contract` from **28 runs green** into **3 failures, 21 errors, 0 skips**.
The guard is real and it fails loud rather than silent, which is the direction
the packet is about.

---

## 2. Is the `email` disappearing a defect or a fix? — **Neither. It did not disappear.**

The brief's reading was a *hypothesis*, stated as one ("the plausible reading is
that these payloads moved *toward* core's schema. Verify that"). It is wrong,
and the verification is worth writing down because the direction of the answer
changes the action.

**Probed by running the corpus and printing the envelopes:**

```
PROBE billing.payment.succeeded  keys=["amount","checkout_session_id","client_reference_id",
                                        "customer_id","email","kind","paid","payment_intent_id",
                                        "processor","processor_event_id"]
PROBE billing.payment.succeeded  email="billing@example.com"
PROBE billing.payment.succeeded  keys=["amount","attempt_count","customer_id","email",
                                        "invoice_id","kind","next_payment_attempt","paid",
                                        "payment_intent_id","processor","processor_event_id",
                                        "subscription_id"]
PROBE billing.payment.succeeded  email="billing@example.com"
PROBE billing.payment.failed     keys=["amount","attempt_count","customer_id","email",
                                        "invoice_id","kind","next_payment_attempt","paid",
                                        "payment_intent_id","processor","processor_event_id",
                                        "subscription_id"]
PROBE billing.payment.failed     email="billing@example.com"
```

`email` is on **every** money event, still resolved by
`StripeEvents.with_recipient`, still by one indexed lookup on
`customers.processor_customer_id`, still absent-never-null. **`app/` has no diff
in this packet.** Nothing was removed from the wire, and the PII direction of
travel is unchanged.

**What actually happened: core moved.** Commit `b8ae8fb` — *"billing's money
events: declare the recipient and the plan name"*, core-w46 — declares `email`
and `plan_name` **the way billing already sends them**:

* `email`: **OPTIONAL and NEVER NULL**, because `with_recipient`/`core_payload`
  merge it only when `customers.email` is present. `format: email`.
* `plan_name`: **REQUIRED and non-empty**, written unconditionally from a
  `null: false` column with a presence validation.

`billing.payment.succeeded` and `billing.payment.failed` are therefore the
**first money events to match core's schemas exactly** — including the D11
`oneOf` (invoice-backed vs Checkout-backed), which the two shapes the normalizers
produce satisfy. The three subscription types each lost `email` and `plan_name`
from their `unexpected` list and keep the D10 disagreement about cafaye ids
versus core's processor-normalised shape. `entitlements` is untouched on the two
plan events.

So the recorded gap shrank from the **core** side, and the test's own message —
"fix them, or record the new gap" — is answered by the second option, which is
what the brief instructed: **record the smaller gap, restore nothing.**

---

## 3. `PENDING_PAYLOAD_ALIGNMENT` and `cafaye.yml`

Updated together, `test/contract/outbox_envelope_contract_test.rb:75` and the
same-cafaye.yml sections. The table went from **7 entries to 5**:

| event type | missing | unexpected |
|---|---|---|
| `billing.plan.created` | — | `entitlements` |
| `billing.plan.updated` | — | `entitlements` |
| `billing.subscription.started` | `customer_id kind processor processor_event_id` | `account_id currency plan_id started_at` |
| `billing.subscription.updated` | `customer_id kind` | `account_id currency plan_id processor_subscription_id` |
| `billing.subscription.canceled` | `customer_id kind` | `account_id currency plan_id processor_subscription_id` |
| ~~`billing.payment.succeeded`~~ | — | **entry deleted — matches core exactly** |
| ~~`billing.payment.failed`~~ | — | **entry deleted — matches core exactly** |

Two entries deleted, not emptied. `email` and `plan_name` struck from the three
subscription entries, not the whole entry. Both files now carry the reason
core-w46 closed them and the statement that the PII position is unchanged — so
an entry that starts matching does not sit here describing a disagreement that
no longer exists. The table is still asserted **as a set in both directions**,
which is precisely why a gap closing from the core side shows up as a failure
that names it.

The two DECISION NEEDED blocks in `cafaye.yml` were rewritten rather than
deleted: the recipient-fact one now records that core discharged the action item,
and the plan-`entitlements` one is unchanged.

---

## What I deliberately left alone

* **`email` restored nowhere, no payload edited, `app/` untouched** (zero diff
  against `44ca9f6` under `app/`). A consumer needing the field on a money event
  would be a schema change in core, in its own packet.
* **core's schemas not edited.** The fix is on core's side already; editing from
  a read-only service worktree is out of bounds and would have hidden the real
  story.
* **The contract test is not deleted, not skipped, not weakened.** No `skip(` was
  added anywhere; no assertion relaxed. The only `skip` lines in the diff are the
  two pre-existing ones, unchanged in behaviour.
* **`PENDING_PAYLOAD_ALIGNMENT` not emptied.** 5 entries remain and each one is
  still checked.
* **`test/contract/tenant_isolation_matrix_test.rb`, `http_surface_contract_test.rb`,
  the vendored-gem digest guard, the money-coverage gate** — untouched.
* **The 2 pre-existing `tenancy-check` warnings** (`enumeration-partial`,
  `scope-key-unused`) — pre-existing on `44ca9f6`, unchanged, and not this
  packet's to settle. `0 failures` is the gate the brief set.

## One pre-existing red found and repaired

The `/v1` authorization tier's recorded number in `.github/workflows/ci.yml` was
**66/180, and the directory has measured 68/184 since `504de05`** — stale by 2
runs for at least one packet, making `gate` red for a reason unrelated to any
packet's own work. Raised here to 68/184 with the measurement and the reason
recorded, because a gate that is red for an unrelated reason is a gate whose red
means nothing — the same failure this packet is about, one tier over. `44ca9f6`'s
contract-tier figure of 52/420 was stale the same way (7 runs; the four
pre-existing files measure 59/459); corrected to 68/479.

## Deliverables

* `e9eefcc` — the payload gap core-w46 closed, recorded as closed.
  `PENDING_PAYLOAD_ALIGNMENT`, `cafaye.yml`, `CHANGELOG.md`.
* `71d5d2b` — a worktree finds core. `test/support/core_location.rb`,
  `test/contract/core_location_test.rb`, both readers rewired,
  `AGENTS.md` (a new section plus the layout), `CHANGELOG.md`, and the three
  CI baseline numbers raised in the same commit as the tests that moved them.

`BASELINE_RUNS`/`BASELINE_ASSERTIONS` are now **1175 / 3747, in CI and locally
the same number**, which is the first time that has been true: the 361
assertions the core-contract tier contributes were absent locally because a
worktree skipped them. A local run reporting a different count from CI's is now
a run missing the tier.
