#!/usr/bin/env bash
# Unpack one lab kit without copying Microsoft files into the git repo.
#
#   zip       Unzip --kit into DEST/source/extract (zpaq archive, setup.exe, zpaq.exe)
#   zpaq      Unpack that archive into DEST/tmp/zpaq. This is the long step.
#   setup     Pull resources out of setup.exe with 7z. Do not launch it under Wine.
#   organize  Symlink disks and VM folders into DEST/tmp/organized and write an inventory
#
# Wine is only used to run the bundled zpaq.exe when no native zpaq is installed.
# Mono is not required for that. -to keeps the extract inside TMP_DIR; without it,
# Wine has previously spilled files into the parent of the working directory.

set -euo pipefail
# shellcheck source=lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
# shellcheck source=lib/cli.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cli.sh"
# shellcheck source=lib/prereqs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/prereqs.sh"

STEP="all"
FORCE=0
PROMPT=1

usage() {
  cat <<EOF
Usage: extract-lab.sh [--kit ZIP] [--dest DIR] [--step STEP] [--force] [--no-prompt]

Steps:
  zip       Extract lab ZIP into DEST/source/extract
  zpaq      Extract nested .zpaq into DEST/tmp/zpaq
  setup     Unpack setup.exe resources into DEST/tmp/setup
  organize  Classify disks/VM trees under DEST/tmp/organized
  all       Run zip → zpaq → setup → organize (default)

Options:
  --force      Re-run even if a step marker exists
  --no-prompt  Use config/env/flag paths only (no interactive questions)

$(lab_path_help)
EOF
}

parse_lab_cli "$@"
eval "$(lab_cli_restore_eval)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --step) STEP="${2:?}"; shift ;;
    --force) FORCE=1 ;;
    --no-prompt) PROMPT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

# --kit / --dest already chose the paths; don't ask again.
if [[ -n "${LAB_CLI_KIT:-}${LAB_CLI_DEST:-}" ]]; then
  PROMPT=0
fi

load_config "$PROMPT"
check_prereqs 1
require_lab_zip
ensure_dir "$SOURCE_DIR" "$TMP_DIR" "$VM_ROOT"
save_resolved_paths_hint

SEVEN="$(resolve_7z)"

step_done() {
  local name="$1"
  [[ "$FORCE" -eq 1 ]] && return 1
  marker_ok "${MARKERS_DIR}/${name}.done"
}

mark_done() {
  marker_set "${MARKERS_DIR}/${1}.done"
  log "Step complete: $1"
}

extract_zip() {
  if step_done zip; then
    log "Skipping zip (already done). Use --force to redo."
    return 0
  fi

  ensure_dir "$ZIP_DIR"
  log "Extracting lab ZIP -> $ZIP_DIR"
  log "Source: $LAB_ZIP_PATH"

  # Need ~32GiB for the nested zpaq alone, plus headroom.
  local need=$(( 40 * 1024 * 1024 * 1024 ))
  local avail
  avail="$(bytes_available "$SOURCE_DIR")"
  if (( avail < need )); then
    die "Need ~$(human_bytes "$need") free under SOURCE_DIR; have $(human_bytes "$avail")."
  fi

  # If the ZIP already lives in SOURCE_DIR, still extract beside it under extract/
  unzip -o "$LAB_ZIP_PATH" -d "$ZIP_DIR"

  [[ -f "${ZIP_DIR}/Microsoft365DeviceLabKit.zpaq" ]] || \
    die "Expected Microsoft365DeviceLabKit.zpaq after ZIP extract"
  [[ -f "${ZIP_DIR}/zpaq.exe" ]] || die "Expected zpaq.exe after ZIP extract"
  [[ -f "${ZIP_DIR}/setup.exe" ]] || die "Expected setup.exe after ZIP extract"

  mark_done zip
}

