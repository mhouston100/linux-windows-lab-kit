#!/usr/bin/env bash
# Ask the Proxmox API whether these settings can be used. No guest is created.

set -euo pipefail
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/config.sh
source "${HV_DIR}/../../lib/config.sh"
# shellcheck source=load.sh
source "${HV_DIR}/load.sh"

load_config 0
pve_test_connection
