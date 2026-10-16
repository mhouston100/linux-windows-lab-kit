#!/usr/bin/env bash
# Phase 6: prove cleanup refuses to delete anything unless --yes is passed.
# This script does not remove VMs, tmp, or the kit ZIP. To actually reclaim
# disk, run cleanup-lab.sh with an explicit target and --yes.
# Exit 0 when those safety checks pass and the lab is still present.

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
Usage: phase6.sh [--kit ZIP] [--dest DIR]

Verifies cleanup-lab.sh safety (refuses without --yes; does not delete).

To actually reclaim space (explicit):
  ./scripts/cleanup-lab.sh --all-work --yes
  # or finer: --vms / --tmp / --convert / --identity

$(lab_path_help)
EOF
}

parse_lab_cli "$@"
eval "$(lab_cli_restore_eval)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-prompt|--prompt) ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config 0
log "Phase 6 — Cleanup safety verification"
print_checklist

cd "$ROOT_DIR"
"${SCRIPTS_DIR}/verify-phase6.sh"

print_checklist
lab_status_ok
