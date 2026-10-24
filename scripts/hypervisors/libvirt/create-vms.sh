#!/usr/bin/env bash
# libvirt: plant the QEMU guest agent on each converted qcow2 and create
# the server VMs with virt-install.

set -euo pipefail
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/config.sh
source "${HV_DIR}/../../lib/config.sh"
# shellcheck source=load.sh
source "${HV_DIR}/load.sh"

FORCE=0
DO_PROMPT=1
SMOKE=0
PLANT=1
PVE_HOLD=1
TOPOLOGY_FILE=""

usage() {
  cat <<'EOF'
Usage: create-lab-vms.sh [options]

  --force         Recreate VMs if they already exist
  --no-prompt     Use defaults / lab.env without path prompts
  --prompt        Force path prompts (default when interactive)
  --smoke         Boot the gateway once and power it off. Off by default
  --no-smoke      Skip the power-on test (the default)
  --no-hold       Leave the SQL Server and Configuration Manager services enabled
  --no-plant      Do not plant the guest agent on the disks
  --topology FILE Override topology TSV (default: config/topology.tsv)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --no-prompt) DO_PROMPT=0 ;;
    --prompt) DO_PROMPT=1 ;;
    --smoke) SMOKE=1 ;;
    --no-smoke) SMOKE=0 ;;
    --no-plant) PLANT=0 ;;
    --no-hold) PVE_HOLD=0 ;;
    --topology) TOPOLOGY_FILE="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config "$DO_PROMPT"
save_resolved_paths_hint
: "${LIBVIRT_URI:=qemu:///system}"
: "${LIBVIRT_VIRTIO_ISO:=${PVE_VIRTIO_ISO:-}}"
: "${PVE_VIRTIO_ISO:=${LIBVIRT_VIRTIO_ISO:-}}"
require_cmd virsh
require_cmd virt-install
require_cmd qemu-img

: "${TOPOLOGY_FILE:=${ROOT_DIR}/config/topology.tsv}"
[[ -f "$TOPOLOGY_FILE" ]] || die "Topology file not found: $TOPOLOGY_FILE"

CORPNET_NAME="${LAB_PREFIX}-${LAB_NETWORK_NAME}"

converted_disk() {
  local base="$1" stem
  stem="${base%.*}"
  printf '%s/%s.qcow2\n' "$CONVERT_DIR" "$stem"
}

ensure_corpnet() {
  if lv_virsh net-info "$CORPNET_NAME" >/dev/null 2>&1; then
    lv_virsh net-start "$CORPNET_NAME" >/dev/null 2>&1 || true
    return 0
  fi
  log "Defining isolated network ${CORPNET_NAME}"
  lv_virsh net-define /dev/stdin >/dev/null <<EOF
<network>
  <name>${CORPNET_NAME}</name>
  <bridge name="virbr-hyd" stp="on" delay="0"/>
</network>
EOF
  lv_virsh net-autostart "$CORPNET_NAME" >/dev/null
  lv_virsh net-start "$CORPNET_NAME" >/dev/null
}

ensure_default_net() {
  lv_virsh net-info default >/dev/null 2>&1 || die "libvirt network 'default' is missing. The gateway needs it for NAT."
  lv_virsh net-start default >/dev/null 2>&1 || true
}

place_disk() {
  local src="$1" dest="$2"
  ensure_dir "$(dirname "$dest")"
  if [[ -e "$dest" ]]; then
    log "Keeping existing disk $dest"
    return 0
  fi
  log "Placing disk → $dest"
  if cp --reflink=always -- "$src" "$dest" 2>/dev/null; then
    return 0
  fi
  cp -- "$src" "$dest" || die "Could not copy $src to $dest"
}

create_one_vm() {
  local name="$1" memory_mb="$2" cpus="$3" disk_basename="$4" nic1="$5" nic2="$6"
  local src dest
  src="$(converted_disk "$disk_basename")"
  [[ -f "$src" ]] || die "Converted disk missing: $src (run phase 2 first)"
  dest="${VM_ROOT}/${name}/${name}.qcow2"

  if hv_vm_exists "$name"; then
    if [[ "$FORCE" -eq 1 ]]; then
      hv_delete_vm "$name"
    else
      log "VM ${name} already exists — skipping create (use --force to recreate)"
      return 0
    fi
  fi

  place_disk "$src" "$dest"
  log "Creating VM ${name} (mem=${memory_mb}MB cpus=${cpus})"
  local -a args=(
    --connect "$LIBVIRT_URI"
    --name "$name"
    --memory "$memory_mb"
    --vcpus "$cpus"
    --cpu host-passthrough
    --boot uefi
    --os-variant win11
    --disk "path=${dest},format=qcow2,bus=sata"
    --import
    --noautoconsole
    --noreboot
    --graphics vnc,listen=127.0.0.1
  )
  if [[ "$nic1" != "corp" ]]; then
    die "Unsupported nic1='${nic1}' for ${name}"
  fi
  args+=(--network "network=${CORPNET_NAME},model=e1000")
  if [[ "$nic2" == "nat" ]]; then
    args+=(--network "network=default,model=e1000")
  elif [[ "$nic2" != "-" && -n "$nic2" ]]; then
    die "Unsupported nic2='${nic2}' for ${name}"
  fi
  virt-install "${args[@]}"
  log "Created ${name}"
}

smoke_one() {
  local name="$1"
  log "Smoke: starting ${name}. This does not wait for the QEMU guest agent."
  lv_virsh start "$name"
  log "Smoke: powering off ${name}"
  lv_virsh destroy "$name"
  log "Smoke: ${name} OK"
}

ensure_corpnet
ensure_default_net
log "URI=${LIBVIRT_URI} CorpNet=${CORPNET_NAME}"
log "CONVERT_DIR=$CONVERT_DIR VM_ROOT=$VM_ROOT"

plant_names=()
plant_paths=()
while IFS=$'\t' read -r name role memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue
  src="$(converted_disk "$disk")"
  [[ -f "$src" ]] || die "Converted disk missing: ${src} (run phase 2 first)"
  if [[ "$PLANT" -eq 1 ]]; then
    if hv_vm_exists "$name" && [[ "$FORCE" -ne 1 ]]; then
      continue
    fi
    plant_names+=("$name")
    plant_paths+=("$src")
  fi
done <"$TOPOLOGY_FILE"

for i in "${!plant_names[@]}"; do
  lv_plant_disk "${plant_names[$i]}" "${plant_paths[$i]}" </dev/null
done

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
  [[ -n "$smoke_target" ]] || smoke_target="${created[0]}"
  smoke_one "$smoke_target"
fi

marker_set "${MARKERS_DIR}/create-vms.done"
log "Phase 3 create complete (${#created[@]} VMs from topology)"
log "libvirt URI: ${LIBVIRT_URI}"
