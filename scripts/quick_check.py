#!/usr/bin/env python3
"""固定 Windows 快速门：prepare 编译并签收；check 在 60 秒内给出当前结果。

只用标准库；不代替完整测试、CI、GUI 或其他平台验收。构建不计入 check 的
55 秒执行预算，剩余 5 秒用于清理和报告。签收绑定 Git 可见的实际文件内容，
而非提交号或 mtime；源码、工具链、参数或产物变化后必须重新 prepare。
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import platform
import re
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

import zig_test
import zigw

ROOT = Path(__file__).resolve().parents[1]
STATE = Path(".local/quick-check")
SCHEMA = 1
PROFILE = "windows-v1"
EXECUTION_SECONDS = 55.0
TOTAL_SECONDS = 60.0
FRAMEWORK = (
    "test_zig_test", "test_run_unittests", "test_resolve_agent_rules",
    "test_fork_patches", "test_gx_workflows", "test_gx_test_roots",
    "test_setup_zig", "test_zigw", "test_quick_check",
)
FILTERS = {
    "ghostty-test": ("apprt.win32", "gx.", "font.directwrite", "renderer.opengl.wgl", "Command:", "lib.tinyio"),
    "vt": ("terminal.Parser.",),
    "vt_c": ("terminal.Parser.", "terminal.c."),
}
UNCOVERED = [
    "完整 main / vt / vt_c 单测", "固定筛选以外的框架测试",
    "Linux / GTK / POSIX / macOS", "GUI 截图与交互", "WASM / C ABI 示例 / 交叉构建",
    "生成物新鲜度 / 图谱 / 知识库 / 完整 CI",
]


class GateError(RuntimeError):
    pass


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    temporary.replace(path)


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise GateError(f"无效 JSON 对象：{path}")
    return value


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def source_identity(root: Path) -> dict:
    """Include tracked deletions, dirty and non-ignored untracked bytes and symlinks."""
    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root, capture_output=True, check=True, timeout=15,
    )
    value = hashlib.sha256()
    paths = sorted(set(result.stdout.split(b"\0")) - {b""})
    for raw in paths:
        path = root / os.fsdecode(raw)
        value.update(raw + b"\0")
        if path.is_symlink():
            value.update(b"link\0" + os.fsencode(os.readlink(path)) + b"\0")
            # A symlink's resolved bytes can affect compilation too.
        if path.is_file():
            value.update(b"file\0" + bytes.fromhex(digest(path)))
            value.update(str(path.stat().st_mode & 0o111).encode())
        elif not path.exists():
            value.update(b"missing")
        else:
            raise GateError(f"不支持目录形式的 Git 输入（例如 submodule）：{path}")
        value.update(b"\0")
    return {"sha256": value.hexdigest(), "files": len(paths)}


def commands(root: Path) -> list[list[str]]:
    prefix = ["--prefix", str(root / STATE / "build")]
    return [zig_test.build_command(root, suite, zig_test.suite_defines(suite, [], []), prefix) for suite in ("main", "vt")]


def toolchain_identity(root: Path) -> dict:
    zig = zigw.require_zig(root=root)
    path = Path(zig.path).resolve()
    # Hash the executable and shipped libraries: editing a stdlib file must stale the receipt.
    library = Path(os.environ.get("ZIG_LIB_DIR") or path.parent / "lib")
    if not library.is_absolute():
        library = root / library
    library = library.resolve()
    value = hashlib.sha256()
    if not library.is_dir():
        raise GateError(f"缺少 Zig 库目录：{library}")
    for item in sorted(library.rglob("*")):
        if item.is_file():
            value.update(item.relative_to(library).as_posix().encode() + b"\0")
            value.update(bytes.fromhex(digest(item)))
    return {"path": str(path), "version": zigw.setup_zig.ZIG_VERSION,
            "sha256": digest(path), "libraries_path": str(library), "libraries_sha256": value.hexdigest()}


def input_identity(root: Path) -> dict:
    return {"schema": SCHEMA, "profile": PROFILE, "root": str(root.resolve()),
            "platform": [sys.platform, platform.machine()], "source": source_identity(root),
            "toolchain": toolchain_identity(root), "commands": commands(root),
            "environment": {name: os.environ.get(name) for name in (
                "ZIG_LIB_DIR", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS",
            )}}


def binaries(root: Path) -> dict[str, Path]:
    found = {}
    for suite in ("main", "vt"):
        entries, missing = zig_test.suite_binaries(root / STATE / "build", suite)
        if missing:
            raise GateError("缺少完整测试产物：" + ", ".join(map(str, missing)))
        found.update(entries)
    return found


def artifacts(root: Path) -> dict:
    return {label: {"path": str(path.resolve()), "sha256": digest(path)} for label, path in binaries(root).items()}


def validate_receipt(root: Path, receipt: dict) -> None:
    if receipt.get("inputs") != input_identity(root):
        raise GateError("签收已过期：源码、平台、工具链或构建参数变化；运行 just quick-prepare")
    if receipt.get("artifacts") != artifacts(root):
        raise GateError("签收已过期：测试产物缺失或内容变化；运行 just quick-prepare")


def prepare(root: Path) -> int:
    receipt_path = root / STATE / "prepared.json"
    receipt_path.unlink(missing_ok=True)
    write_json(root / STATE / "report.json", base_report(uuid.uuid4().hex))
    before = input_identity(root)
    for command in commands(root):
        print("[quick] build: " + subprocess.list2cmdline(command), flush=True)
        result = subprocess.run(command, cwd=root, check=False)
        if result.returncode:
            raise GateError(f"构建失败（退出码 {result.returncode}），旧签收已撤销")
    produced = artifacts(root)
    if before != input_identity(root):
        raise GateError("构建期间输入发生变化，拒绝签收；重新运行 just quick-prepare")
    if produced != artifacts(root):
        raise GateError("签收期间产物发生变化，拒绝签收")
    write_json(receipt_path, {"inputs": before, "artifacts": produced, "prepared_at": time.time()})
    print("[quick] PREPARED 完整 main / vt / vt_c 已签收；这不是测试 PASS", flush=True)
    return 0


def base_report(run_id: str) -> dict:
    names = ["freshness-before", "rules", "version", "fmt", "diff", "framework", *FILTERS, "freshness-after"]
    return {"schema": SCHEMA, "run_id": run_id, "profile": PROFILE, "status": "PENDING",
            "budget_seconds": TOTAL_SECONDS, "execution_seconds": EXECUTION_SECONDS,
            "groups": [{"name": name, "status": "PENDING", "seconds": 0.0} for name in names],
            "uncovered": UNCOVERED}


def verdict(report: dict) -> str:
    statuses = [row["status"] for row in report["groups"]]
    return "FAIL" if "FAIL" in statuses else ("PASS" if all(s == "PASS" for s in statuses) else "PENDING")


def check_commands(root: Path, directory: Path) -> dict[str, list[str]]:
    py = sys.executable
    scripts = root / "scripts"
    result = {
        "rules": [py, str(scripts / "resolve_agent_rules.py"), "--check"],
        "version": [py, str(scripts / "version.py"), "--check"],
        "fmt": [py, str(scripts / "zigw.py"), "fmt", "--check", "--exclude", ".local", "--exclude", "zig-pkg", "--exclude", "zig-out", "--exclude", ".zig-cache", "."],
        "diff": ["git", "diff", "--check", "HEAD"],
        "framework": [py, str(scripts / "run_unittests.py"), "--jobs", "4", *FRAMEWORK],
    }
    for label, path in binaries(root).items():
        result[label] = [py, str(scripts / "zig_test.py"), "--root", str(root), "--binary", str(path),
                         "--jobs", "8", "--seed", "0", "--json", str(directory / (label + ".json"))]
        for pattern in FILTERS[label]:
            result[label] += ["--filter", pattern]
    return result


def inspect_zig(label: str, payload: dict) -> dict:
    if payload.get("dedupe") is not False or payload.get("build") is not None:
        raise GateError("运行器执行模式不符合固定 profile")
    tests = payload.get("tests", [])
    if not isinstance(tests, list) or any(
        not isinstance(test, dict) or not isinstance(test.get("name"), str)
        or test.get("outcome") not in {"pass", "skip", *zig_test.FAILED_OUTCOMES}
        for test in tests
    ):
        raise GateError("运行器用例报告不完整或结果未知")
    groups = []
    for pattern in FILTERS[label]:
        hits = [test for test in tests if pattern in test["name"]]
        if not hits:
            raise GateError(f"必需组零命中：{label} / {pattern}")
        groups.append({"filter": pattern, "selected": len(hits),
                       "passed": sum(test["outcome"] == "pass" for test in hits),
                       "skipped": sum(test["outcome"] == "skip" for test in hits),
                       "failed": sum(test["outcome"] in zig_test.FAILED_OUTCOMES for test in hits)})
    failed = not payload.get("ok") or payload.get("exit_code") != 0 or any(t["outcome"] in zig_test.FAILED_OUTCOMES for t in tests)
    result = {"selected": len(tests), "passed": sum(t["outcome"] == "pass" for t in tests),
              "skipped": sum(t["outcome"] == "skip" for t in tests), "filters": groups,
              "status": "FAIL" if failed else "PASS", "failures": payload.get("failures", [])}
    if failed:
        result["error"] = "Zig 用例失败；详情见本轮运行器 JSON 和日志"
    return result


def worker(root: Path, directory: Path, run_id: str) -> int:
    # The supervisor attaches containment before releasing this start barrier.
    while not (directory / "start").exists():
        time.sleep(0.01)
    report = base_report(run_id)
    rows = {row["name"]: row for row in report["groups"]}
    checkpoint = directory / "progress.json"
    write_json(checkpoint, report)
    try:
        start = time.monotonic()
        receipt = read_json(root / STATE / "prepared.json")
        validate_receipt(root, receipt)
        rows["freshness-before"].update(status="PASS", seconds=time.monotonic() - start)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        rows["freshness-before"].update(status="FAIL", error=str(exc))
        write_json(checkpoint, report)
        return 1
    running = {}
    try:
        for name, command in check_commands(root, directory).items():
            log = directory / (name + ".log")
            with log.open("wb") as stream:
                process = subprocess.Popen(command, cwd=root, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
            running[name] = (process, time.monotonic())
            rows[name].update(command=command, log=str(log))
        write_json(checkpoint, report)
        while running:
            for name, (process, began) in list(running.items()):
                code = process.poll()
                if code is None:
                    continue
                row = rows[name]
                row.update(status="PASS" if code == 0 else "FAIL", exit_code=code, seconds=time.monotonic() - began)
                try:
                    if name in FILTERS:
                        row.update(inspect_zig(name, read_json(directory / (name + ".json"))))
                        if code:
                            row["status"] = "FAIL"
                    elif name == "framework":
                        output = Path(row["log"]).read_text(encoding="utf-8", errors="replace")
                        counts = re.findall(r"Ran (\d+) tests?", output)
                        row["selected"] = int(counts[-1]) if counts else 0
                        if not row["selected"]:
                            raise GateError("框架测试零命中或缺少计数")
                except (OSError, ValueError, KeyError, RuntimeError) as exc:
                    row.update(status="FAIL", error=str(exc))
                del running[name]
                write_json(checkpoint, report)
            time.sleep(0.01)
        began = time.monotonic()
        try:
            validate_receipt(root, receipt)
            if read_json(root / STATE / "prepared.json") != receipt:
                raise GateError("运行期间签收被替换")
            rows["freshness-after"].update(status="PASS", seconds=time.monotonic() - began)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
            rows["freshness-after"].update(status="FAIL", error=str(exc), seconds=time.monotonic() - began)
    except (OSError, ValueError, RuntimeError) as exc:
        report["error"] = str(exc)
    report["status"] = verdict(report)
    write_json(checkpoint, report)
    return 0 if report["status"] == "PASS" else 1


class ProcessTree:
    """Windows job contains even descendants that create new process groups.

    On Linux a child subreaper keeps orphan descendants attached to this dedicated
    supervisor. No process outside this invocation is selected for cleanup.
    """

    def __init__(self) -> None:
        self.job = None
        self.existing_children = set()
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes as w

            class Basic(ctypes.Structure):
                _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64), ("flags", w.DWORD),
                            ("min_ws", ctypes.c_size_t), ("max_ws", ctypes.c_size_t), ("active", w.DWORD),
                            ("affinity", ctypes.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]

            class Extended(ctypes.Structure):
                _fields_ = [("basic", Basic), ("io", ctypes.c_uint64 * 6),
                            ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                            ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]

            self.api = ctypes.WinDLL("kernel32", use_last_error=True)
            self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
            self.api.CreateJobObjectW.restype = w.HANDLE
            self.api.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
            self.api.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
            self.api.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
            self.api.QueryInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.c_void_p]
            self.api.CloseHandle.argtypes = [w.HANDLE]
            self.job = self.api.CreateJobObjectW(None, None)
            if not self.job:
                raise ctypes.WinError(ctypes.get_last_error())
            info = Extended()
            info.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if not self.api.SetInformationJobObject(self.job, 9, ctypes.byref(info), ctypes.sizeof(info)):
                self.api.CloseHandle(self.job)
                self.job = None
                raise ctypes.WinError(ctypes.get_last_error())
        elif sys.platform.startswith("linux"):
            import ctypes
            if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0):  # PR_SET_CHILD_SUBREAPER
                raise OSError("无法启用子进程树收养")
            self.existing_children = {pid for pid, parent in self.linux_parents().items() if parent == os.getpid()}
        else:
            raise GateError("进程树监督当前支持 Windows 与 Linux")

    def attach(self, process: subprocess.Popen) -> None:
        if self.job is not None and not self.api.AssignProcessToJobObject(self.job, int(process._handle)):
            import ctypes
            raise ctypes.WinError(ctypes.get_last_error())

    @staticmethod
    def linux_parents() -> dict[int, int]:
        parents = {}
        for item in Path("/proc").iterdir():
            if item.name.isdigit():
                with contextlib.suppress(OSError, ValueError, IndexError):
                    fields = (item / "stat").read_text().rsplit(")", 1)[1].split()
                    parents[int(item.name)] = int(fields[1])
        return parents

    def close(self, process: subprocess.Popen | None, timeout: float = 4.0) -> None:
        deadline = time.monotonic() + timeout
        if self.job is not None:
            import ctypes
            from ctypes import wintypes as w

            class Accounting(ctypes.Structure):
                _fields_ = [("times", ctypes.c_int64 * 4), ("faults", w.DWORD),
                            ("total", w.DWORD), ("active", w.DWORD), ("terminated", w.DWORD)]

            try:
                if not self.api.TerminateJobObject(self.job, 1):
                    raise ctypes.WinError(ctypes.get_last_error())
                while True:
                    info = Accounting()
                    if not self.api.QueryInformationJobObject(self.job, 1, ctypes.byref(info), ctypes.sizeof(info), None):
                        raise ctypes.WinError(ctypes.get_last_error())
                    if info.active == 0:
                        break
                    if time.monotonic() >= deadline:
                        raise GateError("进程树未在清理预算内退出")
                    time.sleep(0.01)
            finally:
                self.api.CloseHandle(self.job)
                self.job = None
        elif sys.platform.startswith("linux") and process is not None:
            # Tests and runners may create sessions; walk ancestry, not just one pgid.
            parents = self.linux_parents()
            owned = {process.pid} | {pid for pid, parent in parents.items() if parent == os.getpid() and pid not in self.existing_children}
            changed = True
            while changed:
                found = {pid for pid, parent in parents.items() if parent in owned}
                changed = not found <= owned
                owned |= found
            for pid in reversed(sorted(owned)):
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)
        if process is not None:
            with contextlib.suppress(OSError):
                process.kill()
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=max(0.01, deadline - time.monotonic()))


def supervise(root: Path, *, execution_seconds: float = EXECUTION_SECONDS, total_seconds: float = TOTAL_SECONDS,
              worker_command: list[str] | None = None) -> dict:
    started = time.monotonic()
    run_id = uuid.uuid4().hex
    directory = root / STATE / "runs" / run_id
    directory.mkdir(parents=True)
    report = base_report(run_id)
    report["directory"] = str(directory)
    report_path = root / STATE / "report.json"
    # Invalidate the last PASS before starting anything that might fail or hang.
    write_json(report_path, report)
    process = None
    tree = None
    try:
        tree = ProcessTree()
        command = worker_command or [sys.executable, str(Path(__file__).resolve()), "_worker", "--root", str(root), "--run-id", run_id]
        with (directory / "worker.log").open("wb") as log:
            process = subprocess.Popen(command, cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        tree.attach(process)
        (directory / "start").touch()
        process.wait(timeout=max(0.001, started + execution_seconds - time.monotonic()))
        if (directory / "progress.json").is_file():
            report = read_json(directory / "progress.json")
        if report.get("run_id") != run_id:
            raise GateError("本轮报告身份不符")
        expected = [row["name"] for row in base_report(run_id)["groups"]]
        if [row.get("name") for row in report.get("groups", [])] != expected:
            raise GateError("本轮报告缺少必需检查组")
        report["status"] = verdict(report)
        if process.returncode != 0 or report["status"] != "PASS":
            report["status"] = "FAIL"
            report.setdefault("error", f"本轮检查未全部通过（worker 退出码 {process.returncode}）")
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError, ValueError):
            report = read_json(directory / "progress.json")
        report.update(status="FAIL", timed_out=True, error="超过 55 秒执行预算；未完成项 PENDING，清理本轮进程树")
    except KeyboardInterrupt:
        report.update(status="FAIL", interrupted=True, error="用户中断；清理本轮进程树")
    except (OSError, ValueError, RuntimeError) as exc:
        report.update(status="FAIL", error=str(exc))
    finally:
        if tree is not None:
            try:
                tree.close(process, timeout=max(0.01, started + total_seconds - time.monotonic() - 0.5))
            except (OSError, RuntimeError) as exc:
                report.update(status="FAIL", error=f"进程树清理失败：{exc}")
        elif process is not None:
            process.kill()
    elapsed = time.monotonic() - started
    report.update(directory=str(directory), wall_seconds=round(elapsed, 3))
    if elapsed >= total_seconds:
        report.update(status="FAIL", error="清理超过总预算；不签署 PASS")
    write_json(directory / "report.json", report)
    write_json(report_path, report)
    return report


def print_report(report: dict) -> None:
    print(f"[quick] {report['status']} · {report['wall_seconds']:.3f}s / 60s · {report['profile']}")
    for row in report["groups"]:
        count = f" · {row['selected']} tests" if "selected" in row else ""
        print(f"  {row['status']:7} {row['name']} · {row['seconds']:.3f}s{count}" + (f" · {row['error']}" if row.get("error") else ""))
    if report.get("error"):
        print("[quick] " + report["error"])
    print("[quick] 未覆盖：" + "；".join(report["uncovered"]))
    print("[quick] 本轮证据：" + report["directory"])


def main(argv: list[str] | None = None) -> int:
    zig_test._utf8_stdio()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "check", "_worker"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--run-id")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if args.action == "_worker":
        if not args.run_id or not re.fullmatch(r"[0-9a-f]{32}", args.run_id):
            parser.error("无效 run-id")
        return worker(root, root / STATE / "runs" / args.run_id, args.run_id)
    try:
        if os.name != "nt":
            raise GateError("固定 windows-v1 profile 只在 Windows 执行；其他平台请用完整测试入口")
        lock = root / STATE / "active.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        try:
            descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            raise GateError("另一个 quick 命令运行中；异常退出后先确认进程已结束再删除 .local/quick-check/active.lock") from None
        os.close(descriptor)
        try:
            if args.action == "prepare":
                return prepare(root)
            report = supervise(root)
            print_report(report)
            return 0 if report["status"] == "PASS" else 1
        finally:
            lock.unlink(missing_ok=True)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, zig_test.FatalError) as exc:
        print(f"[quick] FAIL {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
