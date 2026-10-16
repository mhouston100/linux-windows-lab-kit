#!/usr/bin/env bash
# Phase 5 checkpoint: lab-ctl health + boot-order file; optional start smoke with --no-wait.

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

log "Phase 5 verification"

check "boot-order.tsv" test -f "${ROOT_DIR}/config/boot-order.tsv"
check "lab-ctl.sh executable" test -x "${SCRIPTS_DIR}/lab-ctl.sh"

# Health (VMs registered, disks, nets) — does not require running
if "${SCRIPTS_DIR}/lab-ctl.sh" health; then
  printf '  [OK]   lab-ctl health\n'
else
  printf '  [FAIL] lab-ctl health\n'
  failed=1
fi

# Quick start/stop smoke with no inter-VM waits (ACPI may be slow on headless Windows — use poweroff path)
log "Smoke: start all (--no-wait) then stop"
if "${SCRIPTS_DIR}/lab-ctl.sh" start --no-wait \
  && "${SCRIPTS_DIR}/lab-ctl.sh" stop; then
  printf '  [OK]   start/stop smoke\n'
else
  printf '  [FAIL] start/stop smoke\n'
  failed=1
fi

# All should be powered off
while IFS=$'\t' read -r name order wait notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue
  state="$(hv_vm_state "$name")"
  if [[ "$state" == "poweroff" || "$state" == "aborted" ]]; then
    printf '  [OK]   %s off (%s)\n' "$name" "$state"
  else
    printf '  [FAIL] %s state=%s\n' "$name" "$state"
    failed=1
  fi
done <"${ROOT_DIR}/config/boot-order.tsv"

if [[ "$failed" -ne 0 ]]; then
  die "Phase 5 checkpoint failed"
fi

marker_set "${MARKERS_DIR}/phase5.ok"
log "Phase 5 checkpoint PASSED"
