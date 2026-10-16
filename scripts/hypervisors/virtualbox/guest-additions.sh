#!/usr/bin/env bash
# Before a lab VM is powered on, mount its VDI and plant Guest Additions plus
# a one-shot logon that installs them. After power-on, wait until VirtualBox
# reports the additions service. sudo is used only to attach and mount the disk.
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    if [[ -r /dev/tty && -w /dev/tty ]]; then
      printf '\nPassword for sudo. Used only to mount guest disks. It is not stored.\n' >/dev/tty
      sudo -v </dev/tty >/dev/tty
    else
      sudo -v
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

ga_iso_path() {
  local cand listed=""
  if command -v VBoxManage >/dev/null 2>&1; then
    listed="$(VBoxManage list systemproperties 2>/dev/null \
      | sed -n 's/^Default Guest Additions ISO:[[:space:]]*//p' \
      | head -n 1)"
  fi
  for cand in \
    "$listed" \
    /usr/lib/virtualbox/additions/VBoxGuestAdditions.iso \
    /usr/share/virtualbox/VBoxGuestAdditions.iso
  do
    if [[ -n "$cand" && -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

ga_disk_path() {
  local name="$1" disk
  disk="$(VBoxManage showvminfo "$name" --machinereadable 2>/dev/null \
    | sed -n 's/^"SATA-0-0"="\(.*\)"$/\1/p')"
  [[ -n "$disk" && -f "$disk" ]] || return 1
  printf '%s\n' "$disk"
}

ga_vm_state() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null \
    | awk -F= '/^VMState=/{gsub(/"/,"",$2); print $2}' || true
}

# Print runlevel and version. Empty version means the service has not reported in.
# Levels from VirtualBox: 0 none, 1 drivers, 2 additions service, 3 desktop.
ga_additions_info() {
  local name="$1" info run ver
  info="$(VBoxManage showvminfo "$name" --machinereadable 2>/dev/null || true)"
  run="$(printf '%s\n' "$info" | awk -F= '/^GuestAdditionsRunLevel=/{gsub(/"/,"",$2); print $2; exit}')"
  ver="$(printf '%s\n' "$info" | awk -F= '/^GuestAdditionsVersion=/{gsub(/"/,"",$2); print $2; exit}')"
  printf '%s %s\n' "${run:-0}" "${ver:-}"
}

# Host-side switches for the additions features. The graphics controller and
# video memory are chosen when the VM is created. Auto-resize, the shared
# clipboard, and drag-and-drop are turned on once the guest service is up.
# A running VM accepts the clipboard and drag-and-drop through controlvm.
ga_enable_features() {
  local name="$1" state
  log "Enabling Guest Additions integration on $name"
  VBoxManage setextradata "$name" GUI/AutoresizeGuest true
  state="$(ga_vm_state "$name")"
  case "$state" in
    running|paused)
      VBoxManage controlvm "$name" clipboard mode bidirectional
      VBoxManage controlvm "$name" draganddrop bidirectional
      ;;
    *)
      VBoxManage modifyvm "$name" \
        --clipboard-mode bidirectional \
        --draganddrop bidirectional \
        --mouse usbtablet
      ;;
  esac
}

# The host can see this without guestcontrol. guestcontrol cannot install the
# additions the first time, because that channel does not exist until they do.
ga_additions_ready() {
  local info run ver
  info="$(ga_additions_info "$1")"
  run="${info%% *}"
  ver="${info#* }"
  [[ -n "$ver" && "$ver" != "None" && "${run:-0}" -ge 2 ]]
}

