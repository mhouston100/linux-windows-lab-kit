#!/usr/bin/env bash
# Plant the QEMU guest agent onto the disk the guest will boot.
# The VM is stopped first. SSH on the node mounts the volume.

PVE_GA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pve_ga_driver_rel() {
  local root="$1" rel
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

pve_ga_hive_tool() {
  local proj dll
  proj="${ROOT_DIR}/tools/HiveSet/HiveSet.csproj"
  dll="${ROOT_DIR}/tools/HiveSet/bin/Release/net10.0/HiveSet.dll"
  if [[ ! -f "$dll" ]]; then
    log "Building offline registry editor"
    dotnet build "$proj" -c Release -v q || die "HiveSet build failed"
  fi
  PVE_GA_HIVE_TOOL="$dll"
}

pve_ga_hive_record() {
  printf '%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "$4"
}

pve_ga_write_registry() {
  local hive="$1" reg user domain pass
  user="${LAB_ADMIN_USER:-LabAdmin}"
  domain="${LAB_DOMAIN:-Corp}"
  pass="${LAB_ADMIN_PASSWORD:-}"
  [[ -n "$pass" ]] || die "LAB_ADMIN_PASSWORD is empty. Set it in config/lab.env."
  case "$user$domain$pass" in
    *$'\n'*) die "Lab account fields cannot contain newlines." ;;
  esac
  pve_ga_hive_tool
  reg="$(mktemp "${TMPDIR:-/tmp}/pve-ga-reg.XXXXXX")"
  chmod 600 "$reg"
  {
    pve_ga_hive_record 'Microsoft\Windows\CurrentVersion\RunOnce' \
      'PveGuestAgent' sz \
      'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\pve-ga\install-guest-agent.ps1'
    pve_ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'AutoAdminLogon' sz '1'
    pve_ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'DefaultUserName' sz "$user"
    pve_ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'DefaultDomainName' sz "$domain"
    pve_ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'DefaultPassword' sz "$pass"
    pve_ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' \
      'AutoLogonCount' dword '1'
    pve_ga_hive_record 'Microsoft\Windows\CurrentVersion\Policies\System' \
      'ConsentPromptBehaviorAdmin' dword '0'
    pve_ga_hive_record 'Microsoft\Windows\CurrentVersion\Policies\System' \
      'PromptOnSecureDesktop' dword '0'
  } >"$reg"
  if ! dotnet "$PVE_GA_HIVE_TOOL" "$hive" <"$reg"; then
    rm -f "$reg"
    return 1
  fi
  rm -f "$reg"
}

pve_ga_rsync() {
  local rsh
  rsh="$(pve_rsync_shell)"
  rsync -a -e "$rsh" -- "$@"
}

pve_ga_disk_device() {
  local vmid="$1" sata storage vol record vg
  sata="$(pve_config_value "$vmid" sata0)"
  [[ -n "$sata" ]] || return 1
  sata="${sata%%,*}"
  storage="${sata%%:*}"
  vol="${sata#*:}"
  pve_call GET "/storage/$(pve_quote "$storage")"
  pve_expect GET "/storage/${storage}"
  record="$PVE_RESPONSE"
  vg="$(printf '%s' "$record" | python3 -c 'import json,sys
data=json.load(sys.stdin).get("data") or {}
print(data.get("vgname") or "")')"
  [[ -n "$vg" ]] || return 1
  printf '/dev/%s/%s\n' "$vg" "$vol"
}

pve_ga_copy_iso() {
  local src="$1"
  log "Copying Virtio ISO to the node"
  pve_ssh "mkdir -p /var/tmp/lab-pve-ga" || return 1
  pve_ga_rsync "$src" "${PVE_SSH_USER}@${PVE_SSH_HOST}:/var/tmp/lab-pve-ga/virtio-win.iso" || return 1
}

pve_ga_remote() {
  local script
  script="${PVE_GA_DIR}/plant-on-node.sh"
  pve_ssh "mkdir -p /var/tmp/lab-pve-ga" || return 1
  pve_ga_rsync "$script" "${PVE_SSH_USER}@${PVE_SSH_HOST}:/var/tmp/lab-pve-ga/plant-on-node.sh" || return 1
  pve_ssh "bash /var/tmp/lab-pve-ga/plant-on-node.sh $(printf '%q ' "$@")"
}

