"""Cache diagnostics and rebuild probes use temporary fixtures, never the real Zig build."""

from __future__ import annotations

import concurrent.futures
import contextlib
import io
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import ci_cache
import zig_test
import zigw

SCRIPT = SCRIPTS / "ci_cache.py"


class MetadataTests(unittest.TestCase):
    def test_zig_env_selects_only_top_level_whitelisted_fields(self):
        expected = {"zig_exe": r"C:\tools\zig.exe", "lib_dir": r"C:\tools\lib",
                    "version": "0.16.0", "global_cache_dir": r"C:\cache"}
        lines = [f"    .{key} = {json.dumps(value)}," for key, value in expected.items()]
        lines += ['    .env = .{', '        .SECRET = "do-not-report",', '    },']
        self.assertEqual(ci_cache.parse_zig_env(".{\r\n" + "\r\n".join(lines) + "\r\n}"), expected)
        with self.assertRaises(ValueError):
            ci_cache.parse_zig_env('.{ .version = "0.16.0" }')

    def test_zig_info_uses_wrapper_environment_and_normalizes_relative_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fields = {"zig_exe": "tools/zig", "lib_dir": "tools/lib", "version": "0.16.0",
                      "global_cache_dir": "cache"}
            output = ".{\n" + "\n".join(f"    .{key} = {json.dumps(value)}," for key, value in fields.items()) + "\n}"
            with mock.patch.object(zigw, "require_zig", return_value=zigw.ResolvedZig("zig", "PATH")), \
                    mock.patch.object(ci_cache.subprocess, "run", return_value=SimpleNamespace(stdout=output)) as run, \
                    mock.patch.dict(os.environ, {"ZIG_LOCAL_CACHE_DIR": "cache", "ZIG_GLOBAL_CACHE_DIR": "cache",
                                                 "CI_SECRET_SENTINEL": "never-print-this"}):
                result = ci_cache.zig_info(root)
            self.assertEqual(result["lib"], str(root / "tools" / "lib"))
            self.assertEqual(result["local_cache"], str(root / "cache"))
            self.assertEqual(result["global_cache"], str(root / "cache"))
            self.assertNotIn("never-print-this", json.dumps(result))
            self.assertEqual(run.call_args.kwargs["env"]["ZIG_GLOBAL_CACHE_DIR"], "cache")
            self.assertEqual(run.call_args.kwargs["timeout"], 15)
            self.assertTrue(run.call_args.kwargs["check"])

    def test_linux_cpu_model_is_not_an_environment_dump(self):
        with mock.patch.object(ci_cache.sys, "platform", "linux"), \
                mock.patch.object(Path, "read_text", return_value="processor : 0\nmodel name : Test CPU\nsecret : ignored\n"), \
                mock.patch.object(ci_cache.platform, "machine", return_value="x86_64"), \
                mock.patch.object(ci_cache.platform, "processor", return_value="fallback"), \
                mock.patch.object(ci_cache.os, "cpu_count", return_value=4):
            self.assertEqual(ci_cache.cpu_info(), {"arch": "x86_64", "model": "Test CPU", "logical_cpus": 4})

    def test_windows_cpu_model_reads_only_hardware_registry(self):
        registry = mock.MagicMock()
        registry.QueryValueEx.return_value = (" Test Windows CPU ", 1)
        with mock.patch.object(ci_cache.sys, "platform", "win32"), \
                mock.patch.dict(sys.modules, {"winreg": registry}):
            result = ci_cache.cpu_info()
        self.assertEqual(result["model"], "Test Windows CPU")
        registry.OpenKey.assert_called_once_with(registry.HKEY_LOCAL_MACHINE,
                                                r"HARDWARE\DESCRIPTION\System\CentralProcessor\0")
        self.assertEqual(registry.QueryValueEx.call_args.args[1], "ProcessorNameString")


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_sizes_are_partitioned_without_reading_contents(self):
        (self.root / "o" / "abc").mkdir(parents=True)
        (self.root / "o" / "abc" / "file").write_bytes(b"12345")
        (self.root / "manifest").write_bytes(b"12")
        with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("must not read contents")):
            result = ci_cache.cache_sizes(self.root, time.monotonic() + 10)
        self.assertEqual(result["bytes"], 7)
        self.assertEqual(result["top_level_bytes"], {"o": 5, "manifest": 2})
        self.assertTrue(result["complete"])
        missing = ci_cache.cache_sizes(self.root / "missing", time.monotonic() + 10)
        self.assertFalse(missing["exists"])
        self.assertTrue(missing["complete"])

    def test_links_and_reparse_points_are_excluded(self):
        self.assertTrue(ci_cache.is_link(SimpleNamespace(st_mode=stat.S_IFLNK, st_file_attributes=0)))
        self.assertTrue(ci_cache.is_link(SimpleNamespace(st_mode=stat.S_IFDIR,
                                                        st_file_attributes=stat.FILE_ATTRIBUTE_REPARSE_POINT)))
        (self.root / "link").write_bytes(b"not-a-real-symlink")
        with mock.patch.object(ci_cache, "is_link", side_effect=[False, True]):
            result = ci_cache.cache_sizes(self.root, time.monotonic() + 10)
        self.assertEqual(result["bytes"], 0)
        self.assertEqual(result["skipped_links"], 1)

    def test_scan_deadline_and_permission_failure_are_explicit(self):
        self.assertFalse(ci_cache.cache_sizes(self.root, 0)["complete"])
        with mock.patch.object(ci_cache.os, "scandir", side_effect=PermissionError):
            result = ci_cache.cache_sizes(self.root, time.monotonic() + 10)
        self.assertEqual(result["errors"], 1)
        self.assertFalse(result["complete"])

    def test_timings_use_suite_labels_and_never_print_names_or_values(self):
        timings = self.root / "timings"
        timings.mkdir()
        (timings / "vt.json").write_text(json.dumps({"secret-test-name": 1.2, "bad": -1, "bool": True}), encoding="utf-8")
        (timings / "vt_c.json").write_text("not-json", encoding="utf-8")
        with mock.patch.dict(os.environ, {zig_test.TIMINGS_ENV: "timings"}):
            result = ci_cache.timing_counts(self.root, "vt")
        self.assertEqual(result["vt"]["entries"], 1)
        self.assertEqual(result["vt"]["status"], "ok")
        self.assertEqual(result["vt_c"]["status"], "invalid")
        self.assertNotIn("secret-test-name", json.dumps(result))
        self.assertNotIn("ghostty-test", result)

    def test_cold_timings_are_missing_not_failure(self):
        with mock.patch.dict(os.environ, {zig_test.TIMINGS_ENV: "missing"}):
            result = ci_cache.timing_counts(self.root, "main")
        self.assertEqual(result["ghostty-test"]["status"], "missing")

    def test_snapshot_deduplicates_cache_paths_and_fails_incomplete_evidence(self):
        zig = {"exe": "zig", "lib": "lib", "version": "0.16.0", "global_cache": str(self.root),
               "local_cache": str(self.root)}
        with mock.patch.object(ci_cache, "zig_info", return_value=zig), \
                mock.patch.object(ci_cache, "cpu_info", return_value={"model": "test"}), \
                mock.patch.object(ci_cache, "timing_counts", return_value={}), \
                mock.patch.object(ci_cache, "cache_sizes", return_value={"complete": False}) as sizes:
            result = ci_cache.snapshot(self.root, "vt", "restored")
        sizes.assert_called_once()
        self.assertEqual(result["exit_code"], 1)
        self.assertEqual(result["phase"], "restored")

    def test_command_errors_are_redacted_and_reports_do_not_turn_failure_green(self):
        with mock.patch.object(ci_cache, "snapshot", side_effect=ValueError("secret-value")), \
                contextlib.redirect_stdout(io.StringIO()) as stdout:
            code = ci_cache.main(["snapshot", "--suite", "vt", "--phase", "restored"])
        self.assertEqual(code, 2)
        self.assertNotIn("secret-value", stdout.getvalue())
        self.assertIn("ValueError", stdout.getvalue())
        with mock.patch.object(ci_cache, "probe", return_value={"exit_code": 7}), \
                mock.patch.object(Path, "write_text", side_effect=PermissionError), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ci_cache.main(["probe", "--suite", "vt", "--json", str(self.root / "report.json")]), 7)


