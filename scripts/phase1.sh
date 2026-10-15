#!/usr/bin/env bash
# Run Phase 1 end-to-end: prereqs → extract → verify.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FORCE_ARGS=()
PROMPT_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_ARGS+=(--force) ;;
    --no-prompt) PROMPT_ARGS+=(--no-prompt) ;;
    -h|--help)
      cat <<'EOF'
Usage: phase1.sh [--force] [--no-prompt]

1) check-prereqs.sh
2) extract-lab.sh --step all   (prompts for SOURCE_DIR / TMP_DIR / VM_ROOT / ZIP)
3) verify-phase1.sh

Defaults:
  SOURCE_DIR=/virtualmachines/source
  TMP_DIR=/virtualmachines/tmp
  VM_ROOT=/virtualmachines
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

cd "$ROOT_DIR"

log "Phase 1 — Extraction and organization"
"${SCRIPTS_DIR}/check-prereqs.sh"
"${SCRIPTS_DIR}/extract-lab.sh" --step all \
  ${FORCE_ARGS[@]+"${FORCE_ARGS[@]}"} \
  ${PROMPT_ARGS[@]+"${PROMPT_ARGS[@]}"}
"${SCRIPTS_DIR}/verify-phase1.sh" --no-prompt
