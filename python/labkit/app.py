"""Textual menu. Bash still runs each stage."""

from __future__ import annotations

import threading
from datetime import datetime
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, HorizontalScroll, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Checkbox, Header, Input, Label, ProgressBar, RichLog, Static

from labkit.config import (
    HypervisorField,
    LabConfig,
    hypervisor_fields,
    load_config,
    ordered_hypervisors,
    write_keys,
)
from labkit.runner import run_script, stage_args
from labkit.stages import STAGES, Stage, next_stage, note_progress, stage_percent, stage_state, stages_to_run
from labkit.sudo_auth import MountHelper, start_mount_helper

_NAME = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
_GENERAL = ("kit", "work", "domain", "user", "password")


def _platform_label(name: str) -> str:
    if name == "virtualbox":
        return "VirtualBox"
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
                "Enter the administrator password once. "
                "The rest of this run will not ask again. "
                "It is not stored, and it is not the lab account password."
            ),
            Input(placeholder="Password", password=True, id="sudo-password"),
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
            self.notify("Enter the administrator password.", severity="warning")
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
            self.notify("Password was not accepted.", severity="error")
            field.focus()
            return
        self.helper = helper
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
    #parallel { height: 1; width: auto; margin: 0; }
    #stages { height: auto; }
    .stage { height: 1; }
    .stage Label { width: 26; }
    .meta { width: 16; }
    ProgressBar { width: 1fr; }
    #actions { height: 3; }
    #actions Button { margin-right: 1; }
    Screen { overflow-y: auto; }
    #log { height: 1fr; min-height: 5; }
    #confirm, #sudo-form { padding: 1 2; width: 80; height: auto; border: round $accent; background: $surface; }
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
                yield from self._hypervisor_rows(hypervisor_fields(self.cfg.hypervisor, str(self.cfg.vm_root)))
            with Vertical(id="lab-settings", classes="panel"):
                yield from self._general_row("Kit ZIP", str(self.cfg.lab_zip_path), "kit")
                yield from self._general_row("Work directory", str(self.cfg.work_dir), "work")
                yield from self._general_row("Domain", self.cfg.lab_domain, "domain")
                yield from self._general_row("Account", self.cfg.lab_admin_user, "user")
                yield from self._general_row("Password", "", "password", password=True)
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

    @staticmethod
    def _general_row(label: str, value: str, field_id: str, password: bool = False) -> ComposeResult:
        placeholder = "Leave blank to keep the current password" if password else ""
        yield Horizontal(
            Label(label),
            Input(value=value, id=field_id, password=password, placeholder=placeholder),
            classes="setting",
        )

    @staticmethod
    def _hypervisor_rows(fields: list[HypervisorField]) -> ComposeResult:
        if not fields:
            yield Static("No extra settings for this platform.")
            return
        for field in fields:
            yield Horizontal(
                Label(field.label),
                Input(
                    value=field.value,
                    id=f"hv-{field.key}",
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
        for button_id in ("run-all", "run-next", "reset"):
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

    def _save_field(self, field_id: str) -> bool:
        if field_id not in _GENERAL and field_id != "hv-vm-dir":
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
        elif field_id in {"domain", "user"}:
            value = self.query_one(f"#{field_id}", Input).value.strip()
            current = self.cfg.lab_domain if field_id == "domain" else self.cfg.lab_admin_user
            label = "Domain" if field_id == "domain" else "Account"
            if value == current:
                return True
            if not value or any(ch not in _NAME for ch in value):
                self.notify(f"{label} must use letters, digits, dots, underscores, or hyphens.", severity="warning")
                self.query_one(f"#{field_id}", Input).value = current
                return False
            updates["LAB_DOMAIN" if field_id == "domain" else "LAB_ADMIN_USER"] = value
        else:
            password = self.query_one("#password", Input).value
            if password == "":
                return True
            updates["LAB_ADMIN_PASSWORD"] = password
        try:
            write_keys(self.cfg.env_file, self.cfg.root / "config" / "lab.env.example", updates)
        except OSError:
            self.notify("Could not save that setting.", severity="error")
            return False
        self.cfg = load_config(self.cfg.root)
        if field_id == "password":
            self.query_one("#password", Input).value = ""
        self.refresh_stages()
        return True

    def _commit_form(self) -> bool:
        saved = True
        fields = list(_GENERAL)
        if self.cfg.hypervisor == "virtualbox":
            fields.append("hv-vm-dir")
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
        if event.checkbox.id != "parallel" or self._busy:
            return
        enabled = bool(event.value)
        if enabled == self.cfg.parallel:
            return
        self.cfg.parallel = enabled
        try:
            write_keys(
                self.cfg.env_file,
                self.cfg.root / "config" / "lab.env.example",
                {"LAB_PARALLEL": "1" if self.cfg.parallel else "0"},
            )
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
        await box.remove_children()
        await box.mount(*list(self._hypervisor_rows(hypervisor_fields(self.cfg.hypervisor, str(self.cfg.vm_root)))))
        self._sync_actions()

    def _ask_for_mount_helper(self) -> MountHelper | None:
        """Ask once, before the run, and keep the helper for every mount."""
        script = self.cfg.root / "scripts" / "hypervisors" / self.cfg.hypervisor / "guest-additions.sh"
        if not script.is_file():
            self.call_from_thread(self._write, "This platform has no disk-mount helper.")
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
        try:
            if any(stage.needs_sudo for stage, _args in jobs):
                helper = self._ask_for_mount_helper()
                if helper is None:
                    if not self._cancel.is_set():
                        self.call_from_thread(
                            self._write,
                            "The administrator password was not accepted. Nothing was started.",
                        )
                    return
            for stage, args in jobs:
                if self._cancel.is_set():
                    break
                self.call_from_thread(self._mark_running, stage.number)
                script = self.cfg.root / "scripts" / f"{stage.script}.sh"
                rc = run_script(
                    self.cfg,
                    script,
                    args,
                    self._from_stage,
                    self._cancel.is_set,
                    helper.env if helper is not None else None,
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
        chosen_numbers = {stage.number for stage in chosen}
        for stage in STAGES:
            if stage.number not in chosen_numbers:
                self._write(f"Stage {stage.number} already done — skipped.")
        jobs = [(stage, stage_args(stage, self.forward, skip_smoke=True, parallel=self.cfg.parallel)) for stage in chosen]
        if any(stage.number == 3 for stage, _args in jobs):
            self._write("Stage 3 will not boot a VM. Stage 5 starts the lab.")
        self._start(jobs)

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
            if isinstance(self.screen, SudoPrompt):
                self.screen.dismiss(False)

    async def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id or ""
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

    def action_quit(self) -> None:
        if self._busy:
            self.action_cancel()
            return
        self.exit(0)
