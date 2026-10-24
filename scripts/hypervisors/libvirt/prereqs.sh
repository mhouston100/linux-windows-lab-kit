#!/usr/bin/env bash
# libvirt / QEMU host tools. Nothing is installed here.

hv_check_prereqs() {
  local family missing=0 cmd
  family="$(detect_distro_family)"
  for cmd in virsh virt-install qemu-system-x86_64 qemu-img; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '  [OK]   %s -> %s\n' "$cmd" "$(command -v "$cmd")"
    else
      printf '  [MISS] %s\n' "$cmd"
      missing=1
    fi
  done
  if [[ "$missing" -eq 0 ]]; then
    return 0
  fi
  case "$family" in
    arch) printf '         Hint: sudo pacman -S libvirt qemu-desktop virt-install edk2-ovmf dnsmasq\n' ;;
    debian) printf '         Hint: sudo apt install libvirt-daemon-system qemu-system-x86 virtinst ovmf\n' ;;
    fedora) printf '         Hint: sudo dnf install libvirt qemu-kvm virt-install edk2-ovmf\n' ;;
    *) printf '         Hint: install libvirt, qemu-system-x86_64, virt-install, and OVMF\n' ;;
  esac
  return 1
}
