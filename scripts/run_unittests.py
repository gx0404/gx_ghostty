#!/usr/bin/env python3
"""并行运行框架单元测试 scripts/test_*.py：每个 TestCase 类一个子进程。

用法：
  python scripts/run_unittests.py [--jobs N] [--list] [--timeout SECONDS] [PATTERN ...]

单元 id 形如 test_x.ClassName；定义了 load_tests 的模块整体是一个单元，id 为 test_x。
父进程把 scripts/ 放进 sys.path 导入测试模块来枚举单元（与 unittest discover -s scripts
相同的导入方式），再在仓库根对每个单元运行 `python -m unittest -q scripts.<单元 id>`。
并发数默认取 CPU 逻辑核数与 8 的较小值：这些单元主要在起子进程（git、bash、PowerShell、
Python），Windows 上进程创建在少量并发时就饱和，再多的单元只会互相拖慢；--jobs 可覆盖。
调度按 .local/test-timings/unittest.json 记录的上次耗时从慢到快（没有记录的新单元最先），
每次运行后更新该缓存。类属性 RUN_LAST = True 的 TestCase（load_tests 模块则看同名模块属性）
排在队尾，其余单元全部启动后才启动，留给会拖慢整机进程创建的单元（如启动 Windows
PowerShell 5.1 的探针）。

PATTERN（可多个，取并集）：test_x、scripts.test_x 或 scripts/test_x.py 选整个模块；
test_x.ClassName 选一个单元；含 * ? [ 的按 fnmatch 匹配单元 id 或模块名。每个 PATTERN
必须命中至少一个单元。单个测试方法请直接运行 python -m unittest scripts.test_x.Class.test_y。

输出：每个单元结束时打印一行状态；全部结束后打印失败单元的完整输出、最慢的 5 个单元，
以及汇总（Ran N tests、墙钟时间与 OK / FAILED (failures=…, errors=…)）。

退出码：0 全部单元通过（skip 不算失败）；1 有失败、错误、崩溃、超时，或子进程运行的
测试数与发现阶段不符；2 用法或发现错误（模块导入失败、PATTERN 未命中、没有任何测试）；
单元运行期间被 Ctrl+C（POSIX 上还有 SIGTERM、SIGHUP）中断时终止运行中的单元并以 130 退出。
"""

from __future__ import annotations

import argparse
import contextlib
import fnmatch
import importlib
import json
import locale
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import unittest
from dataclasses import dataclass, fields
from pathlib import Path
from typing import IO, Callable, Iterator, Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
TESTS_DIR = "scripts"
MODULE_GLOB = "test_*.py"
TIMINGS_FILE = Path(".local") / "test-timings" / "unittest.json"
TIMINGS_VERSION = 1
DEFAULT_TIMEOUT_SECONDS = 600.0
# Units mostly start processes; past a handful of concurrent spawners Windows process creation
# thrashes and every unit slows down, so the default never runs more than this many at once.
DEFAULT_MAX_JOBS = 8
# A TestCase class (or a load_tests module) with this attribute set to True starts after every other unit.
RUN_LAST_ATTRIBUTE = "RUN_LAST"
SLOWEST_SHOWN = 5
POLL_SECONDS = 0.01
KILL_WAIT_SECONDS = 30.0

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_INTERRUPTED = 130

_RAN_LINE = re.compile(r"Ran (\d+) tests? in [\d.]+s")
_STATUS_LINE = re.compile(r"(OK|FAILED|NO TESTS RAN)(?: \((.*)\))?")
_STATUS_ITEM = re.compile(r"(failures|errors|skipped|expected failures|unexpected successes)=(\d+)")
_GLOB_CHARS = frozenset("*?[")


class DiscoveryError(Exception):
    """The tests cannot be enumerated or selected (exit code 2)."""


@dataclass
class Counts:
    tests: int = 0
    failures: int = 0
    errors: int = 0
    skipped: int = 0
    expected_failures: int = 0
    unexpected_successes: int = 0

    def __iadd__(self, other: Counts) -> Counts:
        for item in fields(self):
            setattr(self, item.name, getattr(self, item.name) + getattr(other, item.name))
        return self

    def details(self) -> str:
        """The non-zero items of unittest's parenthesised summary, e.g. 'failures=1, skipped=2'."""
        names = ("failures", "errors", "skipped", "expected_failures", "unexpected_successes")
        return ", ".join(f"{name.replace('_', ' ')}={getattr(self, name)}" for name in names if getattr(self, name))


