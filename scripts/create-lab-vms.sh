#!/usr/bin/env bash
# Phase 3: Create VirtualBox networks + server VMs; place disks under VM_ROOT.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

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
save_resolved_paths_hint

: "${TOPOLOGY_FILE:=${ROOT_DIR}/config/topology.tsv}"
[[ -f "$TOPOLOGY_FILE" ]] || die "Topology file not found: $TOPOLOGY_FILE"

CORPNET_NAME="${LAB_PREFIX}-${LAB_NETWORK_NAME}"
# VirtualBox internal network name (no spaces)
CORPNET_INTNET="${CORPNET_NAME}"

ensure_dir "$VM_ROOT"
ensure_dir "$CONVERT_DIR"

place_disk() {
  # Hardlink (same FS) preferred; else copy. Leaves CONVERT_DIR originals intact.
  local src="$1" dest="$2"
  ensure_dir "$(dirname "$dest")"
  if [[ -e "$dest" ]]; then
    if [[ "$(stat -c '%i' "$src" 2>/dev/null || true)" == "$(stat -c '%i' "$dest" 2>/dev/null || true)" ]]; then
      return 0
    fi
    # Same path content: if dest already registered/in use, keep it
    if cmp -s "$src" "$dest" 2>/dev/null; then
      return 0
    fi
    die "Disk already exists and differs: $dest"
  fi
  if ln "$src" "$dest" 2>/dev/null; then
    log "Hardlinked disk → $dest"
  else
    log "Copying disk → $dest (hardlink unavailable)"
    cp --reflink=auto "$src" "$dest"
  fi
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
    else
      log "VM $name already exists — skipping create (use --force to recreate)"
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
    --clipboard-mode bidirectional \
    --draganddrop disabled

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

  VBoxManage storagectl "$name" --name "SATA" --add sata --controller IntelAhci --portcount 4 --bootable on
  VBoxManage storageattach "$name" \
    --storagectl "SATA" \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "$dest_disk"

  log "Created $name → $vm_dir"
}

smoke_one() {
  local name="$1"
  log "Smoke: starting $name headless"
  VBoxManage startvm "$name" --type headless
  local i state
  for i in $(seq 1 30); do
    state="$(VBoxManage showvminfo "$name" --machinereadable | awk -F= '/^VMState=/{gsub(/"/,"",$2); print $2}')"
    if [[ "$state" == "running" ]]; then
      break
    fi
    sleep 1
  done
  if [[ "$state" != "running" ]]; then
    die "Smoke failed: $name did not reach running (state=$state)"
  fi
  log "Smoke: $name running — powering off"
  VBoxManage controlvm "$name" poweroff
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
while IFS=$'\t' read -r name role ostype memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue
  create_one_vm "$name" "$ostype" "$memory_mb" "$cpus" "$disk" "$nic1" "$nic2"
  created+=("$name")
done <"$TOPOLOGY_FILE"

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
