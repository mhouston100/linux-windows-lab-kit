#!/usr/bin/env bash
# Ask VirtualBox whether VBoxManage answers. No guest is created.

set -euo pipefail
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/config.sh
source "${HV_DIR}/../../lib/config.sh"

load_config 0
command -v VBoxManage >/dev/null 2>&1 || die "VBoxManage was not found"
version="$(VBoxManage --version)"
log "VirtualBox ${version} answered"
