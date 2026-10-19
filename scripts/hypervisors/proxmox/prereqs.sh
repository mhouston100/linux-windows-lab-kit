#!/usr/bin/env bash
# Proxmox host tools. The node is reached with curl. Nothing is installed here.

hv_check_prereqs() {
  local family missing=0 cmd
  family="$(detect_distro_family)"
  for cmd in curl openssl; do
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
    arch) printf '         Hint: sudo pacman -S curl openssl\n' ;;
    debian) printf '         Hint: sudo apt install curl openssl\n' ;;
    fedora) printf '         Hint: sudo dnf install curl openssl\n' ;;
    *) printf '         Hint: install curl and openssl\n' ;;
  esac
  return 1
}
