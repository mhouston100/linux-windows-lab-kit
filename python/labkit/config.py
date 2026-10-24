"""Read and update config/lab.env. The password is never logged."""

from __future__ import annotations

import re
import shlex
import stat
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_VM_ROOT = Path("/virtualmachines")
DEFAULT_LAB_ZIP = Path("/virtualmachines/Kit/Original/Win11_25H2_Lab.zip")
DEFAULT_LAB_ZIP_NAME = "Win11_25H2_Lab.zip"

# The kit ships with this account and its credentials cached on every guest.
# They cannot be changed, so they are not settings. The password lives in
# scripts/lib/config.sh, which the stage scripts read.
LAB_DOMAIN = "Corp"
LAB_ADMIN_USER = "LabAdmin"
DEFAULT_PVE_NODE = "pve"
DEFAULT_PVE_IMPORT_STORAGE = "local"
DEFAULT_PVE_STORAGE = "local-lvm"
DEFAULT_PVE_BRIDGE = "vmbr1"
DEFAULT_PVE_INTERNET_BRIDGE = "vmbr0"
DEFAULT_PVE_TOKEN_ID = "root@pam!root"
DEFAULT_PVE_SSH_USER = "root"
DEFAULT_PVE_SSH_PORT = "22"


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
    parallel: bool = True
    work_dir: Path = field(default_factory=lambda: Path("/virtualmachines"))
    guest_additions_iso: str = ""
    pve_api_host: str = ""
    pve_tls_fingerprint: str = ""
    pve_node: str = ""
    pve_import_storage: str = ""
    pve_storage: str = ""
    pve_keep_imports: bool = False
    pve_bridge: str = ""
    pve_internet_bridge: str = ""
    pve_token_id: str = ""
    pve_token_secret: str = ""
    pve_ssh_user: str = ""
    pve_ssh_host: str = ""
    pve_ssh_port: str = ""
    pve_ssh_identity: str = ""
    pve_virtio_iso: str = ""
    libvirt_uri: str = "qemu:///system"
    libvirt_virtio_iso: str = ""

    @property
    def markers_dir(self) -> Path:
        return self.tmp_dir / ".markers"

    @property
    def env_file(self) -> Path:
        return self.root / "config" / "lab.env"

    def cli_env(self) -> dict[str, str]:
        """Paths for a stage. Work files and the VM directory stay independent."""
        return {
            "LAB_CLI_KIT": str(self.lab_zip_path),
            "LAB_CLI_WORK": str(self.work_dir),
            "LAB_CLI_VM_DIR": str(self.vm_root),
        }

    def summary_lines(self) -> list[str]:
        if self.hypervisor == "proxmox":
            where = self.pve_api_host or "API host not set"
            machines = self.pve_node or "node not set"
        elif self.hypervisor == "virtualbox":
            where = "local"
            machines = str(self.vm_root)
        elif self.hypervisor == "libvirt":
            where = self.libvirt_uri or "qemu:///system"
            machines = str(self.vm_root)
        else:
            where = self.hypervisor
            machines = str(self.vm_root)
        return [
            f"Kit      {self.lab_zip_path}",
            f"Work     {self.work_dir}",
            f"VMs      {machines}",
            f"Account  {LAB_DOMAIN}\\{LAB_ADMIN_USER}  (preconfigured in the kit)",
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
        parallel=_flag(values.get("LAB_PARALLEL"), default=True),
        work_dir=work_dir,
        guest_additions_iso=values.get("VBOX_GUEST_ADDITIONS_ISO") or guest_additions_iso(),
        pve_api_host=values.get("PVE_API_HOST") or "",
        pve_tls_fingerprint=values.get("PVE_TLS_FINGERPRINT") or "",
        pve_node=values.get("PVE_NODE") or DEFAULT_PVE_NODE,
        pve_import_storage=values.get("PVE_IMPORT_STORAGE") or DEFAULT_PVE_IMPORT_STORAGE,
        pve_storage=values.get("PVE_STORAGE") or DEFAULT_PVE_STORAGE,
        pve_keep_imports=_flag(values.get("PVE_KEEP_IMPORTS"), default=False),
        pve_bridge=values.get("PVE_BRIDGE") or DEFAULT_PVE_BRIDGE,
        pve_internet_bridge=values.get("PVE_INTERNET_BRIDGE") or DEFAULT_PVE_INTERNET_BRIDGE,
        pve_token_id=values.get("PVE_TOKEN_ID") or DEFAULT_PVE_TOKEN_ID,
        pve_token_secret=values.get("PVE_TOKEN_SECRET") or "",
        pve_ssh_user=values.get("PVE_SSH_USER") or DEFAULT_PVE_SSH_USER,
        pve_ssh_host=values.get("PVE_SSH_HOST") or "",
        pve_ssh_port=values.get("PVE_SSH_PORT") or DEFAULT_PVE_SSH_PORT,
        pve_ssh_identity=values.get("PVE_SSH_IDENTITY") or "",
        pve_virtio_iso=values.get("PVE_VIRTIO_ISO") or "",
        libvirt_uri=values.get("LIBVIRT_URI") or "qemu:///system",
        libvirt_virtio_iso=values.get("LIBVIRT_VIRTIO_ISO") or values.get("PVE_VIRTIO_ISO") or "",
    )


