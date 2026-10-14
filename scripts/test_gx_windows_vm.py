"""Tests for gx_windows_vm.py. Every test is isolated from Docker, processes and kernel slots:
IsolatedTestCase makes any unmocked subprocess call, docker CLI lookup or gx_slots acquisition fail
the test, and fakes use a docker path that does not exist."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_windows_vm as vm

MISSING_DOCKER = str(Path(tempfile.gettempdir()) / "gx-no-such-docker" / "docker.exe")


def refuse(*args, **kwargs):
    raise AssertionError(f"unmocked external call in an isolated test: {args[:1]!r}")


class IsolatedTestCase(unittest.TestCase):
    def setUp(self):
        self.assertFalse(Path(MISSING_DOCKER).exists())
        for name in ("run", "Popen", "call", "check_call", "check_output"):
            self.start(mock.patch.object(subprocess, name, side_effect=refuse))
        self.start(mock.patch.object(vm, "docker_executable", side_effect=refuse))
        self.protect = self.start(mock.patch.object(vm, "protect_directory"))
        self.slots = mock.MagicMock()
        self.slots.acquire.side_effect = refuse
        self.start(mock.patch.dict(sys.modules, {"gx_slots": self.slots}))
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()

    def start(self, patcher):
        value = patcher.start()
        self.addCleanup(patcher.stop)
        return value


class FakeDocker(vm.Docker):
    """Answers inspect/exec from memory; never runs a real CLI."""

    def __init__(self, inspect=None, root=None):
        super().__init__(MISSING_DOCKER, runner=self.fake, root=root)
        self.calls = []
        self.inspect = inspect

    def fake(self, argv, input=None, capture_output=True, text=True, timeout=None):
        assert argv[0] == MISSING_DOCKER
        self.calls.append((argv[1:], input))
        if argv[1] == "inspect":
            if self.inspect is None:
                return subprocess.CompletedProcess(argv, 1, "", "No such container")
            return subprocess.CompletedProcess(argv, 0, json.dumps([self.inspect]), "")
        if argv[1:3] == ["image", "inspect"] or argv[1] in ("exec", "compose"):
            return subprocess.CompletedProcess(argv, 0, "" if text else b"", "" if text else b"")
        raise AssertionError(f"unexpected docker command {argv[1:]}")


def payload(root, version="win11", *, running=True, owner=vm.OWNER, image=vm.IMAGE, config_file=None,
            storage=None, uuid=None):
    expected = vm.expected_binding(root, version)
    mounts = [{"Type": "bind", "Source": str(source), "Destination": destination}
              for destination, source in expected["mounts"].items()]
    if storage is not None:
        mounts = [dict(item, Source=str(storage)) if item["Destination"] == "/storage" else item for item in mounts]
    return {"Id": "71c3496b2aaa165eb663ee394a3455ef951621418ef22d617f9209c238b3f710",
            "Config": {"Image": image,
                       "Labels": {"gx.owner": owner, "com.docker.compose.project": vm.container_name(version),
                                  "com.docker.compose.project.config_files": str(config_file or expected["config_file"]),
                                  "com.docker.compose.project.working_dir": str(expected["working_dir"])},
                       "Env": ["PASSWORD=never-shown", "UUID=" + (uuid or expected["machine"]["uuid"]),
                               "HOST=" + expected["machine"]["host"]]},
            "Mounts": mounts,
            "State": {"Running": running, "Status": "running" if running else "exited", "ExitCode": 0}}


class WindowsVmTests(IsolatedTestCase):
    def test_guard_fails_unmocked_process_and_docker(self):
        with self.assertRaisesRegex(AssertionError, "unmocked"):
            vm.Docker("docker").run("ps")
        with self.assertRaisesRegex(AssertionError, "unmocked"):
            vm.docker_executable()
        with self.assertRaisesRegex(AssertionError, "unmocked"):
            sys.modules["gx_slots"].acquire(vm.SLOTS, "heavy", 0)

    def test_stage_validation_binds_live_uuid_and_exact_fixture_hash(self):
        vm.prepare(self.root)
        machine = vm.machine_identity(self.root, "win11")
        destination = vm.stage_validation(self.root, "win11", machine["uuid"], "GX-WIN11")
        data = json.loads((destination / "validation-manifest.json").read_text())
        self.assertEqual(data["guest_uuid"], machine["uuid"])
        self.assertEqual(data["image"], vm.IMAGE)
        self.assertEqual(data["fixture_sha256"], hashlib.sha256(vm.VALIDATION_SCRIPT.read_bytes()).hexdigest())
        self.assertEqual((destination / vm.VALIDATION_SCRIPT.name).read_bytes(), vm.VALIDATION_SCRIPT.read_bytes())
        runner = (destination / vm.GUEST_RUNNER).read_text()
        self.assertIn("-ExecutionPolicy Bypass", runner)
        self.assertIn('-ExportDir "%GXSRC%out"', runner)
        original = (destination / "validation-manifest.json").read_bytes()
        with self.assertRaisesRegex(ValueError, "persisted machine identity"):
            vm.stage_validation(self.root, "win11", "64a9cf19-6e00-44df-8579-58620db1ab2e", "GX-WIN11")
        with self.assertRaisesRegex(ValueError, "nonzero"):
            vm.stage_validation(self.root, "win11", "00000000-0000-0000-0000-000000000000", "GX-WIN11")
        self.assertEqual((destination / "validation-manifest.json").read_bytes(), original)

    def test_media_rejects_corruption_and_truncation(self):
        path = self.root / "iso"
        path.write_bytes(b"good")
        spec = {"size": 4, "sha256": hashlib.sha256(b"good").hexdigest()}
        self.assertEqual(vm.verify_media(path, spec), spec["sha256"])
        path.write_bytes(b"evil")
        with self.assertRaisesRegex(ValueError, "SHA256"):
            vm.verify_media(path, spec)
        path.write_bytes(b"bad")
        with self.assertRaisesRegex(ValueError, "size"):
            vm.verify_media(path, spec)

    def test_prepare_is_idempotent_and_compose_is_exactly_generated(self):
        vm.prepare(self.root)
        self.protect.assert_called_with(self.root)
        first = (self.root / "win11" / "credentials.json").read_bytes()
        machine = (self.root / "win11" / "machine.json").read_bytes()
        vm.prepare(self.root)
        self.assertEqual(first, (self.root / "win11" / "credentials.json").read_bytes())
        self.assertEqual(machine, (self.root / "win11" / "machine.json").read_bytes())
        account = json.loads(first)
        uuids = set()
        for version, web in [("win11", 18006), ("win10", 18007)]:
            compose = (self.root / version / "compose.yaml").read_text()
            identity = vm.machine_identity(self.root, version)
            uuids.add(identity["uuid"])
            self.assertEqual(compose, vm.compose_text(version, identity))
            lines = compose.splitlines()
            self.assertIn(f"      UUID: '{identity['uuid']}'", lines)
            self.assertIn(f"      HOST: 'GX-{version.upper()}'", lines)
            self.assertIn(f"    image: {vm.IMAGE}", lines)
            self.assertIn(f"      - '127.0.0.1:{web}:8006'", lines)
            self.assertIn("    restart: 'no'", lines)
            self.assertNotIn(account["admin_password"], compose)
            self.assertNotIn(str(Path.home()), compose)
            setup = (self.root / version / "oem" / "setup-guest.ps1").read_text()
            self.assertIn("fDisableClip -Value 1", setup)
            self.assertIn("fDisableCdm -Value 1", setup)
        self.assertEqual(len(uuids), 2)

    def test_screenshot_png_round_trip(self):
        pixels = bytes(range(2 * 3 * 3))
        width, height, rgb = vm.parse_ppm(b"P6\n# c\n3 2\n255\n" + pixels)
        self.assertEqual((width, height, rgb), (3, 2, pixels))
        self.assertTrue(vm.png_bytes(width, height, rgb).startswith(b"\x89PNG\r\n\x1a\n"))
        with self.assertRaisesRegex(vm.VmError, "incomplete"):
            vm.parse_ppm(b"P6 3 2 255\n" + pixels[:-1])

    def test_key_translation_and_vnc_events(self):
        self.assertEqual(vm.text_keys("Ab:\\ 1"), ["shift-a", "b", "shift-semicolon", "backslash", "spc", "1"])
        with self.assertRaises(vm.VmError):
            vm.text_keys("\u00e9")
        events = vm.vnc_text_events("A\n")
        self.assertEqual(events[0], ["k", vm.SHIFT_KEYSYM, 1])
        self.assertIn(["k", 0xFF0D, 1], events)
        with self.assertRaises(vm.VmError):
            vm.vnc_text_events("\u00e9")

    def test_secret_travels_on_stdin_and_never_in_argv_or_output(self):
        vm.prepare(self.root)
        secret = json.loads((self.root / "win11" / "credentials.json").read_text())["admin_password"]
        docker = FakeDocker(payload(self.root), root=self.root)
        self.assertEqual(vm.type_secret(self.root, "win11", docker, "admin_password", True), len(secret))
        exec_calls = [call for call in docker.calls if call[0][0] == "exec"]
        self.assertTrue(exec_calls)
        for argv, stdin in exec_calls:
            self.assertNotIn(secret, " ".join(argv))
            self.assertIn(">/dev/null", argv[-1])
            self.assertNotIn(secret, stdin)
        with mock.patch.object(vm, "vnc_send") as send:
            self.assertEqual(vm.type_secret_vnc(self.root, "win11", docker, "admin_password", True), len(secret))
            self.assertTrue(all(secret not in " ".join(map(str, event)) for event in send.call_args.args[2]))
        with self.assertRaises(vm.VmError):
            vm.type_secret(self.root, "win11", docker, "not-a-field", False)

    def test_binding_detects_foreign_compose_mounts_and_uuid(self):
        vm.prepare(self.root)
        self.assertEqual(vm.binding_errors(payload(self.root), self.root, "win11"), [])
        temp_compose = self.root / "other" / "win11" / "compose.yaml"
        cases = {"another compose file": payload(self.root, config_file=temp_compose),
                 "/storage is not bound": payload(self.root, storage=self.root / "elsewhere"),
                 "SMBIOS UUID": payload(self.root, uuid="64a9cf19-6e00-44df-8579-58620db1ab2e"),
                 "owner label": payload(self.root, owner="someone-else"),
                 "pinned digest": payload(self.root, image="dockurr/windows:latest")}
        for reason, data in cases.items():
            errors = vm.binding_errors(data, self.root, "win11")
            self.assertTrue(any(reason in error for error in errors), (reason, errors))
            self.assertNotIn("never-shown", json.dumps(errors))
        with self.assertRaisesRegex(vm.VmError, "not bound to this VM root"):
            vm.require_running(FakeDocker(payload(self.root, config_file=temp_compose), root=self.root), "win11")
        with self.assertRaisesRegex(vm.VmError, "not running"):
            vm.require_running(FakeDocker(payload(self.root, running=False), root=self.root), "win11")
        with self.assertRaisesRegex(vm.VmError, "invalid QEMU key"):
            vm.send_keys(FakeDocker(payload(self.root), root=self.root), "win11", ["ret; quit"])

    def test_up_requires_exact_generated_compose(self):
        vm.prepare(self.root)
        compose = self.root / "win11" / "compose.yaml"
        text = compose.read_text()
        for broken in (text.replace("      UUID:", "      XUUID:"), text + "# extra\n",
                       text.replace("      UUID: '", "      UUID: 'f")):
            compose.write_text(broken)
            with self.assertRaisesRegex(vm.VmError, "generated pinned"):
                vm.up(self.root, "win11", FakeDocker(None, root=self.root), self.root / "log", 0)
        self.slots.acquire.assert_not_called()

    def run_up(self, inspect, replace=None):
        self.slots.acquire.side_effect = None
        docker = FakeDocker(inspect, root=self.root)
        with mock.patch.object(subprocess, "Popen") as popen:
            popen.return_value.wait.return_value = 0
            popen.return_value.pid = 1234
            try:
                result = vm.up(self.root, "win11", docker, self.root / "log", 0, replace)
            finally:
                self.assertEqual(self.slots.acquire.call_args.args[1], "heavy")
        argv = popen.call_args.args[0]
        self.assertEqual(argv[0], MISSING_DOCKER)
        self.assertIn("never", argv)
        return result, argv

    def test_up_reuses_only_matching_container_and_refuses_mismatch(self):
        vm.prepare(self.root)
        _, argv = self.run_up(payload(self.root, running=False))
        self.assertIn("--no-recreate", argv)
        _, argv = self.run_up(None)
        self.assertNotIn("--force-recreate", argv)
        foreign = payload(self.root, running=False, config_file=self.root / "tmp" / "win11" / "compose.yaml")
        with mock.patch.object(subprocess, "Popen") as popen:
            self.slots.acquire.side_effect = None
            for replace in (None, "71c3496b", "deadbeefdead"):
                with self.assertRaisesRegex(vm.VmError, "does not match this VM root"):
                    vm.up(self.root, "win11", FakeDocker(foreign, root=self.root), self.root / "log", 0, replace)
            running_foreign = dict(foreign, State={"Running": True})
            with self.assertRaisesRegex(vm.VmError, "already running"):
                vm.up(self.root, "win11", FakeDocker(running_foreign, root=self.root), self.root / "log", 0,
                      "71c3496b2aaa")
            popen.assert_not_called()
        _, argv = self.run_up(foreign, "71c3496b2aaa")
        self.assertIn("--force-recreate", argv)

    def test_stop_refuses_unbound_container(self):
        vm.prepare(self.root)
        docker = FakeDocker(payload(self.root, config_file=self.root / "x" / "compose.yaml"), root=self.root)
        with self.assertRaisesRegex(vm.VmError, "not bound"):
            vm.stop(self.root, "win11", docker)
        self.assertFalse(any(call[0][0] == "compose" for call in docker.calls))
        docker = FakeDocker(payload(self.root, running=True), root=self.root)
        vm.stop(self.root, "win11", docker)
        self.assertTrue(any(call[0][:1] == ["compose"] and "stop" in call[0] for call in docker.calls))


if __name__ == "__main__":
    unittest.main()