@dataclass(frozen=True)
class Summary:
    status: str  # "OK", "FAILED" or "NO TESTS RAN"
    counts: Counts


@dataclass(frozen=True)
class Unit:
    id: str  # test_x.ClassName, or test_x for a module that defines load_tests
    tests: int  # number of tests the parent's loader found
    last: bool = False  # RUN_LAST: start after every other unit

    @property
    def module(self) -> str:
        return self.id.partition(".")[0]


@dataclass
class UnitResult:
    unit: Unit
    seconds: float
    returncode: int | None
    output: str
    summary: Summary | None
    problem: str | None = None  # a failure that unittest's own summary does not show
    timed_out: bool = False

    @property
    def passed(self) -> bool:
        return self.problem is None and self.summary is not None and self.summary.status == "OK"

    @property
    def label(self) -> str:
        if self.passed:
            return "ok"
        if self.timed_out:
            return "TIMEOUT"
        return "CRASH" if self.summary is None else "FAIL"

    @property
    def counts(self) -> Counts:
        counts = Counts()
        if self.summary is not None:
            counts += self.summary.counts
        if self.problem is not None:
            counts.errors += 1
        return counts


def parse_summary(text: str) -> Summary | None:
    """Parse the closing 'Ran N tests in Xs' block that unittest's text runner writes to stderr.

    The last block wins, so anything a test printed earlier cannot be mistaken for it; None
    means the block is missing or malformed (the child crashed or was killed).
    """
    lines = [line.strip() for line in text.splitlines()]
    for index in range(len(lines) - 1, -1, -1):
        ran = _RAN_LINE.fullmatch(lines[index])
        if ran is None:
            continue
        status = _STATUS_LINE.fullmatch(next((line for line in lines[index + 1:] if line), ""))
        if status is None:
            return None
        counts = Counts(tests=int(ran.group(1)))
        for item in filter(None, (status.group(2) or "").split(", ")):
            match = _STATUS_ITEM.fullmatch(item)
            if match is None:
                return None
            setattr(counts, match.group(1).replace(" ", "_"), int(match.group(2)))
        return Summary(status.group(1), counts)
    return None


# ---- discovery ----


def discover_modules(tests_dir: Path) -> list[str]:
    """Names of the top-level test_*.py modules, the set `unittest discover -s scripts` imports."""
    if not tests_dir.is_dir():
        raise DiscoveryError(f"测试目录不存在：{tests_dir}")
    names: list[str] = []
    problems: list[str] = []
    for path in sorted(tests_dir.glob(MODULE_GLOB)):
        if not path.is_file():
            continue
        if path.stem.isidentifier():
            names.append(path.stem)
        else:
            problems.append(f"{path.name}：文件名不是合法的 Python 模块名，无法作为单元运行")
    for path in sorted(tests_dir.glob(f"*/**/{MODULE_GLOB}")):
        if (path.parent / "__init__.py").is_file():
            relative = path.relative_to(tests_dir).as_posix()
            problems.append(f"{relative}：不支持嵌套测试包，测试模块须直接放在 {tests_dir.name}/ 下")
    if problems:
        raise DiscoveryError("\n".join(problems))
    return names


def _is_glob(pattern: str) -> bool:
    return any(char in _GLOB_CHARS for char in pattern)


def normalize_pattern(raw: str) -> str:
    """test_x / scripts.test_x / scripts/test_x.py -> test_x; test_x.Class stays as it is."""
    text = raw.strip().replace("\\", "/")
    while text.startswith("./"):
        text = text[2:]
    if text.endswith(".py"):
        text = text[: -len(".py")]
    for prefix in (f"{TESTS_DIR}/", f"{TESTS_DIR}."):
        if text.startswith(prefix):
            text = text[len(prefix):]
            break
    return text


def modules_to_import(patterns: Sequence[tuple[str, str]], modules: Sequence[str]) -> list[str]:
    """The modules the (raw, normalized) patterns can reach; a glob or no pattern needs all of them."""
    if not patterns or any(_is_glob(pattern) for _, pattern in patterns):
        return list(modules)
    wanted: set[str] = set()
    for raw, pattern in patterns:
        module = pattern.partition(".")[0]
        if module not in modules:
            raise DiscoveryError(f"PATTERN {raw!r} 没有对应的测试模块 {TESTS_DIR}/{module}.py")
        wanted.add(module)
    return [module for module in modules if module in wanted]


