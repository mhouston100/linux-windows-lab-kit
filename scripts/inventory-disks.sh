#!/usr/bin/env bash
# Phase 2: inventory VHD/VHDX (+ avhdx) and inferred parent links.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

PROMPT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) PROMPT=1 ;;
    --no-prompt) PROMPT=0 ;;
    -h|--help) echo "Usage: inventory-disks.sh [--prompt]"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

load_config "$PROMPT"
ensure_dir "$ORG_META" "$CONVERT_DIR"

OUT="${ORG_META}/disk-inventory.txt"
MAP="${ORG_META}/disk-parents.tsv"

{
  echo "# Disk inventory — $(date -Iseconds)"
  echo "# ZPAQ_DIR=$ZPAQ_DIR"
  echo
} >"$OUT"

{
  echo -e "child\tparent\tnote"
} >"$MAP"

while IFS= read -r -d '' disk; do
  rel="${disk#"$ZPAQ_DIR"/}"
  size="$(du -h "$disk" | awk '{print $1}')"
  parent="-"
  note=""

  if qemu-img info "$disk" >/dev/null 2>&1; then
    note="qemu-ok"
  else
    note="qemu-differencing-or-unsupported"
    # Only scan the header region — full-file strings on 50GB+ disks is too slow.
    hdr="$(head -c 8M "$disk" | strings -el 2>/dev/null || true)"
    if grep -q 'ServerParent\.vhdx' <<<"$hdr"; then
      parent="${ZPAQ_DIR}/ServerParent.vhdx"
      note="diff->ServerParent"
    elif grep -q 'WindowsParent\.vhdx' <<<"$hdr"; then
      parent="${ZPAQ_DIR}/WindowsParent.vhdx"
      note="diff->WindowsParent"
    fi
  fi

  {
    echo "## $rel"
    echo "path: $disk"
    echo "size: $size"
    echo "note: $note"
    echo "parent: $parent"
    echo
  } >>"$OUT"

  printf '%s\t%s\t%s\n' "$disk" "$parent" "$note" >>"$MAP"
done < <(find "$ZPAQ_DIR" \( -iname '*.vhdx' -o -iname '*.vhd' -o -iname '*.avhdx' \) -type f -print0 | sort -z)

log "Inventory: $OUT"
log "Parent map: $MAP"
wc -l "$MAP" | awk '{print "entries:", $1-1}'
