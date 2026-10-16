#!/usr/bin/env bash
# Phase 5: start the lab in dependency order, check health, then stop it.
# This really powers VMs on. Day-to-day control is lab-ctl.sh (start/stop/status).
# Exit 0 when verify-phase5.sh passes.

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
Usage: phase5.sh [--kit ZIP] [--dest DIR]

Runs verify-phase5.sh (lab-ctl health + start/stop smoke).

Day-to-day:
  ./scripts/lab-ctl.sh start          # ordered start with waits
  ./scripts/lab-ctl.sh start --no-wait
  ./scripts/lab-ctl.sh stop
  ./scripts/lab-ctl.sh status
  ./scripts/lab-ctl.sh health

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
log "Phase 5 — Lab control / ordered start-stop"
log "This step powers the VMs on, then stops them."
print_checklist

cd "$ROOT_DIR"
"${SCRIPTS_DIR}/verify-phase5.sh"

print_checklist
lab_status_ok
