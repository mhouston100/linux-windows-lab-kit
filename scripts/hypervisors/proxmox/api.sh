#!/usr/bin/env bash
# Proxmox VE API. The token secret is written only into a short-lived curl
# config file, mode 600, and that file is removed before any error is printed.

pve_quote() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

pve_scrub() {
  local text="$1"
  PVE_TOKEN_SECRET="$PVE_TOKEN_SECRET" python3 -c 'import os,sys
secret=os.environ.get("PVE_TOKEN_SECRET","")
text=sys.stdin.read()
if secret:
    text=text.replace(secret,"[redacted]")
sys.stdout.write(text[:400])' <<<"$text"
}

pve_norm_fp() {
  python3 -c 'import sys
text=sys.argv[1].strip().upper()
if text.startswith("SHA256:"):
    text=text[7:]
text=text.replace(":","").replace(" ","")
if len(text)!=64 or any(ch not in "0123456789ABCDEF" for ch in text):
    sys.exit(1)
print(":".join(text[i:i+2] for i in range(0,64,2)))' "$1"
}

pve_require_settings() {
  # A saved value wins. These fill the fields the menu also starts with.
  : "${PVE_NODE:=pve}"
  : "${PVE_IMPORT_STORAGE:=local}"
  : "${PVE_STORAGE:=local-lvm}"
  : "${PVE_BRIDGE:=vmbr1}"
  : "${PVE_INTERNET_BRIDGE:=vmbr0}"
  : "${PVE_TOKEN_ID:=root@pam!root}"
  : "${PVE_KEEP_IMPORTS:=0}"
  : "${PVE_SSH_USER:=root}"
  : "${PVE_SSH_PORT:=22}"
  : "${PVE_RSYNC_TRIES:=5}"
  [[ -n "${PVE_API_HOST:-}" ]] || die "Set the Proxmox API host"
  [[ -n "${PVE_NODE:-}" ]] || die "Set the Proxmox node"
  [[ -n "${PVE_IMPORT_STORAGE:-}" ]] || die "Set the Proxmox import storage"
  [[ -n "${PVE_STORAGE:-}" ]] || die "Set the Proxmox disk storage"
  [[ -n "${PVE_BRIDGE:-}" ]] || die "Set the CorpNet bridge"
  [[ -n "${PVE_INTERNET_BRIDGE:-}" ]] || die "Set the Internet bridge"
  [[ "${PVE_TOKEN_ID:-}" == *@*!* ]] || die "Proxmox token id must look like user@realm!token"
  [[ -n "${PVE_TOKEN_SECRET:-}" ]] || die "Set the Proxmox API token secret"
  [[ "$PVE_SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]{0,31}$ ]] || die "SSH user must be a plain account name"
  [[ "$PVE_SSH_PORT" =~ ^[0-9]+$ && "$PVE_SSH_PORT" -ge 1 && "$PVE_SSH_PORT" -le 65535 ]] || die "SSH port is not a number"
  [[ "${PVE_RSYNC_TRIES}" =~ ^[0-9]+$ && "$PVE_RSYNC_TRIES" -ge 1 ]] || die "Rsync tries must be a number"
  command -v curl >/dev/null 2>&1 || die "curl is required to call the Proxmox API"
  command -v openssl >/dev/null 2>&1 || die "openssl is required to check the Proxmox certificate"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read Proxmox API replies"
  command -v ssh >/dev/null 2>&1 || die "ssh is required to copy disk images"
  command -v rsync >/dev/null 2>&1 || die "rsync is required to copy disk images"
}

pve_split_host() {
  local host="${PVE_API_HOST}"
  PVE_PORT=8006
  if [[ "$host" == *:* ]]; then
    PVE_PORT="${host##*:}"
    host="${host%%:*}"
  fi
  PVE_HOST="$host"
  [[ "$PVE_PORT" =~ ^[0-9]+$ ]] || die "Proxmox API port is not a number"
}

pve_pin_cert() {
  local pem want got
  if [[ -z "${PVE_TLS_FINGERPRINT:-}" ]]; then
    PVE_CA_FILE=""
    log "TLS fingerprint is blank. The API certificate is not checked."
    return 0
  fi
  pem="${PVE_RUNTIME}/cert.pem"
  want="$(pve_norm_fp "$PVE_TLS_FINGERPRINT")" || die "Proxmox TLS fingerprint must be a SHA256 hex string"
  # s_client returns non-zero for a private certificate even when the
  # certificate was printed. The fingerprint comparison below is the check.
  set +e +o pipefail
  if [[ "$PVE_HOST" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    openssl s_client -connect "${PVE_HOST}:${PVE_PORT}" </dev/null 2>/dev/null \
      | openssl x509 -outform PEM >"$pem"
  else
    openssl s_client -connect "${PVE_HOST}:${PVE_PORT}" -servername "$PVE_HOST" </dev/null 2>/dev/null \
      | openssl x509 -outform PEM >"$pem"
  fi
  set -e -o pipefail
  [[ -s "$pem" ]] || die "Could not read the Proxmox certificate from ${PVE_HOST}:${PVE_PORT}"
  got="$(openssl x509 -in "$pem" -noout -fingerprint -sha256 2>/dev/null || true)"
  got="${got#*=}"
  got="$(pve_norm_fp "$got")" || die "Could not read the Proxmox certificate fingerprint"
  [[ "$got" == "$want" ]] || die "Proxmox certificate fingerprint is ${got}. The saved fingerprint is ${want}."
  PVE_CA_FILE="$pem"
}

pve_prepare() {
  [[ "${PVE_READY:-}" == 1 ]] && return 0
  pve_require_settings
  pve_split_host
  PVE_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/lab-pve.XXXXXX")"
  chmod 700 "$PVE_RUNTIME"
  pve_pin_cert
  PVE_READY=1
}

pve_base() {
  printf 'https://%s:%s/api2/json' "$PVE_HOST" "$PVE_PORT"
}

# $1 method, $2 path. Further args are curl arguments (form fields, not the token).
pve_call() {
  local method="$1" path="$2" cfg http rc
  shift 2
  pve_prepare
  cfg="$(mktemp "${PVE_RUNTIME}/curl.XXXXXX")"
  chmod 600 "$cfg"
  {
    printf 'silent\n'
    printf 'show-error\n'
    printf 'connect-timeout = 20\n'
    if [[ -n "${PVE_CA_FILE:-}" ]]; then
      printf 'cacert = "%s"\n' "$PVE_CA_FILE"
    else
      printf 'insecure\n'
    fi
    printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PVE_TOKEN_ID" "$PVE_TOKEN_SECRET"
    printf 'header = "Accept: application/json"\n'
    printf 'request = "%s"\n' "$method"
    printf 'url = "%s%s"\n' "$(pve_base)" "$path"
  } >"$cfg"
  PVE_RESPONSE_FILE="$(mktemp "${PVE_RUNTIME}/body.XXXXXX")"
  set +e
  http="$("${PVE_CURL:-curl}" --config "$cfg" --output "$PVE_RESPONSE_FILE" --write-out '%{http_code}' "$@")"
  rc=$?
  set -e
  rm -f "$cfg"
  PVE_HTTP="$http"
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$PVE_RESPONSE_FILE"
    die "Could not reach the Proxmox API (${method} ${path}, curl ${rc})"
  fi
  PVE_RESPONSE="$(cat "$PVE_RESPONSE_FILE" 2>/dev/null || true)"
  rm -f "$PVE_RESPONSE_FILE"
}

pve_expect() {
  local method="$1" path="$2"
  if [[ "${PVE_HTTP:-}" == 2* ]]; then
    return 0
  fi
  die "Proxmox API ${method} ${path} failed (HTTP ${PVE_HTTP:-none}): $(pve_scrub "$PVE_RESPONSE")"
}

pve_upid() {
  printf '%s' "$1" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin).get("data")
except Exception:
    data=None
print(data if isinstance(data,str) and data.startswith("UPID:") else "")'
}

pve_wait_task() {
  local upid="$1" encoded status exitstatus started now
  encoded="$(pve_quote "$upid")"
  started="$(date +%s)"
  while true; do
    pve_call GET "/nodes/$(pve_quote "$PVE_NODE")/tasks/${encoded}/status"
    pve_expect GET "/nodes/${PVE_NODE}/tasks/UPID/status"
    status="$(printf '%s' "$PVE_RESPONSE" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("data") or {}).get("status") or "")')"
    exitstatus="$(printf '%s' "$PVE_RESPONSE" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("data") or {}).get("exitstatus") or "")')"
    if [[ "$status" == "stopped" ]]; then
      [[ "$exitstatus" == "OK" ]] || die "Proxmox task failed (${exitstatus})"
      return 0
    fi
    now="$(date +%s)"
    if (( now - started > 0 && (now - started) % 30 < 2 )); then
      log "Proxmox task still running"
    fi
    sleep 2
  done
}

pve_follow() {
  local upid
  upid="$(pve_upid "$1")"
  [[ -n "$upid" ]] || return 0
  pve_wait_task "$upid"
}

pve_resources() {
  pve_call GET "/cluster/resources?type=vm"
  pve_expect GET "/cluster/resources?type=vm"
  printf '%s' "$PVE_RESPONSE" | python3 -c 'import json,sys
rows=json.load(sys.stdin).get("data") or []
for row in rows:
    if row.get("type") != "qemu":
        continue
    print("\t".join(str(row.get(k) or "") for k in ("vmid","name","node","status")))'
}

# Prints "vmid node status" for a guest name. Returns 1 when the name is absent.
pve_find_name() {
  local want="$1" vmid name node status
  while IFS=$'\t' read -r vmid name node status || [[ -n "${vmid:-}" ]]; do
    [[ -n "${vmid:-}" ]] || continue
    if [[ "$name" == "$want" ]]; then
      printf '%s\t%s\t%s\n' "$vmid" "$node" "$status"
      return 0
    fi
  done < <(pve_resources)
  return 1
}

pve_state_word() {
  case "$1" in
    running) printf 'running' ;;
    stopped) printf 'poweroff' ;;
    paused|suspended) printf 'paused' ;;
    "") printf 'missing' ;;
    *) printf '%s' "$1" ;;
  esac
}

