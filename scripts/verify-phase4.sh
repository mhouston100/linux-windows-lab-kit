#!/usr/bin/env bash
# Phase 4 checkpoint: identity artifacts present under TMP_DIR.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

load_config 0

failed=0
check() {
  local desc="$1"; shift
  if "$@"; then printf '  [OK]   %s\n' "$desc"; else printf '  [FAIL] %s\n' "$desc"; failed=1; fi
}

IDENTITY_DIR="${TMP_DIR}/identity"
log "Phase 4 verification (IDENTITY_DIR=$IDENTITY_DIR)"

check "identity marker" marker_ok "${MARKERS_DIR}/identity.done"
check "credentials.md" test -f "${IDENTITY_DIR}/credentials.md"
check "first-boot-notes.md" test -f "${IDENTITY_DIR}/first-boot-notes.md"
check "summary.env" test -f "${IDENTITY_DIR}/summary.env"
check "client unattend template in repo" test -f "${ROOT_DIR}/templates/unattend/client-oobe.xml.tmpl"

if [[ -n "${LAB_ADMIN_PASSWORD:-}" ]]; then
  check "client unattend rendered" test -f "${IDENTITY_DIR}/unattend/HYD-CLIENT1-oobe.xml"
else
  printf '  [INFO] LAB_ADMIN_PASSWORD unset — unattend XML not required for checkpoint\n'
fi

# Server VMs should carry description
for name in HYD-DC1 HYD-CM1 HYD-GW1; do
  if VBoxManage showvminfo "$name" --machinereadable 2>/dev/null | rg -q '^description=".+"'; then
    printf '  [OK]   description set: %s\n' "$name"
  else
    printf '  [FAIL] description missing: %s\n' "$name"
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  die "Phase 4 checkpoint failed"
fi

marker_set "${MARKERS_DIR}/phase4.ok"
log "Phase 4 checkpoint PASSED"
log "Identity files: $IDENTITY_DIR"
