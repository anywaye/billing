#!/usr/bin/env bash
#
# test/gate_declaration_self_test.sh — proof that this repository's gate
# declaration is able to fail.
#
#   bash test/gate_declaration_self_test.sh          # everything, ~90 seconds
#   bash test/gate_declaration_self_test.sh --static # the static half, ~5 seconds
#
# WHAT THIS IS FOR
#
# A `gate.yml` that has only ever been read by a checker that said yes is a
# description, not a gate. This script takes the repository as it stands, copies
# it nineteen times, breaks exactly one thing in each copy, and asserts the
# checker goes red AND names the finding it expects. Every breakage names the
# finding rather than accepting "something went red", because "something went
# red" is a claim that decays silently and "this check is still load-bearing" is
# the one worth making.
#
# The shape is core's `harness/tests/gate_self_test.sh`, and it is the same shape
# for the same reasons: a CONTROL on the unmodified repository runs first,
# because nineteen reds against a repository nobody checked prove nothing at all;
# every breakage gets a fresh throwaway copy, so one can never mask the next; and
# nothing in the committed tree is a deliberately broken repository — the
# breakages are diffs applied here, so a reviewer reads what is being broken
# rather than having to reconstruct it.
#
# EIGHT OF THE NINETEEN BREAK THE GATE, AND THEY ARE THE ONES THAT MATTER
#
# Eleven breakages edit one line in `gate.yml` or in the CI workflow, and the
# checker's static half catches each in under a second. The other eight break
# `bin/prime` or the suite itself and can only be seen by RUNNING the gate: a
# gate that exits 0 having done nothing (7), a gate that runs the suite, watches
# it fail and exits 0 anyway (8), a suite that quietly lost a tier (9), a test
# that starts skipping itself (10), a linter that stops running (12), an audit
# that stops running (13), a database step that stops running (14), and a floor
# set above what the suite reports (15). Those are the false green and its
# cousins, and a declaration that cannot catch them is a comment.
#
# WHAT IT IS NOT
#
# It does not prove the suite touched the database it claims to. A proof is a
# line of output, and a collect-then-run set diff is `cafe`'s job, named in core's
# harness/gate_findings.json under `notEnforced`. It is deliberately NOT wired
# into `bin/prime`: a self-test inside every gate invocation would be a second
# gate that can disagree with the first. It belongs in CI as a step of its own.
#
# COUNTS
#
# Passes and skips are reported separately, always, and a warning case is
# counted as its own kind of thing again: `gate.requirement-unproven` is a claim
# this machine did not settle, it is printed, and it does not move the exit code.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="${ANYWAYE_GATE_CHECK:-$REPO/../core/harness/gate_check.py}"
STATIC_ONLY=0
[ "${1:-}" = "--static" ] && STATIC_ONLY=1

PY="${ANYWAYE_GATE_PYTHON:-}"
if [ -z "$PY" ]; then
  for candidate in python3 python3.13 python3.12 python3.11 python; do
    if command -v "$candidate" >/dev/null 2>&1; then PY="$candidate"; break; fi
  done
fi
if [ -z "$PY" ] || ! "$PY" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
  echo "gate_declaration_self_test: no python >= 3.11 found; set ANYWAYE_GATE_PYTHON" >&2
  exit 1
fi
if [ ! -f "$CHECK" ]; then
  echo "gate_declaration_self_test: core's checker is not at $CHECK; set ANYWAYE_GATE_CHECK" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anywaye-rb-gate-self-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The suite reads core's own schema and doc from `../../../core` relative to
# `test/contract`, which is a SIBLING of the repository root. Every copy below is
# `$WORK/<name>`, so it needs `$WORK/core` to exist or the control is red for a
# reason that has nothing to do with this script. A symlink, because core is
# read-only from this repository and has to stay that way.
ln -s "$(cd "$REPO/.." && pwd)/core" "$WORK/core"

cases=0
passed=0
warn_cases=0
skipped=0
failures=0

# A fresh copy of the repository per breakage, minus .git — a worktree's .git is a
# file pointing at the main checkout, and copying it would make every copy below
# look like a worktree of something. Nothing outside this repository is written.
fresh_copy() {
  local name="$1"
  local dst="$WORK/$name"
  rm -rf "$dst"
  mkdir -p "$dst"
  ( cd "$REPO" && tar -cf - --exclude=./.git --exclude=./tmp --exclude=./log . ) | ( cd "$dst" && tar -xf - )
  chmod +x "$dst/bin/prime"
  printf '%s' "$dst"
}

# edit <file> <old> <new> — a breakage that FAILS LOUDLY if the repository has
# moved past it. A self-test that silently stops breaking anything is worse than
# no self-test, so an unmatched edit is an error here rather than a pass.
edit() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(path, encoding="utf-8").read()
if old not in body:
    sys.exit(f"gate_declaration_self_test: breakage no longer applies to {path}: {old!r} not found")
