#!/usr/bin/env bash
# Shared helpers for Linux Windows Lab Kit scripts.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
LIB_DIR="${SCRIPTS_DIR}/lib"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

marker_set() {
  local path="$1"
  ensure_dir "$(dirname "$path")"
  date -Iseconds >"$path"
}

marker_ok() {
  [[ -f "$1" ]]
}
