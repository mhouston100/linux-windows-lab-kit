# Shared first-boot payload. Sourced by the VirtualBox and QEMU plants.
# Copies first-boot.ps1 plus guest-network.tsv onto the mounted Windows volume.

FB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FB_ROOT="${ROOT_DIR:-$(cd "${FB_LIB}/../.." && pwd)}"
FB_SCRIPT="${FB_ROOT}/scripts/guest/first-boot.ps1"
FB_NET="${FB_ROOT}/config/guest-network.tsv"
FB_RUNONCE='powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\lab-kit\first-boot.ps1'

fb_stage_files() {
  local win="$1"
  [[ -f "$FB_SCRIPT" ]] || return 1
  [[ -f "$FB_NET" ]] || return 1
  mkdir -p "${win}/Temp/lab-kit" || return 1
  cp -a "$FB_SCRIPT" "${win}/Temp/lab-kit/first-boot.ps1" || return 1
  cp -a "$FB_NET" "${win}/Temp/lab-kit/guest-network.tsv" || return 1
}

# Re-arm RunOnce when the operator asked, when first-boot has never run, or
# when the planted script does not match the tree.
fb_needs_registry() {
  local win="$1"
  [[ "${FB_FORCE:-0}" == 1 ]] && return 0
  [[ -f "${win}/Temp/lab-kit/first-boot.ok" ]] || return 0
  cmp -s "$FB_SCRIPT" "${win}/Temp/lab-kit/first-boot.ps1" || return 0
  return 1
}

fb_runonce_record() {
  local name="${1:-LabFirstBoot}"
  ga_hive_record 'Microsoft\Windows\CurrentVersion\RunOnce' \
    "$name" sz \
    "$FB_RUNONCE"
}
