"""Desktop clipboard for the menu. Textual's own clipboard is not the system one."""

from __future__ import annotations

import os
import shutil
import subprocess
from collections.abc import Mapping


def read_clipboard(*, primary: bool = False, environ: Mapping[str, str] | None = None) -> str:
    """Return clipboard text. An empty string means nothing is copied."""
    env = os.environ if environ is None else environ
    for command in _read_commands(env, primary):
        if shutil.which(command[0], path=env.get("PATH")) is None:
            continue
        text = _run(command, env)
        if text is not None:
            return text
    if not primary:
        text = _kde_get(env)
        if text is not None:
            return text
    return ""


def write_clipboard(text: str, *, environ: Mapping[str, str] | None = None) -> bool:
    """Put text on the desktop clipboard. False when no clipboard tool is available."""
    env = os.environ if environ is None else environ
    data = text.encode("utf-8")
    for command in _write_commands(env):
        if shutil.which(command[0], path=env.get("PATH")) is None:
            continue
        if _run(command, env, data) is not None:
            return True
    return _kde_set(env, text)


def _read_commands(env: Mapping[str, str], primary: bool) -> tuple[tuple[str, ...], ...]:
    commands: list[tuple[str, ...]] = []
    if env.get("WAYLAND_DISPLAY"):
        if primary:
            commands.append(("wl-paste", "--primary", "--no-newline"))
        else:
            commands.append(("wl-paste", "--no-newline"))
    if env.get("DISPLAY") or not env.get("WAYLAND_DISPLAY"):
        selection = "primary" if primary else "clipboard"
        commands.append(("xclip", "-selection", selection, "-out"))
        commands.append(("xsel", f"--{selection}", "--output"))
    return tuple(commands)


def _write_commands(env: Mapping[str, str]) -> tuple[tuple[str, ...], ...]:
    commands: list[tuple[str, ...]] = []
    if env.get("WAYLAND_DISPLAY"):
        commands.append(("wl-copy",))
    if env.get("DISPLAY") or not env.get("WAYLAND_DISPLAY"):
        commands.append(("xclip", "-selection", "clipboard"))
        commands.append(("xsel", "--clipboard", "--input"))
    return tuple(commands)


def _kde_tool(env: Mapping[str, str]) -> str | None:
    for name in ("qdbus6", "qdbus"):
        found = shutil.which(name, path=env.get("PATH"))
        if found:
            return found
    return None


def _kde_get(env: Mapping[str, str]) -> str | None:
    tool = _kde_tool(env)
    if tool is None:
        return None
    text = _run(
        (tool, "org.kde.klipper", "/klipper", "org.kde.klipper.klipper.getClipboardContents"),
        env,
    )
    if text is None:
        return None
    if text.endswith("\n"):
        text = text[:-1]
    return text


def _kde_set(env: Mapping[str, str], text: str) -> bool:
    tool = _kde_tool(env)
    if tool is None:
        return False
    return _run(
        (tool, "org.kde.klipper", "/klipper", "org.kde.klipper.klipper.setClipboardContents", text),
        env,
    ) is not None


def _run(command: tuple[str, ...], env: Mapping[str, str], data: bytes | None = None) -> str | None:
    """Run a clipboard tool. None means it could not be used."""
    try:
        completed = subprocess.run(
            command,
            input=data,
            capture_output=True,
            timeout=1,
            check=False,
            env=dict(env),
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.decode("utf-8", errors="replace")
