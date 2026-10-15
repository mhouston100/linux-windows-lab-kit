#!/usr/bin/env bash
# Phase 6: verify cleanup safety gates (does not delete lab by default).

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<'EOF'
Usage: phase6.sh

Verifies cleanup-lab.sh safety (refuses without --yes; does not delete).

To actually reclaim space (explicit):
  ./scripts/cleanup-lab.sh --all-work --yes
  # or finer: --vms / --tmp / --convert / --identity
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

cd "$ROOT_DIR"
log "Phase 6 — Cleanup safety verification"
"${SCRIPTS_DIR}/verify-phase6.sh"
