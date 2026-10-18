"""Tests for gx_windows_vm.py. Every test is isolated from Docker, processes and kernel slots:
IsolatedTestCase makes any unmocked subprocess call, docker CLI lookup or gx_slots acquisition fail
the test, and fakes use a docker path that does not exist."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import struct
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_windows_vm as vm

MISSING_DOCKER = str(Path(tempfile.gettempdir()) / "gx-no-such-docker" / "docker.exe")
# HMP transcripts as QEMU's monitor socket returns them: banner, echoed prompt, CRLF.
BANNER = "QEMU 9.2.0 monitor - type 'help' for more information\r\n(qemu) info mice\r\n"
ABSOLUTE_MICE = BANNER + "  Mouse #0: QEMU PS/2 Mouse\r\n* Mouse #2: QEMU HID Tablet (absolute)\r\n(qemu) "
RELATIVE_MICE = BANNER + "* Mouse #0: QEMU PS/2 Mouse\r\n  Mouse #2: QEMU HID Tablet (absolute)\r\n(qemu) "


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

    def __init__(self, inspect=None, root=None, mice=None):
        super().__init__(MISSING_DOCKER, runner=self.fake, root=root)
        self.calls = []
        self.inspect = inspect
        # HMP "info mice" answers, consumed in order; none means no mouse is reported.
        self.mice = list(mice or [])

    def fake(self, argv, input=None, capture_output=True, text=True, timeout=None):
        assert argv[0] == MISSING_DOCKER
        self.calls.append((argv[1:], input))
        if argv[1] == "inspect":
            if self.inspect is None:
                return subprocess.CompletedProcess(argv, 1, "", "No such container")
            return subprocess.CompletedProcess(argv, 0, json.dumps([self.inspect]), "")
        if argv[1] == "exec" and input == "info mice\n":
            return subprocess.CompletedProcess(argv, 0, self.mice.pop(0) if self.mice else "", "")
        if argv[1:3] == ["image", "inspect"] or argv[1] in ("exec", "compose"):
            return subprocess.CompletedProcess(argv, 0, "" if text else b"", "" if text else b"")
        if argv[1] == "rm":
            return subprocess.CompletedProcess(argv, 0, "", "")
        raise AssertionError(f"unexpected docker command {argv[1:]}")


def payload(root, version="win11", *, running=True, owner=vm.OWNER, image=vm.IMAGE, config_file=None,
            storage=None, uuid=None, project=None, without_uuid=False, extra_mounts=()):
    expected = vm.expected_binding(root, version)
    mounts = [{"Type": "bind", "Source": str(source), "Destination": destination}
              for destination, source in expected["mounts"].items()]
    if storage is not None:
        mounts = [dict(item, Source=str(storage)) if item["Destination"] == "/storage" else item for item in mounts]
    env = ["PASSWORD=never-shown", "HOST=" + expected["machine"]["host"]]
    if not without_uuid:
        env.insert(1, "UUID=" + (uuid or expected["machine"]["uuid"]))
    return {"Id": "71c3496b2aaa165eb663ee394a3455ef951621418ef22d617f9209c238b3f710",
            "Config": {"Image": image,
                       "Labels": {"gx.owner": owner, "com.docker.compose.project": project or vm.container_name(version),
                                  "com.docker.compose.project.config_files": str(config_file or expected["config_file"]),
                                  "com.docker.compose.project.working_dir": str(expected["working_dir"])},
                       "Env": env},
            "Mounts": mounts + list(extra_mounts),
            "State": {"Running": running, "Status": "running" if running else "exited", "ExitCode": 0}}

FULL_ID = "71c3496b2aaa165eb663ee394a3455ef951621418ef22d617f9209c238b3f710"


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

    def up_win10(self, inspect, replace=None, dry_run=False):
        """up for win10 against a fake container; returns (result, docker, popen mock)."""
        self.slots.acquire.side_effect = None
        docker = FakeDocker(inspect, root=self.root)
        with mock.patch.object(subprocess, "Popen") as popen, mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            popen.return_value.wait.return_value = 0
            popen.return_value.pid = 4321
            result = vm.up(self.root, "win10", docker, self.root / "log", 0, replace, dry_run=dry_run)
        return result, docker, popen, stdout.getvalue()

    def test_pre_machine_container_reports_project_and_missing_uuid(self):
        # The live Win10 container was created by "docker compose up" in its directory (project
        # "win10") before machine.json existed, so it carries no UUID.
        vm.prepare(self.root)
        errors = vm.binding_errors(payload(self.root, "win10", project="win10", without_uuid=True), self.root, "win10")
        self.assertEqual(errors, ["compose project differs", "SMBIOS UUID differs from machine.json"])
        self.assertNotIn("never-shown", json.dumps(errors))

    def test_up_rebinds_a_foreign_project_container_by_removing_exactly_it_first(self):
        vm.prepare(self.root)
        foreign = payload(self.root, "win10", running=False, project="win10", without_uuid=True)
        result, docker, popen, out = self.up_win10(foreign, FULL_ID[:12])
        self.assertEqual(result, 0)
        removals = [call[0] for call in docker.calls if call[0][0] == "rm"]
        self.assertEqual(removals, [["rm", FULL_ID]])
        argv = popen.call_args.args[0]
        self.assertIn("never", argv)
        self.assertNotIn("--force-recreate", argv)
        self.assertNotIn("--no-recreate", argv)
        self.assertEqual(argv[argv.index("-p") + 1], "gx-ghostty-win10")
        event = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(event["mode"], "rebind")
        self.assertTrue(event["replace"]["removed_before_create"])
        self.assertEqual(event["replace"]["replaced_container"], FULL_ID)

    def test_same_project_uuid_change_is_a_plain_replace_without_removal(self):
        vm.prepare(self.root)
        stale = payload(self.root, "win10", running=False, uuid="64a9cf19-6e00-44df-8579-58620db1ab2e")
        _, docker, popen, _ = self.up_win10(stale, FULL_ID[:12])
        self.assertFalse([call for call in docker.calls if call[0][0] == "rm"])
        self.assertIn("--force-recreate", popen.call_args.args[0])

    def test_rebind_needs_the_exact_id_of_a_stopped_owned_container(self):
        vm.prepare(self.root)
        for inspect, replace, message in (
                (payload(self.root, "win10", running=False, project="win10", without_uuid=True), None, "does not match"),
                (payload(self.root, "win10", running=False, project="win10", without_uuid=True), FULL_ID[:8], "does not match"),
                (payload(self.root, "win10", running=False, project="win10", without_uuid=True), "deadbeefdead", "does not match"),
                (payload(self.root, "win10", running=False, project="win10", owner="other"), FULL_ID[:12], "does not match"),
                (payload(self.root, "win10", running=True, project="win10", without_uuid=True), FULL_ID[:12], "already running")):
            with self.subTest(replace=replace, message=message), self.assertRaisesRegex(vm.VmError, message):
                self.up_win10(inspect, replace)

    def test_replace_refuses_containers_with_non_bind_mounts(self):
        vm.prepare(self.root)
        volume = {"Type": "volume", "Name": "x", "Source": "/var/lib/docker/volumes/x", "Destination": "/data"}
        inspect = payload(self.root, "win10", running=False, project="win10", without_uuid=True, extra_mounts=[volume])
        self.slots.acquire.side_effect = None
        docker = FakeDocker(inspect, root=self.root)
        with self.assertRaisesRegex(vm.VmError, "non-bind mounts"):
            vm.up(self.root, "win10", docker, self.root / "log", 0, FULL_ID[:12])
        self.assertFalse([call for call in docker.calls if call[0][0] in ("rm", "compose")])

    def test_dry_run_reports_the_rebind_plan_without_slot_removal_or_compose(self):
        vm.prepare(self.root)
        foreign = payload(self.root, "win10", running=False, project="win10", without_uuid=True)
        docker = FakeDocker(foreign, root=self.root)
        with mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(vm.up(self.root, "win10", docker, self.root / "log", 0, FULL_ID[:12], dry_run=True), 0)
        plan = json.loads(stdout.getvalue())
        self.assertEqual((plan["mode"], plan["remove_container"], plan["dry_run"]), ("rebind", FULL_ID, True))
        self.assertEqual(plan["machine"], vm.machine_identity(self.root, "win10"))
        self.assertFalse(plan["disk"]["exists"])
        self.assertEqual(plan["running_owned_vms"], [])
        self.slots.acquire.assert_not_called()
        self.assertFalse([call for call in docker.calls if call[0][0] in ("rm", "compose", "image")])
        self.assertFalse((self.root / "log").exists())

    def test_dry_run_cli_needs_no_log_and_touches_nothing(self):
        vm.prepare(self.root)
        (self.root / "win10" / "storage" / "data.qcow2").write_bytes(b"qcow")
        docker = FakeDocker(payload(self.root, "win10", running=False, project="win10", without_uuid=True), root=self.root)
        argv = ["gx_windows_vm.py", "up", "--root", str(self.root), "--version", "win10",
                "--replace-container", FULL_ID[:12], "--dry-run"]
        with mock.patch.object(vm, "docker_executable", return_value=MISSING_DOCKER), \
                mock.patch.object(vm, "Docker", return_value=docker), mock.patch.object(sys, "argv", argv), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(vm.main(), 0)
        plan = json.loads(stdout.getvalue())
        self.assertEqual(plan["mode"], "rebind")
        self.assertEqual(plan["disk"]["size"], 4)
        self.slots.acquire.assert_not_called()
        self.assertFalse([call for call in docker.calls if call[0][0] in ("rm", "compose")])

    def test_stop_refuses_unbound_container(self):
        vm.prepare(self.root)
        docker = FakeDocker(payload(self.root, config_file=self.root / "x" / "compose.yaml"), root=self.root)
        with self.assertRaisesRegex(vm.VmError, "not bound"):
            vm.stop(self.root, "win11", docker)
        self.assertFalse(any(call[0][0] == "compose" for call in docker.calls))
        docker = FakeDocker(payload(self.root, running=True), root=self.root)
        vm.stop(self.root, "win11", docker)
        self.assertTrue(any(call[0][:1] == ["compose"] and "stop" in call[0] for call in docker.calls))

    def test_drag_holds_the_button_until_release_at_the_target(self):
        events = vm.vnc_drag_events(100, 200, 400, 260, steps=3, hold_ms=300)
        pointer = [event for event in events if event[0] == "p"]
        self.assertEqual(pointer[0], ["p", 100, 200, 0])
        self.assertEqual(pointer[1], ["p", 100, 200, 1])
        held = pointer[2:-1]
        self.assertEqual(len(held), 3)
        self.assertTrue(all(event[3] == 1 for event in held))
        self.assertNotEqual(held[0][1:3], [100, 200])
        self.assertEqual(held[-1], ["p", 400, 260, 1])
        self.assertEqual(pointer[-1], ["p", 400, 260, 0])
        self.assertIn(["s", 0.3], events)
        right = [event for event in vm.vnc_drag_events(5, 5, 50, 5, "right", 2, 0) if event[0] == "p"]
        self.assertEqual([event[3] for event in right], [0, 4, 4, 4, 0])

    def test_drag_rejects_invalid_arguments_before_any_input(self):
        for args in ((10, 10, 10, 10), (10, 10, 20, 20, "left", 1), (10, 10, 20, 20, "left", 61),
                     (10, 10, 20, 20, "left", 12, -1), (10, 10, 20, 20, "left", 12, 5001),
                     (-1, 10, 20, 20), (10, 10, 65536, 20), (10, 10, 20, 20, "x1")):
            with self.subTest(args=args), self.assertRaises(vm.VmError):
                vm.vnc_drag_events(*args)

    def test_drag_keeps_the_owned_running_container_guard(self):
        vm.prepare(self.root)
        for inspect in (payload(self.root, running=False), payload(self.root, owner="someone-else"), None):
            docker = FakeDocker(inspect, root=self.root)
            with self.subTest(inspect=bool(inspect)), self.assertRaises(vm.VmError):
                vm.vnc_drag(docker, "win11", 10, 10, 200, 20)
            self.assertFalse([call for call in docker.calls if call[0][0] == "exec"])
        with mock.patch.object(vm, "vnc_send", return_value={"width": 1280, "height": 800}) as send:
            docker = FakeDocker(payload(self.root), root=self.root, mice=[ABSOLUTE_MICE, ABSOLUTE_MICE])
            self.assertEqual(vm.vnc_drag(docker, "win11", 10, 10, 200, 20, steps=4)["screen"]["width"], 1280)
            self.assertEqual(send.call_args.args[2], vm.vnc_drag_events(10, 10, 200, 20, steps=4))

    def test_drag_cli_validates_before_touching_docker(self):
        argv = ["gx_windows_vm.py", "drag", "--root", str(self.root), "--x", "10", "--y", "10", "--to-x", "50"]
        with mock.patch.object(vm, "docker_executable", return_value=MISSING_DOCKER), \
                mock.patch.object(sys, "argv", argv), mock.patch("sys.stderr") as stderr, \
                self.assertRaises(SystemExit) as raised:
            vm.main()
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("--to-y", "".join(call.args[0] for call in stderr.write.call_args_list))
        argv += ["--to-y", "10", "--steps", "1"]
        with mock.patch.object(vm, "docker_executable", return_value=MISSING_DOCKER), \
                mock.patch.object(sys, "argv", argv), mock.patch("sys.stderr"), \
                self.assertRaises(SystemExit) as raised:
            vm.main()
        self.assertEqual(raised.exception.code, 1)

    def test_info_mice_names_the_device_that_receives_vnc_pointer_input(self):
        mice = vm.parse_mice(ABSOLUTE_MICE)
        self.assertEqual(mice, [
            {"index": 0, "name": "QEMU PS/2 Mouse", "absolute": False, "current": False},
            {"index": 2, "name": "QEMU HID Tablet", "absolute": True, "current": True}])
        self.assertEqual([mouse["current"] for mouse in vm.parse_mice(RELATIVE_MICE)], [True, False])
        self.assertEqual(vm.parse_mice(BANNER + "No mouse devices connected\r\n(qemu) "), [])
        vm.prepare(self.root)
        mode = vm.pointer_mode(FakeDocker(payload(self.root), root=self.root, mice=[ABSOLUTE_MICE]), "win11")
        self.assertTrue(mode["absolute"])
        self.assertEqual(mode["current"]["name"], "QEMU HID Tablet")
        mode = vm.pointer_mode(FakeDocker(payload(self.root), root=self.root, mice=[RELATIVE_MICE]), "win11")
        self.assertFalse(mode["absolute"])
        self.assertEqual(mode["current"]["name"], "QEMU PS/2 Mouse")

    def test_relative_or_unknown_mouse_refuses_click_and_drag_before_any_vnc_input(self):
        vm.prepare(self.root)
        for mice in ([RELATIVE_MICE], [BANNER + "No mouse devices connected\r\n"], [],
                     [ABSOLUTE_MICE.replace("  Mouse #0", "* Mouse #0")]):
            for action in (lambda docker: vm.vnc_click(docker, "win11", 842, 776, "right"),
                           lambda docker: vm.vnc_drag(docker, "win11", 10, 10, 200, 20)):
                docker = FakeDocker(payload(self.root), root=self.root, mice=mice)
                with self.subTest(mice=mice), self.assertRaisesRegex(vm.VmError, "not absolute.*nothing was sent"):
                    action(docker)
                self.assertFalse([call for call in docker.calls if "python3" in call[0]])

    def test_absolute_click_keeps_its_events_and_reports_the_mode_before_and_after(self):
        vm.prepare(self.root)
        docker = FakeDocker(payload(self.root), root=self.root, mice=[ABSOLUTE_MICE, ABSOLUTE_MICE])
        with mock.patch.object(vm, "vnc_send", return_value={"width": 1280, "height": 800}) as send:
            result = vm.vnc_click(docker, "win11", 842, 776, "right")
        self.assertEqual(send.call_args.args[2], [["p", 842, 776, 0], ["s", 0.15], ["p", 842, 776, 4], ["s", 0.08],
                                                  ["p", 842, 776, 0], ["s", 0.08]])
        self.assertEqual(result["screen"], {"width": 1280, "height": 800})
        for moment in ("before", "after"):
            self.assertTrue(result["pointer"][moment]["absolute"])
            self.assertEqual(result["pointer"][moment]["current"]["name"], "QEMU HID Tablet")
        hmp_inputs = [call[1] for call in docker.calls if call[0][:1] == ["exec"]]
        self.assertEqual(hmp_inputs, ["info mice\n", "info mice\n"])

    def test_mouse_that_turns_relative_during_the_send_is_reported_as_unverified(self):
        vm.prepare(self.root)
        docker = FakeDocker(payload(self.root), root=self.root, mice=[ABSOLUTE_MICE, RELATIVE_MICE])
        with mock.patch.object(vm, "vnc_send", return_value={"width": 1280, "height": 800}) as send, \
                self.assertRaisesRegex(vm.VmError, "unverified"):
            vm.vnc_click(docker, "win11", 10, 10)
        send.assert_called_once()

    def test_click_rejects_invalid_arguments_before_any_input(self):
        for args in ((-1, 10), (10, 65536), (10, 10, "x1"), (10, 10, "left", 0), (10, 10, "left", 4)):
            with self.subTest(args=args), self.assertRaises(vm.VmError):
                vm.vnc_click_events(*args)
        double = [event for event in vm.vnc_click_events(3, 4, "middle", 2) if event[0] == "p"]
        self.assertEqual([event[3] for event in double], [0, 2, 0, 2, 0])

    def run_vnc_client(self, events, width=1280, height=800):
        """Run the in-container VNC client source against an in-memory RFB 3.8 server."""
        server = io.BytesIO(b"RFB 003.008\n" + bytes([1, 1]) + struct.pack(">I", 0) + struct.pack(">HH", width, height)
                            + bytes(16) + struct.pack(">I", 2) + b"vm")
        sent = []
        connection = mock.MagicMock()
        connection.recv.side_effect = lambda size: server.read(size)
        connection.sendall.side_effect = sent.append
        fake_socket = mock.MagicMock()
        fake_socket.create_connection.return_value = connection
        with mock.patch.dict(sys.modules, {"socket": fake_socket}), \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(events))), \
                mock.patch("time.sleep"), mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            try:
                exec(compile(vm.VNC_CLIENT, "vnc_client", "exec"), {})
            except SystemExit as exc:
                return sent, None, str(exc)
        return sent, json.loads(stdout.getvalue()), None

    def test_vnc_client_sends_rfb_pointer_events_only_inside_the_screen(self):
        handshake = [b"RFB 003.008\n", b"\x01", b"\x01"]
        sent, screen, error = self.run_vnc_client([["p", 842, 776, 4], ["p", 1279, 799, 0]])
        self.assertIsNone(error)
        self.assertEqual(screen, {"width": 1280, "height": 800})
        self.assertEqual(sent, handshake + [bytes.fromhex("0504034a0308"), bytes.fromhex("050004ff031f")])
        for outside in (["p", 1280, 10, 0], ["p", 10, 800, 1]):
            sent, screen, error = self.run_vnc_client([["p", 10, 10, 0], outside])
            self.assertIn("outside the 1280x800 VNC screen", error)
            self.assertEqual(sent, handshake)
        sent, screen, error = self.run_vnc_client([["k", 0x41, 1], ["k", 0x41, 0]], width=1, height=1)
        self.assertIsNone(error)
        self.assertEqual(sent[3:], [struct.pack(">BBxxI", 4, 1, 0x41), struct.pack(">BBxxI", 4, 0, 0x41)])

    def test_pointer_cli_reports_the_mode_and_fails_when_relative(self):
        for mice, code in ((ABSOLUTE_MICE, 0), (RELATIVE_MICE, 1)):
            vm.prepare(self.root)
            docker = FakeDocker(payload(self.root), root=self.root, mice=[mice])
            argv = ["gx_windows_vm.py", "pointer", "--root", str(self.root)]
            with mock.patch.object(vm, "docker_executable", return_value=MISSING_DOCKER), \
                    mock.patch.object(vm, "Docker", return_value=docker), mock.patch.object(sys, "argv", argv), \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
                self.assertEqual(vm.main(), code)
            self.assertEqual(json.loads(stdout.getvalue())["absolute"], code == 0)


def windows_powershell() -> str | None:
    """Windows PowerShell 5.1, the guest's interpreter for gx_vm_validation.ps1 (None elsewhere)."""
    root = os.environ.get("SystemRoot")
    if os.name != "nt" or not root:
        return None
    path = Path(root) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    return str(path) if path.is_file() else None


