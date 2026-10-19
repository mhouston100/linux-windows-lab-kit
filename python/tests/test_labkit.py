"""Config quoting, stage progress, and percent parsing. No Textual and no lab run."""

from __future__ import annotations

import os
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from labkit.config import LabConfig, load_config, parse_env, write_keys
from labkit.runner import run_script, stage_args
from labkit.stages import STAGES, next_stage, note_progress, stage_percent, stage_state, stages_to_run
from labkit.stages import Stage
from labkit.sudo_auth import start_mount_helper


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
            self.assertEqual(loaded.work_dir, Path("/tmp/lab-dest"))
            self.assertEqual(loaded.vm_root, Path("/tmp/lab-dest"))
            self.assertEqual(loaded.tmp_dir, Path("/tmp/lab-dest/tmp"))
            self.assertEqual(loaded.source_dir, Path("/tmp/lab-dest/source"))

    def test_work_directory_stays_apart_from_the_vm_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            (config_dir / "lab.env").write_text(
                "LAB_WORK_DIR=/data/work\nVM_ROOT=/data/vms\n",
                encoding="utf-8",
            )
            loaded = load_config(root)
            self.assertEqual(loaded.work_dir, Path("/data/work"))
            self.assertEqual(loaded.source_dir, Path("/data/work/source"))
            self.assertEqual(loaded.tmp_dir, Path("/data/work/tmp"))
            self.assertEqual(loaded.vm_root, Path("/data/vms"))

    def test_guest_additions_iso_uses_the_saved_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            (config_dir / "lab.env").write_text(
                "VBOX_GUEST_ADDITIONS_ISO=/opt/custom/VBoxGuestAdditions.iso\n",
                encoding="utf-8",
            )
            loaded = load_config(root)
            self.assertEqual(loaded.guest_additions_iso, "/opt/custom/VBoxGuestAdditions.iso")
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

    def test_run_all_starts_extract_before_convert_is_unblocked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "config").mkdir()
            loaded = load_config(root, dest=str(root / "dest"))
            chosen, blocked = stages_to_run(loaded)
            self.assertEqual(blocked, "")
            self.assertEqual([stage.number for stage in chosen], [1, 2, 3, 4, 5, 6])

    def test_next_stage_starts_at_one_and_moves_forward(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "config").mkdir()
            loaded = load_config(root, dest=str(root / "dest"))
            self.assertEqual(next_stage(loaded).number, 1)
            loaded.markers_dir.mkdir(parents=True)
            (loaded.markers_dir / "phase1.ok").write_text("ok\n", encoding="utf-8")
            self.assertEqual(next_stage(loaded).number, 2)


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


