#!/usr/bin/env python3
"""scripts/zig_test.py 测试：用 Python 伪测试二进制覆盖并行运行器的协议、判定、调度与 CLI 契约。

伪二进制按 std.zig.Server 协议应答（zig_version 握手、test_metadata、test_started、test_results），
行为由同名 .json 描述：pass / skip / fail 带 stderr、泄漏、error 日志、用例中途崩溃、挂起、大量
stderr、多余消息、首次启动失败，以及派生一个继承 stdout/stderr 管道的孙进程：孙进程回连测试里的
Listener，活着时连接一直开着，死后连接随即关闭，据此判断运行器是否连进程树一起杀掉。zig_test 以
当前解释器启动 .py 二进制；每个用例用临时目录当 --root（耗时缓存与 .zig-cache 都落在那里），不写
真实仓库，不运行真实 zig：--suite 路径用临时根里记录参数的伪 scripts/zigw.py，并把 SUITES 换成
安装前缀下的 .py 伪二进制。POSIX 专属的用例（崩溃后清进程组、SIGTERM/SIGHUP、符号链接）由
gx-ci 的 framework job（ubuntu）执行。
"""

from __future__ import annotations

import _thread
import contextlib
import io
import json
import os
import re
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path, PurePosixPath
from typing import Callable
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import zig_test  # noqa: E402

SCRIPT = SCRIPTS / "zig_test.py"
FAKE_RUNNER = r'''
import json, os, struct, subprocess, sys, time
from pathlib import Path

SPEC = json.loads(Path(__file__).with_suffix(".json").read_text(encoding="utf-8"))
TESTS = SPEC["tests"]
OUT, IN = sys.stdout.buffer, sys.stdin.buffer
GRANDCHILD = (
    "import socket, sys\n"
    "connection = socket.create_connection(('127.0.0.1', int(sys.argv[1])))\n"
    "open(sys.argv[2], 'w').close()\n"
    "connection.settimeout(60)\n"
    "try:\n"
    "    connection.recv(1)\n"
    "except OSError:\n"
    "    pass\n"
)


def record(event, **fields):
    directory = SPEC.get("records")
    if directory:
        line = json.dumps({"event": event, "pid": os.getpid(), "time": time.time(), **fields})
        with open(os.path.join(directory, f"{os.getpid()}.jsonl"), "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def send(tag, body=b""):
    OUT.write(struct.pack("<II", tag, len(body)) + body)
    OUT.flush()


def metadata():
    strings, offsets = bytearray(b"\0"), []
    for test in TESTS:
        offsets.append(len(strings))
        strings += test["name"].encode("utf-8") + b"\0"
    count = len(TESTS)
    return (
        struct.pack("<II", len(strings), count)
        + struct.pack(f"<{count}I", *offsets)
        + struct.pack(f"<{count}I", *([0] * count))
        + bytes(strings)
    )


def spawn_grandchild(index):
    ready = os.path.join(SPEC["records"], f"ready-{os.getpid()}-{index}")
    child = subprocess.Popen(
        [sys.executable, "-c", GRANDCHILD, str(SPEC["port"]), ready],
        stdin=subprocess.DEVNULL,
        stdout=1,
        stderr=2,
    )
    while not os.path.exists(ready) and child.poll() is None:
        time.sleep(0.01)


def run(index):
    test = TESTS[index]
    record("run", index=index, name=test["name"])
    send(5)
    if test.get("stderr"):
        sys.stderr.write(test["stderr"])
        sys.stderr.flush()
    if test.get("grandchild"):
        spawn_grandchild(index)
    if test.get("stderr_bytes"):
        line = "x" * 1023 + "\n"
        for _ in range(test["stderr_bytes"] // 1024):
            sys.stderr.write(line)
        sys.stderr.write(test.get("stderr_tail", ""))
        sys.stderr.flush()
    if test.get("sleep"):
        time.sleep(test["sleep"])
    if test.get("crash"):
        os._exit(test.get("exit_code", 3))
    if test.get("noise"):
        send(12, b"unrelated message")
    status = {"pass": 0, "fail": 1, "skip": 2}[test.get("status", "pass")]
    flags = status | test.get("log_err", 0) << 3 | test.get("leak", 0) << 33
    send(4, struct.pack("<IQ", index, flags))


def main():
    args = sys.argv[1:]
    record("start", args=args, cwd=os.getcwd())
    for arg in args:
        if arg != "--listen=-" and not arg.startswith(("--seed=", "--cache-dir=")):
            sys.stderr.write(f"unrecognized command line argument: {arg}\n")
            sys.exit(1)
    marker = SPEC.get("fail_first_start")
    if SPEC.get("never_start") or (marker and not os.path.exists(marker)):
        if marker:
            open(marker, "w").close()
        sys.stderr.write("startup failure\n")
        sys.exit(5)
    send(0, b"0.16.0")
    while True:
        header = IN.read(8)
        if len(header) < 8:
            return
        tag, length = struct.unpack("<II", header)
        body = IN.read(length) if length else b""
        if tag == 0:
            sys.exit(0)
        elif tag == 4:
            send(3, metadata())
        elif tag == 5:
            run(struct.unpack("<I", body)[0])
        else:
            sys.stderr.write(f"unsupported message: {tag:x}\n")
            sys.exit(1)


main()
'''


TREE_KILL = os.name == "nt" or sys.version_info >= (3, 11)
NO_TREE_KILL = "POSIX 上要 Python 3.11+（Popen 的 process_group）测试进程才自成进程组，运行器才能杀进程树"


def same_path(left: str | Path, right: str | Path) -> bool:
    return os.path.normcase(os.path.realpath(left)) == os.path.normcase(os.path.realpath(right))


def split_command(command: str) -> list[str]:
    """按当前平台的规则把一行命令切成 argv：POSIX 用 shlex.split，Windows 用 CommandLineToArgvW（与 C 运行库
    解析命令行的规则一致，subprocess.list2cmdline 是它的逆运算）。"""
    if os.name != "nt":
        return shlex.split(command)
    import ctypes
    from ctypes import wintypes

    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    shell32.CommandLineToArgvW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
    shell32.CommandLineToArgvW.restype = ctypes.POINTER(wintypes.LPWSTR)
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    count = ctypes.c_int()
    argv = shell32.CommandLineToArgvW(command, ctypes.byref(count))
    if not argv:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return [argv[index] for index in range(count.value)]
    finally:
        kernel32.LocalFree(ctypes.cast(argv, ctypes.c_void_p))


