#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"

core_path="${CORE_PATH:-$repo_root/../core}"
checker="$core_path/harness/bin/gate-check"
if [ ! -x "$checker" ]; then
  echo "gate_declaration_self_test: $checker is missing or not executable." >&2
  echo "  Point CORE_PATH at a anywaye/core checkout, or put core beside this" >&2
  echo "  worktree. This script does not vendor the checker: a second copy of it" >&2
  echo "  would be a second answer to the question the copy is being asked." >&2
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/billing-gate-self-test.XXXXXX")"
saved="$work/saved"
mkdir -p "$saved/bin" "$saved/test/integration"

cp -p "$repo_root/bin/prime" "$saved/bin/prime"
cp -p "$repo_root/gate.yml" "$saved/gate.yml"
cp -p "$repo_root/test/integration/health_test.rb" "$saved/test/integration/health_test.rb"

restore() {
  cp -p "$saved/bin/prime" "$repo_root/bin/prime"
  cp -p "$saved/gate.yml" "$repo_root/gate.yml"
  cp -p "$saved/test/integration/health_test.rb" "$repo_root/test/integration/health_test.rb"
}
trap 'restore' EXIT INT TERM

passed=0
failed=0

note() { printf '\n--- %s\n' "$1"; }

verdict() {
  local name="$1" expect="$2" mode="$3" path_prefix="${4:-}"
  local log="$work/$name.log" rc=0
  if [ "$mode" = "prove" ]; then
    if [ -n "$path_prefix" ]; then
      PATH="$path_prefix:$PATH" "$checker" --prove "$repo_root" >"$log" 2>&1 || rc=$?
    else
      "$checker" --prove "$repo_root" >"$log" 2>&1 || rc=$?
    fi
  else
    if [ -n "$path_prefix" ]; then
      PATH="$path_prefix:$PATH" "$checker" "$repo_root" >"$log" 2>&1 || rc=$?
    else
      "$checker" "$repo_root" >"$log" 2>&1 || rc=$?
    fi
  fi

  grep -E '^(FAIL|WARN|OK) ' "$log" | sed 's/^/    /' || true

  if [ "$rc" -ne 1 ]; then
    printf '    CASE FAILED: expected exit 1, got %s\n' "$rc" >&2
    failed=$((failed + 1))
    restore
    return
  fi
  if ! grep -qF "$expect" "$log"; then
    printf '    CASE FAILED: exit was 1 but %s was never named\n' "$expect" >&2
    failed=$((failed + 1))
    restore
    return
  fi
  printf '    ok: exit 1, and it named %s\n' "$expect"
  passed=$((passed + 1))
  restore
}

note "control: the declaration as committed"
rc=0
"$checker" "$repo_root" >"$work/control.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "gate_declaration_self_test: the UNBROKEN declaration is already red (exit $rc)." >&2
  echo "  Nothing below would mean anything. Fix this first." >&2
  sed 's/^/    /' "$work/control.log" >&2
  exit 1
fi
echo "    ok: exit 0, nothing to fix before the cases below"

note "1: bin/prime replaced by a body that is exactly 'exit 0'"
printf '#!/usr/bin/env bash\nexit 0\n' >"$repo_root/bin/prime"
chmod +x "$repo_root/bin/prime"
verdict "case1-exit-zero" "gate.proof-missing" prove

note "2: rm test/integration/health_test.rb (5 tests, no money, referenced by nothing)"
rm -f "$repo_root/test/integration/health_test.rb"
verdict "case2-deleted-test" "gate.floor" prove

suite_floor="$(sed -n 's/^      minimum: \([0-9][0-9]*\)$/\1/p' "$repo_root/gate.yml" | tail -1)"
if [ -z "$suite_floor" ]; then
  echo "    CASE COULD NOT RUN: no '      minimum: <digits>' line was found in gate.yml." >&2
  echo "    If the declaration's formatting changed, fix this case — and do not" >&2
  echo "    paper over it by putting the number back in this script." >&2
  failed=$((failed + 1))
else
  raised_floor=$((suite_floor + 1))
  note "3: the suite floor raised from $suite_floor to $raised_floor"
  sed "s/^      minimum: ${suite_floor}\$/      minimum: ${raised_floor}/" \
    "$repo_root/gate.yml" >"$work/gate.yml.raised"
  mv "$work/gate.yml.raised" "$repo_root/gate.yml"
  if grep -q "^      minimum: ${raised_floor}\$" "$repo_root/gate.yml"; then
    verdict "case3-raised-floor" "gate.floor" prove
  else
    echo "    CASE FAILED: the sed did not find the line to raise." >&2
    echo "    If the declaration's formatting changed, fix this case." >&2
    failed=$((failed + 1))
    restore
  fi
fi

note "4: rm bin/prime (the entrypoint and the command both name it)"
rm -f "$repo_root/bin/prime"
verdict "case4-missing-entrypoint" "gate.entrypoint-missing" static

note "5: a ruby first on PATH that answers 3.4.2 instead of 4.0.1"
shim="$work/wrong-ruby"
mkdir -p "$shim"
printf '#!/bin/sh\nprintf 3.4.2\n' >"$shim/ruby"
chmod +x "$shim/ruby"
verdict "case5-wrong-toolchain" "gate.nonzero" prove "$shim"
if grep -qF "gate.nonzero" "$work/case5-wrong-toolchain.log"; then
  rc=0
  PATH="$shim:$PATH" "$repo_root/bin/prime" >"$work/case5-prime.log" 2>&1 || rc=$?
  if [ "$rc" -eq 127 ] &&
     grep -qF '4.0.1' "$work/case5-prime.log" &&
     grep -qF '3.4.2' "$work/case5-prime.log"; then
    echo "    ok: bin/prime exited 127 naming both 4.0.1 and 3.4.2"
  else
    echo "    CASE FAILED: bin/prime did not refuse the wrong interpreter by name." >&2
    echo "    (exit $rc)" >&2
    sed 's/^/      /' "$work/case5-prime.log" >&2 || true
    failed=$((failed + 1))
  fi
  restore
fi

note "control again: the tree after five breakages"
rc=0
"$checker" "$repo_root" >"$work/control2.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "gate_declaration_self_test: the tree did NOT come back clean (exit $rc)." >&2
  sed 's/^/    /' "$work/control2.log" >&2
  failed=$((failed + 1))
else
  echo "    ok: exit 0 — every breakage was reverted"
fi

note "control again: the three files are byte-identical to the copies taken at the start"
restore_drift=0
for rel in bin/prime gate.yml test/integration/health_test.rb; do
  if ! cmp -s "$saved/$rel" "$repo_root/$rel"; then
    echo "    FAIL: $rel is not the file this script saved" >&2
    restore_drift=1
  fi
done
if [ "$restore_drift" -eq 0 ]; then
  echo "    ok: all three are byte-identical to the start — every breakage was reverted"
else
  failed=$((failed + 1))
fi

if [ -x "$repo_root/bin/prime" ]; then
  echo "    ok: bin/prime is still executable"
else
  echo "    FAIL: bin/prime lost its executable bit" >&2
  failed=$((failed + 1))
fi

if git -C "$repo_root" diff --quiet -- bin/prime gate.yml test/integration/health_test.rb 2>/dev/null; then
  echo "    ok: no uncommitted diff in the files this script touched"
else
  echo "    note: the files this script touched carry an uncommitted diff."
  echo "      Expected while drafting; the bytes above are what this script restored."
fi

printf '\n=== %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  echo "The declaration is NOT proven red-capable. Logs are in $work" >&2
  exit 1
fi
echo "Logs are in $work"
exit 0
