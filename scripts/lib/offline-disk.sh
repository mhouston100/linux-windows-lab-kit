#!/usr/bin/env bash
# Shared by every hypervisor that services a guest disk on the kit machine
# before the guest boots. The disk is attached with qemu-nbd, its Windows
# volume is mounted, and the SOFTWARE hive is edited offline with HiveSet.
# sudo is used only for the device and mount calls, through one helper that
# the menu starts once and every stage reuses.
#
# Source this file. Run it directly only as the root helper:
#   sudo bash offline-disk.sh --root-helper DIR
OFFLINE_DISK_SELF="${BASH_SOURCE[0]}"
case "$OFFLINE_DISK_SELF" in
  /*) ;;
  *) OFFLINE_DISK_SELF="$(cd "$(dirname "$OFFLINE_DISK_SELF")" && pwd)/$(basename "$OFFLINE_DISK_SELF")" ;;
esac

# Run a device or mount command. Try as the current user first. sudo is only
# the fallback, and only through a helper started on the real terminal — the
# menu's captured stage does not have a keyboard.
ga_sudo() {
  if [[ -n "${GA_ROOT_DIR:-}" && -f "${GA_ROOT_DIR}/run" ]]; then
    ga_root_call "$@"
    return $?
  fi
  sudo -n "$@"
}

ga_try() {
  if "$@" 2>/dev/null; then
    return 0
  fi
  ga_sudo "$@"
}

ga_sudo_begin() {
  if [[ -n "${GA_ROOT_DIR:-}" && -f "${GA_ROOT_DIR}/run" ]]; then
    return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    log "Administrator password needed to mount guest disks. It is not stored."
    if { : >/dev/tty; } 2>/dev/null; then
      printf '\nPassword for sudo. Used only to mount guest disks. It is not stored.\n' >/dev/tty
      sudo -v </dev/tty >/dev/tty || die "sudo was not accepted."
    else
      die "No administrator password is available for the disk mount."
    fi
  fi
  ga_root_start
}

# Stop the mount helper. The sudo ticket is not refreshed: after sudo's own
# timeout, passwordless sudo ends. Mounts keep working through the helper
# until this runs.
ga_sudo_end() {
  ga_root_stop
}

ga_hive_tool() {
  local proj dll
  GA_HIVE_TOOL=""
  proj="${ROOT_DIR}/tools/HiveSet/HiveSet.csproj"
  dll="${ROOT_DIR}/tools/HiveSet/bin/Release/net10.0/HiveSet.dll"
  if [[ ! -f "$dll" ]]; then
    log "Building offline registry editor"
    dotnet build "$proj" -c Release -v q || die "HiveSet build failed"
  fi
  GA_HIVE_TOOL="$dll"
}

ga_hive_record() {
  printf '%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "$4"
}

ga_dev_size() {
  local dev="$1" size
  size="$(blockdev --getsize64 "$dev" 2>/dev/null || true)"
  if [[ -z "$size" ]]; then
    size="$(ga_sudo blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  fi
  printf '%s\n' "${size:-0}"
}

# Mount the disk's Windows NTFS volume at $2. $3 is the image format, vdi or
# qcow2, and defaults to GA_DISK_FORMAT or vdi. Sets GA_NBD_DEV.
ga_mount_disk() {
  local disk="$1" mnt="$2" format="${3:-${GA_DISK_FORMAT:-vdi}}" dev part fstype size best bestsize opts i
  case "$format" in
    vdi|qcow2) ;;
    *) die "Cannot mount a ${format} disk for offline servicing" ;;
  esac
  if [[ ! -b /dev/nbd0 ]]; then
    ga_sudo modprobe nbd max_part=16
  fi
  best=""
  bestsize=0
  GA_NBD_DEV=""
  for dev in /dev/nbd{0..15}; do
    [[ -b "$dev" ]] || continue
    if [[ "$(ga_dev_size "$dev")" != "0" ]]; then
      continue
    fi
    if ! ga_try qemu-nbd --connect="$dev" --format="$format" -- "$disk"; then
      continue
    fi
    for i in $(seq 1 20); do
      compgen -G "${dev}p*" >/dev/null && break
      if [[ "$i" -eq 5 ]]; then
        ga_try partprobe "$dev" || true
      fi
      sleep 0.2
    done
    for part in "${dev}p"*; do
      [[ -b "$part" ]] || continue
      fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
      if [[ -z "$fstype" ]]; then
        fstype="$(ga_sudo blkid -o value -s TYPE "$part" 2>/dev/null || true)"
      fi
      [[ "$fstype" == "ntfs" ]] || continue
      size="$(ga_dev_size "$part")"
      if [[ "$size" -gt "$bestsize" ]]; then
        best="$part"
        bestsize="$size"
      fi
    done
    if [[ -n "$best" ]]; then
      mkdir -p "$mnt"
      opts="uid=$(id -u),gid=$(id -g),windows_names"
      if ! ga_try ntfs-3g -o "$opts" "$best" "$mnt"; then
        log "NTFS was not cleanly unmounted. Clearing the hibernation file and mounting read-write."
        ga_sudo ntfs-3g -o "${opts},remove_hiberfile" "$best" "$mnt"
      fi
      GA_NBD_DEV="$dev"
      return 0
    fi
    ga_try qemu-nbd --disconnect "$dev" || true
  done
  die "No free NBD device or no NTFS partition on $disk"
}

ga_unmount_disk() {
  local mnt="$1" dev="$2"
  if mountpoint -q "$mnt" 2>/dev/null; then
    ga_try umount "$mnt" || ga_sudo umount -l "$mnt" || true
  fi
  if [[ -n "$dev" && -b "$dev" ]]; then
    ga_try qemu-nbd --disconnect "$dev" >/dev/null 2>&1 || true
  fi
  GA_NBD_DEV=""
}

ga_windows_dir() {
  local mnt="$1" found
  found="$(find "$mnt" -maxdepth 4 -type f -ipath '*/system32/config/SOFTWARE' -print -quit 2>/dev/null || true)"
  [[ -n "$found" ]] || return 1
  dirname "$(dirname "$(dirname "$found")")"
}

