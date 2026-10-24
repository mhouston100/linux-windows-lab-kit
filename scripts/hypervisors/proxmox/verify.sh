#!/usr/bin/env bash
# Proxmox checks for a created lab. Shared verify-phase3.sh calls this.

hv_verify_disk() {
  local fmt
  [[ -f "$1" ]] || return 1
  fmt="$(qemu-img info --output=json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format",""))')"
  [[ "$fmt" == "qcow2" ]]
}

hv_verify_create() {
  local failed=0 name role memory_mb cpus disk nic1 nic2 notes
  local vmid node status row sata net0 net1
  local topo="${ROOT_DIR}/config/topology.tsv"

  while IFS=$'\t' read -r name role memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue

    if ! row="$(pve_find_name "$name")"; then
      printf '  [FAIL] VM missing: %s\n' "$name"
      failed=1
      continue
    fi
    IFS=$'\t' read -r vmid node status <<<"$row"
    if [[ "$node" != "$PVE_NODE" ]]; then
      printf '  [FAIL] %s is on node %s, not %s\n' "$name" "$node" "$PVE_NODE"
      failed=1
      continue
    fi
    printf '  [OK]   VM registered: %s (%s)\n' "$name" "$vmid"

    sata="$(pve_config_value "$vmid" sata0)"
    if [[ -n "$sata" ]]; then
      printf '  [OK]   SATA disk attached: %s\n' "$name"
    else
      printf '  [FAIL] no SATA disk on %s\n' "$name"
      failed=1
    fi

    net0="$(pve_config_value "$vmid" net0)"
    if [[ "$net0" == *"bridge=${PVE_BRIDGE}"* ]]; then
      printf '  [OK]   CorpNet bridge on net0: %s\n' "$name"
    else
      printf '  [FAIL] CorpNet bridge not on net0: %s\n' "$name"
      failed=1
    fi

    if [[ "$nic2" == "nat" ]]; then
      net1="$(pve_config_value "$vmid" net1)"
      if [[ "$net1" == *"bridge=${PVE_INTERNET_BRIDGE}"* ]]; then
        printf '  [OK]   Internet bridge on net1: %s\n' "$name"
      else
        printf '  [FAIL] Internet bridge missing on net1: %s\n' "$name"
        failed=1
      fi
    fi

    if [[ "$status" == "stopped" ]]; then
      printf '  [OK]   powered off after create: %s\n' "$name"
    else
      printf '  [WARN] unexpected state %s for %s (not failing)\n' "$status" "$name"
    fi
  done <"$topo"

  [[ "$failed" -eq 0 ]]
}
