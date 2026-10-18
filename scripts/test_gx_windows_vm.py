"""Tests for gx_windows_vm.py. Every test is isolated from Docker, processes and kernel slots:
IsolatedTestCase makes any unmocked subprocess call, docker CLI lookup or gx_slots acquisition fail
the test, and fakes use a docker path that does not exist."""
import ast
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import struct
import tempfile
import unittest
from unittest import mock
import zipfile

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
        self.slots.shared_root.return_value = Path("Z:/main-checkout/.local/kernel-slots")
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
            sys.modules["gx_slots"].acquire(self.root, "heavy", 0)

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

    def fake_python(self) -> tuple[Path, dict]:
        """A small zip standing in for the pinned embeddable package (size/SHA patched in)."""
        archive = self.root / "python-embed.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("python312._pth", "python312.zip\r\n.\r\n")
            bundle.writestr("python.exe", b"MZ fake")
        pinned = {"file": "python-3.12.10-embed-amd64.zip", "size": archive.stat().st_size,
                  "sha256": vm.sha256_file(archive)}
        return archive, pinned

    def test_stage_validation_stages_the_pinned_python_broker_fixture(self):
        vm.prepare(self.root)
        machine = vm.machine_identity(self.root, "win11")
        archive, pinned = self.fake_python()
        ole = self.root / "gx_ole_source.exe"
        ole.write_bytes(b"MZ ole source")
        with mock.patch.dict(vm.GUEST_PYTHON, pinned):
            destination = vm.stage_validation(self.root, "win11", machine["uuid"], "GX-WIN11", archive, ole)
        data = json.loads((destination / "validation-manifest.json").read_text())
        fixture = data["python_fixture"]
        self.assertEqual(fixture["python"]["sha256"], pinned["sha256"])
        self.assertEqual((destination / "py" / pinned["file"]).read_bytes(), archive.read_bytes())
        self.assertEqual(sorted(fixture["files"]), sorted(BROKER_CLOSURE))
        self.assertEqual(fixture["source"], {"ref": None, "commit": None, "kind": "working tree"})
        for relative, digest in fixture["files"].items():
            self.assertEqual(digest, vm.sha256_file(vm.ROOT / relative))
            self.assertEqual(vm.sha256_file(destination / "py" / relative), digest)
        tree = "\n".join(f"{name}={digest}" for name, digest in sorted(fixture["files"].items()))
        self.assertEqual(fixture["tree_sha256"], hashlib.sha256(tree.encode()).hexdigest())
        self.assertEqual(fixture["ole_source"]["sha256"], vm.sha256_file(ole))
        self.assertEqual((destination / "py" / vm.OLE_SOURCE_NAME).read_bytes(), ole.read_bytes())
        # Without the two inputs the stage carries no Python fixture (the guest phase refuses).
        destination = vm.stage_validation(self.root, "win11", machine["uuid"], "GX-WIN11")
        self.assertIsNone(json.loads((destination / "validation-manifest.json").read_text())["python_fixture"])

    def test_stage_validation_refuses_an_unpinned_python_before_writing(self):
        vm.prepare(self.root)
        machine = vm.machine_identity(self.root, "win11")
        archive, pinned = self.fake_python()
        ole = self.root / "gx_ole_source.exe"
        ole.write_bytes(b"MZ ole source")
        with self.assertRaisesRegex(ValueError, "not the pinned"):
            vm.stage_validation(self.root, "win11", machine["uuid"], "GX-WIN11", archive, ole)
        self.assertFalse((self.root / "win11" / "exchange" / "validation").exists())
        with self.assertRaisesRegex(ValueError, "together"):
            vm.stage_validation(self.root, "win11", machine["uuid"], "GX-WIN11", archive, None)
        with mock.patch.dict(vm.GUEST_PYTHON, pinned):
            ole.write_bytes(b"not an executable")
            with self.assertRaisesRegex(ValueError, "not a Windows executable"):
                vm.stage_validation(self.root, "win11", machine["uuid"], "GX-WIN11", archive, ole)

    def test_broker_fixture_closure_follows_repository_imports(self):
        self.assertEqual(sorted(vm.fixture_closure(vm.working_tree_reader)), sorted(BROKER_CLOSURE))
        # A fixture branch can import a module the working tree does not have yet.
        sources = {"test/windows/gx_drop_broker_fixture.py": b"import json\nfrom gx_boundary_controller import Native\n",
                   "test/windows/gx_boundary_controller.py": b"import gx_win_gui as gui\nimport os.path\n",
                   "scripts/gx_win_gui.py": b"from gx_drop_broker_fixture import x\n"}
        self.assertEqual(sorted(vm.fixture_closure(sources.get)), sorted(sources))
        with self.assertRaisesRegex(ValueError, "missing"):
            vm.fixture_closure({}.get)

    def test_stage_validation_takes_the_fixture_from_a_git_ref(self):
        vm.prepare(self.root)
        machine = vm.machine_identity(self.root, "win11")
        archive, pinned = self.fake_python()
        ole = self.root / "gx_ole_source.exe"
        ole.write_bytes(b"MZ ole source")
        sources = {"test/windows/gx_drop_broker_fixture.py": b"import gx_ole_fixture\n",
                   "test/windows/gx_ole_fixture.py": b"print('ref')\n"}
        reader = mock.Mock(side_effect=sources.get)
        reader.commit = "0123456789abcdef0123456789abcdef01234567"
        with mock.patch.dict(vm.GUEST_PYTHON, pinned), mock.patch.object(vm, "git_reader", return_value=reader) as git:
            destination = vm.stage_validation(self.root, "win11", machine["uuid"], "GX-WIN11", archive, ole, "wip/fixtures")
        git.assert_called_once_with("wip/fixtures")
        fixture = json.loads((destination / "validation-manifest.json").read_text())["python_fixture"]
        self.assertEqual(fixture["source"], {"ref": "wip/fixtures", "commit": reader.commit, "kind": "git"})
        self.assertEqual(sorted(fixture["files"]), sorted(sources))
        self.assertEqual((destination / "py" / "test" / "windows" / "gx_ole_fixture.py").read_bytes(), b"print('ref')\n")

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

    def test_queue_args_writes_one_quoted_line_for_gx_q(self):
        vm.prepare(self.root)
        machine = vm.machine_identity(self.root, "win11")
        with self.assertRaisesRegex(ValueError, "stage-validation first"):
            vm.queue_args(self.root, "win11", "tstat", ["-Phase", "dpi"])
        destination = vm.stage_validation(self.root, "win11", machine["uuid"], "GX-WIN11")
        runner = (destination / vm.QUEUE_RUNNER).read_text()
        self.assertIn('set /p GXARGS=<"%~dp0q\\%~1.txt"', runner)
        self.assertIn('call "%~dp0gx-run.cmd" %GXARGS%', runner)
        path = vm.queue_args(self.root, "win11", "brk-setup", ["-Phase", "py-fixture", "-PyArgs",
                                                               "setup --root {run}\\broker --exe {app}"])
        self.assertEqual(path, destination / "q" / "brk-setup.txt")
        self.assertEqual(path.read_bytes(), b'-Phase py-fixture -PyArgs "setup --root {run}\\broker --exe {app}"\r\n')
        for name, items in (("Bad", ["-Phase", "dpi"]), ("ok", ["-Phase", "a&b"]), ("ok", ["%PATH%"]),
                            ("ok", ["x" * 1001]), ("ok", ["\u4e2d"]), ("ok", [])):
            with self.assertRaises(ValueError):
                vm.queue_args(self.root, "win11", name, items)
        argv = ["gx_windows_vm.py", "queue-args", "--root", str(self.root), "--name", "tstat", "--",
                "-Phase", "toast-matrix", "-Action", "status", "-RunId", "o10-xa", "-DelaySeconds", "5"]
        with mock.patch.object(sys, "argv", argv), mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(vm.main(), 0)
        self.assertEqual(json.loads(stdout.getvalue())["line"],
                         "-Phase toast-matrix -Action status -RunId o10-xa -DelaySeconds 5")

    def test_queue_args_cli_preserves_literal_tail_after_host_options(self):
        destination = self.root / "win11" / "exchange" / "validation"
        destination.mkdir(parents=True)
        (destination / "validation-manifest.json").write_text("{}", encoding="utf-8")
        host = ["--root", str(self.root), "--name", "literal"]
        cases = [
            (["queue-args", *host], ["-Phase", "toast-matrix"], '-Phase toast-matrix'),
            ([*host, "queue-args"], ["a b", 'say "hi"', ""], '"a b" "say \\"hi\\"" ""'),
            (["queue-args", "prefix", *host], ["-Phase", "dpi"], 'prefix -Phase dpi'),
            (["queue-args", *host], ["--", "--root", "other", "--name", "other"],
             '-- --root other --name other'),
            (["queue-args", *host], ["$(whoami)", "`whoami`", "a;b"], '$(whoami) `whoami` a;b'),
        ]
        for head, tail, expected in cases:
            with self.subTest(head=head, tail=tail), \
                    mock.patch.object(sys, "argv", ["gx_windows_vm.py", *head, "--", *tail]), \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
                self.assertEqual(vm.main(), 0)
                self.assertEqual(json.loads(stdout.getvalue())["line"], expected)
                self.assertEqual((destination / "q" / "literal.txt").read_bytes(),
                                 (expected + "\r\n").encode("ascii"))
        self.assertEqual([path.name for path in (destination / "q").iterdir()], ["literal.txt"])

    def test_queue_args_cli_rejects_injection_and_unknown_host_options(self):
        destination = self.root / "win11" / "exchange" / "validation"
        destination.mkdir(parents=True)
        (destination / "validation-manifest.json").write_text("{}", encoding="utf-8")
        host = ["queue-args", "--root", str(self.root), "--name", "unsafe"]
        for value in ('a&b', '" & whoami & "', '%PATH%', '!PATH!', '^', '|', '<', '>',
                      'a\nb', 'a\rb', 'a\tb'):
            with self.subTest(value=value), \
                    mock.patch.object(sys, "argv", ["gx_windows_vm.py", *host, "--", value]), \
                    mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
                with self.assertRaises(SystemExit) as caught:
                    vm.main()
                self.assertEqual(caught.exception.code, 1)
                self.assertIn("without % ! ^ & | < > or control characters", stderr.getvalue())
        with mock.patch.object(sys, "argv", ["gx_windows_vm.py", *host, "--typo", "--", "safe"]), \
                mock.patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as caught:
                vm.main()
            self.assertEqual(caught.exception.code, 2)
        self.assertFalse((destination / "q").exists())

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

    def test_up_refuses_without_the_shared_slot_root(self):
        vm.prepare(self.root)
        self.slots.acquire.side_effect = None
        self.slots.shared_root = None
        docker = FakeDocker(None, root=self.root)
        with self.assertRaisesRegex(vm.VmError, "shared_root"):
            vm.up(self.root, "win11", docker, self.root / "log", 0)
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
                # The shared root from git's common directory, never this checkout's .local.
                self.assertEqual(self.slots.acquire.call_args.args[0], Path("Z:/main-checkout/.local/kernel-slots"))
                self.assertNotEqual(self.slots.acquire.call_args.args[0], vm.ROOT / ".local" / "kernel-slots")
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


