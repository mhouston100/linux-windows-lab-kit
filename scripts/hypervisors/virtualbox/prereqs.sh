#!/usr/bin/env bash
# VirtualBox host tools. Called from the shared prerequisite check.

hv_check_prereqs() {
  local family hint
  family="$(detect_distro_family)"
  if have_cmd VBoxManage; then
    printf '  [OK]   VBoxManage -> %s\n' "$(command -v VBoxManage)"
    return 0
  fi
  printf '  [MISS] VBoxManage\n'
  case "$family" in
    arch) hint="sudo pacman -S virtualbox" ;;
    debian) hint="sudo apt install virtualbox" ;;
    fedora) hint="Install VirtualBox from virtualbox.org or COPR" ;;
    *) hint="Install VirtualBox (VBoxManage)" ;;
  esac
  printf '         Hint: %s\n' "$hint"
  return 1
}
