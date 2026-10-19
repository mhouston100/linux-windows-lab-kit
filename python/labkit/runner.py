"""Run a Bash stage without letting the screen stall it."""

from __future__ import annotations

import os
import select
import signal
import subprocess
from collections.abc import Callable
from pathlib import Path

from labkit.config import LabConfig
from labkit.stages import Stage

LogFn = Callable[[str], None]


def _children(pid: int) -> list[int]:
    try:
        output = subprocess.check_output(
            ["ps", "-o", "pid=", "--ppid", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    kids: list[int] = []
    for line in output.split():
        if line.isdigit():
            kids.append(int(line))
    return kids


def stop_process(pid: int, sig: int) -> None:
    """Signal the stage session, children first, so a setsid grandchild is included."""
    for child in _children(pid):
        stop_process(child, sig)
    try:
        os.killpg(pid, sig)
    except (ProcessLookupError, PermissionError):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass


def run_script(
    config: LabConfig,
    script: Path,
    args: list[str],
    on_line: LogFn,
    cancel: Callable[[], bool],
    extra_env: dict[str, str] | None = None,
) -> int:
    env = os.environ.copy()
    env["LAB_LOG_CAPTURE"] = "1"
    env.update(config.cli_env())
    if extra_env:
        env.update(extra_env)
    proc = subprocess.Popen(
        ["bash", str(script), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
        bufsize=0,
    )
    assert proc.stdout is not None
    buffer = b""
    rc = 1
    try:
        while True:
            if cancel():
                stop_process(proc.pid, signal.SIGTERM)
                break
            ready, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not ready:
                if proc.poll() is not None:
                    chunk = proc.stdout.read()
                    if chunk:
                        buffer += chunk
                    break
                continue
            chunk = proc.stdout.read(4096)
            if not chunk:
                break
            buffer += chunk
            while True:
                cut = len(buffer)
                for separator in (b"\n", b"\r"):
                    found = buffer.find(separator)
                    if found != -1 and found < cut:
                        cut = found
                if cut == len(buffer):
                    break
                piece = buffer[:cut]
                buffer = buffer[cut + 1 :]
                text = piece.decode("utf-8", errors="replace").strip()
                if text:
                    on_line(text)
        if buffer.strip():
            on_line(buffer.decode("utf-8", errors="replace").strip())
        rc = proc.wait(timeout=30)
    finally:
        if proc.stdout is not None:
            proc.stdout.close()
        if proc.poll() is None:
            stop_process(proc.pid, signal.SIGKILL)
            proc.wait(timeout=10)
    if rc < 0 and -rc in (signal.SIGTERM, signal.SIGINT):
        return 130
    return rc


def stage_args(stage: Stage, forward: list[str], skip_smoke: bool, parallel: bool = True) -> list[str]:
    args = ["--no-prompt", *forward]
    if skip_smoke and stage.number == 3 and "--no-smoke" not in args:
        args.append("--no-smoke")
    if stage.number == 2 and "--parallel" not in args and "--no-parallel" not in args:
        args.append("--parallel" if parallel else "--no-parallel")
    return args
