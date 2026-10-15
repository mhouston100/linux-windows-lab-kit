#!/usr/bin/env bash
# Phase 2 checkpoint: converted disks exist and open in VirtualBox.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

load_config 0

failed=0
check() {
  local desc="$1"; shift
  if "$@"; then printf '  [OK]   %s\n' "$desc"; else printf '  [FAIL] %s\n' "$desc"; failed=1; fi
}

log "Phase 2 verification (CONVERT_DIR=$CONVERT_DIR)"

check "convert marker" marker_ok "${MARKERS_DIR}/convert.done"
check "conversion map" test -f "${CONVERT_DIR}/conversion-map.tsv"

map="${CONVERT_DIR}/conversion-map.tsv"
count=0
while IFS=$'\t' read -r src mid out method; do
  [[ "$src" == "source" ]] && continue
  [[ "$out" == "-" || -z "$out" ]] && continue
  count=$((count + 1))
  if [[ -f "$out" ]] && VBoxManage showmediuminfo "$out" >/dev/null 2>&1; then
    printf '  [OK]   %s (%s)\n' "$(basename "$out")" "$method"
  else
    printf '  [FAIL] %s\n' "$out"
    failed=1
  fi
done <"$map"

printf '  [INFO] converted media checked: %s\n' "$count"
if (( count < 1 )); then
  printf '  [FAIL] no converted disks found\n'
  failed=1
fi

# Expect at least the three lab VMs + preferably parents
for name in HYD-DC1 HYD-CM1 HYD-GW1; do
  if compgen -G "${CONVERT_DIR}/${name}.*" >/dev/null; then
    printf '  [OK]   lab disk present: %s\n' "$name"
  else
    printf '  [FAIL] missing lab disk: %s\n' "$name"
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  die "Phase 2 checkpoint failed"
fi

marker_set "${MARKERS_DIR}/phase2.ok"
log "Phase 2 checkpoint PASSED"
log "Converted disks are under: $CONVERT_DIR"