pve_form() {
  python3 -c 'import sys,urllib.parse
args=sys.argv[1:]
pairs=[]
if len(args)%2:
    sys.exit(2)
for i in range(0,len(args),2):
    pairs.append(urllib.parse.urlencode({args[i]:args[i+1]}))
print("&".join(pairs))' "$@"
}

pve_guest_row() {
  local want="$1" name vmid ostype file
  file="${ROOT_DIR}/config/hypervisors/proxmox/guests.tsv"
  [[ -f "$file" ]] || die "Proxmox guest map not found: $file"
  while IFS=$'\t' read -r name vmid ostype || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue
    if [[ "$name" == "$want" ]]; then
      [[ "$vmid" =~ ^[0-9]+$ ]] || die "Proxmox vmid for ${want} is not a number"
      printf '%s\t%s\n' "$vmid" "$ostype"
      return 0
    fi
  done <"$file"
  return 1
}

pve_config_value() {
  local vmid="$1" key="$2"
  pve_call GET "/nodes/$(pve_quote "$PVE_NODE")/qemu/${vmid}/config"
  pve_expect GET "/nodes/${PVE_NODE}/qemu/${vmid}/config"
  printf '%s' "$PVE_RESPONSE" | python3 -c 'import json,sys
key=sys.argv[1]
print((json.load(sys.stdin).get("data") or {}).get(key) or "")' "$key"
}

