#!/usr/bin/env bash
# Fixed terminal screen for lab.sh. No extra packages: ANSI, tput, and script(1)
# so a running stage still thinks it has a terminal (live progress) without
# painting over this layout.
#
# The stage list stays at the top. Each row has its own bar. Output from the
# stage is appended to the log pane at the bottom, which shows the newest lines.
#
# Severity, from low impact to high:
#   gray    informational, not started
#   green   finished successfully
#   orange  blocked, running, or otherwise needs attention
#   red     failed, or refused because an earlier stage has not finished

# shellcheck source=status.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/status.sh"

# id|phase-script|checkpoint marker|required marker (empty = none)|title
LAB_STAGES=(
  "1|phase1|phase1.ok||Extract and organize"
  "2|phase2|phase2.ok|phase1.ok|Convert disks"
  "3|phase3|phase3.ok|phase2.ok|Create VMs"
  "4|phase4|phase4.ok|phase3.ok|Identity templates"
  "5|phase5|phase5.ok|phase4.ok|Start and stop the lab"
  "6|phase6|phase6.ok|phase3.ok|Cleanup safety check"
)

# Log pane entries: "info|text", "ok|text", "warn|text", "error|text"
TUI_LOG=()
TUI_RUNNING=""
TUI_LIVE_PCT=""
TUI_BUF=""
TUI_CHILD=""
TUI_CANCEL=0
TUI_ALT=0
TUI_STTY=""

tui_enable_color() {
  C_RESET=""
  C_DIM=""
  C_GREEN=""
  C_ORANGE=""
  C_RED=""
  C_BOLD=""
  if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_DIM=$'\033[90m'
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_BOLD=$'\033[1m'
    if [[ "${TERM:-}" == *"256color"* || -n "${COLORTERM:-}" ]]; then
      C_ORANGE=$'\033[38;5;208m'
    else
      C_ORANGE=$'\033[33m'
    fi
  fi
}

tui_enter() {
  [[ "$TUI_ALT" -eq 1 ]] && return 0
  if [[ -t 0 ]]; then
    TUI_STTY="$(stty -g 2>/dev/null || true)"
  fi
  tput smcup 2>/dev/null || true
  printf '\033[?25l'
  TUI_ALT=1
  trap 'tui_leave' EXIT
}

tui_leave() {
  [[ "$TUI_ALT" -eq 0 ]] && return 0
  printf '\033[?25h'
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  if [[ -n "$TUI_STTY" && -t 0 ]]; then
    stty "$TUI_STTY" 2>/dev/null || true
  fi
  TUI_ALT=0
}

tui_log() {
  local level="$1"
  shift
  local text="$*"
  [[ -z "$text" ]] && return 0
  TUI_LOG+=("${level}|${text}")
  if [[ ${#TUI_LOG[@]} -gt 500 ]]; then
    TUI_LOG=("${TUI_LOG[@]: -500}")
  fi
  if [[ -n "${TMP_DIR:-}" ]]; then
    mkdir -p "$TMP_DIR" 2>/dev/null || true
    printf '%s %s\n' "$(date -Iseconds)" "$text" >>"${TMP_DIR}/lab.log" 2>/dev/null || true
  fi
}

tui_stage_fields() {
  local id="$1" entry
  for entry in "${LAB_STAGES[@]}"; do
    if [[ "${entry%%|*}" == "$id" ]]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done
  return 1
}

tui_stage_part() {
  local entry part="$2"
  entry="$(tui_stage_fields "$1")" || return 1
  case "$part" in
    script) printf '%s\n' "$(printf '%s' "$entry" | cut -d'|' -f2)" ;;
    checkpoint) printf '%s\n' "$(printf '%s' "$entry" | cut -d'|' -f3)" ;;
    requires) printf '%s\n' "$(printf '%s' "$entry" | cut -d'|' -f4)" ;;
    title) printf '%s\n' "$(printf '%s' "$entry" | cut -d'|' -f5)" ;;
  esac
}

