#!/usr/bin/env bash
# Check host tools required for the lab kit. Does not install packages.

set -euo pipefail
# shellcheck source=lib/prereqs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/prereqs.sh"

REPORT_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-only) REPORT_ONLY=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: check-prereqs.sh [--report-only]

Checks for unzip, 7z, qemu-img, zpaq (native or Wine), and the tools for the
hypervisor named by HYPERVISOR (default virtualbox).
Does not install anything; prints distro-specific hints when tools are missing.
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

if [[ "$REPORT_ONLY" -eq 1 ]]; then
  check_prereqs 0 || true
else
  check_prereqs 1
fi