class Listener:
    """收孙进程的回连：孙进程活着时连接一直开着，进程一死对端即关闭，recv 立刻返回。"""

    def __init__(self) -> None:
        self.server = socket.create_server(("127.0.0.1", 0))
        self.server.settimeout(0.05)
        self.port: int = self.server.getsockname()[1]
        self.connections: list[socket.socket] = []
        self._closed = threading.Event()
        self._thread = threading.Thread(target=self._accept, name="test-listener", daemon=True)
        self._thread.start()

    def _accept(self) -> None:
        while not self._closed.is_set():
            try:
                connection, _address = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections.append(connection)

    def close(self) -> None:
        self._closed.set()
        self._thread.join(5)
        self.server.close()
        for connection in self.connections:
            connection.close()


class FakeRunnerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.records = self.root / "records"
        self.records.mkdir()
        self._saved_delay = zig_test.SPAWN_RETRY_DELAY
        zig_test.SPAWN_RETRY_DELAY = 0.05
        self._listeners: list[Listener] = []
        environ = mock.patch.dict(os.environ)
        environ.start()
        self.addCleanup(environ.stop)
        os.environ.pop(zig_test.TIMINGS_ENV, None)

    def tearDown(self) -> None:
        for listener in self._listeners:
            listener.close()
        zig_test.SPAWN_RETRY_DELAY = self._saved_delay
        self._tmp.cleanup()

    def listen(self) -> Listener:
        listener = Listener()
        self._listeners.append(listener)
        return listener

    def ready_markers(self) -> list[Path]:
        return sorted(self.records.glob("ready-*"))

    def wait_until(self, condition: Callable[[], bool], timeout: float = 15.0) -> bool:
        deadline = time.monotonic() + timeout
        while not condition():
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.02)
        return True

    def assert_grandchildren_gone(self, listener: Listener, expected: int) -> None:
        self.assertEqual(expected, len(self.ready_markers()), "孙进程没有全部起来")
        self.assertTrue(self.wait_until(lambda: len(listener.connections) >= expected, 5), listener.connections)
        for connection in listener.connections:
            connection.settimeout(5)
            try:
                data = connection.recv(1)
            except socket.timeout:
                self.fail("测试进程派生的孙进程在运行器返回后仍然活着")
            except ConnectionError:
                data = b""
            self.assertEqual(b"", data)

    @contextlib.contextmanager
    def joins_only_finished_workers(self):
        """Worker.join 只能在 done 置位之后调用：CPython 3.12 及更早版本里，join(timeout) 被 KeyboardInterrupt
        打断时会把仍在运行的线程标成已结束（gx-ci 的 ubuntu 3.12 上因此少记了一个 not_run）。"""
        original = zig_test.Worker.join
        early: list[str] = []

        def join(worker: zig_test.Worker, timeout: float | None = None) -> None:
            if not worker.done.is_set():
                early.append(worker.name)
            original(worker, timeout)

        with mock.patch.object(zig_test.Worker, "join", join):
            yield
        self.assertEqual([], early, "运行器在 worker 结束前调用了 Thread.join")

    def assert_no_leaked_threads(self, before: set[threading.Thread]) -> None:
        leaked = [thread.name for thread in threading.enumerate() if thread not in before and thread.name.startswith("zig-test-")]
        self.assertEqual([], leaked, "运行器返回后仍有读管道或工作线程没结束")

    def fake(self, name: str, tests: list[dict], **spec: object) -> Path:
        script = self.root / f"{name}.py"
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(FAKE_RUNNER, encoding="utf-8")
        payload = {"tests": tests, "records": str(self.records), **spec}
        script.with_suffix(".json").write_text(json.dumps(payload), encoding="utf-8")
        return script

    def fake_zigw(self, exit_code: int = 0) -> Path:
        record = self.root / "zigw-args.json"
        zigw = self.root / "scripts" / "zigw.py"
        zigw.parent.mkdir(exist_ok=True)
        zigw.write_text(f"import json, sys\njson.dump(sys.argv[1:], open({str(record)!r}, 'w'))\nsys.exit({exit_code})\n", encoding="utf-8")
        (self.root / "build.zig.zon").write_text('.{ .version = "1.3.2-dev" }\n', encoding="utf-8")
        return record

    def fake_suite(self, suite: str, tests: list[dict]) -> contextlib.AbstractContextManager[object]:
        label = zig_test.SUITES[suite].binaries[0][0]
        self.fake(f"zig-out/test/{label}/test", tests)
        installed = zig_test.Suite(zig_test.SUITES[suite].step, ((label, f"test/{label}/test.py"),))
        return mock.patch.dict(zig_test.SUITES, {suite: installed})

    def run_main(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = zig_test.main(["--root", str(self.root), *args])
        return code, out.getvalue(), err.getvalue()

    def run_json(self, *args: str) -> tuple[int, dict, str]:
        report_path = self.root / "out" / "report.json"
        code, out, err = self.run_main(*args, "--json", str(report_path))
        return code, json.loads(report_path.read_text(encoding="utf-8")), out + err

    def events(self, kind: str) -> list[dict]:
        events = []
        for path in self.records.glob("*.jsonl"):
            events += [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
        return sorted((event for event in events if event["event"] == kind), key=lambda event: event["time"])

    def failure(self, report: dict, name: str) -> dict:
        return next(entry for entry in report["failures"] if entry["name"] == name)


class OutcomeTests(FakeRunnerTestCase):
    def test_mixed_outcomes_follow_zig_build_semantics(self) -> None:
        binary = self.fake(
            "mixed",
            [
                {"name": "ok"},
                {"name": "skipped", "status": "skip"},
                {"name": "broken", "status": "fail", "stderr": "expected 1, found 2\n"},
                {"name": "leaky", "leak": 2, "stderr": "leak trace\n"},
                {"name": "noisy", "log_err": 1, "stderr": "[scope] (err): boom\n"},
                {"name": "silent failure", "status": "fail"},
            ],
        )
        code, report, text = self.run_json("--binary", str(binary), "--jobs", "2", "--seed", "7")
        self.assertEqual(1, code, text)
        self.assertEqual(1, report["exit_code"])
        self.assertEqual(
            {"total": 6, "passed": 1, "skipped": 1, "failed": 2, "leaked": 1, "log_err": 1, "crashed": 0, "timeouts": 0, "not_run": 0},
            report["binaries"][0]["counts"],
        )
        self.assertEqual("failed", self.failure(report, "broken")["message"])
        self.assertIn("expected 1, found 2", self.failure(report, "broken")["output"])
        self.assertEqual("failed without output", self.failure(report, "silent failure")["message"])
        self.assertEqual("leaked 2 allocations", self.failure(report, "leaky")["message"])
        self.assertIn("leak trace", self.failure(report, "leaky")["output"])
        self.assertEqual("logged 1 errors", self.failure(report, "noisy")["message"])
        self.assertIn("expected 1, found 2", text)
        self.assertIn("FAIL 4 of 6 tests failed", text)
        self.assertIn("seed 0x7", text)

    def test_pass_and_skip_exit_zero_and_ignore_unknown_messages(self) -> None:
        binary = self.fake("green", [{"name": "a", "noise": True}, {"name": "b", "status": "skip"}, {"name": "c"}])
        code, out, err = self.run_main("--binary", str(binary), "--jobs", "2")
        self.assertEqual(0, code, out + err)
        self.assertIn("PASS 2 passed, 1 skipped", out)

    def test_classify_precedence_matches_eval_zig_test(self) -> None:
        task = zig_test.Task(zig_test.TestBinary("bin", Path("bin"), 0), 0, "t", 0.0)
        cases = [
            (zig_test.RunOutcome("result", status=1, leak_count=3, log_err_count=2), "fail"),
            (zig_test.RunOutcome("result", status=0, leak_count=3, log_err_count=2), "leak"),
            (zig_test.RunOutcome("result", status=2, log_err_count=1), "log_err"),
            (zig_test.RunOutcome("result", status=2), "skip"),
            (zig_test.RunOutcome("result", status=3), "fail"),
            (zig_test.RunOutcome("crash", detail="exited with code 3"), "crash"),
            (zig_test.RunOutcome("timeout"), "timeout"),
        ]
        for outcome, expected in cases:
            self.assertEqual(expected, zig_test.classify(task, outcome, 1.5).outcome, outcome)
        self.assertEqual("timed out after 1.5s", zig_test.classify(task, zig_test.RunOutcome("timeout"), 1.5).message)


class RecoveryTests(FakeRunnerTestCase):
    def test_crash_mid_test_is_reported_and_process_restarts(self) -> None:
        binary = self.fake(
            "crashy",
            [{"name": "t0"}, {"name": "t1 crashes", "crash": True, "exit_code": 3, "stderr": "panic: boom\n"}, {"name": "t2"}, {"name": "t3"}],
        )
        code, report, text = self.run_json("--binary", str(binary), "--jobs", "1")
        self.assertEqual(1, code, text)
        counts = report["binaries"][0]["counts"]
        self.assertEqual((3, 1), (counts["passed"], counts["crashed"]), counts)
        crash = self.failure(report, "t1 crashes")
        self.assertEqual("crash", crash["outcome"])
        self.assertIn("exited with code 3", crash["message"])
        self.assertIn("panic: boom", crash["output"])
        runs = {event["index"]: event["pid"] for event in self.events("run")}
        self.assertEqual(runs[0], runs[1])
        self.assertNotEqual(runs[1], runs[2])
        self.assertEqual(runs[2], runs[3])
        self.assertEqual(2, report["binaries"][0]["spawns"])

    def test_timeout_kills_process_and_continues(self) -> None:
        binary = self.fake("hang", [{"name": "hangs", "sleep": 30, "stderr": "about to hang\n"}, {"name": "after"}])
        started = time.monotonic()
        code, report, text = self.run_json("--binary", str(binary), "--jobs", "1", "--timeout", "1")
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(1, code, text)
        timeout = self.failure(report, "hangs")
        self.assertEqual(("timeout", "timed out after 1s"), (timeout["outcome"], timeout["message"]))
        self.assertIn("about to hang", timeout["output"])
        self.assertEqual(1, report["binaries"][0]["counts"]["passed"])

    def test_transient_startup_failure_is_retried(self) -> None:
        binary = self.fake("flaky", [{"name": "only"}], fail_first_start=str(self.root / "started-once"))
        code, out, err = self.run_main("--binary", str(binary), "--jobs", "1")
        self.assertEqual(0, code, out + err)
        self.assertEqual(2, len(self.events("start")))

    def test_binary_that_never_starts_exits_2(self) -> None:
        binary = self.fake("dead", [{"name": "only"}], never_start=True)
        code, out, err = self.run_main("--binary", str(binary))
        self.assertEqual(2, code, out + err)
        self.assertIn("startup failure", err)
        self.assertEqual(2, len(self.events("start")))

    def test_chatty_stderr_does_not_deadlock_and_is_bounded(self) -> None:
        binary = self.fake(
            "chatty",
            [
                {"name": "loud pass", "stderr_bytes": 2 << 20},
                {"name": "loud fail", "status": "fail", "stderr_bytes": 600 << 10, "stderr_tail": "END-MARKER\n"},
            ],
        )
        code, report, text = self.run_json("--binary", str(binary), "--jobs", "1")
        self.assertEqual(1, code, text)
        output = self.failure(report, "loud fail")["output"]
        self.assertIn("bytes omitted", output)
        self.assertTrue(output.endswith("END-MARKER"), output[-200:])
        self.assertLess(len(output), zig_test.CAPTURE_HEAD + zig_test.CAPTURE_TAIL + 200)
        self.assertEqual(1, report["binaries"][0]["counts"]["passed"])


class ProcessTreeTests(FakeRunnerTestCase):
    """超时、崩溃收尾与中断时连占着管道的孙进程一起杀；正常结束路径不杀任何进程。

    STDERR_EOF_WAIT 调大到 10 秒：只杀直接子进程时，孙进程占着管道，运行器要在等 stderr 与回收读线程上
    耗满这些时限（约 30 秒）并漏掉读线程，用墙钟上限就能区分。
    """

    def hanging(self, listener: Listener, count: int) -> Path:
        tests = [{"name": f"hangs with a child {index}", "grandchild": True, "sleep": 20} for index in range(count)]
        return self.fake("tree_hang", tests, port=listener.port)

    @unittest.skipUnless(TREE_KILL, NO_TREE_KILL)
    def test_timeout_kills_the_whole_process_tree(self) -> None:
        listener = self.listen()
        binary = self.hanging(listener, 1)
        before = set(threading.enumerate())
        started = time.monotonic()
        with mock.patch.object(zig_test, "STDERR_EOF_WAIT", 10.0):
            code, report, text = self.run_json("--binary", str(binary), "--jobs", "1", "--timeout", "1")
        elapsed = time.monotonic() - started
        self.assertEqual(1, code, text)
        self.assertEqual("timeout", self.failure(report, "hangs with a child 0")["outcome"])
        self.assertLess(elapsed, 6, text)
        self.assert_no_leaked_threads(before)
        self.assert_grandchildren_gone(listener, 1)

    @unittest.skipUnless(os.name == "posix" and TREE_KILL, "Windows 只在超时与中断时杀进程树；POSIX 还要 Python 3.11+")
    def test_crash_cleanup_kills_the_process_group(self) -> None:
        listener = self.listen()
        tests = [
            {"name": "crashes with a child", "grandchild": True, "crash": True, "exit_code": 3, "stderr": "panic: boom\n"},
            {"name": "after"},
        ]
        binary = self.fake("tree_crash", tests, port=listener.port)
        before = set(threading.enumerate())
        started = time.monotonic()
        with mock.patch.multiple(zig_test, STDERR_EOF_WAIT=10.0, EXIT_GRACE=0.2, POLL_INTERVAL=0.05):
            code, report, text = self.run_json("--binary", str(binary), "--jobs", "1")
        elapsed = time.monotonic() - started
        self.assertEqual(1, code, text)
        crash = self.failure(report, "crashes with a child")
        self.assertEqual(("crash", "crashed (exited with code 3)"), (crash["outcome"], crash["message"]))
        self.assertIn("panic: boom", crash["output"])
        self.assertEqual(1, report["binaries"][0]["counts"]["passed"])
        self.assertLess(elapsed, 6, text)
        self.assert_no_leaked_threads(before)
        self.assert_grandchildren_gone(listener, 1)

    @unittest.skipUnless(TREE_KILL, NO_TREE_KILL)
    def test_interrupt_kills_every_process_tree(self) -> None:
        listener = self.listen()
        binary = self.hanging(listener, 2)
        self.addCleanup(signal.signal, signal.SIGINT, signal.signal(signal.SIGINT, signal.default_int_handler))
        fired = threading.Event()

        def interrupt_once_running() -> None:
            if self.wait_until(lambda: len(self.ready_markers()) == 2):
                fired.set()
                _thread.interrupt_main()

        threading.Thread(target=interrupt_once_running, daemon=True).start()
        before = set(threading.enumerate())
        started = time.monotonic()
        with mock.patch.object(zig_test, "STDERR_EOF_WAIT", 10.0), self.joins_only_finished_workers():
            code, report, text = self.run_json("--binary", str(binary), "--jobs", "2")
        elapsed = time.monotonic() - started
        self.assertTrue(fired.is_set(), text)
        self.assertEqual((130, True), (code, report["interrupted"]), text)
        self.assertEqual(2, report["binaries"][0]["counts"]["not_run"])
        self.assertLess(elapsed, 8, text)
        self.assert_no_leaked_threads(before)
        self.assert_grandchildren_gone(listener, 2)

    def test_workers_are_joined_only_after_they_finish(self) -> None:
        binary = self.fake("joined", [{"name": f"t{index}", "sleep": 0.05} for index in range(6)])
        before = set(threading.enumerate())
        with self.joins_only_finished_workers():
            code, out, err = self.run_main("--binary", str(binary), "--jobs", "3")
        self.assertEqual(0, code, out + err)
        self.assert_no_leaked_threads(before)

    def test_normal_shutdown_never_kills(self) -> None:
        first = self.fake("calm_a", [{"name": f"a{index}"} for index in range(4)])
        second = self.fake("calm_b", [{"name": f"b{index}"} for index in range(4)])
        crashy = self.fake("calm_crash", [{"name": "exits by itself", "crash": True}])
        with mock.patch.object(zig_test, "taskkill_trees") as taskkill:
            with mock.patch.object(zig_test, "kill_processes", wraps=zig_test.kill_processes) as kills:
                for extra in (("--jobs", "3"), ("--list",)):
                    code, out, err = self.run_main("--binary", str(first), "--binary", str(second), *extra)
                    self.assertEqual(0, code, out + err)
                self.assertEqual([], kills.call_args_list)
                code, out, err = self.run_main("--binary", str(crashy), "--jobs", "1")
                self.assertEqual(1, code, out + err)
                self.assertTrue(kills.called)
        taskkill.assert_not_called()


@unittest.skipUnless(os.name == "posix", "SIGTERM、SIGHUP 只在 POSIX 上改走中断路径")
class SignalTests(FakeRunnerTestCase):
    def start_runner(self, listener: Listener) -> subprocess.Popen:
        tests = [{"name": f"hangs with a child {index}", "grandchild": True, "sleep": 20} for index in range(2)]
        binary = self.fake("signalled", tests, port=listener.port)
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONIOENCODING": "utf-8"}
        saved = {signum: signal.signal(signum, signal.SIG_DFL) for signum in (signal.SIGTERM, signal.SIGHUP)}
        try:
            runner = subprocess.Popen(
                [sys.executable, str(SCRIPT), "--root", str(self.root), "--binary", str(binary), "--jobs", "2"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                env=env,
            )
        finally:
            for signum, handler in saved.items():
                signal.signal(signum, handler)
        self.addCleanup(self.stop_runner, runner)
        self.wait_until(lambda: len(self.ready_markers()) == 2 or runner.poll() is not None)
        if runner.poll() is not None:
            out, err = runner.communicate()
            self.fail(f"运行器提前退出（{runner.returncode}）：{out}{err}")
        self.assertEqual(2, len(self.ready_markers()), "测试进程没有全部起来")
        return runner

    @staticmethod
    def stop_runner(runner: subprocess.Popen) -> None:
        if runner.poll() is None:
            runner.kill()
        runner.communicate()

    def interrupt_with(self, signum: int) -> None:
        listener = self.listen()
        runner = self.start_runner(listener)
        runner.send_signal(signum)
        out, err = runner.communicate(timeout=30)
        self.assertEqual(130, runner.returncode, out + err)
        self.assertIn("INTERRUPTED 0 passed, 2 not run", out)
        self.assert_grandchildren_gone(listener, 2)

    @unittest.skipUnless(TREE_KILL, NO_TREE_KILL)
    def test_sigterm_takes_the_interrupt_path(self) -> None:
        self.interrupt_with(signal.SIGTERM)

    @unittest.skipUnless(TREE_KILL, NO_TREE_KILL)
    def test_sighup_takes_the_interrupt_path(self) -> None:
        self.interrupt_with(signal.SIGHUP)

    def test_main_routes_default_signals_only_while_running(self) -> None:
        for signum in (signal.SIGTERM, signal.SIGHUP):
            self.addCleanup(signal.signal, signum, signal.signal(signum, signal.SIG_DFL))
        binary = self.fake("routed", [{"name": "only"}])
        run_workers = zig_test.run_workers
        seen: list[tuple[object, object]] = []

        def spy(*args: object, **kwargs: object) -> object:
            seen.append((signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGHUP)))
            return run_workers(*args, **kwargs)

        for hup, during in ((signal.SIG_DFL, signal.default_int_handler), (signal.SIG_IGN, signal.SIG_IGN)):
            signal.signal(signal.SIGHUP, hup)
            seen.clear()
            with mock.patch.object(zig_test, "run_workers", side_effect=spy):
                code, out, err = self.run_main("--binary", str(binary), "--jobs", "1")
            self.assertEqual(0, code, out + err)
            self.assertEqual([(signal.default_int_handler, during)], seen)
            self.assertEqual((signal.SIG_DFL, hup), (signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGHUP)))


class SelectionTests(FakeRunnerTestCase):
    def test_filter_is_substring_union_without_rebuild(self) -> None:
        binary = self.fake("sel", [{"name": "alpha one"}, {"name": "beta two"}, {"name": "gamma three"}])
        code, report, text = self.run_json("--binary", str(binary), "--filter", "beta", "--filter", "gamma", "--jobs", "1")
        self.assertEqual(0, code, text)
        self.assertEqual([1, 2], sorted(event["index"] for event in self.events("run")))
        entry = report["binaries"][0]
        self.assertEqual((3, 2, 2), (entry["total_tests"], entry["selected"], entry["counts"]["passed"]))
        self.assertEqual(["beta", "gamma"], report["filters"])

    def test_filter_without_match_exits_2(self) -> None:
        binary = self.fake("nomatch", [{"name": "alpha"}])
        code, _out, err = self.run_main("--binary", str(binary), "--filter", "zeta")
        self.assertEqual(2, code)
        self.assertIn("运行期 --filter 'zeta' 没有匹配任何用例（1 个二进制共 1 条用例）", err)
        self.assertEqual([], self.events("run"))

    def test_zero_tests_error_names_the_actual_cause(self) -> None:
        empty = self.fake("empty", [])
        for extra in ((), ("--filter", "zeta")):
            code, _out, err = self.run_main("--binary", str(empty), *extra)
            self.assertEqual(2, code, err)
            self.assertIn("测试二进制本身没有用例", err)
            self.assertNotIn("没有匹配", err)
        self.fake_zigw()
        with self.fake_suite("vt", []):
            code, report, text = self.run_json("--suite", "vt", "-Dtest-filter=zzz", "--filter", "zeta")
            self.assertEqual((2, 2), (code, report["exit_code"]), text)
            self.assertEqual("构建期 -Dtest-filter='zzz' 裁掉了全部用例：本轮构建出的测试二进制里没有用例", report["error"])
            code, _out, err = self.run_main("--suite", "vt", "--no-build", "-Dtest-filter=zzz")
            self.assertEqual(2, code, err)
            self.assertIn("测试二进制本身没有用例", err)
            self.assertIn("--no-build 运行的是上次安装的二进制", err)
        with self.fake_suite("vt", [{"name": "alpha"}]):
            code, _out, err = self.run_main("--suite", "vt", "-Dtest-filter=al", "--filter", "zeta")
        self.assertEqual(2, code, err)
        self.assertIn("运行期 --filter 'zeta' 没有匹配任何用例（1 个二进制共 1 条用例，已按构建期 -Dtest-filter='al' 裁剪）", err)
        self.assertEqual([], self.events("run"))

    def test_list_prints_indices_and_runs_nothing(self) -> None:
        binary = self.fake("listing", [{"name": "alpha one"}, {"name": "beta two"}, {"name": "alphabet"}])
        code, out, err = self.run_main("--binary", str(binary), "--list", "--filter", "alpha")
        self.assertEqual(0, code, err)
        self.assertEqual(["listing\t0\talpha one", "listing\t2\talphabet"], out.splitlines())
        self.assertEqual([], self.events("run"))

    def test_timing_cache_orders_longest_first_and_is_refreshed(self) -> None:
        binary = self.fake("timed", [{"name": f"t{index}"} for index in range(4)])
        cache = zig_test.timings_path(self.root, "timed")
        cache.parent.mkdir(parents=True)
        cache.write_text(json.dumps({"t0": 0.001, "t1": 5.0, "t2": 0.5, "removed test": 9.0}), encoding="utf-8")
        code, out, err = self.run_main("--binary", str(binary), "--jobs", "1")
        self.assertEqual(0, code, out + err)
        self.assertEqual([1, 2, 3, 0], [event["index"] for event in self.events("run")])
        refreshed = json.loads(cache.read_text(encoding="utf-8"))
        self.assertEqual(9.0, refreshed.pop("removed test"))
        self.assertEqual({"t0", "t1", "t2", "t3"}, set(refreshed))
        self.assertTrue(all(isinstance(value, float) and value < 5.0 for value in refreshed.values()), refreshed)
        self.assertNotIn(b"\r\n", cache.read_bytes())

    def test_timing_cache_directory_follows_the_environment(self) -> None:
        binary = self.fake("timed", [{"name": "t0"}])
        elsewhere = self.root / "elsewhere"
        for value, directory in (("cache/timings", self.root / "cache" / "timings"), (str(elsewhere), elsewhere)):
            with mock.patch.dict(os.environ, {zig_test.TIMINGS_ENV: value}):
                self.assertEqual(directory / "timed.json", zig_test.timings_path(self.root, "timed"))
                code, out, err = self.run_main("--binary", str(binary), "--jobs", "1")
                self.assertEqual(0, code, out + err)
            self.assertEqual({"t0"}, set(json.loads((directory / "timed.json").read_text(encoding="utf-8"))), value)
        self.assertEqual(self.root / ".local" / "test-timings" / "timed.json", zig_test.timings_path(self.root, "timed"))
        self.assertFalse((self.root / ".local").exists())

    def test_timing_cache_is_pruned_only_after_a_full_suite_build(self) -> None:
        record = self.fake_zigw()
        other = self.fake("other", [{"name": "o"}])
        caches = [zig_test.timings_path(self.root, label) for label in ("vt", "other")]
        caches[0].parent.mkdir(parents=True)

        def cached_after(*args: str) -> tuple[list[str], list[set[str]]]:
            record.unlink(missing_ok=True)
            for cache in caches:
                cache.write_text(json.dumps({"t0": 1.0, "gone": 9.0}), encoding="utf-8")
            code, out, err = self.run_main("--jobs", "1", *args)
            self.assertEqual(0, code, out + err)
            built = json.loads(record.read_text(encoding="utf-8")) if record.exists() else []
            return built, [set(json.loads(cache.read_text(encoding="utf-8"))) for cache in caches]

        pruned, kept, untouched = {"t0", "t1"}, {"t0", "t1", "gone"}, {"t0", "gone"}
        with self.fake_suite("vt", [{"name": "t0"}, {"name": "t1"}]):
            built, names = cached_after("--suite", "vt")
            self.assertEqual(("test-lib-vt-bin", [pruned, untouched]), (built[1], names))
            for define in ("-Dtest-filter=t", "--zig-arg=-Dtest-filter=t"):
                built, names = cached_after("--suite", "vt", define)
                self.assertEqual(("-Dtest-filter=t", [kept, untouched]), (built[-1], names), define)
            self.assertEqual(([], [kept, untouched]), cached_after("--suite", "vt", "--no-build"))
            built, names = cached_after("--suite", "vt", "--binary", str(other))
            self.assertEqual(("test-lib-vt-bin", [pruned, {"t0", "gone", "o"}]), (built[1], names))

    def test_dedupe_runs_shared_names_only_in_first_binary(self) -> None:
        first = self.fake("first", [{"name": "shared a"}, {"name": "shared b"}])
        second = self.fake("second", [{"name": "shared a"}, {"name": "shared b"}, {"name": "c api only"}])
        code, report, text = self.run_json("--binary", str(first), "--binary", str(second), "--jobs", "2", "--dedupe")
        self.assertEqual(0, code, text)
        self.assertTrue(report["dedupe"])
        self.assertEqual(
            [("first", 2, 0, 2), ("second", 1, 2, 1)],
            [(entry["label"], entry["selected"], entry["deduplicated"], entry["counts"]["passed"]) for entry in report["binaries"]],
        )
        self.assertEqual(["c api only"], [test["name"] for test in report["tests"] if test["binary"] == "second"])
        code, report, text = self.run_json("--binary", str(first), "--binary", str(second), "--jobs", "2")
        self.assertEqual(0, code, text)
        self.assertEqual(5, len(report["tests"]))

    def test_serial_filter_runs_matches_in_one_dedicated_worker(self) -> None:
        tests = [{"name": f"serial {letter}", "sleep": 0.1} for letter in "abc"]
        tests += [{"name": f"par {letter}", "sleep": 0.1} for letter in "xyz"]
        binary = self.fake("serial", tests)
        code, report, text = self.run_json("--binary", str(binary), "--jobs", "3", "--serial-filter", "serial")
        self.assertEqual(0, code, text)
        serial = [entry for entry in report["tests"] if entry["name"].startswith("serial")]
        self.assertEqual({0}, {entry["worker"] for entry in serial})
        self.assertTrue(report["workers"][0]["serial"])
        pids = {event["pid"] for event in self.events("run") if event["name"].startswith("serial")}
        self.assertEqual(1, len(pids))


class ProtocolArgumentTests(FakeRunnerTestCase):
    def test_seed_cache_dir_and_cwd_reach_the_binary(self) -> None:
        binary = self.fake("args", [{"name": "only"}])
        code, out, err = self.run_main("--binary", str(binary), "--seed", "0xdeadbeef", "--jobs", "1")
        self.assertEqual(0, code, out + err)
        start = self.events("start")[0]
        self.assertEqual([f"--cache-dir={self.root.resolve() / '.zig-cache'}", "--seed=0xdeadbeef", "--listen=-"], start["args"])
        self.assertTrue(same_path(self.root, start["cwd"]))
        self.assertIn("seed 0xdeadbeef", out)

    def test_decimal_and_default_seeds_are_printed_for_reproduction(self) -> None:
        binary = self.fake("seeds", [{"name": "only"}])
        code, out, _err = self.run_main("--binary", str(binary), "--seed", "123", "--jobs", "1")
        self.assertEqual(0, code)
        self.assertIn("--seed=0x7b", self.events("start")[0]["args"])
        self.assertIn("seed 0x7b", out)
        for path in self.records.glob("*.jsonl"):
            path.unlink()
        code, out, _err = self.run_main("--binary", str(binary), "--jobs", "1")
        self.assertEqual(0, code)
        seed_arg = next(arg for arg in self.events("start")[0]["args"] if arg.startswith("--seed="))
        self.assertIn(f"seed {seed_arg.split('=', 1)[1]}", out)

    def test_json_report_shape(self) -> None:
        binary = self.fake("shape", [{"name": "a"}, {"name": "b", "status": "fail", "stderr": "nope\n"}])
        code, report, text = self.run_json("--binary", str(binary), "--jobs", "2", "--seed", "0x10", "--timeout", "30")
        self.assertEqual(1, code, text)
        for key in ("schema", "exit_code", "ok", "seed", "seed_hex", "jobs", "timeout", "wall_seconds", "binaries", "failures", "slowest", "workers", "tests"):
            self.assertIn(key, report)
        self.assertEqual((1, False, 16, "0x10", 2, 30.0), (report["schema"], report["ok"], report["seed"], report["seed_hex"], report["jobs"], report["timeout"]))
        entry = report["binaries"][0]
        self.assertEqual(("shape", "0.16.0", 2), (entry["label"], entry["zig_version"], entry["total_tests"]))
        self.assertTrue(same_path(binary, entry["path"]))
        self.assertEqual(["a", "b"], [test["name"] for test in report["tests"]])
        self.assertEqual({"pass", "fail"}, {test["outcome"] for test in report["tests"]})
        self.assertEqual(["b"], [failure["name"] for failure in report["failures"]])
        self.assertLessEqual(len(report["slowest"]), zig_test.SLOWEST_COUNT)

    def test_parse_test_metadata(self) -> None:
        strings = b"\0first\0second test\0"
        body = struct.pack("<II", len(strings), 2) + struct.pack("<2I", 1, 7) + struct.pack("<2I", 0, 0) + strings
        self.assertEqual(["first", "second test"], zig_test.parse_test_metadata(body))
        with self.assertRaises(zig_test.ProtocolError):
            zig_test.parse_test_metadata(body[:-3])

    def test_output_capture_keeps_head_and_tail(self) -> None:
        capture = zig_test.OutputCapture()
        capture.append(b"H" * zig_test.CAPTURE_HEAD)
        capture.append(b"m" * 1000)
        capture.append(b"T" * zig_test.CAPTURE_TAIL)
        text = capture.take()
        self.assertTrue(text.startswith("H" * 100))
        self.assertIn("[... 1000 bytes omitted ...]", text)
        self.assertTrue(text.endswith("T" * 100))
        self.assertEqual("", capture.take())

    def test_same_path_sees_through_symlinks(self) -> None:
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        try:
            os.symlink(target, link, target_is_directory=True)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"当前环境不能创建符号链接：{exc}")
        self.assertTrue(same_path(link, target))
        self.assertTrue(same_path(link / "child", target / "child"))
        self.assertFalse(same_path(link, self.root))