BROKER_CLOSURE = ("test/windows/gx_drop_broker_fixture.py", "test/windows/gx_ole_fixture.py",
                  "test/windows/gx_fixture_evidence.py", "scripts/gx_win_gui.py", "scripts/gx_slots.py",
                  "scripts/gx_win_uia.py",
                  # The broker's Native controller also imports its lazy action
                  # backends and language/session helpers after A3 integration.
                  "test/windows/gx_boundary_controller.py", "test/windows/gx_boundary_ipc.py",
                  "test/windows/gx_boundary_ole.py", "test/windows/gx_boundary_remote.py",
                  "test/windows/gx_boundary_uia.py", "test/windows/gx_input_language.py",
                  "test/windows/gx_session_ipc_fixture.py")


class FixtureDependencyTests(unittest.TestCase):
    """Real files and local Git only; never invoke the staged GUI fixtures."""

    def test_real_ref_dependency_is_staged_hashed_and_required(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            repo = root / "repo"
            repo.mkdir()
            # Copy real sources, not an import-only mock closure.
            for folder in vm.FIXTURE_FOLDERS:
                for source in (vm.ROOT / folder).glob("gx_*.py"):
                    target = repo / folder / source.name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.read_bytes())
            def git(*args):
                result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True)
                return result.stdout.decode().strip()
            git("init", "-q")
            git("add", "scripts", "test")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
            commit = git("rev-parse", "HEAD")
            dependency = "scripts/gx_win_uia.py"
            frozen = subprocess.run(["git", "-C", str(repo), "show", f"{commit}:{dependency}"],
                                    capture_output=True, check=True).stdout
            (repo / dependency).write_text("raise RuntimeError('working tree must not be used')\n")
            archive = root / "python.zip"
            archive.write_bytes(b"pinned test archive")
            ole = root / "ole.exe"
            ole.write_bytes(b"MZ test")
            destination = root / "stage"
            destination.mkdir()
            with mock.patch.object(vm, "ROOT", repo), mock.patch.dict(vm.GUEST_PYTHON, {
                    "size": archive.stat().st_size, "sha256": vm.sha256_file(archive)}):
                manifest = vm.stage_python_fixture(destination, archive, ole, commit)
                self.assertIn(dependency, manifest["files"])
                self.assertEqual((destination / "py" / dependency).read_bytes(), frozen)
                self.assertEqual(manifest["files"][dependency], hashlib.sha256(frozen).hexdigest())
                tree = "\n".join(f"{p}={h}" for p, h in sorted(manifest["files"].items()))
                self.assertEqual(manifest["tree_sha256"], hashlib.sha256(tree.encode()).hexdigest())
                evidence = destination / "py/test/windows/gx_fixture_evidence.py"
                spec = importlib.util.spec_from_file_location("staged_evidence", evidence)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                # Newer fixture refs have the path-based source_manifest contract.
                if hasattr(module, "source_manifest"):
                    self.assertEqual(module.source_manifest()[dependency], manifest["files"][dependency])
                git("rm", "-f", dependency)
                git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "missing dependency")
                with self.assertRaisesRegex(ValueError, "gx_win_uia.py.*missing"):
                    vm.stage_python_fixture(destination, archive, ole, "HEAD")


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
$global:LASTEXITCODE = 0
. (Join-Path $Work 'body.ps1')
exit $LASTEXITCODE
"""


@unittest.skipUnless(windows_powershell(), "needs Windows PowerShell 5.1")
class ValidationScriptTests(unittest.TestCase):
    """Runs pieces of the guest fixture under the guest's interpreter (Windows PowerShell 5.1)."""

    def run_body(self, body: str, functions: tuple[str, ...], variables: tuple[str, ...] = ("LF",),
                 timeout: float = 120, expected_exit: int = 0) -> dict:
        with tempfile.TemporaryDirectory() as name:
            work = Path(name)
            (work / "harness.ps1").write_text(PS_HARNESS, encoding="utf-8-sig")
            (work / "body.ps1").write_text(body, encoding="utf-8-sig")
            command = [windows_powershell(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                       "-File", str(work / "harness.ps1"), "-Fixture", str(vm.VALIDATION_SCRIPT), "-Work", str(work),
                       "-Functions", ",".join(functions), "-Variables", ",".join(variables)]
            # A PSModulePath inherited from PowerShell 7 hides 5.1's own modules (Get-FileHash).
            environment = {key: value for key, value in os.environ.items() if key.upper() != "PSMODULEPATH"}
            result = subprocess.run(command, capture_output=True, timeout=timeout, cwd=work, env=environment)
            output = result.stdout.decode("utf-8", "replace")
            self.assertEqual(result.returncode, expected_exit, output + result.stderr.decode("utf-8", "replace"))
            return json.loads(output[output.index("{"):])

    def test_fixture_is_ascii_and_parses_without_errors(self):
        data = vm.VALIDATION_SCRIPT.read_bytes()
        # Windows PowerShell 5.1 reads a BOM-less script as ANSI: non-ASCII text must be built from [char].
        self.assertEqual([index for index, byte in enumerate(data) if byte > 127], [])
        self.assertEqual(self.run_body("[ordered]@{ ok=$true } | ConvertTo-Json -Compress", ()), {"ok": True})

    def test_split_tokens_accept_pair_and_reject_legacy_and_mixed_records(self):
        body = r"""
$medium = [pscustomobject]@{ sid='s'; session_id=1; integrity='medium'; elevated=$false; elevation_type='Limited'; logon_id='m'; linked=[pscustomobject]@{ logon_id='h' } }
$high = [pscustomobject]@{ sid='s'; session_id=1; integrity='high'; elevated=$true; elevation_type='Full'; logon_id='h'; linked=[pscustomobject]@{ logon_id='m' } }
$old = [pscustomobject]@{ sid='s'; session_id=1; integrity='high'; elevated=$true; elevation_type='Default'; logon_id='old' }
$nullLink = $medium | ConvertTo-Json | ConvertFrom-Json
$nullLink.linked = $null
$brokenLink = $medium | ConvertTo-Json | ConvertFrom-Json
$brokenLink.linked = [pscustomobject]@{}
$nativeMedium = @{}; foreach ($p in $medium.PSObject.Properties) { $nativeMedium[$p.Name] = $p.Value }
$nativeHigh = @{}; foreach ($p in $high.PSObject.Properties) { $nativeHigh[$p.Name] = $p.Value }
$nativeMedium.linked = @{ logon_id='h' }; $nativeHigh.linked = @{ logon_id='m' }
@{ good=(Compare-SplitTokens $medium $high); old=(Compare-SplitTokens $old $old);
   native=(Compare-SplitTokens $nativeMedium $nativeHigh); mixedRepresentation=(Compare-SplitTokens $nativeMedium $high);
   mixedHigh=(Compare-SplitTokens $medium $old); mixedMedium=(Compare-SplitTokens $old $high);
   nullLink=(Compare-SplitTokens $nullLink $high); brokenLink=(Compare-SplitTokens $brokenLink $high) } | ConvertTo-Json -Depth 10 -Compress
"""
        out = self.run_body(body, ("Compare-SplitTokens",))
        self.assertTrue(out["good"]["paired"])
        self.assertTrue(out["native"]["paired"])
        self.assertTrue(out["mixedRepresentation"]["paired"])
        for name in ("old", "mixedHigh", "mixedMedium", "nullLink", "brokenLink"):
            self.assertFalse(out[name]["paired"], name)
            self.assertTrue(any("linked" in reason for reason in out[name]["failures"]), name)

    def test_report_dispatch_persists_verdict_and_returns_nonzero_for_incomplete(self):
        # Execute the actual main try/catch/finally and exit tail after replacing only
        # external phase inputs. No VM identity bypass is added to production code.
        body = r"""
$Phase = '__PHASE__'
$Rehearsal = __REHEARSAL__
$DelaySeconds = 0
$PyArgs = ''
$PyTimeoutSeconds = 1
$script:R6Phases = @('py-fixture')
$script:RunRoot = $Work
$script:Step = 'report'
$script:State = @{}
$script:Restore = @{}
$script:ExportRoot = $null
$statePath = Join-Path $Work 'state.json'
$identity = @{}
$RunId = 'test'
$report = [ordered]@{ status='PENDING'; result=$null }
function Get-PhaseState($When) { @{ when=$When } }
function Assert-Action { 'run' }
function Initialize-PyFixture { @{ summary=@{}; values=@{}; runs=0; python=@{ dir=$Work }; fixture='unused.py' } }
function Export-PyFixtureFiles { @() }
function Add-ExportFile { }
function Start-Process {
    $p = [pscustomobject]@{ Handle=1; HasExited=$true; ExitCode=__CODE__ }
    $p | Add-Member ScriptMethod WaitForExit { param($ms) $true }
    $p | Add-Member ScriptMethod Dispose { }
    $p
}
$script:Keys = [ordered]@{ AppPath='a'; ShellAumid='b' }
function Assert-OwnedBaseline($Snapshot, $Name) { if (-not $Snapshot[$Name].exists) { throw "missing $Name" } }
function Run-Inspect {
    New-InstallResult @{ exit_code=0 } @{ AppPath=@{ exists=$true }; ShellAumid=@{ exists=$false } } 'AB' $true
}
__OVERRIDE__
# Keep real serialization; verify the on-disk report before the real exit tail runs.
$main = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text.Contains('switch ($Phase)') })
if ($main.Count -ne 1) { throw 'main dispatch not found' }
$tail = $ast.Extent.Text.Substring($main[0].Extent.StartOffset)
$tail = $tail.Insert($main[0].Extent.EndOffset - $main[0].Extent.StartOffset, @'

$saved = Get-Content -Raw -LiteralPath (Join-Path $Work 'report.json') | ConvertFrom-Json
if ($saved.status -cne '__STATUS__') { throw ('persisted status: ' + $saved.status) }
if ($saved.result.fixture_verdict -cne '__VERDICT__') { throw 'lost inner verdict' }

'@)
. ([scriptblock]::Create($tail))
"""
        cases = [("py-fixture", 2, "PENDING", "PENDING", 2, False, ""),
                 ("inspect", 0, "OBSERVED", "OBSERVED", 2, False, ""),
                 ("py-fixture", 1, "FAIL", "FAIL", 1, False, ""),
                 ("py-fixture", 0, "PASS", "PASS_NATIVE_SCOPED", 0, False, ""),
                 ("py-fixture", 2, "PENDING", "PENDING", 2, True, ""),
                 ("py-fixture", 0, "PASS", "REHEARSAL_NOT_FINAL", 2, True, ""),
                 ("inspect", 0, "RUNNING", "RUNNING", 2, False,
                  "function Run-Inspect { @{ fixture_verdict='RUNNING' } }")]
        for phase, code, verdict, status, exit_code, rehearsal, override in cases:
            with self.subTest(status=status, rehearsal=rehearsal):
                script = body.replace('__PHASE__', phase).replace('__CODE__', str(code))
                script = script.replace('__STATUS__', status).replace('__VERDICT__', verdict)
                script = script.replace('__REHEARSAL__', '$true' if rehearsal else '$false').replace('__OVERRIDE__', override)
                out = self.run_body(script, ("Invoke-PyFixture", "Invoke-PyFixtureProcess", "Expand-PyArgs",
                    "New-InstallResult", "Write-Json", "ConvertTo-GxJson", "ConvertTo-JsonText", "Get-SafeText"),
                    ("LF", "JsonSource", "JsonErrors"), expected_exit=exit_code)
                self.assertEqual(out["status"], status)

    def test_toast_restore_retries_verify_registry_and_effective_state(self):
        body = self.TOAST_FAKES + r"""
$script:ToastSettleSeconds = @{ explicit=0; restore=0 }
$script:Record = [pscustomobject]@{ key='fake'; restored=$false; before=[pscustomobject]@{ exists=$true; values=[pscustomobject]@{} } }
$script:ExactRestores = 0
$script:Checks = 0
$script:Setting = 'DisabledForApplication'
function Read-Record { $script:Record }
function Save-Record($Name, $Value) { $script:Record = $Value }
function Set-RecordField($Record, $Name, $Value) { $Record | Add-Member NoteProperty $Name $Value -Force }
function Restore-AnyKeyTree { $script:ExactRestores++ }
function Read-AnyKeyTree { $script:Record.before }
function Json-Normal($Value) { $Value | ConvertTo-Json -Depth 10 -Compress }
function Get-ToastSetting { $script:Checks++; $script:Setting }
# Use the real registry restore bookkeeping with fake in-memory registry I/O.
$node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Restore-HkcuKey' }, $true)
. ([scriptblock]::Create($node.Extent.Text))
$first = Restore-ToastSettings
$checks1 = $script:Checks
$second = Restore-ToastSettings
$checks2 = $script:Checks
$script:Setting = 'Enabled'
$third = Restore-ToastSettings
$checks3 = $script:Checks
$fourth = Restore-ToastSettings
ConvertTo-GxJson @{ results=@($first,$second,$third,$fourth); checks=@($checks1,$checks2,$checks3,$script:Checks);
    exact_restores=$script:ExactRestores; record=$script:Record } -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "Wait-ToastSetting", "Restore-ToastSettings"), ("LF", "JsonSource"))
        self.assertEqual([x["ok"] for x in out["results"]], [False, False, True, True])
        self.assertTrue(all(x["registry"]["restored"] for x in out["results"]))
        self.assertEqual(out["exact_restores"], 4)
        self.assertTrue(all(b > a for a, b in zip([0] + out["checks"], out["checks"])))
        self.assertTrue(out["record"]["effective_restored"])

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

    def test_export_names_never_overwrite_each_other(self):
        body = r"""
$script:ExportExtra = New-Object System.Collections.Generic.List[string]
foreach ($name in 'a\ghostty.log', 'b\ghostty.log', 'c\ghostty.log', 'd\report.json') {
    $path = Join-Path $Work $name
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path, 'x')
}
Add-ExportFile (Join-Path $Work 'a\ghostty.log') 'toast-a-ghostty.log'
Add-ExportFile (Join-Path $Work 'b\ghostty.log') ''
Add-ExportFile (Join-Path $Work 'c\ghostty.log') ''
Add-ExportFile (Join-Path $Work 'd\report.json') 'py-broker/cases\BRK 04/report.json'
Add-ExportFile (Join-Path $Work 'missing.txt') ''
ConvertTo-GxJson ([ordered]@{ names=@(Get-ExportNames | ForEach-Object { $_.name }) }) -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "Add-ExportFile", "Get-ExportNames"),
                            ("LF", "JsonSource", "ExportAlias"))
        self.assertEqual(out["names"], ["toast-a-ghostty.log", "ghostty.log", "ghostty-2.log",
                                        "py-broker_cases_BRK_04_report.json"])

    def test_py_fixture_tree_and_python_are_hash_checked_copies(self):
        body = r"""
$env:LOCALAPPDATA = Join-Path $Work 'localappdata'
$share = Join-Path $Work 'share'
[IO.Directory]::CreateDirectory((Join-Path $share 'py\test\windows')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $share 'py\scripts')) | Out-Null
[IO.File]::WriteAllText((Join-Path $share 'py\test\windows\fx.py'), 'print(1)')
[IO.File]::WriteAllText((Join-Path $share 'py\scripts\helper.py'), 'X = 1')
[IO.File]::WriteAllBytes((Join-Path $share 'py\gx_ole_source.exe'), [byte[]](77, 90, 1))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipDir = Join-Path $Work 'zipsrc'
[IO.Directory]::CreateDirectory($zipDir) | Out-Null
[IO.File]::WriteAllText((Join-Path $zipDir 'python312._pth'), 'python312.zip')
[IO.Compression.ZipFile]::CreateFromDirectory($zipDir, (Join-Path $share 'py\embed.zip'))
$spec = [pscustomobject]@{
    python=[pscustomobject]@{ version='3.12.10'; file='embed.zip'; sha256=(Get-Sha256 (Join-Path $share 'py\embed.zip')) }
    files=[pscustomobject]@{ 'test/windows/fx.py'=(Get-Sha256 (Join-Path $share 'py\test\windows\fx.py')); 'scripts/helper.py'=(Get-Sha256 (Join-Path $share 'py\scripts\helper.py')) }
    tree_sha256='0123456789abcdef0123'; ole_source=[pscustomobject]@{ file='gx_ole_source.exe'; sha256=(Get-Sha256 (Join-Path $share 'py\gx_ole_source.exe')) } }
$first = Install-GuestPython $spec.python $share
$again = Install-GuestPython $spec.python $share
$tree = Install-PyFixtureTree $spec $share
[IO.File]::WriteAllText((Join-Path $share 'py\scripts\helper.py'), 'X = 2')
$tampered = try { $null = Install-PyFixtureTree $spec $share; 'accepted' } catch { $_.Exception.Message }
$args1 = Expand-PyArgs 'setup --root {run}\b --exe {app} --sha256 {app_sha256}' @{ run='C:\r'; app='C:\a.exe'; app_sha256='ab' }
$unknown = try { Expand-PyArgs '--x {nope}' @{ run='C:\r' } } catch { $_.Exception.Message }
$unavailable = try { Expand-PyArgs '--x {ole}' @{ ole=$null } } catch { $_.Exception.Message }
ConvertTo-GxJson ([ordered]@{ first=$first.extracted; again=$again.extracted; marker=(Test-Path (Join-Path $first.dir 'gx-python.json'));
    pth=(Test-Path (Join-Path $first.dir 'python312._pth')); files=@($tree.files | ForEach-Object { $_.path });
    ole=(Test-Path $tree.ole_source); tampered=$tampered; args1=$args1; unknown=$unknown; unavailable=$unavailable }) -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "Write-Json", "ConvertTo-JsonText", "Get-SafeText", "Read-JsonFile",
                                   "Get-Sha256", "Assert-Hash", "Assert-NoReparse", "Get-MapEntries", "Install-GuestPython",
                                   "Install-PyFixtureTree", "Expand-PyArgs"),
                            ("LF", "JsonSource", "JsonErrors"))
        self.assertEqual((out["first"], out["again"], out["marker"], out["pth"]), (True, False, True, True))
        self.assertEqual(sorted(out["files"]), ["scripts/helper.py", "test/windows/fx.py"])
        self.assertTrue(out["ole"])
        self.assertIn("Frozen file hash mismatch", out["tampered"])
        self.assertEqual(out["args1"], "setup --root C:\\r\\b --exe C:\\a.exe --sha256 ab")
        self.assertIn("{nope}", out["unknown"])
        self.assertIn("{ole}", out["unavailable"])

    TOAST_FAKES = r"""
