"""Config quoting, stage progress, and percent parsing. No Textual and no lab run."""

from __future__ import annotations

import os
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from labkit.clipboard import read_clipboard, write_clipboard
from labkit.config import LabConfig, ensure_saved_defaults, example_defaults, load_config, parse_env, write_keys
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

    def test_first_start_writes_missing_defaults_and_keeps_saved_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            example = config_dir / "lab.env.example"
            example.write_text(
                "# bridges\n"
                "PVE_NODE=pve\n"
                "PVE_BRIDGE=vmbr1\n"
                "PVE_INTERNET_BRIDGE=vmbr0\n"
                "LAB_ADMIN_PASSWORD=\n"
                "# PVE_TOKEN_SECRET=\n",
                encoding="utf-8",
            )
            env_file = config_dir / "lab.env"
            env_file.write_text(
                "# local\nPVE_NODE=proxmox01\nPVE_TOKEN_SECRET=kept-secret\n",
                encoding="utf-8",
            )
            ensure_saved_defaults(root)
            text = env_file.read_text(encoding="utf-8")
            values = parse_env(text)
            self.assertEqual(values["PVE_NODE"], "proxmox01")
            self.assertEqual(values["PVE_BRIDGE"], "vmbr1")
            self.assertEqual(values["PVE_INTERNET_BRIDGE"], "vmbr0")
            self.assertEqual(values["PVE_TOKEN_SECRET"], "kept-secret")
            self.assertNotIn("LAB_ADMIN_PASSWORD", values)
            self.assertIn("# local", text)
            self.assertEqual(text.count("PVE_BRIDGE="), 1)
            ensure_saved_defaults(root)
            self.assertEqual(env_file.read_text(encoding="utf-8"), text)

    def test_example_defaults_include_the_bridges_and_skip_secrets(self) -> None:
        example = Path(__file__).resolve().parents[2] / "config" / "lab.env.example"
        defaults = example_defaults(example)
        self.assertEqual(defaults["PVE_BRIDGE"], "vmbr1")
        self.assertEqual(defaults["PVE_INTERNET_BRIDGE"], "vmbr0")
        self.assertEqual(defaults["PVE_TOKEN_ID"], "root@pam!root")
        self.assertNotIn("PVE_TOKEN_SECRET", defaults)
        self.assertNotIn("PVE_API_HOST", defaults)
        self.assertNotIn("LAB_ADMIN_PASSWORD", defaults)


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

    def test_phase2_accepts_the_parallel_flag(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        script = repo / "scripts" / "phase2.sh"
        for flag in ("--parallel", "--no-parallel"):
            completed = subprocess.run(
                ["bash", str(script), flag, "-h"],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            output = completed.stdout + completed.stderr
            self.assertEqual(completed.returncode, 0, output)
            self.assertNotIn("Unknown option", output)
            self.assertIn(flag, output)

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
        self.assertEqual(proxmox["api-host"].value, "")
        self.assertEqual(proxmox["node"].value, "pve")
        self.assertEqual(proxmox["import-storage"].value, "local")
        self.assertEqual(proxmox["storage"].label, "Disk storage")
        self.assertEqual(proxmox["storage"].value, "local-lvm")
        self.assertEqual(proxmox["bridge"].value, "vmbr1")
        self.assertEqual(proxmox["internet-bridge"].value, "vmbr0")
        self.assertEqual(proxmox["token-id"].value, "root@pam!root")
        self.assertTrue(proxmox["token-id"].editable)
        self.assertTrue(proxmox["token-secret"].secret)
        self.assertEqual(proxmox["token-secret"].value, "")
        self.assertEqual(proxmox["virtio-iso"].value, "")
        self.assertTrue(proxmox["virtio-iso"].editable)

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
    iso = work.parent / "virtio-win.iso"
    iso.write_bytes(b"iso")
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
        f"PVE_VIRTIO_ISO={iso}\n"
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

    def test_a_proxmox_run_stops_until_the_virtio_iso_exists(self) -> None:
        from labkit.config import load_config, virtio_iso_block

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "config").mkdir()
            env = _proxmox_env(root / "work")
            (root / "config" / "lab.env").write_text(env, encoding="utf-8")
            loaded = load_config(root)
            self.assertEqual(virtio_iso_block(loaded), "")
            loaded.pve_virtio_iso = ""
            self.assertIn("The run has not started.", virtio_iso_block(loaded))
            loaded.pve_virtio_iso = str(root / "missing.iso")
            self.assertIn("was not found", virtio_iso_block(loaded))

    def test_missing_proxmox_keys_use_the_root_token(self) -> None:
        from labkit.config import load_config

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "config").mkdir()
            (root / "config" / "lab.env").write_text("HYPERVISOR=proxmox\n", encoding="utf-8")
            loaded = load_config(root)
            self.assertEqual(loaded.pve_node, "pve")
            self.assertEqual(loaded.pve_import_storage, "local")
            self.assertEqual(loaded.pve_storage, "local-lvm")
            self.assertFalse(loaded.pve_keep_imports)
            self.assertEqual(loaded.pve_bridge, "vmbr1")
            self.assertEqual(loaded.pve_internet_bridge, "vmbr0")
            self.assertEqual(loaded.pve_token_id, "root@pam!root")
            self.assertEqual(loaded.pve_ssh_user, "root")
            self.assertEqual(loaded.pve_ssh_host, "")
            self.assertEqual(loaded.pve_ssh_port, "22")
            self.assertEqual(loaded.pve_ssh_identity, "")
            self.assertEqual(loaded.pve_api_host, "")
            self.assertEqual(loaded.pve_token_secret, "")
            (root / "config" / "lab.env").write_text(
                "PVE_NODE=node2\nPVE_TOKEN_ID=other@pve!other\n",
                encoding="utf-8",
            )
            overridden = load_config(root)
            self.assertEqual(overridden.pve_node, "node2")
            self.assertEqual(overridden.pve_token_id, "other@pve!other")
            self.assertEqual(overridden.pve_storage, "local-lvm")
            self.assertEqual(overridden.pve_import_storage, "local")
            overridden.pve_api_host = "pve.example:8006"
            overridden.pve_token_secret = "test-secret-value"
            overridden.pve_tls_fingerprint = ""
            from labkit.config import missing_proxmox_settings
            self.assertNotIn("TLS fingerprint", missing_proxmox_settings(overridden))


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
            "  if grep -q '^insecure$' \"$cfg\"; then printf 'INSECURE\\n' >>\"$log\"; fi\n"
            "  if grep -q '^cacert ' \"$cfg\"; then printf 'CACERT\\n' >>\"$log\"; fi\n"
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
            "code=200\n"
            "if [[ \"$url\" == *\"/tasks/\"* ]]; then\n"
            "  body='{\"data\":{\"status\":\"stopped\",\"exitstatus\":\"OK\"}}'\n"
            "elif [[ \"$url\" == *\"/cluster/resources\"* ]]; then\n"
            "  if [[ \"${FAKE_PVE_MODE:-empty}\" == present ]]; then\n"
            "    body='{\"data\":[{\"type\":\"qemu\",\"vmid\":9101,\"name\":\"HYD-DC1\",\"node\":\"pve\",\"status\":\"stopped\"},{\"type\":\"qemu\",\"vmid\":9102,\"name\":\"HYD-CM1\",\"node\":\"pve\",\"status\":\"stopped\"},{\"type\":\"qemu\",\"vmid\":9103,\"name\":\"HYD-GW1\",\"node\":\"pve\",\"status\":\"stopped\"}]}'\n"
            "  fi\n"
            "elif [[ \"$url\" == *\"/version\"* ]]; then\n"
            "  body='{\"data\":{\"version\":\"8.4.0\"}}'\n"
            "elif [[ \"$url\" == *\"/network\"* ]]; then\n"
            "  if [[ \"${FAKE_PVE_MODE:-}\" == noaudit ]]; then\n"
            "    body='{\"data\":null,\"message\":\"Permission check failed (/nodes/pve, Sys.Audit)\"}'\n"
            "    code=403\n"
            "  elif [[ \"${FAKE_PVE_MODE:-}\" == hidden ]]; then\n"
            "    body='{\"data\":[{\"iface\":\"eno1\",\"type\":\"eth\"}]}'\n"
            "  else\n"
            "    body='{\"data\":[{\"iface\":\"vmbr0\",\"type\":\"bridge\"},{\"iface\":\"vmbr1\",\"type\":\"bridge\"}]}'\n"
            "  fi\n"
            "elif [[ \"$url\" == *\"/storage/\"* && \"$url\" == *\"/status\" ]]; then\n"
            "  body='{\"data\":{\"avail\":500000000000}}'\n"
            "elif [[ \"$url\" == *\"/storage/\"* && \"$url\" != *\"/content\"* && \"$url\" != *\"/upload\"* && \"$url\" != *\"/nodes/\"* ]]; then\n"
            "  body='{\"data\":{\"content\":\"import,images\",\"path\":\"/var/lib/vz\",\"type\":\"dir\"}}'\n"
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
            "printf '%s' \"$code\"\n",
            encoding="utf-8",
        )
        state = root / "remote-sizes"
        state.write_text("", encoding="utf-8")
        ssh = bin_dir / "ssh"
        ssh.write_text(
            "#!/bin/bash\n"
            "log=\"${FAKE_PVE_LOG:?}\"\n"
            "cmd=\"${@: -1}\"\n"
            "printf 'SSH %s\\n' \"$cmd\" >>\"$log\"\n"
            f"state={state}\n"
            "if [[ \"$cmd\" == stat\\ * ]]; then\n"
            "  path=\"${cmd##* }\"\n"
            "  size=\"$(awk -F '\\t' -v p=\"$path\" '$1==p {print $2}' \"$state\" | tail -n 1)\"\n"
            "  if [[ \" $* \" == *\" -n \"* ]]; then printf 'SSH-N\\n' >>\"$log\"; fi\n"
            "  if [[ -n \"$size\" ]]; then\n"
            "    if [[ -n \"${FAKE_PVE_STAT_NOISE:-}\" ]]; then printf '==> Using the SSH password entered for this run.\\n'; fi\n"
            "    printf '%s' \"$size\"; exit 0\n"
            "  fi\n"
            "  exit 1\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        rsync = bin_dir / "rsync"
        rsync.write_text(
            "#!/bin/bash\n"
            "log=\"${FAKE_PVE_LOG:?}\"\n"
            "printf 'RSYNC' >>\"$log\"\n"
            "for arg in \"$@\"; do printf ' %s' \"$arg\" >>\"$log\"; done\n"
            "printf '\\n' >>\"$log\"\n"
            "left=\"${FAKE_PVE_RSYNC_LEFT:-}\"\n"
            "if [[ -n \"$left\" && -f \"$left\" ]]; then\n"
            "  count=\"$(cat \"$left\")\"\n"
            "  if [[ \"$count\" -gt 0 ]]; then\n"
            "    printf '%s' \"$((count - 1))\" >\"$left\"\n"
            "    printf 'rsync connection reset\\n' >&2\n"
            "    exit 255\n"
            "  fi\n"
            "fi\n"
            "src=\"\"; dest=\"\"; skip=0\n"
            "for arg in \"$@\"; do\n"
            "  if [[ \"$skip\" -eq 1 ]]; then skip=0; continue; fi\n"
            "  case \"$arg\" in\n"
            "    -e|--timeout) skip=1; continue ;;\n"
            "    --) continue ;;\n"
            "    -*) continue ;;\n"
            "  esac\n"
            "  if [[ -z \"$src\" ]]; then src=\"$arg\"; else dest=\"$arg\"; fi\n"
            "done\n"
            "dir=\"${dest#*:}\"\n"
            "base=\"$(basename \"$src\")\"\n"
            "bytes=\"$(stat -c %s \"$src\")\"\n"
            f"printf '%s\\t%s\\n' \"${{dir%/}}/$base\" \"$bytes\" >>{state}\n"
            "exit 0\n",
            encoding="utf-8",
        )
        openssl.chmod(0o755)
        curl.chmod(0o755)
        ssh.chmod(0o755)
        rsync.chmod(0o755)
        return bin_dir

    def _run_create(
        self,
        mode: str,
        rsync_fails: int = 0,
        askpass: bool = False,
        stat_noise: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], str]:
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
                if key in {"SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"}:
                    env.pop(key)
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["LAB_ENV_FILE"] = str(env_file)
            env["LAB_NONINTERACTIVE"] = "1"
            env["FAKE_PVE_LOG"] = str(log)
            env["FAKE_PVE_SECRET"] = "test-secret-value"
            env["FAKE_PVE_FINGERPRINT"] = _FINGERPRINT
            env["FAKE_PVE_MODE"] = mode
            env["PVE_RSYNC_WAIT"] = "0"
            left = root / "rsync-left"
            left.write_text(str(rsync_fails), encoding="utf-8")
            env["FAKE_PVE_RSYNC_LEFT"] = str(left)
            if askpass:
                env["SSH_ASKPASS"] = "/bin/true"
                env["SSH_ASKPASS_REQUIRE"] = "force"
            if stat_noise:
                env["FAKE_PVE_STAT_NOISE"] = "1"
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
        self.assertIn("Removing uploaded", completed.stdout)
        self.assertIn("--partial", log)
        self.assertIn("--append-verify", log)
        self.assertIn("root@pve.example:/var/lib/vz/import/", log)
        self.assertNotIn("/upload", log)
        self.assertNotIn("SECRET-IN-ARGV", log)
        argv = "\n".join(line for line in log.splitlines() if line.startswith("ARGV"))
        self.assertNotIn("test-secret-value", argv)
        self.assertIn("SECRET-IN-CONFIG", log)
        self.assertIn("SSH-N", log)
        rsync_lines = [line for line in log.splitlines() if line.startswith("RSYNC")]
        self.assertTrue(rsync_lines)
        for line in rsync_lines:
            self.assertNotIn("ssh -n", line)

    def test_remote_size_ignores_the_login_message(self) -> None:
        completed, _log = self._run_create("empty", stat_noise=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertNotIn("was not a number", completed.stdout + completed.stderr)

    def test_create_skips_guests_that_already_have_a_disk(self) -> None:
        completed, log = self._run_create("present")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertNotIn("import-from=", log)
        self.assertIn("already exists", completed.stdout)

    def test_rsync_retries_a_dropped_copy(self) -> None:
        completed, log = self._run_create("empty", rsync_fails=1)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("partial file stays", completed.stdout)
        self.assertEqual(log.count("\nRSYNC") + (1 if log.startswith("RSYNC") else 0), 4)
        self.assertIn("--append-verify", log)

    def test_a_menu_password_is_used_instead_of_a_key_prompt(self) -> None:
        completed, log = self._run_create("empty", askpass=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("PreferredAuthentications=password", log)
        self.assertIn("Using the SSH password entered for this run.", completed.stdout + completed.stderr)
        self.assertNotIn("BatchMode=yes", log)

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

    def test_blank_fingerprint_calls_the_api_without_a_pin(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = self._fakes(root)
            log = root / "curl.log"
            log.write_text("", encoding="utf-8")
            env = os.environ.copy()
            for key in list(env):
                if key.startswith("PVE_") or key.startswith("FAKE_PVE_"):
                    env.pop(key)
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["FAKE_PVE_LOG"] = str(log)
            env["FAKE_PVE_SECRET"] = "test-secret-value"
            env["FAKE_PVE_FINGERPRINT"] = _FINGERPRINT
            script = (
                f"source '{repo}/scripts/lib/common.sh'\n"
                f"source '{repo}/scripts/hypervisors/proxmox/api.sh'\n"
                "unset PVE_TLS_FINGERPRINT\n"
                "PVE_API_HOST=pve.example:8006\n"
                "PVE_NODE=pve\n"
                "PVE_STORAGE=local\n"
                "PVE_BRIDGE=vmbr1\n"
                "PVE_INTERNET_BRIDGE=vmbr0\n"
                "PVE_TOKEN_ID=labkit@pve!labkit\n"
                "PVE_TOKEN_SECRET=test-secret-value\n"
                "pve_call GET /version\n"
            )
            completed = subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                timeout=15,
                env=env,
                check=False,
            )
            recorded = log.read_text(encoding="utf-8")
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertIn("not checked", completed.stdout)
            self.assertIn("INSECURE", recorded)
            self.assertIn("SECRET-IN-CONFIG", recorded)
            self.assertNotIn("CACERT", recorded)

    def test_connection_check_reads_version_node_storage_and_bridges(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = self._fakes(root)
            log = root / "curl.log"
            log.write_text("", encoding="utf-8")
            env = os.environ.copy()
            for key in list(env):
                if key.startswith("PVE_") or key.startswith("FAKE_PVE_"):
                    env.pop(key)
            env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
            env["FAKE_PVE_LOG"] = str(log)
            env["FAKE_PVE_SECRET"] = "test-secret-value"
            env["FAKE_PVE_FINGERPRINT"] = _FINGERPRINT
            script = (
                f"source '{repo}/scripts/lib/common.sh'\n"
                f"source '{repo}/scripts/hypervisors/proxmox/api.sh'\n"
                "PVE_API_HOST=pve.example:8006\n"
                "PVE_TLS_FINGERPRINT=" + _FINGERPRINT + "\n"
                "PVE_NODE=pve\n"
                "PVE_STORAGE=local\n"
                "PVE_BRIDGE=vmbr1\n"
                "PVE_INTERNET_BRIDGE=vmbr0\n"
                "PVE_TOKEN_ID=labkit@pve!labkit\n"
                "PVE_TOKEN_SECRET=test-secret-value\n"
                "pve_test_connection\n"
            )
            completed = subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                timeout=15,
                env=env,
                check=False,
            )
            recorded = log.read_text(encoding="utf-8")
            output = completed.stdout + completed.stderr
            self.assertEqual(completed.returncode, 0, output)
            self.assertIn("8.4.0", output)
            self.assertIn("Node pve is reachable", output)
            self.assertIn("allows import", output)
            self.assertIn("vmbr1", output)
            self.assertIn("vmbr0", output)
            self.assertIn("can write /var/lib/vz/import", output)
            self.assertIn("SECRET-IN-CONFIG", recorded)
            self.assertNotIn("SECRET-IN-ARGV", recorded)
            self.assertNotIn("POST", recorded)

            env["FAKE_PVE_MODE"] = "noaudit"
            log.write_text("", encoding="utf-8")
            skipped = subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                timeout=15,
                env=env,
                check=False,
            )
            skipped_output = skipped.stdout + skipped.stderr
            self.assertEqual(skipped.returncode, 0, skipped_output)
            self.assertIn("Sys.Audit", skipped_output)
            self.assertIn("Node pve is reachable", skipped_output)

            env["FAKE_PVE_MODE"] = "hidden"
            log.write_text("", encoding="utf-8")
            hidden = subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                timeout=15,
                env=env,
                check=False,
            )
            hidden_output = hidden.stdout + hidden.stderr
            self.assertNotEqual(hidden.returncode, 0, hidden_output)
            self.assertIn("PVESDNUser", hidden_output)
            self.assertIn("/sdn/zones/localnetwork", hidden_output)
            self.assertIn("eno1", hidden_output)