open(path, "w", encoding="utf-8").write(body.replace(old, new, 1))
PY
}

# run_check <repo> [extra args] — the checker's own exit code, never a pipeline's.
# `PIPESTATUS` is a bash array and this is bash; there is no `| tail` here for
# the same reason core's checker calls subprocess.run with an argv and no shell.
run_check() {
  local repo="$1"
  shift
  "$PY" "$CHECK" "$@" --log-dir "$repo/.gatelog" "$repo" 2>&1
}

# expect_red [--prove] <label> <repo> <finding-id> — the copy must exit 1 AND
# name the finding. Exit 2, which is "the check could not happen", is NOT
# accepted as red: a missing checkout is an unknown, not a clean bill of health.
expect_red() {
  local prove_it=""
  if [ "${1:-}" = "--prove" ]; then prove_it="--prove"; shift; fi
  local label="$1" repo="$2" expect="$3"
  local out code
  cases=$((cases + 1))
  out="$(run_check "$repo" $prove_it)"
  code=$?
  if [ "$code" -ne 1 ]; then
    printf 'FAIL gate_self_test: %s\n      expected exit 1, got %s\n%s\n' "$label" "$code" "$out" >&2
    failures=$((failures + 1))
    return
  fi
  if ! printf '%s' "$out" | grep -q "$expect"; then
    printf 'FAIL gate_self_test: %s\n      went red as something else, and never said %s\n%s\n' \
      "$label" "$expect" "$out" >&2
    failures=$((failures + 1))
    return
  fi
  passed=$((passed + 1))
  printf 'PASS  %2s  %s\n         caught by `%s`\n' "$cases" "$label" "$expect"
}

# expect_warn <label> <repo> <finding-id> — the copy must PRINT the finding and
# STILL exit 0. The exit code is the half a tri-state checker gets wrong.
expect_warn() {
  local label="$1" repo="$2" expect="$3"
  local out code
  cases=$((cases + 1))
  out="$(run_check "$repo")"
  code=$?
  if [ "$code" -ne 0 ]; then
    printf 'FAIL gate_self_test: %s\n      a warning moved the exit code to %s\n%s\n' "$label" "$code" "$out" >&2
    failures=$((failures + 1))
    return
  fi
  if ! printf '%s' "$out" | grep -q "$expect"; then
    printf 'FAIL gate_self_test: %s\n      exited 0 without even printing %s\n%s\n' "$label" "$expect" "$out" >&2
    failures=$((failures + 1))
    return
  fi
  warn_cases=$((warn_cases + 1))
  passed=$((passed + 1))
  printf 'PASS  %2s  %s\n         said `%s` and still exited 0\n' "$cases" "$label" "$expect"
}

# expect_green <label> <repo> — the control. Without it, every red below is
# equally consistent with a checker that refuses everything.
expect_green() {
  local label="$1" repo="$2"
  local out code
  cases=$((cases + 1))
  out="$(run_check "$repo")"
  code=$?
  if [ "$code" -ne 0 ]; then
    printf 'FAIL gate_self_test: %s\n      exit %s\n%s\n' "$label" "$code" "$out" >&2
    failures=$((failures + 1))
    return 1
  fi
  passed=$((passed + 1))
  printf 'PASS  %2s  the control — the unmodified declaration is green in the static half\n' "$cases"
  return 0
}

# --------------------------------------------------------------------------
# the control
# --------------------------------------------------------------------------
control="$(fresh_copy control)"
expect_green 'the control' "$control" && \
  expect_warn 'the four requirements this checker deliberately cannot settle on this machine' \
    "$control" 'gate.requirement-unproven'

# --------------------------------------------------------------------------
# the static breakages — one line each, under a second each
# --------------------------------------------------------------------------

one="$(fresh_copy no-declaration)"
rm -f "$one/gate.yml"
expect_red 'a repository that declares no gate at all' "$one" 'gate.declaration-missing'

two="$(fresh_copy command-missing)"
edit "$two/gate.yml" 'command: [bin/prime]' 'command: [bin/absent]'
expect_red 'a gate command naming a file this repository does not have' "$two" 'gate.command-missing'

three="$(fresh_copy entrypoint-missing)"
edit "$three/gate.yml" 'entrypoint: bin/prime' 'entrypoint: bin/absent'
expect_red 'a gate entrypoint this repository does not have, while the command still does' \
  "$three" 'gate.entrypoint-missing'

four="$(fresh_copy entrypoint-not-executable)"
chmod -x "$four/bin/prime"
expect_red 'a gate nobody is allowed to execute' "$four" 'gate.entrypoint-not-executable'

