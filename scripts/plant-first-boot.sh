#!/usr/bin/env bash
# Re-plant first-boot.ps1 and RunOnce on existing local guest disks.
# The guests must be shut off. Does not convert disks or recreate VMs.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

DO_PROMPT=0
FROM_CONVERT=0
usage() {
  cat <<'EOF'
Usage: plant-first-boot.sh [--from-convert]

Mounts each topology disk on this machine, copies first-boot.ps1, and writes
the one-shot autologon plus RunOnce. Guests must be shut off.

libvirt/VirtualBox: the disks under VM_ROOT.
Proxmox: the converted qcow2 on this machine. Copy it to the node before start.

--from-convert  Plant the never-booted convert qcow2s, then replace VM_ROOT
                with those copies. Use this after a first boot you want to
                throw away. Does not convert again.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-prompt) DO_PROMPT=0 ;;
    --from-convert) FROM_CONVERT=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config "$DO_PROMPT"
: "${LIBVIRT_VIRTIO_ISO:=${PVE_VIRTIO_ISO:-}}"
: "${PVE_VIRTIO_ISO:=${LIBVIRT_VIRTIO_ISO:-}}"
FB_FORCE=1
hv_load
: "${TOPOLOGY_FILE:=${ROOT_DIR}/config/topology.tsv}"
[[ -f "$TOPOLOGY_FILE" ]] || die "Topology file not found: $TOPOLOGY_FILE"

converted_qcow2() {
  local base="$1"
  printf '%s/%s.qcow2\n' "$CONVERT_DIR" "${base%.*}"
}

plant_one() {
  local name="$1" disk="$2"
  case "$HYPERVISOR" in
    libvirt)
      dest="${VM_ROOT}/${name}/${name}.qcow2"
      if [[ "$FROM_CONVERT" -eq 1 ]]; then
        src="$(converted_qcow2 "$disk")"
        [[ -f "$src" ]] || die "Converted disk missing: ${src}"
        lv_plant_disk "$name" "$src"
        log "Replacing ${dest} from ${src}"
        cp -- "$src" "$dest" || die "Could not copy ${src} to ${dest}"
        lv_allow_qemu_disk "$dest"
      else
        [[ -f "$dest" ]] || dest="$(converted_qcow2 "$disk")"
        lv_plant_disk "$name" "$dest"
      fi
      ;;
    proxmox)
      dest="$(converted_qcow2 "$disk")"
      pve_plant_disk "$name" "$dest"
      log "Planted ${dest}. Copy that disk to the node before the next start."
      ;;
    virtualbox)
      ga_prepare_vm "$name"
      ;;
    *)
      die "plant-first-boot.sh does not support HYPERVISOR=${HYPERVISOR}"
      ;;
  esac
}

while IFS=$'\t' read -r name role memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue
  state="$(hv_vm_state "$name")"
  if [[ "$state" == "running" || "$state" == "paused" ]]; then
    die "${name} is ${state}. Stop the lab before planting first-boot."
  fi
  plant_one "$name" "$disk"
done <"$TOPOLOGY_FILE"

log "First-boot payload planted. Start the lab to run it (DC, then GW, then CM)."