class SudoTests(unittest.TestCase):
    def _fake_sudo(self, root: Path, expected: str) -> Path:
        argv_path = root / "argv"
        stdin_path = root / "stdin"
        fake = root / "sudo"
        fake.write_text(
            "#!/bin/bash\n"
            f"printf '%s\\n' \"$@\" > {argv_path}\n"
            f"cat > {stdin_path}\n"
            f"cmp -s {stdin_path} <(printf '%s\\n' '{expected}') || exit 1\n"
            "dir=\n"
            "prev=\n"
            "for arg in \"$@\"; do\n"
            "  if [[ \"$prev\" == \"--root-helper\" ]]; then dir=\"$arg\"; fi\n"
            "  prev=\"$arg\"\n"
            "done\n"
            "printf '%s\\n' \"$$\" > \"$dir/helper.pid\"\n"
            "while [[ -f \"$dir/run\" ]]; do sleep 0.05; done\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)
        return fake

    def test_password_starts_helper_and_is_not_an_argument(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self._fake_sudo(root, "s3cret")
            helper = start_mount_helper(root / "guest-additions.sh", "s3cret", sudo_bin=str(fake))
            self.assertIsNotNone(helper)
            assert helper is not None
            self.assertNotIn("s3cret", (root / "argv").read_text(encoding="utf-8"))
            self.assertEqual((root / "stdin").read_text(encoding="utf-8"), "s3cret\n")
            self.assertEqual(helper.env["GA_PRIV_HOLD"], "1")
            self.assertTrue((helper.directory / "helper.pid").is_file())
            helper.stop()
            self.assertFalse(helper.directory.exists())

    def test_rejected_password_starts_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self._fake_sudo(root, "other")
            self.assertIsNone(start_mount_helper(root / "guest-additions.sh", "s3cret", sudo_bin=str(fake)))

    def test_newline_password_is_not_sent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker = root / "ran"
            fake = root / "sudo"
            fake.write_text(f"#!/bin/bash\ntouch {marker}\nexit 0\n", encoding="utf-8")
            fake.chmod(0o755)
            self.assertIsNone(start_mount_helper(root / "unused.sh", "bad\npassword", sudo_bin=str(fake)))
            self.assertFalse(marker.exists())


class ParallelTests(unittest.TestCase):
    def test_missing_setting_means_parallel_and_zero_turns_it_off(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            env = config_dir / "lab.env"
            env.write_text("LAB_DOMAIN=Corp\n", encoding="utf-8")
            self.assertTrue(load_config(root).parallel)
            env.write_text("LAB_PARALLEL=0\n", encoding="utf-8")
            self.assertFalse(load_config(root).parallel)

    def test_convert_stage_gets_one_parallel_flag(self) -> None:
        stage = next(item for item in STAGES if item.number == 2)
        self.assertIn("--parallel", stage_args(stage, [], skip_smoke=False, parallel=True))
        self.assertIn("--no-parallel", stage_args(stage, [], skip_smoke=False, parallel=False))
        args = stage_args(stage, ["--no-parallel"], skip_smoke=False, parallel=True)
        self.assertNotIn("--parallel", args)
        self.assertEqual(args.count("--no-parallel"), 1)

    def test_virtualbox_is_first_and_its_fields_are_locked(self) -> None:
        from labkit.config import hypervisor_fields, ordered_hypervisors

        names = ordered_hypervisors(Path(__file__).resolve().parents[2])
        self.assertEqual(names[0], "virtualbox")
        fields = {field.key: field for field in hypervisor_fields("virtualbox", "/virtualmachines")}
        self.assertEqual(fields["disk-format"].value, "VDI")
        self.assertFalse(fields["disk-format"].editable)
        self.assertTrue(fields["ga-iso"].editable)
        self.assertTrue(fields["ga-iso"].value)
        self.assertEqual(fields["vm-dir"].value, "/virtualmachines")
        self.assertTrue(fields["vm-dir"].editable)
        self.assertIn("proxmox", names)
        proxmox = {field.key: field for field in hypervisor_fields("proxmox")}
        self.assertEqual(proxmox["disk-format"].value, "qcow2")
        self.assertFalse(proxmox["disk-format"].editable)
        self.assertTrue(proxmox["api-host"].editable)
        self.assertTrue(proxmox["token-secret"].secret)
        self.assertEqual(proxmox["token-secret"].value, "")

class CheckboxTests(unittest.IsolatedAsyncioTestCase):
    async def test_checkbox_starts_on_and_saves_when_cleared(self) -> None:
        from textual.widgets import Checkbox

        from labkit.app import LabApp

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            env = config_dir / "lab.env"
            example = config_dir / "lab.env.example"
            env.write_text("LAB_DOMAIN=Corp\n", encoding="utf-8")
            example.write_text("LAB_DOMAIN=Corp\n", encoding="utf-8")
            app = LabApp(load_config(root), [])
            async with app.run_test(size=(110, 36)) as pilot:
                from textual.widgets import Input

                box = app.query_one("#parallel", Checkbox)
                self.assertTrue(box.value)
                self.assertIn("Parallel", str(box.render()))
                self.assertGreater(box.size.height, 0)
                self.assertLess(box.region.y, app.query_one("#actions").region.y)
                self.assertEqual(len(app.query("#settings")), 0)
                self.assertEqual(len(app.query("#stage-1")), 0)
                disk = app.query_one("#hv-disk-format", Input)
                self.assertTrue(disk.disabled)
                self.assertEqual(disk.value, "VDI")
                self.assertEqual(app.query_one("#platform-virtualbox").variant, "primary")
                await pilot.click("#parallel")
                await pilot.pause(0.2)
                self.assertFalse(app.cfg.parallel)
                self.assertIn("LAB_PARALLEL=0", env.read_text(encoding="utf-8"))

    async def test_run_next_starts_stage_one(self) -> None:
        from textual.widgets import Input

        from labkit import app as app_module
        from labkit.app import LabApp

        calls: list[str] = []

        def fake_run(config, script, args, on_line, cancelled, extra_env=None) -> int:
            calls.append(Path(script).name)
            return 0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            (config_dir / "lab.env").write_text("LAB_DOMAIN=Corp\n", encoding="utf-8")
            (config_dir / "lab.env.example").write_text("LAB_DOMAIN=Corp\n", encoding="utf-8")
            original = app_module.run_script
            app_module.run_script = fake_run
            try:
                app = LabApp(load_config(root, dest=str(root / "dest")), [])
                async with app.run_test(size=(110, 36)) as pilot:
                    self.assertEqual(str(app.query_one("#run-next").label), "Run Next (Stage 1)")
                    work = app.query_one("#work", Input)
                    disk = app.query_one("#hv-disk-format", Input)
                    vm_dir = app.query_one("#hv-vm-dir", Input)
                    iso = app.query_one("#hv-ga-iso", Input)
                    self.assertEqual(work.styles.border.left[0], "tall")
                    self.assertEqual(vm_dir.styles.border.left[0], "tall")
                    self.assertEqual(iso.styles.border.left[0], "tall")
                    self.assertFalse(vm_dir.disabled)
                    self.assertFalse(iso.disabled)
                    self.assertTrue(iso.value)
                    self.assertEqual(disk.styles.border.left[0], "")
                    await pilot.click("#run-next")
                    await pilot.pause(0.5)
            finally:
                app_module.run_script = original
            self.assertEqual(calls, ["phase1.sh"])


_FINGERPRINT = ":".join(["AB"] * 32)


def _proxmox_env(work: Path) -> str:
    return (
        "HYPERVISOR=proxmox\n"
        f"LAB_WORK_DIR={work}\n"
        "PVE_API_HOST=pve.example:8006\n"
        f"PVE_TLS_FINGERPRINT={_FINGERPRINT}\n"
        "PVE_NODE=pve\n"
        "PVE_STORAGE=local\n"
        "PVE_BRIDGE=vmbr0\n"
        "PVE_INTERNET_BRIDGE=vmbr1\n"
        "PVE_TOKEN_ID=labkit@pve!labkit\n"
        "PVE_TOKEN_SECRET=test-secret-value\n"
    )


class ProxmoxConfigTests(unittest.TestCase):
    def test_settings_round_trip_and_the_secret_stays_out_of_the_summary(self) -> None:
        from labkit.config import load_config, missing_proxmox_settings

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "config").mkdir()
            (root / "config" / "lab.env").write_text(_proxmox_env(root / "work"), encoding="utf-8")
            loaded = load_config(root)
            self.assertEqual(loaded.hypervisor, "proxmox")
            self.assertEqual(loaded.pve_api_host, "pve.example:8006")
            self.assertEqual(loaded.pve_token_secret, "test-secret-value")
            self.assertEqual(missing_proxmox_settings(loaded), [])
            summary = "\n".join(loaded.summary_lines())
            self.assertIn("pve.example:8006", summary)
            self.assertNotIn("test-secret-value", summary)
            loaded.pve_token_secret = ""
            self.assertIn("token secret", missing_proxmox_settings(loaded))


class ProxmoxApiTests(unittest.TestCase):
    def _fakes(self, root: Path) -> Path:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        openssl = bin_dir / "openssl"
        openssl.write_text(
            "#!/bin/bash\n"
            "if [[ \"$1\" == s_client ]]; then printf 'cert\\n'; exit 0; fi\n"
            "if [[ \"$1\" == x509 && \"$*\" == *fingerprint* ]]; then\n"
            "  printf 'sha256 Fingerprint=%s\\n' \"$FAKE_PVE_FINGERPRINT\"\n"
            "  exit 0\n"
            "fi\n"
            "if [[ \"$1\" == x509 ]]; then printf 'pem\\n'; exit 0; fi\n"
            "exit 1\n",
            encoding="utf-8",
        )
        curl = bin_dir / "curl"
        curl.write_text(
            "#!/bin/bash\n"
            "log=\"${FAKE_PVE_LOG:?}\"\n"
            "printf 'ARGV' >>\"$log\"\n"
            "for arg in \"$@\"; do printf ' %s' \"$arg\" >>\"$log\"; done\n"
            "printf '\\n' >>\"$log\"\n"
            "for arg in \"$@\"; do\n"
            "  if [[ \"$arg\" == *\"$FAKE_PVE_SECRET\"* ]]; then printf 'SECRET-IN-ARGV\\n' >>\"$log\"; fi\n"
            "done\n"
            "cfg=\"\"; out=\"\"\n"
            "args=(\"$@\")\n"
            "i=0\n"
            "while [[ $i -lt ${#args[@]} ]]; do\n"
            "  case \"${args[$i]}\" in\n"
            "    --config) i=$((i+1)); cfg=\"${args[$i]}\" ;;\n"
            "    --output) i=$((i+1)); out=\"${args[$i]}\" ;;\n"
            "    --data) i=$((i+1)); printf 'DATA %s\\n' \"${args[$i]}\" >>\"$log\" ;;\n"
            "    --form|--form-string) i=$((i+1)); printf 'FORM %s\\n' \"${args[$i]}\" >>\"$log\" ;;\n"
            "  esac\n"
            "  i=$((i+1))\n"
            "done\n"
            "method=GET\n"
            "url=\"\"\n"
            "if [[ -n \"$cfg\" ]]; then\n"
            "  if grep -q \"PVEAPIToken=.*${FAKE_PVE_SECRET}\" \"$cfg\"; then printf 'SECRET-IN-CONFIG\\n' >>\"$log\"; fi\n"
            "  parsed=\"$(python3 -c 'import sys\n"
            "method, url = \"GET\", \"\"\n"
            "for line in open(sys.argv[1], encoding=\"utf-8\"):\n"
            "    if line.startswith(\"request = \\\"\"):\n"
            "        method = line.split(\"\\\"\")[1]\n"
            "    if line.startswith(\"url = \\\"\"):\n"
            "        url = line.split(\"\\\"\")[1]\n"
            "print(method)\n"
            "print(url)' \"$cfg\")\"\n"
            "  method=\"${parsed%%$'\\n'*}\"\n"
            "  url=\"${parsed#*$'\\n'}\"\n"
            "fi\n"
            "body='{\"data\":[]}'\n"
            "if [[ \"$url\" == *\"/tasks/\"* ]]; then\n"
            "  body='{\"data\":{\"status\":\"stopped\",\"exitstatus\":\"OK\"}}'\n"
            "elif [[ \"$url\" == *\"/cluster/resources\"* ]]; then\n"
            "  if [[ \"${FAKE_PVE_MODE:-empty}\" == present ]]; then\n"
            "    body='{\"data\":[{\"type\":\"qemu\",\"vmid\":9101,\"name\":\"HYD-DC1\",\"node\":\"pve\",\"status\":\"stopped\"},{\"type\":\"qemu\",\"vmid\":9102,\"name\":\"HYD-CM1\",\"node\":\"pve\",\"status\":\"stopped\"},{\"type\":\"qemu\",\"vmid\":9103,\"name\":\"HYD-GW1\",\"node\":\"pve\",\"status\":\"stopped\"}]}'\n"
            "  fi\n"
            "elif [[ \"$url\" == *\"/config\"* && \"$method\" == GET ]]; then\n"
            "  if [[ \"${FAKE_PVE_MODE:-empty}\" == present ]]; then\n"
            "    body='{\"data\":{\"sata0\":\"local:9101/vm-9101-disk-0.raw\",\"net0\":\"e1000,bridge=vmbr0\",\"description\":\"Lab kit\"}}'\n"
            "  else\n"
            "    body='{\"data\":{}}'\n"
            "  fi\n"
            "elif [[ \"$method\" == POST || \"$method\" == PUT || \"$method\" == DELETE ]]; then\n"
            "  body='{\"data\":\"UPID:pve:00000001:00000002:00000003:qmcreate:9101:labkit@pve:\"}'\n"
            "fi\n"
            "if [[ -n \"$out\" ]]; then printf '%s' \"$body\" >\"$out\"; fi\n"
            "printf '200'\n",
            encoding="utf-8",
        )
        openssl.chmod(0o755)
        curl.chmod(0o755)
        return bin_dir

    def _run_create(self, mode: str) -> tuple[subprocess.CompletedProcess[str], str]:
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / "work"
            convert = work / "tmp" / "convert"
            convert.mkdir(parents=True)
            for name in ("HYD-DC1", "HYD-CM1", "HYD-GW1"):
                (convert / f"{name}.qcow2").write_bytes(b"disk")
            env_file = root / "lab.env"
            env_file.write_text(_proxmox_env(work), encoding="utf-8")
            log = root / "curl.log"
            bin_dir = self._fakes(root)
            env = os.environ.copy()
            for key in list(env):
                if key.startswith("LAB_CLI_") or key.startswith("PVE_") or key.startswith("FAKE_PVE_"):
                    env.pop(key)
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["LAB_ENV_FILE"] = str(env_file)
            env["LAB_NONINTERACTIVE"] = "1"
            env["FAKE_PVE_LOG"] = str(log)
            env["FAKE_PVE_SECRET"] = "test-secret-value"
            env["FAKE_PVE_FINGERPRINT"] = _FINGERPRINT
            env["FAKE_PVE_MODE"] = mode
            completed = subprocess.run(
                ["bash", str(repo / "scripts" / "hypervisors" / "proxmox" / "create-vms.sh"), "--no-prompt", "--no-smoke"],
                capture_output=True,
                text=True,
                timeout=30,
                env=env,
                check=False,
            )
            return completed, log.read_text(encoding="utf-8") if log.is_file() else ""

    def test_create_imports_three_disks_without_the_secret_on_the_command_line(self) -> None:
        completed, log = self._run_create("empty")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        data = "\n".join(line for line in log.splitlines() if line.startswith("DATA"))
        self.assertEqual(data.count("import-from%3D") + data.count("import-from="), 3)
        self.assertNotIn("SECRET-IN-ARGV", log)
        argv = "\n".join(line for line in log.splitlines() if line.startswith("ARGV"))
        self.assertNotIn("test-secret-value", argv)
        self.assertIn("SECRET-IN-CONFIG", log)

    def test_create_skips_guests_that_already_have_a_disk(self) -> None:
        completed, log = self._run_create("present")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertNotIn("import-from=", log)
        self.assertIn("already exists", completed.stdout)

    def test_wrong_fingerprint_stops_before_the_api_call(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = self._fakes(root)
            log = root / "curl.log"
            log.write_text("", encoding="utf-8")
            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["FAKE_PVE_LOG"] = str(log)
            env["FAKE_PVE_SECRET"] = "test-secret-value"
            env["FAKE_PVE_FINGERPRINT"] = _FINGERPRINT
            script = (
                f"source '{repo}/scripts/lib/common.sh'\n"
                f"source '{repo}/scripts/hypervisors/proxmox/api.sh'\n"
                "PVE_API_HOST=pve.example:8006\n"
                "PVE_TLS_FINGERPRINT=" + ":".join(["CC"] * 32) + "\n"
                "PVE_NODE=pve\n"
                "PVE_STORAGE=local\n"
                "PVE_BRIDGE=vmbr0\n"
                "PVE_INTERNET_BRIDGE=vmbr1\n"
                "PVE_TOKEN_ID=labkit@pve!labkit\n"
                "PVE_TOKEN_SECRET=test-secret-value\n"
                "pve_prepare\n"
            )
            completed = subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                timeout=15,
                env=env,
                check=False,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("fingerprint", completed.stderr.lower())
            self.assertNotIn("SECRET-IN-CONFIG", log.read_text(encoding="utf-8"))


class ProxmoxUiTests(unittest.IsolatedAsyncioTestCase):
    async def test_proxmox_fields_replace_the_vm_directory(self) -> None:
        from textual.widgets import Input

        from labkit.app import LabApp

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            for name in ("virtualbox", "proxmox"):
                backend = root / "scripts" / "hypervisors" / name
                backend.mkdir(parents=True)
                (backend / "load.sh").write_text("# test\n", encoding="utf-8")
            env = config_dir / "lab.env"
            example = config_dir / "lab.env.example"
            text = "HYPERVISOR=virtualbox\nLAB_WORK_DIR=" + str(root / "work") + "\n"
            env.write_text(text, encoding="utf-8")
            example.write_text(text, encoding="utf-8")
            app = LabApp(load_config(root), [])
            async with app.run_test(size=(120, 60)) as pilot:
                await pilot.click("#platform-proxmox")
                await pilot.pause(0.3)
                disk = app.query_one("#hv-disk-format", Input)
                secret = app.query_one("#hv-token-secret", Input)
                host = app.query_one("#hv-api-host", Input)
                self.assertEqual(disk.value, "qcow2")
                self.assertTrue(disk.disabled)
                self.assertEqual(disk.styles.border.left[0], "")
                self.assertTrue(secret.password)
                self.assertEqual(secret.value, "")
                self.assertEqual(host.styles.border.left[0], "tall")
                self.assertEqual(app.query_one("#hv-settings").border_title, "Proxmox - Edit hypervisor settings here")
                host.value = "pve.example:8006"
                self.assertTrue(app._save_field("hv-api-host"))
                secret.value = "test-secret-value"
                self.assertTrue(app._save_field("hv-token-secret"))
                self.assertEqual(secret.value, "")
            values = parse_env(env.read_text(encoding="utf-8"))
            self.assertEqual(values["HYPERVISOR"], "proxmox")
            self.assertEqual(values["PVE_API_HOST"], "pve.example:8006")
            self.assertEqual(values["PVE_TOKEN_SECRET"], "test-secret-value")
            log_path = root / "work" / "tmp" / "lab.log"
            if log_path.is_file():
                self.assertNotIn("test-secret-value", log_path.read_text(encoding="utf-8"))

    async def test_stage_three_does_not_ask_for_an_administrator_password(self) -> None:
        from labkit import app as app_module
        from labkit.app import LabApp, SudoPrompt

        calls: list[str] = []

        def fake_run(config, script, args, on_line, cancelled, extra_env=None) -> int:
            calls.append(Path(script).name)
            return 0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / "work"
            config_dir = root / "config"
            config_dir.mkdir()
            backend = root / "scripts" / "hypervisors" / "proxmox"
            backend.mkdir(parents=True)
            (backend / "load.sh").write_text("# test\n", encoding="utf-8")
            env = config_dir / "lab.env"
            example = config_dir / "lab.env.example"
            text = _proxmox_env(work)
            env.write_text(text, encoding="utf-8")
            example.write_text(text, encoding="utf-8")
            loaded = load_config(root)
            loaded.markers_dir.mkdir(parents=True)
            (loaded.markers_dir / "phase1.ok").write_text("ok\n", encoding="utf-8")
            (loaded.markers_dir / "phase2.ok").write_text("ok\n", encoding="utf-8")
            original = app_module.run_script
            app_module.run_script = fake_run
            try:
                app = LabApp(loaded, [])
                async with app.run_test(size=(120, 60)) as pilot:
                    self.assertEqual(str(app.query_one("#run-next").label), "Run Next (Stage 3)")
                    await pilot.click("#run-next")
                    await pilot.pause(0.5)
                    self.assertNotIsInstance(app.screen, SudoPrompt)
            finally:
                app_module.run_script = original
            self.assertEqual(calls, ["phase3.sh"])


if __name__ == "__main__":
    unittest.main()
