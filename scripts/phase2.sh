#!/usr/bin/env bash
# Phase 2 end-to-end: inventory → convert → verify.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|--no-prompt|--prompt) ARGS+=("$1") ;;
    --format) ARGS+=("$1" "${2:?}"); shift ;;
    -h|--help)
      cat <<'EOF'
Usage: phase2.sh [--force] [--no-prompt] [--format vdi|vmdk]

1) inventory-disks.sh
2) convert-disks.sh   (flatten differencing VHDX, convert to VDI)
3) verify-phase2.sh
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

cd "$ROOT_DIR"
log "Phase 2 — Disk inventory and conversion"
"${SCRIPTS_DIR}/inventory-disks.sh" --no-prompt
"${SCRIPTS_DIR}/convert-disks.sh" "${ARGS[@]+"${ARGS[@]}"}"
"${SCRIPTS_DIR}/verify-phase2.sh"
