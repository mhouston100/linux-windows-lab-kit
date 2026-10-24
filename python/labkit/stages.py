"""Stage list shared by the menu and the command-line runner."""

from __future__ import annotations

import re
from dataclasses import dataclass

from labkit.config import LabConfig

_PERCENT = re.compile(r"([0-9]{1,3})(?:\.[0-9]+)?%")


@dataclass(frozen=True)
class Stage:
    number: int
    script: str
    title: str
    checkpoint: str
    requires: str | None
    markers: tuple[str, ...]
    needs_sudo: bool = False

    def block_reason(self, config: LabConfig) -> str:
        if self.requires and not marker_present(config, self.requires):
            return f"{self.title} is blocked. Finish the stage it depends on first."
        return ""


STAGES: tuple[Stage, ...] = (
    Stage(1, "phase1", "Extract and organize", "phase1.ok", None,
          ("zip.done", "zpaq.done", "setup.done", "organize.done", "phase1.ok")),
    Stage(2, "phase2", "Convert disks", "phase2.ok", "phase1.ok",
          ("convert.done", "phase2.ok")),
    Stage(3, "phase3", "Create VMs", "phase3.ok", "phase2.ok",
          ("create-vms.done", "phase3.ok"), needs_sudo=True),
    Stage(4, "phase4", "Identity templates", "phase4.ok", "phase3.ok",
          ("identity.done", "phase4.ok")),
    Stage(5, "phase5", "Start and stop the lab", "phase5.ok", "phase4.ok",
          ("lab-started.done", "lab-health.ok", "lab-stopped.done", "phase5.ok"),
          needs_sudo=True),
    Stage(6, "phase6", "Cleanup safety check", "phase6.ok", "phase3.ok",
          ("phase6.ok",)),
)


def stage_needs_sudo(stage: Stage, hypervisor: str) -> bool:
    """True when the stage mounts a guest disk on this machine.

    VirtualBox mounts the disks in stages 3 and 5. Proxmox plants the guest
    agent while it creates the guests, so only stage 3 mounts anything.
    """
    if hypervisor == "proxmox":
        return stage.number == 3
    return stage.needs_sudo


def stages_to_run(config: LabConfig) -> tuple[list[Stage], str]:
    """Stages Run all should start, in order.

    A later stage that is only waiting on an earlier one is included.
    The message is set when the first remaining stage cannot start.
    """
    chosen: list[Stage] = []
    for stage in STAGES:
        if stage_state(config, stage) == "done":
            continue
        reason = stage.block_reason(config)
        if reason and not chosen:
            return [], reason
        chosen.append(stage)
    return chosen, ""


def next_stage(config: LabConfig) -> Stage | None:
    """The first stage that has not finished. Stage 1 when nothing has run."""
    for stage in STAGES:
        if stage_state(config, stage) != "done":
            return stage
    return None


def stage_by_number(number: int) -> Stage:
    for stage in STAGES:
        if stage.number == number:
            return stage
    raise KeyError(number)


def marker_present(config: LabConfig, name: str) -> bool:
    return (config.markers_dir / name).is_file()


def stage_state(config: LabConfig, stage: Stage, running: int | None = None) -> str:
    if marker_present(config, stage.checkpoint):
        return "done"
    if running == stage.number:
        return "running"
    if stage.block_reason(config):
        return "blocked"
    return "ready"


def stage_percent(config: LabConfig, stage: Stage, running: int | None = None, live: int | None = None) -> int:
    state = stage_state(config, stage, running)
    if state == "done":
        return 100
    if state == "blocked":
        return 0
    have = sum(1 for name in stage.markers if marker_present(config, name))
    total = len(stage.markers) or 1
    percent = have * 100 // total
    if running == stage.number and live is not None and live > percent:
        percent = live
    if running == stage.number and percent == 0:
        percent = 3
    if running == stage.number and percent >= 100:
        percent = 99
    return percent


def note_progress(line: str) -> int | None:
    match = _PERCENT.search(line)
    if not match:
        return None
    value = int(match.group(1))
    return 100 if value > 100 else value
