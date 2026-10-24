"""Textual menu. Bash still runs each stage."""

from __future__ import annotations

import threading
from datetime import datetime
from pathlib import Path

from textual.actions import SkipAction
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, HorizontalScroll, Vertical, VerticalScroll
from textual.events import MouseUp
from textual.screen import ModalScreen
from textual.widget import Widget
from textual.widgets import Button, Checkbox, Header, Input, Label, ProgressBar, RichLog, Static

from labkit.clipboard import read_clipboard, write_clipboard
from labkit.config import (
    HypervisorField,
    LabConfig,
    hypervisor_fields,
    load_config,
    missing_proxmox_settings,
    normalize_fingerprint,
    ordered_hypervisors,
    proxmox_host_ok,
    proxmox_name_ok,
    proxmox_secret_ok,
    proxmox_ssh_host_ok,
    proxmox_ssh_identity_ok,
    proxmox_ssh_port_ok,
    proxmox_ssh_user_ok,
    proxmox_token_ok,
    proxmox_virtio_iso_ok,
    virtio_iso_block,
    write_keys,
)
from labkit.runner import run_script, stage_args
from labkit.stages import (
    STAGES,
    Stage,
    next_stage,
    note_progress,
    stage_needs_sudo,
    stage_percent,
    stage_state,
    stages_to_run,
)
from labkit.ssh_auth import SshSession, login_error, start_ssh_session
from labkit.sudo_auth import MountHelper, start_mount_helper

_GENERAL = ("kit", "work")


def _platform_label(name: str) -> str:
    if name == "virtualbox":
        return "VirtualBox"
    if name == "proxmox":
        return "Proxmox"
    if name == "libvirt":
        return "libvirt"
    return name


def _hypervisor_title(name: str) -> str:
    return f"{_platform_label(name)} - Edit hypervisor settings here"


def _run_next_label(config: LabConfig) -> str:
    stage = next_stage(config)
    if stage is None:
        return "Run Next (done)"
    return f"Run Next (Stage {stage.number})"


class ConfirmReset(ModalScreen[bool]):
    def compose(self) -> ComposeResult:
        yield Vertical(
            Static("Reset deletes the lab VMs, their folders, and source/. tmp is cleared except lab.log. The kit ZIP is kept."),
            Horizontal(
                Button("Reset", id="yes", variant="error"),
                Button("Cancel", id="no", variant="primary"),
            ),
            id="confirm",
        )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")


class LabInput(Input):
    """Input that copies and pastes through the desktop clipboard."""

    BINDINGS = [
        Binding("ctrl+shift+v,shift+insert", "paste", show=False),
        Binding("ctrl+shift+c", "copy", show=False),
    ]

    def action_copy(self) -> None:
        selected = self.selected_text
        if not selected:
            raise SkipAction()
        write_clipboard(selected)
        self.app.copy_to_clipboard(selected)

    def action_paste(self) -> None:
        if self.disabled:
            return
        self._insert_pasted(read_clipboard() or self.app.clipboard)

    def on_mouse_up(self, event: MouseUp) -> None:
        if event.button != 2 or self.disabled:
            return
        event.stop()
        self.focus()
        self._insert_pasted(read_clipboard(primary=True) or read_clipboard() or self.app.clipboard)

    def _insert_pasted(self, text: str) -> None:
        line = text.splitlines()[0].strip() if text else ""
        if not line:
            return
        start, end = self.selection
        self.replace(line, start, end)


