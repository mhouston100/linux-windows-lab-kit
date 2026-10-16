#!/usr/bin/env bash
# Phase 3 checkpoint: the selected hypervisor has the lab VMs and disks.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

load_config 0
hv_load

failed=0
check() {
  local desc="$1"; shift
  if "$@"; then printf '  [OK]   %s\n' "$desc"; else printf '  [FAIL] %s\n' "$desc"; failed=1; fi
}

log "Phase 3 verification (VM_ROOT=$VM_ROOT hypervisor=${HYPERVISOR:-virtualbox})"

check "create-vms marker" marker_ok "${MARKERS_DIR}/create-vms.done"

if ! hv_verify_create; then
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  die "Phase 3 checkpoint failed"
fi

marker_set "${MARKERS_DIR}/phase3.ok"
log "Phase 3 checkpoint PASSED"
log "VMs live under: $VM_ROOT"
