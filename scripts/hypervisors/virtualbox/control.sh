#!/usr/bin/env bash
# VirtualBox: ordered start / stop / status / health for lab VMs.

set -euo pipefail
HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/config.sh
source "${HV_DIR}/../../lib/config.sh"

CMD="${1:-}"
shift || true

DO_PROMPT=0
WAIT=1
BOOT_ORDER_FILE="${ROOT_DIR}/config/boot-order.tsv"

usage() {
  cat <<'EOF'
Usage: lab-ctl.sh <command> [options]

Commands:
  start [--no-wait]   Start VMs in boot-order (default waits between)
  stop                Power off VMs in reverse boot-order
  status              Show VMState for each lab VM
  health              status + VirtualBox disk and network checks
  list                List topology VMs and boot order

Options:
  --no-wait           Do not sleep wait_seconds between starts
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
require_cmd VBoxManage
# shellcheck source=guest-additions.sh
source "${HV_DIR}/guest-additions.sh"
[[ -f "$BOOT_ORDER_FILE" ]] || die "Boot order file missing: $BOOT_ORDER_FILE"

# Populate arrays NAME[] ORDER[] WAITSEC[] sorted by order ascending
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

vm_state() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null \
    | awk -F= '/^VMState=/{gsub(/"/,"",$2); print $2}' || echo "missing"
}

cmd_status() {
  load_boot_order
  local i
  printf '%-14s %-10s %s\n' "NAME" "STATE" "ORDER"
  for i in "${!NAMES[@]}"; do
    printf '%-14s %-10s %s\n' "${NAMES[$i]}" "$(vm_state "${NAMES[$i]}")" "${ORDERS[$i]}"
  done
}

cmd_list() {
  cmd_status
}

cmd_start() {
  load_boot_order
  local i name state
  ga_sudo_begin
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    state="$(vm_state "$name")"
    if [[ "$state" == "running" || "$state" == "paused" || "$state" == "missing" ]]; then
      continue
    fi
    ga_prepare_vm "$name"
  done
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    state="$(vm_state "$name")"
    if [[ "$state" == "missing" ]]; then
      warn "VM not registered: $name — skip"
      continue
    fi
    if [[ "$state" != "running" ]]; then
      log "Starting $name (order=${ORDERS[$i]})"
      VBoxManage startvm "$name" --type headless
    else
      log "$name already running"
    fi
    ga_wait_vm "$name"
    if [[ "$WAIT" -eq 1 ]]; then
      local w="${WAITSECS[$i]}"
      if [[ "$w" -gt 0 ]]; then
        log "Waiting ${w}s for $name to settle..."
        sleep "$w"
      fi
    fi
  done
  marker_set "${MARKERS_DIR}/lab-started.done"
  cmd_status
}

cmd_stop() {
  load_boot_order
  local i name state
  # reverse
  for (( i=${#NAMES[@]}-1; i>=0; i-- )); do
    name="${NAMES[$i]}"
    state="$(vm_state "$name")"
    if [[ "$state" == "missing" ]]; then
      continue
    fi
    if [[ "$state" == "poweroff" || "$state" == "aborted" ]]; then
      log "$name already off ($state)"
      continue
    fi
    log "Powering off $name"
    VBoxManage controlvm "$name" acpipowerbutton 2>/dev/null || true
    local t=0
    while [[ $t -lt 45 ]]; do
      state="$(vm_state "$name")"
      [[ "$state" == "poweroff" || "$state" == "aborted" ]] && break
      sleep 1
      t=$((t+1))
    done
    state="$(vm_state "$name")"
    if [[ "$state" != "poweroff" && "$state" != "aborted" ]]; then
      warn "ACPI slow — hard poweroff $name"
      VBoxManage controlvm "$name" poweroff || true
    fi
  done
  marker_set "${MARKERS_DIR}/lab-stopped.done"
  cmd_status
}

cmd_health() {
  load_boot_order
  local failed=0 i name state
  log "Lab health"
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    state="$(vm_state "$name")"
    if [[ "$state" == "missing" ]]; then
      printf '  [FAIL] %s not registered\n' "$name"
      failed=1
      continue
    fi
    printf '  [OK]   %s registered (state=%s)\n' "$name" "$state"
    # Disk attached?
    if VBoxManage showvminfo "$name" --machinereadable | rg -q 'SATA-0-0"=".*\.vdi"'; then
      printf '  [OK]   %s has SATA disk\n' "$name"
    else
      printf '  [FAIL] %s missing SATA disk\n' "$name"
      failed=1
    fi
    if VBoxManage showvminfo "$name" --machinereadable | rg -q 'nic1="intnet"'; then
      printf '  [OK]   %s on CorpNet (intnet)\n' "$name"
    else
      printf '  [FAIL] %s nic1 not intnet\n' "$name"
      failed=1
    fi
  done
  # Host free space under VM_ROOT
  local avail
  avail="$(bytes_available "$VM_ROOT")"
  printf '  [INFO] free on VM_ROOT filesystem: %s\n' "$(human_bytes "$avail")"
  if [[ "$failed" -ne 0 ]]; then
    die "Health check failed"
  fi
  marker_set "${MARKERS_DIR}/lab-health.ok"
  log "Health check PASSED"
}

case "$CMD" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  health) cmd_health ;;
  list)   cmd_list ;;
  *) usage; die "Unknown command: $CMD" ;;
esac
