# REPORT — billing-receipts-01: the charge and the receipt

**Branch:** `worker/billing-w14-receipts`
**Gate:** `bin/prime` green — `1134 runs, 3264 assertions, 0 failures, 0 errors, 0 skips`
**Date:** 2026-10-07

## What this packet is

A user who pays could not see what they paid for. Jumpstart Pro has a `Charge`
model, a `Billing::ChargesController`, and a `/billing/charges/:id/invoice`
route; cafaye's billing had none of that. This packet adds the record and the
read path:

- **`Charge`** — billing's own record of a payment, distinct from `Pay::Charge`
  (the processor's record). `app/models/charge.rb`.
- **The write path** — `Webhooks::Charges::Recorder`, hooked into
  `Webhooks::StripeEvents.payment_emission`, inside the ingestion transaction.
- **The read path** — `GET /v1/charges/{id}`, rendering a self-contained HTML
  receipt, scoped by the token's account.
- **The migration** — `db/migrate/20261006040000_create_charges.rb`.

## The recovery commits, judged

Six prior attempts died on free-model endpoint errors, never on the packet.
Their accumulated work reached this branch as three unverified recovery
commits. This attempt judged each against the brief:

### `662436e` — the attempt-6 tree (kept, with one fix from `ad50103`)

The `Charge` model, migration, controller, recorder, the `payment_emission`
hook, the route and the schema. **Judged correct and kept.** The model's
validations, the `for_account` scope, the recorder's screening order
(`paid?` → `amount.positive?` → customer → account → write), the controller's
404-not-403 tenancy answer, and the route's placement all match the brief and
the repository's rules.

### `ad50103` — the recorder's two undefined methods, and a PostgreSQL-invalid constraint (kept)

Two real defects in the attempt-6 tree, both fixed here:

1. The recorder called `processor_charge_id` and `resolved_subscription_id`,
   neither of which was defined. Whenever a payment resolved to a cafaye
   customer, `Charge.create!` raised `NoMethodError` inside the ingestion
   transaction, which the ingestion layer parks as a failed delivery — the
   `billing.payment.succeeded` event was never emitted. `processor_charge_id`
   now reads the charge object's id off the raw payload, falling back to the
   payment intent for a one-time Checkout session (which carries no charge
   object; the intent is the processor's own unique id for that payment).
2. The currency `CHECK` constraint used `\A…\z`, PCRE escapes PostgreSQL's
   POSIX regex rejects: the constraint parsed at creation and raised
   `invalid regular expression` on the first insert. `^[A-Z]{3}$` is the
   POSIX pair, and the anchors are load-bearing because `~` is a substring
   match.

### `88b42fa` — the attempt-12 tree (kept)

The openapi document (`GET /v1/charges/{id}`, `operationId: getCharge`,
`info.version` 2.0.0 → 2.1.0) and the contract-test edits: the tenant
isolation matrix (11 of 15 scoped), the account-entry-point matrix (44 data
accesses in 41 methods), the principal lock (15 client operations), the
http-surface contract (2.1.0, `getCharge` pinned), and the money-path
inventory (the receipt controller is a *mixed* money file — it formats a
charge's amount but never decides one). **Judged correct and kept.**

## What this attempt added

The recovery commits were the code; the packet's remaining half was the
docs, the floors and two guards:

- **README** — the surface-table row for `GET /v1/charges/:id`, and a
  paragraph in *Webhooks in* saying a payment event also writes a charge,
  when money moved.
- **The three specs** — `test/models/charge_test.rb` (15 runs),
  `test/services/webhooks/charges/recorder_test.rb` (11 runs),
  `test/requests/v1/charges_test.rb` (7 runs). 33 runs, 96 assertions,
  measured by running each file on its own.
- **The floors** — `gate.yml` lint 127 → 142 and suite 1078 → 1134;
  `ci.yml` `BASELINE_RUNS`/`BASELINE_ASSERTIONS` 1095/3157 → 1134/3264,
  with the per-file deltas itemised in the workflow's own header.
- **Two guards the recovery tree needed.** The receipt renders `html_safe`
  only *after* the values are escaped — `render html:` escapes its argument
  by default, so an unmarked document would arrive as `&lt;!DOCTYPE html&gt;`,
  a receipt that renders as source code. And the `for_account` scan in
  `cross_account_web_test.rb` drops comment lines before matching, so a file
  explaining that it does *not* call `Customer.for_account` is not an
  account-scoped entry point.

## The gate

`bin/prime`, verbatim:

```

== ruby 4.0.1 (pinned by .ruby-version)

== bundle install
Bundle complete! 19 Gemfile dependencies, 117 gems now installed.
Use `bundle info [gemname]` to see where a bundled gem is installed.

== rails db:prepare

== rubocop
Inspecting 142 files
..............................................................................................................................................

142 files inspected, no offenses detected

== rails test
Running 1134 tests in parallel using 8 processes
Run options: --seed 7286

# Running:

..............................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................

Finished in 10.561082s, 107.3754 runs/s, 309.0592 assertions/s.
1134 runs, 3264 assertions, 0 failures, 0 errors, 0 skips

== prime ok (rails Rails 8.1.4)
EXIT: 0
```

The lint floor (142) and the suite floor (1134) are both met exactly, and the
`prime ok` proof line is present.

## One environmental finding: the parallel suite segfaults in libpq's GSSAPI negotiation

The first two gate attempts on this branch died the same way: the suite
printed `Running 1134 tests in parallel using 8 processes`, then a worker
segfaulted, and the parent hung waiting for a worker that could no longer
deregister. The crash reports (going back to 2026-10-06 22:16, before this
session) all have the same signature:

```
ruby  rb_f_fork              ← the parallel worker is forked
ruby  rb_protect
...
libpq-ruby-pg.1.dylib  PQconnectStart
libpq-ruby-pg.1.dylib  pqConnectDBStart
libpq-ruby-pg.1.dylib  init_allowed_encryption_methods
libpq-ruby-pg.1.dylib  select_next_encryption_method
libpq-ruby-pg.1.dylib  pg_GSS_have_cred_cache
libpq-ruby-pg.1.dylib  gss_acquire_cred
libpq-ruby-pg.1.dylib  krb5_gss_acquire_cred_from
libpq-ruby-pg.1.dylib  acquire_cred_from
libpq-ruby-pg.1.dylib  acquire_cred_context
libpq-ruby-pg.1.dylib  acquire_init_cred
libpq-ruby-pg.1.dylib  krb5_cccol_have_content
libpq-ruby-pg.1.dylib  krb5_cccol_cursor_next
libpq-ruby-pg.1.dylib  api_macos_ptcursor_next
libpq-ruby-pg.1.dylib  get_primary_name   ← EXC_BAD_ACCESS
```

The parent process holds a live pg connection; the forked child inherits the
parent's Kerberos framework state; when the child calls `PQconnectStart`,
libpq negotiates GSSAPI encryption and macOS's Kerberos framework crashes in
`get_primary_name`. It is a fork-after-connect bug in the macOS Kerberos
library, not a defect in this repository's code and not anything the charges
packet introduced — the crash reports predate the packet's first commit.

**The workaround is one query parameter:** `gssencmode=disable` on the test
`DATABASE_URL`. It tells libpq to skip GSSAPI negotiation entirely, avoiding
the crashing code path. With it, the suite passes 8 workers in 10.5s. The
parameter is a connection-string fact about this machine's Kerberos state,
not a change to the repository; CI does not need it.

## PDF feasibility

**Not feasible within the existing Gemfile without adding a dependency.** The
Gemfile has no PDF library, and Rails has no built-in PDF rendering. The
options, in order of fit:

- **`prawn`** — pure Ruby, no native extensions, no external binary. The
  lowest-risk addition and the only one with no system dependency. A receipt
  is four lines of fact and a stylesheet; Prawn's API is more than enough.
- **`wicked_pdf`** — shells out to the `wkhtmltopdf` binary, which is not on
  this machine and would need installing and keeping in sync.
- **`grover`** — shells out to headless Chrome, same binary problem, heavier.

Per the repository's rules, a new gem is a decision recorded in the PR body
and the `Gemfile`'s own comment, not a convenience. **PDF is a follow-up
packet**: the HTML receipt is the right shape for this one (it prints, it
saves, it emails, and it needs no asset pipeline), and the `Charge` model
already carries everything a PDF would render.