ga_root_nbd() {
  [[ "$1" =~ ^/dev/nbd[0-9]+$ ]]
}

ga_root_part() {
  [[ "$1" =~ ^/dev/nbd[0-9]+p[0-9]+$ ]]
}

ga_root_mountpoint() {
  local p="$1"
  [[ "$p" == /* && "$p" != *".."* && -d "$p" ]] || return 1
  case "$p" in
    /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/root|/sbin|/sys|/usr|/usr/*) return 1 ;;
  esac
}

ga_root_dispatch() {
  case "$1" in
    modprobe)
      [[ "$2" == "nbd" && "$3" == "max_part=16" && -z "${4:-}" ]] || return 99
      ;;
    qemu-nbd)
      if [[ "$2" == --connect=* && ( "$3" == "--format=vdi" || "$3" == "--format=qcow2" ) && "$4" == "--" ]]; then
        ga_root_nbd "${2#--connect=}" || return 99
        [[ -f "$5" && "$5" == /* && "$5" != *".."* && -z "${6:-}" ]] || return 99
      elif [[ "$2" == "--disconnect" ]]; then
        ga_root_nbd "$3" || return 99
        [[ -z "${4:-}" ]] || return 99
      else
        return 99
      fi
      ;;
    partprobe)
      ga_root_nbd "$2" || return 99
      [[ -z "${3:-}" ]] || return 99
      ;;
    blkid)
      [[ "$2" == "-o" && "$3" == "value" && "$4" == "-s" && "$5" == "TYPE" ]] || return 99
      ga_root_part "$6" || return 99
      [[ -z "${7:-}" ]] || return 99
      ;;
    blockdev)
      [[ "$2" == "--getsize64" ]] || return 99
      [[ "$3" =~ ^/dev/nbd[0-9]+(p[0-9]+)?$ && -z "${4:-}" ]] || return 99
      ;;
    ntfs-3g)
      [[ "$2" == "-o" && "$3" =~ ^uid=[0-9]+,gid=[0-9]+,windows_names(,remove_hiberfile)?$ ]] || return 99
      ga_root_part "$4" || return 99
      ga_root_mountpoint "$5" || return 99
      [[ -z "${6:-}" ]] || return 99
      ;;
    umount)
      if [[ "$2" == "-l" ]]; then
        ga_root_mountpoint "$3" || return 99
        [[ -z "${4:-}" ]] || return 99
      else
        ga_root_mountpoint "$2" || return 99
        [[ -z "${3:-}" ]] || return 99
      fi
      ;;
    *)
      return 99
      ;;
  esac
  "$@"
}

ga_root_call() {
  local dir="$GA_ROOT_DIR" rc i=0
  while ! mkdir "$dir/lock" 2>/dev/null; do
    i=$((i + 1))
    [[ "$i" -lt 200 ]] || die "Guest Additions mount helper is busy"
    sleep 0.05
  done
  printf '%q ' "$@" >"$dir/cmd.new"
  printf '\n' >>"$dir/cmd.new"
  mv "$dir/cmd.new" "$dir/cmd"
  i=0
  while [[ ! -f "$dir/reply" ]]; do
    i=$((i + 1))
    if [[ "$i" -gt 600 || ! -f "$dir/run" ]]; then
      rmdir "$dir/lock" 2>/dev/null || true
      die "Guest Additions mount helper did not answer"
    fi
    sleep 0.05
  done
  rc="$(head -n 1 "$dir/reply")"
  tail -n +2 "$dir/reply"
  if [[ -s "$dir/reply.err" ]]; then
    cat "$dir/reply.err" >&2
  fi
  rm -f "$dir/reply" "$dir/reply.err" "$dir/cmd"
  rmdir "$dir/lock"
  return "$rc"
}

ga_root_helper() {
  local dir="$1" owner rc
  local -a args=()
  [[ -d "$dir" && -f "$dir/run" && -f "$dir/owner.pid" ]] || exit 1
  owner="$(cat "$dir/owner.pid")"
  printf '%s\n' "$$" >"$dir/helper.pid"
  while [[ -f "$dir/run" ]] && kill -0 "$owner" 2>/dev/null; do
    if [[ -f "$dir/cmd" && ! -f "$dir/reply" ]]; then
      args=()
      eval "args=( $(cat "$dir/cmd") )"
      rc=0
      if ! ga_root_dispatch "${args[@]}" >"$dir/out" 2>"$dir/err"; then
        rc=$?
      fi
      { printf '%s\n' "$rc"; cat "$dir/out"; } >"$dir/reply.new"
      if [[ -s "$dir/err" ]]; then
        cp "$dir/err" "$dir/reply.err"
      fi
      mv "$dir/reply.new" "$dir/reply"
      rm -f "$dir/cmd" "$dir/out" "$dir/err"
    else
      sleep 0.05
    fi
  done
}

ga_root_start() {
  local i
  if [[ -n "${GA_ROOT_DIR:-}" && -f "${GA_ROOT_DIR}/run" ]]; then
    return 0
  fi
  GA_ROOT_DIR="$(mktemp -d /tmp/lab-ga.XXXXXX)"
  chmod 700 "$GA_ROOT_DIR"
  touch "$GA_ROOT_DIR/run"
  printf '%s\n' "$$" >"$GA_ROOT_DIR/owner.pid"
  export GA_ROOT_DIR
  sudo -n bash "$OFFLINE_DISK_SELF" --root-helper "$GA_ROOT_DIR" &
  GA_ROOT_PID=$!
  for i in $(seq 1 50); do
    [[ -s "$GA_ROOT_DIR/helper.pid" ]] && return 0
    sleep 0.1
  done
  die "Could not start the mount helper. Approve the sudo prompt and rerun."
}

ga_root_stop() {
  if [[ -n "${GA_ROOT_DIR:-}" && -d "${GA_ROOT_DIR}" ]]; then
    rm -f "$GA_ROOT_DIR/run"
    if [[ -n "${GA_ROOT_PID:-}" ]]; then
      wait "$GA_ROOT_PID" 2>/dev/null || true
    fi
    rm -rf "$GA_ROOT_DIR"
    GA_ROOT_DIR=""
    GA_ROOT_PID=""
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--root-helper" ]]; then
    ga_root_helper "${2:?}"
    exit $?
  fi
  printf 'This file is sourced by the lab scripts.\n' >&2
  exit 1
fi