tui_marker_present() {
  local name="$1"
  [[ -n "${MARKERS_DIR:-}" && -f "${MARKERS_DIR}/${name}" ]]
}

# Markers that move one stage's bar. Order is the order they are written.
tui_stage_markers() {
  case "$1" in
    1) printf '%s\n' "zip.done zpaq.done setup.done organize.done phase1.ok" ;;
    2) printf '%s\n' "convert.done phase2.ok" ;;
    3) printf '%s\n' "create-vms.done phase3.ok" ;;
    4) printf '%s\n' "identity.done phase4.ok" ;;
    5) printf '%s\n' "lab-started.done lab-health.ok lab-stopped.done phase5.ok" ;;
    6) printf '%s\n' "phase6.ok" ;;
  esac
}

tui_block_short() {
  local id="$1"
  local requires
  if [[ "$id" == "1" ]]; then
    if [[ ! -f "${LAB_ZIP_PATH:-}" ]]; then
      printf 'kit ZIP not found'
    fi
    return 0
  fi
  requires="$(tui_stage_part "$id" requires)"
  if [[ -n "$requires" ]] && ! tui_marker_present "$requires"; then
    case "$requires" in
      phase1.ok) printf 'extract the kit first (stage 1)' ;;
      phase2.ok) printf 'convert the disks first (stage 2)' ;;
      phase3.ok) printf 'create the VMs first (stage 3)' ;;
      phase4.ok) printf 'render identity first (stage 4)' ;;
      *) printf 'finish %s first' "$requires" ;;
    esac
  fi
}

tui_block_reason() {
  local id="$1"
  local short title
  short="$(tui_block_short "$id")"
  [[ -n "$short" ]] || return 0
  title="$(tui_stage_part "$id" title)"
  printf '%s is blocked. %s.\n' "$title" "$(tr '[:lower:]' '[:upper:]' <<< "${short:0:1}")${short:1}"
}

tui_stage_state() {
  local id="$1"
  local checkpoint
  checkpoint="$(tui_stage_part "$id" checkpoint)"
  if tui_marker_present "$checkpoint"; then
    printf 'done\n'
    return 0
  fi
  if [[ "$TUI_RUNNING" == "$id" ]]; then
    printf 'running\n'
    return 0
  fi
  if [[ -n "$(tui_block_short "$id")" ]]; then
    printf 'blocked\n'
  else
    printf 'ready\n'
  fi
}

# 0-100 for the bar on one stage row.
tui_stage_pct() {
  local id="$1"
  local state markers marker count=0 have=0 base=0
  state="$(tui_stage_state "$id")"
  if [[ "$state" == "done" ]]; then
    printf '100\n'
    return 0
  fi
  if [[ "$state" == "blocked" ]]; then
    printf '0\n'
    return 0
  fi
  markers="$(tui_stage_markers "$id")"
  for marker in $markers; do
    count=$((count + 1))
    if tui_marker_present "$marker"; then
      have=$((have + 1))
    fi
  done
  if [[ "$count" -gt 0 ]]; then
    base=$((have * 100 / count))
  fi
  if [[ "$TUI_RUNNING" == "$id" && -n "$TUI_LIVE_PCT" && "$TUI_LIVE_PCT" -gt "$base" ]]; then
    base="$TUI_LIVE_PCT"
  fi
  if [[ "$TUI_RUNNING" == "$id" && "$base" -eq 0 ]]; then
    base=3
  fi
  if [[ "$TUI_RUNNING" == "$id" && "$base" -ge 100 ]]; then
    base=99
  fi
  printf '%s\n' "$base"
}

tui_bar_plain() {
  local pct="$1"
  local width="$2"
  local filled empty
  [[ "$pct" -lt 0 ]] && pct=0
  [[ "$pct" -gt 100 ]] && pct=100
  filled=$((pct * width / 100))
  empty=$((width - filled))
  if [[ "$filled" -gt 0 ]]; then
    printf '%*s' "$filled" '' | tr ' ' '#'
  fi
  if [[ "$empty" -gt 0 ]]; then
    printf '%*s' "$empty" '' | tr ' ' '-'
  fi
}

