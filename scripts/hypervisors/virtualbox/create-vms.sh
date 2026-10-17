#!/usr/bin/env bash
# VirtualBox: create networks and server VMs, place disks under VM_ROOT.

set -euo pipefail
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/config.sh
source "${HV_DIR}/../../lib/config.sh"

FORCE=0
DO_PROMPT=1
SMOKE=1
TOPOLOGY_FILE=""

usage() {
  cat <<'EOF'
Usage: create-lab-vms.sh [options]

  --force         Recreate VMs if they already exist (unregister + delete)
  --no-prompt     Use defaults / lab.env without path prompts
  --prompt        Force path prompts (default when interactive)
  --no-smoke      Skip headless power-on smoke test
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
require_cmd VBoxManage
# shellcheck source=guest-additions.sh
source "${HV_DIR}/guest-additions.sh"
save_resolved_paths_hint

: "${TOPOLOGY_FILE:=${ROOT_DIR}/config/topology.tsv}"
GUESTS_FILE="${ROOT_DIR}/config/hypervisors/virtualbox/guests.tsv"
[[ -f "$TOPOLOGY_FILE" ]] || die "Topology file not found: $TOPOLOGY_FILE"
[[ -f "$GUESTS_FILE" ]] || die "VirtualBox guest map not found: $GUESTS_FILE"

vb_ostype() {
  local want="$1" name ostype
  VB_OSTYPE=""
  while IFS=$'\t' read -r name ostype _ || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue
    if [[ "$name" == "$want" ]]; then
      VB_OSTYPE="$ostype"
      return 0
    fi
  done <"$GUESTS_FILE"
  return 1
}

CORPNET_NAME="${LAB_PREFIX}-${LAB_NETWORK_NAME}"
# VirtualBox internal network name (no spaces)
CORPNET_INTNET="${CORPNET_NAME}"

ensure_dir "$VM_ROOT"
ensure_dir "$CONVERT_DIR"

place_disk() {
  # A hardlink keeps the VirtualBox UUID, and VirtualBox will not register the
  # same UUID at two paths. Reflink on btrfs is a cheap copy; sethduuid then
  # gives the VM its own medium. The converted file stays where phase 2 left it.
  local src="$1" dest="$2" new_uuid
  ensure_dir "$(dirname "$dest")"
  if [[ -e "$dest" && "$(stat -c '%i' "$src")" == "$(stat -c '%i' "$dest")" ]]; then
    log "Removing hardlink $dest (same disk UUID as the converted file)"
    rm -f -- "$dest"
  fi
  if [[ -e "$dest" ]]; then
    log "Keeping existing disk $dest"
    return 0
  fi
  log "Placing disk → $dest"
  cp --reflink=always -- "$src" "$dest" || die "Reflink copy failed: $src → $dest"
  new_uuid="$(VBoxManage internalcommands sethduuid "$dest" | awk 'NF { print $NF }')"
  log "New disk UUID ${new_uuid:-assigned} for $dest"
}

disk_attached() {
  local name="$1" dest="$2"
  VBoxManage showvminfo "$name" --machinereadable | grep -F -q -- "$dest"
}

ensure_disk_attached() {
  local name="$1" dest_disk="$2"
  if ! VBoxManage showvminfo "$name" --machinereadable | grep -q '^storagecontrollername0='; then
    VBoxManage storagectl "$name" --name "SATA" --add sata --controller IntelAhci --portcount 4 --bootable on
  fi
  if disk_attached "$name" "$dest_disk"; then
    log "Disk already attached to $name"
    return 0
  fi
  VBoxManage storageattach "$name" \
    --storagectl "SATA" \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "$dest_disk"
  log "Attached $dest_disk to $name"
}

vm_exists() {
  VBoxManage showvminfo "$1" >/dev/null 2>&1
}

unregister_vm() {
  local name="$1"
  if vm_exists "$name"; then
    local state
    state="$(VBoxManage showvminfo "$name" --machinereadable | awk -F= '/^VMState=/{gsub(/"/,"",$2); print $2}')"
    if [[ "$state" != "poweroff" && "$state" != "aborted" ]]; then
      log "Powering off $name ($state)"
      VBoxManage controlvm "$name" poweroff || true
      sleep 2
    fi
    log "Unregistering VM $name"
    VBoxManage unregistervm "$name" --delete
  fi
}