$script:Log = New-Object System.Collections.ArrayList
function Start-Sleep { param($Milliseconds, $Seconds) }
function Restore-HkcuKey($Name) { [void]$script:Log.Add('restore ' + $Name); [ordered]@{ restored=$true } }
function Set-RecordField($Record, $Name, $Value) { $Record | Add-Member NoteProperty $Name $Value -Force }
function Save-Record($Name, $Record) { }
$fakeKey = New-Object psobject
$fakeKey | Add-Member ScriptMethod SetValue { param($n, $v, $k) [void]$script:Log.Add('set ' + $n + '=' + $v) }
$fakeKey | Add-Member ScriptMethod Dispose { }
$fakeBase = New-Object psobject
$fakeBase | Add-Member ScriptMethod CreateSubKey { param($k) [void]$script:Log.Add('key ' + $k); $fakeKey }
$fakeBase | Add-Member ScriptMethod Dispose { }
function Open-HkcuBase { $fakeBase }
# The Settings switch fake: records the call; $script:SwitchFixes makes it take effect.
$script:SwitchFixes = $false
function Set-ToastSwitchInSettings($Aumid) {
    [void]$script:Log.Add('switch ' + $Aumid)
    if ($script:SwitchFixes) { $script:Seen = New-Object System.Collections.Queue; $script:Seen.Enqueue('Enabled') }
    [ordered]@{ found=$true; toggles=@() }
}
$script:InstalledAumid = 'gx0404.GhosttyGX'
$script:NotificationSettingsKey = 'Software\N\gx0404.GhosttyGX'
$script:ToastSettleSeconds = @{ explicit=1; restore=1 }
"""

    def test_toast_settings_are_written_explicitly_then_restored_and_verified(self):
        body = self.TOAST_FAKES + r"""