def _inside(path: Path, directory: Path) -> bool:
    try:
        path.resolve().relative_to(directory.resolve())
    except (OSError, ValueError):
        return False
    return True


@contextlib.contextmanager
def _imports_from(tests_dir: Path) -> Iterator[None]:
    """Import test modules with tests_dir on sys.path, then forget the modules loaded from it.

    Forgetting them lets a later call with another root (the runner's own tests) import its
    own files under the same module names.
    """
    saved_path = list(sys.path)
    saved_modules = set(sys.modules)
    saved_bytecode_flag = sys.dont_write_bytecode
    sys.path.insert(0, str(tests_dir))
    importlib.invalidate_caches()
    try:
        yield
    finally:
        sys.path[:] = saved_path
        sys.dont_write_bytecode = saved_bytecode_flag
        for name in set(sys.modules) - saved_modules:
            origin = getattr(sys.modules.get(name), "__file__", None)
            if origin and _inside(Path(origin), tests_dir):
                sys.modules.pop(name, None)


def _module_units(loader: unittest.TestLoader, name: str, module: object) -> list[Unit]:
    """One unit per TestCase class with tests, mirroring TestLoader.loadTestsFromModule."""
    if getattr(module, "load_tests", None) is not None:
        count = loader.loadTestsFromModule(module).countTestCases()
        return [Unit(name, count, getattr(module, RUN_LAST_ATTRIBUTE, False) is True)] if count else []
    units: list[Unit] = []
    for attribute in dir(module):
        candidate = getattr(module, attribute)
        if (
            isinstance(candidate, type)
            and issubclass(candidate, unittest.TestCase)
            and candidate not in (unittest.TestCase, unittest.FunctionTestCase)
        ):
            count = loader.loadTestsFromTestCase(candidate).countTestCases()
            if count:
                last = getattr(candidate, RUN_LAST_ATTRIBUTE, False) is True
                units.append(Unit(f"{name}.{attribute}", count, last))
    return units


def load_units(tests_dir: Path, modules: Sequence[str]) -> list[Unit]:
    """Import every module and enumerate its units; any import or load failure is an error."""
    loader = unittest.TestLoader()
    units: list[Unit] = []
    problems: list[str] = []
    with _imports_from(tests_dir):
        for name in modules:
            known_errors = len(loader.errors)
            try:
                module = importlib.import_module(name)
                found = _module_units(loader, name, module)
            except KeyboardInterrupt:
                raise
            except BaseException:  # noqa: BLE001 - SystemExit while importing is a broken module too
                problems.append(f"{name}：导入或加载失败\n{traceback.format_exc().rstrip()}")
                continue
            if len(loader.errors) > known_errors:
                problems.extend(f"{name}：加载失败\n{error.rstrip()}" for error in loader.errors[known_errors:])
                continue
            units.extend(found)
    if problems:
        raise DiscoveryError("\n".join(problems))
    return units


def select_units(units: Sequence[Unit], patterns: Sequence[tuple[str, str]]) -> list[Unit]:
    if not patterns:
        return list(units)
    chosen: set[str] = set()
    unmatched: list[str] = []
    for raw, pattern in patterns:
        if _is_glob(pattern):
            hits = {
                unit.id
                for unit in units
                if fnmatch.fnmatchcase(unit.id, pattern) or fnmatch.fnmatchcase(unit.module, pattern)
            }
        else:
            hits = {unit.id for unit in units if pattern in (unit.id, unit.module)}
        if not hits:
            unmatched.append(raw)
        chosen |= hits
    if unmatched:
        raise DiscoveryError(
            "PATTERN 没有命中任何单元："
            + "、".join(repr(raw) for raw in unmatched)
            + "（单元是 TestCase 类；用 --list 查看全部单元）"
        )
    return [unit for unit in units if unit.id in chosen]


# ---- timing cache ----


