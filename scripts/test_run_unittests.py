#!/usr/bin/env python3
"""scripts/run_unittests.py 测试：单元发现与选择、结果汇总、退出码、耗时缓存、超时终止与信号中断。

每个用例在临时目录里写一棵 scripts/test_*.py 夹具树，子进程是真实的 python -m unittest；
不读写真实仓库的耗时缓存。
"""

from __future__ import annotations

import contextlib
import io
import json
import math
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import run_unittests as runner  # noqa: E402

SCRIPT = SCRIPTS / "run_unittests.py"
PID_FILE_ENV = "GX_RUN_UNITTESTS_TEST_PID_FILE"

ALPHA = """
    import unittest


    class _Mixin:
        def test_not_a_unit(self):
            raise AssertionError("a plain mixin is not collected")


    class AlphaTests(unittest.TestCase):
        def test_one(self):
            self.assertEqual(2, 1 + 1)

        @unittest.skip("fixture skip")
        def test_skipped(self):
            raise AssertionError("skipped")


    class BetaTests(unittest.TestCase):
        def test_two(self):
            print("passing-output-marker")


    class NoTests(unittest.TestCase):
        def helper(self):
            return None
"""
GAMMA = """
    import unittest


    class GammaTests(unittest.TestCase):
        def test_kept(self):
            pass

        def test_dropped_by_load_tests(self):
            raise AssertionError("load_tests drops this test")


    def load_tests(loader, tests, pattern):
        return unittest.TestSuite([GammaTests("test_kept")])
"""
BAD = """
    import os
    import unittest


    class CrashingTests(unittest.TestCase):
        def test_crashes(self):
            print("crash-marker", flush=True)
            os._exit(3)


    class ErroringTests(unittest.TestCase):
        def test_errors(self):
            raise RuntimeError("error-marker")


    class FailingTests(unittest.TestCase):
        def test_fails(self):
            self.assertEqual("expected-marker", "actual-marker")


    class PassingTests(unittest.TestCase):
        def test_passes(self):
            print("passing-output-marker")
"""
BROKEN = """
    raise ImportError("broken-marker")
"""
LATE = """
    import unittest


    class LateTests(unittest.TestCase):
        RUN_LAST = True

        def test_late(self):
            pass


    class TruthyTests(unittest.TestCase):
        RUN_LAST = "yes"

        def test_truthy(self):
            pass
"""
# The parent imports this module as test_shift, the child as scripts.test_shift.
SHIFT = """
    import unittest


    class ShiftTests(unittest.TestCase):
        def test_always(self):
            pass


    if __name__.startswith("scripts."):
        ShiftTests.test_only_in_the_child = lambda self: None
"""
SLOW = """
    import os
    import subprocess
    import sys
    import time
    import unittest
    from pathlib import Path


    class SlowTests(unittest.TestCase):
        def test_hangs(self):
            pid_file = os.environ.get("GX_RUN_UNITTESTS_TEST_PID_FILE")
            if pid_file:
                child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
                Path(pid_file).write_text(f"{os.getpid()} {child.pid}\\n", encoding="utf-8")
                child.wait()
            time.sleep(60)
"""


def _alive(pid: int) -> bool:
    if os.name == "nt":
        import ctypes

        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
        if not handle:
            return False
        try:
            return kernel32.WaitForSingleObject(handle, 0) == 0x102  # WAIT_TIMEOUT: still running
        finally:
            kernel32.CloseHandle(handle)
    proc = Path("/proc")
    if proc.is_dir():
        try:
            state = (proc / str(pid) / "stat").read_text().rpartition(")")[2].split()[0]
        except (FileNotFoundError, ProcessLookupError):  # reaped before or between open and read
            return False
        # A killed process stays a zombie until its new parent reaps it.
        return state not in ("Z", "X")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _stop(process: subprocess.Popen, pids: list[int]) -> None:
    """Kill what a failed signal test leaves behind: the runner and any recorded unit process."""
    if process.poll() is None:
        process.kill()
    process.communicate()
    for pid in pids:
        if _alive(pid):
            with contextlib.suppress(OSError):
                os.kill(pid, signal.SIGKILL)


