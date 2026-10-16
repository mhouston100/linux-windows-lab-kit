#!/usr/bin/env bash
# Create lab VMs with the hypervisor selected by HYPERVISOR.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=lib/hypervisor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hypervisor.sh"

hv_load
exec "${HV_DIR}/create-vms.sh" "$@"
