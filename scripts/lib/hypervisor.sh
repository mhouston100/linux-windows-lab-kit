#!/usr/bin/env bash
# Select the hypervisor module named by HYPERVISOR (default virtualbox).
# Each backend is a directory under scripts/hypervisors/<name>/ with a load.sh
# that defines the hv_* hooks below. Shared phase scripts call those hooks.

hv_load() {
  if [[ "${HV_LOADED:-}" == "${HYPERVISOR:-virtualbox}" && -n "${HV_DIR:-}" ]]; then
    return 0
  fi
  if [[ -z "${HYPERVISOR:-}" && -f "${ROOT_DIR}/config/lab.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/config/lab.env"
    set +a
  fi
  local name="${HYPERVISOR:-virtualbox}"
  HV_DIR="${ROOT_DIR}/scripts/hypervisors/${name}"
  [[ -f "${HV_DIR}/load.sh" ]] || die "No hypervisor module '${name}' (${HV_DIR}/load.sh)"
  # shellcheck disable=SC1091
  source "${HV_DIR}/load.sh"
  HV_LOADED="$name"
}
