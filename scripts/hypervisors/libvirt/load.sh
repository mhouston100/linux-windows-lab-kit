#!/usr/bin/env bash
# libvirt backend. Local QEMU/KVM through virsh, same hv_* hooks as VirtualBox.

# shellcheck source=prereqs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prereqs.sh"
# shellcheck source=verify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify.sh"
# shellcheck source=guest-agent.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guest-agent.sh"

: "${LIBVIRT_URI:=qemu:///system}"

lv_virsh() {
  virsh -c "$LIBVIRT_URI" "$@"
}

lv_state_word() {
  case "$1" in
    running) printf 'running' ;;
    "shut off"|shutoff) printf 'poweroff' ;;
    paused) printf 'paused' ;;
    crashed) printf 'aborted' ;;
    *) printf '%s' "${1:-missing}" ;;
  esac
}

hv_disk_format() {
  printf '%s\n' qcow2
}

hv_vm_exists() {
  lv_virsh dominfo "$1" >/dev/null 2>&1
}

hv_vm_state() {
  local state
  if ! state="$(lv_virsh domstate "$1" 2>/dev/null)"; then
    printf 'missing'
    return 0
  fi
  lv_state_word "$state"
}

hv_delete_vm() {
  local name="$1" state
  hv_vm_exists "$name" || {
    log "VM ${name} is not registered"
    return 0
  }
  state="$(hv_vm_state "$name")"
  if [[ "$state" != "poweroff" && "$state" != "missing" ]]; then
    log "Stopping ${name} before delete"
    lv_virsh destroy "$name" >/dev/null || true
  fi
  log "Deleting VM ${name}"
  lv_virsh undefine "$name" --nvram >/dev/null
}

hv_close_lab_media() {
  return 0
}

hv_local_vm_dirs() {
  local name dest
  while IFS=$'\t' read -r name _ || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue
    dest="${VM_ROOT}/${name}"
    [[ -d "$dest" ]] && printf '%s\n' "$dest"
  done <"${ROOT_DIR}/config/topology.tsv"
}

hv_set_description() {
  lv_virsh desc "$1" --title "$1" -- "$2" >/dev/null
}

hv_description_ok() {
  local text
  text="$(lv_virsh desc "$1" 2>/dev/null || true)"
  [[ -n "$text" && "$text" != "No description for domain:"* ]]
}

hv_stage_needs_privileges() {
  [[ "$1" == "3" ]]
}

hv_prepare_privileged() {
  ga_sudo_begin
}

hv_finish_privileged() {
  [[ "${GA_PRIV_HOLD:-0}" == 1 ]] && return 0
  if declare -F ga_sudo_end >/dev/null; then
    ga_sudo_end
  fi
}
