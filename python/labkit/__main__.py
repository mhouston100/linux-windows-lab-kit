"""Command line for the lab kit menu and for running stages without the screen."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from labkit.config import LabConfig, load_config
from labkit.runner import run_script, stage_args
from labkit.stages import STAGES, marker_present, stage_by_number, stages_to_run

ROOT = Path(__file__).resolve().parents[2]


def _print_status(config: LabConfig) -> int:
    """The marker checklist stays in Bash. This only launches it."""
    env = os.environ.copy()
    env["LAB_CLI_KIT"] = str(config.lab_zip_path)
    env["LAB_CLI_DEST"] = str(config.vm_root)
    env["LAB_NONINTERACTIVE"] = "1"
    env["LAB_LOG_CAPTURE"] = "1"
    script = """
set -euo pipefail
source scripts/lib/config.sh
source scripts/lib/status.sh
load_config 0
print_checklist
lab_count_tasks
if [[ "$LAB_TODO_N" -eq 0 ]]; then
  printf 'status: ok (exit 0) — nothing outstanding\\n'
  exit 0
fi
printf 'status: incomplete (exit 1) — %s outstanding\\n' "$LAB_TODO_N" >&2
exit 1
"""
    result = subprocess.run(["bash", "-c", script], cwd=config.root, env=env, check=False)
    return result.returncode


def _run_blocking(config: LabConfig, jobs: list, forward: list[str]) -> int:
    def on_line(line: str) -> None:
        print(line, flush=True)

    for stage, args in jobs:
        print(f"Starting stage {stage.number} — {stage.title}", flush=True)
        script = config.root / "scripts" / f"{stage.script}.sh"
        rc = run_script(config, script, args, on_line, lambda: False)
        if rc != 0:
            print(f"status: failed (exit {rc})", file=sys.stderr)
            return rc
    return 0


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    kit: str | None = None
    dest: str | None = None
    forward: list[str] = []
    command = ""
    index = 0
    while index < len(args):
        item = args[index]
        if item in {"--kit", "--source"} and index + 1 < len(args):
            kit = args[index + 1]
            index += 2
            continue
        if item in {"--dest", "--destination"} and index + 1 < len(args):
            dest = args[index + 1]
            index += 2
            continue
        if item in {"-h", "--help"}:
            print(
                "Usage: lab.sh [--kit ZIP] [--dest DIR] [menu|status|phase1|...|phase6|all]\n"
                "The menu is the Textual screen. Stages still run the Bash scripts."
            )
            return 0
        if item in {"menu", "status", "all"} or (item.startswith("phase") and item[5:].isdigit()):
            command = item
        else:
            forward.append(item)
        index += 1

    config = load_config(ROOT, kit=kit, dest=dest)
    if not command:
        command = "menu" if sys.stdin.isatty() and sys.stdout.isatty() else "status"

    if command == "status":
        return _print_status(config)
    if command == "menu":
        try:
            from labkit.app import LabApp
        except ImportError:
            print(
                "The menu needs Textual. From the repo root:\n"
                "  python3 -m venv .venv && .venv/bin/pip install -r requirements.txt",
                file=sys.stderr,
            )
            return 1
        app = LabApp(config, forward)
        app.run()
        return 0
    if command == "all":
        chosen, blocked = stages_to_run(config)
        if blocked:
            print(blocked, file=sys.stderr)
            return 1
        chosen_numbers = {stage.number for stage in chosen}
        for stage in STAGES:
            if stage.number not in chosen_numbers:
                print(f"Stage {stage.number} already done — skipped.")
        if not chosen:
            print("Run all finished.")
            return 0
        jobs = [(stage, stage_args(stage, forward, skip_smoke=True, parallel=config.parallel)) for stage in chosen]
        rc = _run_blocking(config, jobs, forward)
        if rc == 0 and all(marker_present(config, stage.checkpoint) for stage in STAGES):
            print("status: ok (exit 0)")
        return rc
    number = int(command.removeprefix("phase"))
    stage = stage_by_number(number)
    reason = stage.block_reason(config)
    if reason:
        print(reason, file=sys.stderr)
        return 1
    return _run_blocking(config, [(stage, stage_args(stage, forward, skip_smoke=False, parallel=config.parallel))], forward)


if __name__ == "__main__":
    raise SystemExit(main())
