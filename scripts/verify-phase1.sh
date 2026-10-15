#!/usr/bin/env bash
# Hands-on checkpoint: verify Phase 1 extract/organize layout.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

PROMPT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) PROMPT=1 ;;
    --no-prompt) PROMPT=0 ;;
    -h|--help)
      echo "Usage: verify-phase1.sh [--prompt]"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config "$PROMPT"

failed=0
check() {
  local desc="$1"
  shift
  if "$@"; then
    printf '  [OK]   %s\n' "$desc"
  else
    printf '  [FAIL] %s\n' "$desc"
    failed=1
  fi
}

log "Phase 1 verification"
log "SOURCE_DIR=$SOURCE_DIR  TMP_DIR=$TMP_DIR  VM_ROOT=$VM_ROOT"

check "zip marker" marker_ok "${MARKERS_DIR}/zip.done"
check "zpaq marker" marker_ok "${MARKERS_DIR}/zpaq.done"
check "setup marker" marker_ok "${MARKERS_DIR}/setup.done"
check "organize marker" marker_ok "${MARKERS_DIR}/organize.done"

check "Microsoft365DeviceLabKit.zpaq present" test -f "${ZIP_DIR}/Microsoft365DeviceLabKit.zpaq"
check "zpaq.exe present" test -f "${ZIP_DIR}/zpaq.exe"
check "setup.exe present" test -f "${ZIP_DIR}/setup.exe"

check "zpaq extract dir non-empty" bash -c "[[ -d '$ZPAQ_DIR' && -n \"\$(find '$ZPAQ_DIR' -type f | head -1)\" ]]"
check "organized/disks exists" test -d "$ORG_DISKS"
check "inventory file exists" test -f "$INVENTORY_FILE"

# VM_ROOT should not be polluted with Hyper-V extract trees named like lab VMs
# (those belong under TMP_DIR/zpaq until Phase 3 creates VirtualBox VMs).
disk_count="$(find "$ORG_DISKS" \( -type l -o -type f \) 2>/dev/null | wc -l | tr -d ' ')"
printf '  [INFO] organized disks linked: %s\n' "$disk_count"
if [[ "${disk_count}" -lt 1 ]]; then
  printf '  [FAIL] expected at least one VHD/VHDX under organized/disks\n'
  failed=1
else
  printf '  [OK]   at least one disk image organized\n'
fi

if [[ "$failed" -ne 0 ]]; then
  die "Phase 1 checkpoint failed. Fix extract steps, then re-run verify-phase1.sh"
fi

marker_set "${MARKERS_DIR}/phase1.ok"
log "Phase 1 checkpoint PASSED. Marker: ${MARKERS_DIR}/phase1.ok"
log "Review inventory: $INVENTORY_FILE"
log "Safe to proceed to Phase 2 (disk conversion) when ready."