ga_extract_iso() {
  local iso dest
  [[ -n "${TMP_DIR:-}" ]] || die "TMP_DIR is not set. Guest Additions are extracted under the lab temp directory."
  iso="$(ga_iso_path)" || die "VirtualBox Guest Additions ISO not found."
  dest="${TMP_DIR}/cache/vbox-ga-iso"
  GA_ISO_DIR="$dest"
  if [[ -f "${dest}/VBoxWindowsAdditions-amd64.exe" && -f "${dest}/cert/VBoxCertUtil.exe" ]]; then
    log "Guest Additions already extracted: $dest"
    return 0
  fi
  mkdir -p "$dest"
  log "Extracting Guest Additions from $iso"
  7z x -y "-o${dest}" "$iso" \
    'VBoxWindowsAdditions.exe' \
    'VBoxWindowsAdditions-amd64.exe' \
    'cert/*' >/dev/null
  [[ -f "${dest}/VBoxWindowsAdditions-amd64.exe" ]] || die "ISO extract did not produce the installer"
  [[ -f "${dest}/cert/VBoxCertUtil.exe" ]] || die "ISO extract did not produce VBoxCertUtil.exe"
  log "Guest Additions files: $dest"
}

ga_dev_size() {
  local dev="$1" size
  size="$(blockdev --getsize64 "$dev" 2>/dev/null || true)"
  if [[ -z "$size" ]]; then
    size="$(ga_sudo blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  fi
  printf '%s\n' "${size:-0}"
}

# Mount the VDI's Windows NTFS volume at $2. Sets GA_NBD_DEV.
ga_mount_disk() {
  local disk="$1" mnt="$2" dev part fstype size best bestsize opts i
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
    if ! ga_try qemu-nbd --connect="$dev" --format=vdi -- "$disk"; then
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

ga_additions_present() {
  local win="$1" found
  found="$(find "$win" -maxdepth 6 -type f -iname 'VBoxService.exe' -print -quit 2>/dev/null || true)"
  [[ -n "$found" ]]
}

ga_write_registry() {
  local hive="$1" reg user domain pass tool
  user="${LAB_ADMIN_USER:-Administrator}"
  domain="${LAB_DOMAIN:-}"
  pass="${LAB_ADMIN_PASSWORD:-}"
  [[ -n "$pass" ]] || die "LAB_ADMIN_PASSWORD is empty. Set it in config/lab.env."
  case "$user$domain$pass" in
    *$'\n'*) die "Lab account fields cannot contain newlines." ;;
  esac
  ga_hive_tool
  tool="$GA_HIVE_TOOL"
  reg="$(mktemp /tmp/vbox-ga-reg.XXXXXX)"
  chmod 600 "$reg"
  {
    # HKLM RunOnce runs when LabAdmin is logged on by the one-shot autologon
    # below, then Windows deletes the value. The user hive is left alone.
    ga_hive_record 'Microsoft\Windows\CurrentVersion\RunOnce' \
      'VBoxGuestAdditions' sz \
      'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\vbox-ga\install-guest-additions.ps1'
    ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'AutoAdminLogon' sz '1'
    ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'DefaultUserName' sz "$user"
    ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'DefaultDomainName' sz "$domain"
    ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'DefaultPassword' sz "$pass"
    ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'AutoLogonCount' dword '1'
    ga_hive_record 'Microsoft\Windows\CurrentVersion\Policies\System' \
      'ConsentPromptBehaviorAdmin' dword '0'
    ga_hive_record 'Microsoft\Windows\CurrentVersion\Policies\System' \
      'PromptOnSecureDesktop' dword '0'
  } >"$reg"
  if ! dotnet "$tool" "$hive" <"$reg"; then
    rm -f "$reg"
    return 1
  fi
  rm -f "$reg"
}

