#!/usr/bin/env bash
# Checklist printed for a human watching a terminal.
# "Accomplished" is historical: each marker file holds the timestamp written
# when that step last succeeded. "Outstanding" is every step that has no marker.
# Missing markers are normal on a fresh dest; they are not an error by themselves.

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# marker-file|label   (order is the order an operator should expect)
LAB_TASKS=(
  "zip.done|Phase 1 — extract lab ZIP"
  "zpaq.done|Phase 1 — extract ZPAQ payload"
  "setup.done|Phase 1 — unpack setup.exe resources"
  "organize.done|Phase 1 — organize disks and VM trees"
  "phase1.ok|Phase 1 — checkpoint passed"
  "convert.done|Phase 2 — convert disks"
  "phase2.ok|Phase 2 — checkpoint passed"
  "create-vms.done|Phase 3 — create VMs"
  "phase3.ok|Phase 3 — checkpoint passed"
  "identity.done|Phase 4 — render identity templates"
  "phase4.ok|Phase 4 — checkpoint passed"
  "lab-started.done|Phase 5 — lab started"
  "lab-health.ok|Phase 5 — health check passed"
  "lab-stopped.done|Phase 5 — lab stopped"
  "phase5.ok|Phase 5 — checkpoint passed"
  "phase6.ok|Phase 6 — cleanup safety check passed"
)

LAB_DONE_N=0
LAB_TODO_N=0

# Recount marker files. Used by the plain checklist and the menu.
lab_count_tasks() {
  local entry marker
  LAB_DONE_N=0
  LAB_TODO_N=0
  for entry in "${LAB_TASKS[@]}"; do
    marker="${entry%%|*}"
    if [[ -n "${MARKERS_DIR:-}" && -f "${MARKERS_DIR}/${marker}" ]]; then
      LAB_DONE_N=$((LAB_DONE_N + 1))
    else
      LAB_TODO_N=$((LAB_TODO_N + 1))
    fi
  done
}

print_checklist() {
  local entry marker label when
  local -a done_lines=() todo_lines=()
  lab_count_tasks

  printf '\nChecklist\n'
  printf '  kit:  %s\n' "${LAB_ZIP_PATH:-<unset>}"
  printf '  dest: %s\n' "${VM_ROOT:-<unset>}"
  printf '        source=%s\n' "${SOURCE_DIR:-<unset>}"
  printf '        tmp=%s\n' "${TMP_DIR:-<unset>}"

  for entry in "${LAB_TASKS[@]}"; do
    marker="${entry%%|*}"
    label="${entry#*|}"
    if [[ -n "${MARKERS_DIR:-}" && -f "${MARKERS_DIR}/${marker}" ]]; then
      when="$(tr -d '\n' <"${MARKERS_DIR}/${marker}")"
      done_lines+=("$(printf '  [done] %-32s  %s' "$when" "$label")")
    else
      todo_lines+=("$(printf '  [todo] %s' "$label")")
    fi
  done

  printf '\nAccomplished (%s)\n' "$LAB_DONE_N"
  if [[ ${#done_lines[@]} -eq 0 ]]; then
    printf '  (none yet)\n'
  else
    printf '%s\n' "${done_lines[@]}"
  fi

  printf '\nOutstanding (%s)\n' "$LAB_TODO_N"
  if [[ ${#todo_lines[@]} -eq 0 ]]; then
    printf '  (none)\n'
  else
    printf '%s\n' "${todo_lines[@]}"
  fi
  printf '\n'
}

# Preserve a failing exit code. Bash would otherwise replace it with the
# status of the last command inside the EXIT trap.
lab_install_exit_trap() {
  trap 'lab_on_exit $?' EXIT
}

lab_on_exit() {
  local rc="$1"
  if [[ "$rc" -ne 0 ]]; then
    # Show the same history on failure, once paths have been resolved.
    if [[ -n "${VM_ROOT:-}" ]]; then
      print_checklist || true
    fi
    printf 'status: failed (exit %s)\n' "$rc" >&2
    exit "$rc"
  fi
}

lab_status_ok() {
  printf 'status: ok (exit 0)\n'
}
