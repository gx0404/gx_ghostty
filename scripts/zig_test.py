#!/usr/bin/env python3
"""并行 Zig 测试运行器：按 Zig 0.16 test runner 的 server 协议，把测试二进制的用例分片到多个进程。

用法：
  python scripts/zig_test.py [--suite vt|main] [--binary PATH]... [--jobs N] [--seed N]
      [--filter TEXT]... [--serial-filter TEXT]... [--dedupe] [--timeout SECONDS] [--no-build]
      [--list] [--json PATH] [-D<opt>=<val>]... [--zig-arg ARG]...

套件（未给 --binary 时默认 --suite vt）：
  vt    python scripts/zigw.py build test-lib-vt-bin -Dversion-string=<V> <-D…> <--zig-arg…>，
        再运行 zig-out/test/vt/ 与 zig-out/test/vt_c/ 下的 test(.exe)
  main  构建步骤 test-bin，运行 zig-out/test/ghostty-test(.exe)。ghostty-test 不能为 Windows 编译
        （上游 src/build/SharedDeps.zig 用 translate-c 翻译 pwd.h 等 POSIX 头文件），所以 Windows 上
        只要没加 --no-build（给了 --binary 也一样）就在构建之前以退出码 2 拒绝；主套件在 Linux/macOS
        或 gx-ci 的 linux-main 运行
<V> 钉为 `<build.zig.zon 的 X.Y.Z>-dev+0000000`（与上游无 git 时的回退版本同形），提交不再
改变版本串、不再让构建缓存失效；显式 -Dversion-string= 优先。--no-build 跳过构建，直接运行
已安装的二进制；--binary 可与 --suite 同用（取并集）。构建输出直通终端，构建失败退出 2。
安装目录里 test 与 test.exe 并存时 Windows 取 .exe，其他系统取无后缀的文件。
以 .py 结尾的 --binary 用当前解释器启动（单测的伪测试二进制靠它）。值以 - 开头的 zig 参数写成
--zig-arg=--summary 的形式。--root 只供测试或其他 worktree 使用，默认取脚本所在仓库。

运行：先并行向每个二进制查询用例元数据（--filter 是对用例全名的子串过滤，多次给出取并集，
不重新编译；--list 只列出 `<label>\\t<index>\\t<name>` 后退出 0）。全部用例排成一个全局任务表，
按 .local/test-timings/<label>.json（用例名 → 秒）从长到短排序，未知用例按 DEFAULT_ESTIMATE 估计；
环境变量 GX_ZIG_TEST_TIMINGS_DIR 可换掉这个目录（相对路径按仓库根解析，gx-ci 指向被缓存的 .zig-cache 下）。
每轮运行后把实测并入该文件；只有确定是完整二进制（本轮由 --suite 构建，且 -D 与 --zig-arg 里都
没有 -Dtest-filter）时才删去二进制里已不存在的用例，--no-build、--binary 与带 -Dtest-filter 的
构建只合并不删。N 个工作线程（--jobs，默认 CPU 数）动态取任务，每个线程按二进制懒启动并复用
一个测试进程：`<binary> --cache-dir=<root>/.zig-cache --seed=0x<seed> --listen=-`，cwd 为
仓库根。命中 --serial-filter 的用例只由一个专用线程顺序执行。--seed 默认随机 u32，总结里总会
打印；有失败时结论行之后再打印一条只重跑第一个失败用例的完整命令（--json 里是 reproduce，非默认的
--timeout 也带上）。
--timeout 是单个用例的秒数（默认 600），超时即连同测试进程派生的进程一起杀掉、记 timeout、起新进程继续。
--dedupe（默认关闭）让同名用例只在先出现的二进制里运行：vt 套件里 vt_c 只剩 terminal.c.* 用例，
其余同名用例不再以 c_abi=true 再跑一遍，墙钟约减半，但这是覆盖取舍，由使用者决定。

判定与 zig build 一致（std/Build/Step/Run.zig::evalZigTest）：status fail 记 fail（附 test_started
之后捕获的 stderr）；否则泄漏数 > 0 记 leak；否则 error 日志数 > 0 记 log_err；skip 单独计数；
用例执行中进程退出或 stdout 断开记 crash（附 stderr 尾部），并为剩余任务重启进程。
超时、崩溃收尾与中断时连进程树一起杀：POSIX 向测试进程自成的进程组发 SIGKILL（崩溃后也清掉仍占着管道的
孙进程）；Windows 只在进程仍在运行时（超时、中断）用 taskkill /T。正常结束只关闭 stdin，测试进程自行退出。

退出码：0 全部通过（skip 不算失败）；1 存在 fail / leak / log_err / crash / timeout / 未运行的
用例；2 用法错误（含 Windows 上没加 --no-build 的 --suite main）、构建失败、找不到二进制、元数据
查询失败或没有可运行的用例（报错写明原因：运行期 --filter 没命中、构建期 -Dtest-filter 裁掉了全部
用例，或二进制本身没有用例）；130 被 Ctrl+C 中断（POSIX 上 SIGTERM、SIGHUP 同样按中断处理，被忽略的
信号如 nohup 下的 SIGHUP 除外）。--json PATH 写出机器可读结果（schema 见 build_report）。
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import random
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
from collections import Counter, deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Sequence, Union

REPO_ROOT = Path(__file__).resolve().parents[1]
TAG = "[zig_test]"

# std/zig/Client.zig 与 std/zig/Server.zig 的 Message.Tag；消息头是 {tag: u32 LE, bytes_len: u32 LE}。
CLIENT_EXIT = 0
CLIENT_QUERY_TEST_METADATA = 4
CLIENT_RUN_TEST = 5
SERVER_ZIG_VERSION = 0
SERVER_TEST_METADATA = 3
SERVER_TEST_RESULTS = 4
SERVER_TEST_STARTED = 5
HEADER = struct.Struct("<II")
TEST_RESULTS = struct.Struct("<IQ")
U32 = struct.Struct("<I")
MAX_BODY_BYTES = 64 << 20
STATUS_PASS, STATUS_FAIL, STATUS_SKIP = 0, 1, 2

DEFAULT_TIMEOUT = 600.0
DEFAULT_ESTIMATE = 0.1
TIMINGS_ENV = "GX_ZIG_TEST_TIMINGS_DIR"
STARTUP_TIMEOUT = 60.0
SPAWN_RETRY_DELAY = 1.0
SPAWN_FAILURE_LIMIT = 3
POLL_INTERVAL = 0.5
EXIT_GRACE = 1.0
EXIT_WAIT = 5.0
TASKKILL_TIMEOUT = 10.0
STDERR_EOF_WAIT = 2.0
SETTLE_QUIET = 0.05
SETTLE_LIMIT = 1.0
PROGRESS_INTERVAL = 2.0
CAPTURE_HEAD = 16 << 10
CAPTURE_TAIL = 240 << 10
SLOWEST_COUNT = 10
REPORT_SCHEMA = 1

COUNT_KEYS = {
    "pass": "passed",
    "skip": "skipped",
    "fail": "failed",
    "leak": "leaked",
    "log_err": "log_err",
    "crash": "crashed",
    "timeout": "timeouts",
    "not_run": "not_run",
}
FAILED_OUTCOMES = frozenset(("fail", "leak", "log_err", "crash", "timeout", "not_run"))
LABEL_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")
ZON_VERSION = re.compile(r'^[^/\r\n]*?\.version\s*=\s*"(\d+)\.(\d+)\.(\d+)', re.MULTILINE)


@dataclass(frozen=True)
class Suite:
    step: str
    binaries: tuple[tuple[str, str], ...]  # (label, 安装前缀下去掉 .exe 的相对路径)


SUITES = {
    "vt": Suite("test-lib-vt-bin", (("vt", "test/vt/test"), ("vt_c", "test/vt_c/test"))),
    "main": Suite("test-bin", (("ghostty-test", "test/ghostty-test"),)),
}
MAIN_SUITE_ON_WINDOWS = (
    "--suite main 不能在 Windows 上构建，未构建即退出：ghostty-test 不能为 Windows 编译（上游 src/build/SharedDeps.zig "
    "用 translate-c 翻译 pwd.h 等 POSIX 头文件，Windows 上找不到；上游 zig build test 在 Windows 上同样失败）。"
    "主套件请在 Linux/macOS 上运行（just test），或以 gx-ci 的 linux-main job 为准；Windows 本机用 just test-vt"
    "（python scripts/zig_test.py --suite vt），只运行 --binary 给出的二进制时去掉 --suite main。"
)


class FatalError(Exception):
    """终止整轮运行的错误（用法、构建、二进制或元数据），携带退出码。"""

    def __init__(self, message: str, code: int = 2) -> None:
        super().__init__(message)
        self.code = code


class SpawnError(RuntimeError):
    """测试进程无法启动，或没有完成 zig_version 握手。"""


class ProtocolError(RuntimeError):
    """stdout 上的消息流不符合 std.zig.Server 的格式。"""


Message = tuple[int, bytes, float]
QueueItem = Union[Message, ProtocolError, None]


# ---------------------------------------------------------------- 构建与发现


def host_is_windows() -> bool:
    return os.name == "nt"


def pinned_version_string(root: Path) -> str:
    """`<build.zig.zon 的 X.Y.Z>-dev+0000000`，与 src/build/Config.zig 在没有 git 时的回退一致。"""
    path = root / "build.zig.zon"
    try:
        text = path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as exc:
        raise FatalError(f"无法读取 {path}：{exc}") from exc
    match = ZON_VERSION.search(text)
    if match is None:
        raise FatalError(f"{path} 里没有 X.Y.Z 形式的 .version")
    return f"{match[1]}.{match[2]}.{match[3]}-dev+0000000"


def build_command(root: Path, suite: str, defines: Sequence[str], zig_args: Sequence[str]) -> list[str]:
    command = [sys.executable, str(root / "scripts" / "zigw.py"), "build", SUITES[suite].step]
    if not any(define.startswith("version-string=") for define in defines):
        command.append(f"-Dversion-string={pinned_version_string(root)}")
    command += [f"-D{define}" for define in defines]
    command += list(zig_args)
    return command


def build_test_filters(defines: Sequence[str], zig_args: Sequence[str]) -> list[str]:
    """透传给 zig build 的 -Dtest-filter 值，含写成 --zig-arg=-Dtest-filter=… 的。"""
    options = [*defines, *(arg[2:] for arg in zig_args if arg.startswith("-D"))]
    return [value for name, _, value in (option.partition("=") for option in options) if name == "test-filter"]


def install_prefix(root: Path, zig_args: Sequence[str]) -> Path:
    prefix: str | None = None
    for position, arg in enumerate(zig_args):
        if arg.startswith("--prefix="):
            prefix = arg.split("=", 1)[1]
        elif arg in ("-p", "--prefix") and position + 1 < len(zig_args):
            prefix = zig_args[position + 1]
    return root / (prefix if prefix is not None else "zig-out")


def suite_binaries(prefix: Path, suite: str) -> tuple[list[tuple[str, Path]], list[Path]]:
    """返回 ([(label, 可执行文件)], [缺失的预期路径])；同时存在时按主机取：Windows 取 .exe，其他系统取无后缀的
    文件，Linux 上残留的交叉编译 test.exe 不会盖过原生 test。"""
    found: list[tuple[str, Path]] = []
    missing: list[Path] = []
    for label, relative in SUITES[suite].binaries:
        base = prefix / relative
        exe = base.with_name(base.name + ".exe")
        for candidate in (exe, base) if host_is_windows() else (base, exe):
            if candidate.is_file():
                found.append((label, candidate))
                break
        else:
            missing.append(base)
    return found, missing


def binary_label(path: Path) -> str:
    stem = path.stem if path.suffix.lower() in (".exe", ".py") else path.name
    if stem == "test" and path.parent.name:
        stem = path.parent.name
    return LABEL_UNSAFE.sub("_", stem).strip("._") or "test"


def binary_command(path: Path) -> list[str]:
    if path.suffix.lower() == ".py":
        return [sys.executable, str(path)]
    return [str(path)]


def runner_args(root: Path, seed: int) -> list[str]:
    return [f"--cache-dir={root / '.zig-cache'}", f"--seed=0x{seed:x}", "--listen=-"]


def run_build(root: Path, command: list[str]) -> float:
    shown = " ".join(["python", *(_relative(part, root) for part in command[1:])])
    emit(f"{TAG} build: {shown}")
    started = time.monotonic()
    try:
        returncode = subprocess.run(command, cwd=str(root), check=False).returncode
    except KeyboardInterrupt:
        raise FatalError("构建被中断", 130) from None
    except OSError as exc:
        raise FatalError(f"无法运行构建命令：{exc}") from exc
    if returncode != 0:
        raise FatalError(f"构建失败（zig build 退出码 {returncode}）")
    return time.monotonic() - started


def _relative(part: str, root: Path) -> str:
    try:
        return Path(part).relative_to(root).as_posix()
    except ValueError:
        return part


# ---------------------------------------------------------------- 协议与进程


def parse_test_metadata(body: bytes) -> list[str]:
    """TestMetadata：{string_bytes_len, tests_len} + names[tests_len] + expected_panic_msgs[tests_len] + string_bytes。"""
    if len(body) < 8:
        raise ProtocolError("test_metadata 消息过短")
    string_len, count = struct.unpack_from("<II", body, 0)
    strings_at = 8 + 8 * count
    if len(body) < strings_at + string_len:
        raise ProtocolError("test_metadata 长度与声明不符")
    offsets = struct.unpack_from(f"<{count}I", body, 8)
    strings = body[strings_at : strings_at + string_len]
    names = []
    for offset in offsets:
        end = strings.find(b"\0", offset)
        if offset >= len(strings) or end < 0:
            raise ProtocolError(f"test_metadata 名字偏移 {offset} 越界")
        names.append(strings[offset:end].decode("utf-8", "replace"))
    return names


def describe_exit(code: int | None) -> str:
    if code is None:
        return "exit status unknown"
    if code < 0:
        try:
            return f"terminated with signal {signal.Signals(-code).name}"
        except ValueError:
            return f"terminated with signal {-code}"
    if os.name == "nt" and code > 0xFFFF:
        return f"exited with code {code} (0x{code & 0xFFFFFFFF:08X})"
    return f"exited with code {code}"


def _decode(data: bytes) -> str:
    return data.decode("utf-8", "replace").replace("\r\n", "\n")


class OutputCapture:
    """一个测试进程的 stderr：保留开头 CAPTURE_HEAD 与末尾 CAPTURE_TAIL 字节，中间计数省略。"""

    def __init__(self) -> None:
        self._cond = threading.Condition()
        self._head = bytearray()
        self._tail = bytearray()
        self._dropped = 0
        self._last_data = 0.0
        self._closed = False

    def append(self, chunk: bytes) -> None:
        with self._cond:
            room = CAPTURE_HEAD - len(self._head)
            if room > 0:
                self._head += chunk[:room]
                chunk = chunk[room:]
            if chunk:
                self._tail += chunk
                excess = len(self._tail) - CAPTURE_TAIL
                if excess > 0:
                    del self._tail[:excess]
                    self._dropped += excess
            self._last_data = time.monotonic()
            self._cond.notify_all()

    def close(self) -> None:
        with self._cond:
            self._closed = True
            self._cond.notify_all()

    def reset(self) -> None:
        with self._cond:
            self._head.clear()
            self._tail.clear()
            self._dropped = 0

    def settle(self, since: float) -> None:
        """等 stderr 连续安静 SETTLE_QUIET 秒（从 since 与最后一次输出中较晚者算起），最多等 SETTLE_LIMIT 秒。"""
        limit = time.monotonic() + SETTLE_LIMIT
        with self._cond:
            while not self._closed:
                now = time.monotonic()
                quiet_at = max(self._last_data, since) + SETTLE_QUIET
                if now >= quiet_at or now >= limit:
                    return
                self._cond.wait(min(quiet_at, limit) - now)

    def wait_closed(self, timeout: float) -> bool:
        with self._cond:
            return self._cond.wait_for(lambda: self._closed, timeout)

    def take(self) -> str:
        with self._cond:
            head, tail, dropped = bytes(self._head), bytes(self._tail), self._dropped
            self._head.clear()
            self._tail.clear()
            self._dropped = 0
        if dropped:
            text = f"{_decode(head)}\n[... {dropped} bytes omitted ...]\n{_decode(tail)}"
        else:
            text = _decode(head + tail)
        return text.strip("\n").rstrip()


@dataclass
class RunOutcome:
    kind: str  # result / crash / timeout / send_failed
    seconds: float = 0.0
    status: int = STATUS_PASS
    leak_count: int = 0
    log_err_count: int = 0
    fuzz: bool = False
    output: str = ""
    detail: str = ""


class TestProcess:
    """一个 `--listen=-` 测试进程：stdout 线程解析消息入队，stderr 线程持续排空到 OutputCapture。"""

    def __init__(self, command: Sequence[str], cwd: Path, display: str) -> None:
        options: dict = {}
        if os.name == "nt":
            options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        elif sys.version_info >= (3, 11):
            options["process_group"] = 0
        try:
            self.proc = subprocess.Popen(
                list(command),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=str(cwd),
                **options,
            )
        except (OSError, ValueError) as exc:
            raise SpawnError(f"无法启动 {display}：{exc}") from exc
        self.display = display
        self.own_group = "process_group" in options
        self.zig_version = ""
        self.capture = OutputCapture()
        self.messages: queue.SimpleQueue[QueueItem] = queue.SimpleQueue()
        self._readers = [
            threading.Thread(target=self._read_stdout, name="zig-test-stdout", daemon=True),
            threading.Thread(target=self._read_stderr, name="zig-test-stderr", daemon=True),
        ]
        for reader in self._readers:
            reader.start()

    def _read_stdout(self) -> None:
        stream = self.proc.stdout
        assert stream is not None
        try:
            while True:
                header = stream.read(HEADER.size)
                if len(header) < HEADER.size:
                    break
                tag, length = HEADER.unpack(header)
                if length > MAX_BODY_BYTES:
                    self.messages.put(ProtocolError(f"消息体过大（tag {tag}，{length} 字节），stdout 协议流已损坏"))
                    return
                body = stream.read(length) if length else b""
                if len(body) < length:
                    break
                self.messages.put((tag, body, time.monotonic()))
        except (OSError, ValueError):
            pass
        self.messages.put(None)

    def _read_stderr(self) -> None:
        stream = self.proc.stderr
        assert stream is not None
        try:
            while True:
                chunk = stream.read1(65536)
                if not chunk:
                    break
                self.capture.append(chunk)
        except (OSError, ValueError):
            pass
        finally:
            self.capture.close()

    def alive(self) -> bool:
        return self.proc.poll() is None

    def send(self, tag: int, body: bytes = b"") -> bool:
        stdin = self.proc.stdin
        assert stdin is not None
        try:
            stdin.write(HEADER.pack(tag, len(body)) + body)
            stdin.flush()
        except (OSError, ValueError):
            return False
        return True

    def receive(self, deadline: float | None) -> Message | None:
        """下一条消息；stdout 结束返回 None；超过 deadline 抛 TimeoutError。

        进程已退出但 stdout 迟迟不断开（孙进程继承了管道）时，EXIT_GRACE 秒后也按结束处理。
        """
        exited_at: float | None = None
        while True:
            wait = POLL_INTERVAL
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError
                wait = min(wait, remaining)
            try:
                item = self.messages.get(timeout=wait)
            except queue.Empty:
                if self.alive():
                    continue
                now = time.monotonic()
                if exited_at is None:
                    exited_at = now
                elif now - exited_at >= EXIT_GRACE:
                    return None
                continue
            if isinstance(item, ProtocolError):
                raise item
            return item

    def handshake(self, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while True:
            try:
                item = self.receive(deadline)
            except TimeoutError:
                self.kill()
                raise SpawnError(f"{self.display} 在 {timeout:g} 秒内没有发出 zig_version 握手") from None
            except ProtocolError as exc:
                self.kill()
                raise SpawnError(f"{self.display} 握手失败：{exc}") from None
            if item is None:
                code = self._reap()
                output = self.capture.take()
                raise SpawnError(f"{self.display} 在握手前退出（{describe_exit(code)}）" + (f"：\n{output}" if output else ""))
            tag, body, _ = item
            if tag == SERVER_ZIG_VERSION:
                self.zig_version = body.decode("utf-8", "replace")
                return

    def query_metadata(self, timeout: float) -> list[str]:
        if not self.send(CLIENT_QUERY_TEST_METADATA):
            raise ProtocolError("发送 query_test_metadata 失败：测试进程已退出")
        deadline = time.monotonic() + timeout
        while True:
            try:
                item = self.receive(deadline)
            except TimeoutError:
                raise ProtocolError(f"{timeout:g} 秒内没有收到 test_metadata") from None
            if item is None:
                code = self._reap()
                output = self.capture.take()
                raise ProtocolError(f"等待 test_metadata 时测试进程退出（{describe_exit(code)}）" + (f"：\n{output}" if output else ""))
            tag, body, _ = item
            if tag == SERVER_TEST_METADATA:
                return parse_test_metadata(body)

    def run_test(self, index: int, timeout: float) -> RunOutcome:
        self.capture.reset()
        sent = time.monotonic()
        if not self.send(CLIENT_RUN_TEST, U32.pack(index)):
            return RunOutcome("send_failed")
        started: float | None = None
        try:
            while True:
                item = self.receive(sent + timeout)
                if item is None:
                    return self._ended("crash", started or sent, "")
                tag, body, at = item
                if tag == SERVER_TEST_STARTED:
                    started = at
                elif tag == SERVER_TEST_RESULTS:
                    return self._result(index, body, started or sent, at)
        except TimeoutError:
            self.kill()
            return self._ended("timeout", started or sent, "")
        except ProtocolError as exc:
            self.kill()
            return self._ended("crash", started or sent, f"protocol error: {exc}")

    def _result(self, index: int, body: bytes, began: float, at: float) -> RunOutcome:
        if len(body) < TEST_RESULTS.size:
            raise ProtocolError("test_results 消息过短")
        result_index, flags = TEST_RESULTS.unpack_from(body)
        if result_index != index:
            raise ProtocolError(f"收到用例 {result_index} 的结果，正在等待用例 {index}")
        outcome = RunOutcome(
            "result",
            seconds=max(0.0, at - began),
            status=flags & 0x3,
            fuzz=bool(flags >> 2 & 1),
            log_err_count=flags >> 3 & ((1 << 30) - 1),
            leak_count=flags >> 33 & ((1 << 31) - 1),
        )
        if outcome.status not in (STATUS_PASS, STATUS_SKIP) or outcome.leak_count or outcome.log_err_count:
            self.capture.settle(at)
            outcome.output = self.capture.take()
        return outcome

    def _ended(self, kind: str, began: float, detail: str) -> RunOutcome:
        seconds = time.monotonic() - began
        code = self._reap()
        if kind == "crash" and not detail:
            detail = describe_exit(code)
        return RunOutcome(kind, seconds=seconds, output=self.capture.take(), detail=detail)

    def _reap(self) -> int | None:
        """stdout 已断开或进程已被杀之后收尾：先等它自行退出（保住真实退出码），再杀掉它派生、仍占着管道的
        进程，最后等 stderr 读完。返回退出码，进程始终不退出时为 None。"""
        code = self.wait_exit(EXIT_WAIT)
        self.kill()
        if code is None:
            code = self.wait_exit(EXIT_WAIT)
        self.capture.wait_closed(STDERR_EOF_WAIT)
        return code

    def wait_exit(self, timeout: float) -> int | None:
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return None

    def kill(self) -> None:
        kill_processes((self,))

    def close(self) -> None:
        """正常结束：发 exit 并关闭 stdin，由测试进程自行退出；EXIT_WAIT 秒内不退出才杀。"""
        if self.alive():
            self.send(CLIENT_EXIT)
        try:
            assert self.proc.stdin is not None
            self.proc.stdin.close()
        except (OSError, ValueError):
            pass
        if self.wait_exit(EXIT_WAIT) is None:
            self.kill()
            self.wait_exit(EXIT_WAIT)
        for reader in self._readers:
            reader.join(STDERR_EOF_WAIT)
        if not any(reader.is_alive() for reader in self._readers):
            for stream in (self.proc.stdout, self.proc.stderr):
                try:
                    if stream is not None:
                        stream.close()
                except (OSError, ValueError):
                    pass


def taskkill_trees(pids: Sequence[int]) -> None:
    """Windows：一次 taskkill /F /T 杀掉这些进程及其子孙进程。"""
    executable = shutil.which("taskkill") or str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "taskkill.exe")
    command = [executable, "/F", "/T"]
    for pid in pids:
        command += ["/PID", str(pid)]
    try:
        subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=TASKKILL_TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def kill_processes(processes: Sequence[TestProcess]) -> None:
    """杀掉测试进程及其派生的进程。只走异常路径：超时、崩溃收尾、协议错误、到点不退出与中断；正常结束的
    close() 不经过这里。

    POSIX 向各自的进程组发 SIGKILL，组长已退出也照发，清掉仍占着管道的孙进程；Windows 只对仍在运行的进程
    合起来调一次 taskkill /F /T（Popen 还持有进程句柄，PID 不会被复用），已退出进程留下的孤儿不在进程树里，
    不再追杀。最后都用 Popen.kill 兜底。
    """
    if os.name == "nt":
        running = [process.proc.pid for process in processes if process.alive()]
        if running:
            taskkill_trees(running)
    else:
        for process in processes:
            if process.own_group:
                try:
                    os.killpg(process.proc.pid, signal.SIGKILL)
                except OSError:
                    pass
    for process in processes:
        try:
            process.proc.kill()
        except OSError:
            pass


# ---------------------------------------------------------------- 调度


@dataclass(eq=False)
class TestBinary:
    label: str
    path: Path
    ordinal: int
    complete: bool = False
    names: list[str] = field(default_factory=list)
    zig_version: str = ""
    spawns: int = 0
    broken: str = ""
    _spawn_failures: int = 0
    _spare: list[TestProcess] = field(default_factory=list)
    _lock: threading.Lock = field(default_factory=threading.Lock)

    @property
    def command(self) -> list[str]:
        return binary_command(self.path)

    def put_spare(self, process: TestProcess) -> None:
        with self._lock:
            self._spare.append(process)

    def take_spare(self) -> TestProcess | None:
        with self._lock:
            return self._spare.pop() if self._spare else None

    def note_spawn(self, error: str = "") -> None:
        with self._lock:
            if not error:
                self.spawns += 1
                self._spawn_failures = 0
                return
            self._spawn_failures += 1
            if self._spawn_failures >= SPAWN_FAILURE_LIMIT and not self.broken:
                self.broken = f"测试进程连续 {self._spawn_failures} 次无法启动：{error}"


@dataclass(eq=False)
class Task:
    binary: TestBinary
    index: int
    name: str
    estimate: float


@dataclass
class TestResult:
    binary: str
    index: int
    name: str
    outcome: str
    seconds: float = 0.0
    message: str = ""
    output: str = ""
    worker: int = -1


def classify(task: Task, outcome: RunOutcome, timeout: float) -> TestResult:
    """把一次执行映射成结果，顺序与 Run.zig::evalZigTest 相同：fail > leak > log_err，skip 单列。"""
    result = TestResult(task.binary.label, task.index, task.name, "pass", outcome.seconds, output=outcome.output)
    if outcome.kind == "timeout":
        result.outcome, result.message = "timeout", f"timed out after {timeout:g}s"
    elif outcome.kind in ("crash", "send_failed"):
        result.outcome, result.message = "crash", f"crashed ({outcome.detail or 'test process exited'})"
    elif outcome.status not in (STATUS_PASS, STATUS_SKIP):
        result.outcome = "fail"
        result.message = "failed" if outcome.status == STATUS_FAIL else f"unknown status {outcome.status}"
        if not outcome.output:
            result.message += " without output"
    elif outcome.leak_count:
        result.outcome, result.message = "leak", f"leaked {outcome.leak_count} allocations"
    elif outcome.log_err_count:
        result.outcome, result.message = "log_err", f"logged {outcome.log_err_count} errors"
    elif outcome.status == STATUS_SKIP:
        result.outcome = "skip"
    return result


def select_indices(names: Sequence[str], filters: Sequence[str]) -> list[int]:
    if not filters:
        return list(range(len(names)))
    return [index for index, name in enumerate(names) if any(text in name for text in filters)]


def drop_duplicate_names(binaries: Sequence[TestBinary], selected: dict[str, list[int]]) -> dict[str, int]:
    """--dedupe：同名用例只保留在先出现的二进制里，返回每个二进制被去掉的数量。"""
    seen: set[str] = set()
    dropped: dict[str, int] = {}
    for binary in binaries:
        keep = [index for index in selected[binary.label] if binary.names[index] not in seen]
        dropped[binary.label] = len(selected[binary.label]) - len(keep)
        selected[binary.label] = keep
        seen.update(binary.names[index] for index in keep)
    return dropped


def order_tasks(tasks: list[Task]) -> list[Task]:
    """最长预计耗时优先；同估计值按用例序号、再按二进制交错，首轮无缓存时各二进制均匀铺开。"""
    return sorted(tasks, key=lambda task: (-task.estimate, task.index, task.binary.ordinal))


def timings_path(root: Path, label: str) -> Path:
    override = os.environ.get(TIMINGS_ENV, "").strip()
    directory = root / override if override else root / ".local" / "test-timings"
    return directory / f"{label}.json"


def load_timings(path: Path) -> dict[str, float]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        str(name): float(value)
        for name, value in data.items()
        if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0
    }


def save_timings(path: Path, names: Sequence[str], previous: dict[str, float], measured: dict[str, float], prune: bool) -> None:
    """合并旧值与本轮实测，prune（确定是完整二进制）时才删去二进制里已不存在的用例；先写临时文件再原子替换。"""
    current = set(names)
    merged = {name: seconds for name, seconds in previous.items() if not prune or name in current}
    merged.update({name: seconds for name, seconds in measured.items() if name in current})
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    payload = json.dumps({name: round(seconds, 6) for name, seconds in merged.items()}, ensure_ascii=False, indent=1, sort_keys=True)
    temporary.write_text(payload + "\n", encoding="utf-8", newline="\n")
    os.replace(temporary, path)


class Scheduler:
    def __init__(self, tasks: Sequence[Task], serial_tasks: Sequence[Task]) -> None:
        self._lock = threading.Lock()
        self._tasks = deque(tasks)
        self._serial = deque(serial_tasks)

    def next(self, serial_worker: bool) -> Task | None:
        with self._lock:
            if serial_worker and self._serial:
                return self._serial.popleft()
            if self._tasks:
                return self._tasks.popleft()
            return None

    def drain(self) -> list[Task]:
        with self._lock:
            remaining = list(self._serial) + list(self._tasks)
            self._serial.clear()
            self._tasks.clear()
            return remaining


_print_lock = threading.Lock()


def emit(text: str, stream=None) -> None:
    with _print_lock:
        print(text, file=stream if stream is not None else sys.stdout, flush=True)


class Session:
    """一轮测试的共享状态：结果、计数、活跃进程登记与中断标志。"""

    def __init__(self, root: Path, seed: int, timeout: float, total: int) -> None:
        self.root = root
        self.seed = seed
        self.timeout = timeout
        self.total = total
        self.runner_args = runner_args(root, seed)
        self.stop = threading.Event()
        self.results: list[TestResult] = []
        self.counts: Counter[str] = Counter()
        self._lock = threading.Lock()
        self._processes: set[TestProcess] = set()

    def spawn(self, binary: TestBinary) -> TestProcess:
        """启动并握手；失败后等 SPAWN_RETRY_DELAY 重试一次（智能应用控制可能让新 exe 首次启动失败）。"""
        error: SpawnError | None = None
        for attempt in range(2):
            if attempt:
                time.sleep(SPAWN_RETRY_DELAY)
            process: TestProcess | None = None
            try:
                process = TestProcess(binary.command + self.runner_args, self.root, str(binary.path))
                self.register(process)
                process.handshake(STARTUP_TIMEOUT)
                binary.note_spawn()
                return process
            except SpawnError as exc:
                error = exc
                if process is not None:
                    self.release(process)
        assert error is not None
        binary.note_spawn(str(error))
        raise error

    def register(self, process: TestProcess) -> None:
        with self._lock:
            self._processes.add(process)
            stopped = self.stop.is_set()
        if stopped:
            process.kill()

    def release(self, process: TestProcess) -> None:
        process.close()
        with self._lock:
            self._processes.discard(process)

    def kill_all(self) -> None:
        with self._lock:
            processes = list(self._processes)
        kill_processes(processes)

    def record(self, result: TestResult) -> None:
        if self.stop.is_set() and result.outcome in ("crash", "timeout"):
            result.outcome, result.message, result.output = "not_run", "interrupted", ""
        with self._lock:
            self.results.append(result)
            self.counts[result.outcome] += 1
        if result.outcome in FAILED_OUTCOMES and result.message != "interrupted":
            emit(f"{TAG} {result.outcome.upper()} [{result.binary}] {result.name}: {result.message}")

    def progress(self) -> tuple[int, int]:
        with self._lock:
            done = len(self.results)
            failed = sum(count for outcome, count in self.counts.items() if outcome in FAILED_OUTCOMES)
        return done, failed


class Worker(threading.Thread):
    def __init__(self, session: Session, scheduler: Scheduler, number: int, serial: bool) -> None:
        super().__init__(name=f"zig-test-worker-{number}", daemon=True)
        self.session = session
        self.scheduler = scheduler
        self.number = number
        self.serial = serial
        self.busy = 0.0
        self.tests = 0
        self.idle_at: float | None = None
        self.done = threading.Event()
        self._processes: dict[str, TestProcess] = {}

    def run(self) -> None:
        try:
            while not self.session.stop.is_set():
                task = self.scheduler.next(self.serial)
                if task is None:
                    break
                began = time.monotonic()
                try:
                    result = self.execute(task)
                except Exception as exc:  # noqa: BLE001 - 运行器自身的缺陷也要落到结果里，不能丢用例
                    process = self._processes.pop(task.binary.label, None)
                    if process is not None:
                        self.session.release(process)
                    result = TestResult(task.binary.label, task.index, task.name, "crash", message=f"internal runner error: {exc!r}")
                self.busy += time.monotonic() - began
                self.tests += 1
                result.worker = self.number
                self.session.record(result)
        finally:
            self.idle_at = time.monotonic()
            for process in self._processes.values():
                self.session.release(process)
            self._processes.clear()
            self.done.set()

    def execute(self, task: Task) -> TestResult:
        binary = task.binary
        for attempt in range(2):
            if binary.broken:
                return TestResult(binary.label, task.index, task.name, "not_run", message=binary.broken)
            process = self._processes.get(binary.label)
            if process is None:
                process = binary.take_spare()
                if process is None:
                    try:
                        process = self.session.spawn(binary)
                    except SpawnError as exc:
                        return TestResult(binary.label, task.index, task.name, "crash", message=f"unable to start test process: {exc}")
                self._processes[binary.label] = process
            outcome = process.run_test(task.index, self.session.timeout)
            if outcome.kind != "result":
                del self._processes[binary.label]
                self.session.release(process)
            if outcome.kind == "send_failed" and attempt == 0:
                continue
            return classify(task, outcome, self.session.timeout)
        raise AssertionError("unreachable")


# ---------------------------------------------------------------- 主流程


@dataclass
class Plan:
    root: Path
    seed: int
    jobs: int
    timeout: float
    filters: list[str]
    serial_filters: list[str]
    suite: str | None
    dedupe: bool = False
    no_build: bool = False
    binary_args: list[str] = field(default_factory=list)
    defines: list[str] = field(default_factory=list)
    zig_args: list[str] = field(default_factory=list)
    build: dict | None = None
    build_filters: list[str] = field(default_factory=list)
    binaries: list[TestBinary] = field(default_factory=list)
    deduplicated: dict[str, int] = field(default_factory=dict)


def reproduce_command(plan: Plan, name: str) -> str:
    """只重跑用例 name 的完整命令：本轮的 --suite / --binary、-D、--zig-arg 与 --no-build，加上本轮 seed 与
    --filter <name>；非默认的 --root 与 --timeout 一并带上。解释器同 justfile（Windows 写 python，其他系统
    写 python3），按主机 shell 加引号：POSIX 用 shlex.quote，Windows 用 subprocess.list2cmdline。"""
    windows = host_is_windows()
    argv = ["python" if windows else "python3", "scripts/zig_test.py"]
    if plan.root != REPO_ROOT:
        argv += ["--root", plan.root.as_posix()]
    if plan.suite is not None:
        argv += ["--suite", plan.suite]
    for path in plan.binary_args:
        argv += ["--binary", path]
    argv += [f"-D{define}" for define in plan.defines]
    argv += [f"--zig-arg={arg}" for arg in plan.zig_args]
    if plan.no_build:
        argv.append("--no-build")
    if plan.timeout != DEFAULT_TIMEOUT:
        argv += ["--timeout", repr(plan.timeout)]
    argv += ["--seed", f"0x{plan.seed:x}", "--filter", name]
    return subprocess.list2cmdline(argv) if windows else shlex.join(argv)


def parse_seed(text: str) -> int:
    try:
        value = int(text, 0)
    except ValueError:
        try:
            value = int(text, 10)
        except ValueError:
            raise argparse.ArgumentTypeError(f"不是十进制或 0x 十六进制整数：{text}") from None
    if not 0 <= value <= 0xFFFFFFFF:
        raise argparse.ArgumentTypeError(f"seed 必须在 u32 范围内（0..0xffffffff）：{text}")
    return value


def _positive(kind: Callable[[str], float | int]) -> Callable[[str], float | int]:
    def convert(text: str) -> float | int:
        try:
            value = kind(text)
        except ValueError:
            raise argparse.ArgumentTypeError(f"无效的数值：{text}") from None
        if value <= 0:
            raise argparse.ArgumentTypeError(f"必须大于 0：{text}")
        return value

    return convert


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    doc = __doc__ or ""
    parser = argparse.ArgumentParser(
        prog="zig_test.py",
        description=doc.splitlines()[0],
        epilog=doc.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    parser.add_argument("--suite", choices=sorted(SUITES), help="构建并运行的测试套件（未给 --binary 时默认 vt）")
    parser.add_argument("--binary", action="append", default=[], metavar="PATH", help="直接运行的测试二进制，可重复")
    parser.add_argument("--jobs", type=_positive(int), default=os.cpu_count() or 1, metavar="N", help="并行工作线程数（默认 CPU 数）")
    parser.add_argument("--seed", type=parse_seed, metavar="N", help="传给测试的 u32 seed（十进制或 0x 十六进制，默认随机）")
    parser.add_argument("--filter", action="append", default=[], metavar="TEXT", help="用例全名子串过滤，可重复（取并集）")
    parser.add_argument("--serial-filter", action="append", default=[], metavar="TEXT", help="命中的用例由一个专用线程顺序执行，可重复")
    parser.add_argument("--dedupe", action="store_true", help="同名用例只在先出现的二进制里运行（覆盖取舍，默认关闭）")
    parser.add_argument("--timeout", type=_positive(float), default=DEFAULT_TIMEOUT, metavar="SECONDS", help="单个用例超时秒数（默认 600）")
    parser.add_argument("--no-build", action="store_true", help="跳过 zig build，直接运行已安装的二进制")
    parser.add_argument("--list", action="store_true", help="列出（过滤后的）用例后退出")
    parser.add_argument("--json", type=Path, metavar="PATH", help="写出机器可读结果")
    parser.add_argument("-D", dest="defines", action="append", default=[], metavar="OPT=VAL", help="透传给 zig build 的 -D 选项")
    parser.add_argument("--zig-arg", dest="zig_args", action="append", default=[], metavar="ARG", help="透传给 zig build 的其他参数")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def collect_binaries(plan: Plan, args: argparse.Namespace) -> None:
    if not plan.root.is_dir():
        raise FatalError(f"仓库根不是目录：{plan.root}")
    if plan.suite == "main" and not args.no_build and host_is_windows():
        raise FatalError(MAIN_SUITE_ON_WINDOWS)
    entries: list[tuple[str, Path, bool]] = []
    if plan.suite is not None:
        if not args.no_build:
            command = build_command(plan.root, plan.suite, args.defines, args.zig_args)
            plan.build = {"command": command, "seconds": run_build(plan.root, command)}
            plan.build_filters = build_test_filters(args.defines, args.zig_args)
        found, missing = suite_binaries(install_prefix(plan.root, args.zig_args), plan.suite)
        if missing:
            if not args.no_build:
                hint = f"构建步骤 {SUITES[plan.suite].step} 没有安装它们"
            elif plan.suite == "main" and host_is_windows():
                hint = "Windows 上无法构建 ghostty-test，主套件以 gx-ci 的 linux-main 为准"
            else:
                hint = "先去掉 --no-build 构建一次"
            raise FatalError(f"套件 {plan.suite} 缺少测试二进制（{hint}）：" + "、".join(str(path) for path in missing))
        complete = plan.build is not None and not plan.build_filters
        entries += [(label, path, complete) for label, path in found]
    for raw in args.binary:
        path = Path(raw).absolute()
        if not path.is_file():
            raise FatalError(f"找不到测试二进制：{raw}")
        entries.append((binary_label(path), path, False))
    seen_paths: set[str] = set()
    labels: Counter[str] = Counter()
    for label, path, complete in entries:
        key = os.path.normcase(str(path))
        if key in seen_paths:
            continue
        seen_paths.add(key)
        labels[label] += 1
        unique = label if labels[label] == 1 else f"{label}-{labels[label]}"
        plan.binaries.append(TestBinary(unique, path, len(plan.binaries), complete))
    if not plan.binaries:
        raise FatalError("没有要运行的测试二进制")


def describe_no_tests(plan: Plan) -> str:
    total = sum(len(binary.names) for binary in plan.binaries)
    built_with = " ".join(f"-Dtest-filter={text!r}" for text in plan.build_filters)
    if total:
        trimmed = f"，已按构建期 {built_with} 裁剪" if built_with else ""
        filters = " ".join(repr(text) for text in plan.filters)
        return f"运行期 --filter {filters} 没有匹配任何用例（{len(plan.binaries)} 个二进制共 {total} 条用例{trimmed}）"
    if built_with:
        return f"构建期 {built_with} 裁掉了全部用例：本轮构建出的测试二进制里没有用例"
    message = "测试二进制本身没有用例：" + "、".join(str(binary.path) for binary in plan.binaries)
    if plan.suite is not None and plan.build is None:
        message += "（--no-build 运行的是上次安装的二进制，上次构建带 -Dtest-filter 时可能已被裁空）"
    return message


def load_metadata(session: Session, binaries: Sequence[TestBinary]) -> None:
    errors: dict[str, str] = {}

    def query(binary: TestBinary, done: threading.Event) -> None:
        process: TestProcess | None = None
        try:
            process = session.spawn(binary)
            binary.names = process.query_metadata(STARTUP_TIMEOUT)
            binary.zig_version = process.zig_version
            binary.put_spare(process)
        except (SpawnError, ProtocolError) as exc:
            errors[binary.label] = str(exc)
            if process is not None:
                session.release(process)
        finally:
            done.set()

    finished = [threading.Event() for _ in binaries]
    threads = [threading.Thread(target=query, args=(binary, done), daemon=True) for binary, done in zip(binaries, finished)]
    for thread in threads:
        thread.start()
    for done in finished:
        while not done.wait(0.2):
            pass
    for thread in threads:
        thread.join()
    if errors:
        release_spares(session, binaries)
        raise FatalError("无法读取用例元数据：\n" + "\n".join(f"  {label}: {message}" for label, message in errors.items()))


def release_spares(session: Session, binaries: Sequence[TestBinary]) -> None:
    for binary in binaries:
        while (process := binary.take_spare()) is not None:
            session.release(process)


def run_workers(session: Session, tasks: list[Task], serial_tasks: list[Task], jobs: int) -> tuple[list[Worker], bool]:
    """主线程只在 Worker.done 上等待，不用 Thread.join(timeout)：CPython 3.12 及更早版本里，join 被
    KeyboardInterrupt 打断时 Thread._wait_for_tstate_lock 会释放仍在运行的线程的 tstate 锁并把它标成已结束，
    之后的 join 立即返回，正在执行的用例就来不及记入结果。"""
    scheduler = Scheduler(tasks, serial_tasks)
    count = max(1, min(jobs, len(tasks) + len(serial_tasks)))
    workers = [Worker(session, scheduler, number, serial=number == 0 and bool(serial_tasks)) for number in range(count)]
    started = time.monotonic()
    last_progress = started
    interrupted = False
    for worker in workers:
        worker.start()
    try:
        while True:
            pending = [worker for worker in workers if not worker.done.is_set()]
            if not pending:
                break
            pending[0].done.wait(0.05)
            now = time.monotonic()
            if now - last_progress >= PROGRESS_INTERVAL:
                last_progress = now
                done, failed = session.progress()
                percent = 100 * done // max(1, session.total)
                emit(f"{TAG} {done}/{session.total} ({percent}%) · failed {failed} · {now - started:.1f}s")
    except KeyboardInterrupt:
        interrupted = True
        session.stop.set()
        session.kill_all()
        deadline = time.monotonic() + 10
        for worker in workers:
            worker.done.wait(max(0.0, deadline - time.monotonic()))
    for worker in workers:
        if worker.done.is_set():
            worker.join()
    for task in scheduler.drain():
        session.record(TestResult(task.binary.label, task.index, task.name, "not_run", message="interrupted" if interrupted else "not scheduled"))
    return workers, interrupted


def binary_counts(binary: TestBinary, results: Sequence[TestResult], selected: int) -> dict[str, int]:
    counts = {key: 0 for key in COUNT_KEYS.values()}
    for result in results:
        if result.binary == binary.label:
            counts[COUNT_KEYS[result.outcome]] += 1
    return {"total": selected, **counts}


def build_report(plan: Plan, session: Session, selected: dict[str, int], workers: Sequence[Worker], interrupted: bool, timing: dict[str, float], code: int) -> dict:
    """--json 的结构（schema 1）：顶层 exit_code/ok/interrupted/seed/seed_hex/jobs/timeout/filters/
    serial_filters/dedupe/suite/build/wall_seconds/test_seconds/reproduce（只重跑第一个失败用例的完整命令，
    见 reproduce_command；没有失败或失败全是 not_run 时为 null），binaries[]（label/path/zig_version/
    total_tests/selected/deduplicated/counts/test_seconds/spawns/timings_file），failures[]、slowest[]、
    workers[]、tests[]。
    """
    ordinal = {binary.label: binary.ordinal for binary in plan.binaries}
    results = sorted(session.results, key=lambda result: (ordinal.get(result.binary, 0), result.index))
    ran = [result for result in results if result.outcome != "not_run"]
    first = next((result for result in ran if result.outcome in FAILED_OUTCOMES), None)
    return {
        "schema": REPORT_SCHEMA,
        "exit_code": code,
        "ok": code == 0,
        "interrupted": interrupted,
        "seed": plan.seed,
        "seed_hex": f"0x{plan.seed:x}",
        "jobs": plan.jobs,
        "timeout": plan.timeout,
        "filters": plan.filters,
        "serial_filters": plan.serial_filters,
        "dedupe": plan.dedupe,
        "suite": plan.suite,
        "build": plan.build,
        "wall_seconds": round(timing["wall"], 3),
        "test_seconds": round(timing["tests"], 3),
        "reproduce": None if first is None else reproduce_command(plan, first.name),
        "binaries": [
            {
                "label": binary.label,
                "path": str(binary.path),
                "zig_version": binary.zig_version,
                "total_tests": len(binary.names),
                "selected": selected.get(binary.label, 0),
                "deduplicated": plan.deduplicated.get(binary.label, 0),
                "counts": binary_counts(binary, results, selected.get(binary.label, 0)),
                "test_seconds": round(sum(result.seconds for result in ran if result.binary == binary.label), 3),
                "spawns": binary.spawns,
                "timings_file": str(timings_path(plan.root, binary.label)),
            }
            for binary in plan.binaries
        ],
        "failures": [
            {
                "binary": result.binary,
                "index": result.index,
                "name": result.name,
                "outcome": result.outcome,
                "message": result.message,
                "output": result.output,
                "seconds": round(result.seconds, 6),
            }
            for result in results
            if result.outcome in FAILED_OUTCOMES
        ],
        "slowest": [
            {"binary": result.binary, "index": result.index, "name": result.name, "seconds": round(result.seconds, 6)}
            for result in sorted(ran, key=lambda result: -result.seconds)[:SLOWEST_COUNT]
        ],
        "workers": [
            {
                "worker": worker.number,
                "serial": worker.serial,
                "tests": worker.tests,
                "busy_seconds": round(worker.busy, 3),
                "idle_at": round((worker.idle_at or 0.0) - timing["tests_started"], 3),
            }
            for worker in workers
        ],
        "tests": [
            {
                "binary": result.binary,
                "index": result.index,
                "name": result.name,
                "outcome": result.outcome,
                "seconds": round(result.seconds, 6),
                "worker": result.worker,
            }
            for result in results
        ],
    }


def print_summary(report: dict) -> None:
    columns = ("total", *COUNT_KEYS.values())
    if not any(binary["counts"]["not_run"] for binary in report["binaries"]):
        columns = tuple(column for column in columns if column != "not_run")
    width = max([6, *(len(binary["label"]) for binary in report["binaries"])])
    emit(f"{TAG} summary")
    emit("  " + "binary".ljust(width) + "".join(column.rjust(max(8, len(column) + 2)) for column in columns) + "  test-time")
    for binary in report["binaries"]:
        cells = "".join(str(binary["counts"][column]).rjust(max(8, len(column) + 2)) for column in columns)
        emit(f"  {binary['label'].ljust(width)}{cells}  {binary['test_seconds']:.1f}s")
    failures = report["failures"]
    individual = [failure for failure in failures if failure["outcome"] != "not_run"]
    if individual:
        emit(f"{TAG} failures ({len(individual)})")
        for failure in individual:
            emit(f"--- {failure['outcome'].upper()} [{failure['binary']}] {failure['name']} (#{failure['index']}, {failure['seconds']:.3f}s): {failure['message']}")
            if failure["output"]:
                emit(failure["output"])
    skipped_groups = Counter((failure["binary"], failure["message"]) for failure in failures if failure["outcome"] == "not_run")
    for (label, message), count in sorted(skipped_groups.items()):
        emit(f"--- NOT_RUN [{label}] {count} tests: {message}")
    if report["slowest"]:
        emit(f"{TAG} slowest {len(report['slowest'])}")
        for entry in report["slowest"]:
            emit(f"  {entry['seconds']:9.3f}s  {entry['binary']}  {entry['name']}")
    workers = report["workers"]
    if workers:
        idle = [worker["idle_at"] for worker in workers]
        busy = [worker["busy_seconds"] for worker in workers]
        emit(f"{TAG} workers {len(workers)}: idle from {min(idle):.1f}s to {max(idle):.1f}s, busy {min(busy):.1f}s..{max(busy):.1f}s")


def print_verdict(report: dict) -> None:
    totals = Counter()
    for binary in report["binaries"]:
        totals.update(binary["counts"])
    failed = sum(totals[key] for key in ("failed", "leaked", "log_err", "crashed", "timeouts", "not_run"))
    build = report["build"]["seconds"] if report["build"] else 0.0
    timing = f"wall {report['wall_seconds']:.1f}s (build {build:.1f}s, tests {report['test_seconds']:.1f}s) · jobs {report['jobs']} · seed {report['seed_hex']}"
    if report["interrupted"]:
        emit(f"{TAG} INTERRUPTED {totals['passed']} passed, {totals['not_run']} not run · {timing}")
    elif failed:
        emit(f"{TAG} FAIL {failed} of {totals['total']} tests failed ({totals['passed']} passed, {totals['skipped']} skipped) · {timing}")
        if report["reproduce"]:
            emit(f"{TAG} 重现：{report['reproduce']}")
    else:
        emit(f"{TAG} PASS {totals['passed']} passed, {totals['skipped']} skipped · {timing}")


def write_json(path: Path | None, payload: dict) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")


def _utf8_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            pass


def route_termination_signals() -> list[int]:
    """POSIX：把处于默认处理的 SIGTERM、SIGHUP 接到 signal.default_int_handler，与 Ctrl+C 一样抛
    KeyboardInterrupt，走同一条清理路径并退出 130。被忽略的（如 nohup 下的 SIGHUP）或已有处理器的保持不变；
    返回改过的信号，由 main() 结束时恢复成默认处理。"""
    if os.name != "posix" or threading.current_thread() is not threading.main_thread():
        return []
    routed: list[int] = []
    for name in ("SIGTERM", "SIGHUP"):
        signum = getattr(signal, name, None)
        if signum is not None and signal.getsignal(signum) == signal.SIG_DFL:
            signal.signal(signum, signal.default_int_handler)
            routed.append(signum)
    return routed


def main(argv: Sequence[str] | None = None) -> int:
    _utf8_stdio()
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    routed = route_termination_signals()
    try:
        return run(args)
    finally:
        for signum in routed:
            signal.signal(signum, signal.SIG_DFL)


def run(args: argparse.Namespace) -> int:
    started = time.monotonic()
    plan = Plan(
        root=args.root.resolve(),
        seed=random.SystemRandom().getrandbits(32) if args.seed is None else args.seed,
        jobs=args.jobs,
        timeout=args.timeout,
        filters=list(args.filter),
        serial_filters=list(args.serial_filter),
        suite=args.suite or (None if args.binary else "vt"),
        dedupe=args.dedupe,
        no_build=args.no_build,
        binary_args=list(args.binary),
        defines=list(args.defines),
        zig_args=list(args.zig_args),
    )
    session = Session(plan.root, plan.seed, plan.timeout, 0)
    try:
        collect_binaries(plan, args)
        load_metadata(session, plan.binaries)
        selected = {binary.label: select_indices(binary.names, plan.filters) for binary in plan.binaries}
        if plan.dedupe:
            plan.deduplicated = drop_duplicate_names(plan.binaries, selected)
        if args.list:
            release_spares(session, plan.binaries)
            listing = [
                {"binary": binary.label, "index": index, "name": binary.names[index]}
                for binary in plan.binaries
                for index in selected[binary.label]
            ]
            for entry in listing:
                emit(f"{entry['binary']}\t{entry['index']}\t{entry['name']}")
            emit(f"{TAG} {len(listing)} tests in {len(plan.binaries)} binaries", sys.stderr)
            write_json(args.json, {"schema": REPORT_SCHEMA, "exit_code": 0, "ok": True, "list": listing})
            return 0
        if not any(selected.values()):
            release_spares(session, plan.binaries)
            raise FatalError(describe_no_tests(plan))
    except KeyboardInterrupt:
        session.stop.set()
        session.kill_all()
        release_spares(session, plan.binaries)
        emit(f"{TAG} interrupted", sys.stderr)
        return 130
    except FatalError as exc:
        emit(f"{TAG} error: {exc}", sys.stderr)
        write_json(args.json, {"schema": REPORT_SCHEMA, "exit_code": exc.code, "ok": False, "error": str(exc), "seed": plan.seed, "seed_hex": f"0x{plan.seed:x}"})
        return exc.code

    previous = {binary.label: load_timings(timings_path(plan.root, binary.label)) for binary in plan.binaries}
    tasks = [
        Task(binary, index, binary.names[index], previous[binary.label].get(binary.names[index], DEFAULT_ESTIMATE))
        for binary in plan.binaries
        for index in selected[binary.label]
    ]
    ordered = order_tasks(tasks)
    serial = [task for task in ordered if any(text in task.name for text in plan.serial_filters)]
    parallel = [task for task in ordered if not any(text in task.name for text in plan.serial_filters)]
    session.total = len(ordered)
    emit(
        f"{TAG} running {len(ordered)} tests from {len(plan.binaries)} binaries ("
        + ", ".join(f"{binary.label}: {len(selected[binary.label])}" for binary in plan.binaries)
        + f") with {min(plan.jobs, len(ordered))} jobs, seed 0x{plan.seed:x}"
        + (f", {len(serial)} serial" if serial else "")
        + (f", {sum(plan.deduplicated.values())} duplicate names skipped" if plan.dedupe else "")
    )
    tests_started = time.monotonic()
    workers, interrupted = run_workers(session, parallel, serial, plan.jobs)
    release_spares(session, plan.binaries)
    finished = time.monotonic()

    for binary in plan.binaries:
        measured = {result.name: result.seconds for result in session.results if result.binary == binary.label and result.outcome != "not_run"}
        if measured:
            try:
                save_timings(timings_path(plan.root, binary.label), binary.names, previous[binary.label], measured, binary.complete)
            except OSError as exc:
                emit(f"{TAG} warning: 无法写入耗时缓存 {timings_path(plan.root, binary.label)}：{exc}", sys.stderr)

    failed = any(result.outcome in FAILED_OUTCOMES for result in session.results)
    code = 130 if interrupted else (1 if failed else 0)
    timing = {"wall": finished - started, "tests": finished - tests_started, "tests_started": tests_started}
    report = build_report(plan, session, {label: len(indices) for label, indices in selected.items()}, workers, interrupted, timing, code)
    print_summary(report)
    print_verdict(report)
    try:
        write_json(args.json, report)
    except OSError as exc:
        emit(f"{TAG} error: 无法写入 {args.json}：{exc}", sys.stderr)
        return 2
    return code


if __name__ == "__main__":
    raise SystemExit(main())