class ProxmoxUiTests(unittest.IsolatedAsyncioTestCase):
    async def test_stage_one_does_not_start_without_the_virtio_iso(self) -> None:
        from labkit import app as app_module
        from labkit.app import LabApp

        calls: list[str] = []

        def fake_run(config, script, args, on_line, cancelled, extra_env=None) -> int:
            calls.append(Path(script).name)
            return 0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / "work"
            config_dir = root / "config"
            config_dir.mkdir()
            text = "\n".join(
                line for line in _proxmox_env(work).splitlines() if not line.startswith("PVE_VIRTIO_ISO=")
            ) + "\n"
            (config_dir / "lab.env").write_text(text, encoding="utf-8")
            (config_dir / "lab.env.example").write_text(text, encoding="utf-8")
            loaded = load_config(root)
            original = app_module.run_script
            app_module.run_script = fake_run
            try:
                app = LabApp(loaded, [])
                async with app.run_test(size=(120, 60)) as pilot:
                    await pilot.click("#run-next")
                    await pilot.pause(0.3)
            finally:
                app_module.run_script = original
            self.assertEqual(calls, [])
            log_text = (work / "tmp" / "lab.log").read_text(encoding="utf-8")
            self.assertIn("The run has not started.", log_text)
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
                token = app.query_one("#hv-token-id", Input)
                self.assertEqual(disk.value, "qcow2")
                self.assertEqual(app.query_one("#hv-node", Input).value, "pve")
                self.assertEqual(app.query_one("#hv-import-storage", Input).value, "local")
                self.assertEqual(app.query_one("#hv-storage", Input).value, "local-lvm")
                from textual.widgets import Checkbox
                self.assertFalse(app.query_one("#hv-keep-imports", Checkbox).value)
                self.assertEqual(app.query_one("#hv-bridge", Input).value, "vmbr1")
                self.assertEqual(app.query_one("#hv-internet-bridge", Input).value, "vmbr0")
                self.assertEqual(token.value, "root@pam!root")
                self.assertEqual(app.query_one("#hv-ssh-user", Input).value, "root")
                self.assertEqual(app.query_one("#hv-ssh-host", Input).value, "")
                self.assertEqual(app.query_one("#hv-ssh-port", Input).value, "22")
                self.assertIn("API host", app.query_one("#hv-ssh-host", Input).placeholder)
                self.assertIn("asks for the password", app.query_one("#hv-ssh-identity", Input).placeholder)
                self.assertFalse(token.disabled)
                self.assertTrue(disk.disabled)
                self.assertEqual(disk.styles.border.left[0], "")
                self.assertTrue(secret.password)
                self.assertEqual(secret.value, "")
                fingerprint = app.query_one("#hv-fingerprint", Input)
                self.assertEqual(host.styles.border.left[0], "tall")
                self.assertIn("Optional", fingerprint.placeholder)
                self.assertIn("Blank skips the check", fingerprint.placeholder)
                fingerprint.value = "aa" * 32
                self.assertTrue(app._save_field("hv-fingerprint"))
                fingerprint.value = ""
                self.assertTrue(app._save_field("hv-fingerprint"))
                self.assertEqual(app.query_one("#hv-settings").border_title, "Proxmox - Edit hypervisor settings here")
                fields = app.query_one("#hv-fields")
                button = app.query_one("#test-connection")
                self.assertGreater(button.region.x, fields.region.x)
                host.value = "pve.example:8006"
                self.assertTrue(app._save_field("hv-api-host"))
                secret.value = "test-secret-value"
                self.assertTrue(app._save_field("hv-token-secret"))
                self.assertEqual(secret.value, "")
            values = parse_env(env.read_text(encoding="utf-8"))
            self.assertEqual(values["HYPERVISOR"], "proxmox")
            self.assertEqual(values["PVE_API_HOST"], "pve.example:8006")
            self.assertEqual(values["PVE_TOKEN_SECRET"], "test-secret-value")
            self.assertEqual(values.get("PVE_TLS_FINGERPRINT", ""), "")
            log_path = root / "work" / "tmp" / "lab.log"
            if log_path.is_file():
                self.assertNotIn("test-secret-value", log_path.read_text(encoding="utf-8"))

    async def test_stage_three_asks_for_the_ssh_password_before_it_starts(self) -> None:
        from unittest.mock import patch

        from textual.widgets import Input

        from labkit import app as app_module
        from labkit.app import LabApp, SshPrompt, SudoPrompt

        calls: list[str] = []
        passed: list[dict[str, str] | None] = []

        def fake_run(config, script, args, on_line, cancelled, extra_env=None) -> int:
            calls.append(Path(script).name)
            passed.append(extra_env)
            return 0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / "work"
            config_dir = root / "config"
            config_dir.mkdir()
            backend = root / "scripts" / "hypervisors" / "proxmox"
            backend.mkdir(parents=True)
            (backend / "load.sh").write_text("# test\n", encoding="utf-8")
            (backend / "test-connection.sh").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
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
                    with patch("labkit.app.login_error", return_value=None):
                        await pilot.click("#run-next")
                        await pilot.pause(0.3)
                        self.assertIsInstance(app.screen, SshPrompt)
                        self.assertNotIsInstance(app.screen, SudoPrompt)
                        self.assertEqual(calls, [])
                        app.screen.query_one("#ssh-password", Input).value = "ssh-secret"
                        await pilot.click("#ssh-continue")
                        await pilot.pause(0.5)
                    self.assertNotIsInstance(app.screen, SshPrompt)
            finally:
                app_module.run_script = original
            self.assertEqual(calls, ["phase3.sh"])
            self.assertIsNotNone(passed[0])
            assert passed[0] is not None
            self.assertIn("SSH_ASKPASS", passed[0])
            self.assertNotIn("ssh-secret", " ".join(passed[0].values()))
            self.assertNotIn("ssh-secret", env.read_text(encoding="utf-8"))
            self.assertFalse(Path(passed[0]["SSH_ASKPASS"]).exists())

    async def test_a_rejected_ssh_password_does_not_start_the_stage(self) -> None:
        from unittest.mock import patch

        from textual.widgets import Input

        from labkit import app as app_module
        from labkit.app import LabApp, SshPrompt

        calls: list[str] = []

        def fake_run(config, script, args, on_line, cancelled, extra_env=None) -> int:
            calls.append(Path(script).name)
            return 0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / "work"
            config_dir = root / "config"
            config_dir.mkdir()
            (config_dir / "lab.env").write_text(_proxmox_env(work), encoding="utf-8")
            (config_dir / "lab.env.example").write_text(_proxmox_env(work), encoding="utf-8")
            loaded = load_config(root)
            loaded.markers_dir.mkdir(parents=True)
            (loaded.markers_dir / "phase1.ok").write_text("ok\n", encoding="utf-8")
            (loaded.markers_dir / "phase2.ok").write_text("ok\n", encoding="utf-8")
            original = app_module.run_script
            app_module.run_script = fake_run
            try:
                app = LabApp(loaded, [])
                async with app.run_test(size=(120, 60)) as pilot:
                    with patch("labkit.app.login_error", return_value="Password was not accepted."):
                        await pilot.click("#run-next")
                        await pilot.pause(0.3)
                        app.screen.query_one("#ssh-password", Input).value = "ssh-secret"
                        await pilot.click("#ssh-continue")
                        await pilot.pause(0.5)
                        self.assertIsInstance(app.screen, SshPrompt)
                        await pilot.click("#ssh-cancel")
                        await pilot.pause(0.3)
            finally:
                app_module.run_script = original
            self.assertEqual(calls, [])

    async def test_connection_check_asks_for_the_ssh_password_first(self) -> None:
        from unittest.mock import patch

        from textual.widgets import Input

        from labkit import app as app_module
        from labkit.app import LabApp, SshPrompt

        calls: list[str] = []

        def fake_run(config, script, args, on_line, cancelled, extra_env=None) -> int:
            calls.append(Path(script).name)
            return 0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            backend = root / "scripts" / "hypervisors" / "proxmox"
            backend.mkdir(parents=True)
            (backend / "load.sh").write_text("# test\n", encoding="utf-8")
            (backend / "test-connection.sh").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
            text = _proxmox_env(root / "work")
            (config_dir / "lab.env").write_text(text, encoding="utf-8")
            (config_dir / "lab.env.example").write_text(text, encoding="utf-8")
            original = app_module.run_script
            app_module.run_script = fake_run
            try:
                app = LabApp(load_config(root), [])
                async with app.run_test(size=(120, 60)) as pilot:
                    with patch("labkit.app.login_error", return_value=None):
                        await pilot.click("#test-connection")
                        await pilot.pause(0.3)
                        self.assertIsInstance(app.screen, SshPrompt)
                        self.assertEqual(calls, [])
                        app.screen.query_one("#ssh-password", Input).value = "ssh-secret"
                        await pilot.click("#ssh-continue")
                        await pilot.pause(0.5)
            finally:
                app_module.run_script = original
            self.assertEqual(calls, ["test-connection.sh"])


