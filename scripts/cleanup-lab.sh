#!/usr/bin/env bash
# Phase 6: Cleanup with explicit confirmations. Never deletes SOURCE ZIP by default.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

DO_PROMPT=0
YES=0
DELETE_VMS=0
DELETE_CONVERT=0
DELETE_TMP=0
DELETE_IDENTITY=0
KEEP_SOURCE=1

usage() {
  cat <<'EOF'
Usage: cleanup-lab.sh [options]

Destructive options require --yes (and interactive confirm unless LAB_NONINTERACTIVE=1).

  --vms           Unregister/delete VMs created by this lab (HYD-*)
  --convert       Delete TMP_DIR/convert (VDI outputs; breaks VM hardlinks if still used)
  --tmp           Delete TMP_DIR/{zpaq,setup,organized,convert,identity,.markers}
  --identity      Delete TMP_DIR/identity only
  --all-work      Shortcut: --vms --tmp (keeps SOURCE_DIR and Kit/Original)
  --yes           Required to actually delete
  --no-prompt     Skip path prompts

SOURCE_DIR / lab ZIP are never removed by this script.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vms) DELETE_VMS=1 ;;
    --convert) DELETE_CONVERT=1 ;;
    --tmp) DELETE_TMP=1 ;;
    --identity) DELETE_IDENTITY=1 ;;
    --all-work) DELETE_VMS=1; DELETE_TMP=1 ;;
    --yes) YES=1 ;;
    --no-prompt) DO_PROMPT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config "$DO_PROMPT"

if [[ "$DELETE_VMS$DELETE_CONVERT$DELETE_TMP$DELETE_IDENTITY" == "0000" ]]; then
  usage
  die "Nothing selected — pass --vms / --tmp / --convert / --identity / --all-work and --yes"
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

if [[ "$DELETE_VMS" -eq 1 ]]; then
  confirm "unregister and delete lab VMs under $VM_ROOT"
  hv_load
  while IFS=$'\t' read -r name rest || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue
    hv_delete_vm "$name"
  done <"${ROOT_DIR}/config/topology.tsv"
fi

if [[ "$DELETE_IDENTITY" -eq 1 && "$DELETE_TMP" -eq 0 ]]; then
  confirm "delete $TMP_DIR/identity"
  rm -rf "${TMP_DIR}/identity"
fi

if [[ "$DELETE_CONVERT" -eq 1 && "$DELETE_TMP" -eq 0 ]]; then
  confirm "delete $CONVERT_DIR"
  rm -rf "$CONVERT_DIR"
fi

if [[ "$DELETE_TMP" -eq 1 ]]; then
  confirm "delete transitive trees under $TMP_DIR (zpaq/setup/organized/convert/identity/markers)"
  rm -rf \
    "${TMP_DIR}/zpaq" \
    "${TMP_DIR}/setup" \
    "${TMP_DIR}/organized" \
    "${TMP_DIR}/convert" \
    "${TMP_DIR}/identity" \
    "${TMP_DIR}/.markers"
fi

log "SOURCE_DIR kept: $SOURCE_DIR (KEEP_SOURCE=$KEEP_SOURCE)"
marker_set "${TMP_DIR}/.markers/cleanup.done" 2>/dev/null || true
log "Cleanup finished"
