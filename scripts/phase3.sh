#!/usr/bin/env bash
# Phase 3 end-to-end: create networks/VMs → verify.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|--no-prompt|--prompt|--no-smoke) ARGS+=("$1") ;;
    --topology) ARGS+=("$1" "${2:?}"); shift ;;
    -h|--help)
      cat <<'EOF'
Usage: phase3.sh [--force] [--no-prompt] [--no-smoke]

1) create-lab-vms.sh   (CorpNet intnet + NAT on GW; attach converted VDIs)
2) verify-phase3.sh
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

cd "$ROOT_DIR"
log "Phase 3 — VirtualBox networks and VMs"
"${SCRIPTS_DIR}/create-lab-vms.sh" "${ARGS[@]+"${ARGS[@]}"}"
"${SCRIPTS_DIR}/verify-phase3.sh"
