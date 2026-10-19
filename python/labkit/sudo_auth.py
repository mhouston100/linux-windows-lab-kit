"""Start the disk-mount helper once. The password is not kept.

sudo reads the password from its standard input and starts the existing Bash
helper. Stages then call that helper. They do not ask for sudo themselves.
"""

from __future__ import annotations

import locale
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


class MountHelper:
    def __init__(self, directory: Path, process: subprocess.Popen[bytes]) -> None:
        self.directory = directory
        self.process = process

    @property
    def env(self) -> dict[str, str]:
        return {"GA_ROOT_DIR": str(self.directory), "GA_PRIV_HOLD": "1"}

    def stop(self) -> None:
        self.directory.joinpath("run").unlink(missing_ok=True)
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        shutil.rmtree(self.directory, ignore_errors=True)


def start_mount_helper(script: Path, password: str, sudo_bin: str = "sudo") -> MountHelper | None:
    """Start the helper. Returns None when sudo rejects the password."""
    if password == "" or any(char in password for char in "\n\r\x00"):
        return None
    encoding = locale.getpreferredencoding(False) or "utf-8"
    try:
        payload = password.encode(encoding, errors="strict") + b"\n"
    except UnicodeEncodeError:
        return None

    directory = Path(tempfile.mkdtemp(prefix="lab-ga."))
    os.chmod(directory, 0o700)
    (directory / "run").touch()
    (directory / "owner.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
    started = False
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            [sudo_bin, "-S", "-p", "", "bash", str(script), "--root-helper", str(directory)],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        assert process.stdin is not None
        process.stdin.write(payload)
        process.stdin.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            pid_file = directory / "helper.pid"
            if pid_file.is_file() and pid_file.stat().st_size > 0:
                started = True
                return MountHelper(directory, process)
            if process.poll() is not None:
                break
            time.sleep(0.05)
        return None
    except (FileNotFoundError, OSError):
        return None
    finally:
        payload = b""
        if not started:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            shutil.rmtree(directory, ignore_errors=True)