class SshAuthTests(unittest.TestCase):
    def test_the_password_lives_only_in_the_askpass_file(self) -> None:
        from labkit.ssh_auth import start_ssh_session

        session = start_ssh_session("ssh-secret")
        self.assertIsNotNone(session)
        assert session is not None
        try:
            self.assertNotIn("ssh-secret", " ".join(session.env.values()))
            askpass = Path(session.env["SSH_ASKPASS"])
            self.assertEqual(askpass.stat().st_mode & 0o777, 0o700)
            completed = subprocess.run([str(askpass)], capture_output=True, text=True, check=False)
            self.assertEqual(completed.stdout, "ssh-secret\n")
        finally:
            session.stop()
        self.assertFalse(askpass.exists())

    def test_login_error_names_a_rejected_password(self) -> None:
        from labkit.ssh_auth import login_error, start_ssh_session

        session = start_ssh_session("ssh-secret")
        self.assertIsNotNone(session)
        assert session is not None
        try:
            with tempfile.TemporaryDirectory() as tmp:
                binary = Path(tmp) / "ssh"
                binary.write_text(
                    "#!/bin/sh\nprintf '%s\\n' 'Permission denied (publickey,password).' >&2\nexit 255\n",
                    encoding="utf-8",
                )
                binary.chmod(0o755)
                old = os.environ.get("PATH", "")
                os.environ["PATH"] = f"{tmp}:{old}"
                try:
                    self.assertEqual(
                        login_error(session, "root", "pve.example", "22"),
                        "Password was not accepted.",
                    )
                finally:
                    os.environ["PATH"] = old
        finally:
            session.stop()


