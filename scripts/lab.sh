#!/usr/bin/env bash
# Terminal entry point.
#
#   ./scripts/lab.sh
#       Interactive menu when stdin is a terminal: pick a stage or run all.
#       Blocked stages are shown and refused until the stage they depend on
#       has a checkpoint marker.
#   ./scripts/lab.sh phase1 --no-prompt
#   ./scripts/lab.sh all --no-prompt
#   ./scripts/lab.sh status
#
# With no command and no terminal, print the checklist and exit 0 only when
# every task marker is present.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
# shellcheck source=lib/cli.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cli.sh"
# shellcheck source=lib/tui.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/tui.sh"

usage() {
  cat <<EOF
Usage: lab.sh [--kit ZIP] [--dest DIR] [menu|status|phase1|phase2|phase3|phase4|phase5|phase6|all]

$(lab_path_help)

Commands:
  menu     Arrow-free stage menu (default on a terminal)
  status   Print the task list and exit
  phaseN   Run that stage if its dependency marker exists
  all      Run every stage that is not done, in order. Stops when one fails
           or when the next stage is blocked. Stage 5 starts the VMs.

Stages:
  1 extract    always, once the kit ZIP is on disk
  2 convert    after stage 1
  3 create VMs after stage 2
  4 identity   after stage 3
  5 run lab    after stage 4 (powers VMs on, then off)
  6 cleanup    after stage 3 (checks the safety gates; does not delete)
EOF
}

parse_lab_cli "$@"
eval "$(lab_cli_restore_eval)"

COMMAND=""
LAB_FORWARD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    menu|status|phase1|phase2|phase3|phase4|phase5|phase6|all) COMMAND="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) LAB_FORWARD+=("$1") ;;
  esac
  shift
done

if [[ -z "$COMMAND" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    COMMAND="menu"
  else
    COMMAND="status"
  fi
fi

load_config 0
tui_enable_color
export LAB_FORWARD

case "$COMMAND" in
  menu)
    tui_menu
    ;;
  status)
    print_checklist
    if [[ "$LAB_TODO_N" -eq 0 ]]; then
      printf 'status: ok (exit 0) — nothing outstanding\n'
      exit 0
    fi
    printf 'status: incomplete (exit 1) — %s outstanding\n' "$LAB_TODO_N"
    exit 1
    ;;
  phase1|phase2|phase3|phase4|phase5|phase6)
    id="${COMMAND#phase}"
    set +e
    tui_run_stage "$id"
    rc=$?
    set -e
    if [[ "$TUI_ALT" -eq 1 && -t 0 ]]; then
      printf '\033[?25h'
      IFS= read -r _ || true
      tui_leave
    fi
    exit "$rc"
    ;;
  all)
    set +e
    tui_run_all
    rc=$?
    set -e
    if [[ "$TUI_ALT" -eq 1 && -t 0 ]]; then
      printf '\033[?25h'
      IFS= read -r _ || true
      tui_leave
    fi
    if [[ "$rc" -ne 0 ]]; then
      printf 'status: failed (exit %s)\n' "$rc" >&2
      exit "$rc"
    fi
    lab_count_tasks
    if [[ "$LAB_TODO_N" -eq 0 ]]; then
      printf 'status: ok (exit 0)\n'
    else
      printf 'status: incomplete (exit 1) — %s outstanding\n' "$LAB_TODO_N"
      exit 1
    fi
    ;;
  *)
    usage
    die "Unknown command: $COMMAND"
    ;;
esac
