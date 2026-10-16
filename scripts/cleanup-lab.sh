#!/usr/bin/env bash
# Remove lab work. A full reset is --reset. Finer flags delete only one part.
# The kit ZIP is never deleted. VM names come from config/topology.tsv and must
# start with LAB_PREFIX, so a later run does not need a record of the last one.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
# shellcheck source=lib/cli.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cli.sh"

DO_PROMPT=0
YES=0
DELETE_VMS=0
DELETE_CONVERT=0
DELETE_TMP=0
DELETE_IDENTITY=0
DELETE_RESET=0

usage() {
  cat <<'EOF'
Usage: cleanup-lab.sh [options]

Destructive options require --yes (and interactive confirm unless LAB_NONINTERACTIVE=1).

  --vms           Unregister/delete VMs named in the topology
  --convert       Delete TMP_DIR/convert
  --tmp           Delete TMP_DIR/{zpaq,setup,organized,convert,identity,.markers}
  --identity      Delete TMP_DIR/identity only
  --all-work      Shortcut: --vms --tmp (keeps SOURCE_DIR and the kit ZIP)
  --reset         Delete topology VMs, their folders, SOURCE_DIR, and TMP_DIR except lab.log
  --yes           Required to actually delete
  --no-prompt     Skip path prompts
  --kit PATH      Lab ZIP. Kept. A reset refuses to delete a directory that contains it
  --dest DIR      Output root (source/ and tmp/ are under it)

The kit ZIP and TMP_DIR/lab.log are never removed.
EOF
}

parse_lab_cli "$@"
eval "$(lab_cli_restore_eval)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vms) DELETE_VMS=1 ;;
    --convert) DELETE_CONVERT=1 ;;
    --tmp) DELETE_TMP=1 ;;
    --identity) DELETE_IDENTITY=1 ;;
    --all-work) DELETE_VMS=1; DELETE_TMP=1 ;;
    --reset) DELETE_RESET=1 ;;
    --yes) YES=1 ;;
    --no-prompt) DO_PROMPT=0 ;;
    --prompt) DO_PROMPT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config "$DO_PROMPT"

if [[ "$DELETE_VMS$DELETE_CONVERT$DELETE_TMP$DELETE_IDENTITY$DELETE_RESET" == "00000" ]]; then
  usage
  die "Nothing selected — pass --vms / --tmp / --convert / --identity / --all-work / --reset and --yes"
fi

