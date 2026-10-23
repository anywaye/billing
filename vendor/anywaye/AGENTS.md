# AGENTS.md — anywaye-rb

Read this before changing anything. The house rules — SSH remotes for the repositories anywaye owns, and tests first: write the test, watch it fail, then implement —
apply on top of it, and `core/AGENTS.md` and `billing/AGENTS.md` are the
references for tone.

## What this repository is

`anywaye`, the gem every anywaye **Ruby** service depends on. It exists so that no
service hand-rolls the two things where a private shortcut is a security
incident:

1. **Token verification** — RS256 bearer tokens checked against identity's
   published JWKS.
2. **The transactional outbox** — core's event envelope written into a Postgres
   outbox inside the caller's own transaction.

`courier` is Elixir and does not use it. `guard` is TypeScript and verifies
tokens with its own `src/middleware/jwt.ts`; this packet does **not** migrate it
and must not. `billing` is the first Ruby consumer and has no verifier at all
yet — its `AGENTS.md` records `/v1` as unauthenticated for exactly that reason.

## Layout

```
lib/anywaye.rb                  the module: config, logger, and the two accessors
lib/anywaye/configuration.rb    every setting, in one object
lib/anywaye/errors.rb           the error hierarchy, and the rule about messages
lib/anywaye/token.rb            a token that will not print itself
lib/anywaye/principal.rb        the verified caller: frozen, named readers only
lib/anywaye/token_verifier.rb   the trust chain, in order
lib/anywaye/jwks/               key_set, cache, fetcher, transport
lib/anywaye/outbox.rb           the namespace and the reference DDL
lib/anywaye/outbox/envelope.rb  core's envelope, validated on construction
lib/anywaye/outbox/writer.rb    publish!, and the refusal to write outside a tx
lib/anywaye/outbox/publisher.rb claim, deliver, ack, mark
lib/anywaye/outbox/pg_connection.rb             the statements, over `pg`
lib/anywaye/outbox/active_record_connection.rb  the same statements, over AR
lib/anywaye/railtie.rb          install into a host app; inert until configured
lib/anywaye/generators/         `rails generate anywaye:outbox`
db/outbox_events.sql           core's column list, the file a service copies
test/contract/                 the checks that read core's own files
test/canary_test.rb            the security assertion, end to end
test/support/                  a real database, a real JWKS server, real RSA keys
```

## Commands

Run these; do not improvise equivalents.

| Task | Command |
|------|---------|
| Prime the worktree | `bin/prime` (or `mise run prime`) |
| Dependencies and database only | `bin/prime --fast` |
| Run the suite | `bundle exec rake test` |
| Run one file | `bundle exec ruby -Ilib -Itest test/outbox_writer_test.rb` |
| Lint | `bundle exec rubocop --parallel` |
| Audit the bundle | `bundle exec bundler-audit check --update` |
| Reset the test schema | `bundle exec rake db:reset` |

`bin/prime` is the gate: bundle, database, rubocop, bundler-audit, minitest. It
creates its own test database from the reference DDL, so a clean checkout primes
with no manual step. Point it elsewhere with `ANYWAYE_TEST_DATABASE_URL`.

**The gate is declared in `gate.yml`, not discovered.** It is written against
`core/schemas/gate.schema.json`, checked by core's `harness/gate_check.py`, and
it says the two things a `mise` task structurally cannot: what the gate needs
from the machine (`selfContained: false`, plus five requirements), and what its
own output must contain before "passed" means anything (five `proof` entries).

Two consequences for anyone changing this repository:

- **Adding a test means raising `gate.proof[].suite.minimum`**, or at least
  deciding you did not need to. The floor is a decrease-detector: it is 220
  against a suite that reports 228. Nothing enforces the upward direction the way
  core's `test_the_gate_floor_is_not_below_the_suite_core_claims` does — that
  ratchet is **owed** and named in REPORT-core-10.