pve_power() {
  pve_power_try "$@" || die "Proxmox ${2} failed for VMID ${1}"
}

pve_power_try() {
  local vmid="$1" action="$2" path body
  path="/nodes/$(pve_quote "$PVE_NODE")/qemu/${vmid}/status/${action}"
  pve_call POST "$path"
  [[ "${PVE_HTTP:-}" == 2* ]] || return 1
  body="$PVE_RESPONSE"
  pve_follow "$body"
}

pve_agent_ready() {
  local vmid="$1"
  pve_call GET "/nodes/$(pve_quote "$PVE_NODE")/qemu/${vmid}/agent/ping"
  [[ "${PVE_HTTP:-}" == 200 ]]
}

pve_wait_agent() {
  local name="$1" vmid="$2" max="${PVE_AGENT_WAIT:-1800}" elapsed=0 off=0 state
  log "Waiting up to ${max}s for the QEMU guest agent on ${name}"
  while [[ "$elapsed" -lt "$max" ]]; do
    state="$(hv_vm_state "$name")"
    if [[ "$state" == "running" ]] && pve_agent_ready "$vmid"; then
      log "QEMU guest agent answered on ${name}"
      return 0
    fi
    if [[ "$state" == "poweroff" || "$state" == "missing" ]]; then
      off=$((off + 10))
      if [[ "$off" -ge 120 && "$elapsed" -gt 60 ]]; then
        die "${name} stayed off. The QEMU guest agent is not planted in the disk yet."
      fi
    else
      off=0
    fi
    if (( elapsed > 0 && elapsed % 30 == 0 )); then
      log "Still waiting for the QEMU guest agent on ${name} (${elapsed}s)"
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  die "Timed out waiting for the QEMU guest agent on ${name}. The agent is not planted in the disk yet."
}