# Plant the installer, the PowerShell script, RunOnce, and autologon.
# No-op when the VM is already running or additions are already on the disk.
ga_prepare_vm() {
  local name="$1" state disk mnt dev rc win staged staged_ps
  state="$(ga_vm_state "$name")"
  if [[ "$state" == "running" || "$state" == "paused" ]]; then
    log "$name is $state. Skipping offline Guest Additions setup."
    return 0
  fi
  if [[ "$state" == "missing" || -z "$state" ]]; then
    warn "$name is not registered. Skipping Guest Additions setup."
    return 0
  fi
  [[ -n "${LAB_ADMIN_PASSWORD:-}" ]] || die "LAB_ADMIN_PASSWORD is empty. Set it in config/lab.env."
  ga_hive_tool
  ga_extract_iso
  disk="$(ga_disk_path "$name")" || die "No SATA disk for $name"
  mnt="${TMP_DIR}/mnt/${name}"
  dev=""
  mkdir -p "$mnt"
  ga_sudo_begin
  log "Mounting $name disk for Guest Additions"
  ga_mount_disk "$disk" "$mnt"
  dev="$GA_NBD_DEV"
  set +e
  ga_prepare_mounted "$name" "$mnt"
  rc=$?
  set -e
  sync
  ga_unmount_disk "$mnt" "$dev"
  if [[ "$rc" -ne 0 ]]; then
    die "Guest Additions setup failed for $name"
  fi
  log "Guest Additions staged on $name"
}

ga_prepare_mounted() {
  local name="$1" mnt="$2" win staged staged_ps hive
  win="$(ga_windows_dir "$mnt")" || {
    warn "Windows directory not found on $name"
    return 1
  }
  if ga_additions_present "$win"; then
    log "Guest Additions already on the $name disk"
    return 0
  fi
  ga_extract_iso || return 1
  staged="$GA_ISO_DIR"
  staged_ps="${HV_DIR}/install-guest-additions.ps1"
  if [[ ! -f "$staged_ps" ]]; then
    warn "Missing $staged_ps"
    return 1
  fi
  log "Copying Guest Additions files onto $name"
  rm -rf "${win}/Temp/vbox-ga"
  mkdir -p "${win}/Temp/vbox-ga"
  cp -a "${staged}/." "${win}/Temp/vbox-ga/" || return 1
  cp -a "$staged_ps" "${win}/Temp/vbox-ga/install-guest-additions.ps1" || return 1
  hive="$(find "$win" -maxdepth 4 -type f -ipath '*/system32/config/SOFTWARE' -print -quit)"
  if [[ -z "$hive" ]]; then
    warn "SOFTWARE hive not found on $name"
    return 1
  fi
  if [[ ! -f "${hive}.before-ga" ]]; then
    cp -a -- "$hive" "${hive}.before-ga" || return 1
  fi
  log "Setting one-shot autologon and RunOnce on $name"
  ga_write_registry "$hive" || return 1
}

# Block until the guest reports additions, or GA_WAIT_SECONDS (default 30 min).
ga_wait_vm() {
  local name="$1" max="${GA_WAIT_SECONDS:-1800}" elapsed=0 off=0 info run ver state
  log "Waiting up to ${max}s for Guest Additions to report from $name"
  while [[ "$elapsed" -lt "$max" ]]; do
    state="$(ga_vm_state "$name")"
    if ga_additions_ready "$name"; then
      info="$(ga_additions_info "$name")"
      run="${info%% *}"
      ver="${info#* }"
      log "Guest Additions ${ver} are running on $name (run level ${run})"
      ga_enable_features "$name"
      return 0
    fi
    info="$(ga_additions_info "$name")"
    run="${info%% *}"
    if [[ "$state" == "poweroff" || "$state" == "aborted" ]]; then
      off=$((off + 10))
      if [[ "$off" -ge 120 && "$elapsed" -gt 60 ]]; then
        die "$name stayed off before Guest Additions reported in (last level ${run:-0})"
      fi
    else
      off=0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  die "Timed out waiting for Guest Additions on $name. Guest log: C:\\Windows\\Temp\\vbox-ga\\install.log"
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
      if [[ "$2" == --connect=* && "$3" == "--format=vdi" && "$4" == "--" ]]; then
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
  sudo -n bash "${HV_DIR}/guest-additions.sh" --root-helper "$GA_ROOT_DIR" &
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
