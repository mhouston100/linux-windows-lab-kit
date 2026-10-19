"""Read and update config/lab.env. The password is never logged."""

from __future__ import annotations

import shlex
import stat
from dataclasses import dataclass
from pathlib import Path

DEFAULT_VM_ROOT = Path("/virtualmachines")
DEFAULT_LAB_ZIP = Path("/virtualmachines/Kit/Original/Win11_25H2_Lab.zip")
DEFAULT_LAB_ZIP_NAME = "Win11_25H2_Lab.zip"


@dataclass
class LabConfig:
    root: Path
    source_dir: Path
    tmp_dir: Path
    vm_root: Path
    lab_zip_path: Path
    hypervisor: str
    lab_prefix: str
    lab_network_name: str
    lab_admin_user: str
    lab_admin_password: str
    lab_domain: str
    parallel: bool = True

    @property
    def markers_dir(self) -> Path:
        return self.tmp_dir / ".markers"

    @property
    def env_file(self) -> Path:
        return self.root / "config" / "lab.env"

    @property
    def password_set(self) -> bool:
        return bool(self.lab_admin_password)

    def summary_lines(self) -> list[str]:
        password = "set" if self.password_set else "not set"
        where = "local" if self.hypervisor == "virtualbox" else self.hypervisor
        return [
            f"Kit      {self.lab_zip_path}",
            f"Dest     {self.vm_root}",
            f"Account  {self.lab_domain} / {self.lab_admin_user}  password {password}",
            f"Hypervisor  {self.hypervisor}  {where}",
        ]


def _flag(value: str | None, default: bool) -> bool:
    if value is None or value == "":
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def _unquote(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    try:
        parts = shlex.split(value, posix=True)
    except ValueError:
        return value
    return parts[0] if parts else ""


def parse_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key.isidentifier():
            continue
        values[key] = _unquote(value)
    return values


def load_config(root: Path, kit: str | None = None, dest: str | None = None) -> LabConfig:
    env_path = root / "config" / "lab.env"
    values: dict[str, str] = {}
    if env_path.is_file():
        values = parse_env(env_path.read_text(encoding="utf-8", errors="replace"))

    vm_root = Path(values.get("VM_ROOT") or DEFAULT_VM_ROOT)
    source_dir = Path(values.get("SOURCE_DIR") or (vm_root / "source"))
    tmp_dir = Path(values.get("TMP_DIR") or (vm_root / "tmp"))
    if dest:
        vm_root = Path(dest)
        source_dir = vm_root / "source"
        tmp_dir = vm_root / "tmp"

    zip_value = kit or values.get("LAB_ZIP_PATH") or ""
    if not zip_value:
        named = source_dir / DEFAULT_LAB_ZIP_NAME
        zip_value = str(named if named.is_file() else DEFAULT_LAB_ZIP if DEFAULT_LAB_ZIP.is_file() else named)

    return LabConfig(
        root=root,
        source_dir=source_dir,
        tmp_dir=tmp_dir,
        vm_root=vm_root,
        lab_zip_path=Path(zip_value),
        hypervisor=values.get("HYPERVISOR") or "virtualbox",
        lab_prefix=values.get("LAB_PREFIX") or "HYD",
        lab_network_name=values.get("LAB_NETWORK_NAME") or "CorpNet",
        lab_admin_user=values.get("LAB_ADMIN_USER") or "LabAdmin",
        lab_admin_password=values.get("LAB_ADMIN_PASSWORD") or "",
        lab_domain=values.get("LAB_DOMAIN") or "Corp",
        parallel=_flag(values.get("LAB_PARALLEL"), default=True),
    )


def write_keys(env_file: Path, example: Path, updates: dict[str, str]) -> None:
    """Replace keys in lab.env. Comments and unrelated lines stay."""
    if not env_file.is_file():
        if not example.is_file():
            raise FileNotFoundError(example)
        env_file.write_text(example.read_text(encoding="utf-8"), encoding="utf-8")
    remaining = dict(updates)
    output: list[str] = []
    for line in env_file.read_text(encoding="utf-8").splitlines():
        replaced = False
        for key in list(remaining):
            if line.startswith(f"{key}="):
                output.append(f"{key}={shlex.quote(remaining.pop(key))}")
                replaced = True
                break
        if not replaced:
            output.append(line)
    for key, value in remaining.items():
        output.append(f"{key}={shlex.quote(value)}")
    env_file.write_text("\n".join(output) + "\n", encoding="utf-8")
    env_file.chmod(stat.S_IRUSR | stat.S_IWUSR)


def hypervisors(root: Path) -> list[str]:
    base = root / "scripts" / "hypervisors"
    if not base.is_dir():
        return []
    names = [path.name for path in sorted(base.iterdir()) if (path / "load.sh").is_file()]
    return names
