#!/usr/bin/env bash
# Phase 2: inventory Hyper-V disks, flatten differencing VHDX, convert to VDI.
# qemu-img cannot open Hyper-V differencing disks, so VhdxFlatten runs first.
# Converted files stay in DEST/tmp/convert. Exit 0 when verify-phase2.sh passes.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
# shellcheck source=lib/cli.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cli.sh"
# shellcheck source=lib/status.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/status.sh"

lab_install_exit_trap

usage() {
  cat <<EOF
Usage: phase2.sh [--kit ZIP] [--dest DIR] [--force] [--no-prompt] [--format vdi|vmdk]

1) inventory-disks.sh
2) convert-disks.sh   (flatten differencing VHDX, convert to VDI)
3) verify-phase2.sh

$(lab_path_help)
EOF
}

parse_lab_cli "$@"
eval "$(lab_cli_restore_eval)"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|--no-prompt|--prompt) ARGS+=("$1") ;;
    --format) ARGS+=("$1" "${2:?}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config 0
log "Phase 2 — Disk inventory and conversion"
print_checklist

cd "$ROOT_DIR"
"${SCRIPTS_DIR}/inventory-disks.sh" --no-prompt
"${SCRIPTS_DIR}/convert-disks.sh" "${ARGS[@]+"${ARGS[@]}"}"
"${SCRIPTS_DIR}/verify-phase2.sh"

print_checklist
lab_status_ok
