#!/usr/bin/env bash
# Phase 1: confirm host tools, extract the kit, then verify the layout.
#
# The lab ZIP is only an input. Output goes under --dest (default
# /virtualmachines): source/extract for the unzip, tmp/ for the ZPAQ tree.
# Each finished step writes a timestamped marker in tmp/.markers and is
# skipped on the next run. --force ignores those markers and extracts again.
#
#   ./scripts/phase1.sh
#   ./scripts/phase1.sh --kit /path/Win11_25H2_Lab.zip --dest /virtualmachines --no-prompt
#
# Exit 0 after verify-phase1.sh passes. A failed step prints
# "status: failed (exit N)" and leaves the failing marker unset.

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
Usage: phase1.sh [--kit ZIP] [--dest DIR] [--force] [--no-prompt]

1) check-prereqs.sh
2) extract-lab.sh --step all
3) verify-phase1.sh

$(lab_path_help)
EOF
}

parse_lab_cli "$@"
eval "$(lab_cli_restore_eval)"

FORCE_ARGS=()
PROMPT=1
PROMPT_EXPLICIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_ARGS+=(--force) ;;
    --no-prompt) PROMPT=0; PROMPT_EXPLICIT=1 ;;
    --prompt) PROMPT=1; PROMPT_EXPLICIT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

# A path on the command line means "use this", not "ask me again".
if [[ "$PROMPT_EXPLICIT" -eq 0 && -n "${LAB_CLI_KIT:-}${LAB_CLI_DEST:-}" ]]; then
  PROMPT=0
fi

load_config "$PROMPT"
require_virtio_iso

log "Phase 1 — Extraction and organization"
print_checklist

cd "$ROOT_DIR"
"${SCRIPTS_DIR}/check-prereqs.sh"
# --no-prompt on the child: this script already resolved paths.
"${SCRIPTS_DIR}/extract-lab.sh" --step all --no-prompt \
  ${FORCE_ARGS[@]+"${FORCE_ARGS[@]}"}
"${SCRIPTS_DIR}/verify-phase1.sh" --no-prompt

print_checklist
lab_status_ok