five="$(fresh_copy task-unresolvable)"
edit "$five/mise.toml" 'run = "./bin/prime"' 'run = "./bin/something-else"'
expect_red 'a mise task that resolves to a different file than the declaration names' \
  "$five" 'gate.task-unresolvable'

six="$(fresh_copy ci-missing)"
edit "$six/gate.yml" 'workflow: ci/ci.yml' 'workflow: .github/workflows/nope.yml'
expect_red 'a declaration naming a CI workflow that is not in this repository' "$six" 'gate.ci-missing'

seven="$(fresh_copy ci-disagrees)"
# The anchor is the ONE-LINE spelling `run: ./bin/prime`, which is what this
# repository's workflow now carries. It used to be the block-scalar body line
# (`          ./bin/prime`), because the step was a block scalar for a reason that
# no longer exists: core's RUN_KEY could not see a one-line `run:` (D12, fixed in
# core 63fd319), so the step was written `run: |` purely to be visible to
# gate.ci-disagrees. That accommodation is retired — see the commit on
# ci/ci.yml — and this anchor is deliberately the one-line form.
#
# It also makes this the case that would catch a REGRESSION of the core fix. If
# RUN_KEY went back to being blind to a one-line `run:`, breakage 7 would still
# go red (nothing here is invisible too) and prove nothing; the case that fails
# is the CONTROL above, which asserts this repository as committed is green, and
# it is green only while core can see `run: ./bin/prime`. A red control is a
# blocking failure, not a finding to disclose.
edit "$seven/ci/ci.yml" '        run: ./bin/prime' '        run: echo "nothing here"'
expect_red 'a CI workflow that no longer runs the gate' "$seven" 'gate.ci-disagrees'

eight="$(fresh_copy requirement-path-missing)"
edit "$eight/gate.yml" 'command: [bin/prime, --fast]' 'command: [bin/absent-setup]'
expect_red 'an external requirement satisfied by a file that is not in this repository' \
  "$eight" 'gate.requirement-path-missing'

nine="$(fresh_copy self-contained-claim)"
edit "$nine/gate.yml" '  selfContained: false' '  selfContained: true'
expect_red 'a gate that claims to be self-contained while five requirements sit under it' \
  "$nine" 'gate.schema'

ten="$(fresh_copy proof-uncompilable)"
# The capture group's `)` moves to the end, so the pattern no longer compiles.
# Caught at the SHAPE layer rather than the proving layer, and that is the better
# answer: a pattern that will not compile is refused without spending the gate's
# whole runtime to find out.
edit "$ten/gate.yml" \
  "match: '^([0-9]+) runs, [0-9]+ assertions, 0 failures, 0 errors, 0 skips\$'" \
  "match: '^([0-9]+ runs, [0-9]+ assertions, 0 failures, 0 errors, 0 skips\$'"
expect_red 'a proof whose pattern does not compile, which would otherwise read as "no proof required"' \
  "$ten" 'gate.schema'

eleven="$(fresh_copy task-undeclared)"
edit "$eleven/gate.yml" '  miseTask: prime
' ''
expect_warn 'a repository with mise tasks and a declaration that names none of them' \
  "$eleven" 'gate.task-undeclared'

# --------------------------------------------------------------------------
# the proving breakages — these break the GATE, so only running it can see them
# --------------------------------------------------------------------------
if [ "$STATIC_ONLY" -eq 0 ]; then

# 12. The false green, and the exact defect this declaration exists to prevent in
# this repository: a gate that exits 0 having executed nothing at all. Every
# string in the declaration is still true. Only the proof catches it.
twelve="$(fresh_copy false-green)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$twelve/bin/prime"
chmod +x "$twelve/bin/prime"
expect_red --prove 'a declaration that is entirely true about a gate that exited 0 without running anything' \
  "$twelve" 'gate.proof-missing'

# 13. The subtler false green, and the reason the suite proof spells out
# `0 failures, 0 errors` rather than only counting runs. The gate RUNS the suite,
# the suite FAILS, and the gate reports success. `gate.nonzero` cannot see it —
# this gate's exit code really is 0 — and the control immediately below shows
# that a proof of `^([0-9]+) runs` sails straight past it.
thirteen="$(fresh_copy swallowed-failure)"
edit "$thirteen/test/version_test.rb" \
  'assert_equal(Anywaye::VERSION, spec.version.to_s)' 'assert_equal("9.9.9", spec.version.to_s)'
edit "$thirteen/bin/prime" 'bundle exec rake test' 'bundle exec rake test || true'
expect_red --prove 'a gate that runs a FAILING suite and exits 0 anyway' \
  "$thirteen" 'gate.proof-missing'

