#!/usr/bin/env bash
# Service a converted qcow2 on the kit machine before it is copied to the node.
# The virtio-serial driver, the QEMU guest agent, and an install script are put
# on the Windows volume, and the registry gets a one-shot autologon plus a
# RunOnce entry that starts the install script. The VM does not exist yet, so
# nothing is stopped, and the node is not touched. The mount, the sudo helper,
# and the hive tool are shared with VirtualBox in scripts/lib/offline-disk.sh.

PVE_GA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/offline-disk.sh
source "${PVE_GA_DIR}/../../lib/offline-disk.sh"
# shellcheck source=../../lib/first-boot.sh
source "${PVE_GA_DIR}/../../lib/first-boot.sh"

pve_ga_pick_from_listing() {
  python3 -c '
import re
import sys

prefs = [
    "vioserial/2k25/amd64",
    "vioserial/w11/amd64",
    "vioserial/2k22/amd64",
    "vioserial/w10/amd64",
    "vioser/w11/amd64",
    "vioser/w10/amd64",
    "vioser/2k22/amd64",
]
pat = re.compile(
    r"\s(\d+)\s+(?:[A-Z][a-z]{2}\s+\d+\s+\d{4}|\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+(.+)$"
)
files = {}
for line in sys.stdin:
    match = pat.search(line.rstrip("\n"))
    if not match:
        continue
    size = int(match.group(1))
    name = match.group(2).split(" link to ", 1)[0].lstrip("./")
    if size > 0:
        files[name] = size
msi = "guest-agent/qemu-ga-x86_64.msi"
for rel in prefs:
    if files.get(f"{rel}/vioser.inf", 0) <= 0:
        continue
    members = sorted(
        name
        for name, size in files.items()
        if name.startswith(rel + "/") and size > 0 and not name.lower().endswith(".pdb")
    )
    if msi not in files:
        sys.stderr.write("virtio-win ISO has no qemu-ga-x86_64.msi\n")
        sys.exit(2)
    for name in members:
        print(name)
    print(msi)
    sys.exit(0)
sys.stderr.write("virtio-win ISO has no vioser driver\n")
sys.exit(1)
'
}

# Extract the virtio-serial driver and qemu-ga MSI from the local ISO once per run.
pve_ga_prepare_files() {
  local iso="$1" base stamp want tree members inf dir
  local -a paths
  set -o pipefail
  command -v bsdtar >/dev/null 2>&1 || die "bsdtar is required to read the virtio-win ISO"
  [[ -f "$iso" ]] || return 1
  base="${TMP_DIR:-${TMPDIR:-/tmp}}/pve-ga-files"
  stamp="${base}/source"
  want="${iso} $(stat -c '%s %Y' "$iso")"
  if [[ -f "$stamp" && "$(<"$stamp")" == "$want" \
    && -s "${base}/payload/vioser/vioser.inf" \
    && -s "${base}/payload/vioser/vioser.sys" \
    && -s "${base}/payload/qemu-ga-x86_64.msi" ]]; then
    PVE_GA_LOCAL_STAGE="${base}/payload"
    return 0
  fi
  log "Reading the virtio-serial driver and the guest agent from the Virtio ISO"
  tree="$(mktemp -d "${TMPDIR:-/tmp}/pve-ga-iso.XXXXXX")"
  if ! members="$(bsdtar -tvf "$iso" | pve_ga_pick_from_listing)"; then
    rm -rf "$tree"
    die "Could not read the virtio-serial driver from ${iso}"
  fi
  mapfile -t paths <<< "$members"
  bsdtar -xf "$iso" -C "$tree" -- "${paths[@]}"
  inf="$(find "$tree" -type f -name vioser.inf -size +0c -print -quit)"
  if [[ -z "$inf" || ! -s "${tree}/guest-agent/qemu-ga-x86_64.msi" ]]; then
    rm -rf "$tree"
    die "The Virtio ISO did not yield a virtio-serial driver and qemu-ga-x86_64.msi"
  fi
  dir="$(dirname "$inf")"
  rm -rf "$base"
  mkdir -p "${base}/payload/vioser"
  find "$dir" -maxdepth 1 -type f ! -iname '*.pdb' -exec cp -a {} "${base}/payload/vioser/" \;
  cp -a "${tree}/guest-agent/qemu-ga-x86_64.msi" "${base}/payload/qemu-ga-x86_64.msi"
  rm -rf "$tree"
  if [[ ! -s "${base}/payload/vioser/vioser.inf" || ! -s "${base}/payload/vioser/vioser.sys" || ! -s "${base}/payload/qemu-ga-x86_64.msi" ]]; then
    rm -rf "$base"
    die "The extracted virtio-serial driver is incomplete"
  fi
  printf '%s\n' "$want" > "$stamp"
  PVE_GA_LOCAL_STAGE="${base}/payload"
}

