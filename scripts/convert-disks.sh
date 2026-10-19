#!/usr/bin/env bash
# Phase 2: flatten differencing VHDX (DiscUtils) + convert to the hypervisor disk format.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
# shellcheck source=lib/prereqs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/prereqs.sh"

PROMPT=0
FORCE=0
FORMAT=""
FORMAT_EXPLICIT=0
PARALLEL=1
MAX_JOBS=3

usage() {
  cat <<'EOF'
Usage: convert-disks.sh [--no-prompt] [--force] [--format vdi|vmdk] [--parallel|--no-parallel]

Pipeline:
  1) Inventory disks (if needed)
  2) For base VHDX (qemu-readable): qemu-img convert -> CONVERT_DIR/<name>.<format>
  3) For differencing VHDX: VhdxFlatten -> flat VHDX, then qemu-img
  4) Write CONVERT_DIR/conversion-map.tsv

The disk format defaults to the selected hypervisor (vdi for VirtualBox).
--format overrides that. qemu-img cannot open Hyper-V differencing VHDX
(ENOTSUP). Those are flattened with tools/VhdxFlatten (DiscUtils / .NET) first.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) PROMPT=1 ;;
    --no-prompt) PROMPT=0 ;;
    --force) FORCE=1 ;;
    --format) FORMAT="${2:?}"; FORMAT_EXPLICIT=1; shift ;;
    --parallel) PARALLEL=1 ;;
    --no-parallel) PARALLEL=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

if [[ "$FORMAT_EXPLICIT" -eq 1 ]]; then
  case "$FORMAT" in
    vdi|vmdk) ;;
    *) die "Unsupported format: $FORMAT (use vdi or vmdk)" ;;
  esac
fi

load_config "$PROMPT"
hv_load
if [[ -z "$FORMAT" ]]; then
  FORMAT="$(hv_disk_format)"
fi
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

flatten_dll="${ROOT_DIR}/tools/VhdxFlatten/bin/Release/net10.0/VhdxFlatten.dll"
flatten_stale=0
if [[ ! -f "$flatten_dll" ]]; then
  flatten_stale=1
else
  for src in "${ROOT_DIR}/tools/VhdxFlatten/"*.cs "${ROOT_DIR}/tools/VhdxFlatten/"*.csproj; do
    if [[ -f "$src" && "$src" -nt "$flatten_dll" ]]; then
      flatten_stale=1
      break
    fi
  done
fi
if [[ "$flatten_stale" -eq 1 ]]; then
  log "Building VhdxFlatten..."
  dotnet build "$FLATTEN_PROJ" -c Release -v q
else
  log "VhdxFlatten is already built"
fi
FLATTEN=(dotnet run --project "$FLATTEN_PROJ" -c Release --no-build --)

{
  echo -e "source\tintermediate\toutput\tmethod"
} >"$CONV_MAP"

append_map() {
  flock 9
  printf '%s\t%s\t%s\t%s\n' "$@" >>"$CONV_MAP"
  flock -u 9
} 9>>"${CONV_MAP}.lock"

convert_one() {
  local src="$1" parent="$2" note="$3"
  local base out flat started elapsed method
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
    append_map "$src" "-" "$out" "skipped-exists"
    return 0
  fi

  # Skip tiny checkpoint deltas (AVHDX) — merge story for later if needed.
  if [[ "$src" == *.avhdx || "$src" == *.AVHDX ]]; then
    sz="$(stat -c%s "$src")"
    if (( sz < 64 * 1024 * 1024 )); then
      warn "Skipping small checkpoint delta: $src ($(human_bytes "$sz"))"
      append_map "$src" "-" "-" "skipped-small-avhdx"
      return 0
    fi
  fi

  # Skip hardlinked/copied parents sitting beside children (already converted from ZPAQ_DIR root).
  case "$(basename "$src")" in
    ServerParent.vhdx|WindowsParent.vhdx)
      if [[ "$(dirname "$src")" != "$ZPAQ_DIR" ]]; then
        log "Skip nested parent copy: $src"
        append_map "$src" "-" "-" "skipped-nested-parent"
        return 0
      fi
      ;;
  esac

  log "Converting: $src"
  started="$(date +%s)"

  if [[ "$note" == qemu-ok ]] || qemu-img info "$src" >/dev/null 2>&1; then
    method="qemu-img"
    if [[ "$PARALLEL" -eq 1 ]]; then
      qemu-img convert -f vhdx -O "$FORMAT" "$src" "$out"
    else
      qemu-img convert -p -f vhdx -O "$FORMAT" "$src" "$out"
    fi
    append_map "$src" "-" "$out" "$method"
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
    method="flatten+qemu-img"
    "${FLATTEN[@]}" "$src" "$flat" --parent "$parent"
    if [[ "$PARALLEL" -eq 1 ]]; then
      qemu-img convert -f vhdx -O "$FORMAT" "$flat" "$out"
    else
      qemu-img convert -p -f vhdx -O "$FORMAT" "$flat" "$out"
    fi
    append_map "$src" "$flat" "$out" "$method"
  fi

  if [[ "$PARALLEL" -eq 0 ]]; then
    hv_verify_disk "$out"
  fi
  elapsed=$(( $(date +%s) - started ))
  log "OK: $out (${elapsed}s, ${method})"
}

convert_batch() {
  local want_qemu="$1"
  local -a pids=()
  local src parent note fail=0
  while IFS=$'\t' read -r src parent note; do
    [[ "$src" == "child" ]] && continue
    if [[ "$want_qemu" -eq 1 ]]; then
      [[ "$note" == qemu-ok ]] || continue
    else
      [[ "$note" == qemu-ok ]] && continue
    fi
    if [[ "$PARALLEL" -eq 0 ]]; then
      convert_one "$src" "$parent" "$note"
      continue
    fi
    convert_one "$src" "$parent" "$note" &
    pids+=("$!")
    if [[ "${#pids[@]}" -ge "$MAX_JOBS" ]]; then
      if ! wait "${pids[0]}"; then
        fail=1
      fi
      pids=("${pids[@]:1}")
    fi
  done <"$MAP"
  for pid in "${pids[@]+"${pids[@]}"}"; do
    if ! wait "$pid"; then
      fail=1
    fi
  done
  [[ "$fail" -eq 0 ]] || die "A disk conversion failed"
}

verify_converted() {
  local out
  [[ "$PARALLEL" -eq 1 ]] || return 0
  while IFS=$'\t' read -r _src _mid out _method; do
    [[ -n "$out" && "$out" != "-" && -f "$out" ]] || continue
    hv_verify_disk "$out"
  done <"$CONV_MAP"
}

if [[ "$PARALLEL" -eq 1 ]]; then
  log "Converting independent disks together (up to ${MAX_JOBS})"
else
  log "Converting disks one at a time"
fi

# Parents first, then children. Within each group the disks do not depend on each other.
convert_batch 1
convert_batch 0
verify_converted

marker_set "${MARKERS_DIR}/convert.done"
log "Conversion map: $CONV_MAP"
log "Step complete: convert"