def example_defaults(example: Path) -> dict[str, str]:
    """Uncommented example assignments that have a value. Empty and commented lines stay out."""
    if not example.is_file():
        return {}
    defaults: dict[str, str] = {}
    for raw in example.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key.isidentifier():
            continue
        value = _unquote(value)
        if value == "":
            continue
        defaults[key] = value
    return defaults


def ensure_saved_defaults(root: Path) -> None:
    """Write example defaults that lab.env does not already set.

    The menu shows these values even when the line was never saved. A stage
    sources the file, so the line has to be there. Existing lines stay.
    """
    env_file = root / "config" / "lab.env"
    example = root / "config" / "lab.env.example"
    if not example.is_file():
        return
    if not env_file.is_file():
        env_file.parent.mkdir(parents=True, exist_ok=True)
        write_keys(env_file, example, {})
        return
    present = parse_env(env_file.read_text(encoding="utf-8", errors="replace"))
    missing = {key: value for key, value in example_defaults(example).items() if key not in present}
    if not missing:
        return
    write_keys(env_file, example, missing)


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
    secret: bool = False
    placeholder: str = ""


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


def hypervisor_fields(
    name: str,
    vm_dir: str = "",
    ga_iso: str | None = None,
    proxmox: dict[str, str] | None = None,
    libvirt: dict[str, str] | None = None,
) -> list[HypervisorField]:
    """Settings for one backend. Locked fields stay visible."""
    if name == "virtualbox":
        iso = guest_additions_iso() if ga_iso is None else ga_iso
        return [
            HypervisorField("disk-format", "Disk format", "VDI", False),
            HypervisorField("ga-iso", "Guest Additions ISO", iso, True),
            HypervisorField("vm-dir", "VM directory", vm_dir, True),
        ]
    if name == "libvirt":
        values = libvirt or {}
        return [
            HypervisorField("disk-format", "Disk format", "qcow2", False),
            HypervisorField("uri", "URI", values.get("uri") or "qemu:///system", True),
            HypervisorField("vm-dir", "VM directory", vm_dir, True),
            HypervisorField(
                "virtio-iso",
                "Virtio ISO",
                values.get("virtio_iso", ""),
                True,
                placeholder="virtio-win ISO downloaded on this machine",
            ),
        ]
    if name == "proxmox":
        values = proxmox or {}
        return [
            HypervisorField("disk-format", "Disk format", "qcow2", False),
            HypervisorField("api-host", "API host", values.get("api_host", ""), True, placeholder="host:8006"),
            HypervisorField(
                "fingerprint",
                "TLS fingerprint",
                values.get("tls_fingerprint", ""),
                True,
                placeholder="Optional. SHA256 pin of the node certificate. Blank skips the check",
            ),
            HypervisorField("node", "Node", values.get("node") or DEFAULT_PVE_NODE, True),
            HypervisorField(
                "import-storage",
                "Import storage",
                values.get("import_storage") or DEFAULT_PVE_IMPORT_STORAGE,
                True,
            ),
            HypervisorField("storage", "Disk storage", values.get("storage") or DEFAULT_PVE_STORAGE, True),
            HypervisorField("bridge", "CorpNet bridge", values.get("bridge") or DEFAULT_PVE_BRIDGE, True),
            HypervisorField(
                "internet-bridge",
                "Internet bridge",
                values.get("internet_bridge") or DEFAULT_PVE_INTERNET_BRIDGE,
                True,
            ),
            HypervisorField("token-id", "Token id", values.get("token_id") or DEFAULT_PVE_TOKEN_ID, True),
            HypervisorField(
                "token-secret",
                "Token secret",
                "",
                True,
                secret=True,
                placeholder="Leave blank to keep the current token",
            ),
            HypervisorField("ssh-user", "SSH user", values.get("ssh_user") or DEFAULT_PVE_SSH_USER, True),
            HypervisorField(
                "ssh-host",
                "SSH host",
                values.get("ssh_host", ""),
                True,
                placeholder="Blank uses the API host",
            ),
            HypervisorField("ssh-port", "SSH port", values.get("ssh_port") or DEFAULT_PVE_SSH_PORT, True),
            HypervisorField(
                "ssh-identity",
                "SSH identity",
                values.get("ssh_identity", ""),
                True,
                placeholder="Optional key. A menu run asks for the password",
            ),
            HypervisorField(
                "virtio-iso",
                "Virtio ISO",
                values.get("virtio_iso", ""),
                True,
                placeholder="virtio-win ISO downloaded on this machine",
            ),
        ]
    return []