class CleanupTests(unittest.TestCase):
    def windows_probe(self, taskkill_result, *, interrupted=False, parent_error=None):
        process = mock.Mock(pid=12345)
        process.poll.return_value = None
        stop_reason = KeyboardInterrupt() if interrupted else subprocess.TimeoutExpired("build", 1)
        process.wait.side_effect = [stop_reason, parent_error or 0]
        run_options = ({"side_effect": taskkill_result} if isinstance(taskkill_result, BaseException)
                       else {"return_value": SimpleNamespace(returncode=taskkill_result)})
        with mock.patch.object(ci_cache.os, "name", "nt"), \
                mock.patch.object(zig_test, "build_command", return_value=["fake-build"]), \
                mock.patch.object(ci_cache.subprocess, "Popen", return_value=process), \
                mock.patch.object(ci_cache.subprocess, "run", **run_options) as taskkill, \
                contextlib.redirect_stdout(io.StringIO()):
            report = ci_cache.probe(SCRIPTS.parent, "vt", [], 1)
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=1), mock.call(timeout=10)])
        self.assertEqual(taskkill.call_args.args[0][1:], ["/PID", "12345", "/T", "/F"])
        self.assertEqual(taskkill.call_args.kwargs["timeout"], 10)
        return report

    def test_windows_taskkill_nonzero_is_reported_without_losing_timeout(self):
        report = self.windows_probe(5)
        self.assertEqual(report["cleanup_error"], [{"stage": "taskkill", "exit_code": 5}])
        self.assertEqual(report["exit_code"], 124)
        self.assertTrue(report["timed_out"])
        self.assertFalse(report["interrupted"])

    def test_windows_taskkill_exceptions_are_reported_and_parent_is_reaped(self):
        for error in (FileNotFoundError("secret"), PermissionError("secret"), subprocess.TimeoutExpired("taskkill", 10)):
            with self.subTest(error=type(error).__name__):
                report = self.windows_probe(error)
                self.assertEqual(report["cleanup_error"], [{"stage": "taskkill", "error_type": type(error).__name__}])
                self.assertEqual(report["exit_code"], 124)
                self.assertTrue(report["timed_out"])
                self.assertNotIn("secret", json.dumps(report))

    def test_cleanup_failure_preserves_interrupt_exit_code(self):
        report = self.windows_probe(5, interrupted=True)
        self.assertEqual(report["exit_code"], 130)
        self.assertTrue(report["interrupted"])
        self.assertFalse(report["timed_out"])
        self.assertEqual(report["cleanup_error"], [{"stage": "taskkill", "exit_code": 5}])

    def test_parent_reap_failure_is_also_visible(self):
        report = self.windows_probe(5, parent_error=subprocess.TimeoutExpired("parent", 10))
        self.assertEqual(report["exit_code"], 124)
        self.assertTrue(report["timed_out"])
        self.assertEqual(report["cleanup_error"], [{"stage": "taskkill", "exit_code": 5},
                                                  {"stage": "wait_parent", "error_type": "TimeoutExpired"}])


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        (self.root / "build.zig.zon").write_text('.{\n.version = "1.3.2-dev",\n}', encoding="utf-8")

    def invoke(self, source: str, suite: str = "vt", *extra: str):
        (self.root / "scripts" / "zigw.py").write_text(source, encoding="utf-8")
        report = self.root / "report.json"
        completed = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "probe", "--suite", suite, "--root", str(self.root),
             "--json", str(report), *extra], capture_output=True, text=True, encoding="utf-8", timeout=20,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        return completed, json.loads(report.read_text(encoding="utf-8")) if report.exists() else None

    def test_real_subprocess_failure_is_not_swallowed(self):
        completed, report = self.invoke("raise SystemExit(7)\n")
        self.assertEqual(completed.returncode, 7, completed.stderr)
        self.assertEqual(report["exit_code"], 7)
        self.assertFalse(report["timed_out"])
        self.assertEqual(report["command"], zig_test.build_command(self.root, "vt", [], ["--summary", "all"]))
        self.assertIn("test-lib-vt-bin", completed.stdout)

    def test_main_rebuild_uses_same_defines_and_pinned_version_without_tests(self):
        completed, report = self.invoke("raise SystemExit(0)\n", "main", "-Dapp-runtime=none")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(report["command"], zig_test.build_command(self.root, "main", ["app-runtime=none"],
                                                                 ["--summary", "all"]))
        self.assertIn("test-bin", report["command"])
        self.assertNotIn("test", report["command"])
        self.assertGreaterEqual(report["seconds"], 0)

    def test_explicit_version_is_preserved(self):
        completed, report = self.invoke("raise SystemExit(0)\n", "vt", "-Dversion-string=1.3.2-test")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual([part for part in report["command"] if part.startswith("-Dversion-string=")],
                         ["-Dversion-string=1.3.2-test"])

    def test_timeout_kills_the_build_and_returns_124(self):
        completed, report = self.invoke("import time\ntime.sleep(60)\n", "vt", "--timeout", "1")
        self.assertEqual(completed.returncode, 124, completed.stderr)
        self.assertTrue(report["timed_out"])
        self.assertIsNone(report["cleanup_error"])
        self.assertEqual(report["timeout_seconds"], 1)
        self.assertLess(report["seconds"], 15)

    def test_timeout_reaps_wrapper_and_closes_live_child_socket(self):
        with socket.create_server(("127.0.0.1", 0)) as server:
            server.settimeout(10)
            port = server.getsockname()[1]
            child = ("import socket\n"
                     f"connection = socket.create_connection(('127.0.0.1', {port}), timeout=10)\n"
                     "connection.settimeout(15)\n"
                     "connection.sendall(b'R')\n"
                     "connection.recv(1)\n")
            wrapper = ("import subprocess, sys\n"
                       f"subprocess.run([sys.executable, '-c', {child!r}], stdout=subprocess.DEVNULL, "
                       "stderr=subprocess.DEVNULL, timeout=15, check=True)\n")
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(self.invoke, wrapper, "vt", "--timeout", "5")
                with server.accept()[0] as connection:
                    connection.settimeout(5)
                    self.assertEqual(connection.recv(1), b"R")
                    completed, report = future.result(timeout=15)
                    self.assertEqual(completed.returncode, 124, completed.stderr)
                    self.assertEqual(report["exit_code"], 124)
                    self.assertTrue(report["timed_out"])
                    self.assertIsNone(report["cleanup_error"])
                    try:
                        closed = connection.recv(1) == b""
                    except ConnectionResetError:
                        closed = True
                    self.assertTrue(closed, "the child still owns its live socket after probe cleanup")

    def test_timeout_bounds_and_suite_validation(self):
        for args in (("--timeout", "0"), ("--timeout", "1801"), ("--timeout", "nan")):
            with self.subTest(args=args):
                completed, report = self.invoke("raise SystemExit(0)\n", "vt", *args)
                self.assertEqual(completed.returncode, 2)
                self.assertIsNone(report)

    def test_build_command_errors_return_nonzero_without_launching(self):
        (self.root / "build.zig.zon").write_text("invalid", encoding="utf-8")
        completed, report = self.invoke("raise SystemExit(0)\n")
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(report["error_type"], "FatalError")


if __name__ == "__main__":
    unittest.main()
