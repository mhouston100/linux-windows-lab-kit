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

Reads config/lab.env (paths) and the kit account (LAB_ADMIN_*, LAB_DOMAIN) and writes:
  TMP_DIR/identity/credentials.md
  TMP_DIR/identity/first-boot-notes.md
  TMP_DIR/identity/unattend/<vm>-oobe.xml   (clients)
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

RENDER_UNATTEND=1

render() {
  local src="$1" dest="$2"
  local computer="${3:-}"
  local content
  content="$(cat "$src")"
  content="${content//\{\{LAB_ADMIN_USER\}\}/${LAB_ADMIN_USER}}"
  content="${content//\{\{LAB_ADMIN_PASSWORD\}\}/${LAB_ADMIN_PASSWORD}}"
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

# Stamp VM descriptions from topology (no secrets). The hypervisor module does the write.
hv_load
topo="${ROOT_DIR}/config/topology.tsv"
while IFS=$'\t' read -r name role memory_mb cpus disk nic1 nic2 notes || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  [[ "$name" == "name" ]] && continue
  if hv_vm_exists "$name"; then
    desc="${role} | domain=${LAB_DOMAIN} | admin=${LAB_DOMAIN}\\${LAB_ADMIN_USER} | net=${CORPNET_INTNET}"
    hv_set_description "$name" "$desc"
    log "Updated description: $name"
  fi
done <"$topo"

# Operator-facing summary (no password echo)
cat >"${IDENTITY_DIR}/summary.env" <<EOF
LAB_DOMAIN=${LAB_DOMAIN}
LAB_ADMIN_USER=${LAB_ADMIN_USER}
LAB_ADMIN_PASSWORD_SET=1
CORPNET_INTNET=${CORPNET_INTNET}
IDENTITY_DIR=${IDENTITY_DIR}
UNATTEND_OUT=${UNATTEND_OUT}
EOF

marker_set "${MARKERS_DIR}/identity.done"
log "Identity outputs: $IDENTITY_DIR"
