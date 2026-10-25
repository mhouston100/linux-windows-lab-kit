#!/usr/bin/env bash
# libvirt: ordered start / stop / status / health for lab VMs.

set -euo pipefail
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/config.sh
source "${HV_DIR}/../../lib/config.sh"
# shellcheck source=load.sh
source "${HV_DIR}/load.sh"

CMD="${1:-}"
shift || true

DO_PROMPT=0
WAIT=1
BOOT_ORDER_FILE="${ROOT_DIR}/config/boot-order.tsv"

usage() {
  cat <<'EOF'
Usage: lab-ctl.sh <command> [options]

Commands:
  start [--no-wait]   Start VMs in boot-order, then wait for the QEMU guest agent
  stop                Power off VMs in reverse boot-order
  status              Show state for each lab VM
  health              status plus disk and network checks
  list                List topology VMs and boot order
  restore-services    Turn the services disabled on the disk (hold-services.tsv)

Options:
  --no-wait           Do not apply the settle time between starts
  --boot-order FILE   Override config/boot-order.tsv
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait) WAIT=0 ;;
    --boot-order) BOOT_ORDER_FILE="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ -n "$CMD" ]] || { usage; exit 1; }

load_config "$DO_PROMPT"
: "${LIBVIRT_URI:=qemu:///system}"
[[ -f "$BOOT_ORDER_FILE" ]] || die "Boot order file missing: $BOOT_ORDER_FILE"

NAMES=()
ORDERS=()
WAITSECS=()

load_boot_order() {
  NAMES=(); ORDERS=(); WAITSECS=()
  local name order wait notes
  while IFS=$'\t' read -r name order wait notes || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue
    NAMES+=("$name")
    ORDERS+=("$order")
    WAITSECS+=("${wait:-0}")
  done < <(awk -F'\t' '!/^#/ && NF && $1!="name" {print}' "$BOOT_ORDER_FILE" | sort -t$'\t' -k2,2n)
}

lv_agent_ready() {
  lv_virsh qemu-agent-command "$1" '{"execute":"guest-ping"}' >/dev/null 2>&1
}

lv_wait_agent() {
  local name="$1" max="${PVE_AGENT_WAIT:-1800}" need="${PVE_AGENT_STABLE:-120}"
  local elapsed=0 since=0 now state
  log "Waiting up to ${max}s for the QEMU guest agent on ${name}"
  while [[ "$elapsed" -lt "$max" ]]; do
    state="$(hv_vm_state "$name")"
    if [[ "$state" == "running" ]] && lv_agent_ready "$name"; then
      now="$(date +%s)"
      if [[ "$since" -eq 0 ]]; then
        since="$now"
        log "QEMU guest agent answered on ${name}"
        if [[ "$need" -gt 0 ]]; then
          log "Checking that it keeps answering for ${need}s. The installer restarts the guest once."
        fi
      fi
      if [[ $((now - since)) -ge "$need" ]]; then
        log "QEMU guest agent on ${name} is steady"
        return 0
      fi
    elif [[ "$since" -ne 0 ]]; then
      log "The QEMU guest agent on ${name} stopped answering. Waiting for it to come back."
      since=0
    fi
    if [[ "$state" == "poweroff" || "$state" == "missing" ]]; then
      die "${name} stayed powered off while the QEMU guest agent was awaited."
    fi
    if [[ "$since" -eq 0 ]] && (( elapsed > 0 && elapsed % 30 == 0 )); then
      log "Still waiting for the QEMU guest agent on ${name} (${elapsed}s)"
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  die "Timed out waiting for the QEMU guest agent on ${name}"
}

cmd_status() {
  load_boot_order
  local i
  printf '%-14s %-10s %s\n' "NAME" "STATE" "ORDER"
  for i in "${!NAMES[@]}"; do
    printf '%-14s %-10s %s\n' "${NAMES[$i]}" "$(hv_vm_state "${NAMES[$i]}")" "${ORDERS[$i]}"
  done
}

cmd_list() {
  cmd_status
}

cmd_health() {
  hv_verify_create
}

cmd_start() {
  load_boot_order
  local i name state
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    state="$(hv_vm_state "$name")"
    lv_ensure_agent_channel "$name"
    if [[ "$state" != "running" ]]; then
      log "Starting ${name} (order=${ORDERS[$i]})"
      lv_allow_qemu_disk "${VM_ROOT}/${name}/${name}.qcow2"
      lv_virsh start "$name"
    else
      log "${name} is already running"
    fi
    lv_wait_agent "$name"
    if [[ "$WAIT" -eq 1 && "${WAITSECS[$i]}" -gt 0 ]]; then
      log "Settle ${WAITSECS[$i]}s after ${name}"
      sleep "${WAITSECS[$i]}"
    fi
  done
}

cmd_stop() {
  load_boot_order
  local i name state
  for ((i = ${#NAMES[@]} - 1; i >= 0; i--)); do
    name="${NAMES[$i]}"
    state="$(hv_vm_state "$name")"
    if [[ "$state" == "running" || "$state" == "paused" ]]; then
      log "Stopping ${name}"
      lv_virsh shutdown "$name" >/dev/null || true
      local n=0
      while [[ "$(hv_vm_state "$name")" != "poweroff" && "$n" -lt "${PVE_STOP_WAIT:-300}" ]]; do
        sleep 5
        n=$((n + 5))
      done
      if [[ "$(hv_vm_state "$name")" != "poweroff" ]]; then
        log "Hard stop ${name}"
        lv_virsh destroy "$name" >/dev/null
      fi
    fi
  done
}

cmd_restore_services() {
  die "restore-services is not wired on libvirt yet. Use the Proxmox backend or run restore-held-services.ps1 in the guest."
}

case "$CMD" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  health) cmd_health ;;
  list) cmd_list ;;
  restore-services) cmd_restore_services ;;
  *) usage; exit 1 ;;
esac
