# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0: a minor bump may break the API. Every break is listed here with the
commit that caused it and the one line that changes to opt back in.

## [Unreleased]

### Added

- **`gate.yml`** — this repository declares its gate rather than leaving it to be
  discovered by getting it wrong: the command, the entrypoint, the mise task it
  must resolve to, five proofs of what "the gate ran" looks like in its output,
  and the five things the gate needs that are not in this repository (an
  interpreter, two network hosts, a PostgreSQL server, and a checkout of core).
  Written against `core/schemas/gate.schema.json` and checked by core's
  `harness/gate_check.py`. `selfContained` is `false`, and the reason is not a
  formality: with core absent the suite is red — see REPORT-core-10.md.
- **`test/gate_declaration_self_test.sh`** — twenty-two cases proving the
  declaration is load-bearing: one control, two warning cases, and nineteen
  deliberate breakages, eight of which break `bin/prime` or the suite itself and
  can only be caught by running the gate. Not wired into `bin/prime`, because a
  self-test inside every gate invocation would be a second gate that can disagree
  with the first.

### Changed

- **`.github/workflows/ci.yml`** — the gate step is `run: ./bin/prime` on one
  line again, the spelling the other eight services use. It was a `run: |` block
  scalar, with a comment above it saying why: core's gate checker could not see a
  one-line `run:` at all, so the step had to be written in a shape the checker
  could read (D12, fixed in core `63fd319`). The command was byte-identical
  either way, so this is not a behaviour change — it retires a permanent
  accommodation for a defect that no longer exists. Verified in both directions
  against core's fixed checker: the one-liner is `OK … 0 failure(s)`, and
  deleting the step from the same tree is `FAIL gate.ci-disagrees`, exit 1.
  REPORT-core-10.md carries the history and is corrected rather than left
  asserting a limitation that is gone.

## [0.1.0] — 2026-09-30

The first real packet in a repository that was an empty scaffold. Three
deliverables, in the order they landed.

### Added

- **`Cafaye::TokenVerifier`** — RS256 verification against identity's JWKS at
  `{issuer}/.well-known/jwks.json`. The algorithm is an allowlist and `none`,
  HS256 and every symmetric algorithm are refused from the protected header
  before any key is fetched, so an attacker cannot aim an outbound request at
  identity by choosing an algorithm. `iss`, `aud`, `exp`, `iat`, `nbf` and `sub`
  are checked; `jti` is required, per core's
  `docs/openapi-conventions.md`.
- **A bounded key-set cache** — one fetch per TTL, **one** forced refresh per
  minimum interval for an unknown `kid`, and a negative cache for unknown `kid`s
  that is itself size-capped. A caller who sends a request per bad token buys a
  refusal per bad token, not an outbound request. A failed fetch keeps the
  previous key set, because discarding it turns a dependency blip into a total
  authentication outage.
- **`Cafaye::Principal`** — the verified caller, frozen all the way down,
  including the scope strings. It has no `[]`, no `to_h` of the claims hash, and
  no accessor that can reach a claim this library did not name.
- **`Cafaye::Token`** — a string that will not print itself. Not a `String` and
  no `to_str`, because a subclass of `str` leaks through every C-level string
  operation and `%s` is the one that actually happens.
- **The canary test** — a unique string in a claim, asserted *present* in the
  input first and then asserted absent from every log line at every level, from
  every exception message, and from every backtrace. The RSA modulus and
  exponent are asserted absent separately, and a truncation rule is called out
  for what it is.
- **`Cafaye::Outbox::Envelope`** — core's envelope, validated on construction,
  with every pattern copied from core's schema and the copies checked against
  core's own file by `test/contract/core_specs_test.rb`.
- **`Cafaye::Outbox::Writer`** — `publish!` writes core's event envelope into
  `outbox_events` on the caller's connection and **refuses to write outside a
  transaction**. The envelope `id` is a UUID minted per emission and reused on
  every retry of that row, which is what makes at-least-once safe for a consumer
  deduping on it. A duplicated id is a loud `UniqueViolation`, not
  `on conflict do nothing`.
- **`Cafaye::Outbox::Publisher`** — claims a batch with `for update skip locked`,
  delivers in `created_at` order, and marks `published_at` only on the
  transport's acknowledgement. Failures increment `attempts` and back off
  exponentially from `created_at`; a pass that cannot claim its batch raises
  rather than spinning.
- **`Cafaye::Outbox::PgConnection` and `Cafaye::Outbox::ActiveRecordConnection`**
  — one statement, two drivers. The Active Record adapter leases the connection
  the caller's transaction is already on, because a second connection would
  commit the event on its own.
- **`db/outbox_events.sql`** — core's column list, plus the CHECK constraints
  from core's envelope schema, as the one file both this gem's suite and a
  service's own migration are built from.
- **`Cafaye::Railtie` and `Cafaye::Configuration`** — installs both halves into
  a host app and generates the outbox migration. Inert until configured: an app
  with the gem and no config block boots exactly as it would without it. Set some
  of the three required settings and it refuses to boot, naming what is missing,
  because an app that set an issuer and no audience believes it verifies tokens.
- **`test/readme_example_test.rb`** — every runnable block in `README.md`,
  executed against a real PostgreSQL and a real JWKS endpoint.
- **`cafaye.yml`**, `AGENTS.md`, `.rubocop.yml`, `mise.toml`, `bin/prime` and
  `.github/workflows/ci.yml`.

### Notes for a reader

- `exp`, `nbf` and `iat` are checked by this library rather than by the `jwt`
  gem, because that gem calls `Time.now` directly and takes no clock. The
  injected clock is the only clock in the process, which is what makes every
  time-based assertion deterministic on any day.
- Delivery is **at-least-once** and that is a contract with consumers, not a
  limitation to paper over. The publisher's half of it is that a redelivery
  carries the same envelope `id`.

### Open decisions

Recorded in full in `cafaye.yml` and in the worker report. The two that change
the API's shape:

1. **The claim contract is ambiguous.** core says `scopes` (an array, required)
   and `account_id`; `guard` reads `scope` (a space-separated string,
   optional) and no tenant claim at all; `identity` mints no tokens yet, so
   there is nothing to read the names off. This gem reads both scope claim
   names, makes the account claim opt-in, and matches guard on RS256-only. One
   constant each to flip: `Cafaye::TokenVerifier::DEFAULT_SCOPE_CLAIMS`,
   `Cafaye.config.account_claim`, `ALGORITHMS`.
2. **`core/docs/event-outbox.md` says there is no shared outbox library.** This
   repository is one. Reconcilable — this gem speaks SQL over one connection
   and owns no ORM — but core is read-only from here, so the contradiction
   stands in the document.

[Unreleased]: https://github.com/cafaye/cafaye-rb/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cafaye/cafaye-rb/releases/tag/v0.1.0
