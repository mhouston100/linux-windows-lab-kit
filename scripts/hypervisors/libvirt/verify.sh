#!/usr/bin/env bash
# libvirt checks for a converted disk and a created lab.

hv_verify_disk() {
  qemu-img info -f qcow2 "$1" >/dev/null
}

hv_verify_create() {
  local failed=0 name role memory_mb cpus disk nic1 nic2 notes dest xml
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

    dest="${VM_ROOT}/${name}/${name}.qcow2"
    if [[ -f "$dest" ]]; then
      printf '  [OK]   disk under VM_ROOT: %s\n' "$dest"
    else
      printf '  [FAIL] disk missing under VM_ROOT: %s\n' "$dest"
      failed=1
    fi

    xml="$(lv_virsh dumpxml "$name")"
    if printf '%s' "$xml" | rg -q 'target dev=.sda.|bus=.sata.'; then
      printf '  [OK]   SATA disk attached: %s\n' "$name"
    else
      printf '  [FAIL] no SATA disk on %s\n' "$name"
      failed=1
    fi

    if printf '%s' "$xml" | rg -q 'name=.org.qemu.guest_agent.0.'; then
      printf '  [OK]   QEMU guest agent channel: %s\n' "$name"
    else
      printf '  [FAIL] no QEMU guest agent channel on %s\n' "$name"
      failed=1
    fi

    if printf '%s' "$xml" | rg -q "network>${corpnet}<|network='${corpnet}'"; then
      printf '  [OK]   CorpNet on nic1: %s\n' "$name"
    else
      printf '  [FAIL] CorpNet not on nic1: %s\n' "$name"
      failed=1
    fi

    if [[ "$nic2" == "nat" ]]; then
      if printf '%s' "$xml" | rg -q "network>default<|network='default'"; then
        printf '  [OK]   default NAT on nic2: %s\n' "$name"
      else
        printf '  [FAIL] default NAT missing on nic2: %s\n' "$name"
        failed=1
      fi
    fi
  done <"$topo"

  [[ "$failed" -eq 0 ]]
}
