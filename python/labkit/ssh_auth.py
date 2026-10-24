"""Hold an SSH password for one run. It is not written to lab.env.

OpenSSH reads it through a short-lived askpass program. The program and the
password file are removed when the run ends.
"""

from __future__ import annotations

import locale
import os
import shlex
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


class SshSession:
    def __init__(self, directory: Path) -> None:
        self.directory = directory

    @property
    def env(self) -> dict[str, str]:
        return {
            "SSH_ASKPASS": str(self.directory / "askpass"),
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": os.environ.get("DISPLAY") or ":0",
        }

    def stop(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)


def start_ssh_session(password: str) -> SshSession | None:
    """Create the askpass files. Returns None when the password cannot be used."""
    if password == "" or any(char in password for char in "\n\r\x00"):
        return None
    encoding = locale.getpreferredencoding(False) or "utf-8"
    try:
        payload = password.encode(encoding, errors="strict") + b"\n"
    except UnicodeEncodeError:
        return None

    directory = Path(tempfile.mkdtemp(prefix="lab-ssh."))
    os.chmod(directory, 0o700)
    secret = directory / "password"
    askpass = directory / "askpass"
    try:
        secret.write_bytes(payload)
        os.chmod(secret, stat.S_IRUSR | stat.S_IWUSR)
        askpass.write_text("#!/bin/sh\ncat " + shlex.quote(str(secret)) + "\n", encoding="utf-8")
        os.chmod(askpass, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    except OSError:
        shutil.rmtree(directory, ignore_errors=True)
        return None
    finally:
        payload = b""
    return SshSession(directory)


def login_error(session: SshSession, user: str, host: str, port: str) -> str | None:
    """None when this password logs in. Otherwise a short reason with no password in it."""
    env = os.environ.copy()
    env.update(session.env)
    try:
        completed = subprocess.run(
            [
                "ssh",
                "-n",
                "-p",
                port,
                "-o",
                "PreferredAuthentications=password",
                "-o",
                "NumberOfPasswordPrompts=1",
                "-o",
                "IdentitiesOnly=yes",
                "-o",
                "ConnectTimeout=8",
                "-o",
                "StrictHostKeyChecking=accept-new",
                f"{user}@{host}",
                "true",
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "SSH login failed."
    if completed.returncode == 0:
        return None
    text = (completed.stderr or "").strip()
    if "Permission denied" in text:
        return "Password was not accepted."
    tail = text.splitlines()[-1].strip() if text else ""
    if tail:
        return "SSH login failed. " + tail[:160]
    return "SSH login failed."


def login_accepted(session: SshSession, user: str, host: str, port: str) -> bool:
    """True when this password logs in. The password is not passed as an argument."""
    return login_error(session, user, host, port) is None
