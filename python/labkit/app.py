"""Textual menu. Bash still runs each stage."""

from __future__ import annotations

import threading
from datetime import datetime
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, HorizontalScroll, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Checkbox, Header, Input, Label, ProgressBar, RichLog, Select, Static

from labkit.config import LabConfig, hypervisors, write_keys
from labkit.runner import run_script, stage_args
from labkit.stages import STAGES, Stage, note_progress, stage_percent, stage_state, stages_to_run
from labkit.sudo_auth import MountHelper, start_mount_helper


def _summary(config: LabConfig) -> str:
    return "\n".join(config.summary_lines())


def _stage_label(stage: Stage) -> str:
    short = stage.title.split()[0]
    return f"{stage.number} {short}"


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


class SettingsScreen(ModalScreen[LabConfig | None]):
    def __init__(self, config: LabConfig) -> None:
        super().__init__()
        self.config = config

    def compose(self) -> ComposeResult:
        names = hypervisors(self.config.root) or [self.config.hypervisor]
        options = [(name, name) for name in names]
        yield Vertical(
            Static("Settings are written to config/lab.env. A blank password keeps the current one."),
            Label("Kit ZIP"),
            Input(value=str(self.config.lab_zip_path), id="kit"),
            Label("Destination"),
            Input(value=str(self.config.vm_root), id="dest"),
            Label("Domain"),
            Input(value=self.config.lab_domain, id="domain"),
            Label("Account"),
            Input(value=self.config.lab_admin_user, id="user"),
            Label("Password"),
            Input(placeholder="Leave blank to keep the current password", password=True, id="password"),
            Label("Platform"),
            Select(options, value=self.config.hypervisor if self.config.hypervisor in names else names[0], allow_blank=False, id="platform"),
            Horizontal(
                Button("Save", id="save", variant="primary"),
                Button("Cancel", id="cancel"),
            ),
            id="settings-form",
        )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.dismiss(None)
            return
        kit = self.query_one("#kit", Input).value.strip()
        dest = self.query_one("#dest", Input).value.strip()
        domain = self.query_one("#domain", Input).value.strip()
        user = self.query_one("#user", Input).value.strip()
        password = self.query_one("#password", Input).value
        platform = self.query_one("#platform", Select).value
        if not kit.lower().endswith(".zip"):
            self.notify("Choose a .zip file.", severity="warning")
            return
        if not dest or dest in {"/", str(self.config.root)}:
            self.notify("Choose a destination outside the git checkout.", severity="warning")
            return
        for label, value in (("Domain", domain), ("Account", user)):
            if not value or any(ch not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" for ch in value):
                self.notify(f"{label} must use letters, digits, dots, underscores, or hyphens.", severity="warning")
                return
        if not isinstance(platform, str):
            self.notify("Choose a platform.", severity="warning")
            return
        updates = {
            "LAB_ZIP_PATH": kit,
            "VM_ROOT": dest,
            "SOURCE_DIR": str(self._path(dest) / "source"),
            "TMP_DIR": str(self._path(dest) / "tmp"),
            "LAB_DOMAIN": domain,
            "LAB_ADMIN_USER": user,
            "HYPERVISOR": platform,
        }
        if password:
            updates["LAB_ADMIN_PASSWORD"] = password
        write_keys(self.config.env_file, self.config.root / "config" / "lab.env.example", updates)
        from labkit.config import load_config

        self.dismiss(load_config(self.config.root, kit=kit, dest=dest))

    @staticmethod
    def _path(dest: str):
        from pathlib import Path

        return Path(dest)


class LabApp(App[int]):
    TITLE = "Linux Windows Lab Kit"
    CSS = """
    #summary { height: auto; max-height: 6; border: round $accent; padding: 0 1; margin-bottom: 1; }
    #stages { height: auto; margin-bottom: 1; }
    .stage { height: 1; }
    .stage Label { width: 26; }
    .meta { width: 16; }
    ProgressBar { width: 1fr; }
    #parallel { width: auto; height: 3; margin: 0 1 1 1; }
    #actions { height: 3; margin-bottom: 1; }
    #actions Button { margin-right: 1; }
    #log { height: 1fr; border: round $primary; }
    #confirm, #settings-form, #sudo-form { padding: 1 2; width: 80; height: auto; border: round $accent; background: $surface; }
    #settings-form { width: 88; }
    """
    BINDINGS = [
        Binding("a", "run_all", "Run all", show=False),
        Binding("s", "settings", "Settings", show=False),
        Binding("c", "reset", "Reset", show=False),
        Binding("q", "quit", "Quit", show=False),
        Binding("ctrl+c", "cancel", "Stop", show=False),
        *[Binding(str(number), f"stage({number})", show=False) for number in range(1, 7)],
    ]

    def __init__(self, config: LabConfig, forward: list[str]) -> None:
        super().__init__()
        self.cfg = config
        self.forward = forward
        self._busy = False
        self._busy_stage: int | None = None
        self._live_pct: int | None = None
        self._cancel = threading.Event()
        self._frozen_summary = ""

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static(_summary(self.cfg), id="summary")
        with Vertical(id="stages"):
            for stage in STAGES:
                with Horizontal(classes="stage"):
                    yield Label(f"{stage.number}  {stage.title}", id=f"label-{stage.number}")
                    yield ProgressBar(total=100, show_eta=False, id=f"bar-{stage.number}")
                    yield Label("", id=f"meta-{stage.number}", classes="meta")
        yield Checkbox("Parallel disks", value=self.cfg.parallel, id="parallel")
        with HorizontalScroll(id="actions"):
            for stage in STAGES:
                yield Button(_stage_label(stage), id=f"stage-{stage.number}")
            yield Button("Run all (a)", id="run-all", variant="primary")
            yield Button("Settings (s)", id="settings")
            yield Button("Reset (c)", id="reset", variant="error")
            yield Button("Quit (q)", id="quit")
        yield RichLog(id="log", highlight=False, markup=False, wrap=True, max_lines=500)

    def on_mount(self) -> None:
        self.refresh_stages()
        self._write("Pick a stage, or use the buttons. The same keys still work.")

    def refresh_stages(self) -> None:
        summary = self.query_one("#summary", Static)
        if self._busy and self._frozen_summary:
            summary.update(self._frozen_summary)
        else:
            summary.update(_summary(self.cfg))
        for stage in STAGES:
            state = stage_state(self.cfg, stage, self._busy_stage)
            percent = stage_percent(self.cfg, stage, self._busy_stage, self._live_pct)
            self.query_one(f"#bar-{stage.number}", ProgressBar).update(progress=percent)
            self.query_one(f"#meta-{stage.number}", Label).update(f"{percent:3d}%  {state}")
        self._sync_actions()

    def _sync_actions(self) -> None:
        for stage in STAGES:
            self.query_one(f"#stage-{stage.number}", Button).disabled = self._busy
        for button_id in ("run-all", "settings", "reset"):
            self.query_one(f"#{button_id}", Button).disabled = self._busy
        self.query_one("#parallel", Checkbox).disabled = self._busy

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
        self._frozen_summary = _summary(self.cfg)
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
        self._frozen_summary = ""
        self.refresh_stages()

    def action_stage(self, number: int) -> None:
        if self._busy:
            return
        stage = next(item for item in STAGES if item.number == number)
        reason = stage.block_reason(self.cfg)
        if reason:
            self._write(reason)
            return
        self._write(f"Starting stage {stage.number} — {stage.title}")
        self._start([(stage, stage_args(stage, self.forward, skip_smoke=False, parallel=self.cfg.parallel))])

    def action_run_all(self) -> None:
        if self._busy:
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

    def action_settings(self) -> None:
        if self._busy:
            return

        def apply(updated: LabConfig | None) -> None:
            if updated is None:
                return
            self.cfg = updated
            self._write("Settings saved.")
            self.refresh_stages()

        self.push_screen(SettingsScreen(self.cfg), apply)

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

    def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id or ""
        if button_id.startswith("stage-"):
            event.stop()
            self.action_stage(int(button_id.removeprefix("stage-")))
            return
        action = {
            "run-all": self.action_run_all,
            "settings": self.action_settings,
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