class RunnerCase(unittest.TestCase):
    def make_root(self, **modules: str) -> Path:
        """A temporary repository root whose scripts/ holds the given test modules."""
        tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()
        for name, text in modules.items():
            path = root / "scripts" / f"{name}.py"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")
        (root / "scripts").mkdir(exist_ok=True)
        return root

    def main(self, root: Path, *args: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = runner.main(["--root", str(root), "--jobs", "4", *args])
        return code, stdout.getvalue(), stderr.getvalue()

    def cache(self, root: Path) -> Path:
        return root / ".local" / "test-timings" / "unittest.json"

    def wait_for_pids(self, pid_file: Path, process: subprocess.Popen) -> list[int]:
        """The PIDs the SLOW fixture records once its unit runs: the unit's own, then its child's."""
        deadline = time.monotonic() + 30
        while True:
            text = pid_file.read_text(encoding="utf-8") if pid_file.is_file() else ""
            if text.endswith("\n"):
                return [int(pid) for pid in text.split()]
            if process.poll() is not None:
                self.fail(f"the process exited with {process.returncode} before the unit started its child")
            self.assertLess(time.monotonic(), deadline, "the unit never started its child")
            time.sleep(0.02)


class SummaryParsingTests(unittest.TestCase):
    def test_ok_failed_and_empty_summaries(self) -> None:
        cases = {
            "Ran 3 tests in 0.010s\n\nOK\n": ("OK", runner.Counts(tests=3)),
            "Ran 1 test in 0.001s\n\nOK (skipped=1)\n": ("OK", runner.Counts(tests=1, skipped=1)),
            "Ran 0 tests in 0.000s\n\nNO TESTS RAN\n": ("NO TESTS RAN", runner.Counts()),
            (
                "Ran 9 tests in 1.5s\n\nFAILED (failures=1, errors=2, skipped=3, "
                "expected failures=1, unexpected successes=1)\n"
            ): (
                "FAILED",
                runner.Counts(tests=9, failures=1, errors=2, skipped=3, expected_failures=1, unexpected_successes=1),
            ),
        }
        for text, (status, counts) in cases.items():
            with self.subTest(text=text):
                self.assertEqual(runner.Summary(status, counts), runner.parse_summary(text))

    def test_last_block_wins_and_crlf_or_trailing_output_is_tolerated(self) -> None:
        text = (
            "Ran 5 tests in 0.1s\r\n\r\nOK\r\n"  # printed by a test, not the runner
            "Traceback ...\r\n----------------------------------------------------------------------\r\n"
            "Ran 2 tests in 0.020s\r\n\r\nFAILED (errors=1)\r\nException ignored in: <thread>\r\n"
        )
        self.assertEqual(runner.Summary("FAILED", runner.Counts(tests=2, errors=1)), runner.parse_summary(text))

    def test_missing_or_malformed_summary_is_none(self) -> None:
        for text in ("", "Segmentation fault\n", "Ran 2 tests in 0.1s\n\n", "Ran 2 tests in 0.1s\n\nFAILED (weird=1)\n"):
            with self.subTest(text=text):
                self.assertIsNone(runner.parse_summary(text))


class DiscoveryTests(RunnerCase):
    def test_units_are_test_case_classes_or_load_tests_modules(self) -> None:
        root = self.make_root(test_alpha=ALPHA, test_gamma=GAMMA, test_empty="import unittest\n", helper="x = 1\n")
        (root / "scripts" / "notes").mkdir()
        (root / "scripts" / "notes" / "test_hidden.py").write_text("raise ImportError('never imported')\n", encoding="utf-8")
        tests_dir = root / "scripts"
        modules = runner.discover_modules(tests_dir)
        self.assertEqual(["test_alpha", "test_empty", "test_gamma"], modules)
        units = runner.load_units(tests_dir, modules)
        self.assertEqual(
            [runner.Unit("test_alpha.AlphaTests", 2), runner.Unit("test_alpha.BetaTests", 1), runner.Unit("test_gamma", 1)],
            units,
        )
        # The fixture modules are forgotten again, so another root can reuse their names.
        self.assertNotIn("test_alpha", sys.modules)
        self.assertNotIn(str(tests_dir), sys.path)
        self.assertEqual([sys.executable, "-m", "unittest", "-q", "scripts.test_alpha.BetaTests"], runner.unit_command(units[1]))

    def test_patterns_select_modules_classes_and_globs(self) -> None:
        root = self.make_root(test_alpha=ALPHA, test_gamma=GAMMA)
        cases = {
            ("test_alpha",): ["test_alpha.AlphaTests", "test_alpha.BetaTests"],
            ("scripts/test_alpha.py",): ["test_alpha.AlphaTests", "test_alpha.BetaTests"],
            ("scripts\\test_gamma.py",): ["test_gamma"],
            ("scripts.test_alpha.BetaTests",): ["test_alpha.BetaTests"],
            ("test_alpha.BetaTests", "test_gamma"): ["test_alpha.BetaTests", "test_gamma"],
            ("*Beta*",): ["test_alpha.BetaTests"],
            ("test_g*",): ["test_gamma"],
        }
        for patterns, expected in cases.items():
            with self.subTest(patterns=patterns):
                code, out, err = self.main(root, "--list", *patterns)
                self.assertEqual(0, code, err)
                listed = [line.split()[1] for line in out.splitlines()[:-1]]
                self.assertEqual(sorted(expected), sorted(listed))
        self.assertFalse(self.cache(root).exists(), "--list must not write the timing cache")

    def test_unmatched_patterns_and_bad_options_are_usage_errors(self) -> None:
        root = self.make_root(test_alpha=ALPHA)
        for patterns, fragment in (
            (("test_missing",), "test_missing"),
            (("test_alpha.NoSuchTests",), "test_alpha.NoSuchTests"),
            (("test_alpha.AlphaTests.test_one",), "test_alpha.AlphaTests.test_one"),
            (("*nothing*",), "*nothing*"),
        ):
            with self.subTest(patterns=patterns):
                code, out, err = self.main(root, *patterns)
                self.assertEqual(2, code)
                self.assertEqual("", out)
                self.assertIn(fragment, err)
        for args in (("--jobs", "0"), ("--timeout", "0"), ("--timeout", "nan"), ("--no-such-option",)):
            with self.subTest(args=args), self.assertRaises(SystemExit) as raised:
                self.main(root, *args)
            self.assertEqual(2, raised.exception.code)

    def test_import_failure_is_reported_and_nothing_runs(self) -> None:
        root = self.make_root(test_alpha=ALPHA, test_broken=BROKEN)
        code, out, err = self.main(root)
        self.assertEqual(2, code)
        self.assertEqual("", out)
        self.assertIn("test_broken", err)
        self.assertIn("broken-marker", err)
        self.assertFalse(self.cache(root).exists())

    def test_unrunnable_layouts_are_reported(self) -> None:
        root = self.make_root(test_alpha=ALPHA)
        package = root / "scripts" / "pkg"
        package.mkdir()
        (package / "__init__.py").write_text("", encoding="utf-8")
        (package / "test_nested.py").write_text("import unittest\n", encoding="utf-8")
        (root / "scripts" / "test_bad-name.py").write_text("import unittest\n", encoding="utf-8")
        code, _, err = self.main(root)
        self.assertEqual(2, code)
        self.assertIn("pkg/test_nested.py", err)
        self.assertIn("test_bad-name.py", err)
        for layout in (self.make_root(helper="x = 1\n"), self.make_root() / "missing"):
            with self.subTest(root=layout.name):
                self.assertEqual(2, self.main(layout)[0])


class RunTests(RunnerCase):
    def test_passing_run_aggregates_counts_and_records_timings(self) -> None:
        root = self.make_root(test_alpha=ALPHA, test_gamma=GAMMA)
        code, out, err = self.main(root)
        self.assertEqual(0, code, out + err)
        lines = out.splitlines()
        self.assertEqual("run_unittests: 3 units, 4 tests, 2 modules; jobs=4", lines[0])
        self.assertEqual(3, sum(1 for line in lines if line.startswith("[") and "] ok " in line))
        self.assertIn("最慢的 3 个单元：", lines)
        self.assertRegex(out, r"Ran 4 tests in 3 units; wall \d+\.\d\ds \(jobs=4, unit total \d+\.\d\ds\)")
        self.assertEqual("OK (skipped=1)", lines[-1])
        self.assertNotIn("passing-output-marker", out)
        raw = self.cache(root).read_bytes()
        self.assertNotIn(b"\r", raw)
        cache = json.loads(raw)
        self.assertEqual(1, cache["version"])
        self.assertEqual(["test_alpha.AlphaTests", "test_alpha.BetaTests", "test_gamma"], list(cache["units"]))
        self.assertTrue(all(isinstance(value, float) and value >= 0 for value in cache["units"].values()))

    def test_failures_errors_and_crashes_exit_1_with_their_full_output(self) -> None:
        root = self.make_root(test_bad=BAD)
        code, out, _ = self.main(root)
        self.assertEqual(1, code)
        labels = {line.split()[3]: line.split()[1] for line in out.splitlines() if line.startswith("[")}
        self.assertEqual(
            {
                "test_bad.CrashingTests": "CRASH",
                "test_bad.ErroringTests": "FAIL",
                "test_bad.FailingTests": "FAIL",
                "test_bad.PassingTests": "ok",
            },
            labels,
        )
        for marker in ("expected-marker", "error-marker", "crash-marker", "退出码 3"):
            self.assertIn(marker, out)
        self.assertIn("复现：python -m unittest scripts.test_bad.FailingTests", out)
        self.assertNotIn("passing-output-marker", out)
        self.assertEqual("FAILED (failures=1, errors=2, failed units=3)", out.splitlines()[-1])

    def test_child_running_other_tests_than_discovered_fails(self) -> None:
        root = self.make_root(test_shift=SHIFT)
        code, out, _ = self.main(root)
        self.assertEqual(1, code)
        self.assertIn("发现阶段有 1 个测试，子进程运行了 2 个", out)
        self.assertEqual("FAILED (errors=1, failed units=1)", out.splitlines()[-1])

    def test_timeout_kills_the_unit(self) -> None:
        root = self.make_root(test_slow=SLOW)
        started = time.monotonic()
        code, out, _ = self.main(root, "--timeout", "0.3")
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(1, code)
        self.assertIn("] TIMEOUT ", out)
        self.assertIn("--timeout 0.3s", out)

    def test_kill_tree_reaches_grandchildren(self) -> None:
        root = self.make_root(test_slow=SLOW)
        pid_file = root / "pids"
        environment = dict(os.environ, **{PID_FILE_ENV: str(pid_file)})
        item = runner._start(runner.Unit("test_slow.SlowTests", 1), root, environment)
        try:
            _, grandchild = self.wait_for_pids(pid_file, item.process)
            runner._kill_tree(item.process)
        finally:
            runner._kill_tree(item.process)
            item.stdout.close()
            item.stderr.close()
        self.assertIsNotNone(item.process.returncode)
        deadline = time.monotonic() + 10
        while _alive(grandchild) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(_alive(grandchild), "the grandchild outlived the killed unit")

    def test_termination_signals_interrupt_only_while_units_run(self) -> None:
        root = self.make_root(test_alpha=ALPHA)
        signums = [getattr(signal, name) for name in ("SIGTERM", "SIGHUP") if hasattr(signal, name)]
        seen: list[dict[int, object]] = []
        run_units = runner.run_units

        def dispositions() -> dict[int, object]:
            return {signum: signal.getsignal(signum) for signum in signums}

        def spy(*args: object, **kwargs: object) -> list[runner.UnitResult]:
            seen.append(dispositions())
            return run_units(*args, **kwargs)

        for signum, handler in dispositions().items():
            self.addCleanup(signal.signal, signum, handler)
        with mock.patch.object(runner, "run_units", spy):
            for disposition in (signal.SIG_DFL, signal.SIG_IGN):
                for signum in signums:
                    signal.signal(signum, disposition)
                code, out, err = self.main(root, "test_alpha.BetaTests")
                self.assertEqual(0, code, out + err)
                self.assertEqual(dict.fromkeys(signums, disposition), dispositions())
        # Like Python's own SIGINT handler, a signal the parent ignores (nohup) stays ignored.
        self.assertEqual(
            [dict.fromkeys(signums, signal.default_int_handler), dict.fromkeys(signums, signal.SIG_IGN)], seen
        )


class TimingCacheTests(RunnerCase):
    def test_default_jobs_is_the_cpu_count_capped(self) -> None:
        for cpus, expected in ((None, 1), (1, 1), (4, 4), (8, 8), (20, runner.DEFAULT_MAX_JOBS)):
            with self.subTest(cpus=cpus), mock.patch.object(runner.os, "cpu_count", return_value=cpus):
                self.assertEqual(expected, runner.default_jobs())
        self.assertEqual(8, runner.DEFAULT_MAX_JOBS)

    def test_schedule_runs_unknown_then_slowest_first_and_run_last_at_the_end(self) -> None:
        units = [runner.Unit(name, 1) for name in ("t.A", "t.B", "t.C", "t.D", "t.E")]
        units += [runner.Unit("t.F", 1, last=True), runner.Unit("t.G", 1, last=True)]
        timings = {"t.A": 1.0, "t.B": 5.0, "t.D": 5.0, "t.E": 0.0, "t.F": 99.0}
        self.assertEqual(
            ["t.C", "t.B", "t.D", "t.A", "t.E", "t.G", "t.F"], [unit.id for unit in runner.schedule(units, timings)]
        )

    def test_run_last_attribute_is_read_from_the_class(self) -> None:
        root = self.make_root(test_alpha=ALPHA, test_late=LATE)
        self.cache(root).parent.mkdir(parents=True)
        self.cache(root).write_text(json.dumps({"version": 1, "units": {"test_late.LateTests": 50.0}}), encoding="utf-8")
        code, out, err = self.main(root, "--list")
        self.assertEqual(0, code, err)
        lines = out.splitlines()[:-1]
        self.assertEqual("test_late.LateTests", lines[-1].split()[1])
        self.assertTrue(lines[-1].endswith("(1 test, RUN_LAST)"), lines[-1])
        self.assertEqual(1, sum("RUN_LAST" in line for line in lines), "only RUN_LAST = True counts")

    def test_cache_orders_runs_and_is_merged_back(self) -> None:
        root = self.make_root(test_alpha=ALPHA, test_gamma=GAMMA)
        self.cache(root).parent.mkdir(parents=True)
        previous = {
            "test_alpha.AlphaTests": 1.0,
            "test_alpha.BetaTests": 5.0,
            "test_alpha.RemovedTests": 7.0,
            "test_gone.OldTests": 9.0,
        }
        self.cache(root).write_text(json.dumps({"version": 1, "units": previous}), encoding="utf-8")
        expected_order = ["test_gamma", "test_alpha.BetaTests", "test_alpha.AlphaTests"]
        code, out, err = self.main(root, "--list")
        self.assertEqual(0, code, err)
        self.assertEqual(expected_order, [line.split()[1] for line in out.splitlines()[:-1]])
        self.assertEqual(["-", "5.00s", "1.00s"], [line.split()[0] for line in out.splitlines()[:-1]])
        self.assertEqual("3 units, 4 tests, 2 modules", out.splitlines()[-1])
        # One job runs the units strictly in schedule order.
        code, out, err = self.main(root, "--jobs", "1")
        self.assertEqual(0, code, out + err)
        self.assertEqual(expected_order, [line.split()[3] for line in out.splitlines() if line.startswith("[")])
        units = json.loads(self.cache(root).read_text(encoding="utf-8"))["units"]
        # RemovedTests vanished from an imported module and test_gone.py no longer exists.
        self.assertEqual(["test_alpha.AlphaTests", "test_alpha.BetaTests", "test_gamma"], sorted(units))
        self.assertNotEqual(5.0, units["test_alpha.BetaTests"])
        # Running one module keeps the records of modules that were not imported.
        code, out, err = self.main(root, "test_gamma")
        self.assertEqual(0, code, out + err)
        self.assertEqual(sorted(units), sorted(json.loads(self.cache(root).read_text(encoding="utf-8"))["units"]))

    def test_unusable_cache_is_ignored_and_replaced(self) -> None:
        root = self.make_root(test_alpha=ALPHA)
        self.cache(root).parent.mkdir(parents=True)
        for text in ("not json", '{"version": 99, "units": {"test_alpha.AlphaTests": 3}}', '{"version": 1, "units": []}'):
            with self.subTest(text=text):
                self.cache(root).write_text(text, encoding="utf-8")
                self.assertEqual({}, runner.load_timings(self.cache(root)))
        self.cache(root).write_text(
            '{"version": 1, "units": {"a.B": 2, "a.C": true, "a.D": -1, "a.E": "1", "a.F": 1e999}}', encoding="utf-8"
        )
        self.assertEqual({"a.B": 2.0}, runner.load_timings(self.cache(root)))
        self.cache(root).write_text("not json", encoding="utf-8")
        code, out, err = self.main(root, "test_alpha.BetaTests")
        self.assertEqual(0, code, out + err)
        units = json.loads(self.cache(root).read_text(encoding="utf-8"))["units"]
        self.assertEqual(["test_alpha.BetaTests"], list(units))
        self.assertTrue(math.isfinite(units["test_alpha.BetaTests"]))


class CommandLineTests(RunnerCase):
    def run_script(self, root: Path, *args: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(root), "--jobs", "2", *args],
            capture_output=True,
            timeout=120,
            check=False,
        )

    def test_exit_codes_and_lf_utf8_output(self) -> None:
        root = self.make_root(test_alpha=ALPHA, test_bad=BAD)
        passed = self.run_script(root, "test_alpha.BetaTests")
        self.assertEqual(0, passed.returncode, passed.stderr)
        self.assertNotIn(b"\r\n", passed.stdout)
        self.assertIn("最慢的 1 个单元：", passed.stdout.decode("utf-8"))
        self.assertEqual(1, self.run_script(root, "test_bad.FailingTests").returncode)
        broken = self.make_root(test_broken=BROKEN)
        failed_import = self.run_script(broken)
        self.assertEqual(2, failed_import.returncode)
        self.assertIn("broken-marker", failed_import.stderr.decode("utf-8"))

    @unittest.skipUnless(os.name == "posix", "only POSIX delivers SIGTERM to a running process as a signal")
    def test_sigterm_kills_the_running_units_and_exits_130(self) -> None:
        root = self.make_root(test_slow=SLOW)
        pid_file = root / "pids"
        pids: list[int] = []
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--root", str(root), "--jobs", "1"],
            env=dict(os.environ, **{PID_FILE_ENV: str(pid_file)}),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.addCleanup(_stop, process, pids)
        pids += self.wait_for_pids(pid_file, process)
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        output = (stdout + stderr).decode("utf-8", "replace")
        self.assertEqual(130, process.returncode, output)
        self.assertIn("run_unittests: 已中断，运行中的单元已终止", output)
        deadline = time.monotonic() + 10
        while any(_alive(pid) for pid in pids) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual([], [pid for pid in pids if _alive(pid)], "unit processes outlived the interrupted run")


if __name__ == "__main__":
    unittest.main()