$script:Seen = New-Object System.Collections.Queue
foreach ($s in 'DisabledForApplication', 'DisabledForApplication', 'Enabled', 'Enabled') { $script:Seen.Enqueue($s) }
function Get-ToastSetting($Aumid) { if ($script:Seen.Count -gt 1) { $script:Seen.Dequeue() } else { $script:Seen.Peek() } }
# The backup had no Enabled value (the app was enabled by default).
function Read-Record($Name) { [pscustomobject]@{ restored=$false; before=[pscustomobject]@{ exists=$true; values=[pscustomobject]@{} } } }
$ok = Restore-ToastSettings
$script:Seen = New-Object System.Collections.Queue
$script:Seen.Enqueue('DisabledForApplication')
$stuck = Restore-ToastSettings
# Only the Settings switch refreshes the platform: the key write alone stays disabled.
$script:Seen = New-Object System.Collections.Queue
$script:Seen.Enqueue('DisabledForApplication')
$script:SwitchFixes = $true
$switched = Restore-ToastSettings
$script:SwitchFixes = $false
$script:Seen = New-Object System.Collections.Queue
$script:Seen.Enqueue('DisabledForApplication')
# A backup with Enabled=0 is put back as disabled, and that is what must take effect.
function Read-Record($Name) { [pscustomobject]@{ restored=$false; before=[pscustomobject]@{ exists=$true;
    values=[pscustomobject]@{ 'value:Enabled'=[pscustomobject]@{ kind='DWord'; data=0 } } } } }