create_one_vm() {
  local name="$1" ostype="$2" memory_mb="$3" cpus="$4" disk_basename="$5" nic1="$6" nic2="$7"

  local src_disk="${CONVERT_DIR}/${disk_basename}"
  [[ -f "$src_disk" ]] || die "Converted disk missing: $src_disk (run phase2 first)"

  local vm_dir="${VM_ROOT}/${name}"
  local dest_disk="${vm_dir}/${disk_basename}"

  if vm_exists "$name"; then
    if [[ "$FORCE" -eq 1 ]]; then
      unregister_vm "$name"
    elif disk_attached "$name" "${vm_dir}/${disk_basename}"; then
      log "VM $name already exists — skipping create (use --force to recreate)"
      return 0
    else
      log "VM $name exists without its disk — attaching $disk_basename"
      ensure_dir "$vm_dir"
      place_disk "$src_disk" "$dest_disk"
      ensure_disk_attached "$name" "$dest_disk"
      return 0
    fi
  fi

  ensure_dir "$vm_dir"
  place_disk "$src_disk" "$dest_disk"

  log "Creating VM $name (ostype=$ostype mem=${memory_mb}MB cpus=$cpus)"
  VBoxManage createvm --name "$name" --ostype "$ostype" --register --basefolder "$VM_ROOT"

  VBoxManage modifyvm "$name" \
    --memory "$memory_mb" \
    --cpus "$cpus" \
    --firmware efi \
    --vram 128 \
    --graphicscontroller vboxsvga \
    --boot1 disk \
    --boot2 none \
    --boot3 none \
    --boot4 none \
    --rtcuseutc on \
    --mouse usbtablet

  # NIC1: CorpNet (internal)
  if [[ "$nic1" == "corp" ]]; then
    VBoxManage modifyvm "$name" \
      --nic1 intnet \
      --intnet1 "$CORPNET_INTNET" \
      --nictype1 82540EM \
      --cableconnected1 on
  else
    die "Unsupported nic1='$nic1' for $name"
  fi

  # NIC2: optional NAT for Internet (gateway)
  if [[ "$nic2" == "nat" ]]; then
    VBoxManage modifyvm "$name" \
      --nic2 nat \
      --nictype2 82540EM \
      --cableconnected2 on
  elif [[ "$nic2" != "-" && -n "$nic2" ]]; then
    die "Unsupported nic2='$nic2' for $name"
  fi

  ensure_disk_attached "$name" "$dest_disk"
  ga_enable_features "$name"

  log "Created $name → $vm_dir"
}

smoke_one() {
  local name="$1" state
  ga_prepare_vm "$name"
  state="$(ga_vm_state "$name")"
  if [[ "$state" == "running" || "$state" == "paused" ]]; then
    log "Smoke: $name is already $state"
  else
    log "Smoke: starting $name headless"
    VBoxManage startvm "$name" --type headless
  fi
  ga_wait_vm "$name"
  log "Smoke: Guest Additions ready on $name — powering off"
  VBoxManage controlvm "$name" poweroff
  local i state
  for i in $(seq 1 30); do
    state="$(VBoxManage showvminfo "$name" --machinereadable | awk -F= '/^VMState=/{gsub(/"/,"",$2); print $2}')"
    if [[ "$state" == "poweroff" || "$state" == "aborted" ]]; then
      break
    fi
    sleep 1
  done
  log "Smoke: $name OK ($state)"
}

log "CorpNet internal network name: $CORPNET_INTNET"
log "VM_ROOT=$VM_ROOT CONVERT_DIR=$CONVERT_DIR"

created=()
while IFS=$'\t' read -r name role memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue
  vb_ostype "$name" || die "No VirtualBox ostype for $name in $GUESTS_FILE"
  create_one_vm "$name" "$VB_OSTYPE" "$memory_mb" "$cpus" "$disk" "$nic1" "$nic2"
  created+=("$name")
done <"$TOPOLOGY_FILE"

if [[ "$SMOKE" -eq 0 ]]; then
  log "Skipping smoke boot. A later start plants Guest Additions and boots the lab."
fi
if [[ "$SMOKE" -eq 1 && ${#created[@]} -gt 0 ]]; then
  # Prefer lightest VM for smoke (GW1) if present, else first
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
log "VirtualBox machine folder: $VM_ROOT"
