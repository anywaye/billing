#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
REPO_NAME="$(basename "$REPO_DIR")"

WORKSPACE="${WORKSPACE:-$(cd "$REPO_DIR/../.." && pwd)}"
BRANCH="${CI_BRANCH:-master}"
export CI="${CI:-1}"
export WORKSPACE

log() { printf '\n== %s\n' "$1"; }

log "pipeline: $REPO_NAME at $REPO_DIR"

GATE=(./bin/prime)

PATHS=()

if [ "${#PATHS[@]}" -gt 0 ]; then
  for d in "${PATHS[@]}"; do
    export PATH="$d:$PATH"
  done
fi

if [ -z "${DATABASE_URL:-}" ]; then
  echo "pipeline: DATABASE_URL is not set by the backend — bin/prime will use"
  echo "  config/database.yml's derived name and fail honestly if no PostgreSQL"
  echo "  answers there. That failure is the report, not a reason to invent a URL."
else
  echo "pipeline: DATABASE_URL is set by the backend"
fi

log "the toolchain the repository pins"
if [ -f mise.toml ] && command -v mise >/dev/null 2>&1; then
  mise install
  GATE=(mise exec -- "${GATE[@]}")
elif [ -f mise.toml ]; then
  echo "pipeline: mise.toml is present and mise is NOT on PATH — the gate runs on the machine's own toolchain"
fi

log "the gate"
"${GATE[@]}"

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

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$SHIPPED" ]; then
  log "pipeline: shipped $REPO_NAME $SHIPPED at $COMMIT"
else
  log "pipeline: passed $REPO_NAME at $COMMIT (nothing published)"
fi