class GuestAgentTests(unittest.TestCase):
    def test_server_2025_driver_directory_wins(self) -> None:
        script = Path(__file__).resolve().parents[2] / "scripts" / "hypervisors" / "proxmox" / "guest-agent.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel in ("vioser/w11/amd64", "vioserial/w11/amd64", "vioserial/2k25/amd64"):
                (root / rel).mkdir(parents=True)
            (root / "vioser/w11/amd64/vioser.inf").write_text("legacy\n", encoding="utf-8")
            (root / "vioserial/w11/amd64/vioser.inf").write_text("", encoding="utf-8")
            (root / "vioserial/2k25/amd64/vioser.inf").write_text("server\n", encoding="utf-8")
            completed = subprocess.run(
                ["bash", "-c", f'source "{script}"; pve_ga_driver_rel "{root}"'],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "vioserial/2k25/amd64")

    def test_install_script_plants_the_agent_and_clears_autologon(self) -> None:
        text = (
            Path(__file__).resolve().parents[2]
            / "scripts"
            / "hypervisors"
            / "proxmox"
            / "install-guest-agent.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("qemu-ga-x86_64.msi", text)
        self.assertIn("vioser.inf", text)
        self.assertIn("AutoAdminLogon", text)
        self.assertIn("DefaultPassword", text)

    def test_each_stage_script_checks_the_virtio_iso_before_work(self) -> None:
        repo = Path(__file__).resolve().parents[2]
        for number in range(1, 7):
            text = (repo / "scripts" / f"phase{number}.sh").read_text(encoding="utf-8")
            self.assertIn("require_virtio_iso", text)
        with tempfile.TemporaryDirectory() as tmp:
            completed = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'source "{repo}/scripts/lib/config.sh"; HYPERVISOR=proxmox; PVE_VIRTIO_ISO=; require_virtio_iso',
                ],
                capture_output=True,
                text=True,
                check=False,
                cwd=tmp,
            )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("The run has not started.", completed.stderr)


