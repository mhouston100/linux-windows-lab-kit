#!/usr/bin/env bash
# Load lab.env configuration and resolve storage paths.

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Defaults for testing / CachyOS lab host
DEFAULT_SOURCE_DIR=/virtualmachines/source
DEFAULT_TMP_DIR=/virtualmachines/tmp
DEFAULT_VM_ROOT=/virtualmachines
DEFAULT_LAB_ZIP_NAME=Win11_25H2_Lab.zip

prompt_path() {
  # prompt_path VAR "Prompt text" DEFAULT
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local current="${!var_name:-}"
  local reply

  if [[ -n "$current" ]]; then
    default="$current"
  fi

  if [[ "${LAB_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    printf -v "$var_name" '%s' "$default"
    return
  fi

  read -r -p "${prompt} [${default}]: " reply || true
  if [[ -z "$reply" ]]; then
    printf -v "$var_name" '%s' "$default"
  else
    printf -v "$var_name" '%s' "$reply"
  fi
}

apply_derived_paths() {
  # source/: lab ZIP and immediate unzip (zpaq archive, setup.exe, zpaq.exe)
  ZIP_DIR="${SOURCE_DIR}/extract"

  # tmp/: transitive Hyper-V media + tooling unpack + inventories
  ZPAQ_DIR="${TMP_DIR}/zpaq"
  SETUP_DIR="${TMP_DIR}/setup"
  ORG_DIR="${TMP_DIR}/organized"
  ORG_DISKS="${ORG_DIR}/disks"
  ORG_VMS="${ORG_DIR}/vms"
  ORG_TOOLS="${ORG_DIR}/tools"
  ORG_META="${ORG_DIR}/meta"
  CONVERT_DIR="${TMP_DIR}/convert"
  MARKERS_DIR="${TMP_DIR}/.markers"
  INVENTORY_FILE="${ORG_META}/inventory.txt"

  # vm root: VirtualBox machine folder (definitions + final disks)
  # Phase 3 will create VMs here; keep source/ and tmp/ as siblings.
  export SOURCE_DIR TMP_DIR VM_ROOT LAB_ZIP_PATH GUIDES_ZIP_PATH \
    HYPERVISOR LAB_PREFIX LAB_NETWORK_NAME LAB_ADMIN_USER LAB_ADMIN_PASSWORD LAB_DOMAIN \
    ZIP_DIR ZPAQ_DIR SETUP_DIR ORG_DIR ORG_DISKS ORG_VMS ORG_TOOLS ORG_META \
    CONVERT_DIR MARKERS_DIR INVENTORY_FILE
}

resolve_paths() {
  # Optional interactive prompts (defaults under /virtualmachines).
  local do_prompt="${1:-0}"

  : "${SOURCE_DIR:=$DEFAULT_SOURCE_DIR}"
  : "${TMP_DIR:=$DEFAULT_TMP_DIR}"
  : "${VM_ROOT:=$DEFAULT_VM_ROOT}"
  : "${LAB_ZIP_PATH:=}"
  : "${GUIDES_ZIP_PATH:=}"

  if [[ "$do_prompt" == "1" ]]; then
    log "Storage paths (Enter accepts default). Repo stays clean — media lives under /virtualmachines."
    prompt_path SOURCE_DIR "Source directory (ZIP + immediate extract)" "$DEFAULT_SOURCE_DIR"
    prompt_path TMP_DIR "Temp directory (zpaq disks, setup unpack, scratch)" "$DEFAULT_TMP_DIR"
    prompt_path VM_ROOT "VM root (VirtualBox machines + final disks)" "$DEFAULT_VM_ROOT"

    local zip_default="${LAB_ZIP_PATH:-${SOURCE_DIR}/${DEFAULT_LAB_ZIP_NAME}}"
    # Prefer known original location if present and default missing
    if [[ ! -f "$zip_default" && -f /virtualmachines/Kit/Original/Win11_25H2_Lab.zip ]]; then
      zip_default=/virtualmachines/Kit/Original/Win11_25H2_Lab.zip
    fi
    LAB_ZIP_PATH="${LAB_ZIP_PATH:-$zip_default}"
    prompt_path LAB_ZIP_PATH "Path to lab ZIP" "$LAB_ZIP_PATH"
  else
    if [[ -z "${LAB_ZIP_PATH}" ]]; then
      if [[ -f "${SOURCE_DIR}/${DEFAULT_LAB_ZIP_NAME}" ]]; then
        LAB_ZIP_PATH="${SOURCE_DIR}/${DEFAULT_LAB_ZIP_NAME}"
      elif [[ -f /virtualmachines/Kit/Original/Win11_25H2_Lab.zip ]]; then
        LAB_ZIP_PATH=/virtualmachines/Kit/Original/Win11_25H2_Lab.zip
      else
        LAB_ZIP_PATH="${SOURCE_DIR}/${DEFAULT_LAB_ZIP_NAME}"
      fi
    fi
  fi

  : "${HYPERVISOR:=virtualbox}"
  : "${LAB_PREFIX:=HYD}"
  : "${LAB_NETWORK_NAME:=CorpNet}"
  : "${LAB_ADMIN_USER:=LabAdmin}"
  : "${LAB_ADMIN_PASSWORD:=}"
  : "${LAB_DOMAIN:=Corp}"

  apply_derived_paths

  log "SOURCE_DIR=$SOURCE_DIR"
  log "TMP_DIR=$TMP_DIR"
  log "VM_ROOT=$VM_ROOT"
  log "LAB_ZIP_PATH=$LAB_ZIP_PATH"
}

load_config() {
  local env_file="${LAB_ENV_FILE:-${ROOT_DIR}/config/lab.env}"
  local example="${ROOT_DIR}/config/lab.env.example"
  local do_prompt="${1:-0}"

  if [[ -f "$env_file" ]]; then
    log "Loading config: $env_file"
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  else
    warn "No config at $env_file — using defaults / prompts."
    warn "Optional: cp $example config/lab.env"
  fi

  resolve_paths "$do_prompt"
}

require_lab_zip() {
  [[ -n "${LAB_ZIP_PATH}" ]] || die "LAB_ZIP_PATH is not set"
  [[ -f "${LAB_ZIP_PATH}" ]] || die "LAB_ZIP_PATH not found: ${LAB_ZIP_PATH}"
}

save_resolved_paths_hint() {
  # Write a non-secret path snapshot under tmp for operator reference (not in git).
  ensure_dir "$ORG_META"
  cat >"${ORG_META}/paths.env" <<EOF
SOURCE_DIR=${SOURCE_DIR}
TMP_DIR=${TMP_DIR}
VM_ROOT=${VM_ROOT}
LAB_ZIP_PATH=${LAB_ZIP_PATH}
ZIP_DIR=${ZIP_DIR}
ZPAQ_DIR=${ZPAQ_DIR}
SETUP_DIR=${SETUP_DIR}
ORG_DIR=${ORG_DIR}
CONVERT_DIR=${CONVERT_DIR}
EOF
}
