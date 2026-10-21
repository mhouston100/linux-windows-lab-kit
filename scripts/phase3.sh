#!/usr/bin/env bash
# Phase 3: create the three server VMs under DEST (the hypervisor machine folder).
# CorpNet is an internal network. HYD-GW1 also gets a NAT adapter.
# Disks are attached from DEST/tmp/convert. --no-smoke skips the power-on test.
# Exit 0 when verify-phase3.sh passes.

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
Usage: phase3.sh [--kit ZIP] [--dest DIR] [--force] [--no-prompt] [--no-smoke]

1) create-lab-vms.sh   (CorpNet intnet + NAT on GW; attach converted VDIs)
2) verify-phase3.sh

$(lab_path_help)
EOF
}

parse_lab_cli "$@"
eval "$(lab_cli_restore_eval)"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|--no-prompt|--prompt|--no-smoke) ARGS+=("$1") ;;
    --topology) ARGS+=("$1" "${2:?}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config 0
require_virtio_iso
log "Phase 3 — create VMs"
print_checklist

cd "$ROOT_DIR"
"${SCRIPTS_DIR}/create-lab-vms.sh" "${ARGS[@]+"${ARGS[@]}"}"
"${SCRIPTS_DIR}/verify-phase3.sh"

print_checklist
lab_status_ok
