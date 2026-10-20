#!/usr/bin/env bash
# Proxmox: copy qcow2 images with rsync and create the server VMs through the API.

set -euo pipefail
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/config.sh
source "${HV_DIR}/../../lib/config.sh"
# shellcheck source=load.sh
source "${HV_DIR}/load.sh"

FORCE=0
DO_PROMPT=1
SMOKE=1
TOPOLOGY_FILE=""

usage() {
  cat <<'EOF'
Usage: create-lab-vms.sh [options]

  --force         Recreate VMs if they already exist
  --no-prompt     Use defaults / lab.env without path prompts
  --prompt        Force path prompts (default when interactive)
  --no-smoke      Skip the gateway power-on smoke test
  --topology FILE Override topology TSV (default: config/topology.tsv)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --no-prompt) DO_PROMPT=0 ;;
    --prompt) DO_PROMPT=1 ;;
    --no-smoke) SMOKE=0 ;;
    --topology) TOPOLOGY_FILE="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config "$DO_PROMPT"
save_resolved_paths_hint
pve_prepare

: "${TOPOLOGY_FILE:=${ROOT_DIR}/config/topology.tsv}"
[[ -f "$TOPOLOGY_FILE" ]] || die "Topology file not found: $TOPOLOGY_FILE"

converted_disk() {
  local base="$1" stem
  stem="${base%.*}"
  printf '%s/%s.qcow2\n' "$CONVERT_DIR" "$stem"
}

vmid_owner() {
  local want="$1" vmid name node status
  while IFS=$'\t' read -r vmid name node status || [[ -n "${vmid:-}" ]]; do
    [[ "$vmid" == "$want" ]] || continue
    printf '%s\n' "$name"
    return 0
  done < <(pve_resources)
  return 1
}

create_one_vm() {
  local name="$1" memory_mb="$2" cpus="$3" disk_basename="$4" nic1="$5" nic2="$6"
  local src vmid ostype row found node status sata net0 net1 body owner
  local -a args=()

  src="$(converted_disk "$disk_basename")"
  [[ -f "$src" ]] || die "Converted disk missing: $src (run phase 2 first)"
  row="$(pve_guest_row "$name")" || die "No Proxmox guest id for ${name}"
  IFS=$'\t' read -r vmid ostype <<<"$row"

  if [[ "$nic1" != "corp" ]]; then
    die "Unsupported nic1='${nic1}' for ${name}"
  fi
  net0="e1000,bridge=${PVE_BRIDGE}"
  net1=""
  if [[ "$nic2" == "nat" ]]; then
    net1="e1000,bridge=${PVE_INTERNET_BRIDGE}"
  elif [[ "$nic2" != "-" && -n "$nic2" ]]; then
    die "Unsupported nic2='${nic2}' for ${name}"
  fi

  if row="$(pve_find_name "$name")"; then
    IFS=$'\t' read -r found node status <<<"$row"
    [[ "$found" == "$vmid" ]] || die "VM ${name} is VMID ${found}, not the lab id ${vmid}. Refusing to change it."
    [[ "$node" == "$PVE_NODE" ]] || die "VM ${name} is on node ${node}, not ${PVE_NODE}"
    if [[ "$FORCE" -eq 1 ]]; then
      hv_delete_vm "$name"
    else
      sata="$(pve_config_value "$vmid" sata0)"
      if [[ -n "$sata" ]]; then
        log "VM ${name} already exists — skipping create (use --force to recreate)"
        return 0
      fi
      log "VM ${name} exists without its disk — importing $(basename "$src")"
      attach_disk "$name" "$vmid" "$src"
      return 0
    fi
  fi

  if owner="$(vmid_owner "$vmid")"; then
    die "Proxmox VMID ${vmid} is already ${owner}. Refusing to create ${name}."
  fi

  log "Creating VM ${name} (vmid=${vmid} ostype=${ostype} mem=${memory_mb}MB cpus=${cpus})"
  args=(
    vmid "$vmid"
    name "$name"
    memory "$memory_mb"
    cores "$cpus"
    ostype "$ostype"
    bios ovmf
    machine q35
    cpu host
    agent 1
    onboot 0
    net0 "$net0"
    efidisk0 "${PVE_STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
    description "Lab kit ${name}"
  )
  if [[ -n "$net1" ]]; then
    args+=(net1 "$net1")
  fi
  body="$(pve_form "${args[@]}")"
  pve_call POST "/nodes/$(pve_quote "$PVE_NODE")/qemu" --data "$body"
  pve_expect POST "/nodes/${PVE_NODE}/qemu"
  pve_follow "$PVE_RESPONSE"
  attach_disk "$name" "$vmid" "$src"
  log "Created ${name}"
}