- **The gate needs a checkout of `core` beside this one.** `test/contract/` reads
  core's schema and doc directly; two of those tests need the real files and go
  red without them. `CORE_PATH` overrides the location. CI clones core before
  `./bin/prime` in every matrix job, and `anywaye/core` is public so the clone
  needs no credential; core-10 could not make that change (it would have meant
  modifying the gate's own behaviour) and so it stayed "reported, not fixed" in
  REPORT-core-10 until fix/ci-green did it. See REPORT-ci-green.

To check the declaration, and to check that it can still fail:

```
bash test/gate_declaration_self_test.sh            # ~90s: 19 breakages
bash test/gate_declaration_self_test.sh --static   # ~5s: the static half
```

## Rules

**Tests first, and shown failing.** A test that has never failed has never
proven it tests anything. When a test fails, decide whether the test or the code
is wrong *before* touching either, and if the failure is the wrong failure, fix
the test first.

**No sleeps, ever.** Every clock in this library is injected and every clock in
the suite is a constant. A test that needs to wait is a design that is wrong:
the JWKS cache takes a callable, the claim query takes `now` as a parameter, and
`bin/prime` has to pass in CI at 3am. Adding a `sleep` to make a backoff test
green is the single most likely way to break this repository.

**No skipped tests, no loosened assertions, no raised retry counts.** There is
one exception, and it is deliberate: `test/contract/core_specs_test.rb` falls
back to a pinned copy of core's constraints when `core` is not a sibling, and
says so in a test rather than in a comment. A skip tells the next reader nothing
about whether the contract is being enforced.

**The coverage floor only goes up.** 60% at bootstrap, 90% with the verifier,
95% with the outbox. Lowering it, or adding an inline `exclude` to reach green,
is not a way to make a build pass.

**Nothing this library logs may have come from a token, a claim, a key, a key
set, or a URL with a query string.** Not at debug level, not in an exception
message, not in a backtrace. `test/canary_test.rb` is what holds that line, and
it asserts the canary is *present* in the input before asserting it is absent
from the output — a test that only asserted absence could pass on an empty log.
If you add a log line, add the canary assertion with it.

**A truncation rule is not a redaction rule.** The first eight characters of a
bearer token are eight characters of a bearer token. The rule is *none of it*,
and `Anywaye::Token` enforces it by not being a `String`.

**The token chooses nothing.** The algorithm allowlist is a constant, checked
from the protected header before any key is fetched. Never make it a
per-request option, and never let a token widen it. There is a test per
refused algorithm asserting the outbound request count is zero; keep those.

**A refresh on the hot path needs a reason and a budget.** A `kid` is
attacker-chosen, so "refresh on unknown `kid`" without a rate limit is an
amplifier aimed at identity, not a fallback. `Jwks::Cache` bounds it three ways
and `test/token_verifier_test.rb` asserts the counts. Do not add a path that
fetches a key without going through the cache.

**`JwksUnavailable` is not `TokenInvalid`.** identity being unreachable is not
the caller's credential failing. A 401 there sends an operator to rotate a token
that was fine, which is how a dependency outage becomes a fleet-wide credential
incident. There is a subclass per refusal so a caller can branch without
matching on a message.

**The envelope is core's, and the patterns are copied.** Every regex in
`Outbox::Envelope` comes from `core/schemas/event-envelope.schema.json`, and
`test/contract/core_specs_test.rb` checks the copy. Anchored with `\A`/`\z`
rather than core's `^`/`$`, which is strictly narrower and the safe direction.
**`db/outbox_events.sql` is core's column list** and the contract test compares
it against core's doc. Adding a column is a contract change and needs a manager
decision, not a commit.

**The insert is always inside the caller's transaction.** `publish!` raises
`NotInTransaction` rather than warning. The writer never opens or commits a
transaction of its own and has no `transaction` method, so the pairing cannot be
broken by reaching for the wrong one. Never add a `deliver`, a `flush` or an
`enqueue` to the writer: publishing after commit from an in-memory queue is the
same bug with a nicer syntax.

**Never give the outbox a second connection.** The AR adapter leases the
connection Active Record is already using. A `PG::Connection` built from the
same database config is a different session, is not enlisted, and would commit
the event on its own — the exact failure the table exists to prevent, wearing
the costume of a correct implementation.

**Ids are minted per emission and never reused,** including on a retry of the
same logical event, and the publisher republishes the row's own id. A duplicate
id is a loud `UniqueViolation`, not `on conflict do nothing`: a conflict is a
uuid collision or a caller passing an id it does not own, and both are bugs.

**The outbox writer has no broker.** No NATS gem, no Redis gem, no queue
dependency. The transport is a decision that belongs to the service, and a
shared library that picked would be a shared library that had picked for
`courier` and `identity`, which disagree. A service supplies one callable.

**The railtie is inert until configured, and loud when half-configured.** Nothing
set: the gem does nothing at all. Some of the three required settings: a boot
failure naming what is missing, because an app that set an issuer and no
audience believes it verifies tokens and it does not. All three set: validated
at boot, so a typo is a boot failure rather than a 503 on every request.

**A dependency earns its place by owning a contract you would otherwise
hand-roll.** There are exactly two: `jwt` (JOSE, and the algorithm allowlist) and
`pg` (the Postgres wire protocol). Anything else needs a line in the `Gemfile`
comment saying what contract it owns, in the style of the `stripe` comment in
`../billing/Gemfile`. There is no JSON Schema validator, no HTTP client gem, no
job queue, and no logging framework, and adding any of them is a decision this
repository does not get to make on its own.

**Clocks are injected, never read.** Production code calls the injected clock;
nothing in `lib/` calls `Time.now` except the default lambda. This is why `exp`,
`nbf` and `iat` are checked in `TokenVerifier` rather than by the `jwt` gem,
which calls `Time.now` internally and takes no clock.

**Migrations do not read model constants.** The generated migration is a plain
`ActiveRecord::Migration` and its comments explain the constraints; the
generator is the only thing that writes into a host app, and it writes exactly
one migration however many times it is run.

**Never touch a repository outside this worktree.** `core`, `identity`,
`billing`, `guard` and `muse` are read-only references. Record what core still
owes in `anywaye.yml` and in the worker report, not by writing into core.

## Contracts this repository owes core

- **The claim names.** `anywaye.yml` carries the full `DECISION NEEDED`. Both
  scope claim names are read and unioned, the account claim is opt-in, and
  RS256-only matches `guard`. One constant each to flip.
- **The outbox is a shared library that `core/docs/event-outbox.md` says will
  not exist.** The section's stated reason is that a shared library would own
  six ORMs' transaction semantics; this one speaks SQL over one connection and
  owns none. The document still says otherwise and core is read-only from here.
- **`core/schemas/events/`** ships two payload schemas. `Writer` takes a
  `payload_validators` callable per type rather than carrying a validator, so a
  service wires its own and nothing is validated until it is.

## Before you open a PR

- [ ] `bin/prime` is green from a clean worktree
- [ ] New behaviour has a test that fails without it
- [ ] Nothing logged can have come from a token, a claim, a key or a key set
- [ ] Any new log line has a canary assertion with it
- [ ] The coverage floor went up, or stayed
- [ ] `AGENTS.md` still describes the repository as it now is
- [ ] `CHANGELOG.md` has an entry
- [ ] `anywaye.yml` still satisfies core's manifest schema, and any new open
      question is in it rather than only in a commit message

## Secrets
- No `.env` files with values. Use `cafe secret set/get/list` (dev) and `cafe dev` (injects). See `docs/secrets.md`.

## Packet identifiers

`REPORT-x`, `HANDOFF-x` and `MEASUREMENTS-x` name **work packets, not
files**. The written reports were removed on 2026-10-20: duplicated across
repositories, owned by nobody, rotting faster than they were read. What
survives of a packet is its entry in `CHANGELOG.md` and, where a decision was
made, in `DECISIONS.md`. A citation to a packet id points at that entry.
