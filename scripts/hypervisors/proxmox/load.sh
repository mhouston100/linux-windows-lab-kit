#!/usr/bin/env bash
# Proxmox backend. Same hv_* hooks as VirtualBox. Disks are qcow2 copied
# with rsync into the import directory, then imported through the API.
# The API token never goes on a command line.

# shellcheck source=prereqs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prereqs.sh"
# shellcheck source=api.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/api.sh"
# shellcheck source=verify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify.sh"
# shellcheck source=guest-agent.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guest-agent.sh"

hv_disk_format() {
  printf '%s\n' qcow2
}

hv_vm_exists() {
  pve_prepare
  pve_find_name "$1" >/dev/null
}

hv_vm_state() {
  local row status
  pve_prepare
  if ! row="$(pve_find_name "$1")"; then
    printf 'missing'
    return 0
  fi
  status="${row##*$'\t'}"
  pve_state_word "$status"
}

hv_delete_vm() {
  local name="$1" row vmid node status expected
  pve_prepare
  expected="$(pve_guest_row "$name" | awk -F'\t' '{print $1}')" || die "No Proxmox vmid for ${name}"
  if ! row="$(pve_find_name "$name")"; then
    log "VM ${name} is not registered"
    return 0
  fi
  IFS=$'\t' read -r vmid node status <<<"$row"
  [[ "$vmid" == "$expected" ]] || die "VM ${name} is VMID ${vmid}, not the lab id ${expected}. Refusing to delete it."
  [[ "$node" == "$PVE_NODE" ]] || die "VM ${name} is on node ${node}, not ${PVE_NODE}. Refusing to delete it."
  if [[ "$status" != "stopped" ]]; then
    log "Stopping ${name} before delete"
    pve_power "$vmid" stop
  fi
  pve_delete_vm "$name" "$vmid"
  pve_delete_import "${name}.qcow2" || true
}

# Proxmox has no local medium registry. Drop the uploaded import copies.
# The guest disks themselves are removed with the VM.
hv_close_lab_media() {
  local name
  pve_prepare
  while IFS=$'\t' read -r name _ || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue
    [[ "$name" == "${LAB_PREFIX}-"* ]] || continue
    log "Removing import image ${name}.qcow2 if it is still on ${PVE_IMPORT_STORAGE}"
    pve_delete_import "${name}.qcow2" || true
  done <"${ROOT_DIR}/config/topology.tsv"
}

# No local machine folders. Reset must not delete a VirtualBox directory
# that happens to sit under VM_ROOT.
hv_local_vm_dirs() {
  return 0
}

hv_set_description() {
  local name="$1" text="$2" row vmid body
  pve_prepare
  row="$(pve_find_name "$name")" || die "VM ${name} is not registered"
  vmid="${row%%$'\t'*}"
  body="$(pve_form description "$text")"
  pve_call PUT "/nodes/$(pve_quote "$PVE_NODE")/qemu/${vmid}/config" --data "$body"
  pve_expect PUT "/nodes/${PVE_NODE}/qemu/${vmid}/config"
}

hv_description_ok() {
  local row vmid text
  pve_prepare
  row="$(pve_find_name "$1")" || return 1
  vmid="${row%%$'\t'*}"
  text="$(pve_config_value "$vmid" description)"
  [[ -n "$text" ]]
}

# Stage 3 mounts each converted disk to plant the guest agent. Nothing else
# on Proxmox needs sudo.
hv_stage_needs_privileges() {
  [[ "$1" == "3" ]]
}

hv_prepare_privileged() {
  ga_sudo_begin
}

hv_finish_privileged() {
  # A full run holds the helper across stages. Do not stop it between them.
  [[ "${GA_PRIV_HOLD:-0}" == 1 ]] && return 0
  if declare -F ga_sudo_end >/dev/null; then
    ga_sudo_end
  fi
}
