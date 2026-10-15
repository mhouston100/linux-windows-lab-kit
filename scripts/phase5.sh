#!/usr/bin/env bash
# Phase 5 end-to-end: verify lab-ctl (includes start/stop smoke).

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<'EOF'
Usage: phase5.sh

Runs verify-phase5.sh (lab-ctl health + start/stop smoke).

Day-to-day:
  ./scripts/lab-ctl.sh start          # ordered start with waits
  ./scripts/lab-ctl.sh start --no-wait
  ./scripts/lab-ctl.sh stop
  ./scripts/lab-ctl.sh status
  ./scripts/lab-ctl.sh health
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

cd "$ROOT_DIR"
log "Phase 5 — Lab control / ordered start-stop"
"${SCRIPTS_DIR}/verify-phase5.sh"