class CliTests(FakeRunnerTestCase):
    def test_missing_binary_and_bad_arguments_exit_2(self) -> None:
        code, _out, err = self.run_main("--binary", str(self.root / "missing.exe"))
        self.assertEqual(2, code)
        self.assertIn("missing.exe", err)
        self.assertEqual(2, self.run_main("--seed", "0x100000000")[0])
        self.assertEqual(2, self.run_main("--jobs", "0")[0])
        self.assertEqual(2, self.run_main("--suite", "nope")[0])

    def test_suite_without_installed_binaries_exits_2(self) -> None:
        code, report, _text = self.run_json("--suite", "vt", "--no-build")
        self.assertEqual(2, code)
        self.assertIn("vt", report["error"])
        self.assertFalse(report["ok"])

    def test_main_suite_is_refused_on_windows_unless_no_build(self) -> None:
        record = self.fake_zigw(exit_code=1)
        binary = self.fake("explicit", [{"name": "only"}])

        def built_step() -> str:
            step = json.loads(record.read_text(encoding="utf-8"))[1]
            record.unlink()
            return step

        with mock.patch.object(zig_test, "host_is_windows", return_value=True):
            for args in (("--suite", "main"), ("--suite", "main", "--binary", str(binary))):
                code, report, text = self.run_json(*args)
                self.assertEqual(2, code, text)
                self.assertEqual((False, zig_test.MAIN_SUITE_ON_WINDOWS), (report["ok"], report["error"]))
                for needle in ("ghostty-test", "pwd.h", "linux-main", "just test-vt", "--binary"):
                    self.assertIn(needle, text)
            self.assertFalse(record.exists())
            self.assertEqual([], self.events("start"))
            code, _out, err = self.run_main("--suite", "main", "--no-build", "--list")
            self.assertEqual(2, code, err)
            self.assertIn("缺少测试二进制（Windows 上无法构建 ghostty-test", err)
            self.assertNotIn("先去掉 --no-build", err)
            with self.fake_suite("main", [{"name": "installed"}]):
                code, out, err = self.run_main("--suite", "main", "--no-build", "--jobs", "1")
            self.assertEqual(0, code, out + err)
            code, out, err = self.run_main("--binary", str(binary), "--jobs", "1")
            self.assertEqual(0, code, out + err)
            self.assertFalse(record.exists())
            self.assertEqual((2, "test-lib-vt-bin"), (self.run_main("--suite", "vt")[0], built_step()))
        with mock.patch.object(zig_test, "host_is_windows", return_value=False):
            code, _out, err = self.run_main("--suite", "main")
        self.assertEqual((2, "test-bin"), (code, built_step()), err)
        self.assertIn("构建失败", err)

    def test_cli_process_exit_codes(self) -> None:
        green = self.fake("cli_green", [{"name": "a"}, {"name": "b", "status": "skip"}])
        red = self.fake("cli_red", [{"name": "a"}, {"name": "b", "status": "fail"}])
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONIOENCODING": "utf-8"}
        for binary, expected in ((green, 0), (red, 1)):
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(self.root), "--binary", str(binary), "--jobs", "2"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                env=env,
                check=False,
            )
            self.assertEqual(expected, result.returncode, result.stdout + result.stderr)