$disabled = Restore-ToastSettings
ConvertTo-GxJson ([ordered]@{ ok=$ok; stuck=$stuck; switched=$switched; disabled=$disabled; log=@($script:Log) }) -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "Wait-ToastSetting", "Restore-ToastSettings"), ("LF", "JsonSource"))
        self.assertTrue(out["ok"]["ok"])
        self.assertEqual(out["ok"]["effective"]["want"], "Enabled")
        self.assertTrue(out["ok"]["effective"]["after_explicit"]["reached"])
        self.assertIsNone(out["ok"]["effective"]["settings_switch"])
        self.assertFalse(out["stuck"]["ok"])
        self.assertEqual(out["stuck"]["effective"]["after_restore"]["setting"], "DisabledForApplication")
        self.assertTrue(out["stuck"]["effective"]["settings_switch"]["found"])
        self.assertTrue(out["switched"]["ok"])
        self.assertTrue(out["switched"]["effective"]["after_switch"]["reached"])
        # A backup that disabled the app never touches the Settings switch.
        self.assertIsNone(out["disabled"]["effective"]["settings_switch"])
        self.assertEqual([x for x in out["log"] if x.startswith("switch ")], ["switch gx0404.GhosttyGX"] * 2)
        self.assertEqual(out["disabled"]["effective"]["want"], "DisabledForApplication")
        self.assertTrue(out["disabled"]["ok"])
        # Each run writes Enabled first and restores the exact backup only afterwards.
        self.assertEqual(out["log"][:3], ["key Software\\N\\gx0404.GhosttyGX", "set Enabled=1",
                                          "restore toast-notification-settings"])
        # The switch runs before the exact backup is restored.
        self.assertEqual(out["log"][3:7], ["key Software\\N\\gx0404.GhosttyGX", "set Enabled=1",
                                           "switch gx0404.GhosttyGX", "restore toast-notification-settings"])
        self.assertEqual(out["log"][-2:], ["set Enabled=0", "restore toast-notification-settings"])

    def test_install_result_keeps_the_registry_and_names_each_baseline_difference(self):
        body = r"""
$script:Keys = [ordered]@{ AppPath='a'; ShellAumid='b'; ShellClsid='c' }
# An older package (gx-v0.0.2) has no shell identity yet.
function Assert-OwnedBaseline($Snapshot, $Name) { if (-not $Snapshot[$Name].exists) { throw "Integration group $Name is missing after installation." } }
$old = @{ AppPath=@{ exists=$true }; ShellAumid=@{ exists=$false }; ShellClsid=@{ exists=$false } }
$new = @{ AppPath=@{ exists=$true }; ShellAumid=@{ exists=$true }; ShellClsid=@{ exists=$true } }
ConvertTo-GxJson ([ordered]@{ observed=(New-InstallResult @{ exit_code=0 } $old 'AB' $true); failed=(New-InstallResult @{ exit_code=0 } $old 'AB' $false);
    passed=(New-InstallResult @{ exit_code=0 } $new 'CD' $false) }) -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "New-InstallResult"), ("LF", "JsonSource"))
        self.assertEqual(out["observed"]["fixture_verdict"], "OBSERVED")
        self.assertEqual([p["group"] for p in out["observed"]["baseline_problems"]], ["ShellAumid", "ShellClsid"])
        self.assertIn("ShellAumid", out["observed"]["registry"])
        self.assertEqual(out["failed"]["fixture_verdict"], "FAIL")
        self.assertIn("ShellAumid, ShellClsid", out["failed"]["fixture_reason"])
        self.assertNotIn("fixture_verdict", out["passed"])
        self.assertEqual((out["passed"]["baseline_problems"], out["passed"]["app_sha256"]), ([], "CD"))

    def test_acl_comparison_ignores_only_the_auto_inherited_flags(self):
        base = "O:S-1-5-21-1-2-3-1001G:S-1-5-21-1-2-3-513D:(A;OICIID;FA;;;SY)(A;OICIID;FA;;;S-1-5-21-1-2-3-1001)"
        body = r"""
