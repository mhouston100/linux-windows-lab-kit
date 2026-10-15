#!/usr/bin/env bash
# Phase 2: flatten differencing VHDX (DiscUtils) + convert to VirtualBox VDI (qemu-img).

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
# shellcheck source=lib/prereqs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/prereqs.sh"

PROMPT=0
FORCE=0
FORMAT=vdi

usage() {
  cat <<'EOF'
Usage: convert-disks.sh [--no-prompt] [--force] [--format vdi|vmdk]

Pipeline:
  1) Inventory disks (if needed)
  2) For base VHDX (qemu-readable): qemu-img convert -> CONVERT_DIR/<name>.vdi
  3) For differencing VHDX: VhdxFlatten -> flat VHDX, then qemu-img -> VDI
  4) Write CONVERT_DIR/conversion-map.tsv

Notes:
  qemu-img cannot open Hyper-V differencing VHDX (ENOTSUP). We flatten with
  tools/VhdxFlatten (DiscUtils / .NET) first.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) PROMPT=1 ;;
    --no-prompt) PROMPT=0 ;;
    --force) FORCE=1 ;;
    --format) FORMAT="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

case "$FORMAT" in
  vdi|vmdk) ;;
  *) die "Unsupported format: $FORMAT (use vdi or vmdk)" ;;
esac

load_config "$PROMPT"
check_prereqs 1
have_cmd dotnet || die "dotnet is required for VhdxFlatten (differencing VHDX). Hint: sudo pacman -S dotnet-sdk"

ensure_dir "$CONVERT_DIR" "$ORG_META" "$MARKERS_DIR"
MAP="${ORG_META}/disk-parents.tsv"
CONV_MAP="${CONVERT_DIR}/conversion-map.tsv"

if [[ ! -f "$MAP" ]]; then
  log "No disk inventory yet — running inventory-disks.sh"
  "${SCRIPTS_DIR}/inventory-disks.sh" --no-prompt
fi

FLATTEN_PROJ="${ROOT_DIR}/tools/VhdxFlatten/VhdxFlatten.csproj"
[[ -f "$FLATTEN_PROJ" ]] || die "Missing $FLATTEN_PROJ"

log "Building VhdxFlatten..."
dotnet build "$FLATTEN_PROJ" -c Release -v q
FLATTEN=(dotnet run --project "$FLATTEN_PROJ" -c Release --no-build --)

{
  echo -e "source\tintermediate\toutput\tmethod"
} >"$CONV_MAP"

convert_one() {
  local src="$1" parent="$2" note="$3"
  local base out flat
  base="$(basename "$src")"
  base="${base%.*}"
  # Normalize extension casing
  base="${base%.VHDX}"
  base="${base%.vhdx}"
  base="${base%.avhdx}"
  base="${base%.AVHDX}"

  out="${CONVERT_DIR}/${base}.${FORMAT}"
  flat="${CONVERT_DIR}/${base}.flat.vhdx"

  if [[ "$FORCE" -ne 1 && -f "$out" ]]; then
    log "Skip existing: $out"
    printf '%s\t%s\t%s\t%s\n' "$src" "-" "$out" "skipped-exists" >>"$CONV_MAP"
    return 0
  fi

  # Skip tiny checkpoint deltas (AVHDX) — merge story for later if needed.
  if [[ "$src" == *.avhdx || "$src" == *.AVHDX ]]; then
    sz="$(stat -c%s "$src")"
    if (( sz < 64 * 1024 * 1024 )); then
      warn "Skipping small checkpoint delta: $src ($(human_bytes "$sz"))"
      printf '%s\t%s\t%s\t%s\n' "$src" "-" "-" "skipped-small-avhdx" >>"$CONV_MAP"
      return 0
    fi
  fi

  # Skip hardlinked/copied parents sitting beside children (already converted from ZPAQ_DIR root).
  case "$(basename "$src")" in
    ServerParent.vhdx|WindowsParent.vhdx)
      if [[ "$(dirname "$src")" != "$ZPAQ_DIR" ]]; then
        log "Skip nested parent copy: $src"
        printf '%s\t%s\t%s\t%s\n' "$src" "-" "-" "skipped-nested-parent" >>"$CONV_MAP"
        return 0
      fi
      ;;
  esac

  log "Converting: $src"

  if [[ "$note" == qemu-ok ]] || qemu-img info "$src" >/dev/null 2>&1; then
    qemu-img convert -p -f vhdx -O "$FORMAT" "$src" "$out"
    printf '%s\t%s\t%s\t%s\n' "$src" "-" "$out" "qemu-img" >>"$CONV_MAP"
  else
    [[ -n "$parent" && "$parent" != "-" && -f "$parent" ]] || \
      die "Differencing disk needs parent: $src"

    # Link parent beside child for locator resolution attempts
    local sibling
    sibling="$(dirname "$src")/$(basename "$parent")"
    if [[ ! -e "$sibling" ]]; then
      ln -sfn "$parent" "$sibling" || ln "$parent" "$sibling"
    fi

    rm -f "$flat"
    "${FLATTEN[@]}" "$src" "$flat" --parent "$parent"
    qemu-img convert -p -f vhdx -O "$FORMAT" "$flat" "$out"
    printf '%s\t%s\t%s\t%s\n' "$src" "$flat" "$out" "flatten+qemu-img" >>"$CONV_MAP"
  fi

  # Verify VirtualBox can see the medium
  VBoxManage showmediuminfo "$out" >/dev/null
  log "OK: $out"
}

# Convert parents first, then children (map order may be mixed — do two passes)
while IFS=$'\t' read -r src parent note; do
  [[ "$src" == "child" ]] && continue
  [[ "$note" == qemu-ok ]] || continue
  convert_one "$src" "$parent" "$note"
done <"$MAP"

while IFS=$'\t' read -r src parent note; do
  [[ "$src" == "child" ]] && continue
  [[ "$note" == qemu-ok ]] && continue
  convert_one "$src" "$parent" "$note"
done <"$MAP"

marker_set "${MARKERS_DIR}/convert.done"
log "Conversion map: $CONV_MAP"
log "Step complete: convert"