tui_fit() {
  local text="$1"
  local max="$2"
  if [[ ${#text} -gt "$max" ]]; then
    printf '%s' "${text:0:max}"
  else
    printf '%s' "$text"
  fi
}

tui_row() {
  local color="$1"
  local text="$2"
  local cols="${3:-80}"
  local nl="${4:-1}"
  text="$(tui_fit "$text" "$((cols - 1))")"
  if [[ "$nl" -eq 1 ]]; then
    printf '%b%s%b\033[K\n' "$color" "$text" "$C_RESET"
  else
    printf '%b%s%b\033[K' "$color" "$text" "$C_RESET"
  fi
}

tui_classify() {
  local line="$1"
  if [[ "$line" == *"ERROR:"* || "$line" == *"status: failed"* || "$line" == *"[FAIL]"* ]]; then
    printf 'error\n'
  elif [[ "$line" == *"WARNING:"* || "$line" == *"status: incomplete"* ]]; then
    printf 'warn\n'
  elif [[ "$line" == *"status: ok"* || "$line" == *"Step complete"* || "$line" == *"PASSED"* || "$line" == *"[OK]"* ]]; then
    printf 'ok\n'
  else
    printf 'info\n'
  fi
}

tui_ingest_line() {
  local line="$1" level n
  line="$(printf '%s' "$line" | sed $'s/\033\\[[0-9;]*[[:alpha:]]//g')"
  line="${line//$'\r'/}"
  [[ -z "$line" ]] && return 0
  level="$(tui_classify "$line")"
  tui_log "$level" "$line"
  if [[ "$line" =~ ([0-9]{1,3})% ]]; then
    n="${BASH_REMATCH[1]}"
    [[ "$n" -gt 100 ]] && n=100
    TUI_LIVE_PCT="$n"
  fi
}

# Split the read buffer on CR/LF. Progress tools often update with CR only.
tui_pump_buf() {
  local part a b
  while [[ "$TUI_BUF" == *$'\n'* || "$TUI_BUF" == *$'\r'* ]]; do
    a="${TUI_BUF%%$'\n'*}"
    b="${TUI_BUF%%$'\r'*}"
    if [[ ${#a} -le ${#b} ]]; then
      part="$a"
    else
      part="$b"
    fi
    TUI_BUF="${TUI_BUF:$((${#part} + 1))}"
    tui_ingest_line "$part"
  done
}

tui_draw() {
  local cols rows id title state pct bar word color plain
  local note level text shown start idx
  cols="$(tput cols 2>/dev/null || echo 80)"
  rows="$(tput lines 2>/dev/null || echo 24)"
  [[ "$cols" -lt 40 ]] && cols=40
  [[ "$rows" -lt 16 ]] && rows=16

  printf '\033[H'
  tui_row "$C_BOLD" "Linux Windows Lab Kit" "$cols"
  tui_row "$C_DIM" "  kit   ${LAB_ZIP_PATH:-<unset>}" "$cols"
  tui_row "$C_DIM" "  dest  ${VM_ROOT:-<unset>}    source=${SOURCE_DIR:-<unset>}  tmp=${TMP_DIR:-<unset>}" "$cols"
  tui_row "$C_DIM" "  log   ${TMP_DIR:-<unset>}/lab.log" "$cols"
  tui_row "" "" "$cols"

  for id in 1 2 3 4 5 6; do
    title="$(tui_stage_part "$id" title)"
    state="$(tui_stage_state "$id")"
    pct="$(tui_stage_pct "$id")"
    bar="$(tui_bar_plain "$pct" 16)"
    case "$state" in
      done) color="$C_GREEN"; word="done" ;;
      running) color="$C_ORANGE"; word="running" ;;
      blocked) color="$C_ORANGE"; word="blocked" ;;
      *) color="$C_DIM"; word="ready" ;;
    esac
    if [[ "$state" == "done" ]]; then
      plain="$(printf ' ✓ %s %-22.22s [%s] %3d%%  %s' "$id" "$title" "$bar" "$pct" "$word")"
    else
      plain="$(printf '   %s %-22.22s [%s] %3d%%  %s' "$id" "$title" "$bar" "$pct" "$word")"
    fi
    tui_row "$color" "$plain" "$cols"
  done

  tui_row "" "" "$cols"
  tui_row "$C_BOLD" "Log" "$cols"

  # Title, kit, dest, log path, blank, 6 stages, blank, "Log" = 13. Last row is the prompt.
  local log_h=$((rows - 14))
  [[ "$log_h" -lt 2 ]] && log_h=2
  local count="${#TUI_LOG[@]}"
  start=0
  if [[ "$count" -gt "$log_h" ]]; then
    start=$((count - log_h))
  fi
  shown=0
  for ((idx = start; idx < count; idx++)); do
    note="${TUI_LOG[$idx]}"
    level="${note%%|*}"
    text="${note#*|}"
    case "$level" in
      ok) color="$C_GREEN" ;;
      warn) color="$C_ORANGE" ;;
      error) color="$C_RED" ;;
      *) color="$C_DIM" ;;
    esac
    tui_row "$color" "  $text" "$cols"
    shown=$((shown + 1))
  done
  while [[ "$shown" -lt "$log_h" ]]; do
    tui_row "" "" "$cols"
    shown=$((shown + 1))
  done

  if [[ "$TUI_RUNNING" == "reset" ]]; then
    tui_row "$C_ORANGE" "Resetting this lab. Interrupt returns to the menu." "$cols" 0
  elif [[ -n "$TUI_RUNNING" ]]; then
    tui_row "$C_ORANGE" "Running stage ${TUI_RUNNING}. Interrupt returns to the menu." "$cols" 0
  else
    tui_row "$C_BOLD" "Press 1-6, a = run all, c = reset lab, q = quit" "$cols" 0
  fi
  printf '\033[J'
}