_PVE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,62}")
_PVE_TOKEN = re.compile(r"[A-Za-z0-9._-]{1,64}@[A-Za-z0-9._-]{1,32}![A-Za-z0-9._-]{1,64}")


def proxmox_host_ok(value: str) -> bool:
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,252})(?::[0-9]{1,5})?", value):
        return False
    if ":" in value:
        port = int(value.rsplit(":", 1)[1])
        return 1 <= port <= 65535
    return True


def proxmox_name_ok(value: str) -> bool:
    return _PVE_NAME.fullmatch(value) is not None


def proxmox_token_ok(value: str) -> bool:
    return _PVE_TOKEN.fullmatch(value) is not None


def normalize_fingerprint(value: str) -> str | None:
    text = value.strip().upper()
    if text.startswith("SHA256:"):
        text = text[7:]
    text = text.replace(":", "").replace(" ", "")
    if len(text) != 64 or any(char not in "0123456789ABCDEF" for char in text):
        return None
    return ":".join(text[index:index + 2] for index in range(0, 64, 2))


def proxmox_ssh_user_ok(value: str) -> bool:
    return re.fullmatch(r"[A-Za-z_][A-Za-z0-9._-]{0,31}", value) is not None


def proxmox_ssh_host_ok(value: str) -> bool:
    if value == "":
        return True
    return re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,252})?", value) is not None


def proxmox_ssh_port_ok(value: str) -> bool:
    if not re.fullmatch(r"[0-9]{1,5}", value):
        return False
    return 1 <= int(value) <= 65535


def proxmox_virtio_iso_ok(value: str) -> bool:
    """A blank field can be saved. A run still refuses to start until the file exists."""
    if value == "":
        return True
    if any(ord(char) <= 32 or char in "\"'\\$`" for char in value):
        return False
    return value.lower().endswith(".iso") and Path(value).is_file()


def virtio_iso_block(config: LabConfig) -> str:
    """Stop a Proxmox or libvirt run before any stage when the virtio-win ISO is missing."""
    if config.hypervisor == "libvirt":
        path = config.libvirt_virtio_iso.strip()
    elif config.hypervisor == "proxmox":
        path = config.pve_virtio_iso.strip()
    else:
        return ""
    if not path:
        return "Set Virtio ISO to the virtio-win ISO you downloaded. The run has not started."
    if not proxmox_virtio_iso_ok(path):
        return f"Virtio ISO was not found: {path}. The run has not started."
    return ""


def proxmox_ssh_identity_ok(value: str) -> bool:
    if value == "":
        return True
    if any(ord(char) <= 32 or char in "\"'\\$`" for char in value):
        return False
    return Path(value).is_file()


def proxmox_secret_ok(value: str) -> bool:
    if not value or len(value) > 256:
        return False
    return all(32 < ord(char) < 127 and char not in "\"'\\$`#" for char in value)


def missing_proxmox_settings(config: LabConfig) -> list[str]:
    """Labels for Proxmox settings a create or start still needs."""
    missing: list[str] = []
    if not proxmox_host_ok(config.pve_api_host):
        missing.append("API host")
    if config.pve_tls_fingerprint and normalize_fingerprint(config.pve_tls_fingerprint) is None:
        missing.append("TLS fingerprint")
    if not proxmox_name_ok(config.pve_node):
        missing.append("node")
    if not proxmox_name_ok(config.pve_import_storage):
        missing.append("import storage")
    if not proxmox_name_ok(config.pve_storage):
        missing.append("disk storage")
    if not proxmox_name_ok(config.pve_bridge):
        missing.append("CorpNet bridge")
    if not proxmox_name_ok(config.pve_internet_bridge):
        missing.append("Internet bridge")
    if not proxmox_token_ok(config.pve_token_id):
        missing.append("token id")
    if not proxmox_secret_ok(config.pve_token_secret):
        missing.append("token secret")
    if not proxmox_ssh_user_ok(config.pve_ssh_user):
        missing.append("SSH user")
    if not proxmox_ssh_host_ok(config.pve_ssh_host):
        missing.append("SSH host")
    if not proxmox_ssh_port_ok(config.pve_ssh_port):
        missing.append("SSH port")
    if not proxmox_ssh_identity_ok(config.pve_ssh_identity):
        missing.append("SSH identity")
    if not proxmox_virtio_iso_ok(config.pve_virtio_iso):
        missing.append("Virtio ISO")
    return missing