def load_timings(path: Path) -> dict[str, float]:
    """Recorded wall seconds per unit id; a missing, unreadable or foreign cache counts as empty."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return {}
    if not isinstance(data, dict) or data.get("version") != TIMINGS_VERSION:
        return {}
    units = data.get("units")
    if not isinstance(units, dict):
        return {}
    return {
        key: float(value)
        for key, value in units.items()
        if isinstance(key, str)
        and isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value >= 0
    }


def merge_timings(
    previous: dict[str, float],
    results: Sequence[UnitResult],
    *,
    units: Sequence[Unit],
    modules: Sequence[str],
    imported: Sequence[str],
) -> dict[str, float]:
    """This run's times over the cache; entries of deleted modules or vanished units are dropped."""
    current = {unit.id for unit in units}
    existing, loaded = set(modules), set(imported)
    merged = {
        key: value
        for key, value in previous.items()
        if key in current or (key.partition(".")[0] in existing and key.partition(".")[0] not in loaded)
    }
    merged.update((result.unit.id, result.seconds) for result in results)
    return merged


def save_timings(path: Path, timings: dict[str, float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"version": TIMINGS_VERSION, "units": {key: round(timings[key], 3) for key in sorted(timings)}}
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    try:
        with open(temporary, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            temporary.unlink()
        raise


def schedule(units: Sequence[Unit], timings: dict[str, float]) -> list[Unit]:
    """Slowest recorded unit first, units without a record before all of them, RUN_LAST units at the end."""
    return sorted(units, key=lambda unit: (unit.last, -timings.get(unit.id, math.inf)))


# ---- running ----


@dataclass
class _Running:
    unit: Unit
    process: subprocess.Popen
    stdout: IO[bytes]
    stderr: IO[bytes]
    started: float


def unit_command(unit: Unit) -> list[str]:
    return [sys.executable, "-m", "unittest", "-q", f"{TESTS_DIR}.{unit.id}"]


def default_jobs() -> int:
    return max(1, min(os.cpu_count() or 1, DEFAULT_MAX_JOBS))


def _start(unit: Unit, root: Path, environment: dict[str, str]) -> _Running:
    stdout = tempfile.TemporaryFile()
    stderr = tempfile.TemporaryFile()
    # A session of its own lets a timeout kill the whole POSIX process group.
    options = {} if os.name == "nt" else {"start_new_session": True}
    try:
        process = subprocess.Popen(
            unit_command(unit),
            cwd=root,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            **options,
        )
    except BaseException:
        stdout.close()
        stderr.close()
        raise
    return _Running(unit, process, stdout, stderr, time.monotonic())


def _kill_tree(process: subprocess.Popen) -> None:
    """Kill a unit together with the bash/PowerShell/Python processes its tests started."""
    if process.poll() is None:
        if os.name == "nt":
            taskkill = shutil.which("taskkill") or str(
                Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "taskkill.exe"
            )
            with contextlib.suppress(OSError, subprocess.SubprocessError):
                subprocess.run(
                    [taskkill, "/F", "/T", "/PID", str(process.pid)],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=KILL_WAIT_SECONDS,
                    check=False,
                )
        else:
            with contextlib.suppress(OSError):
                os.killpg(process.pid, signal.SIGKILL)
    with contextlib.suppress(OSError):
        process.kill()
    with contextlib.suppress(subprocess.TimeoutExpired):
        process.wait(timeout=KILL_WAIT_SECONDS)


def _decode(data: bytes) -> str:
    """Child output is UTF-8 or, without UTF-8 mode on Windows, the ANSI code page."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode(locale.getpreferredencoding(False), errors="replace")
    return text.replace("\r\n", "\n")


def _read(stream: IO[bytes]) -> str:
    stream.seek(0)
    return _decode(stream.read())


def _problem(unit: Unit, returncode: int | None, summary: Summary | None, timed_out: bool, timeout: float) -> str | None:
    if timed_out:
        return f"超过 --timeout {timeout:g}s 仍未结束，已终止其进程树"
    if summary is None:
        return f"输出中没有 unittest 汇总，子进程异常退出（退出码 {returncode}）"
    if summary.status == "FAILED":
        return None if returncode == 1 else f"unittest 报告 FAILED，但退出码是 {returncode}"
    if summary.counts.tests != unit.tests:
        return f"发现阶段有 {unit.tests} 个测试，子进程运行了 {summary.counts.tests} 个"
    if returncode != 0:
        return f"unittest 报告 {summary.status}，但退出码是 {returncode}"
    return None


def _finish(item: _Running, timed_out: bool, timeout: float) -> UnitResult:
    seconds = time.monotonic() - item.started
    try:
        stdout, stderr = _read(item.stdout), _read(item.stderr)
    finally:
        item.stdout.close()
        item.stderr.close()
    returncode = item.process.returncode
    summary = parse_summary(stderr)
    output = "\n".join(part.rstrip("\n") for part in (stdout, stderr) if part.strip())
    problem = _problem(item.unit, returncode, summary, timed_out, timeout)
    return UnitResult(item.unit, seconds, returncode, output, summary, problem, timed_out)


def run_units(
    units: Sequence[Unit],
    *,
    root: Path,
    environment: dict[str, str],
    jobs: int,
    timeout: float,
    on_result: Callable[[UnitResult], None] = lambda result: None,
) -> list[UnitResult]:
    """Run up to `jobs` units at once, in the given order; output goes to temporary files."""
    pending = list(units)
    running: list[_Running] = []
    results: list[UnitResult] = []
    try:
        while pending or running:
            while pending and len(running) < jobs:
                unit = pending.pop(0)
                try:
                    running.append(_start(unit, root, environment))
                except OSError as exc:
                    result = UnitResult(unit, 0.0, None, "", None, f"无法启动子进程：{exc}")
                    results.append(result)
                    on_result(result)
            finished = False
            for item in list(running):
                timed_out = item.process.poll() is None and time.monotonic() - item.started > timeout
                if timed_out:
                    _kill_tree(item.process)
                elif item.process.returncode is None:
                    continue
                running.remove(item)
                result = _finish(item, timed_out, timeout)
                results.append(result)
                on_result(result)
                finished = True
            if not finished:
                time.sleep(POLL_SECONDS)
    except BaseException:
        for item in running:
            _kill_tree(item.process)
            item.stdout.close()
            item.stderr.close()
        raise
    return results


# ---- reporting ----


def _plural(count: int, word: str) -> str:
    return f"{count} {word}{'' if count == 1 else 's'}"


def progress_line(result: UnitResult, done: int, total: int) -> str:
    parts = [_plural(result.unit.tests, "test")]
    if result.summary is not None and result.summary.counts.details():
        parts.append(result.summary.counts.details())
    if result.problem is not None:
        parts.append(result.problem)
    width = len(str(total))
    return f"[{done:0{width}d}/{total}] {result.label:<7} {result.seconds:7.2f}s  {result.unit.id} ({'; '.join(parts)})"


def report(results: Sequence[UnitResult], *, wall: float, jobs: int, out: IO[str]) -> int:
    failed = [result for result in results if not result.passed]
    for result in failed:
        print("=" * 70, file=out)
        print(f"{result.label}: {result.unit.id}", file=out)
        print(f"复现：python -m unittest {TESTS_DIR}.{result.unit.id}", file=out)
        if result.problem is not None:
            print(f"问题：{result.problem}", file=out)
        print("-" * 70, file=out)
        print(result.output or "（没有输出）", file=out)
    if failed:
        print("=" * 70, file=out)
    slowest = sorted(results, key=lambda result: result.seconds, reverse=True)[:SLOWEST_SHOWN]
    print(f"最慢的 {len(slowest)} 个单元：", file=out)
    for result in slowest:
        print(f"  {result.seconds:7.2f}s  {result.unit.id}", file=out)
    total = Counts()
    for result in results:
        total += result.counts
    unit_seconds = sum(result.seconds for result in results)
    print(
        f"Ran {_plural(total.tests, 'test')} in {_plural(len(results), 'unit')}; "
        f"wall {wall:.2f}s (jobs={jobs}, unit total {unit_seconds:.2f}s)",
        file=out,
    )
    details = total.details()
    if failed:
        details = ", ".join(filter(None, (details, f"failed units={len(failed)}")))
    print(("FAILED" if failed else "OK") + (f" ({details})" if details else ""), file=out, flush=True)
    return EXIT_FAILED if failed else EXIT_OK


def _print_list(units: Sequence[Unit], timings: dict[str, float], out: IO[str]) -> None:
    for unit in units:
        recorded = timings.get(unit.id)
        when = f"{recorded:7.2f}s" if recorded is not None else f"{'-':>8}"
        last = f", {RUN_LAST_ATTRIBUTE}" if unit.last else ""
        print(f"{when}  {unit.id} ({_plural(unit.tests, 'test')}{last})", file=out)
    modules = len({unit.module for unit in units})
    tests = sum(unit.tests for unit in units)
    print(f"{_plural(len(units), 'unit')}, {_plural(tests, 'test')}, {_plural(modules, 'module')}", file=out)


# ---- CLI ----


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="run_unittests.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("patterns", nargs="*", metavar="PATTERN", help="只运行匹配的单元（规则见上文）；默认全部")
    parser.add_argument(
        "-j",
        "--jobs",
        type=int,
        default=None,
        metavar="N",
        help=f"同时运行的单元数（默认 CPU 逻辑核数与 {DEFAULT_MAX_JOBS} 的较小值）",
    )
    parser.add_argument("--list", action="store_true", help="按调度顺序列出单元与记录的耗时，不运行")
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        metavar="SECONDS",
        help=f"单个单元的时限，超时即终止其进程树并记为失败（默认 {DEFAULT_TIMEOUT_SECONDS:g}）",
    )
    parser.add_argument("--root", type=Path, default=None, help="仓库根（默认：本脚本所在仓库）")
    return parser


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            with contextlib.suppress(OSError, ValueError):
                reconfigure(encoding="utf-8", errors="replace", newline="\n")


def _interrupt_on_termination() -> list[signal.Signals]:
    """Let SIGTERM and SIGHUP raise KeyboardInterrupt, so they end a run the way Ctrl+C does.

    Like Python's own SIGINT setup, only a default disposition is replaced: a signal the parent
    ignores (nohup) stays ignored. Returns the signals to reset to SIG_DFL afterwards.
    """
    installed: list[signal.Signals] = []
    for name in ("SIGTERM", "SIGHUP"):
        signum = getattr(signal, name, None)
        if signum is not None and signal.getsignal(signum) == signal.SIG_DFL:
            signal.signal(signum, signal.default_int_handler)
            installed.append(signum)
    return installed


def main(argv: Sequence[str] | None = None) -> int:
    started = time.monotonic()
    parser = _parser()
    args = parser.parse_intermixed_args(argv)
    if args.jobs is not None and args.jobs < 1:
        parser.error("--jobs 必须是正整数")
    if not (math.isfinite(args.timeout) and args.timeout > 0):
        parser.error("--timeout 必须是正数")
    root = (args.root if args.root is not None else REPO_ROOT).resolve()
    tests_dir = root / TESTS_DIR
    # Children get the environment as it was before any test module ran its import-time code.
    environment = dict(os.environ)
    patterns = [(raw, normalize_pattern(raw)) for raw in args.patterns]
    try:
        modules = discover_modules(tests_dir)
        imported = modules_to_import(patterns, modules)
        known = load_units(tests_dir, imported)
        units = select_units(known, patterns)
        if not units:
            raise DiscoveryError(f"{tests_dir} 下没有发现任何测试（{MODULE_GLOB}）")
    except DiscoveryError as exc:
        for line in str(exc).splitlines():
            print(f"run_unittests: {line}", file=sys.stderr)
        return EXIT_USAGE

    timings_path = root / TIMINGS_FILE
    previous = load_timings(timings_path)
    ordered = schedule(units, previous)
    if args.list:
        _print_list(ordered, previous, sys.stdout)
        return EXIT_OK

    jobs = args.jobs or default_jobs()
    total_tests = sum(unit.tests for unit in ordered)
    modules_run = len({unit.module for unit in ordered})
    print(
        f"run_unittests: {_plural(len(ordered), 'unit')}, {_plural(total_tests, 'test')}, "
        f"{_plural(modules_run, 'module')}; jobs={jobs}",
        flush=True,
    )
    done = 0

    def on_result(result: UnitResult) -> None:
        nonlocal done
        done += 1
        print(progress_line(result, done, len(ordered)), flush=True)

    installed = _interrupt_on_termination()
    try:
        results = run_units(
            ordered, root=root, environment=environment, jobs=jobs, timeout=args.timeout, on_result=on_result
        )
    except KeyboardInterrupt:
        print("run_unittests: 已中断，运行中的单元已终止", file=sys.stderr)
        return EXIT_INTERRUPTED
    finally:
        for signum in installed:
            signal.signal(signum, signal.SIG_DFL)
    wall = time.monotonic() - started
    try:
        save_timings(
            timings_path, merge_timings(previous, results, units=known, modules=modules, imported=imported)
        )
    except OSError as exc:
        print(f"run_unittests: 无法写入耗时缓存 {timings_path}：{exc}", file=sys.stderr)
    return report(results, wall=wall, jobs=jobs, out=sys.stdout)


if __name__ == "__main__":
    _configure_stdio()
    raise SystemExit(main())