# Ctrl+C is a byte while ISIG is off. bash read turns ISIG back on, so this
# uses dd and leaves the terminal settings alone.
tui_poll_cancel() {
  local key=""
  [[ -t 0 && -r /dev/tty ]] || return 0
  key="$(dd if=/dev/tty bs=1 count=1 status=none iflag=nonblock 2>/dev/null || true)"
  if [[ "$key" == $'\003' ]]; then
    TUI_CANCEL=1
  fi
}

tui_stop_capture() {
  local pid="$1" sig="${2:-TERM}" kids grand="" k
  [[ -z "$pid" ]] && return 0
  kids="$(ps -o pid= --ppid "$pid" 2>/dev/null || true)"
  for k in $kids; do
    grand+=" $(ps -o pid= --ppid "$k" 2>/dev/null || true)"
  done
  # shellcheck disable=SC2086
  kill -"$sig" $grand $kids "$pid" 2>/dev/null || true
}

# Run a command under a private pty and fold its output into the log pane.
# Returns the command's exit code.
tui_capture() {
  local cmd="$1"
  local fifo ts spid piece rc=0 prev_int i
  fifo="$(mktemp -u /tmp/lab-tui.XXXXXX)"
  ts="$(mktemp /tmp/lab-tui-ts.XXXXXX)"
  mkfifo "$fifo"
  TUI_BUF=""
  TUI_CANCEL=0
  TUI_LIVE_PCT=""
  prev_int="$(trap -p INT || true)"
  set +e
  # Read-write open does not block. A plain read open would wait for the
  # writer, and Ctrl+C in that window would leave the screen.
  exec 7<>"$fifo"
  # Ignore SIGINT for the duration. Ctrl+C is read as a byte below.
  # A trap that kills the stage hits a bash longjmp bug and drops the menu.
  trap '' INT
  if [[ -t 0 ]]; then
    stty -isig -icanon -echo min 1 time 0 2>/dev/null || true
  fi
  script -q -e -f -c "$cmd" "$ts" >"$fifo" 2>>"$ts" &
  spid=$!
  TUI_CHILD="$spid"
  while kill -0 "$spid" 2>/dev/null; do
    tui_poll_cancel
    if [[ "$TUI_CANCEL" -eq 1 ]]; then
      tui_stop_capture "$spid" TERM
      break
    fi
    piece=""
    IFS= read -r -t 0.2 -N 512 -u 7 piece || true
    tui_poll_cancel
    if [[ -n "$piece" ]]; then
      TUI_BUF+="$piece"
      tui_pump_buf
    fi
    [[ -t 1 ]] && tui_draw
  done
  while true; do
    piece=""
    IFS= read -r -t 0.05 -N 512 -u 7 piece || true
    [[ -z "$piece" ]] && break
    TUI_BUF+="$piece"
    tui_pump_buf
  done
  if [[ -n "$TUI_BUF" ]]; then
    tui_ingest_line "$TUI_BUF"
    TUI_BUF=""
  fi
  if [[ "$TUI_CANCEL" -eq 1 ]]; then
    tui_stop_capture "$spid" TERM
    for i in 1 2 3 4 5; do
      kill -0 "$spid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$spid" 2>/dev/null && tui_stop_capture "$spid" KILL
  fi
  wait "$spid"
  rc=$?
  if [[ -n "$prev_int" ]]; then
    eval "$prev_int"
  else
    trap - INT
  fi
  exec 7<&-
  rm -f "$fifo" "$ts"
  TUI_CHILD=""
  if [[ -n "$TUI_STTY" && -t 0 ]]; then
    stty "$TUI_STTY" 2>/dev/null || true
  fi
  # Leave set +e in place. Turning set -e back on before a non-zero return
  # makes bash exit the whole script instead of coming back to the menu.
  if [[ "$TUI_CANCEL" -eq 1 ]]; then
    return 130
  fi
  return "$rc"
}

