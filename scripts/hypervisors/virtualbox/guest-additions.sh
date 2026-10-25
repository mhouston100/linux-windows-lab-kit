#!/usr/bin/env bash
# Before a lab VM is powered on, mount its VDI and plant Guest Additions plus
# a one-shot logon that installs them. After power-on, wait until VirtualBox
# reports the additions service. The mount, sudo helper, and hive tool are in
# scripts/lib/offline-disk.sh.
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/offline-disk.sh
source "${HV_DIR}/../../lib/offline-disk.sh"
# shellcheck source=../../lib/first-boot.sh
source "${HV_DIR}/../../lib/first-boot.sh"

ga_iso_path() {
  local cand listed=""
  if [[ -n "${VBOX_GUEST_ADDITIONS_ISO:-}" ]]; then
    if [[ -f "${VBOX_GUEST_ADDITIONS_ISO}" ]]; then
      printf '%s\n' "${VBOX_GUEST_ADDITIONS_ISO}"
      return 0
    fi
    return 1
  fi
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
  [[ -n "$pass" ]] || die "The kit account password is not set. scripts/lib/config.sh defines it."
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
    fb_runonce_record VBoxGuestAdditions
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
  [[ -n "${LAB_ADMIN_PASSWORD:-}" ]] || die "The kit account password is not set. scripts/lib/config.sh defines it."
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
  hive="$(find "$win" -maxdepth 4 -type f -ipath '*/system32/config/SOFTWARE' -print -quit)"
  if [[ -z "$hive" ]]; then
    warn "SOFTWARE hive not found on $name"
    return 1
  fi
  if ga_additions_present "$win"; then
    log "Guest Additions already on the $name disk"
  else
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
    if [[ ! -f "${hive}.before-ga" ]]; then
      cp -a -- "$hive" "${hive}.before-ga" || return 1
    fi
  fi
  fb_stage_files "$win" || return 1
  if fb_needs_registry "$win"; then
    log "Setting one-shot autologon and RunOnce on $name"
    ga_write_registry "$hive" || return 1
  fi
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