loose="$(fresh_copy swallowed-failure-loose-proof)"
edit "$loose/test/version_test.rb" \
  'assert_equal(Anywaye::VERSION, spec.version.to_s)' 'assert_equal("9.9.9", spec.version.to_s)'
edit "$loose/bin/prime" 'bundle exec rake test' 'bundle exec rake test || true'
edit "$loose/gate.yml" \
  "match: '^([0-9]+) runs, [0-9]+ assertions, 0 failures, 0 errors, 0 skips\$'" \
  "match: '^([0-9]+) runs, '"
cases=$((cases + 1))
if run_check "$loose" --prove >/dev/null 2>&1; then
  passed=$((passed + 1))
  printf 'PASS  %2s  the control for 13 — the SAME failing gate is ACCEPTED when the proof counts runs\n' "$cases"
  printf '         without pinning 0 failures, so 13 is the pattern doing the work and not the fixture.\n'
else
  printf 'FAIL gate_self_test: the control for 13 — loosening the proof to `^([0-9]+) runs, ` should\n'
  printf '      ACCEPT this repository, because that is what makes breakage 13 mean anything. It did not.\n' >&2
  failures=$((failures + 1))
fi

# 14. A suite that quietly loses a tier and is otherwise entirely GREEN.
# `test/contract/manifest_test.rb` is 15 tests over a YAML file and core's
# schema that touch no line of `lib/`, so removing them costs coverage nothing and
# the gate stays green over 213 tests instead of 228. The floor is what says so,
# and `gate.nonzero` has nothing to say about it.
fourteen="$(fresh_copy shrunken-suite)"
mv "$fourteen/test/contract/manifest_test.rb" "$fourteen/test/contract/manifest_test.rb.bak"
expect_red --prove 'a suite that quietly lost its contract tier and is otherwise entirely green' \
  "$fourteen" 'gate.floor'

# 15. A test that skips itself. AGENTS.md says this repository has no skipped
# tests, so a skip appearing is a signal and not a statistic — and `0 skips` in
# the proof is what makes it one. The run COUNT does not change, so a proof of
# `^([0-9]+) runs` would not notice this at all.
fifteen="$(fresh_copy skipped-test)"
edit "$fifteen/test/version_test.rb" \
  '  def test_the_version_is_a_three_segment_number' \
  '  def test_the_version_is_a_three_segment_number
    skip "the gate does not get to skip tests"'
expect_red --prove 'a suite where one test has started skipping itself' \
  "$fifteen" 'gate.proof-missing'

# 16-18. A gate step that stops being part of the gate. bin/prime's own header
# says "No step is skippable into a false green"; these three are what makes
# that sentence checkable rather than aspirational.
sixteen="$(fresh_copy lint-dropped)"
edit "$sixteen/bin/prime" 'bundle exec rubocop --parallel' 'true # the linter was dropped'
expect_red --prove 'a gate that no longer lints' "$sixteen" 'gate.proof-missing'

seventeen="$(fresh_copy audit-dropped)"
edit "$seventeen/bin/prime" 'bundle exec bundler-audit check --update' 'true # the audit was dropped'
expect_red --prove 'a gate that no longer audits its bundle for known CVEs' \
  "$seventeen" 'gate.proof-missing'

eighteen="$(fresh_copy database-step-dropped)"
edit "$eighteen/bin/prime" 'bundle exec rake db:prepare' 'true # the database step was dropped'
expect_red --prove 'a gate that no longer prepares its own test database' \
  "$eighteen" 'gate.proof-missing'

# 19. The floor, set above what the suite reports. The decrease-detector's other
# direction: a number written once and never revisited.
nineteen="$(fresh_copy floor)"
edit "$nineteen/gate.yml" 'minimum: 220' 'minimum: 400'
expect_red --prove 'a gate that proves 228 tests where the declaration promised 400' \
  "$nineteen" 'gate.floor'

else
  skipped=9   # breakages 12-19, plus the control's proving half
fi

# --------------------------------------------------------------------------
printf '\n'
if [ "$failures" -ne 0 ]; then
  printf 'FAIL: gate_declaration_self_test — %s of %s checks did not come out right.\n' "$failures" "$cases"
  exit 1
fi
printf 'PASS: gate_declaration_self_test — %s passed, %s skipped, %s run.\n' "$passed" "$skipped" "$cases"
printf '      %s of those %s passed are warning cases: they printed their finding and still exited 0.\n' \
  "$warn_cases" "$passed"
if [ "$STATIC_ONLY" -eq 1 ]; then
  printf '      The %s skipped need the gate to be RUN, including the whole suite.\n' "$skipped"
  printf '      Full run: bash test/gate_declaration_self_test.sh\n'
fi