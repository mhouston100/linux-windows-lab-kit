#!/usr/bin/env bash
# Proxmox: ordered start / stop / status / health for lab VMs.

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
  health              status + disk and bridge checks
  list                List topology VMs and boot order

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
pve_prepare
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

vm_vmid() {
  local row
  row="$(pve_guest_row "$1")" || die "No Proxmox vmid for $1"
  printf '%s\n' "${row%%$'\t'*}"
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

cmd_start() {
  load_boot_order
  local i name state started now elapsed w remain vmid
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    state="$(hv_vm_state "$name")"
    if [[ "$state" == "missing" ]]; then
      warn "VM not registered: $name — skip"
      continue
    fi
    vmid="$(vm_vmid "$name")"
    pve_plant_agent "$name"
    state="$(hv_vm_state "$name")"
    started="$(date +%s)"
    if [[ "$state" != "running" ]]; then
      log "Starting $name (order=${ORDERS[$i]})"
      pve_power "$vmid" start
    else
      log "$name already running"
    fi
    pve_wait_agent "$name" "$vmid"
    if [[ "$WAIT" -eq 1 ]]; then
      w="${WAITSECS[$i]}"
      if [[ "$w" -gt 0 ]]; then
        now="$(date +%s)"
        elapsed=$((now - started))
        if [[ "$elapsed" -lt "$w" ]]; then
          remain=$((w - elapsed))
          log "Waiting ${remain}s more for $name to settle (${elapsed}s of ${w}s already elapsed)"
          sleep "$remain"
        else
          log "$name settle time already elapsed (${elapsed}s, ${w}s required)"
        fi
      fi
    fi
  done
  marker_set "${MARKERS_DIR}/lab-started.done"
  cmd_status
}

cmd_stop() {
  load_boot_order
  local i name state vmid t
  for (( i=${#NAMES[@]}-1; i>=0; i-- )); do
    name="${NAMES[$i]}"
    state="$(hv_vm_state "$name")"
    if [[ "$state" == "missing" ]]; then
      continue
    fi
    if [[ "$state" == "poweroff" ]]; then
      log "$name already off ($state)"
      continue
    fi
    vmid="$(vm_vmid "$name")"
    log "Powering off $name"
    pve_power_try "$vmid" shutdown || true
    t=0
    while [[ $t -lt 45 ]]; do
      state="$(hv_vm_state "$name")"
      [[ "$state" == "poweroff" ]] && break
      sleep 1
      t=$((t+1))
    done
    state="$(hv_vm_state "$name")"
    if [[ "$state" != "poweroff" ]]; then
      warn "ACPI slow — hard poweroff $name"
      pve_power "$vmid" stop || true
    fi
  done
  marker_set "${MARKERS_DIR}/lab-stopped.done"
  cmd_status
}

cmd_health() {
  load_boot_order
  local failed=0 i name state vmid sata net0
  log "Lab health"
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    state="$(hv_vm_state "$name")"
    if [[ "$state" == "missing" ]]; then
      printf '  [FAIL] %s not registered\n' "$name"
      failed=1
      continue
    fi
    printf '  [OK]   %s registered (state=%s)\n' "$name" "$state"
    vmid="$(vm_vmid "$name")"
    sata="$(pve_config_value "$vmid" sata0)"
    if [[ -n "$sata" ]]; then
      printf '  [OK]   %s has SATA disk\n' "$name"
    else
      printf '  [FAIL] %s missing SATA disk\n' "$name"
      failed=1
    fi
    net0="$(pve_config_value "$vmid" net0)"
    if [[ "$net0" == *"bridge=${PVE_BRIDGE}"* ]]; then
      printf '  [OK]   %s on CorpNet bridge\n' "$name"
    else
      printf '  [FAIL] %s net0 is not the CorpNet bridge\n' "$name"
      failed=1
    fi
  done
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
