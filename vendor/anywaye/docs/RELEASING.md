# Releasing anywaye

A tag is the release. Pushing `vX.Y.Z` runs `.github/workflows/release.yml`,
which gates, builds the gem, creates the GitHub Release, and pushes to
rubygems.org when it can. There is no other release path.

The shape is the fleet uniform — `anywaye-ts` and `anywaye-py` follow the same
file. What is written here is what this repository actually built.

## Cutting a release

1. Move the `Unreleased` section of `CHANGELOG.md` to `X.Y.Z` and date it, built
   from the repo's actual history and never invented. Leave an empty
   `## [Unreleased]` at the top for the permanent discipline.
2. Set `Anywaye::VERSION` in `lib/anywaye/version.rb`. It is the single version
   source: `anywaye.gemspec` `require_relative`s it, so the manifest, the built
   gem and the changelog header all move with this one constant. There is no
   second file to keep in step.
3. Commit, merge, then cut and push the tag:

   ```
   git tag -a vX.Y.Z -m "anywaye X.Y.Z"
   git push origin vX.Y.Z
   ```

   The tag and the version constant must agree — the workflow checks `v0.1.0`
   against `Anywaye::VERSION` and stops the release if they differ. Never create
   the tag before the bump commit is merged; never move a tag after pushing it.

`0.1.0` is already set and is the intended first release, so the first run needs
no bump commit — only the tag.

## What the workflow does

- Checks out this repository at full depth, plus `anywaye/core`.
- Installs Ruby **4.0.1** — the pin in `mise.toml` and `.ruby-version` — never a
  floating version. Compiles the `pg` extension against that interpreter.
- Points `CORE_PATH` at the `core` checkout before gating, because
  `test/contract/core_specs_test.rb` reads core's own event-envelope schema
  rather than a copy. Without core the gate is red, and a release must not ship
  one.
- Runs `./bin/prime`: `bundle install`, `rake db:prepare` against a real
  PostgreSQL service, `rubocop`, `bundler-audit`, and the full minitest suite. A
  release that skips the gate is not a release.
- Runs `gem build anywaye.gemspec`. The artifact is `anywaye-X.Y.Z.gem`.
- Reads the release notes out of `CHANGELOG.md` — the `## [X.Y.Z]` section,
  nothing else. The notes ARE the changelog section, not a generated commit
  dump. A missing section stops the release.
- Creates the GitHub Release titled `vX.Y.Z` with the `.gem` attached, using the
  runner's `gh` and the job's `contents: write` permission.
- Pushes to rubygems.org **only when the credential exists** (below).

## Publishing: the one credential

The account currently has **no rubygems credential configured**, so releases
ship as GitHub Releases with the `.gem` attached, and the publish step logs that
it skipped. That is the designed behaviour, not a failure.

To enable publishing, add a rubygems.org API key with **push** scope for the
`anywaye` gem as the repository secret **`RUBYGEMS_API_KEY`** (repo Settings →
Secrets and variables → Actions). Nothing else changes: the next tag run pushes
with no workflow edit.

The push form is `gem push "$GEM_FILE"` reading the key from the
`GEM_HOST_API_KEY` environment variable the step sets from that secret. That is
deliberate: it keeps the credential in the environment rather than writing it to
`~/.gem/credentials`, which is what `--key` would require.

One thing to know when the key is created: `anywaye.gemspec` sets
`rubygems_mfa_required`, so the rubygems.org account must have MFA enabled, and
the API key must be created with the `push_rubygem` scope under an account that
allows API pushes. If the account is set to require an OTP for every API push,
`gem push` will need `--otp` and the workflow will need the code passed in —
set the account to allow a scoped push key instead, which is the arrangement
this step assumes.

A second secret is needed only if `anywaye/core` is private: a fine-grained
read-only token (Contents: read, limited to `anywaye/core`) stored as
**`SIBLING_REPOS_READ_TOKEN`**, so the `core` checkout above can be read. If
`core` is public, the run's default token suffices and this secret can stay
unset.

## Semver here

Pre-1.0: `0.x.y` releases may break the API on a minor bump, and every break is
listed in the changelog with the commit that caused it. `0.1.0` (2026-10-15) is
the first release; `lib/anywaye/version.rb` read `0.1.0` from the start and no tag
had ever been cut.