class ReproduceTests(FakeRunnerTestCase):
    PYTHON = "python" if os.name == "nt" else "python3"

    def test_reproduce_command_reruns_only_the_first_failure(self) -> None:
        green = self.fake("repro_green", [{"name": "fine"}])
        code, report, text = self.run_json("--binary", str(green), "--jobs", "1")
        self.assertEqual((0, None), (code, report["reproduce"]), text)
        self.assertNotIn("重现", text)
        name = "repro.test.fails with 'single' and \"double\" quotes"
        tests = [{"name": "repro.test.passes"}, {"name": name, "status": "fail", "stderr": "boom\n"}, {"name": "repro.test.fails later", "status": "fail"}]
        binary = self.fake("repro", tests)
        code, report, text = self.run_json("--binary", str(binary), "--jobs", "2", "--seed", "0x2a", "-Doptimize=Debug", "--zig-arg=--summary", "--no-build")
        self.assertEqual(1, code, text)
        command = report["reproduce"]
        self.assertIn(f"{zig_test.TAG} 重现：{command}\n", text)
        argv = split_command(command)
        root = self.root.resolve().as_posix()
        self.assertEqual(
            [self.PYTHON, "scripts/zig_test.py", "--root", root, "--binary", str(binary), "-Doptimize=Debug", "--zig-arg=--summary", "--no-build", "--seed", "0x2a", "--filter", name],
            argv,
        )
        for path in self.records.glob("*.jsonl"):
            path.unlink()
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONIOENCODING": "utf-8"}
        rerun = subprocess.run([sys.executable, *argv[1:]], cwd=str(ROOT), capture_output=True, text=True, encoding="utf-8", env=env, check=False)
        self.assertEqual(1, rerun.returncode, rerun.stdout + rerun.stderr)
        self.assertIn("FAIL 1 of 1 tests failed", rerun.stdout)
        self.assertEqual([(1, name)], [(event["index"], event["name"]) for event in self.events("run")])
        self.assertIn("--seed=0x2a", self.events("start")[0]["args"])

    def test_reproduce_command_keeps_suite_and_build_arguments(self) -> None:
        self.fake_zigw()
        given = ["-Doptimize=ReleaseFast", "-Dtest-filter=broken one", "--zig-arg=--summary", "--zig-arg", "all"]
        kept = ["-Doptimize=ReleaseFast", "-Dtest-filter=broken one", "--zig-arg=--summary", "--zig-arg=all"]
        root = self.root.resolve().as_posix()
        with self.fake_suite("vt", [{"name": "vt.test.ok"}, {"name": "vt.test.broken one", "status": "fail"}]):
            for extra in ([], ["--no-build"]):
                code, report, text = self.run_json("--suite", "vt", "--seed", "7", *given, *extra)
                self.assertEqual(1, code, text)
                self.assertEqual(
                    [self.PYTHON, "scripts/zig_test.py", "--root", root, "--suite", "vt", *kept, *extra, "--seed", "0x7", "--filter", "vt.test.broken one"],
                    split_command(report["reproduce"]),
                )

    def test_reproduce_command_carries_only_a_non_default_timeout(self) -> None:
        plan = zig_test.Plan(zig_test.REPO_ROOT, 0x2A, 1, zig_test.DEFAULT_TIMEOUT, [], [], "vt")
        self.assertNotIn("--timeout", split_command(zig_test.reproduce_command(plan, "x")))
        plan.timeout = 2.5
        argv = split_command(zig_test.reproduce_command(plan, "x"))
        self.assertEqual(["--suite", "vt", "--timeout", "2.5", "--seed", "0x2a", "--filter", "x"], argv[2:])
        self.assertEqual(2.5, zig_test.parse_args(argv[2:]).timeout)

    def test_reproduce_command_quotes_for_the_host_shell(self) -> None:
        plan = zig_test.Plan(zig_test.REPO_ROOT, 0x2A, 1, zig_test.DEFAULT_TIMEOUT, [], [], "vt", defines=["test-filter=a b"])
        name = "a: it's \"q\""
        with mock.patch.object(zig_test, "host_is_windows", return_value=False):
            self.assertEqual(
                r"""python3 scripts/zig_test.py --suite vt '-Dtest-filter=a b' --seed 0x2a --filter 'a: it'"'"'s "q"'""",
                zig_test.reproduce_command(plan, name),
            )
        with mock.patch.object(zig_test, "host_is_windows", return_value=True):
            self.assertEqual(
                r'''python scripts/zig_test.py --suite vt "-Dtest-filter=a b" --seed 0x2a --filter "a: it's \"q\""''',
                zig_test.reproduce_command(plan, name),
            )


class BuildTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        zon = '.{\r\n    .name = .ghostty,\r\n    .version = "1.3.2-dev",\r\n    .minimum_zig_version = "0.16.0",\r\n}\r\n'
        (self.root / "build.zig.zon").write_bytes(zon.encode("utf-8"))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_pinned_version_string_from_crlf_zon(self) -> None:
        self.assertEqual("1.3.2-dev+0000000", zig_test.pinned_version_string(self.root))
        (self.root / "build.zig.zon").write_text('.{ .version = "2.0.1", }\n', encoding="utf-8")
        self.assertEqual("2.0.1-dev+0000000", zig_test.pinned_version_string(self.root))
        (self.root / "build.zig.zon").write_text('.{\n    // .version = "0.0.1",\n    .minimum_zig_version = "0.16.0",\n    .version = "3.4.5-dev",\n}\n', encoding="utf-8")
        self.assertEqual("3.4.5-dev+0000000", zig_test.pinned_version_string(self.root))
        (self.root / "build.zig.zon").write_text(".{ .name = .ghostty }\n", encoding="utf-8")
        with self.assertRaises(zig_test.FatalError):
            zig_test.pinned_version_string(self.root)

    def test_build_command_pins_version_unless_overridden(self) -> None:
        zigw = str(self.root / "scripts" / "zigw.py")
        self.assertEqual(
            [sys.executable, zigw, "build", "test-lib-vt-bin", "-Dversion-string=1.3.2-dev+0000000", "-Doptimize=ReleaseFast", "--summary", "all"],
            zig_test.build_command(self.root, "vt", ["optimize=ReleaseFast"], ["--summary", "all"]),
        )
        self.assertEqual(
            [sys.executable, zigw, "build", "test-bin", "-Dversion-string=9.9.9"],
            zig_test.build_command(self.root, "main", ["version-string=9.9.9"], []),
        )

    def test_build_test_filters_cover_defines_and_zig_args(self) -> None:
        self.assertEqual(
            ["a", "b c"],
            zig_test.build_test_filters(["optimize=Debug", "test-filter=a", "test-filters=x"], ["--summary", "all", "-Dtest-filter=b c"]),
        )
        self.assertEqual([], zig_test.build_test_filters(["optimize=Debug"], ["-Doptimize=ReleaseFast", "--prefix=out"]))

    def test_suite_binary_discovery_and_install_prefix(self) -> None:
        prefix = zig_test.install_prefix(self.root, [])
        self.assertEqual(self.root / "zig-out", prefix)
        self.assertEqual(self.root / "custom", zig_test.install_prefix(self.root, ["-p", "custom"]))
        self.assertEqual(self.root / "other", zig_test.install_prefix(self.root, ["--prefix=other"]))
        for relative in ("test/vt/test.exe", "test/vt_c/test", "test/ghostty-test"):
            path = prefix / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"")
        found, missing = zig_test.suite_binaries(prefix, "vt")
        self.assertEqual([("vt", prefix / "test/vt/test.exe"), ("vt_c", prefix / "test/vt_c/test")], found)
        self.assertEqual([], missing)
        self.assertEqual(([("ghostty-test", prefix / "test/ghostty-test")], []), zig_test.suite_binaries(prefix, "main"))
        self.assertEqual("vt", zig_test.binary_label(prefix / "test/vt/test.exe"))
        self.assertEqual("ghostty-test", zig_test.binary_label(Path("zig-out/test/ghostty-test.exe")))
        self.assertEqual("abc123", zig_test.binary_label(Path(".zig-cache/o/abc123/test.exe")))

    def test_suite_binaries_prefer_the_host_suffix(self) -> None:
        prefix = self.root / "zig-out"
        for relative in ("test/vt/test", "test/vt/test.exe", "test/vt_c/test.exe", "test/ghostty-test"):
            path = prefix / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"")
        for windows, vt in ((True, "test/vt/test.exe"), (False, "test/vt/test")):
            with mock.patch.object(zig_test, "host_is_windows", return_value=windows):
                self.assertEqual(([("vt", prefix / vt), ("vt_c", prefix / "test/vt_c/test.exe")], []), zig_test.suite_binaries(prefix, "vt"))
                self.assertEqual(([("ghostty-test", prefix / "test/ghostty-test")], []), zig_test.suite_binaries(prefix, "main"))

    def test_suites_match_the_gx0002_steps_and_install_dirs(self) -> None:
        text = (ROOT / "build.zig").read_text(encoding="utf-8")
        for suite in zig_test.SUITES.values():
            self.assertRegex(text, r'\bb\.step\(\s*"' + re.escape(suite.step) + '"')
        hunks = re.findall(r"// fork\(gx\): GX-0002 begin(.*?)// fork\(gx\): GX-0002 end", text, re.DOTALL)
        self.assertTrue(hunks, "build.zig 里没有 GX-0002 块")
        custom = {value for hunk in hunks for value in re.findall(r'\.custom\s*=\s*"([^"]*)"', hunk)}
        installed = {PurePosixPath(relative).parent.as_posix() for suite in zig_test.SUITES.values() for _label, relative in suite.binaries}
        self.assertTrue(installed)
        self.assertEqual(installed, custom)

    def test_build_failure_exits_2_with_exact_zig_arguments(self) -> None:
        record = self.root / "zigw-args.json"
        fake_zigw = self.root / "scripts" / "zigw.py"
        fake_zigw.parent.mkdir()
        fake_zigw.write_text(
            "import json, sys\n"
            f"json.dump(sys.argv[1:], open({str(record)!r}, 'w'))\n"
            "sys.exit(int(__import__('os').environ.get('FAKE_ZIGW_EXIT', '1')))\n",
            encoding="utf-8",
        )
        args = ["--root", str(self.root), "--suite", "vt", "-Doptimize=ReleaseFast", "--zig-arg=--summary", "--zig-arg", "all"]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
            code = zig_test.main(args)
        self.assertEqual(2, code)
        self.assertIn("构建失败", err.getvalue())
        self.assertEqual(
            ["build", "test-lib-vt-bin", "-Dversion-string=1.3.2-dev+0000000", "-Doptimize=ReleaseFast", "--summary", "all"],
            json.loads(record.read_text(encoding="utf-8")),
        )
        os.environ["FAKE_ZIGW_EXIT"] = "0"
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                code = zig_test.main(args)
        finally:
            del os.environ["FAKE_ZIGW_EXIT"]
        self.assertEqual(2, code)
        self.assertIn("缺少测试二进制", err.getvalue())


if __name__ == "__main__":
    unittest.main()