$base = '__BASE__'
$ai = $base.Replace('D:(', 'D:AI(')
$deny = $base.Replace('D:(', 'D:(D;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;S-1-5-21-1-2-3-1001)')
$protected = $base.Replace('D:(', 'D:P(')
ConvertTo-GxJson ([ordered]@{ ai=((Get-NormalizedSddl $ai) -ceq (Get-NormalizedSddl $base));
    deny=((Get-NormalizedSddl $deny) -ceq (Get-NormalizedSddl $base));
    protected=((Get-NormalizedSddl $protected) -ceq (Get-NormalizedSddl $base)) }) -Compress
""".replace("__BASE__", base)
        out = self.run_body(body, ("ConvertTo-GxJson", "Get-NormalizedSddl"), ("LF", "JsonSource"))
        self.assertEqual(out, {"ai": True, "deny": False, "protected": False})

    def test_jumplist_p6_asks_for_one_trailing_backslash_and_its_marker_records_it(self):
        body = r"""
$script:RunRoot = $Work
$markDir = Get-JumpListMarkDir
[IO.Directory]::CreateDirectory($markDir) | Out-Null
[IO.File]::WriteAllText((Join-Path $markDir 'gx-jl-argv.ps1'), (Get-JumpListArgvScript), [Text.Encoding]::ASCII)
$p6 = @(Get-JumpListProfiles $markDir | Where-Object { $_.key -ceq 'p6' })[0]
Add-Type -TypeDefinition $script:TokenSource -Language CSharp
# CommandLineToArgvW is the CRT-compatible parse Ghostty's profile command follows.
$argv = @([GxVmToken]::Arguments($p6.command))
# The A/B set keeps the original input, which the same rules read as <dir>".
$legacy = @(Get-JumpListProfiles $markDir -LegacyP6 | Where-Object { $_.key -ceq 'p6' })[0]
$legacyArgv = @([GxVmToken]::Arguments($legacy.command))
# Run the marker the way the profile would, without -NoExit, and read what it recorded.
$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
$start.Arguments = $p6.command.Substring($p6.command.IndexOf(' ') + 1).Replace('-NoExit ', '')
$start.UseShellExecute = $false
$start.EnvironmentVariables.Remove('PSModulePath')
$process = [Diagnostics.Process]::Start($start)
if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'marker did not finish' }
$marker = @(Get-ChildItem -LiteralPath $markDir -Filter 'gx-jl-argv-*.json')[0]
$record = [IO.File]::ReadAllText($marker.FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
ConvertTo-GxJson ([ordered]@{ dir=$markDir; argv=$argv; legacy_argv=$legacyArgv; script_args=@($record.script_args); last=@($record.argv)[-1];
    command_line=$record.command_line; crt=@([GxVmToken]::Arguments($record.command_line)); exit=$process.ExitCode }) -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "Get-JumpListMarkDir", "Get-JumpListProfiles", "Get-JumpListArgvScript"),
                            ("LF", "JsonSource", "TokenSource"))
        expected = out["dir"] + "\\"
        self.assertIn("\u4e2d\u6587", out["dir"])
        self.assertEqual(out["argv"][-1], expected)
        self.assertEqual(out["legacy_argv"][-1], out["dir"] + '"')
        # Whole values: script args, .NET argv and the CRT-decoded raw command line.
        self.assertEqual((out["script_args"], out["last"], out["crt"][-1], out["exit"]), ([expected], expected, expected, 0))
        self.assertTrue(out["command_line"].endswith('"' + out["dir"] + '\\\\"'), out["command_line"])

    def test_respond_when_shown_answers_each_new_confirmation_once(self):
        body = r"""
$script:RunRoot = $Work
$PyRoot = 'brk'; $PyCase = 'BRK-04'; $PyWaitSeconds = 5
$PyResponses = 'allow,broker-preview,0,-120,-30;cancel,protected-paste,0'
[IO.Directory]::CreateDirectory((Join-Path $Work 'brk\cases\BRK-04')) | Out-Null
[IO.File]::WriteAllText((Join-Path $Work 'brk\cases\BRK-04\report.json'), '{"target":{"pid":4242}}')
$script:Windows = @(@{ hwnd='0x10a'; class='GhosttyGxPopup'; visible=$true; title='Paste into elevated terminal?' },
                    @{ hwnd='0x20b'; class='#32770'; visible=$true; title='Warning' })
function Get-PyPopups([int]$TargetPid, $Answered) { @($script:Windows | Where-Object { $Answered -notcontains [Convert]::ToInt64($_['hwnd'].Substring(2), 16) }) }
$script:Calls = New-Object System.Collections.ArrayList
function Invoke-PyFixtureProcess($Context, [string]$Arguments, [string]$Tag) {
    [void]$script:Calls.Add($Arguments)
    if ($Tag -ceq 'inspect') {
        return [ordered]@{ verdict='PASS'; output=[pscustomobject]@{ popups=@([pscustomobject]@{ hwnd=0x10a; rect=@(100, 200, 500, 400) },
            [pscustomobject]@{ hwnd=0x20b; rect=@(10, 20, 30, 40) }) } }
    }
    return [ordered]@{ verdict='PASS'; exit_code=0 }
}
$result = Invoke-PyRespondWhenShown $null
ConvertTo-GxJson ([ordered]@{ verdict=$result.fixture_verdict; reason=$result.fixture_reason; calls=@($script:Calls); click=$result.steps[0].click }) -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "Read-JsonFile", "Invoke-PyRespondWhenShown"), ("LF", "JsonSource"))
        self.assertEqual(out["verdict"], "PASS", out)
        self.assertEqual(out["click"], [380, 370])
        calls = out["calls"]
        self.assertEqual(len(calls), 4)
        self.assertTrue(calls[0].startswith("inspect ") and "--name BRK-04" in calls[0])
        self.assertIn("--popup-hwnd 0x10a --decision allow --stage broker-preview --desktop-held --x 380 --y 370", calls[1])
        self.assertIn("--popup-hwnd 0x20b --decision cancel --stage protected-paste", calls[3])
        self.assertNotIn("--x", calls[3])

    def test_fixture_process_output_of_one_line_or_a_json_document_is_kept(self):
        body = r"""
