#!/usr/bin/env python3
"""快速门故障注入：仅临时目录和伪进程，不构建真实项目。"""

from __future__ import annotations

import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import quick_check as quick


class IdentityTests(unittest.TestCase):
    def test_external_standard_library_contents_invalidate_identity(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "zig.exe"
            executable.write_bytes(b"pinned compiler")
            library = root / "external-lib"
            library.mkdir()
            source = library / "std.zig"
            source.write_text("before", encoding="utf-8")
            with mock.patch.object(quick.zigw, "require_zig", return_value=SimpleNamespace(path=str(executable))), \
                    mock.patch.dict(os.environ, {"ZIG_LIB_DIR": "external-lib"}):
                before = quick.toolchain_identity(root)
                self.assertEqual(str(library.resolve()), before["libraries_path"])
                stamp = source.stat()
                source.write_text("edited", encoding="utf-8")
                os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                self.assertNotEqual(before, quick.toolchain_identity(root))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text("ignored\n", encoding="utf-8")
        (self.root / "tracked").write_text("first", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)

    def test_actual_bytes_not_mtime(self):
        initial = quick.source_identity(self.root)
        path = self.root / "tracked"
        stamp = path.stat()
        path.write_text("other", encoding="utf-8")
        os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        self.assertNotEqual(initial, quick.source_identity(self.root))

    def test_untracked_deletion_and_ignored_inputs(self):
        initial = quick.source_identity(self.root)
        (self.root / "ignored").write_text("irrelevant", encoding="utf-8")
        self.assertEqual(initial, quick.source_identity(self.root))
        (self.root / "new").write_text("input", encoding="utf-8")
        self.assertNotEqual(initial, quick.source_identity(self.root))
        (self.root / "new").unlink()
        (self.root / "tracked").unlink()
        self.assertNotEqual(initial, quick.source_identity(self.root))

    def test_receipt_rejects_input_and_binary_replacement(self):
        receipt = {"inputs": {"hash": "a"}, "artifacts": {"hash": "b"}}
        with mock.patch.object(quick, "input_identity", return_value=receipt["inputs"]), mock.patch.object(quick, "artifacts", return_value=receipt["artifacts"]):
            quick.validate_receipt(self.root, receipt)
        for inputs, artifacts in [({"hash": "changed"}, receipt["artifacts"]), (receipt["inputs"], {"hash": "replaced"})]:
            with mock.patch.object(quick, "input_identity", return_value=inputs), mock.patch.object(quick, "artifacts", return_value=artifacts):
                with self.assertRaises(quick.GateError):
                    quick.validate_receipt(self.root, receipt)

    def test_missing_artifacts_fail(self):
        with self.assertRaises(quick.GateError):
            quick.artifacts(self.root)

    def test_failed_prepare_revokes_old_receipt(self):
        path = self.root / quick.STATE / "prepared.json"
        quick.write_json(path, {"old": "PASS"})
        with mock.patch.object(quick, "input_identity", return_value={}), mock.patch.object(quick, "commands", return_value=[["fake"]]), mock.patch.object(quick.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaises(quick.GateError):
                quick.prepare(self.root)
        self.assertFalse(path.exists())

    def test_prepare_refuses_changing_inputs(self):
        with mock.patch.object(quick, "input_identity", side_effect=[{"a": 1}, {"a": 2}]), mock.patch.object(quick, "commands", return_value=[]), mock.patch.object(quick, "artifacts", return_value={}):
            with self.assertRaises(quick.GateError):
                quick.prepare(self.root)
        self.assertFalse((self.root / quick.STATE / "prepared.json").exists())

    def test_builds_are_complete_and_use_private_prefix(self):
        (self.root / "build.zig.zon").write_text('.{ .version = "1.0.0" }', encoding="utf-8")
        commands = quick.commands(self.root)
        self.assertEqual([command[3] for command in commands], ["test-bin", "test-lib-vt-bin"])
        for command in commands:
            self.assertEqual(command[-2:], ["--prefix", str(self.root / quick.STATE / "build")])
            self.assertNotIn("test-filter", " ".join(command))


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run_id = "a" * 32
        self.directory = self.root / quick.STATE / "runs" / self.run_id
        self.directory.mkdir(parents=True)
        (self.directory / "start").touch()
        quick.write_json(self.root / quick.STATE / "prepared.json", {"signed": 1})

    def commands(self):
        result = {}
        for name in ["rules", "version", "fmt", "diff", "framework", *quick.FILTERS]:
            source = "import pathlib, json, sys\nprint('" + name + "')\n"
            if name == "framework":
                source += "print('Ran 17 tests in 0.1s')\n"
            if name in quick.FILTERS:
                payload = {"dedupe": False, "build": None, "ok": True, "exit_code": 0,
                           "tests": [{"name": pattern + "case", "outcome": "pass"} for pattern in quick.FILTERS[name]]}
                source += f"pathlib.Path({str(self.directory / (name + '.json'))!r}).write_text({json.dumps(payload)!r})\n"
            result[name] = [sys.executable, "-c", source]
        return result

    def run_worker(self, validation=None, commands=None):
        with mock.patch.object(quick, "validate_receipt", side_effect=validation), mock.patch.object(quick, "check_commands", return_value=commands or self.commands()):
            code = quick.worker(self.root, self.directory, self.run_id)
        return code, quick.read_json(self.directory / "progress.json")

    def test_concurrent_groups_have_separate_logs_and_counts(self):
        code, report = self.run_worker()
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "PASS")
        for row in report["groups"]:
            if "log" in row:
                self.assertEqual(Path(row["log"]).read_text().splitlines()[0], row["name"])
        rows = {row["name"]: row for row in report["groups"]}
        self.assertEqual(rows["framework"]["selected"], 17)
        self.assertEqual(rows["vt"]["selected"], 1)
        self.assertEqual(rows["vt_c"]["selected"], 2)

    def test_input_change_after_execution_fails(self):
        code, report = self.run_worker([None, quick.GateError("changed during execution")])
        self.assertEqual(code, 1)
        self.assertEqual(report["groups"][-1]["status"], "FAIL")

    def test_receipt_replacement_after_execution_fails(self):
        def validate(root, receipt):
            quick.write_json(root / quick.STATE / "prepared.json", {"signed": 2})
        code, report = self.run_worker(validate)
        self.assertEqual(code, 1)
        self.assertIn("签收被替换", report["groups"][-1]["error"])

    def test_missing_receipt_never_launches_commands(self):
        (self.root / quick.STATE / "prepared.json").unlink()
        with mock.patch.object(quick, "check_commands") as commands:
            self.assertEqual(quick.worker(self.root, self.directory, self.run_id), 1)
            commands.assert_not_called()

    def test_framework_zero_tests_fails(self):
        commands = self.commands()
        commands["framework"] = [sys.executable, "-c", "print('Ran 0 tests')"]
        code, report = self.run_worker(commands=commands)
        self.assertEqual(code, 1)
        self.assertEqual(next(row for row in report["groups"] if row["name"] == "framework")["status"], "FAIL")


class ProfileTests(unittest.TestCase):
    def payload(self, label="vt_c"):
        return {"dedupe": False, "build": None, "ok": True, "exit_code": 0,
                "tests": [{"name": pattern + "example", "outcome": "pass"} for pattern in quick.FILTERS[label]]}

    def test_every_required_filter_must_hit(self):
        for label in quick.FILTERS:
            for index in range(len(quick.FILTERS[label])):
                payload = self.payload(label)
                del payload["tests"][index]
                with self.subTest(label=label, missing=index), self.assertRaises(quick.GateError):
                    quick.inspect_zig(label, payload)

    def test_modes_and_unknown_results_fail_closed(self):
        for key, value in [("dedupe", True), ("build", {}), ("tests", [{"name": "terminal.Parser.example", "outcome": "unknown"}])]:
            payload = self.payload()
            payload[key] = value
            with self.subTest(key=key), self.assertRaises(quick.GateError):
                quick.inspect_zig("vt_c", payload)

    def test_runner_failure_cannot_be_hidden(self):
        for update in [{"ok": False}, {"exit_code": 1}]:
            payload = self.payload()
            payload.update(update)
            self.assertEqual(quick.inspect_zig("vt_c", payload)["status"], "FAIL")
        payload = self.payload()
        payload["tests"][0]["outcome"] = "fail"
        self.assertEqual(quick.inspect_zig("vt_c", payload)["status"], "FAIL")

    def test_skips_are_separately_reported(self):
        payload = self.payload()
        payload["tests"][0]["outcome"] = "skip"
        result = quick.inspect_zig("vt_c", payload)
        self.assertEqual((result["selected"], result["passed"], result["skipped"]), (2, 1, 1))

    def test_fixed_profile_has_no_dedupe_or_compile_filter(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with mock.patch.object(quick, "binaries", return_value={label: root / label for label in quick.FILTERS}):
                commands = quick.check_commands(root, root)
            self.assertEqual(len(quick.FILTERS["ghostty-test"]), 6)
            self.assertEqual(quick.FILTERS["vt"], ("terminal.Parser.",))
            self.assertEqual(quick.FILTERS["vt_c"], ("terminal.Parser.", "terminal.c."))
            self.assertEqual(len(quick.FRAMEWORK), 9)
            for label in quick.FILTERS:
                self.assertNotIn("--dedupe", commands[label])
                self.assertNotIn("--suite", commands[label])
                self.assertNotIn("-Dtest-filter", " ".join(commands[label]))


@unittest.skipUnless(os.name == "nt" or sys.platform.startswith("linux"), "process containment platform")
class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_worker(self, body, budget=2):
        script = self.root / "fake.py"
        script.write_text("import json, os, pathlib, subprocess, sys, time\n"
                          "root = pathlib.Path.cwd()\n"
                          "directory = next((root / '.local/quick-check/runs').iterdir())\n"
                          "while not (directory / 'start').exists(): time.sleep(.01)\n" + body, encoding="utf-8")
        return quick.supervise(self.root, execution_seconds=budget, total_seconds=budget + 2,
                               worker_command=[sys.executable, str(script)])

    def test_success_requires_complete_current_report(self):
        report = quick.base_report("placeholder")
        for row in report["groups"]:
            row["status"] = "PASS"
        body = f"report = {report!r}\nreport['run_id'] = directory.name\n(directory / 'progress.json').write_text(json.dumps(report))\n"
        result = self.run_worker(body)
        self.assertEqual(result["status"], "PASS")

    def test_zero_exit_without_report_does_not_reuse_previous_pass(self):
        quick.write_json(self.root / quick.STATE / "report.json", {"status": "PASS", "run_id": "old"})
        result = self.run_worker("pass\n")
        self.assertEqual(result["status"], "FAIL")
        self.assertNotEqual(result["run_id"], "old")

    def test_empty_groups_cannot_pass(self):
        result = self.run_worker("(directory / 'progress.json').write_text(json.dumps({'run_id': directory.name, 'groups': []}))\n")
        self.assertEqual(result["status"], "FAIL")

    def test_nonzero_worker_exit_cannot_pass(self):
        result = self.run_worker("sys.exit(3)\n")
        self.assertEqual(result["status"], "FAIL")

    def test_timeout_bounds_wall_time_and_cleans_descendants(self):
        marker = self.root / "escaped"
        child = "import pathlib, time; time.sleep(1.5); pathlib.Path(" + repr(str(marker)) + ").touch(); time.sleep(30)"
        body = f"child = subprocess.Popen([sys.executable, '-c', {child!r}], creationflags=(subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0))\n(directory / 'child.pid').write_text(str(child.pid))\ntime.sleep(30)\n"
        start = time.monotonic()
        result = self.run_worker(body, budget=.7)
        self.assertEqual(result["status"], "FAIL")
        self.assertTrue(result["timed_out"])
        self.assertLess(time.monotonic() - start, 2.7)
        self.assertTrue((Path(result["directory"]) / "child.pid").exists())
        time.sleep(1)
        self.assertFalse(marker.exists(), "grandchild survived containment cleanup")

    def test_large_stdout_and_stderr_do_not_block(self):
        result = self.run_worker("sys.stdout.write('x' * 1000000)\nsys.stderr.write('y' * 1000000)\n")
        self.assertFalse(result.get("timed_out", False))
        self.assertGreater((Path(result["directory"]) / "worker.log").stat().st_size, 1900000)


if __name__ == "__main__":
    unittest.main()
