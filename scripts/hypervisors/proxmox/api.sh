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
  [[ -n "${PVE_API_HOST:-}" ]] || die "Set the Proxmox API host"
  [[ -n "${PVE_TLS_FINGERPRINT:-}" ]] || die "Set the Proxmox TLS fingerprint"
  [[ -n "${PVE_NODE:-}" ]] || die "Set the Proxmox node"
  [[ -n "${PVE_STORAGE:-}" ]] || die "Set the Proxmox storage"
  [[ -n "${PVE_BRIDGE:-}" ]] || die "Set the CorpNet bridge"
  [[ -n "${PVE_INTERNET_BRIDGE:-}" ]] || die "Set the Internet bridge"
  [[ "${PVE_TOKEN_ID:-}" == *@*!* ]] || die "Proxmox token id must look like user@pve!labkit"
  [[ -n "${PVE_TOKEN_SECRET:-}" ]] || die "Set the Proxmox API token secret"
  command -v curl >/dev/null 2>&1 || die "curl is required to call the Proxmox API"
  command -v openssl >/dev/null 2>&1 || die "openssl is required to check the Proxmox certificate"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read Proxmox API replies"
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
    printf 'cacert = "%s"\n' "$PVE_CA_FILE"
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

pve_upload() {
  local file="$1" base volid
  base="$(basename "$file")"
  [[ "$base" == *.qcow2 ]] || die "Proxmox import expects a qcow2 file: ${file}"
  [[ "$file" != *[![:print:]]* && "$file" != *";"* ]] || die "Refusing to upload a path with unusual characters"
  volid="${PVE_STORAGE}:import/${base}"
  pve_call GET "/nodes/$(pve_quote "$PVE_NODE")/storage/$(pve_quote "$PVE_STORAGE")/content?content=import"
  if [[ "${PVE_HTTP:-}" != 2* ]]; then
    die "Proxmox storage ${PVE_STORAGE} did not list import content (HTTP ${PVE_HTTP}). Enable the import content type on that storage. $(pve_scrub "$PVE_RESPONSE")"
  fi
  if printf '%s' "$PVE_RESPONSE" | python3 -c 'import json,sys
volid=sys.argv[1]
rows=json.load(sys.stdin).get("data") or []
sys.exit(0 if any(row.get("volid")==volid for row in rows) else 1)' "$volid"; then
    log "Import image already on ${PVE_STORAGE}: ${base}"
    return 0
  fi
  log "Uploading ${base} to ${PVE_STORAGE} (import). This is the large copy."
  pve_call POST "/nodes/$(pve_quote "$PVE_NODE")/storage/$(pve_quote "$PVE_STORAGE")/upload" \
    --form-string "content=import" \
    --form "filename=@${file};filename=${base}"
  pve_expect POST "/nodes/${PVE_NODE}/storage/${PVE_STORAGE}/upload"
  pve_follow "$PVE_RESPONSE"
}

pve_delete_import() {
  local base="$1" volid encoded http_path
  volid="${PVE_STORAGE}:import/${base}"
  encoded="$(pve_quote "$volid")"
  http_path="/nodes/$(pve_quote "$PVE_NODE")/storage/$(pve_quote "$PVE_STORAGE")/content/${encoded}"
  pve_call DELETE "$http_path"
  if [[ "${PVE_HTTP:-}" == 404 ]]; then
    return 0
  fi
  pve_expect DELETE "/nodes/${PVE_NODE}/storage/${PVE_STORAGE}/content/${volid}"
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