confirm() {
  local msg="$1"
  if [[ "$YES" -ne 1 ]]; then
    die "Refusing: pass --yes to confirm: $msg"
  fi
  if [[ "${LAB_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    log "Confirmed (--yes, noninteractive): $msg"
    return 0
  fi
  local reply
  read -r -p "Type YES to $msg: " reply
  [[ "$reply" == "YES" ]] || die "Aborted"
}

# Names this lab is allowed to remove. Re-read on every run.
lab_collect_vms() {
  local name
  LAB_VM_NAMES=()
  [[ -n "${LAB_PREFIX:-}" ]] || die "LAB_PREFIX is empty; refusing to choose VMs"
  [[ -f "${ROOT_DIR}/config/topology.tsv" ]] || die "Topology file is missing"
  while IFS=$'\t' read -r name _ || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Unsafe VM name in topology: ${name}"
    [[ "$name" == "${LAB_PREFIX}-"* ]] || die "Refusing ${name}; lab VMs must start with ${LAB_PREFIX}-"
    LAB_VM_NAMES+=("$name")
  done <"${ROOT_DIR}/config/topology.tsv"
  [[ ${#LAB_VM_NAMES[@]} -gt 0 ]] || die "Topology has no lab VMs"
}

lab_resolved() {
  local path="$1"
  if [[ -e "$path" ]]; then
    readlink -f "$path"
  else
    printf '%s' "$path"
  fi
}

# Refuse a delete that would take the VM root, the repo, or a kit archive.
lab_refuse_tree() {
  local path="$1" label="$2" real zip
  [[ -n "$path" && "$path" != "/" && "$path" != "." ]] || die "Refusing to delete ${label}: path is empty"
  [[ ! -L "$path" ]] || die "Refusing to delete ${label}: ${path} is a symlink"
  real="$(lab_resolved "$path")"
  [[ "$real" != "/" && -n "$real" ]] || die "Refusing to delete ${label}: ${path}"
  [[ -z "${HOME:-}" || "$real" != "$HOME" ]] || die "Refusing to delete ${label}: ${real}"
  [[ "$real" != "$ROOT_DIR" ]] || die "Refusing to delete ${label}: ${real}"
  [[ -n "${VM_ROOT:-}" && "$VM_ROOT" != "/" ]] || die "VM root is not a safe path"
  [[ "$real" != "$(lab_resolved "$VM_ROOT")" ]] || die "Refusing to delete the VM root (${real})"
  if [[ -n "${LAB_ZIP_PATH:-}" ]]; then
    zip="$(lab_resolved "$LAB_ZIP_PATH")"
    [[ -n "$zip" && "$zip" != "$real" && "$zip" != "$real"/* ]] || die "Refusing to delete ${label}: it contains the kit ZIP ${zip}"
  fi
  if [[ -n "${GUIDES_ZIP_PATH:-}" ]]; then
    zip="$(lab_resolved "$GUIDES_ZIP_PATH")"
    [[ -z "$zip" || "$zip" != "$real" && "$zip" != "$real"/* ]] || die "Refusing to delete ${label}: it contains the guides ZIP ${zip}"
  fi
}

lab_vm_folder() {
  local name="$1" root dir
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Unsafe VM name: ${name}"
  root="$(lab_resolved "$VM_ROOT")"
  dir="${root}/${name}"
  [[ "$dir" == "${root}/${name}" && "$dir" != "$root" ]] || die "Refusing VM folder ${dir}"
  printf '%s\n' "$dir"
}

lab_remove_tree() {
  local path="$1" label="$2" real parent base hold
  lab_refuse_tree "$path" "$label"
  if [[ ! -e "$path" ]]; then
    log "${label} already gone: ${path}"
    return 0
  fi
  real="$(lab_resolved "$path")"
  lab_refuse_tree "$real" "$label"
  parent="$(dirname "$real")"
  base="$(basename "$real")"
  [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || die "Refusing to stage removal of ${real}"
  hold="${parent}/.lab-removing-${base}.$$"
  [[ ! -e "$hold" && "$hold" != "$real" && "$hold" != "$parent" ]] || die "Refusing to stage removal at ${hold}"
  # Rename first. The menu writes tmp/lab.log while a reset runs, and rm
  # reports "Directory not empty" if that file is recreated in the same directory.
  log "Removing ${label}: ${real}"
  mv -- "$real" "$hold"
  rm -rf -- "$hold"
}

# Empty tmp but leave lab.log. The menu appends to that file during a reset,
# and the next run still needs the record of this one.
lab_clear_tmp_keep_log() {
  local entry name dotglob nullglob
  local log_file="${TMP_DIR}/lab.log"
  lab_refuse_tree "$TMP_DIR" "tmp"
  if [[ ! -d "$TMP_DIR" ]]; then
    log "tmp already gone: ${TMP_DIR}"
    return 0
  fi
  log "Clearing ${TMP_DIR} (keeping lab.log)"
  dotglob="$(shopt -p dotglob || true)"
  nullglob="$(shopt -p nullglob || true)"
  shopt -s dotglob nullglob
  for entry in "${TMP_DIR}"/*; do
    name="$(basename "$entry")"
    if [[ "$name" == "lab.log" && -f "$entry" && ! -L "$entry" ]]; then
      continue
    fi
    if [[ -L "$entry" ]]; then
      log "Removing symlink ${name}"
      rm -- "$entry"
      continue
    fi
    lab_remove_tree "$entry" "$name"
  done
  eval "$dotglob"
  eval "$nullglob"
  if [[ -f "$log_file" && ! -L "$log_file" ]]; then
    log "Kept ${log_file}"
  else
    log "No lab.log to keep under ${TMP_DIR}"
  fi
}

lab_delete_vms() {
  local name
  lab_collect_vms
  hv_load
  for name in "${LAB_VM_NAMES[@]}"; do
    if hv_vm_exists "$name"; then
      hv_delete_vm "$name"
    else
      log "VM ${name} is not registered"
    fi
  done
}

lab_reset() {
  local name dir
  local -a folders=() media_roots=()
  lab_collect_vms
  [[ -n "${LAB_ZIP_PATH:-}" ]] || die "LAB_ZIP_PATH is unset; refusing to reset"
  lab_refuse_tree "$SOURCE_DIR" "source"
  lab_refuse_tree "$TMP_DIR" "tmp"
  for name in "${LAB_VM_NAMES[@]}"; do
    dir="$(lab_vm_folder "$name")"
    lab_refuse_tree "$dir" "VM folder ${name}"
    folders+=("$dir")
  done

  confirm "reset this lab (VMs ${LAB_VM_NAMES[*]}, ${SOURCE_DIR}, and ${TMP_DIR} except lab.log). The kit ZIP is kept"
  lab_delete_vms

  media_roots=("$SOURCE_DIR" "$TMP_DIR" "${folders[@]}")
  declare -F hv_close_lab_media >/dev/null || die "This hypervisor cannot close lab disks"
  hv_close_lab_media "${media_roots[@]}"

  for dir in "${folders[@]}"; do
    lab_remove_tree "$dir" "VM folder"
  done
  lab_remove_tree "$SOURCE_DIR" "source"
  lab_clear_tmp_keep_log
  if [[ -n "${LAB_ZIP_PATH:-}" && -f "$LAB_ZIP_PATH" ]]; then
    log "Kit ZIP kept: ${LAB_ZIP_PATH}"
  else
    log "Kit ZIP path: ${LAB_ZIP_PATH:-<unset>}"
  fi
  log "Reset finished. The next run starts at stage 1."
}

if [[ "$DELETE_RESET" -eq 1 ]]; then
  lab_reset
  exit 0
fi

if [[ "$DELETE_VMS" -eq 1 ]]; then
  confirm "unregister and delete lab VMs under $VM_ROOT"
  lab_delete_vms
fi

if [[ "$DELETE_IDENTITY" -eq 1 && "$DELETE_TMP" -eq 0 ]]; then
  confirm "delete $TMP_DIR/identity"
  lab_refuse_tree "${TMP_DIR}/identity" "identity"
  rm -rf "${TMP_DIR}/identity"
fi

if [[ "$DELETE_CONVERT" -eq 1 && "$DELETE_TMP" -eq 0 ]]; then
  confirm "delete $CONVERT_DIR"
  lab_refuse_tree "$CONVERT_DIR" "convert"
  rm -rf "$CONVERT_DIR"
fi

if [[ "$DELETE_TMP" -eq 1 ]]; then
  confirm "delete transitive trees under $TMP_DIR (zpaq/setup/organized/convert/identity/markers)"
  for dir in zpaq setup organized convert identity .markers; do
    lab_refuse_tree "${TMP_DIR}/${dir}" "$dir"
  done
  rm -rf \
    "${TMP_DIR}/zpaq" \
    "${TMP_DIR}/setup" \
    "${TMP_DIR}/organized" \
    "${TMP_DIR}/convert" \
    "${TMP_DIR}/identity" \
    "${TMP_DIR}/.markers"
fi

log "SOURCE_DIR kept: $SOURCE_DIR"
log "Cleanup finished"