pve_read_storage() {
  local id="$1"
  pve_call GET "/storage/$(pve_quote "$id")"
  if [[ "${PVE_HTTP:-}" != 2* ]]; then
    pve_log_token_permissions
    die "Proxmox storage ${id} was not accepted (HTTP ${PVE_HTTP}). The token needs PVEDatastoreAdmin on /storage/${id}. $(pve_scrub "$PVE_RESPONSE")"
  fi
  PVE_STORAGE_CONTENT="$(printf '%s' "$PVE_RESPONSE" | python3 -c 'import json,sys
data=json.load(sys.stdin).get("data") or {}
print(data.get("content") or "")')"
  pve_call GET "/nodes/$(pve_quote "$PVE_NODE")/storage/$(pve_quote "$id")/status"
  if [[ "${PVE_HTTP:-}" != 2* ]]; then
    die "Proxmox storage ${id} did not report free space (HTTP ${PVE_HTTP}). The token needs PVEDatastoreAdmin on /storage/${id}. $(pve_scrub "$PVE_RESPONSE")"
  fi
  PVE_STORAGE_AVAIL="$(printf '%s' "$PVE_RESPONSE" | python3 -c 'import json,sys
data=json.load(sys.stdin).get("data") or {}
value=data.get("avail")
if value is None:
    raise SystemExit(1)
print(int(value))')" || die "Proxmox storage ${id} did not report free space."
}

