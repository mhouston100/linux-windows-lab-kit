"""Config quoting, stage progress, and percent parsing. No Textual and no lab run."""

from __future__ import annotations

import tempfile
import threading
import time
import unittest
from pathlib import Path

from labkit.config import LabConfig, load_config, parse_env, write_keys
from labkit.runner import run_script
from labkit.stages import note_progress, stage_percent, stage_state
from labkit.stages import Stage


class EnvTests(unittest.TestCase):
    def test_round_trip_keeps_password_and_comments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            example = root / "example.env"
            example.write_text("# keep me\nLAB_DOMAIN=Corp\nLAB_ADMIN_PASSWORD=\n", encoding="utf-8")
            target = root / "lab.env"
            write_keys(target, example, {"LAB_DOMAIN": "Lab", "LAB_ADMIN_PASSWORD": "p@ss w/ord"})
            text = target.read_text(encoding="utf-8")
            self.assertIn("# keep me", text)
            values = parse_env(text)
            self.assertEqual(values["LAB_DOMAIN"], "Lab")
            self.assertEqual(values["LAB_ADMIN_PASSWORD"], "p@ss w/ord")
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(text.count("LAB_DOMAIN="), 1)

    def test_load_uses_dest_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            (config_dir / "lab.env").write_text("VM_ROOT=/virtualmachines\nLAB_DOMAIN=Corp\n", encoding="utf-8")
            loaded = load_config(root, dest="/tmp/lab-dest")
            self.assertEqual(loaded.vm_root, Path("/tmp/lab-dest"))
            self.assertEqual(loaded.tmp_dir, Path("/tmp/lab-dest/tmp"))
            self.assertEqual(loaded.lab_domain, "Corp")


class StageTests(unittest.TestCase):
    def test_percent_uses_the_whole_number_before_the_dot(self) -> None:
        self.assertEqual(note_progress("convert 59.10%"), 59)
        self.assertEqual(note_progress("done 100%"), 100)
        self.assertIsNone(note_progress("no percent here"))

    def test_blocked_stage_stays_at_zero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "config").mkdir()
            loaded = load_config(root, dest=str(root / "dest"))
            stage = Stage(2, "phase2", "Convert disks", "phase2.ok", "phase1.ok", ("convert.done", "phase2.ok"))
            self.assertEqual(stage_state(loaded, stage), "blocked")
            self.assertEqual(stage_percent(loaded, stage), 0)
            loaded.markers_dir.mkdir(parents=True)
            (loaded.markers_dir / "phase1.ok").write_text("ok\n", encoding="utf-8")
            self.assertEqual(stage_state(loaded, stage), "ready")


class RunnerTests(unittest.TestCase):
    def test_reads_percent_lines_without_waiting_for_the_screen(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = root / "stage.sh"
            script.write_text("#!/bin/bash\nprintf 'work 59.10%%\\n'\nexit 0\n", encoding="utf-8")
            script.chmod(0o755)
            config = LabConfig(
                root=root,
                source_dir=root / "source",
                tmp_dir=root / "tmp",
                vm_root=root,
                lab_zip_path=root / "kit.zip",
                hypervisor="virtualbox",
                lab_prefix="HYD",
                lab_network_name="CorpNet",
                lab_admin_user="LabAdmin",
                lab_admin_password="secret",
                lab_domain="Corp",
            )
            lines: list[str] = []
            rc = run_script(config, script, [], lines.append, lambda: False)
            self.assertEqual(rc, 0)
            self.assertEqual(lines, ["work 59.10%"])
            self.assertEqual(note_progress(lines[0]), 59)

    def test_cancel_stops_a_quiet_script(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = root / "stage.sh"
            script.write_text("#!/bin/bash\nsleep 30\n", encoding="utf-8")
            script.chmod(0o755)
            config = LabConfig(
                root=root,
                source_dir=root / "source",
                tmp_dir=root / "tmp",
                vm_root=root,
                lab_zip_path=root / "kit.zip",
                hypervisor="virtualbox",
                lab_prefix="HYD",
                lab_network_name="CorpNet",
                lab_admin_user="LabAdmin",
                lab_admin_password="secret",
                lab_domain="Corp",
            )
            cancel = threading.Event()

            def later() -> None:
                time.sleep(0.3)
                cancel.set()

            threading.Thread(target=later, daemon=True).start()
            started = time.monotonic()
            rc = run_script(config, script, [], lambda _line: None, cancel.is_set)
            self.assertEqual(rc, 130)
            self.assertLess(time.monotonic() - started, 5)


if __name__ == "__main__":
    unittest.main()
