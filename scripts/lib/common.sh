#!/usr/bin/env bash
# Shared helpers for Linux Windows Lab Kit scripts.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
LIB_DIR="${SCRIPTS_DIR}/lib"

# Append one line to the lab log when TMP_DIR is known. The menu also writes
# this file. A captured stage sets LAB_LOG_CAPTURE so the child does not write
# the same line twice; the menu records the captured text instead.
lab_log_append() {
  local path
  [[ "${LAB_LOG_CAPTURE:-}" == 1 ]] && return 0
  [[ -n "${TMP_DIR:-}" ]] || return 0
  path="${TMP_DIR}/lab.log"
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -Iseconds)" "$*" >>"$path" 2>/dev/null || true
}

log()  { printf '==> %s\n' "$*"; lab_log_append "==> $*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; lab_log_append "WARNING: $*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; lab_log_append "ERROR: $*"; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

bytes_available() {
  # Free bytes on the filesystem containing $1 (dir or file path).
  local path="$1"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  if [[ ! -e "$path" ]]; then
    mkdir -p "$path"
  fi
  df -B1 --output=avail "$path" | awk 'NR==2 {print $1}'
}

human_bytes() {
  local n="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$n"
  else
    printf '%s bytes' "$n"
  fi
}

ensure_dir() {
  mkdir -p "$@"
}

# Markers are the run history. The file's contents are an ISO timestamp,
# which the checklist prints next to accomplished tasks. Delete the marker
# (or pass --force) to make that step run again. Deleting only the extracted
# files does not; the marker still says the step finished.
marker_set() {
  local path="$1"
  ensure_dir "$(dirname "$path")"
  date -Iseconds >"$path"
}

marker_ok() {
  [[ -f "$1" ]]
}
