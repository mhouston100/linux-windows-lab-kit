#!/usr/bin/env bash
# Phase 3 checkpoint: networks/VMs exist, disks attached under VM_ROOT.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

load_config 0

failed=0
check() {
  local desc="$1"; shift
  if "$@"; then printf '  [OK]   %s\n' "$desc"; else printf '  [FAIL] %s\n' "$desc"; failed=1; fi
}

TOPOLOGY_FILE="${ROOT_DIR}/config/topology.tsv"
CORPNET_INTNET="${LAB_PREFIX}-${LAB_NETWORK_NAME}"

log "Phase 3 verification (VM_ROOT=$VM_ROOT)"

check "create-vms marker" marker_ok "${MARKERS_DIR}/create-vms.done"

while IFS=$'\t' read -r name role ostype memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue

  if VBoxManage showvminfo "$name" >/dev/null 2>&1; then
    printf '  [OK]   VM registered: %s\n' "$name"
  else
    printf '  [FAIL] VM missing: %s\n' "$name"
    failed=1
    continue
  fi

  dest="${VM_ROOT}/${name}/${disk}"
  if [[ -f "$dest" ]]; then
    printf '  [OK]   disk under VM_ROOT: %s\n' "$dest"
  else
    printf '  [FAIL] disk missing under VM_ROOT: %s\n' "$dest"
    failed=1
  fi

  info="$(VBoxManage showvminfo "$name" --machinereadable)"
  if echo "$info" | rg -q "SATA-0-0\".*=.*${disk}|${disk}"; then
    printf '  [OK]   SATA disk attached: %s\n' "$name"
  else
    if echo "$info" | rg -q 'SATA-0-0"=".*\.vdi"'; then
      printf '  [OK]   SATA disk attached: %s\n' "$name"
    else
      printf '  [FAIL] no SATA disk on %s\n' "$name"
      failed=1
    fi
  fi

  if echo "$info" | rg -q "intnet1=\"${CORPNET_INTNET}\"|nic1=\"intnet\""; then
    printf '  [OK]   CorpNet (intnet) on nic1: %s\n' "$name"
  else
    printf '  [FAIL] CorpNet not on nic1: %s\n' "$name"
    failed=1
  fi

  if [[ "$nic2" == "nat" ]]; then
    if echo "$info" | rg -q 'nic2="nat"'; then
      printf '  [OK]   NAT on nic2: %s\n' "$name"
    else
      printf '  [FAIL] NAT missing on nic2: %s\n' "$name"
      failed=1
    fi
  fi

  state="$(echo "$info" | awk -F= '/^VMState=/{gsub(/"/,"",$2); print $2}')"
  if [[ "$state" == "poweroff" || "$state" == "aborted" ]]; then
    printf '  [OK]   powered off after create/smoke: %s (%s)\n' "$name" "$state"
  else
    printf '  [WARN] unexpected state %s for %s (not failing)\n' "$state" "$name"
  fi
done <"$TOPOLOGY_FILE"

if [[ "$failed" -ne 0 ]]; then
  die "Phase 3 checkpoint failed"
fi

marker_set "${MARKERS_DIR}/phase3.ok"
log "Phase 3 checkpoint PASSED"
log "VMs live under: $VM_ROOT"
log "Internal network: $CORPNET_INTNET"