extract_zpaq() {
  if step_done zpaq; then
    log "Skipping zpaq (already done). Use --force to redo."
    return 0
  fi

  marker_ok "${MARKERS_DIR}/zip.done" || die "Run zip step first"

  local archive="${ZIP_DIR}/Microsoft365DeviceLabKit.zpaq"
  [[ -f "$archive" ]] || die "Missing archive: $archive"

  ensure_dir "$ZPAQ_DIR"
  log "Extracting ZPAQ -> $ZPAQ_DIR"
  log "This can take a long time and use tens of GB of disk."

  local need=$(( 140 * 1024 * 1024 * 1024 ))
  local avail
  avail="$(bytes_available "$TMP_DIR")"
  if (( avail < need )); then
    warn "Low free space under TMP_DIR (have $(human_bytes "$avail"); ~$(human_bytes "$need") recommended)."
  fi

  # Use -to so Wine/zpaq cannot spill into the wrong CWD (seen extracting into /virtualmachines/).
  if ! run_zpaq x "$archive" -f -s1 -to "${ZPAQ_DIR}/"; then
    warn "zpaq with -s1 failed; retrying without summary flag"
    run_zpaq x "$archive" -f -to "${ZPAQ_DIR}/"
  fi

  local count
  count="$(find "$ZPAQ_DIR" -type f | wc -l)"
  (( count > 0 )) || die "ZPAQ extract produced no files under $ZPAQ_DIR"
  log "ZPAQ extract produced $count files"

  mark_done zpaq
}

extract_setup() {
  if step_done setup; then
    log "Skipping setup (already done). Use --force to redo."
    return 0
  fi

  marker_ok "${MARKERS_DIR}/zip.done" || die "Run zip step first"

  local setup="${ZIP_DIR}/setup.exe"
  [[ -f "$setup" ]] || die "Missing: $setup"

  ensure_dir "$SETUP_DIR"
  log "Unpacking setup.exe resources -> $SETUP_DIR"
  # Do not run setup.exe under Wine (would invite Mono/.NET).
  "$SEVEN" x -y "-o${SETUP_DIR}" "$setup" >/dev/null

  mark_done setup
}

organize_tree() {
  if step_done organize; then
    log "Skipping organize (already done). Use --force to redo."
    return 0
  fi

  marker_ok "${MARKERS_DIR}/zpaq.done" || die "Run zpaq step first"

  ensure_dir "$ORG_DISKS" "$ORG_VMS" "$ORG_TOOLS" "$ORG_META"
  log "Organizing extracted tree under $ORG_DIR"

  [[ -f "${ZIP_DIR}/zpaq.exe" ]] && ln -sfn "${ZIP_DIR}/zpaq.exe" "${ORG_TOOLS}/zpaq.exe"
  [[ -f "${ZIP_DIR}/setup.exe" ]] && ln -sfn "${ZIP_DIR}/setup.exe" "${ORG_TOOLS}/setup.exe"

  find "$ZPAQ_DIR" \( -iname '*.vhd' -o -iname '*.vhdx' \) -type f -print0 \
    | while IFS= read -r -d '' disk; do
        ln -sfn "$disk" "${ORG_DISKS}/$(basename "$disk")"
      done

  find "$ZPAQ_DIR" -type d \( -name 'Virtual Machines' -o -name 'Virtual Hard Disks' \) -print0 \
    | while IFS= read -r -d '' vdir; do
        local parent name
        parent="$(dirname "$vdir")"
        name="$(basename "$parent")"
        if [[ "$name" != "zpaq" && "$name" != "." ]]; then
          ln -sfn "$parent" "${ORG_VMS}/${name}"
        fi
      done

  {
    echo "# Lab extract inventory — $(date -Iseconds)"
    echo "# SOURCE_DIR=$SOURCE_DIR"
    echo "# TMP_DIR=$TMP_DIR"
    echo "# VM_ROOT=$VM_ROOT"
    echo
    echo "## Disks"
    find "$ORG_DISKS" \( -type l -o -type f \) 2>/dev/null | sort || true
    echo
    echo "## VM trees (Hyper-V originals in tmp — not lab VMs yet)"
    find "$ORG_VMS" -maxdepth 1 \( -type l -o -type d \) 2>/dev/null | sort || true
    echo
    echo "## Top-level ZPAQ entries"
    find "$ZPAQ_DIR" -maxdepth 2 \( -type f -o -type d \) | sort | head -200
  } >"$INVENTORY_FILE"

  save_resolved_paths_hint
  log "Inventory written: $INVENTORY_FILE"
  mark_done organize
}

case "$STEP" in
  zip) extract_zip ;;
  zpaq) extract_zpaq ;;
  setup) extract_setup ;;
  organize) organize_tree ;;
  all)
    extract_zip
    extract_zpaq
    extract_setup
    organize_tree
    ;;
  *)
    usage
    die "Unknown step: $STEP"
    ;;
esac

log "Done (step=$STEP)."
