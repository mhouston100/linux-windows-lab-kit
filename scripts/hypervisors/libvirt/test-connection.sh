#!/usr/bin/env bash
# Ask libvirt whether the URI answers. No guest is created.

set -euo pipefail
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/config.sh
source "${HV_DIR}/../../lib/config.sh"

load_config 0
: "${LIBVIRT_URI:=qemu:///system}"
command -v virsh >/dev/null 2>&1 || die "virsh was not found"
command -v virt-install >/dev/null 2>&1 || die "virt-install was not found"
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 was not found"

if [[ ! -e /dev/kvm ]]; then
  die "/dev/kvm is missing. Load kvm_intel and add this account to the kvm or libvirt group"
fi
if [[ "$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo N)" != "Y" ]]; then
  log "Nested VT-x is off. A nested Proxmox guest will not have KVM."
fi

if ! version="$(virsh -c "$LIBVIRT_URI" version)"; then
  die "Could not open ${LIBVIRT_URI}. Enable the system sockets: sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtnodedevd.socket virtstoraged.socket virtlogd.socket virtlockd.socket"
fi

hyp="$(printf '%s\n' "$version" | awk -F': ' '/Running hypervisor/{print $2}')"
log "libvirt answered at ${LIBVIRT_URI}${hyp:+ (${hyp})}"
if [[ "$LIBVIRT_URI" == *"/system" ]]; then
  if virsh -c "$LIBVIRT_URI" net-info default >/dev/null 2>&1; then
    log "Network default is present"
  else
    log "Network default is missing. The gateway's NAT nic needs it."
  fi
fi
