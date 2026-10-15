#!/usr/bin/env bash
# Phase 4: Render identity / unattend templates into TMP_DIR (config-driven).

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

DO_PROMPT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-prompt) DO_PROMPT=0 ;;
    --prompt) DO_PROMPT=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: prepare-identity.sh [--no-prompt]

Reads config/lab.env (LAB_ADMIN_*, LAB_DOMAIN, paths) and writes:
  TMP_DIR/identity/credentials.md
  TMP_DIR/identity/first-boot-notes.md
  TMP_DIR/identity/unattend/<vm>-oobe.xml   (clients; requires password)
  VM extradata Description for each Phase-3 server VM
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config "$DO_PROMPT"
save_resolved_paths_hint

IDENTITY_DIR="${TMP_DIR}/identity"
UNATTEND_OUT="${IDENTITY_DIR}/unattend"
ensure_dir "$IDENTITY_DIR" "$UNATTEND_OUT"

CORPNET_INTNET="${LAB_PREFIX}-${LAB_NETWORK_NAME}"

if [[ -z "${LAB_ADMIN_PASSWORD:-}" ]]; then
  warn "LAB_ADMIN_PASSWORD is empty — set it in config/lab.env for unattend rendering."
  warn "Kit documentation commonly cites an evaluation password; do not commit secrets."
  PASS_DISPLAY="(unset — edit config/lab.env)"
  RENDER_UNATTEND=0
else
  PASS_DISPLAY="(set; ${#LAB_ADMIN_PASSWORD} chars)"
  RENDER_UNATTEND=1
fi

render() {
  local src="$1" dest="$2"
  local computer="${3:-}"
  local content
  content="$(cat "$src")"
  content="${content//\{\{LAB_ADMIN_USER\}\}/${LAB_ADMIN_USER}}"
  content="${content//\{\{LAB_ADMIN_PASSWORD\}\}/${LAB_ADMIN_PASSWORD}}"
  content="${content//\{\{LAB_ADMIN_PASSWORD_DISPLAY\}\}/${PASS_DISPLAY}}"
  content="${content//\{\{LAB_DOMAIN\}\}/${LAB_DOMAIN}}"
  content="${content//\{\{VM_ROOT\}\}/${VM_ROOT}}"
  content="${content//\{\{IDENTITY_DIR\}\}/${IDENTITY_DIR}}"
  content="${content//\{\{CORPNET_INTNET\}\}/${CORPNET_INTNET}}"
  content="${content//\{\{COMPUTER_NAME\}\}/${computer}}"
  content="${content//\{\{PRODUCT_KEY\}\}/}"
  printf '%s\n' "$content" >"$dest"
  log "Wrote $dest"
}

TMPL_DIR="${ROOT_DIR}/templates"
render "${TMPL_DIR}/identity/credentials.md.tmpl" "${IDENTITY_DIR}/credentials.md"
render "${TMPL_DIR}/identity/first-boot-notes.md.tmpl" "${IDENTITY_DIR}/first-boot-notes.md"

# Client unattend stubs (for Phase 3b / later differencing clients)
CLIENTS=(HYD-CLIENT1 HYD-CLIENT2 HYD-CLIENT3 HYD-CLIENT4)
if [[ "$RENDER_UNATTEND" -eq 1 ]]; then
  for c in "${CLIENTS[@]}"; do
    # Short NetBIOS-friendly name (max 15)
    short="${c#HYD-}"
    render "${TMPL_DIR}/unattend/client-oobe.xml.tmpl" "${UNATTEND_OUT}/${c}-oobe.xml" "$short"
  done
else
  warn "Skipping unattend XML render (no LAB_ADMIN_PASSWORD)"
fi

# Stamp VirtualBox VM descriptions from topology (no secrets in extradata)
if command -v VBoxManage >/dev/null 2>&1; then
  topo="${ROOT_DIR}/config/topology.tsv"
  while IFS=$'\t' read -r name role ostype memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    [[ "$name" == "name" ]] && continue
    if VBoxManage showvminfo "$name" >/dev/null 2>&1; then
      desc="${role} | domain=${LAB_DOMAIN} | admin=${LAB_DOMAIN}\\${LAB_ADMIN_USER} | net=${CORPNET_INTNET}"
      VBoxManage modifyvm "$name" --description "$desc" >/dev/null
      log "Updated description: $name"
    fi
  done <"$topo"
fi

# Operator-facing summary (no password echo)
cat >"${IDENTITY_DIR}/summary.env" <<EOF
LAB_DOMAIN=${LAB_DOMAIN}
LAB_ADMIN_USER=${LAB_ADMIN_USER}
LAB_ADMIN_PASSWORD_SET=$([[ -n "${LAB_ADMIN_PASSWORD:-}" ]] && echo 1 || echo 0)
CORPNET_INTNET=${CORPNET_INTNET}
IDENTITY_DIR=${IDENTITY_DIR}
UNATTEND_OUT=${UNATTEND_OUT}
EOF

marker_set "${MARKERS_DIR}/identity.done"
log "Identity outputs: $IDENTITY_DIR"