$script:RunRoot = $Work
$script:Step = 'step'
$script:ExportExtra = New-Object System.Collections.Generic.List[string]
$PyTimeoutSeconds = 60
[IO.File]::WriteAllText((Join-Path $Work 'one.py'), 'print("only line")')
[IO.File]::WriteAllText((Join-Path $Work 'doc.py'), 'import json, sys; print("noise"); print(json.dumps({"status": "ok", "n": [1]}, indent=2)); sys.exit(2)')
$context = [ordered]@{ python=[ordered]@{ dir='__PYDIR__' }; fixture=(Join-Path $Work 'one.py'); runs=0 }
$one = Invoke-PyFixtureProcess $context '' 'run'
$context.fixture = Join-Path $Work 'doc.py'
$doc = Invoke-PyFixtureProcess $context '' 'run'
ConvertTo-GxJson ([ordered]@{ one=$one; doc=$doc; names=@(Get-ExportNames | ForEach-Object { $_.name }) }) -Compress
""".replace("__PYDIR__", str(Path(sys._base_executable).parent))
        out = self.run_body(body, ("ConvertTo-GxJson", "Read-TextLines", "Add-ExportFile", "Get-ExportNames", "Invoke-PyFixtureProcess"),
                            ("LF", "JsonSource", "ExportAlias"))
        self.assertEqual((out["one"]["stdout_tail"], out["one"]["verdict"]), (["only line"], "PASS"))
        self.assertEqual(out["doc"]["output"], {"status": "ok", "n": [1]})
        self.assertEqual((out["doc"]["exit_code"], out["doc"]["verdict"]), (2, "PENDING"))
        self.assertEqual(out["names"], ["py-run-1.stdout.txt", "py-run-1.stderr.txt", "py-run-2.stdout.txt", "py-run-2.stderr.txt"])

    def test_fixture_files_held_open_by_an_app_are_still_hashed_and_listed(self):
        body = r"""
