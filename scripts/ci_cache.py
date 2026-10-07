#!/usr/bin/env python3
"""Report allowlisted CI cache metadata or repeat a suite's build without running tests."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Sequence

try:
    import zig_test
    import zigw
except ImportError:
    from scripts import zig_test, zigw

ROOT = Path(__file__).resolve().parents[1]
ZIG_ENV_FIELDS = ("zig_exe", "lib_dir", "version", "global_cache_dir")
SCAN_TIMEOUT = 60.0
PROBE_TIMEOUT = 900


def cpu_info() -> dict:
    result = {"arch": platform.machine(), "logical_cpus": os.cpu_count(), "model": "unknown"}
    if sys.platform == "linux":
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            name, _, value = line.partition(":")
            if name.strip() == "model name":
                result["model"] = value.strip()
                break
    elif sys.platform == "win32":
        import winreg

        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0") as key:
            result["model"] = winreg.QueryValueEx(key, "ProcessorNameString")[0].strip()
    return result


def parse_zig_env(text: str) -> dict[str, str]:
    fields = {}
    for name in ZIG_ENV_FIELDS:
        match = re.search(rf'^    \.{name}\s*=\s*("(?:[^"\\]|\\.)*"),?\s*$', text, re.MULTILINE)
        if match is None:
            raise ValueError(f"zig env is missing {name}")
        value = json.loads(match[1])
        if not isinstance(value, str):
            raise ValueError(f"zig env has an invalid {name}")
        fields[name] = value
    return fields


def absolute_path(root: Path, value: str) -> Path:
    return (root / value).resolve()


def zig_info(root: Path) -> dict[str, str]:
    env = zigw.child_env(root=root)
    zig = zigw.require_zig(env, root)
    completed = subprocess.run(
        [zig.path, "env"], cwd=root, env=env, capture_output=True,
        text=True, encoding="utf-8", timeout=15, check=True,
    )
    fields = parse_zig_env(completed.stdout)
    return {
        "exe": str(absolute_path(root, fields["zig_exe"])),
        "lib": str(absolute_path(root, fields["lib_dir"])),
        "version": fields["version"],
        "global_cache": str(absolute_path(root, fields["global_cache_dir"])),
        "local_cache": str(absolute_path(root, env.get("ZIG_LOCAL_CACHE_DIR", "").strip() or ".zig-cache")),
    }


def is_link(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def cache_sizes(path: Path, deadline: float) -> dict:
    result = {"path": str(path), "exists": path.exists(), "bytes": 0, "top_level_bytes": {},
              "skipped_links": 0, "errors": 0, "complete": True}
    pending = [(path, None)] if result["exists"] else []
    while pending:
        if time.monotonic() >= deadline:
            result["complete"] = False
            break
        directory, group = pending.pop()
        try:
            if is_link(directory.lstat()):
                result["skipped_links"] += 1
                continue
            with os.scandir(directory) as entries:
                for entry in entries:
                    if time.monotonic() >= deadline:
                        result["complete"] = False
                        return result
                    bucket = entry.name if group is None else group
                    try:
                        info = entry.stat(follow_symlinks=False)
                        if is_link(info):
                            result["skipped_links"] += 1
                        elif stat.S_ISDIR(info.st_mode):
                            result["top_level_bytes"].setdefault(bucket, 0)
                            pending.append((Path(entry.path), bucket))
                        elif stat.S_ISREG(info.st_mode):
                            result["bytes"] += info.st_size
                            result["top_level_bytes"][bucket] = result["top_level_bytes"].get(bucket, 0) + info.st_size
                    except OSError:
                        result["errors"] += 1
        except OSError:
            result["errors"] += 1
    result["complete"] = result["complete"] and result["errors"] == 0
    return result


def timing_counts(root: Path, suite: str) -> dict:
    result = {}
    for label, _ in zig_test.SUITES[suite].binaries:
        path = zig_test.timings_path(root, label)
        entry = {"path": str(path), "entries": 0, "status": "missing"}
        try:
            info = path.lstat()
            if is_link(info) or not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
                raise ValueError("invalid timings file")
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ValueError("invalid timings object")
            entry["entries"] = sum(isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0
                                   for value in data.values())
            entry["status"] = "ok"
        except FileNotFoundError:
            pass
        except (OSError, ValueError):
            entry["status"] = "invalid"
        result[label] = entry
    return result


def snapshot(root: Path, suite: str, phase: str) -> dict:
    started = time.monotonic()
    zig = zig_info(root)
    deadline = time.monotonic() + SCAN_TIMEOUT
    paths = dict.fromkeys((zig["global_cache"], zig["local_cache"]))
    caches = [cache_sizes(Path(path), deadline) for path in paths]
    timings = timing_counts(root, suite)
    complete = all(cache["complete"] for cache in caches) and all(item["status"] != "invalid" for item in timings.values())
    return {"schema": 1, "kind": "snapshot", "phase": phase, "suite": suite,
            "cpu": cpu_info(), "zig": zig, "caches": caches, "timings": timings,
            "seconds": round(time.monotonic() - started, 3), "exit_code": 0 if complete else 1}


def stop_build(process: subprocess.Popen) -> list[dict]:
    errors = []
    if os.name == "nt":
        executable = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "taskkill.exe")
        try:
            result = subprocess.run(
                [executable, "/PID", str(process.pid), "/T", "/F"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=10, check=False,
            )
            if result.returncode:
                errors.append({"stage": "taskkill", "exit_code": result.returncode})
        except (OSError, subprocess.SubprocessError) as exc:
            errors.append({"stage": "taskkill", "error_type": type(exc).__name__})
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            errors.append({"stage": "killpg", "error_type": type(exc).__name__})
    try:
        if process.poll() is None:
            process.kill()
    except OSError as exc:
        errors.append({"stage": "kill_parent", "error_type": type(exc).__name__})
    try:
        process.wait(timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        errors.append({"stage": "wait_parent", "error_type": type(exc).__name__})
    return errors


def probe(root: Path, suite: str, defines: Sequence[str], timeout: int) -> dict:
    command = zig_test.build_command(root, suite, defines, ["--summary", "all"])
    print("[ci_cache] rebuild: " + json.dumps(command), flush=True)
    started = time.monotonic()
    options = {"start_new_session": True} if os.name != "nt" else {}
    process = subprocess.Popen(command, cwd=root, **options)
    timed_out = interrupted = False
    cleanup_error = []
    try:
        code = zigw._exit_status(process.wait(timeout=timeout))
    except subprocess.TimeoutExpired:
        timed_out, code = True, 124
        cleanup_error = stop_build(process)
    except KeyboardInterrupt:
        interrupted, code = True, 130
        cleanup_error = stop_build(process)
    return {"schema": 1, "kind": "probe", "suite": suite, "command": command,
            "seconds": round(time.monotonic() - started, 3), "timeout_seconds": timeout,
            "timed_out": timed_out, "interrupted": interrupted, "cleanup_error": cleanup_error or None,
            "exit_code": code}


def bounded_timeout(value: str) -> int:
    seconds = int(value)
    if not 1 <= seconds <= 1800:
        raise argparse.ArgumentTypeError("timeout must be between 1 and 1800 seconds")
    return seconds


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("snapshot", "probe"):
        sub = subparsers.add_parser(name)
        sub.add_argument("--suite", choices=sorted(zig_test.SUITES), required=True)
        sub.add_argument("--json", type=Path)
        sub.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
        if name == "snapshot":
            sub.add_argument("--phase", choices=("restored", "finished"), required=True)
        else:
            sub.add_argument("-D", dest="defines", action="append", default=[])
            sub.add_argument("--timeout", type=bounded_timeout, default=PROBE_TIMEOUT)
    args = parser.parse_args(argv)
    try:
        if args.command == "snapshot":
            report = snapshot(args.root.resolve(), args.suite, args.phase)
        else:
            report = probe(args.root.resolve(), args.suite, args.defines, args.timeout)
    except (OSError, ValueError, subprocess.SubprocessError, zigw.ZigwError, zig_test.FatalError) as exc:
        report = {"schema": 1, "kind": args.command, "suite": args.suite,
                  "error_type": type(exc).__name__, "exit_code": 2}
    print("[ci_cache] " + json.dumps(report, ensure_ascii=True, sort_keys=True), flush=True)
    try:
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(report, ensure_ascii=True, indent=2) + "\n", encoding="utf-8", newline="\n")
    except OSError as exc:
        print(f"[ci_cache] report write failed: {type(exc).__name__}", file=sys.stderr)
        return report["exit_code"] or 2
    return report["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())
