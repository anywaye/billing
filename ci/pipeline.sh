#!/usr/bin/env bash
# ci/pipeline.sh — billing's pipeline, on the instabox backend or any other.
#
# A backend's job is only to provide an environment and call this script; the
# gate is billing's. Which backend ran is recorded in `ci/backend`, and
# switching is one line — `github-actions` keeps `.github/workflows/ci.yml` as
# the runner (kit's `backends/README.md` is the contract).
#
# WHERE EVERY COMMAND COMES FROM: `.github/workflows/ci.yml` IN THIS
# REPOSITORY. That file is the source of truth; when it changes, change this
# file with it.
#
#   1. THE GATE is `bin/prime`, verbatim and unmodified — the `gate` job's step
#      body is `bin/prime 2>&1 | tee "$log"`. No flags: CI runs the same
#      command a developer runs, and a CI-only variant would be a second gate.
#      (The per-tier re-runs and the count guards around it stay in the
#      workflow; they re-run the suite and assert its size, which is CI's job
#      rather than the pipeline's.)
#   2. THE TOOLCHAIN is the ruby pin in `.ruby-version` (one Ruby number in
#      three files: `mise.toml`, `.ruby-version`, the Dockerfile's
#      `ARG RUBY_VERSION`). CI installs it with `ruby/setup-ruby`; here
#      `mise install` materializes the same pin from `mise.toml`, and the gate
#      runs under `mise exec` so a developer, a runner and this sandbox all
#      use the same interpreter. `bin/prime` refuses anything else with 127.
#   3. NO PATH ENTRIES: no step in `.github/workflows/*.yml` appends to
#      `$GITHUB_PATH`, so `PATHS` below is empty. If a workflow ever gains one,
#      copy it there in the same order.
#
# CONCURRENCY — RUBY GATES ARE SERIAL. Do not run this pipeline concurrently
# with another Ruby gate on the same machine: the `pg` gem has a known fork
# segfault under concurrency (seen in this repository as a parallel test
# worker dying in `connect_start`, leaving the suite green and un-exiting —
# the workflow's gate step documents it). The backend's supervisor must
# serialize billing's gate against every other Ruby service's gate. Nothing in
# this script enforces that; the supervisor owns scheduling, and this comment
# is how it knows.
#
# WHAT THE BACKEND PROVIDES (kit `backends/README.md`): WORKSPACE, GH_TOKEN,
# CI. Anything else this pipeline needs it declares below, and the backend
# materializes it from its own secret store.
set -euo pipefail

# ---------------------------------------------------------------------------
# identity
# ---------------------------------------------------------------------------
# The repository root is derived from this file, not from the caller's cwd. The
# agent resets the checkout to the fetched commit before calling us, and the
# pipeline does the same itself so that a hand-run is identical to a polled one.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
REPO_NAME="$(basename "$REPO_DIR")"

WORKSPACE="${WORKSPACE:-$(cd "$REPO_DIR/../.." && pwd)}"
BRANCH="${CI_BRANCH:-master}"
export CI="${CI:-1}"
export WORKSPACE

log() { printf '\n== %s\n' "$1"; }

log "pipeline: $REPO_NAME at $REPO_DIR"

# The gate CI names. `bin/prime`, verbatim — see the header.
GATE=(./bin/prime)

# No `echo … >> $GITHUB_PATH` line in `.github/workflows/*.yml` — verified, so
# this stays empty rather than carrying a guess.
PATHS=()

if [ "${#PATHS[@]}" -gt 0 ]; then
  for d in "${PATHS[@]}"; do
    export PATH="$d:$PATH"
  done
fi

# ---------------------------------------------------------------------------
# the database
# ---------------------------------------------------------------------------
# The gate reads `DATABASE_URL` from the environment the backend provides
# (CI sets a per-run database on the `gate` job so overlapping runs cannot
# share one; `config/database.yml` derives a per-checkout name otherwise).
# Until the kit database packet wires those names, a gate run that names the
# missing URL honestly is a correct result — so this declares the need and
# does NOT fake it with a default. A default database URL here would point the
# money suite at a database nobody provisioned and report whatever it found.
if [ -z "${DATABASE_URL:-}" ]; then
  echo "pipeline: DATABASE_URL is not set by the backend — bin/prime will use"
  echo "  config/database.yml's derived name and fail honestly if no PostgreSQL"
  echo "  answers there. That failure is the report, not a reason to invent a URL."
else
  echo "pipeline: DATABASE_URL is set by the backend"
fi

log "the toolchain the repository pins"
# `mise install` materializes the versions in mise.toml; `mise exec` runs the
# gate under them. When there is no mise, the gate runs on whatever this
# machine ships — which `bin/prime` refuses with 127 unless it is the pinned
# ruby — and that refusal is reported rather than hidden.
if [ -f mise.toml ] && command -v mise >/dev/null 2>&1; then
  mise install
  GATE=(mise exec -- "${GATE[@]}")
elif [ -f mise.toml ]; then
  echo "pipeline: mise.toml is present and mise is NOT on PATH — the gate runs on the machine's own toolchain"
fi

log "the gate"
# The command is a list, so nothing here is re-parsed.
"${GATE[@]}"

# ---------------------------------------------------------------------------
# ship
# ---------------------------------------------------------------------------
# This tree carries a chart (`chart/Chart.yaml`) but no `bin/publish`, and the
# kit template for one is not vendored here — shipping is not wired on this
# backend yet. The gate is the whole run until it is. If `bin/publish` ever
# lands, this block ships through it; until then a green gate that also tried
# to push would be a pipeline failing for a reason unrelated to the tree.
if [ "${CI_DRY_RUN:-0}" = "1" ]; then
  log "gate passed; CI_DRY_RUN=1, not shipping"
  exit 0
fi

SHIPPED=""
if [ -f chart/Chart.yaml ] && [ -x bin/publish ]; then
  log "publish image + chart"
  ./bin/publish --service-dir .
  chart_name="$(sed -n 's/^name: *//p' chart/Chart.yaml | head -1)"
  chart_version="$(sed -n 's/^version: *//p' chart/Chart.yaml | head -1)"
  SHIPPED="image+chart ${chart_name}:${chart_version}"
else
  echo "pipeline: no bin/publish in this tree — nothing to publish; the gate is the whole run"
fi

# ---------------------------------------------------------------------------
# the last line a log tail reads
# ---------------------------------------------------------------------------
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$SHIPPED" ]; then
  log "pipeline: shipped $REPO_NAME $SHIPPED at $COMMIT"
else
  log "pipeline: passed $REPO_NAME at $COMMIT (nothing published)"
fi
