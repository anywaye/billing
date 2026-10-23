#!/usr/bin/env bash
#
# The gate, as the anywaye CI runs it.
#
# The CI runs THIS file. It is here so that "what CI runs" is one named
# thing in the repository: the check behind gate.yml's ci block reads this
# file and asks whether it invokes the declared gate, and it can only answer
# that if there is a file to read.
#
# The command below is the argv gate.yml declares under ci.invokes, spelled
# the same way, so the declaration and the gate cannot drift apart without
# the check noticing.
set -euo pipefail
cd "$(dirname "$0")/.."

# THE MISE TASK, when the repository has one. The task is how the toolchain
# is pinned, and running the gate through it is running the gate the way a
# developer runs it. The argv below is the fallback, and it is what the
# declaration names.
if [ -f mise.toml ] && command -v mise >/dev/null 2>&1 \
  && mise tasks ls 2>/dev/null | grep -qE '^prime([[:space:]]|$)'; then
  exec mise run prime
fi

exec ./bin/prime
