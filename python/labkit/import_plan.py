"""Decide where a Proxmox disk image is copied, and whether it stays."""

from __future__ import annotations

import argparse
import re
import sys

_PATH_PART = re.compile(r"[A-Za-z0-9._@+-]+")


class ImportPlanError(Exception):
    """The images cannot fit, even one at a time."""


def format_bytes(size: int) -> str:
    amount = size / (1024 ** 3)
    if amount >= 10:
        return f"{amount:.0f} GB"
    return f"{amount:.1f} GB"


def plan(
    files: list[tuple[str, int]],
    *,
    import_free: int,
    disk_free: int,
    import_name: str,
    disk_name: str,
    keep: bool,
) -> tuple[str, str]:
    """Return ``keep`` or ``delete``, and the line to log.

    ``delete`` removes each upload after that guest disk exists.
    A request to keep the files falls back to delete when they do not all fit.
    """
    if not files:
        return "delete", "No disk images to upload."
    largest_name, largest = max(files, key=lambda item: item[1])
    total = sum(size for _name, size in files)
    same = import_name == disk_name
    if same:
        delete_need = total + largest
        keep_need = total * 2
        if delete_need > import_free:
            raise ImportPlanError(
                f"Storage {import_name} has {format_bytes(import_free)} free. "
                f"The guest disks and the largest upload need {format_bytes(delete_need)} at the same time."
            )
        if keep and keep_need > import_free:
            return (
                "delete",
                f"Keep uploaded images is on. The uploads and guest disks need {format_bytes(keep_need)} "
                f"on {import_name} and {format_bytes(import_free)} is free, so this run removes each upload after its import.",
            )
        if keep:
            return "keep", f"Uploaded images stay on {import_name}."
        return "delete", "Each upload is removed after its guest disk is created."
    if largest > import_free:
        raise ImportPlanError(
            f"Import storage {import_name} has {format_bytes(import_free)} free. "
            f"{largest_name} is {format_bytes(largest)}. The largest upload has to fit on its own."
        )
    if total > disk_free:
        raise ImportPlanError(
            f"Disk storage {disk_name} has {format_bytes(disk_free)} free. "
            f"The guest disks need {format_bytes(total)}."
        )
    if keep and total > import_free:
        return (
            "delete",
            f"Keep uploaded images is on. The uploads need {format_bytes(total)} on {import_name} "
            f"and {format_bytes(import_free)} is free, so this run removes each upload after its import.",
        )
    if keep:
        return "keep", f"Uploaded images stay on {import_name}."
    return "delete", "Each upload is removed after its guest disk is created."


def import_directory(record: dict) -> str:
    """Directory rsync writes, from the storage record.

    ``path`` is the mount Proxmox reported. ``content-dirs`` can replace the
    ``import`` folder. The guest disk is still imported as ``storage:import/name``.
    """
    path = str(record.get("path") or "")
    if not _directory_ok(path):
        raise ImportPlanError(
            "Import storage has no usable directory path. "
            "rsync copies onto directory, NFS, or CIFS storage. "
            "LVM and ZFS stay the disk storage."
        )
    folder = "import"
    raw = str(record.get("content-dirs") or "")
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise ImportPlanError(f"Import storage content-dirs entry {item!r} is not type=directory.")
        kind, value = item.split("=", 1)
        if kind == "import":
            folder = value.strip()
    parts = [part for part in folder.split("/") if part]
    if not parts or any(not _part_ok(part) for part in parts):
        raise ImportPlanError("Import storage content-dirs names an import directory the kit will not use.")
    return path.rstrip("/") + "/" + "/".join(parts)


def _part_ok(part: str) -> bool:
    return part not in {".", ".."} and _PATH_PART.fullmatch(part) is not None


def _directory_ok(path: str) -> bool:
    if not path.startswith("/"):
        return False
    parts = [part for part in path.split("/") if part]
    return bool(parts) and all(_part_ok(part) for part in parts)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Choose whether Proxmox uploads are kept.")
    parser.add_argument("--import-free", type=int, required=True)
    parser.add_argument("--disk-free", type=int, required=True)
    parser.add_argument("--import-name", required=True)
    parser.add_argument("--disk-name", required=True)
    parser.add_argument("--keep", choices=("0", "1"), required=True)
    args = parser.parse_args(argv)
    files: list[tuple[str, int]] = []
    for line in sys.stdin:
        text = line.strip()
        if not text:
            continue
        size_text, name = text.split("\t", 1)
        files.append((name, int(size_text)))
    try:
        mode, message = plan(
            files,
            import_free=args.import_free,
            disk_free=args.disk_free,
            import_name=args.import_name,
            disk_name=args.disk_name,
            keep=args.keep == "1",
        )
    except ImportPlanError as exc:
        print(exc, file=sys.stderr)
        return 1
    print(mode)
    print(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