# Stop the guest when it is up, mount its disk on the node, and plant the agent.
pve_plant_agent() {
  local name="$1" vmid state device iso stage mnt info nbd hive win local_hive quoted row t
  trap pve_ga_cleanup EXIT
  row="$(pve_guest_row "$name")" || die "No Proxmox guest id for ${name}"
  vmid="${row%%$'\t'*}"
  state="$(hv_vm_state "$name")"
  if [[ "$state" == "running" || "$state" == "paused" ]]; then
    log "Stopping ${name} so the guest agent can be planted on its disk"
    pve_power "$vmid" stop
    t=0
    while [[ "$t" -lt 60 ]]; do
      state="$(hv_vm_state "$name")"
      [[ "$state" == "poweroff" ]] && break
      sleep 1
      t=$((t + 1))
    done
  fi
  [[ "$state" == "poweroff" || "$state" == "stopped" ]] || die "${name} is ${state}. The guest agent is planted only while the VM is stopped."
  device="$(pve_ga_disk_device "$vmid")" || die "No LVM disk device for ${name}. The guest agent plant uses the volume behind sata0."
  [[ -n "${PVE_VIRTIO_ISO:-}" && -f "${PVE_VIRTIO_ISO}" ]] || die "Virtio ISO was not found: ${PVE_VIRTIO_ISO:-unset}"
  pve_ga_copy_iso "${PVE_VIRTIO_ISO}" || die "Could not copy the Virtio ISO to the node."
  iso="/var/tmp/lab-pve-ga/virtio-win.iso"
  stage="/var/tmp/lab-pve-ga/${name}"
  mnt="/var/tmp/lab-pve-ga/mnt-${name}"
  log "Staging virtio-serial and the guest agent for ${name}"
  pve_ga_remote stage-iso "$iso" "$stage" >/dev/null
  pve_ga_rsync "${PVE_GA_DIR}/install-guest-agent.ps1" \
    "${PVE_SSH_USER}@${PVE_SSH_HOST}:${stage}/install-guest-agent.ps1"
  info="$(pve_ga_remote mount "$device" "$mnt")"
  nbd="$(printf '%s\n' "$info" | awk '$1=="NBD" {print $2}')"
  hive="$(printf '%s\n' "$info" | awk '$1=="HIVE" {print $2}')"
  win="$(printf '%s\n' "$info" | awk '$1=="WIN" {print $2}')"
  PVE_GA_MNT="$mnt"
  PVE_GA_NBD="$nbd"
  if [[ -n "$nbd" ]]; then
    PVE_GA_MOUNTED=1
  fi
  if [[ -z "$nbd" || -z "$hive" || -z "$win" ]]; then
    pve_ga_cleanup
    die "The node did not mount the Windows volume on ${name}"
  fi
  if pve_ssh "test -f $(printf '%q' "${win}/Temp/pve-ga/install-guest-agent.ps1") && test -f $(printf '%q' "${win}/Temp/pve-ga/qemu-ga-x86_64.msi")"; then
    log "Guest agent files are already on the ${name} disk"
    pve_ga_cleanup
    return 0
  fi
  quoted="$(printf '%q' "${win}/Temp/pve-ga")"
  pve_ssh "rm -rf ${quoted} && mkdir -p ${quoted} && cp -a $(printf '%q' "${stage}/.") ${quoted}/"
  if ! pve_ssh "test -f $(printf '%q' "${hive}.before-pve-ga")"; then
    pve_ssh "cp -a -- $(printf '%q' "$hive") $(printf '%q' "${hive}.before-pve-ga")"
  fi
  local_hive="$(mktemp "${TMPDIR:-/tmp}/pve-ga-hive.XXXXXX")"
  chmod 600 "$local_hive"
  pve_ga_rsync "${PVE_SSH_USER}@${PVE_SSH_HOST}:${hive}" "$local_hive"
  log "Setting one-shot autologon and RunOnce on ${name}"
  if ! pve_ga_write_registry "$local_hive"; then
    rm -f "$local_hive"
    pve_ga_cleanup
    die "Could not write the RunOnce autologon on ${name}"
  fi
  pve_ga_rsync "$local_hive" "${PVE_SSH_USER}@${PVE_SSH_HOST}:${hive}"
  rm -f "$local_hive"
  pve_ga_cleanup
  log "Guest agent staged on ${name}"
}

pve_ga_cleanup() {
  if [[ -n "${PVE_GA_MOUNTED:-}" ]]; then
    pve_ga_remote unmount "${PVE_GA_MNT}" "${PVE_GA_NBD}" >/dev/null || true
    PVE_GA_MOUNTED=""
  fi
}