# Registry values for the first boot, as NUL-separated key, name, type, data
# records for HiveSet. $1 user, $2 domain, $3 password.
pve_ga_registry_records() {
  local user="$1" domain="$2" pass="$3"
  # RunOnce runs first-boot.ps1 (addresses, RRAS, DHCP), which then starts
  # the tools installer. Windows deletes the value; the installer clears autologon.
  fb_runonce_record PveGuestAgent
  ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' 'AutoAdminLogon' sz '1'
  ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' 'DefaultUserName' sz "$user"
  ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' 'DefaultDomainName' sz "$domain"
  ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' 'DefaultPassword' sz "$pass"
  ga_hive_record 'Microsoft\Windows NT\CurrentVersion\Winlogon' 'AutoLogonCount' dword '1'
  ga_hive_record 'Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' dword '0'
  ga_hive_record 'Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' dword '0'
}

pve_ga_write_registry() {
  local hive="$1" reg user domain pass
  user="${LAB_ADMIN_USER:-Administrator}"
  domain="${LAB_DOMAIN:-}"
  pass="${LAB_ADMIN_PASSWORD:-}"
  [[ -n "$pass" ]] || die "The kit account password is not set. scripts/lib/config.sh defines it."
  case "$user$domain$pass" in
    *$'\n'*) die "Lab account fields cannot contain newlines." ;;
  esac
  ga_hive_tool
  reg="$(mktemp "${TMPDIR:-/tmp}/pve-ga-reg.XXXXXX")"
  chmod 600 "$reg"
  pve_ga_registry_records "$user" "$domain" "$pass" >"$reg"
  if ! dotnet "$GA_HIVE_TOOL" "$hive" <"$reg"; then
    rm -f "$reg"
    return 1
  fi
  rm -f "$reg"
}

# One hash of everything that is planted. A disk with the same hash is left
# alone. A new ISO, a new install script, or a new lab account plants again.
pve_ga_signature() {
  local stamp
  stamp="$(dirname "$PVE_GA_LOCAL_STAGE")/source"
  {
    cat "$stamp"
    sha256sum "${PVE_GA_DIR}/install-guest-agent.ps1" "${PVE_GA_DIR}/restore-held-services.ps1" \
      "$FB_SCRIPT" "$FB_NET"
    pve_ga_hold_patterns "${PVE_GA_NAME:-}"
    printf '%s\n%s\n%s\n' "${LAB_ADMIN_USER:-Administrator}" "${LAB_DOMAIN:-}" "${LAB_ADMIN_PASSWORD:-}"
  } | sha256sum | awk '{print $1}'
}

# Service-name patterns for guest $1 from config/hypervisors/proxmox/hold-services.tsv.
# Nothing is printed when PVE_HOLD is 0.
pve_ga_hold_patterns() {
  local file="${ROOT_DIR}/config/hypervisors/proxmox/hold-services.tsv"
  [[ "${PVE_HOLD:-1}" == 1 && -f "$file" ]] || return 0
  awk -F'\t' -v g="$1" '!/^#/ && NF >= 2 && $1 == g {print $2}' "$file"
}

# Disable the automatic services that match, in the SYSTEM hive of the mounted
# disk. The old start types are kept in the guest for restore-held-services.ps1.
pve_ga_hold_services() {
  local name="$1" win="$2" dir="$3" hive patterns held merged
  patterns="$(mktemp "${TMPDIR:-/tmp}/pve-ga-hold.XXXXXX")"
  pve_ga_hold_patterns "$name" >"$patterns"
  if [[ ! -s "$patterns" ]]; then
    rm -f "$patterns"
    return 0
  fi
  hive="$(find "$win" -maxdepth 4 -type f -ipath '*/system32/config/SYSTEM' -print -quit)"
  if [[ -z "$hive" ]]; then
    rm -f "$patterns"
    warn "SYSTEM hive not found on ${name}"
    return 1
  fi
  if [[ ! -f "${hive}.before-pve-ga" ]]; then
    cp -a -- "$hive" "${hive}.before-pve-ga" || { rm -f "$patterns"; return 1; }
  fi
  ga_hive_tool
  held="$(mktemp "${TMPDIR:-/tmp}/pve-ga-held.XXXXXX")"
  if ! dotnet "$GA_HIVE_TOOL" "$hive" --hold "$patterns" >"$held"; then
    rm -f "$patterns" "$held"
    return 1
  fi
  # A second plant finds those services already disabled. Keep the first record.
  merged="$(mktemp "${TMPDIR:-/tmp}/pve-ga-held.XXXXXX")"
  cat "${dir}/held-services.tsv" "$held" 2>/dev/null | awk -F'\t' 'NF >= 2 && !seen[$1]++' >"$merged"
  cp -- "$merged" "${dir}/held-services.tsv" || { rm -f "$patterns" "$held" "$merged"; return 1; }
  log "Disabled $(wc -l <"$held") services on ${name} until restore-services runs"
  rm -f "$patterns" "$held" "$merged"
}