# Loads named functions and $script: assignments of the fixture through the PowerShell parser
# (the fixture's own body runs the VM identity guard, so it is never executed here), then runs
# the test body. Output is the body's JSON on stdout.
PS_HARNESS = r"""
param([string]$Fixture, [string]$Work, [string]$Functions, [string]$Variables)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Fixture, [ref]$tokens, [ref]$errors)
if (@($errors).Count -gt 0) { throw ('parse errors: ' + (@($errors | ForEach-Object { $_.Message + ' @' + $_.Extent.StartLineNumber }) -join '; ')) }
$wanted = @($Functions.Split(',') | Where-Object { $_ })
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $node.Name) { . ([scriptblock]::Create($node.Extent.Text)) }
}
$names = @($Variables.Split(',') | Where-Object { $_ } | ForEach-Object { '$script:' + $_ })
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $false)) {
    if ($names -contains $node.Left.Extent.Text) { . ([scriptblock]::Create($node.Extent.Text)) }
}
. (Join-Path $Work 'body.ps1')
"""


@unittest.skipUnless(windows_powershell(), "needs Windows PowerShell 5.1")
class ValidationScriptTests(unittest.TestCase):
    """Runs pieces of the guest fixture under the guest's interpreter (Windows PowerShell 5.1)."""

    def run_body(self, body: str, functions: tuple[str, ...], variables: tuple[str, ...] = ("LF",),
                 timeout: float = 120) -> dict:
        with tempfile.TemporaryDirectory() as name:
            work = Path(name)
            (work / "harness.ps1").write_text(PS_HARNESS, encoding="utf-8-sig")
            (work / "body.ps1").write_text(body, encoding="utf-8-sig")
            command = [windows_powershell(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                       "-File", str(work / "harness.ps1"), "-Fixture", str(vm.VALIDATION_SCRIPT), "-Work", str(work),
                       "-Functions", ",".join(functions), "-Variables", ",".join(variables)]
            result = subprocess.run(command, capture_output=True, timeout=timeout, cwd=work)
            output = result.stdout.decode("utf-8", "replace")
            self.assertEqual(result.returncode, 0, output + result.stderr.decode("utf-8", "replace"))
            return json.loads(output[output.index("{"):])

    def test_fixture_is_ascii_and_parses_without_errors(self):
        data = vm.VALIDATION_SCRIPT.read_bytes()
        # Windows PowerShell 5.1 reads a BOM-less script as ANSI: non-ASCII text must be built from [char].
        self.assertEqual([index for index, byte in enumerate(data) if byte > 127], [])
        self.assertEqual(self.run_body("[ordered]@{ ok=$true } | ConvertTo-Json -Compress", ()), {"ok": True})

    def test_report_json_is_bounded_plain_utf8_and_records_conversions(self):
        body = r"""
$log = Join-Path $Work 'app.log'
$zh = -join @([char]0x547D, [char]0x4EE4, [char]0x63D0, [char]0x793A, [char]0x7B26)
[IO.File]::WriteAllText($log, ('one' + [char]13 + [char]10 + 'two ' + $zh + [char]10), [Text.UTF8Encoding]::new($false))
Add-Type -TypeDefinition 'public class GxVmTestBad { public override string ToString() { throw new System.Exception("boom"); } }'
# Get-Content lines carry PSPath/PSDrive/PSProvider notes: the r6-x peer report hang.
$value = [ordered]@{ content=@(Get-Content -LiteralPath $log); tail=@(Read-TextLines $log | Select-Object -Last 20);
    bad=(New-Object GxVmTestBad); int_keys=@{ 7='seven' }; empty=@(); one=@('x'); zh=$zh;
    custom=[pscustomobject]@{ a=1; b=@(1, 2) } }
$clock = [Diagnostics.Stopwatch]::StartNew()
Write-Json (Join-Path $Work 'report.json') $value
$bytes = [IO.File]::ReadAllBytes((Join-Path $Work 'report.json'))
[ordered]@{ ms=$clock.ElapsedMilliseconds; bom=($bytes[0] -eq 0xEF); report=[Text.Encoding]::UTF8.GetString($bytes); errors=$script:JsonErrors.Count } | ConvertTo-Json -Compress
"""
        out = self.run_body(body, ("ConvertTo-JsonText", "Get-SafeText", "ConvertTo-GxJson", "Write-Json", "Read-TextLines"),
                            ("LF", "JsonErrors", "JsonSource"))
        self.assertLess(out["ms"], 20000)
        self.assertFalse(out["bom"])
        self.assertEqual(out["errors"], 0)
        report = json.loads(out["report"])
        self.assertEqual(len(report["content"]), 2)
        self.assertTrue(all(isinstance(line, str) for line in report["content"]))
        self.assertEqual(report["tail"], ["one", "two \u547d\u4ee4\u63d0\u793a\u7b26"])
        self.assertEqual(report["zh"], "\u547d\u4ee4\u63d0\u793a\u7b26")
        self.assertEqual(report["int_keys"], {"7": "seven"})
        self.assertEqual((report["empty"], report["one"]), ([], ["x"]))
        self.assertEqual(report["custom"], {"a": 1, "b": [1, 2]})
        self.assertEqual(report["bad"], "<GxVmTestBad>")
        self.assertTrue(any("ToString of GxVmTestBad failed: boom" in note for note in report["json_notes"]))

    def test_unserializable_value_still_writes_a_json_error_file(self):
        body = r"""
function ConvertTo-GxJson($Value) { throw 'serializer unavailable' }
Write-Json (Join-Path $Work 'r.json') ([ordered]@{ a=1 })
[ordered]@{ text=[IO.File]::ReadAllText((Join-Path $Work 'r.json')); errors=@($script:JsonErrors) } | ConvertTo-Json -Compress
"""
        out = self.run_body(body, ("ConvertTo-JsonText", "Get-SafeText", "Write-Json"), ("LF", "JsonErrors"))
        written = json.loads(out["text"])
        self.assertEqual(written["json_error"], "serializer unavailable")
        self.assertEqual(out["errors"], ["r.json: serializer unavailable"])

    def test_probe_errors_are_collected_without_stopping_the_step(self):
        body = r"""
$result = [ordered]@{}
try { throw 'first probe' } catch { Add-ProbeError $result 'first' $_ }
$result.second = 'still ran'
try { [void][IO.File]::ReadAllText((Join-Path $Work 'missing.txt')) } catch { Add-ProbeError $result 'third' $_ }
ConvertTo-GxJson $result -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "Add-ProbeError"), ("LF", "JsonSource"))
        self.assertEqual(out["second"], "still ran")
        self.assertEqual([item["probe"] for item in out["probe_errors"]], ["first", "third"])
        self.assertEqual(out["probe_errors"][0]["error"], "first probe")


if __name__ == "__main__":
    unittest.main()
