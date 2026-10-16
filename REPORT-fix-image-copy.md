# REPORT — the image build, and the vendored gem Docker flattened

Branch: `fix/image-copy`
Worktree: `/Users/kaka/Code/any/moon/wt/billing-build` (the only worktree used;
no second repository was touched)
Date: 2026-10-16

## What the packet is for

billing's image build failed, so `publish.yml` never produced an image, so the
packages were never published, so the substrate's billing `Application` pointed
at artifacts that do not exist and every box install was forced down the
credential path. The mechanism was already measured. This packet reproduces it,
fixes it, and proves the build.

## The mechanism, reproduced

`Dockerfile`'s `build` stage copied the vendored outbox gem with a glob:

```
COPY vendor/* ./vendor/
```

**Docker's directory-copy semantics**: `COPY <src-dir> <dest>/` copies the
**contents** of `src-dir` into `dest`, dropping `src-dir`'s own name. The glob
`vendor/*` matches two entries in the build context:

| entry | kind | what lands in `vendor/` |
|---|---|---|
| `.keep` | file | `.keep` (kept, name irrelevant) |
| `cafaye` | **directory** | its **contents** — `cafaye.gemspec`, `lib/`, `db/`, … — flattened directly into `vendor/` |

So `/rails/vendor/cafaye` never exists in the image, and the Gemfile's
`gem "cafaye", path: "vendor/cafaye"` dependency dies at `bundle install`.

Confirmed independently against the exact build context with the test image the
previous attempt left behind:

```
$ docker run --rm billing-copy-test:latest sh -c 'ls -la ./vendor/; ls ./vendor/cafaye/'
total 32
drwxr-xr-x  .  ..
-rw-r--r--  .keep
-rw-r--r--  cafaye.gemspec      <-- cafaye's CONTENTS, flattened here
drwxr-xr-x  db
drwxr-xr-x  lib
-rw-r--r--  CHANGELOG.md
...
ls: cannot access './vendor/cafaye/': No such file or directory
```

`.dockerignore` does not exclude `vendor` (checked: no `vendor` rule), and no
other file in the repository is implicated — there is exactly one `Dockerfile`.

## The failure, before the fix

`docker build --progress=plain --target build .` from this checkout:

```
#9  [build 2/5] COPY vendor/* ./vendor/
#13 [build 4/5] RUN bundle install && rm -rf ~/.bundle/ ...
#13 1.230 Bundler 4.0.3 is running, but your lockfile was generated with 4.0.18.
          Installing Bundler 4.0.18 and restarting using that version.
#13 73.21 Fetching bundler 4.0.18
#13 74.44 Installing bundler 4.0.18
#13 91.77 The path `/rails/vendor/cafaye` does not exist.
#13 ERROR: process "... bundle install ..." did not complete successfully: exit code: 13
ERROR: failed to build: failed to solve: ... exit code: 13
```

**Docker reported `exit code: 13`.** Every other build step succeeded; the
vendored-gem COPY is the whole cause.

## The fix

`Dockerfile`, the `build` stage:

```diff
-# Install application gems
-COPY vendor/* ./vendor/
+# Install application gems.
+#
+# The destination is spelled out, and it is not incidental. Docker copies the
+# CONTENTS of a source directory into the destination and drops the directory's
+# own name, so the glob that used to be here — `COPY vendor/* ./vendor/` —
+# matched `cafaye/` (a directory), flattened it into `vendor/`, and left
+# `/rails/vendor/cafaye` nonexistent. The Gemfile's `path: "vendor/cafaye"`
+# dependency then failed at `bundle install` with exit code 13. Naming the
+# destination keeps the directory, which is what the path pin needs. Do not
+# "simplify" this back into a glob: that is the bug this line fixes.
+COPY vendor/cafaye/ ./vendor/cafaye/
+COPY vendor/.keep ./vendor/.keep
 COPY Gemfile Gemfile.lock ./
```

The destination is named so the directory survives; `.keep` (an empty git
marker, inert in the image) is copied on its own line so dropping the glob loses
nothing. The comment records the trap in the file's own voice so a future
"simplification" back to `vendor/*` is read as a regression.

## The build, after the fix

`docker build --progress=plain --target build .` → **exit 0**:

```
#11 [build 2/6] COPY vendor/cafaye/ ./vendor/cafaye/
#14 [build 5/6] RUN bundle install && rm -rf ~/.bundle/ ...
#14 128.3 Bundle complete! 22 Gemfile dependencies, 125 gems now installed.
#14 DONE 129.3s
#16 exporting to image
#16 writing image sha256:c07d9cad... done
```

`docker build --progress=plain -t billing-fix-image-copy:verify .` (the full
image) → **exit 0**:

```
#16 [stage-2 1/3] RUN groupadd ... useradd rails ...
#17 [stage-2 2/3] COPY --from=build /usr/local/bundle /usr/local/bundle
#18 [stage-2 3/3] COPY --from=build /rails /rails
#19 exporting to image
#19 writing image sha256:ec71a99f... done
#19 naming to docker.io/library/billing-fix-image-copy:verify done
```

And the final image carries the gem and resolves the bundle:

```
$ docker run --rm --entrypoint sh billing-fix-image-copy:verify \
    -c 'ls /rails/vendor/cafaye/ && cd /rails && bundle check'
cafaye.gemspec  lib  db  CHANGELOG.md  DIGESTS  LICENSE.txt  README.md  VENDORED.md
The Gemfile's dependencies are satisfied
```

No network step was skipped; the full build fetched all 125 gems from
rubygems.org and compiled the native ones.

## The bundler version: NOT pinned, from the evidence

The image ships Bundler 4.0.3 while `Gemfile.lock` says `BUNDLED WITH 4.0.18`,
and Bundler self-installs 4.0.18 mid-build. Normalised and expected for a
`ruby:4.0.1-slim` base. The brief said to pin only if it fails on the runner; the
run shows it **succeeding** (fetched and installed at 73–75 s in the before log,
before the path error at 91 s). **Chosen: no pin.** The path was the sole cause
of the exit-13 failure; adding a pin would be ceremony the evidence does not
justify. If it ever does fail on a runner whose network cannot reach
rubygems.org for the self-install, the pin is `gem install bundler -v 4.0.18`
before `bundle install` — but that is a different failure with a different
remedy.

## Other COPY instructions: audited, none had the same shape

Every copy in the one `Dockerfile` was checked:

| line | instruction | glob matching a directory? |
|---|---|---|
| 48–49 | `COPY vendor/cafaye/ ./vendor/cafaye/`, `COPY vendor/.keep ./vendor/.keep` | no — explicit |
| 50 | `COPY Gemfile Gemfile.lock ./` | no — files |
| 56 | `COPY . .` | no — whole context, **keeps** every nested directory's name |
| 68–69 | `COPY --from=build ...` | no — from a stage, no globs |

Only the vendored-gem COPY had the shape (`<glob>` → trailing-slash dest). No
second fix was needed. There is no other `Dockerfile*` anywhere in the repo.

## The repo gate

`bin/prime` from this worktree → **exit 0**:

```
158 files inspected, no offenses detected          (rubocop)
1231 runs, 4026 assertions, 0 failures, 0 errors, 0 skips
== prime ok (rails Rails 8.1.4)
```

Run against the code commit `bccc12d` (the Dockerfile fix), which is the only
change to `app/`, configuration or tests in this packet. The commits after it add
documentation only, so the gate's result carries.

## Files touched

- `Dockerfile` — the fix (3-line change: the comment and two COPY lines).
- `CHANGELOG.md` — the entry under `[Unreleased] / Fixed`.
- `REPORT-fix-image-copy.md` — this report.

No `app/` code, no test, no `Gemfile`, no lockfile, no floor changed. The
vendored gem was **not** deleted and the Gemfile's `path: "vendor/cafaye"` pin was
**not** touched — the fix is the COPY, as briefed.

## One thing the manager should know: a pre-existing CI floor drift

`.github/workflows/ci.yml`'s `gate` job asserts the suite size **by equality**
(`BASELINE_RUNS: '1227'`, `BASELINE_ASSERTIONS: '4001'`), and this branch's suite
is **`1231 / 4026`** — the same number the branch tip `4ad01be` reports in its own
commit message (`1231 runs, 4026 assertions, 0 failures`). So the drift predates
this packet: `4ad01be` changed `test/requests/v1/subscriptions_test.rb` and
`test/contract/http_surface_contract_test.rb` and did not raise the floor, and the
last commit to touch `ci.yml` is `9e293a8`.

This packet adds **no tests** (it changes only the `Dockerfile`, the `CHANGELOG`
and this report), so it neither causes nor can honestly resolve that drift, and
the brief reserves floor changes to the repo's writer. **Left untouched, recorded
here.** It does not affect the packet's done-condition: `bin/prime` is green, the
image builds, and `publish.yml` triggers on a push to `master` independently of
`ci.yml`. If the manager wants `ci.yml`'s `gate` green before the push,
`BASELINE_RUNS`/`BASELINE_ASSERTIONS` go to `'1231'`/`'4026'` — but that is
`4ad01be`'s author's call, not this packet's.

## Handoff / what is left

Nothing for the next worker. The packet's done-condition is met: `docker build .`
succeeds from this checkout (exit 0), the repo gate is green (exit 0), and the
before/after build output is quoted above. The branch is `fix/image-copy` with
the commits made; the manager merges and pushes, and the push runs billing's
publish. The verification that the packages exist and are public is the
manager's, per the brief.
