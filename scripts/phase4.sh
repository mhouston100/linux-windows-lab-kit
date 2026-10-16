#!/usr/bin/env bash
# Phase 4: render our unattend / identity templates from config/lab.env.
# Output is DEST/tmp/identity. The password stays in lab.env and is not printed.
# Exit 0 when verify-phase4.sh passes.

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
Usage: phase4.sh [--kit ZIP] [--dest DIR] [--no-prompt]

1) prepare-identity.sh
2) verify-phase4.sh

$(lab_path_help)
EOF
}

parse_lab_cli "$@"
eval "$(lab_cli_restore_eval)"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-prompt|--prompt) ARGS+=("$1") ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config 0
log "Phase 4 — Identity / unattend templates"
print_checklist

cd "$ROOT_DIR"
"${SCRIPTS_DIR}/prepare-identity.sh" "${ARGS[@]+"${ARGS[@]}"}"
"${SCRIPTS_DIR}/verify-phase4.sh"

print_checklist
lab_status_ok