attach_disk() {
  local name="$1" vmid="$2" src="$3" base body import
  base="$(basename "$src")"
  pve_upload "$src"
  import="${PVE_STORAGE}:0,import-from=${PVE_IMPORT_STORAGE}:import/${base}"
  log "Importing ${base} onto ${name} as SATA"
  # POST is the asynchronous config call. PUT runs the import inside the request,
  # and pveproxy closes that after 30 seconds with HTTP 596.
  body="$(pve_form sata0 "$import" boot "order=sata0")"
  pve_call POST "/nodes/$(pve_quote "$PVE_NODE")/qemu/${vmid}/config" --data "$body"
  pve_expect POST "/nodes/${PVE_NODE}/qemu/${vmid}/config"
  pve_follow "$PVE_RESPONSE"
  if [[ "${PVE_REMOVE_UPLOADS:-1}" == "1" ]]; then
    log "Removing uploaded ${base} from ${PVE_IMPORT_STORAGE}"
    pve_delete_import "$base"
  fi
}

smoke_one() {
  local name="$1" row vmid
  row="$(pve_find_name "$name")" || die "Smoke: ${name} is not registered"
  vmid="${row%%$'\t'*}"
  log "Smoke: starting ${name}. This does not wait for the QEMU guest agent."
  pve_power "$vmid" start
  log "Smoke: powering off ${name}"
  pve_power "$vmid" stop
  log "Smoke: ${name} OK"
}

log "Proxmox node=${PVE_NODE} import=${PVE_IMPORT_STORAGE} disks=${PVE_STORAGE} bridge=${PVE_BRIDGE}"
log "CONVERT_DIR=$CONVERT_DIR"

upload_paths=()
while IFS=$'\t' read -r name role memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue
  src="$(converted_disk "$disk")"
  [[ -f "$src" ]] || die "Converted disk missing: ${src} (run phase 2 first)"
  upload_paths+=("$src")
done <"$TOPOLOGY_FILE"
pve_plan_uploads "${upload_paths[@]}"
pve_check_copy

created=()
while IFS=$'\t' read -r name role memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue
  create_one_vm "$name" "$memory_mb" "$cpus" "$disk" "$nic1" "$nic2"
  created+=("$name")
done <"$TOPOLOGY_FILE"

if [[ "$SMOKE" -eq 0 ]]; then
  log "Skipping smoke boot. Stage 5 starts the lab and waits for the QEMU guest agent."
fi
if [[ "$SMOKE" -eq 1 && ${#created[@]} -gt 0 ]]; then
  smoke_target=""
  for n in HYD-GW1 HYD-DC1 HYD-CM1; do
    for c in "${created[@]}"; do
      if [[ "$c" == "$n" ]]; then smoke_target="$n"; break 2; fi
    done
  done
  if [[ -z "$smoke_target" ]]; then
    smoke_target="${created[0]}"
  fi
  smoke_one "$smoke_target"
fi

marker_set "${MARKERS_DIR}/create-vms.done"
log "Phase 3 create complete (${#created[@]} VMs from topology)"
log "Proxmox node: ${PVE_NODE}"