class ClipboardTests(unittest.TestCase):
    def test_wayland_tools_read_and_write_the_desktop_clipboard(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "copied"
            paste = root / "wl-paste"
            copy = root / "wl-copy"
            paste.write_text("#!/bin/sh\nprintf '%s' 'pve.example:8006'\n", encoding="utf-8")
            copy.write_text(
                "#!/bin/sh\ncat > \"$CLIP_OUT\"\n",
                encoding="utf-8",
            )
            paste.chmod(0o755)
            copy.chmod(0o755)
            env = {
                "PATH": f"{root}:/usr/bin",
                "WAYLAND_DISPLAY": "wayland-test",
                "CLIP_OUT": str(out),
            }
            self.assertEqual(read_clipboard(environ=env), "pve.example:8006")
            self.assertTrue(write_clipboard("labkit@pve!labkit", environ=env))
            self.assertEqual(out.read_text(encoding="utf-8"), "labkit@pve!labkit")

    def test_kde_klipper_is_used_when_the_wayland_tools_are_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "copied"
            qdbus = root / "qdbus6"
            qdbus.write_text(
                "#!/bin/sh\n"
                "case \"$3\" in\n"
                "  *getClipboardContents*) printf '%s\\n' 'copied-host' ;;\n"
                "  *setClipboardContents*) printf '%s' \"$4\" > \"$CLIP_OUT\" ;;\n"
                "esac\n"
                "exit 0\n",
                encoding="utf-8",
            )
            qdbus.chmod(0o755)
            env = {"PATH": str(root), "CLIP_OUT": str(out), "WAYLAND_DISPLAY": "wayland-test"}
            self.assertEqual(read_clipboard(environ=env), "copied-host")
            self.assertTrue(write_clipboard("labkit@pve!labkit", environ=env))
            self.assertEqual(out.read_text(encoding="utf-8"), "labkit@pve!labkit")


class ClipboardUiTests(unittest.IsolatedAsyncioTestCase):
    async def test_ctrl_v_and_ctrl_c_use_the_desktop_clipboard(self) -> None:
        from unittest.mock import patch

        from textual.widgets import Input
        from textual.widgets.input import Selection

        from labkit.app import LabApp

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_dir = root / "config"
            config_dir.mkdir()
            text = "LAB_WORK_DIR=" + str(root / "work") + "\n"
            (config_dir / "lab.env").write_text(text, encoding="utf-8")
            (config_dir / "lab.env.example").write_text(text, encoding="utf-8")
            app = LabApp(load_config(root), [])
            async with app.run_test(size=(120, 40)) as pilot:
                field = app.query_one("#kit", Input)
                field.focus()
                field.value = ""
                with patch("labkit.app.read_clipboard", return_value="pasted-kit.zip"):
                    await pilot.press("ctrl+v")
                self.assertEqual(field.value, "pasted-kit.zip")
                field.selection = Selection(0, len(field.value))
                with patch("labkit.app.write_clipboard", return_value=True) as write:
                    await pilot.press("ctrl+c")
                write.assert_called_once_with("pasted-kit.zip")


class ImportPlanTests(unittest.TestCase):
    def test_keep_falls_back_when_the_uploads_do_not_fit_together(self) -> None:
        from labkit.import_plan import ImportPlanError, plan

        mode, message = plan(
            [("HYD-DC1.qcow2", 26), ("HYD-CM1.qcow2", 54)],
            import_free=60,
            disk_free=400,
            import_name="local",
            disk_name="local-lvm",
            keep=True,
        )
        self.assertEqual(mode, "delete")
        self.assertIn("removes each upload", message)

        mode, message = plan(
            [("HYD-DC1.qcow2", 26), ("HYD-CM1.qcow2", 54)],
            import_free=200,
            disk_free=400,
            import_name="local",
            disk_name="local-lvm",
            keep=True,
        )
        self.assertEqual(mode, "keep")
        self.assertIn("local", message)

        with self.assertRaises(ImportPlanError) as raised:
            plan(
                [("HYD-CM1.qcow2", 54)],
                import_free=40,
                disk_free=400,
                import_name="local",
                disk_name="local-lvm",
                keep=False,
            )
        self.assertIn("HYD-CM1.qcow2", str(raised.exception))

        with self.assertRaises(ImportPlanError) as raised:
            plan(
                [("HYD-DC1.qcow2", 26), ("HYD-CM1.qcow2", 54)],
                import_free=200,
                disk_free=50,
                import_name="local",
                disk_name="local-lvm",
                keep=False,
            )
        self.assertIn("local-lvm", str(raised.exception))

    def test_import_directory_uses_the_storage_path_and_content_dirs(self) -> None:
        from labkit.import_plan import ImportPlanError, import_directory

        self.assertEqual(import_directory({"path": "/mnt/pve/share"}), "/mnt/pve/share/import")
        self.assertEqual(
            import_directory({"path": "/var/lib/vz", "content-dirs": "iso=template/iso,import=incoming"}),
            "/var/lib/vz/incoming",
        )
        with self.assertRaises(ImportPlanError):
            import_directory({"type": "lvmthin", "vgname": "pve"})
        with self.assertRaises(ImportPlanError):
            import_directory({"path": "/var/lib/vz", "content-dirs": "import=../secret"})


if __name__ == "__main__":
    unittest.main()