$script:RunRoot = Join-Path $Work 'run'
$script:Step = 'step'
$script:ExportExtra = New-Object System.Collections.Generic.List[string]
$log = Join-Path $script:RunRoot 'brk\profile\ghostty\logs\ghostty.log'
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($log)) | Out-Null
# Held like a running app holds its log: write access, read and write sharing.
$held = [IO.FileStream]::new($log, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
$bytes = [Text.Encoding]::ASCII.GetBytes('log line')
$held.Write($bytes, 0, $bytes.Length); $held.Flush()
try { $written = @(Export-PyFixtureFiles ([ordered]@{ started=[DateTime]::UtcNow.AddMinutes(-1) })) } finally { $held.Dispose() }
ConvertTo-GxJson ([ordered]@{ written=$written; names=@(Get-ExportNames | ForEach-Object { $_.name }) }) -Compress
"""
        out = self.run_body(body, ("ConvertTo-GxJson", "Add-ExportFile", "Get-ExportNames", "Export-PyFixtureFiles", "Get-SharedSha256"),
                            ("LF", "JsonSource", "ExportAlias"))
        # The directory entry size of a file still open for writing may lag (0 here); the hash reads the data.
        self.assertEqual([(item["path"], item["sha256"]) for item in out["written"]],
                         [("brk\\profile\\ghostty\\logs\\ghostty.log", hashlib.sha256(b"log line").hexdigest())])
        self.assertEqual(out["names"], ["py-brk_profile_ghostty_logs_ghostty.log"])

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
