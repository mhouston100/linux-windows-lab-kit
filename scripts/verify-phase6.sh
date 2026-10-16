#!/usr/bin/env bash
# Phase 6 checkpoint: cleanup script dry-run behavior (refuses without --yes).

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

load_config 0
hv_load

failed=0
check() {
  local desc="$1"; shift
  if "$@"; then printf '  [OK]   %s\n' "$desc"; else printf '  [FAIL] %s\n' "$desc"; failed=1; fi
}

log "Phase 6 verification (non-destructive)"

check "cleanup-lab.sh executable" test -x "${SCRIPTS_DIR}/cleanup-lab.sh"

# Must refuse without --yes
if "${SCRIPTS_DIR}/cleanup-lab.sh" --vms >/dev/null 2>&1; then
  printf '  [FAIL] cleanup without --yes should fail\n'
  failed=1
else
  printf '  [OK]   cleanup refuses without --yes\n'
fi

# Must refuse with nothing selected
if "${SCRIPTS_DIR}/cleanup-lab.sh" --yes >/dev/null 2>&1; then
  printf '  [FAIL] cleanup with only --yes should fail\n'
  failed=1
else
  printf '  [OK]   cleanup refuses with nothing selected\n'
fi

# Reset is the menu action. This check must not pass --yes.
if "${SCRIPTS_DIR}/cleanup-lab.sh" --reset >/dev/null 2>&1; then
  printf '  [FAIL] reset without --yes should fail\n'
  failed=1
else
  printf '  [OK]   reset refuses without --yes\n'
fi

# Ensure we did not delete VMs during verify
for name in HYD-DC1 HYD-CM1 HYD-GW1; do
  if hv_vm_exists "$name"; then
    printf '  [OK]   VM still present after dry checks: %s\n' "$name"
  else
    printf '  [FAIL] VM missing (should not have deleted): %s\n' "$name"
    failed=1
  fi
done

check "SOURCE_DIR still exists" test -d "$SOURCE_DIR"
check "lab ZIP still present" test -f "$LAB_ZIP_PATH"

if [[ "$failed" -ne 0 ]]; then
  die "Phase 6 checkpoint failed"
fi

marker_set "${MARKERS_DIR}/phase6.ok"
log "Phase 6 checkpoint PASSED (cleanup gates OK; no lab data deleted)"
