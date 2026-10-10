# vendor/cafaye — a pinned copy of the fleet's shared gem

`cafaye` is the shared Ruby library every cafaye service is meant to depend on:
token verification against identity's published JWKS, and the transactional
outbox (`lib/cafaye/outbox` — the claim query, the envelope grammar, the publish
pass). billing's outbox publisher uses it, per the fleet rule that there is one
claim mechanism and not one per service.

## Why it is vendored here

Three facts, all verified on the day this copy was made:

1. The gem is **not published to rubygems.org** (`/api/v1/versions/cafaye.json`
   is a 404, and a search for the name returns an empty list).
2. **github.com/cafaye/cafaye-rb is not reachable** from this environment — a
   `git ls-remote` answers "Repository not found", so a `git:` dependency in the
   Gemfile cannot resolve here.
3. No service in the fleet consumes the gem yet (a grep of every fleet
   `Gemfile` finds no `gem "cafaye"`), so there is no established install
   pattern to copy.

A `path:` gem is the only way this service can depend on the shared mechanism
without a second copy of its logic. **This is a pinned copy, not a fork.**
Upstream commit `5056500ee977f13c4e04852f02ddb3e699d3a505` ("Merge
worker/cafaye-rb-ignore-01"), copied verbatim on 2026-10-10 — every file the
gem's own `cafaye.gemspec` ships, and nothing else.

## The obligation this creates

The copy will drift. `test/contract/vendored_gem_test.rb` compares it, file by
file, against the upstream checkout whenever that checkout is on disk — by
`CAFAYE_RB_PATH`, or at `../../cafaye/cafaye-rb` beside the standard fleet
layout. When the upstream checkout is absent the test **says so and skips**,
which is the same seam and the same limitation `test/contract/`'s core checks
already carry (`CORE_PATH`): CI cannot reach a private repository, so the drift
check is a developer-machine guarantee, not a CI one.

**The action item this records: publish `cafaye` (or make the private repo
reachable from CI), and replace this `path:` dependency with the released or
git dependency — in the fleet's packages, not in billing's.** Until then the
honest statement is that billing carries a pinned copy of a shared library, and
the test above is what keeps the copy from becoming a second thing.