# Runs with the disk mounted at $2. Sets PVE_GA_CHANGED=1 when it wrote.
pve_ga_plant_mounted() {
  local name="$1" mnt="$2" win dir hive sig held_keep
  PVE_GA_NAME="$name"
  win="$(ga_windows_dir "$mnt")" || {
    warn "Windows directory not found on ${name}"
    return 1
  }
  dir="${win}/Temp/pve-ga"
  sig="$(pve_ga_signature)" || return 1
  if [[ "${FB_FORCE:-0}" != 1 && -f "${dir}/planted" && "$(<"${dir}/planted")" == "$sig" ]]; then
    log "The QEMU guest agent is already on the ${name} disk"
    return 0
  fi
  hive="$(find "$win" -maxdepth 4 -type f -ipath '*/system32/config/SOFTWARE' -print -quit)"
  if [[ -z "$hive" ]]; then
    warn "SOFTWARE hive not found on ${name}"
    return 1
  fi
  log "Copying the virtio-serial driver and the guest agent onto ${name}"
  held_keep=""
  installed_keep=""
  if [[ -f "${dir}/held-services.tsv" ]]; then
    held_keep="$(mktemp "${TMPDIR:-/tmp}/pve-ga-held.XXXXXX")"
    cp -- "${dir}/held-services.tsv" "$held_keep" || return 1
  fi
  if [[ -f "${dir}/installed.ok" ]]; then
    installed_keep="$(mktemp "${TMPDIR:-/tmp}/pve-ga-ok.XXXXXX")"
    cp -- "${dir}/installed.ok" "$installed_keep" || return 1
  fi
  rm -rf "$dir"
  mkdir -p "$dir" || return 1
  cp -a "${PVE_GA_LOCAL_STAGE}/." "${dir}/" || return 1
  cp -a "${PVE_GA_DIR}/install-guest-agent.ps1" "${dir}/install-guest-agent.ps1" || return 1
  cp -a "${PVE_GA_DIR}/restore-held-services.ps1" "${dir}/restore-held-services.ps1" || return 1
  fb_stage_files "$win" || return 1
  if [[ -n "$held_keep" ]]; then
    cp -- "$held_keep" "${dir}/held-services.tsv" || return 1
    rm -f "$held_keep"
  fi
  if [[ -n "$installed_keep" ]]; then
    cp -- "$installed_keep" "${dir}/installed.ok" || return 1
    rm -f "$installed_keep"
  fi
  pve_ga_hold_services "$name" "$win" "$dir" || return 1
  if [[ ! -f "${hive}.before-pve-ga" ]]; then
    cp -a -- "$hive" "${hive}.before-pve-ga" || return 1
  fi
  log "Setting one-shot autologon and RunOnce on ${name}"
  pve_ga_write_registry "$hive" || return 1
  printf '%s\n' "$sig" >"${dir}/planted" || return 1
  PVE_GA_CHANGED=1
}

# Plant the guest agent on a converted qcow2 that has never been booted.
# $1 guest name, $2 path to its qcow2.
pve_plant_disk() {
  local name="$1" disk="$2" mnt dev rc
  PVE_GA_CHANGED=0
  [[ -f "$disk" ]] || die "Converted disk missing: ${disk} (run phase 2 first)"
  [[ -n "${PVE_VIRTIO_ISO:-}" && -f "${PVE_VIRTIO_ISO}" ]] || die "Virtio ISO was not found: ${PVE_VIRTIO_ISO:-unset}"
  [[ -n "${LAB_ADMIN_PASSWORD:-}" ]] || die "The kit account password is not set. scripts/lib/config.sh defines it."
  [[ -n "${TMP_DIR:-}" ]] || die "TMP_DIR is not set. The disk is mounted under the lab temp directory."
  pve_ga_prepare_files "$PVE_VIRTIO_ISO"
  ga_hive_tool
  mnt="${TMP_DIR}/mnt/${name}"
  mkdir -p "$mnt"
  ga_sudo_begin
  log "Mounting the ${name} disk to plant the QEMU guest agent"
  ga_mount_disk "$disk" "$mnt" qcow2
  dev="$GA_NBD_DEV"
  set +e
  pve_ga_plant_mounted "$name" "$mnt"
  rc=$?
  set -e
  sync
  ga_unmount_disk "$mnt" "$dev"
  [[ "$rc" -eq 0 ]] || die "Could not plant the QEMU guest agent on ${name}"
  if [[ "$PVE_GA_CHANGED" -eq 1 ]]; then
    log "QEMU guest agent planted on ${name}"
  fi
}
