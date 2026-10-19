"""Read and update config/lab.env. The password is never logged."""

from __future__ import annotations

import shlex
import stat
import subprocess
from dataclasses import dataclass, field
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
    work_dir: Path = field(default_factory=lambda: Path("/virtualmachines"))

    @property
    def markers_dir(self) -> Path:
        return self.tmp_dir / ".markers"

    @property
    def env_file(self) -> Path:
        return self.root / "config" / "lab.env"

    @property
    def password_set(self) -> bool:
        return bool(self.lab_admin_password)

    def cli_env(self) -> dict[str, str]:
        """Paths for a stage. Work files and the VM directory stay independent."""
        return {
            "LAB_CLI_KIT": str(self.lab_zip_path),
            "LAB_CLI_WORK": str(self.work_dir),
            "LAB_CLI_VM_DIR": str(self.vm_root),
        }

    def summary_lines(self) -> list[str]:
        password = "set" if self.password_set else "not set"
        where = "local" if self.hypervisor == "virtualbox" else self.hypervisor
        return [
            f"Kit      {self.lab_zip_path}",
            f"Work     {self.work_dir}",
            f"VMs      {self.vm_root}",
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
    work_dir = _work_dir(values, vm_root)
    if dest:
        work_dir = Path(dest)
        vm_root = work_dir
    source_dir = work_dir / "source"
    tmp_dir = work_dir / "tmp"

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
        work_dir=work_dir,
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


def ordered_hypervisors(root: Path) -> list[str]:
    """Installed backends, with VirtualBox first."""
    names = hypervisors(root)
    if "virtualbox" in names:
        names = ["virtualbox", *[name for name in names if name != "virtualbox"]]
    return names


@dataclass(frozen=True)
class HypervisorField:
    key: str
    label: str
    value: str
    editable: bool


def guest_additions_iso() -> str:
    """The VirtualBox Guest Additions ISO, or a short note when it is missing."""
    listed = ""
    try:
        completed = subprocess.run(
            ["VBoxManage", "list", "systemproperties"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        completed = None
    if completed is not None:
        prefix = "Default Guest Additions ISO:"
        for line in completed.stdout.splitlines():
            if line.startswith(prefix):
                listed = line[len(prefix):].strip()
                break
    for candidate in (
        listed,
        "/usr/lib/virtualbox/additions/VBoxGuestAdditions.iso",
        "/usr/share/virtualbox/VBoxGuestAdditions.iso",
    ):
        if candidate and Path(candidate).is_file():
            return candidate
    return "not found"


def _work_dir(values: dict[str, str], vm_root: Path) -> Path:
    """Folder for the unzip, converted disks, and log. source/ and tmp/ live under it."""
    explicit = values.get("LAB_WORK_DIR")
    if explicit:
        return Path(explicit)
    source = values.get("SOURCE_DIR")
    tmp = values.get("TMP_DIR")
    if source and tmp:
        source_path = Path(source)
        tmp_path = Path(tmp)
        if source_path.name == "source" and tmp_path.name == "tmp" and source_path.parent == tmp_path.parent:
            return source_path.parent
    return vm_root


def hypervisor_fields(name: str, vm_dir: str = "") -> list[HypervisorField]:
    """Settings for one backend. Locked fields stay visible."""
    if name == "virtualbox":
        return [
            HypervisorField("disk-format", "Disk format", "VDI", False),
            HypervisorField("ga-iso", "Guest Additions ISO", guest_additions_iso(), False),
            HypervisorField("vm-dir", "VM directory", vm_dir, True),
        ]
    return []