tui_run_stage() {
  local id="$1"
  local reason script title rc cmd
  title="$(tui_stage_part "$id" title)" || return 1
  reason="$(tui_block_reason "$id")"
  if [[ -n "$reason" ]]; then
    tui_log error "$reason"
    if [[ -t 1 && "$TUI_ALT" -eq 1 ]]; then
      tui_draw
    else
      printf '%b%s%b\n' "$C_RED" "$reason" "$C_RESET" >&2
    fi
    return 1
  fi
  script="$(tui_stage_part "$id" script)"
  if [[ ! -t 1 ]]; then
    "${SCRIPTS_DIR}/${script}.sh" --no-prompt ${LAB_FORWARD[@]+"${LAB_FORWARD[@]}"}
    return $?
  fi

  tui_enter
  if [[ "$(tui_stage_state "$id")" == "done" ]]; then
    tui_log info "Stage $id already done. Finished steps will be skipped."
  fi
  if [[ "$id" == "5" ]]; then
    tui_log warn "Stage 5 powers the lab VMs on, then stops them."
  fi
  hv_load
  if hv_stage_needs_privileges "$id"; then
    hv_prepare_privileged
  fi
  tui_log warn "Starting stage $id — $title"
  TUI_RUNNING="$id"
  TUI_LIVE_PCT=""
  cmd="$(printf '%q ' env LAB_LOG_CAPTURE=1 ${GA_ROOT_DIR:+GA_ROOT_DIR="$GA_ROOT_DIR"} "${SCRIPTS_DIR}/${script}.sh" --no-prompt ${LAB_FORWARD[@]+"${LAB_FORWARD[@]}"})"
  set +e
  tui_capture "$cmd"
  rc=$?
  hv_finish_privileged
  set -e
  TUI_RUNNING=""
  TUI_LIVE_PCT=""
  if [[ "$rc" -eq 0 ]]; then
    tui_log ok "Stage $id finished — $title."
  elif [[ "$rc" -eq 130 ]]; then
    tui_log error "Stage $id interrupted."
  else
    tui_log error "Stage $id failed (exit $rc) — $title."
  fi
  [[ -t 1 ]] && tui_draw
  return "$rc"
}

