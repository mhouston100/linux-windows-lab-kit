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
  restore-services    Turn the services disabled on the disk (hold-services.tsv)
                      back on in every running guest, then start them

Options:
  --no-wait           Do not apply the settle time between starts. The settle time
                      counts from the moment the QEMU guest agent answers steadily
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
    if [[ "$state" != "running" ]]; then
      log "Starting $name (order=${ORDERS[$i]})"
      pve_power "$vmid" start
    else
      log "$name already running"
    fi
    pve_wait_agent "$name" "$vmid"
    # The settle time counts from the steady agent. On the first start the
    # guest restarts once after the agent first answers, and a guest that
    # needs this one (a domain controller) has to be back before the next starts.
    started="$(date +%s)"
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
    # SQL Server and Configuration Manager on a small guest can take minutes to
    # stop. A hard stop in the middle risks the databases, so the wait is long.
    t=0
    while [[ $t -lt "${PVE_STOP_WAIT:-300}" ]]; do
      state="$(hv_vm_state "$name")"
      [[ "$state" == "poweroff" ]] && break
      sleep 2
      t=$((t+2))
      if (( t % 60 == 0 )); then
        log "Still waiting for $name to shut down (${t}s)"
      fi
    done
    state="$(hv_vm_state "$name")"
    if [[ "$state" != "poweroff" ]]; then
      warn "$name did not shut down within ${PVE_STOP_WAIT:-300}s — hard poweroff"
      pve_power "$vmid" stop || true
    fi
  done
  marker_set "${MARKERS_DIR}/lab-stopped.done"
  cmd_status
}

# Runs restore-held-services.ps1 in each running guest through the guest agent.
# SQL Server and Configuration Manager can take many minutes to start.
cmd_restore_services() {
  load_boot_order
  local i name state vmid out rc failed=0
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    state="$(hv_vm_state "$name")"
    if [[ "$state" != "running" ]]; then
      log "$name is not running — skip"
      continue
    fi
    vmid="$(vm_vmid "$name")"
    pve_agent_ready "$vmid" || die "The guest agent on ${name} is not answering"
    log "Restoring held services on ${name}"
    set +e
    out="$(pve_agent_exec "$vmid" "${PVE_RESTORE_WAIT:-1800}" powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File 'C:\Windows\Temp\pve-ga\restore-held-services.ps1')"
    rc=$?
    set -e
    [[ -n "$out" ]] && log "${name}: ${out//$'\n'/ }"
    if [[ "$rc" -ne 0 ]]; then
      warn "${name}: some services did not start (exit ${rc}). See C:\\Windows\\Temp\\pve-ga\\restore-services.log"
      failed=1
    fi
  done
  [[ "$failed" -eq 0 ]] || exit 1
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
  restore-services) cmd_restore_services ;;
  *) usage; die "Unknown command: $CMD" ;;
esac