pve_content_has() {
  local needle="$1" item
  local -a parts=()
  IFS=',' read -ra parts <<<"${PVE_STORAGE_CONTENT:-}"
  for item in "${parts[@]}"; do
    item="${item// /}"
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

pve_require_import_content() {
  pve_read_storage "$1"
  pve_content_has import || die "Storage ${1} has no Import content type. Datacenter, Storage, ${1}, Edit, Content, turn on Import."
}

pve_require_disk_content() {
  pve_read_storage "$1"
  pve_content_has images || die "Storage ${1} does not support VM disks. Choose a storage with Disk image, usually local-lvm."
}

# Paths of the qcow2 files that stage 3 will upload. Sets PVE_REMOVE_UPLOADS.
pve_plan_uploads() {
  local path bytes name mode message result err keep import_free disk_free
  local -a lines=()
  [[ $# -gt 0 ]] || die "No disk images to upload"
  pve_require_import_content "$PVE_IMPORT_STORAGE"
  import_free="$PVE_STORAGE_AVAIL"
  if [[ "$PVE_IMPORT_STORAGE" == "$PVE_STORAGE" ]]; then
    pve_content_has images || die "Storage ${PVE_STORAGE} does not support VM disks. Choose a storage with Disk image, usually local-lvm."
    disk_free="$import_free"
  else
    pve_require_disk_content "$PVE_STORAGE"
    disk_free="$PVE_STORAGE_AVAIL"
  fi
  for path in "$@"; do
    [[ -f "$path" ]] || die "Converted disk missing: ${path} (run phase 2 first)"
    bytes="$(stat -c %s "$path")"
    name="$(basename "$path")"
    lines+=("${bytes}"$'\t'"${name}")
  done
  keep=0
  [[ "${PVE_KEEP_IMPORTS:-0}" == "1" ]] && keep=1
  err="$(mktemp)"
  if ! result="$(
    PYTHONPATH="${ROOT_DIR}/python${PYTHONPATH:+:${PYTHONPATH}}" python3 -m labkit.import_plan \
      --import-free "$import_free" \
      --disk-free "$disk_free" \
      --import-name "$PVE_IMPORT_STORAGE" \
      --disk-name "$PVE_STORAGE" \
      --keep "$keep" <<<"$(printf '%s\n' "${lines[@]}")" 2>"$err"
  )"; then
    message="$(cat "$err")"
    rm -f "$err"
    die "${message:-The disk images do not fit on the Proxmox storage}"
  fi
  rm -f "$err"
  mode="${result%%$'\n'*}"
  message="${result#*$'\n'}"
  log "$message"
  if [[ "$mode" == "keep" ]]; then
    PVE_REMOVE_UPLOADS=0
  else
    PVE_REMOVE_UPLOADS=1
  fi
}

# A blank SSH host uses the API host. A menu run sets SSH_ASKPASS for the
# password entered at the start. A shell run with no askpass uses a key.
pve_ssh_prepare() {
  pve_prepare
  : "${PVE_SSH_HOST:=$PVE_HOST}"
  [[ "$PVE_SSH_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})?$ ]] || die "SSH host must be a hostname or address"
  if [[ -z "${SSH_ASKPASS:-}" && -n "${PVE_SSH_IDENTITY:-}" ]]; then
    [[ -f "$PVE_SSH_IDENTITY" ]] || die "SSH identity file was not found: ${PVE_SSH_IDENTITY}"
    [[ "$PVE_SSH_IDENTITY" != *$'\n'* && "$PVE_SSH_IDENTITY" != *[![:print:]]* && "$PVE_SSH_IDENTITY" != *" "* ]] || die "SSH identity path has unusual characters"
  fi
  if [[ -n "${SSH_ASKPASS:-}" && -z "${PVE_SSH_AUTH_LOGGED:-}" ]]; then
    # Standard error, so a size check that reads standard output stays a number.
    printf '==> %s\n' "Using the SSH password entered for this run." >&2
    lab_log_append "==> Using the SSH password entered for this run."
    PVE_SSH_AUTH_LOGGED=1
  fi
}

pve_ssh_fill() {
  pve_ssh_prepare
  # ssh -n keeps a plain command from reading the topology loop. rsync must
  # not use -n: that flag closes the stream the rsync protocol travels on.
  local -a opts=(
    -p "$PVE_SSH_PORT"
    -o ConnectTimeout=20
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
    -o StrictHostKeyChecking=accept-new
  )
  if [[ -n "${SSH_ASKPASS:-}" ]]; then
    opts+=(
      -o PreferredAuthentications=password
      -o NumberOfPasswordPrompts=1
      -o IdentitiesOnly=yes
    )
  else
    opts+=(-o BatchMode=yes)
    if [[ -n "${PVE_SSH_IDENTITY:-}" ]]; then
      opts+=(-i "$PVE_SSH_IDENTITY" -o IdentitiesOnly=yes)
    fi
  fi
  PVE_SSH_RSYNC_CMD=(ssh "${opts[@]}")
  PVE_SSH_CMD=(ssh -n "${opts[@]}")
}

pve_ssh() {
  pve_ssh_fill
  "${PVE_SSH_CMD[@]}" "${PVE_SSH_USER}@${PVE_SSH_HOST}" "$@"
}

pve_rsync_shell() {
  local part joined=""
  pve_ssh_fill
  for part in "${PVE_SSH_RSYNC_CMD[@]}"; do
    joined+="$(printf '%q' "$part") "
  done
  joined="${joined% }"
  printf '%s' "$joined"
}

# path plus the import folder from the storage record. Not a fixed location.
pve_import_dir() {
  local dir err message
  pve_call GET "/storage/$(pve_quote "$PVE_IMPORT_STORAGE")"
  pve_expect GET "/storage/${PVE_IMPORT_STORAGE}"
  err="$(mktemp)"
  if ! dir="$(
    printf '%s' "$PVE_RESPONSE" | PYTHONPATH="${ROOT_DIR}/python${PYTHONPATH:+:${PYTHONPATH}}" python3 -c '
import json, sys
from labkit.import_plan import ImportPlanError, import_directory
try:
    print(import_directory((json.load(sys.stdin).get("data") or {})))
except ImportPlanError as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1)
' 2>"$err"
  )"; then
    message="$(cat "$err")"
    rm -f "$err"
    die "${message:-Import storage ${PVE_IMPORT_STORAGE} has no directory path}"
  fi
  rm -f "$err"
  PVE_IMPORT_DIR="$dir"
}

# Prints the remote byte count, or nothing when the file is absent.
# Connection failures are not treated as a missing file.
pve_remote_size() {
  local target="$1" quoted err size rc message
  quoted="$(printf '%q' "$target")"
  err="$(mktemp)"
  set +e
  size="$(pve_ssh "stat -c %s -- ${quoted}" 2>"$err")"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$err"
    size="$(printf '%s\n' "$size" | awk '/^[0-9]+$/ {n=$0} END {print n}')"
    [[ "$size" =~ ^[0-9]+$ ]] || die "Remote size of ${target} was not a number"
    printf '%s' "$size"
    return 0
  fi
  if [[ "$rc" -eq 1 ]]; then
    rm -f "$err"
    printf ''
    return 0
  fi
  message="$(cat "$err")"
  rm -f "$err"
  die "SSH to ${PVE_SSH_USER}@${PVE_SSH_HOST} failed (${rc}). $(pve_scrub "$message")"
}

pve_check_copy() {
  local dir parent quoted parent_q
  pve_import_dir
  dir="$PVE_IMPORT_DIR"
  parent="$(dirname "$dir")"
  quoted="$(printf '%q' "$dir")"
  parent_q="$(printf '%q' "$parent")"
  if pve_ssh "test -d ${quoted} && test -w ${quoted}"; then
    log "SSH ${PVE_SSH_USER}@${PVE_SSH_HOST} can write ${dir}"
    return 0
  fi
  if pve_ssh "test -d ${parent_q} && test -w ${parent_q}"; then
    log "SSH ${PVE_SSH_USER}@${PVE_SSH_HOST} can write ${parent}. The copy creates ${dir}"
    return 0
  fi
  die "SSH ${PVE_SSH_USER}@${PVE_SSH_HOST} cannot write ${dir}. That login needs write permission on the import directory. API roles do not grant it."
}

pve_rsync_file() {
  local src="$1" base dest local_bytes remote quoted attempt rc rsh
  base="$(basename "$src")"
  dest="${PVE_IMPORT_DIR}/${base}"
  local_bytes="$(stat -c %s "$src")"
  remote="$(pve_remote_size "$dest")"
  if [[ "$remote" == "$local_bytes" ]]; then
    log "Import image already on ${PVE_IMPORT_STORAGE}: ${base}"
    return 0
  fi
  if [[ -n "$remote" && "$remote" -gt "$local_bytes" ]]; then
    log "Remote ${base} is larger than the local file. Removing it before the copy."
    quoted="$(printf '%q' "$dest")"
    pve_ssh "rm -f -- ${quoted}" || die "Could not remove ${dest}"
  fi
  quoted="$(printf '%q' "$PVE_IMPORT_DIR")"
  pve_ssh "mkdir -p -- ${quoted}" || die "Could not create ${PVE_IMPORT_DIR}"
  rsh="$(pve_rsync_shell)"
  attempt=1
  while [[ "$attempt" -le "$PVE_RSYNC_TRIES" ]]; do
    log "Copying ${base} to ${PVE_SSH_USER}@${PVE_SSH_HOST}:${PVE_IMPORT_DIR} (attempt ${attempt} of ${PVE_RSYNC_TRIES}). A dropped connection keeps the partial file and the next attempt continues it."
    set +e
    rsync -a --partial --append-verify --timeout=120 --info=progress2,stats2 \
      -e "$rsh" \
      -- "$src" "${PVE_SSH_USER}@${PVE_SSH_HOST}:${PVE_IMPORT_DIR}/"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      remote="$(pve_remote_size "$dest")"
      [[ "$remote" == "$local_bytes" ]] || die "Copied ${base} but the remote size is ${remote:-missing}, not ${local_bytes}"
      log "Copied ${base}"
      return 0
    fi
    log "rsync of ${base} stopped with exit ${rc}. The partial file stays on the node."
    if [[ "$attempt" -eq "$PVE_RSYNC_TRIES" ]]; then
      die "Could not copy ${base} to ${PVE_IMPORT_STORAGE} after ${PVE_RSYNC_TRIES} attempts"
    fi
    sleep $((attempt * ${PVE_RSYNC_WAIT:-5}))
    attempt=$((attempt + 1))
  done
}

pve_upload() {
  local file="$1" base
  base="$(basename "$file")"
  [[ "$base" == *.qcow2 ]] || die "Proxmox import expects a qcow2 file: ${file}"
  [[ "$file" != *[![:print:]]* && "$file" != *";"* ]] || die "Refusing to copy a path with unusual characters"
  [[ -f "$file" ]] || die "Converted disk missing: ${file} (run phase 2 first)"
  pve_import_dir
  pve_rsync_file "$file"
}

pve_delete_import() {
  local base="$1" volid encoded http_path
  volid="${PVE_IMPORT_STORAGE}:import/${base}"
  encoded="$(pve_quote "$volid")"
  http_path="/nodes/$(pve_quote "$PVE_NODE")/storage/$(pve_quote "$PVE_IMPORT_STORAGE")/content/${encoded}"
  pve_call DELETE "$http_path"
  if [[ "${PVE_HTTP:-}" == 404 ]]; then
    return 0
  fi
  pve_expect DELETE "/nodes/${PVE_NODE}/storage/${PVE_IMPORT_STORAGE}/content/${volid}"
}

# The signed-in token can always read its own effective permissions.
pve_log_token_permissions() {
  local dump
  pve_call GET "/access/permissions"
  [[ "${PVE_HTTP:-}" == 2* ]] || return 0
  dump="$(printf '%s' "$PVE_RESPONSE" | PVE_TOKEN_ID="$PVE_TOKEN_ID" python3 -c 'import json,os,sys
data=json.load(sys.stdin).get("data") or {}
token=os.environ.get("PVE_TOKEN_ID","")
user=token.split("!",1)[0]
if not isinstance(data, dict) or not data:
    print("Token %s has no effective permissions." % token)
    print("Privilege separation keeps a privilege only when both the user and the token have it.")
    print("Grant the same roles to the user %s on the same paths." % user)
    raise SystemExit(0)
print("Token %s is allowed on:" % token)
for path in sorted(data):
    privs=sorted(k for k,v in (data[path] or {}).items() if v)
    print("  %s (%s)" % (path, ", ".join(privs)))
')"
  while IFS= read -r line; do
    [[ -n "$line" ]] && log "$line"
  done <<<"$dump"
}

# Read-only check. It does not create a guest or upload a disk.
pve_test_connection() {
  local version missing
  pve_prepare
  pve_call GET "/version"
  pve_expect GET "/version"
  version="$(printf '%s' "$PVE_RESPONSE" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("data") or {}).get("version") or "")')"
  [[ -n "$version" ]] || die "Proxmox did not report a version"
  log "Proxmox ${version} answered on ${PVE_HOST}:${PVE_PORT}"

  # Listing guests needs VM.Audit, which PVEVMAdmin on /vms already has.
  # Node status needs Sys.Audit, which that token does not have.
  pve_call GET "/nodes/$(pve_quote "$PVE_NODE")/qemu"
  if [[ "${PVE_HTTP:-}" != 2* ]]; then
    die "Proxmox node ${PVE_NODE} was not accepted (HTTP ${PVE_HTTP}). $(pve_scrub "$PVE_RESPONSE")"
  fi
  log "Node ${PVE_NODE} is reachable"

  pve_require_import_content "$PVE_IMPORT_STORAGE"
  if [[ "$PVE_IMPORT_STORAGE" == "$PVE_STORAGE" ]]; then
    pve_content_has images || die "Storage ${PVE_STORAGE} does not support VM disks. Choose a storage with Disk image, usually local-lvm."
    log "Storage ${PVE_STORAGE} allows import and VM disks"
  else
    log "Import storage ${PVE_IMPORT_STORAGE} allows import"
    pve_require_disk_content "$PVE_STORAGE"
    log "Disk storage ${PVE_STORAGE} allows VM disks"
  fi

  pve_check_copy

  pve_call GET "/nodes/$(pve_quote "$PVE_NODE")/network"
  if [[ "${PVE_HTTP:-}" == 403 ]]; then
    log "Bridges ${PVE_BRIDGE} and ${PVE_INTERNET_BRIDGE} were not checked. The token has no Sys.Audit on the node."
    return 0
  fi
  if [[ "${PVE_HTTP:-}" != 2* ]]; then
    die "Proxmox network list failed (HTTP ${PVE_HTTP}). $(pve_scrub "$PVE_RESPONSE")"
  fi
  missing="$(printf '%s' "$PVE_RESPONSE" | PVE_BRIDGE="$PVE_BRIDGE" PVE_INTERNET_BRIDGE="$PVE_INTERNET_BRIDGE" python3 -c 'import json,os,sys
data=json.load(sys.stdin).get("data") or []
rows=[row for row in data if isinstance(row, dict)]
have={str(row.get("iface") or "") for row in rows}
bridges=sorted(str(row.get("iface") or "") for row in rows if str(row.get("type") or "") in ("bridge","OVSBridge") and row.get("iface"))
need=[]
for name in (os.environ.get("PVE_BRIDGE",""), os.environ.get("PVE_INTERNET_BRIDGE","")):
    if name and name not in have and name not in need:
        need.append(name)
found=", ".join(sorted(name for name in have if name)) or "none"
print(", ".join(need))
print(", ".join(bridges))
print(found)')"
  if [[ -n "${missing%%$'\n'*}" ]]; then
    needed="${missing%%$'\n'*}"
    rest="${missing#*$'\n'}"
    bridges="${rest%%$'\n'*}"
    found="${rest#*$'\n'}"
    if [[ -z "$bridges" ]]; then
      die "Proxmox hid ${needed} from this token. Add PVESDNUser on /sdn/zones/localnetwork for the user and the token, with propagate. The token currently sees: ${found}"
    fi
    die "Proxmox bridge not found on ${PVE_NODE}: ${needed}. Bridges on the node: ${bridges}"
  fi
  if [[ "$PVE_BRIDGE" == "$PVE_INTERNET_BRIDGE" ]]; then
    log "Bridge ${PVE_BRIDGE} is present"
  else
    log "Bridges ${PVE_BRIDGE} and ${PVE_INTERNET_BRIDGE} are present"
  fi
}

pve_delete_vm() {
  local name="$1" vmid="$2" path body
  path="/nodes/$(pve_quote "$PVE_NODE")/qemu/${vmid}?purge=1&destroy-unreferenced-disks=1"
  pve_call DELETE "$path"
  pve_expect DELETE "/nodes/${PVE_NODE}/qemu/${vmid}"
  body="$PVE_RESPONSE"
  pve_follow "$body"
  log "Deleted Proxmox VM ${name} (${vmid})"
}