tui_run_all() {
  local id state
  for id in 1 2 3 4 5 6; do
    state="$(tui_stage_state "$id")"
    if [[ "$state" == "done" ]]; then
      tui_log info "Stage $id already done — skipped."
      [[ -t 1 && "$TUI_ALT" -eq 1 ]] && tui_draw
      continue
    fi
    if [[ "$state" == "blocked" ]]; then
      tui_log error "$(tui_block_reason "$id")"
      [[ -t 1 && "$TUI_ALT" -eq 1 ]] && tui_draw
      return 1
    fi
    tui_run_stage "$id" || return $?
  done
  tui_log ok "Run all finished."
  [[ -t 1 && "$TUI_ALT" -eq 1 ]] && tui_draw
  return 0
}

# YES is read on the real terminal. A stage's captured pty cannot see the keyboard.
tui_confirm_reset() {
  local reply=""
  tui_log warn "Reset deletes the lab VMs, their folders, and source/. tmp is cleared except lab.log. The kit ZIP is kept."
  [[ -t 1 && "$TUI_ALT" -eq 1 ]] && tui_draw
  printf '\033[?25h'
  stty echo icanon isig 2>/dev/null || true
  printf '%bType YES to reset this lab: %b' "$C_BOLD" "$C_RESET" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  if [[ -n "$TUI_STTY" && -t 0 ]]; then
    stty "$TUI_STTY" 2>/dev/null || true
  fi
  printf '\033[?25l'
  if [[ "$reply" != "YES" ]]; then
    tui_log warn "Reset cancelled."
    return 1
  fi
  return 0
}

tui_run_reset() {
  local rc cmd
  tui_log warn "Resetting the lab."
  TUI_RUNNING="reset"
  TUI_LIVE_PCT=""
  cmd="$(printf '%q ' env LAB_NONINTERACTIVE=1 LAB_LOG_CAPTURE=1 "${SCRIPTS_DIR}/cleanup-lab.sh" --reset --yes)"
  set +e
  tui_capture "$cmd"
  rc=$?
  set -e
  TUI_RUNNING=""
  TUI_LIVE_PCT=""
  if [[ "$rc" -eq 0 ]]; then
    tui_log ok "Lab reset. Stages will run again from the start."
  elif [[ "$rc" -eq 130 ]]; then
    tui_log error "Reset interrupted."
  else
    tui_log error "Reset failed (exit ${rc})."
  fi
  [[ -t 1 ]] && tui_draw
  return "$rc"
}

tui_menu() {
  local choice
  tui_enter
  trap 'tui_leave; exit 130' INT
  trap 'tui_leave' EXIT
  tui_log info "Session log: ${TMP_DIR:-<unset>}/lab.log"
  tui_log info "Pick a stage. A blocked stage runs only after the stage it depends on has finished. c resets this lab."
  while true; do
    TUI_RUNNING=""
    tui_draw
    printf '\033[?25h'
    # One key, shown as it is typed. Line reads hid the key and waited for Enter.
    stty echo -icanon isig min 1 time 0 2>/dev/null || true
    choice="$(dd if=/dev/tty bs=1 count=1 status=none 2>/dev/null || true)"
    stty "$TUI_STTY" 2>/dev/null || stty echo icanon isig 2>/dev/null || true
    printf '\033[?25l'
    [[ -n "$choice" ]] || { tui_leave; exit 0; }
    case "$choice" in
      q|Q)
        tui_leave
        trap - EXIT
        exit 0
        ;;
      a|A|all)
        tui_log warn "Selected run all."
        tui_run_all || true
        ;;
      [1-6])
        tui_log warn "Selected stage $choice."
        tui_run_stage "$choice" || true
        ;;
      c|C)
        tui_confirm_reset && tui_run_reset || true
        ;;
      "")
        ;;
      *)
        tui_log warn "Enter 1-6, a, c, or q."
        ;;
    esac
  done
}
