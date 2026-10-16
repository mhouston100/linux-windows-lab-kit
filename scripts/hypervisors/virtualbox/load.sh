#!/usr/bin/env bash
# VirtualBox backend. A new hypervisor copies this directory and implements
# the same hv_* functions: check prereqs, disk format, verify a converted
# disk, verify created VMs, set a description, query and delete a VM, and
# say which stages need a privileged disk mount before boot.

# shellcheck source=prereqs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prereqs.sh"
# shellcheck source=verify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify.sh"
# shellcheck source=guest-additions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guest-additions.sh"

hv_disk_format() {
  printf '%s\n' vdi
}

hv_verify_disk() {
  VBoxManage showmediuminfo "$1" >/dev/null
}

hv_vm_exists() {
  VBoxManage showvminfo "$1" >/dev/null 2>&1
}

hv_vm_state() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null \
    | awk -F= '/^VMState=/{gsub(/"/,"",$2); print $2}' || true
}

hv_delete_vm() {
  local name="$1" state
  hv_vm_exists "$name" || return 0
  state="$(hv_vm_state "$name")"
  if [[ "$state" != "poweroff" && "$state" != "aborted" ]]; then
    VBoxManage controlvm "$name" poweroff || true
    sleep 2
  fi
  log "Deleting VM $name"
  VBoxManage unregistervm "$name" --delete
}

# Drop registered media whose files live under the given directories.
# Children are closed before their parents. The files themselves stay on disk
# until the caller removes those directories.
hv_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

hv_close_lab_media() {
  local -a roots=() uuids=() parents=() locs=() vbkinds=()
  local p line kind uuid="" parent="" loc="" norm root
  local i n j progress vbkind child

  for p in "$@"; do
    [[ -n "$p" && "$p" != "/" ]] || die "Refusing to close media for path: ${p:-<empty>}"
    if [[ -d "$p" ]]; then
      roots+=("$(readlink -f "$p")")
    else
      roots+=("$p")
    fi
  done
  [[ ${#roots[@]} -gt 0 ]] || return 0

  for kind in hdds dvds floppies; do
    case "$kind" in
      hdds) vbkind="disk" ;;
      dvds) vbkind="dvd" ;;
      floppies) vbkind="floppy" ;;
    esac
    uuid=""
    parent=""
    loc=""
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
      if [[ -z "$line" ]]; then
        if [[ -n "$uuid" && -n "$loc" ]]; then
          if [[ -e "$loc" ]]; then
            norm="$(readlink -f "$loc")"
          else
            norm="$loc"
          fi
          for root in "${roots[@]}"; do
            if [[ "$norm" == "$root" || "$norm" == "$root"/* ]]; then
              uuids+=("$uuid")
              parents+=("${parent:-base}")
              locs+=("$norm")
              vbkinds+=("$vbkind")
              break
            fi
          done
        fi
        uuid=""
        parent=""
        loc=""
        continue
      fi
      case "$line" in
        UUID:*) uuid="$(hv_trim "${line#UUID:}")" ;;
        "Parent UUID:"*) parent="$(hv_trim "${line#Parent UUID:}")" ;;
        Location:*) loc="$(hv_trim "${line#Location:}")" ;;
      esac
    done < <(VBoxManage list "$kind" 2>/dev/null || true)
    if [[ -n "$uuid" && -n "$loc" ]]; then
      if [[ -e "$loc" ]]; then
        norm="$(readlink -f "$loc")"
      else
        norm="$loc"
      fi
      for root in "${roots[@]}"; do
        if [[ "$norm" == "$root" || "$norm" == "$root"/* ]]; then
          uuids+=("$uuid")
          parents+=("${parent:-base}")
          locs+=("$norm")
          vbkinds+=("$vbkind")
          break
        fi
      done
    fi
  done

  [[ ${#uuids[@]} -gt 0 ]] || return 0
  while [[ ${#uuids[@]} -gt 0 ]]; do
    progress=0
    n=$((${#uuids[@]} - 1))
    for ((i = n; i >= 0; i--)); do
      # A parent cannot be unregistered while a child in this set still points at it.
      child=0
      for ((j = 0; j < ${#uuids[@]}; j++)); do
        [[ "${parents[$j]}" == "${uuids[$i]}" ]] && child=1
      done
      [[ "$child" -eq 1 ]] && continue
      log "Closing medium ${locs[$i]}"
      VBoxManage closemedium "${vbkinds[$i]}" "${uuids[$i]}"
      unset 'uuids[i]' 'parents[i]' 'locs[i]' 'vbkinds[i]'
      uuids=("${uuids[@]}")
      parents=("${parents[@]}")
      locs=("${locs[@]}")
      vbkinds=("${vbkinds[@]}")
      progress=1
      break
    done
    [[ "$progress" -eq 1 ]] || die "Could not close a lab disk that another disk still uses"
  done
}

hv_set_description() {
  VBoxManage modifyvm "$1" --description "$2" >/dev/null
}

hv_description_ok() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null | rg -q '^description=".+"'
}

hv_stage_needs_privileges() {
  [[ "$1" == "3" || "$1" == "5" ]]
}

hv_prepare_privileged() {
  ga_sudo_begin
  ga_sudo_keepalive_start
}

hv_finish_privileged() {
  if declare -F ga_sudo_keepalive_stop >/dev/null; then
    ga_sudo_keepalive_stop
  fi
}
