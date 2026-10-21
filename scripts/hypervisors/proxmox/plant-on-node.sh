#!/usr/bin/env bash
# Runs on the Proxmox node. Mounts virtio-win and the guest's raw disk.
# The kit calls one action per SSH session. stdout is machine-readable.

set -euo pipefail

usage() {
  echo "Usage: plant-on-node.sh stage-iso ISO DEST | mount DEVICE MOUNT | unmount MOUNT NBD" >&2
  exit 2
}

driver_rel() {
  local root="$1" rel
  # The ISO directory is vioserial. w11 is often a zero-length hardlink to 2k25,
  # so a non-empty inf wins. Older images used vioser.
  for rel in \
    vioserial/2k25/amd64 \
    vioserial/w11/amd64 \
    vioserial/2k22/amd64 \
    vioserial/w10/amd64 \
    vioser/w11/amd64 \
    vioser/w10/amd64 \
    vioser/2k22/amd64
  do
    if [[ -s "${root}/${rel}/vioser.inf" ]]; then
      printf '%s\n' "$rel"
      return 0
    fi
  done
  return 1
}

stage_iso() {
  local iso="$1" dest="$2" mnt rel
  [[ -f "$iso" ]] || { echo "ISO missing: ${iso}" >&2; exit 1; }
  mkdir -p "$dest"
  mnt="$(mktemp -d /tmp/lab-virtio.XXXXXX)"
  mount -o loop,ro -- "$iso" "$mnt"
  if ! rel="$(driver_rel "$mnt")"; then
    umount "$mnt" || true
    rmdir "$mnt" || true
    echo "virtio-win ISO has no vioser driver" >&2
    exit 1
  fi
  if [[ ! -f "${mnt}/guest-agent/qemu-ga-x86_64.msi" ]]; then
    umount "$mnt" || true
    rmdir "$mnt" || true
    echo "virtio-win ISO has no qemu-ga-x86_64.msi" >&2
    exit 1
  fi
  rm -rf "${dest}/vioser"
  mkdir -p "${dest}/vioser"
  cp -a "${mnt}/${rel}/." "${dest}/vioser/"
  cp -a "${mnt}/guest-agent/qemu-ga-x86_64.msi" "${dest}/"
  umount "$mnt"
  rmdir "$mnt" || true
  echo "STAGED ${dest}"
}

pick_nbd() {
  local dev size
  modprobe nbd max_part=16 || true
  for dev in /dev/nbd{0..15}; do
    [[ -b "$dev" ]] || continue
    size="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    if [[ "$size" == "0" ]]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done
  return 1
}

mount_disk() {
  local disk="$1" mnt="$2" nbd part fstype size best bestsize i hive win
  [[ -b "$disk" ]] || { echo "Disk device missing: ${disk}" >&2; exit 1; }
  nbd="$(pick_nbd)" || { echo "No free NBD device" >&2; exit 1; }
  qemu-nbd --connect="$nbd" --format=raw -- "$disk"
  best=""
  bestsize=0
  for i in $(seq 1 25); do
    compgen -G "${nbd}p*" >/dev/null && break
    partprobe "$nbd" >/dev/null 2>&1 || true
    sleep 0.2
  done
  for part in "${nbd}p"*; do
    [[ -b "$part" ]] || continue
    fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
    [[ "$fstype" == "ntfs" ]] || continue
    size="$(blockdev --getsize64 "$part" 2>/dev/null || echo 0)"
    if [[ "$size" -gt "$bestsize" ]]; then
      best="$part"
      bestsize="$size"
    fi
  done
  if [[ -z "$best" ]]; then
    qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
    echo "No NTFS partition on ${disk}" >&2
    exit 1
  fi
  mkdir -p "$mnt"
  if ! mount -t ntfs3 "$best" "$mnt" 2>/dev/null; then
    if ! command -v ntfs-3g >/dev/null 2>&1 || ! ntfs-3g -o remove_hiberfile "$best" "$mnt"; then
      qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
      echo "Could not mount NTFS on ${best}" >&2
      exit 1
    fi
  fi
  hive="$(find "$mnt" -maxdepth 4 -type f -ipath '*/system32/config/SOFTWARE' -print -quit 2>/dev/null || true)"
  if [[ -z "$hive" ]]; then
    umount "$mnt" || true
    qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
    echo "Windows directory not found on ${disk}" >&2
    exit 1
  fi
  win="$(dirname "$(dirname "$(dirname "$hive")")")"
  echo "NBD ${nbd}"
  echo "HIVE ${hive}"
  echo "WIN ${win}"
}

unmount_disk() {
  local mnt="$1" nbd="$2"
  if mountpoint -q "$mnt" 2>/dev/null; then
    umount "$mnt"
  fi
  if [[ -n "$nbd" && -b "$nbd" ]]; then
    qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
  fi
  echo "UNMOUNTED"
}

[[ $# -ge 1 ]] || usage
case "$1" in
  stage-iso) [[ $# -eq 3 ]] || usage; stage_iso "$2" "$3" ;;
  mount) [[ $# -eq 3 ]] || usage; mount_disk "$2" "$3" ;;
  unmount) [[ $# -eq 3 ]] || usage; unmount_disk "$2" "$3" ;;
  *) usage ;;
esac
