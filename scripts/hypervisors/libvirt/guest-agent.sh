#!/usr/bin/env bash
# Plant the QEMU guest agent on a local qcow2. The helpers live with the
# Proxmox backend; they only touch the disk on this machine.

# shellcheck source=../proxmox/guest-agent.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../proxmox/guest-agent.sh"

lv_plant_disk() {
  local name="$1" disk="$2"
  : "${PVE_VIRTIO_ISO:=${LIBVIRT_VIRTIO_ISO:-}}"
  [[ -n "${PVE_VIRTIO_ISO:-}" ]] || die "Set Virtio ISO to the virtio-win ISO you downloaded"
  pve_plant_disk "$name" "$disk"
}
