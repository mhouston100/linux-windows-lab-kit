#!/usr/bin/env bash
# VirtualBox checks for a created lab. Shared verify-phase3.sh calls this.

hv_verify_create() {
  local failed=0 name role memory_mb cpus disk nic1 nic2 notes dest info state
  local topo="${ROOT_DIR}/config/topology.tsv"
  local corpnet="${LAB_PREFIX}-${LAB_NETWORK_NAME}"

  while IFS=$'\t' read -r name role memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue

    if hv_vm_exists "$name"; then
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
    if echo "$info" | rg -q 'SATA-0-0"=".*\.vdi"'; then
      printf '  [OK]   SATA disk attached: %s\n' "$name"
    else
      printf '  [FAIL] no SATA disk on %s\n' "$name"
      failed=1
    fi

    if echo "$info" | rg -q "intnet1=\"${corpnet}\"|nic1=\"intnet\""; then
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
  done <"$topo"

  [[ "$failed" -eq 0 ]]
}