class SudoPrompt(ModalScreen[bool]):
    """Ask once. The helper started here serves every mount in the run."""

    BINDINGS = [Binding("escape", "cancel_sudo", "Cancel", show=False)]

    def __init__(self, script: Path) -> None:
        super().__init__()
        self.script = script
        self.helper: MountHelper | None = None
        self._checking = False

    def compose(self) -> ComposeResult:
        yield Vertical(
            Static(
                "Enter your sudo password for this computer. "
                "sudo is needed once, to mount the guest disks and plant the QEMU guest agent. "
                "The rest of this run will not ask again. "
                "It is not stored, and it is not the Proxmox or the lab account password."
            ),
            LabInput(placeholder="sudo password", password=True, id="sudo-password"),
            Horizontal(
                Button("Continue", id="sudo-continue", variant="primary"),
                Button("Cancel", id="sudo-cancel"),
            ),
            id="sudo-form",
        )

    def on_mount(self) -> None:
        self.query_one("#sudo-password", Input).focus()

    def action_cancel_sudo(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "sudo-cancel":
            event.stop()
            self.dismiss(False)
            return
        if event.button.id == "sudo-continue":
            event.stop()
            self._submit()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        event.stop()
        self._submit()

    def _submit(self) -> None:
        if self._checking:
            return
        field = self.query_one("#sudo-password", Input)
        password = field.value
        field.value = ""
        if password == "":
            self.notify("Enter your sudo password.", severity="warning")
            field.focus()
            return
        self._checking = True
        helper: MountHelper | None = None
        try:
            helper = start_mount_helper(self.script, password)
        except Exception:
            helper = None
        finally:
            del password
            self._checking = False
        if helper is None:
            self.notify("sudo did not accept that password.", severity="error")
            field.focus()
            return
        self.helper = helper
        self.dismiss(True)


class SshPrompt(ModalScreen[bool]):
    """Ask once, before a run starts. The password lasts for that run only."""

    BINDINGS = [Binding("escape", "cancel_ssh", "Cancel", show=False)]

    def __init__(self, login: tuple[str, str, str] | None) -> None:
        super().__init__()
        self.login = login
        self.session: SshSession | None = None
        self._checking = False

    def compose(self) -> ComposeResult:
        if self.login is None:
            who = "the Proxmox node"
        else:
            user, host, port = self.login
            who = f"{user}@{host}" if port == "22" else f"{user}@{host} port {port}"
        yield Vertical(
            Static(
                f"Enter the SSH password for {who} once. "
                "The rest of this run will not ask again. "
                "It is not stored, and it is not the lab account password."
            ),
            LabInput(placeholder="SSH password", password=True, id="ssh-password"),
            Horizontal(
                Button("Continue", id="ssh-continue", variant="primary"),
                Button("Cancel", id="ssh-cancel"),
            ),
            id="ssh-form",
        )

    def on_mount(self) -> None:
        self.query_one("#ssh-password", Input).focus()

    def action_cancel_ssh(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "ssh-cancel":
            event.stop()
            self.dismiss(False)
            return
        if event.button.id == "ssh-continue":
            event.stop()
            self._submit()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        event.stop()
        self._submit()

    def _submit(self) -> None:
        if self._checking:
            return
        field = self.query_one("#ssh-password", Input)
        password = field.value
        field.value = ""
        if password == "":
            self.notify("Enter the SSH password.", severity="warning")
            field.focus()
            return
        session = start_ssh_session(password)
        del password
        if session is None:
            self.notify("That SSH password cannot be used.", severity="warning")
            field.focus()
            return
        if self.login is None:
            session.stop()
            self.notify("Set the SSH user and host before continuing.", severity="warning")
            field.focus()
            return
        self._checking = True
        self.notify("Checking the SSH login.")
        try:
            problem = login_error(session, *self.login)
        finally:
            self._checking = False
        if problem:
            session.stop()
            self.notify(problem, severity="error")
            field.focus()
            return
        user, host, port = self.login
        where = f"{user}@{host}" if port == "22" else f"{user}@{host} port {port}"
        write = getattr(self.app, "_write", None)
        if write is not None:
            write(f"SSH login accepted for {where}.")
        self.session = session
        self.dismiss(True)


class LabApp(App[int]):
    TITLE = "Linux Windows Lab Kit"
    CSS = """
    #setup { height: auto; }
    .panel {
        height: auto;
        border: round $accent;
        padding: 0 1;
        margin-bottom: 1;
    }
    #platforms { height: 3; }
    #platforms Button { margin-right: 1; }
    .setting { height: auto; align: left middle; }
    .setting Label { width: 22; }
    .setting Input {
        width: 1fr;
        height: 1;
        border: none;
        border-left: tall $accent;
        border-right: tall $accent;
        background: $primary 40%;
        padding: 0 1;
    }
    .setting Input:focus {
        border-left: tall $accent;
        border-right: tall $accent;
        background: $primary 25%;
    }
    .setting Input.locked {
        height: 1;
        border: none;
        background: transparent;
        color: $text-muted;
        padding: 0;
    }
    #hv-body { height: auto; align: left middle; }
    #hv-fields { width: 1fr; height: auto; }
    #test-connection { margin-left: 1; }
    #parallel { height: 1; width: auto; margin: 0; }
    #hv-keep-imports { height: 1; width: auto; margin: 0; }
    #stages { height: auto; }
    .stage { height: 1; }
    .stage Label { width: 26; }
    .meta { width: 16; }
    ProgressBar { width: 1fr; }
    #actions { height: 3; }
    #actions Button { margin-right: 1; }
    Screen { overflow-y: auto; }
    #log { height: 1fr; min-height: 5; }
    #confirm, #sudo-form, #ssh-form { padding: 1 2; width: 80; height: auto; border: round $accent; background: $surface; }
    """
    BINDINGS = [
        Binding("a", "run_all", "Run all", show=False),
        Binding("n", "run_next", "Run next", show=False),
        Binding("c", "reset", "Reset", show=False),
        Binding("q", "quit", "Quit", show=False),
        Binding("ctrl+c", "cancel", "Stop", show=False),
    ]

    def __init__(self, config: LabConfig, forward: list[str]) -> None:
        super().__init__()
        self.cfg = config
        self.forward = forward
        self.platform_names = ordered_hypervisors(config.root) or [config.hypervisor]
        self._busy = False
        self._busy_stage: int | None = None
        self._live_pct: int | None = None
        self._cancel = threading.Event()

    def compose(self) -> ComposeResult:
        yield Header()
        with VerticalScroll(id="setup"):
            with Vertical(id="platform-box", classes="panel"):
                with HorizontalScroll(id="platforms"):
                    for name in self.platform_names:
                        selected = name == self.cfg.hypervisor
                        yield Button(
                            _platform_label(name),
                            id=f"platform-{name}",
                            variant="primary" if selected else "default",
                        )
            with Vertical(id="hv-settings", classes="panel"):
                with Horizontal(id="hv-body"):
                    with Vertical(id="hv-fields"):
                        yield from self._hv_mount_widgets()
                    yield Button("Test connection", id="test-connection")
            with Vertical(id="lab-settings", classes="panel"):
                yield from self._general_row("Kit ZIP", str(self.cfg.lab_zip_path), "kit")
                yield from self._general_row("Work directory", str(self.cfg.work_dir), "work")
                yield Checkbox("Parallel disks", value=self.cfg.parallel, id="parallel", compact=True)
            with Vertical(id="stages", classes="panel"):
                for stage in STAGES:
                    with Horizontal(classes="stage"):
                        yield Label(f"{stage.number}  {stage.title}", id=f"label-{stage.number}")
                        yield ProgressBar(total=100, show_eta=False, id=f"bar-{stage.number}")
                        yield Label("", id=f"meta-{stage.number}", classes="meta")
        with Vertical(id="run-box", classes="panel"):
            with HorizontalScroll(id="actions"):
                yield Button("Run all (a)", id="run-all", variant="primary")
                yield Button(_run_next_label(self.cfg), id="run-next")
                yield Button("Reset (c)", id="reset", variant="error")
                yield Button("Quit (q)", id="quit")
        yield RichLog(id="log", classes="panel", highlight=False, markup=False, wrap=True, max_lines=500)

    def _hv_fields(self) -> list[HypervisorField]:
        return hypervisor_fields(
            self.cfg.hypervisor,
            str(self.cfg.vm_root),
            self.cfg.guest_additions_iso,
            {
                "api_host": self.cfg.pve_api_host,
                "tls_fingerprint": self.cfg.pve_tls_fingerprint,
                "node": self.cfg.pve_node,
                "import_storage": self.cfg.pve_import_storage,
                "storage": self.cfg.pve_storage,
                "bridge": self.cfg.pve_bridge,
                "internet_bridge": self.cfg.pve_internet_bridge,
                "token_id": self.cfg.pve_token_id,
                "ssh_user": self.cfg.pve_ssh_user,
                "ssh_host": self.cfg.pve_ssh_host,
                "ssh_port": self.cfg.pve_ssh_port,
                "ssh_identity": self.cfg.pve_ssh_identity,
                "virtio_iso": self.cfg.pve_virtio_iso,
            },
            {
                "uri": self.cfg.libvirt_uri,
                "virtio_iso": self.cfg.libvirt_virtio_iso,
            },
        )

    @staticmethod
    def _general_row(label: str, value: str, field_id: str) -> ComposeResult:
        yield Horizontal(
            Label(label),
            LabInput(value=value, id=field_id),
            classes="setting",
        )

    def _hv_mount_widgets(self) -> list[Widget]:
        widgets: list[Widget] = list(self._hypervisor_rows(self._hv_fields()))
        if self.cfg.hypervisor == "proxmox":
            widgets.append(
                Checkbox(
                    "Keep uploaded images",
                    value=self.cfg.pve_keep_imports,
                    id="hv-keep-imports",
                    compact=True,
                )
            )
        return widgets

    @staticmethod
    def _hypervisor_rows(fields: list[HypervisorField]) -> ComposeResult:
        if not fields:
            yield Static("No extra settings for this platform.")
            return
        for field in fields:
            yield Horizontal(
                Label(field.label),
                LabInput(
                    value="" if field.secret else field.value,
                    id=f"hv-{field.key}",
                    password=field.secret,
                    placeholder=field.placeholder,
                    disabled=not field.editable,
                    compact=not field.editable,
                    classes=None if field.editable else "locked",
                ),
                classes="setting",
            )

    def on_mount(self) -> None:
        self.query_one("#platform-box", Vertical).border_title = "Hypervisor - Choose the platform"
        self.query_one("#hv-settings", Vertical).border_title = _hypervisor_title(self.cfg.hypervisor)
        self.query_one("#lab-settings", Vertical).border_title = "Lab - Edit general lab settings here"
        self.query_one("#stages", Vertical).border_title = "Status - Stage completion status"
        self.query_one("#run-box", Vertical).border_title = "Run - Start the lab or reset it"
        self.query_one("#log", RichLog).border_title = "Log - Output from this run"
        self.refresh_stages()
        self._write("Check the settings, then Run all or Run next. a and n do the same.")

    def refresh_stages(self) -> None:
        for stage in STAGES:
            state = stage_state(self.cfg, stage, self._busy_stage)
            percent = stage_percent(self.cfg, stage, self._busy_stage, self._live_pct)
            self.query_one(f"#bar-{stage.number}", ProgressBar).update(progress=percent)
            self.query_one(f"#meta-{stage.number}", Label).update(f"{percent:3d}%  {state}")
        self._sync_actions()

    def _sync_actions(self) -> None:
        for button_id in ("run-all", "run-next", "reset", "test-connection"):
            self.query_one(f"#{button_id}", Button).disabled = self._busy
        self.query_one("#run-next", Button).label = _run_next_label(self.cfg)
        self.query_one("#parallel", Checkbox).disabled = self._busy
        for field_id in _GENERAL:
            self.query_one(f"#{field_id}", Input).disabled = self._busy
        for name in self.platform_names:
            button = self.query_one(f"#platform-{name}", Button)
            button.disabled = self._busy
            button.variant = "primary" if name == self.cfg.hypervisor else "default"
        for field in self.query("#hv-settings Input"):
            field.disabled = True if "locked" in field.classes else self._busy
        for box in self.query("#hv-keep-imports"):
            box.disabled = self._busy

    def _write(self, line: str) -> None:
        self.query_one("#log", RichLog).write(line)
        path = self.cfg.tmp_dir / "lab.log"
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now().astimezone().isoformat(timespec="seconds")
            with path.open("a", encoding="utf-8") as handle:
                handle.write(f"{stamp} {line}\n")
        except OSError:
            pass

    def _from_stage(self, line: str) -> None:
        def apply() -> None:
            self._write(line)
            found = note_progress(line)
            if found is not None:
                self._live_pct = found
            self.refresh_stages()

        self.call_from_thread(apply)

    def _outside_checkout(self, value: str) -> bool:
        return not value or value in {"/", str(self.cfg.root)}

    def _save_proxmox_text(self, field_id: str, updates: dict[str, str]) -> bool:
        key, current, invalid, accept = {
            "hv-api-host": (
                "PVE_API_HOST",
                self.cfg.pve_api_host,
                "API host must be a hostname or address, with an optional port.",
                proxmox_host_ok,
            ),
            "hv-node": (
                "PVE_NODE",
                self.cfg.pve_node,
                "Node must use letters, digits, dots, underscores, or hyphens.",
                proxmox_name_ok,
            ),
            "hv-import-storage": (
                "PVE_IMPORT_STORAGE",
                self.cfg.pve_import_storage,
                "Import storage must use letters, digits, dots, underscores, or hyphens.",
                proxmox_name_ok,
            ),
            "hv-storage": (
                "PVE_STORAGE",
                self.cfg.pve_storage,
                "Disk storage must use letters, digits, dots, underscores, or hyphens.",
                proxmox_name_ok,
            ),
            "hv-bridge": (
                "PVE_BRIDGE",
                self.cfg.pve_bridge,
                "CorpNet bridge must use letters, digits, dots, underscores, or hyphens.",
                proxmox_name_ok,
            ),
            "hv-internet-bridge": (
                "PVE_INTERNET_BRIDGE",
                self.cfg.pve_internet_bridge,
                "Internet bridge must use letters, digits, dots, underscores, or hyphens.",
                proxmox_name_ok,
            ),
            "hv-token-id": (
                "PVE_TOKEN_ID",
                self.cfg.pve_token_id,
                "Token id must look like user@realm!token.",
                proxmox_token_ok,
            ),
        }[field_id]
        widget = self.query_one(f"#{field_id}", Input)
        value = widget.value.strip()
        if value == current:
            return True
        if not accept(value):
            self.notify(invalid, severity="warning")
            widget.value = current
            return False
        updates[key] = value
        return True

    def _save_fingerprint(self, updates: dict[str, str]) -> bool:
        widget = self.query_one("#hv-fingerprint", Input)
        raw = widget.value.strip()
        current = self.cfg.pve_tls_fingerprint
        if raw == "":
            if current == "":
                return True
            updates["PVE_TLS_FINGERPRINT"] = ""
            return True
        value = normalize_fingerprint(raw)
        if value is None:
            self.notify("TLS fingerprint must be a SHA256 hex string.", severity="warning")
            widget.value = current
            return False
        widget.value = value
        if value == current:
            return True
        updates["PVE_TLS_FINGERPRINT"] = value
        return True

    def _save_field(self, field_id: str) -> bool:
        if field_id not in _GENERAL and not field_id.startswith("hv-"):
            return True
        if field_id.startswith("hv-") and field_id not in {
            "hv-vm-dir",
            "hv-ga-iso",
            "hv-api-host",
            "hv-fingerprint",
            "hv-node",
            "hv-import-storage",
            "hv-storage",
            "hv-bridge",
            "hv-internet-bridge",
            "hv-token-id",
            "hv-token-secret",
            "hv-ssh-user",
            "hv-ssh-host",
            "hv-ssh-port",
            "hv-ssh-identity",
            "hv-virtio-iso",
            "hv-uri",
        }:
            return True
        updates: dict[str, str] = {}
        if field_id == "kit":
            kit = self.query_one("#kit", Input).value.strip()
            if kit == str(self.cfg.lab_zip_path):
                return True
            if not kit.lower().endswith(".zip"):
                self.notify("Choose a .zip file.", severity="warning")
                self.query_one("#kit", Input).value = str(self.cfg.lab_zip_path)
                return False
            updates["LAB_ZIP_PATH"] = kit
        elif field_id == "work":
            work = self.query_one("#work", Input).value.strip()
            if work == str(self.cfg.work_dir):
                return True
            if self._outside_checkout(work):
                self.notify("Choose a work directory outside the git checkout.", severity="warning")
                self.query_one("#work", Input).value = str(self.cfg.work_dir)
                return False
            updates["LAB_WORK_DIR"] = work
            updates["SOURCE_DIR"] = str(Path(work) / "source")
            updates["TMP_DIR"] = str(Path(work) / "tmp")
        elif field_id == "hv-vm-dir":
            vm_dir = self.query_one("#hv-vm-dir", Input).value.strip()
            if vm_dir == str(self.cfg.vm_root):
                return True
            if self._outside_checkout(vm_dir):
                self.notify("Choose a VM directory outside the git checkout.", severity="warning")
                self.query_one("#hv-vm-dir", Input).value = str(self.cfg.vm_root)
                return False
            updates["VM_ROOT"] = vm_dir
        elif field_id == "hv-ga-iso":
            iso = self.query_one("#hv-ga-iso", Input).value.strip()
            if iso == self.cfg.guest_additions_iso:
                return True
            if not iso.lower().endswith(".iso"):
                self.notify("Choose a Guest Additions .iso file.", severity="warning")
                self.query_one("#hv-ga-iso", Input).value = self.cfg.guest_additions_iso
                return False
            updates["VBOX_GUEST_ADDITIONS_ISO"] = iso
        elif field_id == "hv-uri":
            uri = self.query_one("#hv-uri", Input).value.strip() or "qemu:///system"
            if uri == self.cfg.libvirt_uri:
                return True
            if not uri.startswith("qemu://"):
                self.notify("URI must start with qemu://", severity="warning")
                self.query_one("#hv-uri", Input).value = self.cfg.libvirt_uri
                return False
            updates["LIBVIRT_URI"] = uri
        elif field_id in {"hv-ssh-user", "hv-ssh-host", "hv-ssh-port", "hv-ssh-identity", "hv-virtio-iso"}:
            if not self._save_ssh(field_id, updates):
                return False
        elif field_id == "hv-token-secret":
            secret = self.query_one("#hv-token-secret", Input).value
            if secret == "":
                return True
            if not proxmox_secret_ok(secret):
                self.notify("The token secret cannot include spaces, quotes, or control characters.", severity="warning")
                self.query_one("#hv-token-secret", Input).value = ""
                return False
            updates["PVE_TOKEN_SECRET"] = secret
        elif field_id == "hv-fingerprint":
            if not self._save_fingerprint(updates):
                return False
        elif field_id in {
            "hv-api-host",
            "hv-node",
            "hv-import-storage",
            "hv-storage",
            "hv-bridge",
            "hv-internet-bridge",
            "hv-token-id",
        }:
            if not self._save_proxmox_text(field_id, updates):
                return False
            if not updates:
                return True
        else:
            return True
        if not updates:
            return True
        try:
            write_keys(self.cfg.env_file, self.cfg.root / "config" / "lab.env.example", updates)
        except OSError:
            self.notify("Could not save that setting.", severity="error")
            return False
        self.cfg = load_config(self.cfg.root)
        if field_id == "hv-token-secret":
            self.query_one("#hv-token-secret", Input).value = ""
        self.refresh_stages()
        return True

    def _save_ssh(self, field_id: str, updates: dict[str, str]) -> bool:
        key, current, invalid, accept = {
            "hv-ssh-user": (
                "PVE_SSH_USER",
                self.cfg.pve_ssh_user,
                "SSH user must be a plain account name.",
                proxmox_ssh_user_ok,
            ),
            "hv-ssh-host": (
                "PVE_SSH_HOST",
                self.cfg.pve_ssh_host,
                "SSH host must be a hostname or address. Leave it blank to use the API host.",
                proxmox_ssh_host_ok,
            ),
            "hv-ssh-port": (
                "PVE_SSH_PORT",
                self.cfg.pve_ssh_port,
                "SSH port must be a number from 1 to 65535.",
                proxmox_ssh_port_ok,
            ),
            "hv-ssh-identity": (
                "PVE_SSH_IDENTITY",
                self.cfg.pve_ssh_identity,
                "SSH identity must be a key file, or blank to use the default key.",
                proxmox_ssh_identity_ok,
            ),
            "hv-virtio-iso": (
                "LIBVIRT_VIRTIO_ISO" if self.cfg.hypervisor == "libvirt" else "PVE_VIRTIO_ISO",
                self.cfg.libvirt_virtio_iso if self.cfg.hypervisor == "libvirt" else self.cfg.pve_virtio_iso,
                "Virtio ISO must be a .iso file on this machine.",
                proxmox_virtio_iso_ok,
            ),
        }[field_id]
        widget = self.query_one(f"#{field_id}", Input)
        value = widget.value.strip()
        if value == current:
            return True
        if not accept(value):
            self.notify(invalid, severity="warning")
            widget.value = current
            return False
        updates[key] = value
        return True

    def _commit_form(self) -> bool:
        saved = True
        fields = list(_GENERAL)
        if self.cfg.hypervisor == "virtualbox":
            fields.extend(("hv-vm-dir", "hv-ga-iso"))
        elif self.cfg.hypervisor == "libvirt":
            fields.extend(("hv-uri", "hv-vm-dir", "hv-virtio-iso"))
        elif self.cfg.hypervisor == "proxmox":
            fields.extend((
                "hv-api-host",
                "hv-fingerprint",
                "hv-node",
                "hv-import-storage",
                "hv-storage",
                "hv-bridge",
                "hv-internet-bridge",
                "hv-token-id",
                "hv-token-secret",
                "hv-ssh-user",
                "hv-ssh-host",
                "hv-ssh-port",
                "hv-ssh-identity",
                "hv-virtio-iso",
            ))
        for field_id in fields:
            if not self._save_field(field_id):
                saved = False
        return saved

    def on_input_blurred(self, event: Input.Blurred) -> None:
        if self._busy or not event.input.id:
            return
        self._save_field(event.input.id)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if isinstance(self.screen, SudoPrompt) or self._busy or not event.input.id:
            return
        self._save_field(event.input.id)

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        if self._busy or event.checkbox.id not in {"parallel", "hv-keep-imports"}:
            return
        enabled = bool(event.value)
        if event.checkbox.id == "parallel":
            if enabled == self.cfg.parallel:
                return
            self.cfg.parallel = enabled
            updates = {"LAB_PARALLEL": "1" if enabled else "0"}
        else:
            if enabled == self.cfg.pve_keep_imports:
                return
            self.cfg.pve_keep_imports = enabled
            updates = {"PVE_KEEP_IMPORTS": "1" if enabled else "0"}
        try:
            write_keys(self.cfg.env_file, self.cfg.root / "config" / "lab.env.example", updates)
        except OSError:
            self.notify("Could not save that setting.", severity="error")

    async def _show_hypervisor(self, name: str) -> None:
        if self._busy or name == self.cfg.hypervisor:
            return
        try:
            write_keys(self.cfg.env_file, self.cfg.root / "config" / "lab.env.example", {"HYPERVISOR": name})
        except OSError:
            self.notify("Could not save that setting.", severity="error")
            return
        self.cfg = load_config(self.cfg.root)
        box = self.query_one("#hv-settings", Vertical)
        box.border_title = _hypervisor_title(self.cfg.hypervisor)
        fields = self.query_one("#hv-fields", Vertical)
        await fields.remove_children()
        await fields.mount(*self._hv_mount_widgets())
        self._sync_actions()

    def _ssh_login(self) -> tuple[str, str, str] | None:
        host = self.cfg.pve_ssh_host.strip()
        if not host and self.cfg.pve_api_host:
            host = self.cfg.pve_api_host.split(":", 1)[0]
        if not proxmox_ssh_user_ok(self.cfg.pve_ssh_user):
            return None
        if not host or not proxmox_ssh_host_ok(host) or not proxmox_ssh_port_ok(self.cfg.pve_ssh_port):
            return None
        return self.cfg.pve_ssh_user, host, self.cfg.pve_ssh_port

    def _ask_for_ssh(self) -> SshSession | None:
        """Ask once, before the first stage, and keep the password for this run."""
        done = threading.Event()
        holder: dict[str, SshSession | None] = {"session": None}

        def open_dialog() -> None:
            prompt = SshPrompt(self._ssh_login())

            def finished(ok: bool | None) -> None:
                holder["session"] = prompt.session if ok else None
                done.set()

            self.push_screen(prompt, finished)

        self.call_from_thread(open_dialog)
        done.wait()
        return holder["session"]

    def _ask_for_mount_helper(self) -> MountHelper | None:
        """Ask once, before the run, and keep the helper for every mount."""
        script = self.cfg.root / "scripts" / "lib" / "offline-disk.sh"
        if not script.is_file():
            self.call_from_thread(self._write, "The disk-mount helper is missing.")
            return None
        done = threading.Event()
        holder: dict[str, MountHelper | None] = {"helper": None}

        def open_dialog() -> None:
            prompt = SudoPrompt(script)

            def finished(ok: bool | None) -> None:
                holder["helper"] = prompt.helper if ok else None
                done.set()

            self.push_screen(prompt, finished)

        self.call_from_thread(open_dialog)
        done.wait()
        return holder["helper"]

    def _start(self, jobs: list[tuple[Stage, list[str]]]) -> None:
        if self._busy:
            return
        self._busy = True
        self._cancel.clear()
        self._sync_actions()
        self.run_worker(lambda: self._execute(jobs), thread=True, exclusive=True)

    def _execute(self, jobs: list[tuple[Stage, list[str]]]) -> None:
        helper: MountHelper | None = None
        ssh: SshSession | None = None
        try:
            if self.cfg.hypervisor == "proxmox" and any(stage.number >= 1 for stage, _args in jobs):
                ssh = self._ask_for_ssh()
                if ssh is None:
                    if not self._cancel.is_set():
                        self.call_from_thread(
                            self._write,
                            "The SSH password was not entered. Nothing was started.",
                        )
                    return
            if any(stage_needs_sudo(stage, self.cfg.hypervisor) for stage, _args in jobs):
                helper = self._ask_for_mount_helper()
                if helper is None:
                    if not self._cancel.is_set():
                        self.call_from_thread(
                            self._write,
                            "sudo did not accept the password. Nothing was started.",
                        )
                    return
            for stage, args in jobs:
                if self._cancel.is_set():
                    break
                self.call_from_thread(self._mark_running, stage.number)
                script = self.cfg.root / "scripts" / f"{stage.script}.sh"
                extra: dict[str, str] = {}
                if helper is not None:
                    extra.update(helper.env)
                if ssh is not None:
                    extra.update(ssh.env)
                rc = run_script(
                    self.cfg,
                    script,
                    args,
                    self._from_stage,
                    self._cancel.is_set,
                    extra or None,
                )
                if stage.number == 0:
                    ok = "Lab reset. Stages will run again from the start."
                    bad = f"Reset failed (exit {rc})."
                    stopped = "Reset interrupted."
                else:
                    ok = f"Stage {stage.number} finished — {stage.title}."
                    bad = f"Stage {stage.number} failed (exit {rc}) — {stage.title}."
                    stopped = f"Stage {stage.number} interrupted."
                if rc == 0:
                    self.call_from_thread(self._write, ok)
                elif rc == 130:
                    self.call_from_thread(self._write, stopped)
                    break
                else:
                    self.call_from_thread(self._write, bad)
                    break
        finally:
            if ssh is not None:
                ssh.stop()
            if helper is not None:
                helper.stop()
            self.call_from_thread(self._finish)

    def _mark_running(self, number: int) -> None:
        self._busy_stage = number
        self._live_pct = None
        self.refresh_stages()

    def _finish(self) -> None:
        self._busy = False
        self._busy_stage = None
        self._live_pct = None
        self.refresh_stages()

    def action_run_next(self) -> None:
        if self._busy or not self._commit_form():
            return
        stage = next_stage(self.cfg)
        if stage is None:
            self._write("Every stage has already finished.")
            return
        reason = stage.block_reason(self.cfg)
        if reason:
            self._write(reason)
            return
        blocked = virtio_iso_block(self.cfg) or self._proxmox_block([(stage, [])])
        if blocked:
            self._write(blocked)
            return
        self._write(f"Starting stage {stage.number} — {stage.title}")
        if stage.number == 3:
            self._write("Stage 3 boots the gateway briefly, then powers it off.")
        self._start([(stage, stage_args(stage, self.forward, skip_smoke=False, parallel=self.cfg.parallel))])

    def action_run_all(self) -> None:
        if self._busy or not self._commit_form():
            return
        chosen, blocked = stages_to_run(self.cfg)
        if blocked:
            self._write(blocked)
            return
        if not chosen:
            self._write("Run all finished.")
            return
        blocked_settings = virtio_iso_block(self.cfg) or self._proxmox_block([(stage, []) for stage in chosen])
        if blocked_settings:
            self._write(blocked_settings)
            return
        chosen_numbers = {stage.number for stage in chosen}
        for stage in STAGES:
            if stage.number not in chosen_numbers:
                self._write(f"Stage {stage.number} already done — skipped.")
        jobs = [(stage, stage_args(stage, self.forward, skip_smoke=True, parallel=self.cfg.parallel)) for stage in chosen]
        if any(stage.number == 3 for stage, _args in jobs):
            self._write("Stage 3 will not boot a VM. Stage 5 starts the lab.")
        self._start(jobs)

    def _proxmox_block(self, jobs: list[tuple[Stage, list[str]]]) -> str:
        if self.cfg.hypervisor != "proxmox":
            return ""
        if not any(stage.number >= 3 for stage, _args in jobs):
            return ""
        missing = missing_proxmox_settings(self.cfg)
        if not missing:
            return ""
        return "Set the Proxmox " + ", ".join(missing) + " before this stage."

    def action_reset(self) -> None:
        if self._busy:
            return

        def go(confirmed: bool | None) -> None:
            if not confirmed:
                self._write("Reset cancelled.")
                return
            self._write("Resetting the lab.")
            self._start([(
                Stage(0, "cleanup-lab", "Reset", "", None, ()),
                ["--reset", "--yes"],
            )])

        self.push_screen(ConfirmReset(), go)

    def action_cancel(self) -> None:
        if self._busy:
            self._cancel.set()
            self._write("Interrupt requested.")
            if isinstance(self.screen, (SudoPrompt, SshPrompt)):
                self.screen.dismiss(False)

    async def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id or ""
        if button_id == "test-connection":
            event.stop()
            self.action_test_connection()
            return
        if button_id.startswith("platform-"):
            event.stop()
            await self._show_hypervisor(button_id.removeprefix("platform-"))
            return
        action = {
            "run-all": self.action_run_all,
            "run-next": self.action_run_next,
            "reset": self.action_reset,
            "quit": self.action_quit,
        }.get(button_id)
        if action is None:
            return
        event.stop()
        action()

    def action_test_connection(self) -> None:
        if self._busy:
            return
        if not self._commit_form():
            return
        if self.cfg.hypervisor == "proxmox":
            missing = missing_proxmox_settings(self.cfg)
            if missing:
                self.notify(
                    "Set the Proxmox " + ", ".join(missing) + " before this check.",
                    severity="warning",
                )
                return
        script = self.cfg.root / "scripts" / "hypervisors" / self.cfg.hypervisor / "test-connection.sh"
        if not script.is_file():
            self.notify("This platform has no connection check.", severity="warning")
            return
        if self.cfg.hypervisor == "proxmox":
            prompt = SshPrompt(self._ssh_login())

            def finished(ok: bool | None) -> None:
                if not ok or prompt.session is None:
                    self._write("The SSH password was not entered. The connection was not checked.")
                    return
                self._begin_connection_check(script, prompt.session)

            self.push_screen(prompt, finished)
            return
        self._begin_connection_check(script, None)

    def _begin_connection_check(self, script: Path, ssh: SshSession | None) -> None:
        self._busy = True
        self._cancel.clear()
        self._sync_actions()
        self._write("Checking the connection.")
        self.run_worker(lambda: self._test_connection(script, ssh), thread=True, exclusive=True)

    def _test_connection(self, script: Path, ssh: SshSession | None = None) -> None:
        ok = False
        try:
            rc = run_script(
                self.cfg,
                script,
                [],
                self._from_stage,
                self._cancel.is_set,
                ssh.env if ssh is not None else None,
            )
            ok = rc == 0 and not self._cancel.is_set()
            if ok:
                self.call_from_thread(self._write, "Connection ok.")
            elif self._cancel.is_set():
                self.call_from_thread(self._write, "Connection check interrupted.")
            else:
                self.call_from_thread(self._write, f"Connection check failed (exit {rc}).")
        finally:
            if ssh is not None:
                ssh.stop()
            self.call_from_thread(self._finish_test, ok)

    def _finish_test(self, ok: bool) -> None:
        self._busy = False
        self._sync_actions()
        if ok:
            self.notify("Connection ok.")
        elif self._cancel.is_set():
            self.notify("Connection check interrupted.", severity="warning")
        else:
            self.notify("Connection check failed.", severity="error")

    def action_quit(self) -> None:
        if self._busy:
            self.action_cancel()
            return
        self.exit(0)
