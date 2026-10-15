#!/usr/bin/env bash
# Phase 4 end-to-end: prepare identity → verify.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-prompt|--prompt) ARGS+=("$1") ;;
    -h|--help)
      cat <<'EOF'
Usage: phase4.sh [--no-prompt]

1) prepare-identity.sh
2) verify-phase4.sh
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

cd "$ROOT_DIR"
log "Phase 4 — Identity / unattend templates"
"${SCRIPTS_DIR}/prepare-identity.sh" "${ARGS[@]+"${ARGS[@]}"}"
"${SCRIPTS_DIR}/verify-phase4.sh"
