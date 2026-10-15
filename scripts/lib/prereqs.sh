#!/usr/bin/env bash
# Prerequisite detection with distro-aware install hints (no auto-install).

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

detect_distro_family() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID_LIKE:-$ID}" in
      *arch*|cachyos|manjaro) echo arch ;;
      *debian*|ubuntu|linuxmint) echo debian ;;
      *fedora*|rhel|*centos*) echo fedora ;;
      *suse*) echo suse ;;
      *) echo unknown ;;
    esac
  else
    echo unknown
  fi
}

hint_for() {
  local pkg="$1"
  local family
  family="$(detect_distro_family)"
  case "$family" in
    arch)
      case "$pkg" in
        unzip) echo "sudo pacman -S unzip" ;;
        p7zip|7z) echo "sudo pacman -S p7zip" ;;
        qemu-img) echo "sudo pacman -S qemu-img" ;;
        virtualbox|VBoxManage) echo "sudo pacman -S virtualbox" ;;
        wine) echo "sudo pacman -S wine" ;;
        zpaq) echo "Native zpaq is often AUR-only; Wine + bundled zpaq.exe is supported: sudo pacman -S wine" ;;
        *) echo "Install package providing: $pkg" ;;
      esac
      ;;
    debian)
      case "$pkg" in
        unzip) echo "sudo apt install unzip" ;;
        p7zip|7z) echo "sudo apt install p7zip-full" ;;
        qemu-img) echo "sudo apt install qemu-utils" ;;
        virtualbox|VBoxManage) echo "sudo apt install virtualbox" ;;
        wine) echo "sudo apt install wine" ;;
        zpaq) echo "sudo apt install zpaq   # or use Wine + bundled zpaq.exe" ;;
        *) echo "Install package providing: $pkg" ;;
      esac
      ;;
    fedora)
      case "$pkg" in
        unzip) echo "sudo dnf install unzip" ;;
        p7zip|7z) echo "sudo dnf install p7zip p7zip-plugins" ;;
        qemu-img) echo "sudo dnf install qemu-img" ;;
        virtualbox|VBoxManage) echo "Install VirtualBox from virtualbox.org or COPR" ;;
        wine) echo "sudo dnf install wine" ;;
        zpaq) echo "sudo dnf install zpaq   # or use Wine + bundled zpaq.exe" ;;
        *) echo "Install package providing: $pkg" ;;
      esac
      ;;
    *)
      echo "Install a package that provides: $pkg"
      ;;
  esac
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Returns 0 if native zpaq OR (wine available for bundled zpaq.exe later).
zpaq_strategy() {
  if have_cmd zpaq; then
    echo native
    return 0
  fi
  if have_cmd wine; then
    echo wine
    return 0
  fi
  echo missing
  return 1
}

check_prereqs() {
  local strict="${1:-1}" # 1 = fail on missing required; 0 = report only
  local failed=0
  local family
  family="$(detect_distro_family)"

  log "Distro family: $family"
  log "Checking host prerequisites (no automatic installs)"

  local -a required=(unzip 7z qemu-img VBoxManage)
  local cmd path hint
  for cmd in "${required[@]}"; do
    if have_cmd "$cmd"; then
      path="$(command -v "$cmd")"
      printf '  [OK]   %s -> %s\n' "$cmd" "$path"
    else
      # 7z often installed as 7za
      if [[ "$cmd" == "7z" ]] && have_cmd 7za; then
        path="$(command -v 7za)"
        printf '  [OK]   7z (via 7za) -> %s\n' "$path"
        continue
      fi
      printf '  [MISS] %s\n' "$cmd"
      hint="$(hint_for "$cmd")"
      printf '         Hint: %s\n' "$hint"
      failed=1
    fi
  done

  # Phase 2: differencing VHDX flatten (optional for Phase 1)
  if have_cmd dotnet; then
    path="$(command -v dotnet)"
    printf '  [OK]   dotnet (Phase 2 VhdxFlatten) -> %s\n' "$path"
  else
    printf '  [WARN] dotnet missing — required for Phase 2 differencing VHDX flatten\n'
    printf '         Hint: sudo pacman -S dotnet-sdk\n'
  fi

  local strat
  if strat="$(zpaq_strategy)"; then
    if [[ "$strat" == native ]]; then
      path="$(command -v zpaq)"
      printf '  [OK]   zpaq (native) -> %s\n' "$path"
    else
      path="$(command -v wine)"
      printf '  [OK]   zpaq via Wine -> %s\n' "$path"
      printf '         (Mono is NOT required for zpaq.exe)\n'
    fi
  else
    printf '  [MISS] zpaq (need native zpaq OR wine for bundled zpaq.exe)\n'
    hint="$(hint_for zpaq)"
    printf '         Hint: %s\n' "$hint"
    hint="$(hint_for wine)"
    printf '         Hint: %s\n' "$hint"
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    warn "One or more prerequisites are missing."
    if [[ "$strict" -eq 1 ]]; then
      die "Install missing tools, then re-run."
    fi
    return 1
  fi

  log "All required prerequisites found."
  return 0
}

resolve_7z() {
  if have_cmd 7z; then
    echo 7z
  elif have_cmd 7za; then
    echo 7za
  else
    die "Neither 7z nor 7za found"
  fi
}

run_zpaq() {
  # Usage: run_zpaq <args...>   (archive path should be absolute for Wine)
  local strat
  strat="$(zpaq_strategy)" || die "No zpaq strategy available"

  if [[ "$strat" == native ]]; then
    zpaq "$@"
    return
  fi

  local wine_zpaq="${ZIP_DIR:-}/zpaq.exe"
  if [[ ! -f "$wine_zpaq" ]]; then
    die "Wine zpaq.exe not found at $wine_zpaq — extract the lab ZIP first"
  fi

  # Avoid Mono/.NET prompts and reduce noise; zpaq.exe is native Win64.
  WINEDEBUG="${WINEDEBUG:--all}" wine "$wine_zpaq" "$@"
}
