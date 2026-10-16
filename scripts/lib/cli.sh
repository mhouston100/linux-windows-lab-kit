#!/usr/bin/env bash
# Shared --kit / --dest parsing.
#
# --kit is the lab ZIP the operator points at (one specific kit download).
# --dest is the writable root for this run. It is split into:
#   DEST/source   immediate unzip of the ZIP
#   DEST/tmp      zpaq payload, setup unpack, convert scratch, markers
#   DEST          VM folder for the selected hypervisor (definitions and final disks)
# Flags override config/lab.env. Defaults live in lib/config.sh.

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LAB_CLI_KIT="${LAB_CLI_KIT:-}"
LAB_CLI_DEST="${LAB_CLI_DEST:-}"
LAB_REMAINING=()

lab_path_help() {
  cat <<EOF
Path options:
  --kit PATH     Lab ZIP. Default: ${DEFAULT_LAB_ZIP:-/virtualmachines/Kit/Original/Win11_25H2_Lab.zip}
                 if that file exists, else DEST/source/${DEFAULT_LAB_ZIP_NAME:-Win11_25H2_Lab.zip}
  --dest DIR     Output root. Default: ${DEFAULT_VM_ROOT:-/virtualmachines}
                 (source/ and tmp/ are created under it)
EOF
}

# Pull --kit/--dest out of "$@". Everything else is left in LAB_REMAINING.
parse_lab_cli() {
  LAB_REMAINING=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kit|--source)
        [[ -n "${2:-}" && "$2" != --* ]] || die "--kit needs the path to the lab ZIP"
        LAB_CLI_KIT="$2"
        export LAB_CLI_KIT
        shift 2
        ;;
      --dest|--destination)
        [[ -n "${2:-}" && "$2" != --* ]] || die "--dest needs a directory"
        LAB_CLI_DEST="$2"
        export LAB_CLI_DEST
        shift 2
        ;;
      *)
        LAB_REMAINING+=("$1")
        shift
        ;;
    esac
  done
}

# After parse_lab_cli, put the leftover words back into "$@".
# Must run in the caller, not a function: set -- inside a function is local.
#   eval "$(lab_cli_restore_eval)"
lab_cli_restore_eval() {
  if [[ ${#LAB_REMAINING[@]} -eq 0 ]]; then
    printf '%s\n' 'set --'
  else
    printf 'set --'
    local arg
    for arg in "${LAB_REMAINING[@]}"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  fi
}
