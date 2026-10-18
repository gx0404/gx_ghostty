#!/usr/bin/env python3
"""Ghostty GX timing data: collect samples, summarize them and compare two builds run in alternation.

Usage: python scripts/gx_perf.py COMMAND [ARGS...]      (just perf COMMAND [ARGS...])

  summarize PATH... [--json FILE]
        Read every sample in the files (directories are searched recursively for *.log, *.txt
        and run.json) and print n, median, p90, min and max per metric.
  compare --old PATH... --new PATH... [--json FILE]
        The same for two sample sets side by side, with the change of the median.
  win32 --exe PATH [--exe PATH] [--label NAME]... --out DIR [--runs N] [--resizes N] [--config FILE]
        [--env NAME=VALUE]...
        Measure Windows builds: per run start ghostty.exe in an isolated profile (one per
        build, reused so every run but the discarded warm-up is a warm start), time the
        window, a new tab, a split and SetWindowPos resizes, then close it. With two --exe the
        builds alternate (A B A B ...) so drift hits both alike. Each run writes
        DIR/<label>/run-NN.txt and a copy of its log; the summary or comparison follows.
        --env sets variables for every run, e.g. GHOSTTY_GX_PERF=1.
  gtk --clone PATH [--clone PATH] [--label NAME]... --out DIR [--runs N] [--env NAME=VALUE]...
        Verified ReleaseFast GTK images through `scripts/gx_wsl.py smoke --perf` in WSL clones.
        New/empty DIR only; no automatic warm-up; AB/BA order. DIR/<label>/run-NN/ holds raw evidence,
        gtk-runs.json preserves every planned run, RESULT.json records validity (not a performance verdict).
        Missing/failed/changed-identity runs cannot be filtered into success.
        --case p2|p4 selects the isolated idle/UI driver (default: standard, unchanged C1 load).
        P2/P4 require 10 runs; --capabilities LABEL:JSON_FILE binds instrumentation to source/exe.
        Their separate action schema retains unknown counters; exit 4 means a failed absolute gate.
  quiet --out DIR [--slot-root DIR] [--idle-seconds 600] [--wait --interval 900 --max-attempts 3]
        [--strict-blacklist] [--input-observe-only]
        Read-only checks under the criteria named in the JSON (r6-13:20 user ruling): this project's
        own load gates (Windows and WSL build/test processes, the validation VM, all slots probed and
        immediately released), with the console session and user input; other software (the plan §4
        blacklist, kimi-cu, CPU, Docker containers) is only recorded. --strict-blacklist makes the
        blacklist a gate again; --input-observe-only records input instead of gating it.
        Exit 0 quiet, 3 busy, 2 tool error. Every attempt is retained as JSON.
  quiet-batch --out DIR [--timeout S] [--injected-input | --input-observe-only] [--strict-blacklist]
        -- COMMAND [ARGS...]
        A reviewed external C1 task package additionally requires --frozen-collector MANIFEST
        --frozen-collector-sha256 SHA256. Exact cwd/argv/files and fresh outputs are checked again
        inside the quiet lease; the child receives verified code bytes, not reopened script paths.
        --input-observe-only allowlists direct gx_perf.py gtk / just perf gtk and gx_wsl.py /
        just wsl smoke or scenario only; wrappers, run and unknown commands are rejected before locking.
        Allowed just recipes become direct Python argv using scripts/ in the measurement cwd;
        checked argv is executed with shell=False, so trailing shell controls stay literal arguments.
        Acquire all shared slots, check immediately inside the lease, run the command, check again
        before release. End-check failure invalidates the entire batch. With --injected-input a batch
        that sent input is judged by its batch-bound gx_win_gui guard JSONL; a batch that sent none
        (with or without the flag) must have had no input at all since the start check.
        --input-observe-only is for batches that run only in WSL/Xvfb (C1, C5, P9): the start idle
        gate and the end input check are recorded, never gate; it refuses commands that drive the
        Windows desktop (gx_win_gui, gx_perf win32 drivers, test/windows fixtures, ghostty.exe), and a
        batch that still writes gx_win_gui guard rows is an ERROR.
        Exit 0 VALID, 4 FAIL (quiet valid; a gx_perf win32-* or GTK P2/P4 driver exited 4), 3 NOT_STARTED/INVALID (quiet
        criteria not met), 2 ERROR (tool/driver), 5 NONCOMPLIANT (thresholds below plan §4),
        6 PRODUCT_FAIL (a measured Ghostty instance ended or hung mid-batch, or win32-idle saw it activate
        or restore itself without input: cause instance_gone, instance_hung or instance_self_activated).
  win32-ui --exe PATH [--exe PATH] --out DIR --case p3|p4|p5|p6 [--runs 10] [--diagnostic]
  win32-idle --exe PATH --out DIR [--tabs 1 --windows 1 --state visible --seconds 60]
  win32-gpu --exe PATH --out DIR              (PDH dedicated GPU bytes, 1/11 terminals)
  win32-mem --exe PATH --out DIR              (PrivateUsage and threads, 1/11 terminals)
        All four accept --label, --config, --env, --label-env LABEL:NAME=VALUE, --runs, --json
        and --diagnostic. New output only, per-round isolated profiles, AB/BA order, no retry.
        Input uses gx_win_gui guards. Use quiet-batch for performance; desktop-only runs are diagnostic.
        run.json and ghostty.log preserve originals; samples.txt contains reduced measurements.
        RESULT.json and SUMMARY.txt describe driver evidence, never a performance verdict.
  remote PATH... [--out DIR] [--json FILE]
        Summarize remote.* fixture logs only; no remote scene or desktop actions.

Samples come from these lines:
  - `info(gx_perf): <metric> <value>us` written when GHOSTTY_GX_PERF=1 (src/gx/perf.zig);
    historical ns/ms/s time lines are also accepted;
  - `info(gx_perf): metric <name> <value>` (unitless count/gauge; sum is also reported);
  - `metric <name> <value> [s|ms|us]` from `gx_wsl.py smoke --perf` and from this tool's runs;
  - the Debug-build log line `window shown after <n>ms first_frame=<bool>` (log.window_shown);
  - the `startup_ms` block of a scripts/gx_win_gui.py run.json (startup.<mark>).
Times are reported in milliseconds; metrics without a unit are counts. p90 is the nearest-rank
90th percentile. Exit codes: 0 success, 1 a failed measurement run, 2 usage errors or no samples,
4 a complete win32-* or GTK P2/P4 batch whose new-arm absolute gate failed (truthful FAIL evidence).
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Mapping, Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = Path(__file__).resolve().parent
TAG = "[gx-perf]"

GX_PERF_RE = re.compile(
    r"\(gx_perf\):\s+(?P<name>[A-Za-z0-9_.:-]+)[\s=]+(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>ns|us|ms|s)\b")
METRIC_RE = re.compile(r"^metric\s+(?P<name>[A-Za-z0-9_.:-]+)\s+(?P<value>-?\d+(?:\.\d+)?)(?:\s+(?P<unit>s|ms|us))?\s*$")
GX_COUNT_RE = re.compile(r"\(gx_perf\):\s+metric\s+(?P<name>[A-Za-z0-9_.:-]+)\s+(?P<value>-?\d+(?:\.\d+)?)\s*$")
WINDOW_SHOWN_RE = re.compile(r"window shown after (?P<value>\d+)ms first_frame=(?P<drawn>true|false)")
SAMPLE_SUFFIXES = (".log", ".txt")
ENV_MARKER = ".gx-win-gui-env"  # scripts/gx_win_gui.py::ENV_MARKER
# The Windows file log (src/apprt/win32/file_log.zig) stamps lines `HH:MM:SS.mmm [thread] `. These
# milestones of a run are timed from its first line, in milliseconds.
LOG_STAMP_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[\d+\] ")
LOG_MILESTONES = (
    # src/renderer/opengl/wgl.zig: "<kind> OpenGL x.y" once the device probe made a context.
    ("log.opengl_probed", re.compile(r"info\(opengl\): (?!loaded )\w+ OpenGL \d")),
    ("log.config_read", re.compile(r"reading configuration file")),
    ("log.font_loaded", re.compile(r"\(font_shared_grid_set\): font regular")),
    ("log.pty_started", re.compile(r"\(io_exec\): started subcommand")),
    ("log.renderer_context", re.compile(r"info\(opengl\): loaded OpenGL \d")),
)

# Default bindings of the measured actions on Windows (src/config/Config.zig).
NEW_TAB_KEYS = "ctrl+shift+t"
SPLIT_KEYS = "ctrl+shift+o"
DEFAULT_WIN32_CONFIG = """command = cmd.exe /d /k prompt $G$S
language = en
"""


def to_ms(value: float, unit: str | None) -> float:
    """A time in milliseconds; values without a unit (counts) stay as they are."""
    if unit == "s":
        return value * 1000
    if unit == "us":
        return value / 1000
    if unit == "ns":
        return value / 1_000_000
    return value


class PerfError(RuntimeError):
    """A usage problem (exit 2), or a failed measurement step. `cause` mirrors
    gx_win_gui.InputBlocked.cause when the failure is attributable (e.g. foreign_input)."""

    def __init__(self, *args, cause: str | None = None) -> None:
        super().__init__(*args)
        self.cause = cause


@dataclass
class Samples:
    """Samples per metric; `units` says whether a metric is a time (ms) or a count."""

    values: dict[str, list[float]] = field(default_factory=dict)
    units: dict[str, str] = field(default_factory=dict)
    gtk_runs: list[dict] = field(default_factory=list)
    unverified: set[str] = field(default_factory=set)

    def add(self, name: str, value: float, unit: str | None) -> None:
        normalized = "" if unit is None else "ms"
        if name in self.units and self.units[name] != normalized:
            raise PerfError(f"metric {name}: time/count unit conflict")
        converted = to_ms(value, unit)
        if not math.isfinite(converted) or (name.startswith("cpu.") and converted < 0):
            raise PerfError(f"metric {name}: invalid or negative sample")
        self.values.setdefault(name, []).append(converted)
        self.units[name] = normalized

    def extend(self, other: "Samples") -> None:
        for name, values in other.values.items():
            for value in values:
                self.add(name, value, "ms" if other.units[name] else None)
        self.gtk_runs.extend(other.gtk_runs)
        self.unverified.update(other.unverified)

    def __bool__(self) -> bool:
        return any(self.values.values())


def clock_ms(match: re.Match) -> int:
    hours, minutes, seconds, millis = (int(match.group(index)) for index in range(1, 5))
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis


def parse_text(text: str, samples: Samples | None = None) -> Samples:
    samples = Samples() if samples is None else samples
    first: int | None = None
    seen: set[str] = set()
    for line in text.splitlines():
        stamp = LOG_STAMP_RE.match(line)
        if stamp:
            now = clock_ms(stamp)
            if first is None:
                first = now
            for name, pattern in LOG_MILESTONES:
                if name not in seen and pattern.search(line):
                    seen.add(name)
                    samples.add(name, (now - first) % (24 * 3600 * 1000), "ms")
        match = GX_PERF_RE.search(line)
        if match:
            samples.add(match.group("name"), float(match.group("value")), match.group("unit"))
            continue
        match = GX_COUNT_RE.search(line)
        if match:
            samples.add(match.group("name"), float(match.group("value")), None)
            continue
        match = METRIC_RE.match(line.strip())
        if match:
            samples.add(match.group("name"), float(match.group("value")), match.group("unit"))
            continue
        match = WINDOW_SHOWN_RE.search(line)
        if match:
            samples.add("log.window_shown", float(match.group("value")), "ms")
            samples.add("log.first_frame_drawn", 1.0 if match.group("drawn") == "true" else 0.0, None)
    return samples


def parse_run_json(data: Mapping, samples: Samples | None = None) -> Samples:
    samples = Samples() if samples is None else samples
    for mark, value in (data.get("startup_ms") or {}).items():
        samples.add("startup." + mark.removesuffix("_ms"), float(value), "ms")
    return samples


def in_profile(path: Path, root: Path) -> bool:
    """Whether path lies in an isolated profile of gx_win_gui.py, whose log the run directory holds a copy of."""
    for parent in path.parents:
        if (parent / ENV_MARKER).is_file():
            return True
        if parent == root:
            return False
    return False


GTK_REQUIRED = ("cpu.main", "cpu.renderer", "cpu.total", "window_seconds", "workload_seconds")


def sample_files(paths: Iterable[Path]) -> list[Path]:
    files: dict[str, Path] = {}
    for path in paths:
        path = path.resolve()
        if path.is_dir():
            candidates = sorted(p for p in path.rglob("*") if p.is_file() and
                                (p.suffix in SAMPLE_SUFFIXES or p.name in ("run.json", "gtk-runs.json") or
                                 p.name.endswith("-meta.json")) and not in_profile(p, path))
        elif path.is_file():
            candidates = [path] if not in_profile(path, path.parent) else []
        else:
            raise PerfError(f"{path} does not exist")
        for candidate in candidates:
            resolved = candidate.resolve()
            files.setdefault(os.path.normcase(str(resolved)), resolved)
    return list(files.values())


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("expected object")
        return data
    except (OSError, ValueError) as exc:
        raise PerfError(f"{path}: invalid evidence JSON: {exc}") from None


def gtk_evidence(path: Path) -> tuple[dict, Samples]:
    try:
        return _gtk_evidence(path)
    except (OSError, ValueError, TypeError, KeyError) as exc:
        raise PerfError(f"{path}: malformed GTK evidence: {exc}") from None


def _gtk_evidence(path: Path) -> tuple[dict, Samples]:
    meta = read_json(path)
    if meta.get("schema") != "gx-gtk-perf-v1":
        raise PerfError(f"{path}: unknown GTK evidence schema")
    if meta.get("valid") is not True or meta.get("exit") != 0 or meta.get("errors"):
        raise PerfError(f"{path}: rejected GTK run: {meta.get('errors', [])}")
    if meta.get("perf") is False:
        return meta, Samples()
    if meta.get("perf") is not True or \
            meta.get("workload_finished") is not True or meta.get("workload_exit") != "0" or \
            meta.get("build_mode") != "ReleaseFast" or meta.get("cleanup_identity") != "verified":
        raise PerfError(f"{path}: rejected GTK run: {meta.get('errors', [])}")
    for key, kind in (("identity", dict), ("identity_checks", list), ("files", list), ("artifact_sha256", dict),
                      ("version", str), ("effective_env", dict)):
        if not isinstance(meta.get(key), kind):
            raise PerfError(f"{path}: incomplete evidence field {key}")
    if not all(isinstance(item, dict) for item in meta["identity_checks"]) or not all(isinstance(name, str) for name in meta["files"]):
        raise PerfError(f"{path}: malformed manifest or identity checks")
    identity = meta["identity"]
    if not isinstance(identity.get("pid"), int) or identity["pid"] <= 0 or not identity.get("starttime") or \
            not re.fullmatch(r"[0-9a-f]{64}", identity.get("sha256", "")) or not identity.get("exe"):
        raise PerfError(f"{path}: incomplete process identity")
    checks = meta.get("identity_checks", [])
    required_stages = {"launch", "before before", "before after", "after before", "after after", "finished", "cleanup"}
    if not required_stages <= {item.get("stage") for item in checks} or any(
            any(item.get(key) != value for key, value in identity.items()) for item in checks):
        raise PerfError(f"{path}: incomplete or changed process identity checkpoints")
    if any(not re.fullmatch(r"[0-9a-f]{40}", meta.get(key, "")) for key in ("commit", "tree")) or \
            meta.get("dirty") is not False or meta.get("dirty_paths") != "":
        raise PerfError(f"{path}: incomplete or dirty source identity")
    if not re.fullmatch(r"[0-9a-f]{32}", meta.get("capture_id", "")) or type(meta.get("child_exit")) is not int or \
            meta["child_exit"] not in (0, -15) or meta.get("cleanup") != "owned pidfd SIGTERM":
        raise PerfError(f"{path}: inconsistent capture/child-exit/cleanup evidence")
    executable = meta.get("executable", {})
    if not isinstance(executable, dict) or executable.get("path") != identity["exe"] or \
            any(identity.get(key) != value for key, value in executable.items() if key != "path") or \
            not all(key in executable for key in ("sha256", "size", "inode", "device", "mtime_ns")):
        raise PerfError(f"{path}: executable and process identity conflict")
    prefix = path.name.removesuffix("-meta.json")
    allowed = {prefix + suffix for suffix in (".log", ".png", "-perf.png", "-after.png", "-version.txt", "-perf.txt",
               "-times.txt", "-tasks-before.txt", "-tasks-after.txt", "-status-before.txt", "-status-after.txt",
               "-process-before.json", "-process-after.json", "-build-receipt.json")}
    for name in meta["files"]:
        artifact = path.parent / name
        if name not in allowed or artifact.is_symlink() or not artifact.is_file() or \
                hashlib.sha256(artifact.read_bytes()).hexdigest() != meta["artifact_sha256"].get(name):
            raise PerfError(f"{path}: missing or changed artifact {name}")
    def raw(suffix: str) -> str:
        name = prefix + suffix
        if name not in meta.get("files", []) or not (path.parent / name).is_file():
            raise PerfError(f"{path}: missing artifact {name}")
        return (path.parent / name).read_text(encoding="utf-8", errors="strict")
    try:
        version = raw("-version.txt")
        if not re.search(r"build mode\s*:\s*(?:\w+\.)?\.?ReleaseFast\b", version):
            raise ValueError("version does not verify ReleaseFast")
        import gx_wsl
        namespace: dict = {"__name__": "gx_perf_validator"}
        exec(compile(gx_wsl.PERF_PROGRAM + gx_wsl.RECEIPT_PROGRAM, "gx_perf_validator", "exec"), namespace)
        source = {key: meta[key] for key in ("commit", "tree", "dirty", "dirty_paths")}
        receipt_text = raw("-build-receipt.json")
        if hashlib.sha256(receipt_text.encode()).hexdigest() != meta.get("build_receipt_sha256") or meta.get("version") != version:
            raise ValueError("build receipt/version raw hash conflict")
        receipt = json.loads(receipt_text)
        if receipt.get("perf_eligible") is not True or meta.get("source_end") != source:
            raise ValueError("source changed since normal build or during smoke")
        namespace["validate_receipt"](receipt, source, executable, version, meta.get("version_exit"))
        before, after, times = raw("-tasks-before.txt"), raw("-tasks-after.txt"), raw("-times.txt")
        namespace["measurement"](before, after, times)
        for text in (before, after):
            task = namespace["parse_tasks"](text).get(str(identity["pid"]), {})
            if task.get("starttime") != identity["starttime"]:
                raise ValueError("raw main birth differs from process identity")
        if namespace["parse_times"](times).get("run_exit") != "0":
            raise ValueError("missing or nonzero run_exit")
        samples = parse_text(raw("-perf.txt"))
        clk_tck = meta.get("clk_tck", 0)
        if not isinstance(clk_tck, int) or clk_tck <= 0:
            raise ValueError("missing CLK_TCK")
        process_before, process_after = json.loads(raw("-process-before.json")), json.loads(raw("-process-after.json"))
        accounting = namespace["cpu_accounting"](before, after, process_before, process_after, str(identity["pid"]), clk_tck)
        if meta.get("cpu_accounting") != accounting:
            raise ValueError("process CPU reconciliation differs from raw evidence")
        expected = parse_text(namespace["report"](before, after, times, raw(".log"), clk_tck, process_before, process_after))
        if samples.values != expected.values or samples.units != expected.units:
            raise ValueError("reported metrics differ from raw task window")
        for metric in GTK_REQUIRED:
            if len(samples.values.get(metric, [])) != 1 or samples.units.get(metric) != "ms":
                raise ValueError("missing or duplicate GTK metric " + metric)
        for suffix in (".png", "-perf.png", "-status-before.txt", "-status-after.txt"):
            name = prefix + suffix
            if name not in meta.get("files", []) or not (path.parent / name).is_file():
                raise ValueError("missing artifact " + name)
        samples.extend(parse_text(raw(".log")))
    except (OSError, ValueError) as exc:
        raise PerfError(f"{path}: invalid GTK evidence: {exc}") from None
    samples.gtk_runs.append(meta)
    return meta, samples


def collect(paths: Iterable[Path]) -> Samples:
    samples = Samples()
    files = sample_files(paths)
    experiment_dirs = {}
    for path in files:
        manifest = path.parent / 'run.json'
        if manifest.is_file() and manifest.parent not in experiment_dirs:
            data = read_json(manifest)
            if data.get('schema') == 'gx-win32-perf-run-v1':
                if data.get('status') != 'completed' or data.get('errors'):
                    raise PerfError(f'{manifest}: rejected Windows measurement')
                experiment_dirs[manifest.parent] = data
    for directory in experiment_dirs:
        # Per-run derived metrics already reduce warmups and select measurement
        # intervals. Never count the same events again from the full raw log.
        samples.extend(parse_text((directory / 'samples.txt').read_text(encoding='utf-8')))
        samples.unverified.add(str(directory / 'run.json'))
    files = [path for path in files if path.parent not in experiment_dirs]
    for parent in {path.parent for path in files}:
        for legacy in parent.glob("*-meta.txt"):
            text = legacy.read_text(encoding="utf-8", errors="replace")
            match = re.search(r"(?m)^exit:\s*(-?\d+)\s*$", text)
            if match and int(match.group(1)) != 0:
                raise PerfError(f"{legacy}: nonzero smoke exit; historical samples rejected")
    manifests = {p for p in files if p.name.endswith("-meta.json")}
    batches = set()
    for path in files:
        manifests.update(path.parent.glob("*-meta.json"))
        for parent in path.parents:
            batch = parent / "gtk-runs.json"
            if batch.is_file():
                batches.add(batch)
                break
    cached = {}
    for batch_path in sorted(batches):
        data = read_json(batch_path)
        plan = canonical_plan(batch_path.parent, data, require_valid=True)
        capture_ids = set()
        by_label = {}
        for item, target in plan:
            manifest = target / "perf-meta.json"
            if manifest.is_symlink() or not manifest.is_file() or hashlib.sha256(manifest.read_bytes()).hexdigest() != item["meta_sha256"]:
                raise PerfError(f"{manifest}: changed or missing planned-run original")
            meta, run = gtk_evidence(manifest)
            if not meta.get("perf") or meta["capture_id"] in capture_ids:
                raise PerfError(f"{manifest}: repeated or non-perf capture in declared batch")
            capture_ids.add(meta["capture_id"])
            cached[manifest] = (meta, run)
            by_label.setdefault(item["label"], set()).add(manifest)
        all_originals = set().union(*by_label.values())
        selected = manifests & all_originals
        if any(p.is_relative_to(batch_path.parent) and p not in all_originals for p in manifests):
            raise PerfError(f"{batch_path}: selected original is not in the canonical plan")
        for label, originals in by_label.items():
            chosen = selected & originals
            if chosen and chosen != originals:
                raise PerfError(f"{batch_path}: {label} selected {len(chosen)}/{data['planned_runs']} planned runs; partial GTK subsets cannot be verified")
    covered: set[Path] = set()
    for manifest in sorted(manifests):
        meta, run = cached[manifest] if manifest in cached else gtk_evidence(manifest)
        if meta.get("perf"):
            covered.update((manifest.parent / name).resolve() for name in meta.get("files", []))
            samples.extend(run)
    for path in files:
        if path in covered or path.name.endswith("-meta.json") or path.name == "gtk-runs.json":
            continue
        if path.name == "run.json":
            parse_run_json(read_json(path), samples)
        else:
            text = path.read_text(encoding="utf-8", errors="replace")
            if "valid: no" in text or ("# gx-wsl smoke --perf" in text and "finished: no" in text):
                raise PerfError(f"{path}: explicitly rejected sample")
            parsed = parse_text(text)
            if parsed:
                samples.unverified.add(str(path))
                samples.extend(parsed)
    return samples


def p90(values: Sequence[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.9 * len(ordered)) - 1)]


def stats(values: Sequence[float], unit: str = "ms") -> dict[str, float]:
    result = {"n": len(values), "median": statistics.median(values), "p90": p90(values), "min": min(values),
              "max": max(values)}
    if not unit:
        result["sum"] = sum(values)
    return result


def fmt(value: float, unit: str) -> str:
    return f"{value:.1f}" if unit == "ms" else (f"{value:.0f}" if float(value).is_integer() else f"{value:.2f}")


def summary_table(samples: Samples) -> tuple[str, dict]:
    rows = [f"{'metric':<34} {'unit':<4} {'n':>4} {'median':>10} {'p90':>10} {'min':>10} {'max':>10} {'sum':>10}"]
    report = {}
    for name in sorted(samples.values):
        values = samples.values[name]
        if not values:
            continue
        unit = samples.units[name]
        summary = stats(values, unit)
        report[name] = {"unit": unit, **summary}
        rows.append(f"{name:<34} {unit:<4} {summary['n']:>4} {fmt(summary['median'], unit):>10} "
                    f"{fmt(summary['p90'], unit):>10} {fmt(summary['min'], unit):>10} {fmt(summary['max'], unit):>10} "
                    f"{fmt(summary['sum'], unit) if not unit else '-':>10}")
    return "\n".join(rows) + "\n", report


def compare_table(old: Samples, new: Samples, labels: tuple[str, str] = ("old", "new")) -> tuple[str, dict]:
    a, b = labels
    rows = [f"{'metric':<34} {'unit':<4} {a + ' n':>6} {a + ' med':>10} {a + ' p90':>10} "
            f"{b + ' n':>6} {b + ' med':>10} {b + ' p90':>10} {'Δ med':>10} {'Δ%':>7} {a + ' sum':>10} {b + ' sum':>10}"]
    report = {}
    for name in sorted(set(old.values) | set(new.values)):
        unit = old.units.get(name, new.units.get(name, ""))
        left = {**stats(old.values[name], old.units[name]), 'unit': old.units[name]} if old.values.get(name) else None
        right = {**stats(new.values[name], new.units[name]), 'unit': new.units[name]} if new.values.get(name) else None
        comparison = metric_comparability(old, new, name)
        comparable = comparison['comparable']
        entry: dict = {"unit": unit if comparable else None, a: left, b: right, **comparison}
        cells = []
        for side in (left, right):
            cells += [f"{side['n']:>6}", f"{fmt(side['median'], side['unit']):>10}", f"{fmt(side['p90'], side['unit']):>10}"] if side \
                else [f"{'-':>6}", f"{'-':>10}", f"{'-':>10}"]
        if comparable:
            delta = right["median"] - left["median"]
            percent = (delta / left["median"] * 100) if left["median"] else float("nan")
            entry["delta_median"], entry["delta_percent"] = delta, percent if math.isfinite(percent) else None
            cells += [f"{('+' if delta >= 0 else '') + fmt(delta, unit):>10}",
                      f"{'n/a' if math.isnan(percent) else f'{percent:+.1f}':>7}"]
        else:
            cells += [f"{'-':>10}", f"{'-':>7}"]
        report[name] = entry
        cells += [f"{fmt(side['sum'], '') if side and not side['unit'] else '-':>10}" for side in (left, right)]
        display_unit = unit if not left or not right or left['unit'] == right['unit'] else f"{left['unit'] or 'count'}/{right['unit'] or 'count'}"
        rows.append(f"{name:<34} {display_unit:<4} " + " ".join(cells))
    return "\n".join(rows) + "\n", report


def metric_comparability(old: Samples, new: Samples, name: str) -> dict:
    """Describe coverage without inventing samples or evaluating a benefit."""
    left, right = old.values.get(name, []), new.values.get(name, [])
    reasons = []
    if not left or not right:
        reasons.append('metric missing on one side')
    if left and right and old.units.get(name) != new.units.get(name):
        reasons.append('time/count unit conflict')
    if left and right and len(left) != len(right):
        reasons.append(f'sample counts differ ({len(left)} vs {len(right)})')
    return {'comparable': not reasons, 'reasons': reasons}


def gtk_sample_errors(samples: Samples, runs: int) -> list[str]:
    """Only the five core metrics are required in every planned run.

    Other CPU groups describe the comm values actually captured at the endpoints.
    A missing group is unknown, not a zero; a present group still needs valid time
    samples. The cross-arm equal-n rule is enforced by comparison_errors.
    """
    errors = []
    for name in sorted(set(GTK_REQUIRED) | {n for n in samples.values if n.startswith('cpu.')}):
        values = samples.values.get(name, [])
        if name in GTK_REQUIRED and (not values or len(values) != runs):
            errors.append(f'{name}: requires {runs} time samples, got {len(values)}')
        if values and (samples.units.get(name) != 'ms' or any(not math.isfinite(v) or v < 0 for v in values)):
            errors.append(f'{name}: invalid time unit or non-finite/negative sample')
    return errors


def metric_coverage(samples: Samples, planned: int | None = None, names: Iterable[str] = ()) -> dict:
    return {name: {'n': len(samples.values.get(name, [])), 'unit': samples.units.get(name),
                   'role': 'required' if name in GTK_REQUIRED else 'captured_cpu_group' if name.startswith('cpu.') else 'optional',
                   'planned_runs': planned, 'availability': 'observed' if samples.values.get(name) else 'unknown'}
            for name in sorted(set(samples.values) | set(names))}


def comparison_errors(old: Samples, new: Samples, gtk: bool = False, runs: int | None = None) -> list[str]:
    errors = []
    verified_gtk = gtk or bool(old.gtk_runs or new.gtk_runs)
    if verified_gtk or any(name.startswith("cpu.") for name in set(old.values) | set(new.values)):
        for side, samples in (("old", old), ("new", new)):
            expected = runs if runs is not None else len(samples.values.get("cpu.main", []))
            errors.extend(f'{side} {error}' for error in gtk_sample_errors(samples, expected))
    for name in sorted(set(old.values) | set(new.values)):
        left, right = old.values.get(name, []), new.values.get(name, [])
        if left and right and old.units.get(name) != new.units.get(name):
            errors.append(f'{name}: time/count unit conflict')
        if verified_gtk and name not in GTK_REQUIRED and not (name.startswith('cpu.') and left and right):
            continue
        if not left or not right:
            if verified_gtk:
                errors.append(f"{name}: metric missing on one side")
        elif len(left) != len(right):
            errors.append(f"{name}: sample counts differ ({len(left)} vs {len(right)})")
    return errors


def validation(samples: Sequence[Samples]) -> dict:
    return {"status": "valid", "identity": "unverified" if any(s.unverified for s in samples) else "verified",
            "verified_gtk_runs": [len(s.gtk_runs) for s in samples],
            "metric_coverage": [metric_coverage(s) for s in samples],
            "optional_metrics_complete": "not asserted; unknown/missing sides remain absent, never synthesized as zero",
            "cpu_contract": "process/endpoint quantized ticks; residual bounds diagnostic-only and unproved" if any(s.gtk_runs for s in samples) else "unverified",
            "unverified_files": sorted(set().union(*(s.unverified for s in samples)))}


def write_json(path: Path | None, data: Mapping) -> None:
    if path is not None:
        try:
            text = json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
        except ValueError as exc:
            raise PerfError(f"{path}: non-finite report data: {exc}") from None
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")


def alternate(labels: Sequence[str], runs: int) -> list[tuple[int, str]]:
    """(run number, label) in measurement order: every label once per round, rounds alternating direction."""
    order = []
    for run in range(1, runs + 1):
        round_labels = list(labels) if run % 2 else list(reversed(labels))
        order += [(run, label) for label in round_labels]
    return order


def labels_for(count: int, given: Sequence[str]) -> list[str]:
    if given and len(given) != count:
        raise PerfError(f"give one --label per build ({count}), got {len(given)}")
    labels = list(given) or (["old", "new"] if count == 2 else ["build"])
    if len(set(labels)) != len(labels) or not all(label not in (".", "..") and re.fullmatch(r"[A-Za-z0-9._-]+", label) for label in labels):
        raise PerfError("labels must be distinct and use letters, digits, '.', '_' or '-'")
    return labels


def label_environments(labels: Sequence[str], common: Sequence[str], overrides: Sequence[str], parse) -> dict:
    """Resolve label-local overrides without mutating the caller's environment."""
    parse(common)
    base = dict(item.split("=", 1) for item in common)
    result = {label: dict(base) for label in labels}
    for item in overrides:
        label, separator, assignment = item.partition(":")
        if not separator or label not in result:
            raise PerfError(f"--label-env requires a known LABEL:NAME=VALUE: {item}")
        parse([assignment])
        name, value = assignment.split("=", 1)
        result[label][name] = value
    return result


# Quiet checks observe state; they never stop a process, VM or WSL distribution.
BUILD_PROCESSES = ("zig", "build", "test", "ghostty-test", "clang", "clang++", "cc1", "cc1plus", "ld.lld", "lld-link",
                   "ninja", "msbuild", "cl", "link", "gcc", "g++", "make", "cmake", "rustc", "cargo")
# The quiet criteria in force (the user's ruling of 2026-10-18 13:20, r6-contract.md §6): other
# software is recorded, never gated (the plan §4 blacklist, like CPU); this project's own load still
# gates (build/test processes on Windows and in WSL, the validation VM, every slot); Windows-desktop
# batches still need >= 600 s without input before the start and none during the batch; WSL/Xvfb-only
# batches (--input-observe-only) record input instead.
QUIET_CRITERIA = 'r6-13:20 user ruling'
# The plan §4 list, kept literally; recorded in blacklist_observation, a gate only with
# --strict-blacklist (the criteria before the 13:20 ruling). Matching is a case-insensitive (casefold)
# substring of a process image name or main window title: Windows reports image
# names in whatever case the launcher used (todesk.exe, TODESK.EXE) and titles
# are free text. Devin/devin fold to one entry. No bare "kimi": it would also
# match kimi-cu, which root ruled is not Kimi Code.
BLACKLIST = ("Devin", "devin", "ToDesk", "Kimi Code", "哔哩哔哩")
BLACKLIST_MATCHING = "case-insensitive (casefold) substring of a process image name or main window title"
# Other programs worth noting in the evidence (root ruling: kimi-cu is not "Kimi
# Code"). Observation only: they never make a snapshot busy.
OBSERVED_PROGRAMS = ("kimi-cu",)
BUILD_RUNNER_RE = (r'(?:run_unittests\.py|zig_test\.py|zigw\.py\s+build|(?:^|\s)-m\s+(?:unittest|pytest)(?:\s|$)|'
                   r'(?:^|[/\\\s])test_[^\s]+\.py|gx_(?:win_gui|perf|wsl|windows_vm)\.py|test[/\\]windows[/\\][^\s]+\.py)')


def command_output(argv: Sequence[str]) -> str:
    result = subprocess.run(list(argv), capture_output=True, timeout=45)
    if result.returncode:
        raise PerfError(f"{argv[0]} exited {result.returncode}: {result.stderr.decode('utf-8', errors='replace')}")
    raw = result.stdout
    return raw.decode("utf-16" if b"\0" in raw else "utf-8-sig", errors="strict")


def powershell_json(script: str):
    prefix = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference='Stop'; "
    return json.loads(command_output(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", prefix + script]))


def shared_slots_root() -> Path:
    import gx_slots
    return gx_slots.shared_root()


def validate_slot_root(root: Path) -> Path:
    import gx_slots
    if root.resolve() != shared_slots_root().resolve():
        raise PerfError(f'{root}: slot root must be the main checkout shared root {shared_slots_root()}')
    if not root.is_dir() or any(not (root / name).is_file() for name in gx_slots.QUIET_NAMES):
        raise PerfError(f'{root}: slot root or lock files do not exist')
    return root.resolve()


PLAN_IDLE_SECONDS = 600  # plan §4: no user input for at least 10 minutes
TICK_MASK = 0xFFFFFFFF  # GetTickCount and LASTINPUTINFO.dwTime wrap every 49.7 days


def input_observation(ticks: Mapping, since: Mapping | None = None) -> dict:
    """Idle time from one GetLastInputInfo/GetTickCount pair; with `since`, also
    the time elapsed on the same tick clock since an earlier (start-check) pair."""
    last, now = int(ticks['last_input_tick']), int(ticks['tick_count'])
    data = {'last_input_tick': last, 'tick_count': now, 'idle_seconds': ((now - last) & TICK_MASK) / 1000}
    if since is not None:
        data['batch_start_tick'] = int(since['tick_count'])
        data['batch_seconds'] = ((now - data['batch_start_tick']) & TICK_MASK) / 1000
    return data


def input_session() -> dict:
    if sys.platform != 'win32':
        raise PerfError('input session check requires Windows')
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.ProcessIdToSessionId.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
    kernel.ProcessIdToSessionId.restype = ctypes.c_int
    kernel.WTSGetActiveConsoleSessionId.restype = ctypes.c_uint32
    current = ctypes.c_uint32()
    if not kernel.ProcessIdToSessionId(os.getpid(), ctypes.byref(current)):
        raise ctypes.WinError(ctypes.get_last_error())
    active = kernel.WTSGetActiveConsoleSessionId()
    return {'process_session': current.value, 'active_console_session': active,
            'interactive_console': active != 0xFFFFFFFF and active == current.value}


def last_input_ticks() -> tuple[int, int]:
    if sys.platform != "win32":
        raise PerfError("GetLastInputInfo requires Windows")
    class LASTINPUTINFO(ctypes.Structure):
        _fields_ = [("cbSize", ctypes.c_uint32), ("dwTime", ctypes.c_uint32)]
    info = LASTINPUTINFO(ctypes.sizeof(LASTINPUTINFO), 0)
    user = ctypes.WinDLL("user32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    user.GetLastInputInfo.argtypes = [ctypes.POINTER(LASTINPUTINFO)]
    user.GetLastInputInfo.restype = ctypes.c_int
    kernel.GetTickCount.restype = ctypes.c_uint32
    if not user.GetLastInputInfo(ctypes.byref(info)):
        raise ctypes.WinError(ctypes.get_last_error())
    return info.dwTime, kernel.GetTickCount()


def process_name(name: str) -> str:
    return name.replace("\\", "/").rsplit("/", 1)[-1].casefold().removesuffix(".exe")


def ancestor_exclusions(cim: Sequence[Mapping], start_pid: int, inventory_pid=None) -> tuple[dict[int, str], str]:
    """PIDs exempt from runner command-line matching only: this process, its
    verified ancestors and the inventory helper it started.

    A parent counts only while its CreationDate is not later than its child's,
    so a recycled ParentProcessId (common once userinit.exe has exited) is never
    exempted. Returns {pid: reason} and why the walk stopped."""
    by_pid = {row['pid']: row for row in cim}
    excluded: dict[int, str] = {}
    helper = by_pid.get(inventory_pid) if isinstance(inventory_pid, int) else None
    if helper is not None and helper.get('ppid') == start_pid:
        excluded[inventory_pid] = 'inventory'
    current, reason, end = by_pid.get(start_pid), 'self', 'self_missing'
    while current is not None:
        excluded[current['pid']] = reason
        reason = 'ancestor'
        parent_pid = current.get('ppid')
        if not isinstance(parent_pid, int) or parent_pid <= 0 or parent_pid == current['pid']:
            end = 'root'
            break
        parent = by_pid.get(parent_pid)
        if parent is None:
            end = 'parent_exited'
            break
        if parent_pid in excluded:
            end = 'cycle'
            break
        born, parent_born = current.get('created'), parent.get('created')
        if not isinstance(born, int) or not isinstance(parent_born, int) or parent_born > born:
            end = 'parent_pid_reused_or_unverifiable'
            break
        current = parent
    return excluded, end


def windows_inventory(data: Mapping, self_pid: int) -> dict:
    """Join Win32_Process (parent, creation, command line) with Get-Process (window title).

    Command lines and titles stay in memory for matching; quiet_snapshot persists
    only pid/name/flags. The self/ancestor exemption applies to runner
    command-line matching alone: build-process names and the blacklist still
    cover every process, ancestors included."""
    cim = data.get('cim') if isinstance(data, Mapping) else None
    processes = data.get('processes') if isinstance(data, Mapping) else None
    if not isinstance(cim, list) or not cim or not isinstance(processes, list) or not processes:
        raise PerfError("Windows process inventory is missing")
    excluded, chain_end = ancestor_exclusions(cim, self_pid, data.get('inventory_pid'))
    rows: dict[int, dict] = {}
    for item in cim:
        line = item.get('command_line')
        rows[item['pid']] = {'pid': item['pid'], 'name': item.get('name') or '', 'names': [item.get('name') or ''],
                             'title': '', 'command_line_unavailable': not line,
                             # Windows command lines are case-insensitive, like the former PowerShell -match.
                             'runner_match': bool(line) and re.search(BUILD_RUNNER_RE, line, re.IGNORECASE) is not None}
    for item in processes:
        row = rows.setdefault(item['pid'], {'pid': item['pid'], 'name': item.get('name') or '', 'names': [], 'title': '',
                                            'command_line_unavailable': True, 'runner_match': False})
        row['names'].append(item.get('name') or '')
        row['title'] = item.get('title') or ''
    exclusions = []
    for pid in sorted(rows):
        row = rows[pid]
        reason = excluded.get(pid)
        row['build_runner'] = row['runner_match'] and reason is None
        if reason:
            row['runner_exclusion'] = reason
            exclusions.append({'pid': pid, 'name': row['name'], 'reason': reason, 'runner_match_suppressed': row['runner_match']})
    return {'processes': [rows[pid] for pid in sorted(rows)], 'runner_exclusions': exclusions,
            'ancestor_chain_end': chain_end}


class QuietProbe:
    def windows(self) -> dict:
        data = powershell_json(
            "$cim=@(Get-CimInstance Win32_Process | ForEach-Object {@{pid=[int]$_.ProcessId;ppid=[int]$_.ParentProcessId;"
            "name=$_.Name;created=$(if($_.CreationDate){$_.CreationDate.ToFileTimeUtc()}else{$null});"
            "command_line=$_.CommandLine}}); "
            "$processes=@(Get-Process | ForEach-Object {@{pid=$_.Id;name=$_.ProcessName;title=$_.MainWindowTitle}}); "
            "@{inventory_pid=$PID;cim=$cim;processes=$processes} | ConvertTo-Json -Depth 4 -Compress")
        if not isinstance(data, dict):
            raise PerfError("Windows process inventory is missing")
        return data

    def registered(self, distro: str) -> None:
        registered = command_output(['wsl.exe', '--list', '--quiet'])
        if distro.casefold() not in {line.strip().casefold() for line in registered.splitlines()}:
            raise PerfError(f'WSL distribution is not registered: {distro}')

    def wsl(self, distro: str) -> dict:
        self.registered(distro)
        running = command_output(["wsl.exe", "--list", "--running", "--quiet"])
        rows = []
        active = [line.strip() for line in running.splitlines() if line.strip()]
        for name in active:
            # docker-desktop* is Docker's own utility VM, not a build distribution. Plan §4
            # gates only the validation VM containers (vm check); the number of running
            # containers is recorded separately as an observation (docker_containers).
            if name.casefold().startswith('docker-desktop'):
                continue
            output = command_output(["wsl.exe", "--distribution", name, "--exec", "ps", "-eo", "pid=,comm=,args="])
            if not output.strip():
                raise PerfError(f'WSL process inventory is empty: {name}')
            for line in output.splitlines():
                pid, process, argv = line.strip().split(None, 2)
                rows.append({"distro": name, "pid": int(pid), "name": process, "build_runner": bool(re.search(BUILD_RUNNER_RE, argv))})
        return {"distro": distro, "running": distro.casefold() in {name.casefold() for name in active},
                "running_distributions": active, "processes": rows}

    def vm(self, slots: Path) -> dict:
        # status historically treats a failed docker inspect as an absent VM.
        # Verify daemon access first so an unavailable daemon cannot look quiet.
        import gx_windows_vm
        docker = gx_windows_vm.docker_executable(None)
        command_output([docker, "info", "--format", "{{json .ServerVersion}}"])
        data = json.loads(command_output([sys.executable, str(SCRIPTS / "gx_windows_vm.py"), "status",
                                         "--root", str(slots.parent / "windows-vm")]))
        if not isinstance(data, dict) or not data or any(not isinstance(row, dict) or
                type(row.get("running")) is not bool or type(row.get("exists")) is not bool for row in data.values()):
            raise PerfError("VM status is incomplete")
        return data

    def containers(self) -> int:
        """Running Docker containers of any image; only the count is kept."""
        import gx_windows_vm
        docker = gx_windows_vm.docker_executable(None)
        return sum(bool(line.strip()) for line in command_output([docker, 'ps', '-q']).splitlines())

    def slots(self, root: Path) -> bool:
        import gx_slots
        validate_slot_root(root)
        try:
            with gx_slots.acquire(root, "quiet", timeout=0, probe=True):
                pass
            return True
        except TimeoutError:
            return False

    def input_ticks(self) -> dict:
        tick, now = last_input_ticks()
        return {'last_input_tick': tick, 'tick_count': now}

    def session(self) -> dict:
        return input_session()

    def cpu(self) -> dict:
        return powershell_json("@{cpu=@(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | "
                               "Where-Object Name -eq '_Total' | Select-Object PercentProcessorTime); "
                               "top=@(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | "
                               "Where-Object {$_.IDProcess -ne 0 -and $_.Name -ne '_Total'} | "
                               "Sort-Object PercentProcessorTime -Descending | Select-Object -First 10 "
                               "IDProcess,Name,PercentProcessorTime)} | ConvertTo-Json -Depth 5 -Compress")


def program_matches(rows: Sequence[Mapping], names: Sequence[str]) -> list[dict]:
    """Rows whose image name or window title contains one of `names`, compared after
    casefold; names equal after casefold report once, as their first spelling.
    Only pid/name/matches are returned, never the title."""
    keys: dict[str, str] = {}
    for name in names:
        keys.setdefault(name.casefold(), name)
    found = []
    for row in rows:
        texts = [(text or '').casefold() for text in (*(row.get('names') or [row.get('name')]), row.get('title'))]
        matches = [name for key, name in keys.items() if any(key in text for text in texts)]
        if matches:
            found.append({'pid': row['pid'], 'name': row.get('name'), 'matches': matches})
    return found


def quiet_snapshot(args, probe=None, *, lease=None, end=None) -> dict:
    """One check of every criterion of QUIET_CRITERIA. `end` = {evidence, since, injected_mode}
    turns the input item into the end-of-batch criterion (see end_input). The blacklist is
    recorded in blacklist_observation and gates only with --strict-blacklist; with
    --input-observe-only the input item is kept with status observed (its result in `observed`),
    which never makes the snapshot busy."""
    probe = probe or QuietProbe()
    strict = bool(getattr(args, 'strict_blacklist', False))
    observe_input = bool(getattr(args, 'input_observe_only', False))
    checks = {}
    def check(name, operation, assess):
        try:
            raw = operation()
            passed, reason = assess(raw)
            checks[name] = {"status": "pass" if passed else "fail", "reason": reason, "raw": raw}
        except Exception as exc:
            checks[name] = {"status": "error", "reason": str(exc)}
    builds = {process_name(name) for name in (*BUILD_PROCESSES, *(args.build_process or []))}
    blacklist = sorted({*BLACKLIST, *(args.blacklist or [])})
    observed = sorted({*OBSERVED_PROGRAMS, *(getattr(args, 'observe', None) or [])})
    def build_check(rows):
        found = [row for row in rows if any(process_name(name) in builds for name in row.get('names') or [row['name']])
                 or row.get('build_runner')]
        return not found, "no build/test processes" if not found else f"build/test PIDs: {[row['pid'] for row in found]}"
    check("windows", lambda: windows_inventory(probe.windows(), os.getpid()), lambda data: build_check(data['processes']))
    windows = checks["windows"]
    other_programs = {'status': 'unavailable', 'names': observed, 'scope': 'observation only; never a quiet gate'}
    blacklist_observation = {'status': 'unavailable', 'names': blacklist, 'matching': BLACKLIST_MATCHING,
                             'scope': 'a quiet gate (--strict-blacklist)' if strict else
                             f'observation only ({QUIET_CRITERIA}); never a quiet gate'}
    if windows['status'] == 'error':
        blacklist_observation['reason'] = 'Windows inventory unavailable'
        if strict:
            checks['blacklist'] = {"status": "error", "reason": "Windows inventory unavailable"}
    else:
        rows = windows['raw']['processes']
        found = program_matches(rows, blacklist)
        blacklist_observation.update(status='recorded', matches=found)
        if strict:
            check('blacklist', lambda: found,
                  lambda found: (not found, 'blacklisted process present' if found else 'no blacklisted processes'))
        other_programs.update(status='recorded', matches=program_matches(rows, observed))
        windows['command_lines_unavailable'] = sum(bool(row.get('command_line_unavailable')) for row in rows)
        windows['raw'] = {'processes': [{key: row[key] for key in ('pid', 'name', 'build_runner', 'command_line_unavailable',
                                                                   'runner_exclusion') if key in row} for row in rows],
                          'runner_exclusions': windows['raw']['runner_exclusions'],
                          'ancestor_chain_end': windows['raw']['ancestor_chain_end']}
    check("wsl", lambda: probe.wsl(args.distro), lambda data: build_check(data['processes']))
    check("vm", lambda: probe.vm(args.slot_root), lambda data: (
        not any(row['running'] for row in data.values()),
        "all validation VM containers stopped" if not any(row['running'] for row in data.values()) else "VM container running"))
    if lease is None:
        check("slots", lambda: probe.slots(args.slot_root), lambda free: (free, "all four existing locks probed and released" if free else "slot occupied"))
    else:
        check('slots', lease.verify, lambda held: (held, 'all four locks held by this batch' if held else 'batch lock ownership lost'))
    check('session', probe.session, lambda data: (
        data['interactive_console'], 'running in the active console session' if data['interactive_console'] else
        'not in the active console session: GetLastInputInfo cannot observe the console user'))
    if checks['session']['status'] == 'fail':
        checks['session']['status'] = 'error'
    threshold = args.idle_seconds
    if end is None:
        check('input', lambda: input_observation(probe.input_ticks()),
              lambda data: (data['idle_seconds'] >= threshold, f"idle {data['idle_seconds']:.3f}s; required {threshold:g}s"))
    else:
        check('input', lambda: end_input(end, probe, threshold), lambda data: (data['state'] == 'pass', data['reason']))
    if observe_input and checks['input']['status'] != 'error':
        # A WSL/Xvfb batch: the values and the result the gate would have had are kept, never gating.
        row = checks['input']
        row.update(status='observed', observed=row['status'],
                   reason=f"observe only (--input-observe-only, a WSL/Xvfb batch): {row['reason']}")
    try:
        observation = {"status": "recorded", "raw": probe.cpu()}
    except Exception as exc:
        observation = {"status": "unavailable", "reason": str(exc)}
    container_scope = 'observation only; plan §4 gates the validation VM containers (vm check)'
    try:
        containers = {'status': 'recorded', 'running': int(probe.containers()), 'scope': container_scope}
    except Exception as exc:
        containers = {'status': 'unavailable', 'reason': str(exc), 'scope': container_scope}
    code = 2 if any(row['status'] == 'error' for row in checks.values()) else (
        3 if any(row['status'] == 'fail' for row in checks.values()) else 0)
    thresholds = thresholds_plan_compliant(args)
    return {"schema": "gx-quiet-v1", "time_ns": time.time_ns(), "quiet": code == 0, "exit": code,
            'criteria': QUIET_CRITERIA, 'criteria_options': {'strict_blacklist': strict, 'input_observe_only': observe_input},
            'gates': [name for name, row in checks.items() if row['status'] != 'observed'],
            'observed_only': [*(['input'] if observe_input else []), *([] if strict else ['blacklist']),
                              'other_programs', 'cpu_observation', 'docker_containers'],
            'thresholds_plan_compliant': thresholds,
            # Every gate of `criteria` met with its thresholds (point in time; batches see RESULT.json).
            'plan_compliant': code == 0 and thresholds,
            "slot_root": str(args.slot_root), "checks": checks, "cpu_observation": observation,
            "other_programs": other_programs, "blacklist_observation": blacklist_observation, "docker_containers": containers,
            "build_processes": sorted(builds), "blacklist": blacklist, "blacklist_matching": BLACKLIST_MATCHING,
            "scope": "batch-owned locks" if lease else "point-in-time probe; locks released, not a reservation"}


def thresholds_plan_compliant(args) -> bool:
    """The idle threshold is the plan's (>= 600 s); it does not apply when input is only observed."""
    return bool(getattr(args, 'input_observe_only', False)) or args.idle_seconds >= PLAN_IDLE_SECONDS


def new_output(path: Path) -> Path:
    path = path.resolve()
    if path.exists() and (not path.is_dir() or any(path.iterdir())):
        raise PerfError(f"{path}: output must be new or empty; evidence is never overwritten")
    path.mkdir(parents=True, exist_ok=True)
    return path


def run_quiet(args, probe=None, sleep=time.sleep) -> int:
    if not math.isfinite(args.idle_seconds) or args.idle_seconds < 0 or not math.isfinite(args.interval) or args.interval <= 0 or args.max_attempts < 1:
        raise PerfError("invalid idle threshold, polling interval or attempts")
    args.slot_root = args.slot_root or shared_slots_root()
    out = new_output(args.out)
    for attempt in range(1, (args.max_attempts if args.wait else 1) + 1):
        result = quiet_snapshot(args, probe)
        result['attempt'] = attempt
        write_json(out / f"attempt-{attempt:03d}.json", result)
        write_json(args.json, result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
        if result['exit'] != 3 or not args.wait or attempt == args.max_attempts:
            return result['exit']
        sleep(args.interval)
    return 2


# gx_win_gui runs these guards immediately before every SendInput (scripts/gx_win_gui.py::input_guard).
SEND_GUARDS = ('ensure_foreground', 'ensure_point')
# Audit causes (gx_win_gui.InputBlocked.CAUSES). Environment causes refute the plan §4 input
# criterion (INVALID); instance_gone (it ended), instance_hung (it hangs or crashed, with a Ghost
# or WerFault window in the way) and instance_self_activated (win32-idle: without any input it took
# the foreground back from its focus helper or restored a minimized window) are product/driver failures
# of the measured Ghostty and are never read as noise: rerunning such a batch until one passes would
# cherry-pick the result, and a defect that recurs on every attempt would end up BLOCKED.
ENVIRONMENT_CAUSES = ('foreground_lost', 'pointer_target_lost', 'foreign_input')
PRODUCT_CAUSES = ('instance_gone', 'instance_hung', 'instance_self_activated')


def guard_evidence(path: Path, batch_id: str) -> dict:
    """Facts from the batch-bound gx_win_gui audit log (gx-input-guard-v1); no file means no rows.

    injected: input was actually sent (a passed SendInput guard or a sent key/button
    release). Failed rows are split by cause: environment (failed guards with an
    ENVIRONMENT_CAUSES cause; nothing was sent at that point), product (PRODUCT_CAUSES
    rows of any event) and unexplained (any other failure: unknown or missing cause,
    a release that was not sent). Foreign, malformed or other-batch rows raise
    PerfError because the log cannot be trusted."""
    data = path.read_bytes() if path.is_file() else b''
    rows = [json.loads(line) for line in data.decode('utf-8').splitlines() if line.strip()]
    if any(not isinstance(row, dict) or row.get('schema') != 'gx-input-guard-v1' or row.get('batch_id') != batch_id for row in rows):
        raise PerfError('foreign or malformed input guard evidence')
    guards = [row for row in rows if row.get('event') == 'guard']
    sent = [row for row in guards if row.get('status') == 'pass' and row.get('check') in SEND_GUARDS]
    releases = [row for row in rows if row.get('event') == 'release']
    failed = [row for row in rows if row.get('status') != 'pass']
    product = [row for row in failed if row.get('cause') in PRODUCT_CAUSES]
    return {'events': len(rows), 'guards': len(guards), 'passed_guards': len(sent),
            'injected': bool(sent) or any(row.get('status') == 'pass' for row in releases),
            'environment': [row for row in failed if row.get('cause') in ENVIRONMENT_CAUSES and row.get('event') == 'guard'],
            'product': product,
            # Anything else that failed is not understood: an unknown cause or a release that was not sent.
            'unexplained': [row for row in failed if row not in product and
                            not (row.get('cause') in ENVIRONMENT_CAUSES and row.get('event') == 'guard')],
            'sha256': hashlib.sha256(data).hexdigest() if data else None}


def end_input(end: Mapping, probe, threshold: float) -> dict:
    """The input criterion of plan §4 at the end check of a batch.

    A batch that injected input is judged by its audited guards, because its own
    SendInput refreshes GetLastInputInfo. A batch that injected nothing - run without
    --injected-input, or with it but no input was ever sent (one-tab one-window
    win32-idle) - must have had no input at all since the start check:
    idle >= max(threshold, batch duration) on the same tick clock. Failed guards
    fail the criterion only for environment causes (foreground_lost, pointer_target_lost,
    foreign_input); PRODUCT_CAUSES rows (instance_gone, instance_hung, instance_self_activated) are product
    failures handled by classify_batch;
    unexplained failures (unknown cause, release not sent) are tool errors."""
    evidence = end['evidence']
    if isinstance(evidence, BaseException):
        raise evidence
    if evidence['unexplained']:
        first = evidence['unexplained'][0]
        raise PerfError(f"unexplained input audit failure ({first.get('event')}, cause {first.get('cause')}): {first.get('reason')}")
    summary = {key: evidence[key] for key in ('events', 'guards', 'passed_guards', 'injected', 'sha256')}
    summary['product_failures'] = len(evidence['product'])
    if evidence['environment']:
        first = evidence['environment'][0]
        return {**summary, 'mode': 'guards', 'state': 'fail', 'cause': first['cause'], 'failures': evidence['environment'],
                'reason': f"{first['cause']}: input check {first.get('check')} failed: {first.get('reason')}"}
    if end['injected_mode'] and evidence['injected']:
        return {**summary, 'mode': 'guards', 'state': 'pass',
                'reason': f"injected input: {evidence['passed_guards']} audited input guards passed, not GetLastInputInfo"}
    data = {**summary, **input_observation(probe.input_ticks(), end['since']), 'mode': 'last_input'}
    if end['injected_mode']:
        data['fallback'] = 'last_input'  # nothing was injected, so GetLastInputInfo shows only other input
    data['state'] = 'pass' if data['idle_seconds'] >= max(threshold, data['batch_seconds']) else 'fail'
    if data['state'] == 'fail':
        data['cause'] = 'foreign_input'  # input this batch did not send happened after the start check
    data['reason'] = (f"idle {data['idle_seconds']:.3f}s; batch {data['batch_seconds']:.3f}s; no input allowed after the start "
                      f"check (required >= {threshold:g}s and >= the batch duration)" +
                      ('; --injected-input batch sent no input: last-input fallback' if end['injected_mode'] else ''))
    return data


FILETIME_UNIX_EPOCH = 116444736000000000  # 100 ns intervals from 1601-01-01 to 1970-01-01


def batch_preflight(args, probe) -> dict:
    """Fail before waiting for locks when the batch could never start: an
    unregistered distribution, a session that GetLastInputInfo cannot observe,
    or a quiet-batch nested under its own slot holder (gx_slots.py, Invoke-Heavy
    or Invoke-Desktop), which would only time out after --timeout."""
    import gx_slots
    probe.registered(args.distro)
    session = probe.session()
    if not session.get('interactive_console'):
        raise PerfError(f'not in the active console session: {session}')
    holders = gx_slots.holders(args.slot_root)
    nested = []
    if holders:
        cim = probe.windows().get('cim') or []
        chain, _ = ancestor_exclusions(cim, os.getpid())
        born = {row['pid']: row.get('created') for row in cim}
        for holder in holders:
            created, started = born.get(holder['pid']), holder.get('started_ns')
            # A verified self/ancestor that took the lock after it was created
            # (1 s clock slack); a stale record of a recycled PID predates it.
            if chain.get(holder['pid']) in ('self', 'ancestor') and isinstance(created, int) and isinstance(started, int) \
                    and started >= (created - FILETIME_UNIX_EPOCH) * 100 - 1_000_000_000:
                nested.append(holder)
    if nested:
        raise PerfError(f'quiet-batch is nested under its own slot holder {nested}; '
                        'run it directly, never inside gx_slots.py, Invoke-Heavy or Invoke-Desktop')
    return {'distro_registered': args.distro, 'session': session, 'slot_holders': holders}


BATCH_GUIDANCE = {
    'VALID': 'Quiet criteria met at the start and end checks and the command completed; '
             'the measurement RESULT/SUMMARY carries the performance verdict.',
    'FAIL': 'Quiet criteria met at the start and end checks; the command reported a gate FAIL (exit 4). '
            'For the pinned C1 entry this means shared CPU sample counts differ: INSUFFICIENT, not a performance regression. '
            'Keep it as FAIL evidence; never rerun to replace it.',
    'INVALID': 'A quiet criterion was not met at the end check: the whole batch is INVALID. '
               'Originals are retained; rerun on another day in a new directory.',
    'NOT_STARTED': 'The start check did not pass or the slots stayed busy; the command was not run.',
    'ERROR': 'Tool or driver error: this batch is neither PASS nor FAIL evidence. Investigate before rerunning.',
    'NONCOMPLIANT': 'Quiet thresholds were weakened below plan §4 (idle < 600 s): never plan evidence.',
    'PRODUCT_FAIL': 'A measured Ghostty instance ended, changed identity or hung during the batch, or activated or '
                    'restored itself without input (cause instance_gone, instance_hung or instance_self_activated): '
                    'a FAIL-class product/driver failure, not environment noise. Keep it and count it; never rerun to '
                    'replace it; read ghostty.log, crash dumps and guards.jsonl before another attempt. '
                    'product_failure_runs names the arm and run of that instance; root rules on a crash of the '
                    'historical arm.',
    'RUNNING': 'The batch did not finish recording its result.',
}


WIN32_DRIVERS = ('win32-ui', 'win32-idle', 'win32-gpu', 'win32-mem', 'win32-c7')


FROZEN_C1_CONTRACT = {
    'runs_per_arm': 10, 'order': 'AB/BA', 'workload': 'seq 1 3000000', 'tail_seconds': 1, 'poll_ms': 50,
    'env': ['GHOSTTY_GX_PERF=1', 'GHOSTTY_GX_PIPELINE_STATS=1', 'GSK_RENDERER=cairo'],
}
FROZEN_C1_FILES = ('adapter', 'gx_perf.py', 'gx_wsl.py', 'test_gx_perf.py', 'test_gx_wsl.py')

# Only this fixed bootstrap is executed, with the verified bytes on stdin. The
# child does not reopen the adapter/modules after the lease-time hash check.
FROZEN_COLLECTOR_BOOTSTRAP = '''import base64, json, sys
from importlib.machinery import BuiltinImporter, FrozenImporter, PathFinder
from pathlib import Path

if not (sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode):
    raise RuntimeError('frozen collector requires -I -S -B')
# Snapshot only the interpreter's isolated, no-site search path. Never consult
# task sys.path additions. Bound application modules are installed from payload
# bytes by the reviewed adapter; all other imports must belong to the stdlib.
stdlib_paths = tuple(sys.path)
stdlib_roots = tuple(Path(value).resolve() for value in stdlib_paths)
stdlib_names = frozenset(sys.stdlib_module_names)

def trusted_path(value):
    path = Path(value).resolve()
    return (not {'site-packages', 'dist-packages'}.intersection(path.parts) and
            any(path.is_relative_to(root) for root in stdlib_roots))

class StdlibOnly:
    @staticmethod
    def find_spec(fullname, path=None, target=None):
        if fullname.partition('.')[0] not in stdlib_names:
            raise ImportError('unbound frozen collector import: ' + fullname)
        search = stdlib_paths if path is None else tuple(path)
        if not all(trusted_path(value) for value in search):
            raise ImportError('untrusted frozen collector package path: ' + fullname)
        spec = PathFinder.find_spec(fullname, search, target)
        if spec is None:
            # Keep optional platform probes (e.g. subprocess importing msvcrt
            # on POSIX) compatible with normal import failure semantics.
            raise ModuleNotFoundError('stdlib module unavailable: ' + fullname, name=fullname)
        if not spec.origin or not trusted_path(spec.origin):
            raise ImportError('untrusted frozen collector module origin: ' + fullname)
        return spec

sys.meta_path[:] = [BuiltinImporter, FrozenImporter, StdlibOnly]
payload = json.load(sys.stdin)
payload['files'] = {name: base64.b64decode(raw, validate=True) for name, raw in payload['files'].items()}
entry = payload['manifest']['files']['adapter']['path']
namespace = {'__name__': '__frozen_collector__', '__file__': entry}
exec(compile(payload['files']['adapter'], entry, 'exec'), namespace)
raise SystemExit(namespace['main'](payload))
'''


def frozen_collector_binding(args, command: Sequence[str]) -> dict:
    """Validate an explicitly reviewed C1 task manifest; return captured bytes.

    No host paths or Git objects are built in. The CLI manifest SHA is a separate
    trust anchor selected after review, not a hash supplied by the manifest itself.
    Call again inside the quiet lease immediately before dispatch. A content hash
    binds identity; it is not a substitute for review of the external adapter.
    """
    if args.json is not None:
        raise PerfError('frozen collector: outer --json is forbidden')
    def exact_path(value):
        if not isinstance(value, str) or not value:
            raise PerfError('frozen collector: missing path')
        path = Path(value)
        if not path.is_absolute() or path.is_symlink() or path.resolve() != path.absolute():
            raise PerfError(f'frozen collector: relative or redirected path: {value}')
        return path

    def checked_bytes(path, expected):
        if not isinstance(expected, str) or not re.fullmatch('[0-9a-f]{64}', expected):
            raise PerfError('frozen collector: missing complete SHA256')
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise PerfError(f'frozen collector: SHA256 mismatch: {path}')
        return raw

    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise PerfError(f'frozen collector: duplicate manifest key: {key}')
            result[key] = value
        return result

    manifest_path = exact_path(str(args.frozen_collector))
    raw = checked_bytes(manifest_path, args.frozen_collector_sha256)
    data = json.loads(raw, object_pairs_hook=unique_keys)
    keys = {'schema', 'cwd', 'argv', 'files', 'contract', 'builds', 'distro'}
    if not isinstance(data, dict) or set(data) != keys or data['schema'] != 'gx-c1-frozen-collector-v3':
        raise PerfError('frozen collector: unknown manifest schema/fields')
    if not isinstance(data['distro'], str) or not data['distro'] or args.distro != data['distro']:
        raise PerfError('frozen collector: outer distro differs from reviewed manifest')
    cwd = exact_path(data['cwd'])
    if not cwd.is_dir() or Path.cwd().resolve() != cwd:
        raise PerfError('frozen collector: measurement cwd mismatch')
    if data['contract'] != FROZEN_C1_CONTRACT or not isinstance(data['builds'], dict) or set(data['builds']) != {'base', 'gate', 'combined'}:
        raise PerfError('frozen collector: C1 contract or frozen builds missing')
    files = data['files']
    if not isinstance(files, dict) or set(files) != set(FROZEN_C1_FILES):
        raise PerfError('frozen collector: incomplete file manifest')
    buffers = {}
    for name in FROZEN_C1_FILES:
        item = files[name]
        if not isinstance(item, dict) or set(item) != {'path', 'sha256'}:
            raise PerfError('frozen collector: malformed file identity')
        path = exact_path(item['path'])
        if name != 'adapter' and path != cwd / 'scripts' / name:
            raise PerfError('frozen collector: wrapper/module location mismatch')
        buffers[name] = checked_bytes(path, item['sha256'])
    argv = data['argv']
    if not isinstance(argv, list) or not all(isinstance(v, str) for v in argv) or list(command) != argv or len(argv) != 9:
        raise PerfError('frozen collector: argv differs from reviewed manifest')
    if argv[:3] != [sys.executable, files['adapter']['path'], 'gtk'] or sorted(argv[3::2]) != ['--json', '--out', '--pair']:
        raise PerfError('frozen collector: only the pinned direct Python C1 invocation is allowed')
    options = dict(zip(argv[3::2], argv[4::2]))
    if options['--pair'] not in ('base-vs-gate', 'gate-vs-combined'):
        raise PerfError('frozen collector: unknown pair')
    out, report = exact_path(options['--out']), exact_path(options['--json'])
    batch_out = exact_path(str(args.out))
    if out != batch_out / 'measure' or report != batch_out / 'measurement-result.json':
        raise PerfError('frozen collector: outputs differ from owned quiet batch')
    for path in (out, report, batch_out / 'collector-identity.json', batch_out / 'collector-outcome.json'):
        exact_path(str(path))
        if path.exists():
            raise PerfError(f'frozen collector: output must be fresh: {path}')
    payload = json.dumps({'manifest': data, 'manifest_sha256': args.frozen_collector_sha256,
                          'files': {name: base64.b64encode(content).decode('ascii') for name, content in buffers.items()}},
                         allow_nan=False).encode('utf-8')
    return {'payload': payload, 'argv': [sys.executable, '-I', '-S', '-B', '-c', FROZEN_COLLECTOR_BOOTSTRAP],
            'evidence': {'manifest_path': str(manifest_path), 'manifest_sha256': args.frozen_collector_sha256,
                         'files': files, 'cwd': str(cwd), 'distro': data['distro'], 'requested_argv': argv,
                         'payload_sha256': hashlib.sha256(payload).hexdigest(),
                         'bootstrap_sha256': hashlib.sha256(FROZEN_COLLECTOR_BOOTSTRAP.encode()).hexdigest()}}


def gate_exit_contract(command: Sequence[str]) -> bool:
    """Whether exit 4 means an absolute gate FAIL (including direct GTK P2/P4).
    gx_perf.py win32-* drivers promise that (run_experiment), run as
    `python ... gx_perf.py win32-ui ...` or `just perf win32-ui ...` (just passes the
    exit code through). Direct GTK P2/P4 includes just calls normalized by observe mode.
    Exit 4 of anything else is not a measured FAIL."""
    # Interpret GTK options with the actual parser, not a token search: --case
    # may also occur as an option value. Never unwrap a shell or module launcher.
    if len(command) >= 3 and process_name(command[1]) == 'gx_perf.py' and command[2] == 'gtk':
        if process_name(command[0]).removesuffix('.exe') not in ('python', 'python3', 'py') and command[0] != sys.executable:
            return False
        import contextlib
        import io
        try:
            with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                args = build_parser().parse_args(list(command[2:]))
        except SystemExit:
            return False
        return args.case in ('p2', 'p4')
    names = [process_name(part) for part in command]
    for index in range(len(command) - 1):
        if command[index + 1] not in WIN32_DRIVERS:
            continue
        if names[index] == 'gx_perf.py' or (names[index] == 'perf' and 'just' in names[:index]):
            return True
    return False


def normalize_observe_command(command: Sequence[str]) -> list[str]:
    """Remove the just recipe's second shell interpretation, preserving measurement cwd.
    In C1 the collector lives outside the frozen measurement checkout. Resolve its recipes
    against the caller's cwd, never this collector's SCRIPTS; retain every trailing argv verbatim.
    """
    if len(command) >= 2 and process_name(command[0]).removesuffix('.exe') == 'just':
        if command[1] in ('perf', 'wsl'):
            script = Path.cwd() / 'scripts' / f'gx_{command[1]}.py'
            return [sys.executable, str(script), *command[2:]]
    return list(command)


def desktop_command(command: Sequence[str]) -> bool:
    """Check normalized argv; require desktop input gates unless a direct Xvfb entry is allowlisted.
    Shell wrappers, Python module/command execution and unknown scripts are never unwrapped.
    """
    if len(command) < 3:
        return True
    launcher = process_name(command[0]).removesuffix('.exe')
    entry = process_name(command[1])
    if launcher in ('python', 'python3', 'py') or command[0] == sys.executable:
        if entry not in ('gx_perf.py', 'gx_wsl.py'):
            return True
    else:
        return True
    if entry == 'gx_perf.py':
        return command[2] != 'gtk'
    # Only gx_wsl global options may precede its subcommand. Do not search arbitrary argv
    # for a token such as 'smoke': it could be a wrapper's argument or an option value.
    index = 2
    while index < len(command):
        value = command[index]
        if value in ('--clone', '--distro') and index + 1 < len(command):
            index += 2
        elif value.startswith(('--clone=', '--distro=')) or value == '--dry-run':
            index += 1
        else:
            return value not in ('smoke', 'scenario')
    return True


def driver_out_dir(command: Sequence[str]) -> Path | None:
    """The --out directory of a gx_perf.py win32-* driver command, the measurement quiet-batch runs."""
    if not gate_exit_contract(command) and not any(
            process_name(command[index]) in ('gx_perf.py', 'perf') and command[index + 1] == 'win32'
            for index in range(len(command) - 1)):
        return None
    for index, part in enumerate(command):
        if part == '--out' and index + 1 < len(command):
            return Path(command[index + 1])
        if part.startswith('--out='):
            return Path(part[len('--out='):])
    return None


def product_failure_runs(out_dir: Path | None, rows: Sequence[Mapping]) -> list[dict]:
    """The driver arm and run that started the instance of each product failure row: the run.json
    under out_dir (LABEL/run-NN/run.json of run_experiment) whose pid is the row's instance_pid;
    label and run stay None when no such run.json exists (another command, or a pid it never wrote)."""
    runs: dict[int, dict] = {}
    if out_dir is not None and out_dir.is_dir():
        for path in sorted(set(out_dir.glob('*/run-*/run.json')) | set(out_dir.glob('*/*.json')) |
                           set(out_dir.glob('*/*/run-*/run.json'))):
            try:
                report = json.loads(path.read_text(encoding='utf-8'))
            except (OSError, ValueError):
                continue
            if isinstance(report, dict) and isinstance(report.get('pid'), int):
                runs[report['pid']] = {'label': report.get('label'), 'run': report.get('run'),
                                       'baseline': bool(report.get('baseline')), 'path': path.parent.relative_to(out_dir).as_posix()}
    unknown = {'label': None, 'run': None, 'baseline': None, 'path': None}
    return [{'instance_pid': pid, **runs.get(pid, unknown)} for pid in dict.fromkeys(row.get('instance_pid') for row in rows)]


def measurement_state(raised: bool, exit_code, gate_contract: bool = True) -> str:
    """The command's own result: 0 complete, 4 absolute gate FAIL (recognized drivers),
    anything else a driver/tool error."""
    if raised or exit_code is None:
        return 'DRIVER_ERROR'
    if exit_code == 4 and not gate_contract:
        return 'DRIVER_ERROR'
    return {0: 'COMPLETE', 4: 'GATE_FAIL'}.get(exit_code, 'DRIVER_ERROR')


def classify_batch(result: dict, before: dict, after: dict, *, mode_mismatch: bool | str, product_failures: Sequence[Mapping] = (),
                   failure_runs: Sequence[Mapping] = ()) -> None:
    """Quiet validity comes only from the checks; the measurement only from the command.
    INVALID means a quiet criterion failed; a gate FAIL under valid checks stays FAIL.
    A measured instance that ended, hung or activated itself mid-batch (PRODUCT_CAUSES) is PRODUCT_FAIL
    even when the environment was also noisy: reading it as INVALID would invite rerunning until it
    passes."""
    statuses = {name: row['status'] for name, row in after['checks'].items()}
    quiet = 'INVALID' if 'fail' in statuses.values() else 'ERROR' if 'error' in statuses.values() else 'VALID'
    result['quiet_status'], result['quiet_valid'] = quiet, quiet == 'VALID'
    result['failed_checks'] = sorted(name for name, status in statuses.items() if status == 'fail')
    result['error_checks'] = sorted(name for name, status in statuses.items() if status == 'error')
    thresholds = before['thresholds_plan_compliant'] and after['thresholds_plan_compliant']
    result['plan_compliant'] = result['quiet_valid'] and thresholds
    if result['measurement'] == 'DRIVER_ERROR' and result['command_exit'] is not None:
        result['errors'].append(f"command exited {result['command_exit']}: driver or tool error")
    input_check = after['checks'].get('input', {})
    if product_failures:
        first = product_failures[0]
        cause = first.get('cause') if first.get('cause') in PRODUCT_CAUSES else 'instance_gone'
        what = {'instance_hung': 'hangs or crashed',
                'instance_self_activated': 'activated or restored itself without input'}.get(cause, 'ended or changed identity')
        result['failure_cause'] = cause
        result['product_failure_runs'] = list(failure_runs)
        arm = next((item for item in failure_runs if item.get('instance_pid') == first.get('instance_pid')), None)
        if arm and arm.get('label') is not None:
            where = f" in arm {arm['label']} run {arm['run']}" + (" (the historical arm)" if arm.get('baseline') else "")
        else:
            where = " (arm unknown: no driver run.json names that pid)"
        result['errors'].append(f"{cause}: Ghostty pid {first.get('instance_pid')} {what} mid-batch{where}: "
                                f"{first.get('reason')}")
        result['status'], result['exit'] = 'PRODUCT_FAIL', 6
    elif mode_mismatch:
        result['failure_cause'] = 'mode_mismatch'
        result['errors'].append(mode_mismatch if isinstance(mode_mismatch, str) else
                                'the command injected guarded input but --injected-input was not given; rerun with --injected-input')
        result['status'], result['exit'] = 'ERROR', 2
    elif quiet == 'INVALID':
        result['failure_cause'] = (input_check.get('raw') or {}).get('cause') if input_check.get('status') == 'fail' else None
        result['failure_cause'] = result['failure_cause'] or 'quiet_criteria'
        result['errors'].append('end check did not pass; entire batch is INVALID, originals retained')
        result['status'], result['exit'] = 'INVALID', 3
    elif quiet == 'ERROR':
        result['failure_cause'] = 'end_check_error'
        result['errors'].append('end check raised a tool error; quiet validity is unproved')
        result['status'], result['exit'] = 'ERROR', 2
    elif result['measurement'] == 'DRIVER_ERROR':
        result['failure_cause'] = 'driver_error'
        result['status'], result['exit'] = 'ERROR', 2
    elif not thresholds:
        result['status'], result['exit'] = 'NONCOMPLIANT', 5
    elif result['measurement'] == 'GATE_FAIL':
        result['failure_cause'] = 'gate_fail'
        result['status'], result['exit'] = 'FAIL', 4
    else:
        result['status'], result['exit'] = 'VALID', 0


def batch_summary(result: Mapping, before: Mapping | None, after: Mapping | None) -> str:
    lines = [f"{result['status']} exit={result['exit']} quiet={result['quiet_status']} measurement={result['measurement']} "
             f"command_exit={result['command_exit']} plan_compliant={str(result['plan_compliant']).lower()} "
             f"failure_cause={result.get('failure_cause') or 'none'}",
             BATCH_GUIDANCE.get(result['status'], ''),
             f"criteria: {result.get('criteria')} " + ' '.join(f'{key}={str(value).lower()}' for key, value in
                                                               (result.get('criteria_options') or {}).items())]
    for name, snapshot in (('before', before), ('after', after)):
        if snapshot:
            lines.append(f'{name}: ' + ', '.join(f"{key}={row['status']}" for key, row in snapshot['checks'].items()))
    return '\n'.join([*lines, *result['errors']]) + '\n'


def run_quiet_batch(args, probe=None, execute=None) -> int:
    import gx_slots
    probe = probe or QuietProbe()
    command = args.batch_command[1:] if args.batch_command[:1] == ['--'] else args.batch_command
    if not command or not math.isfinite(args.timeout) or args.timeout < 0 or not math.isfinite(args.idle_seconds) or args.idle_seconds < 0:
        raise PerfError('quiet-batch requires a command and finite nonnegative timeout/idle threshold')
    observe_input = bool(getattr(args, 'input_observe_only', False))
    frozen = bool(getattr(args, 'frozen_collector', None))
    if frozen != bool(getattr(args, 'frozen_collector_sha256', None)):
        raise PerfError('--frozen-collector and its explicit SHA256 are both required')
    if frozen and not observe_input:
        raise PerfError('--frozen-collector requires --input-observe-only')
    if observe_input and args.injected_input:
        raise PerfError('--input-observe-only and --injected-input are mutually exclusive')
    requested_command = list(command)
    if frozen:
        frozen_collector_binding(args, command)  # fail fast only; never reuse this authorization after waiting
    elif observe_input:
        command = normalize_observe_command(command)
    if observe_input and not frozen and desktop_command(command):
        raise PerfError('--input-observe-only requires a direct gx_perf gtk or gx_wsl smoke/scenario command '
                        '(including just perf/just wsl); this command drives the Windows desktop or is not '
                        'allowlisted: run it without --input-observe-only')
    out = new_output(args.out)
    guard_log = out / 'guards.jsonl'
    result = {'schema': 'gx-quiet-batch-v2', 'batch_id': uuid.uuid4().hex, 'command': command,
              'requested_command': requested_command, 'command_cwd': str(Path.cwd()),
              'injected_input': args.injected_input, 'input_observe_only': observe_input, 'criteria': QUIET_CRITERIA,
              'criteria_options': {'strict_blacklist': bool(getattr(args, 'strict_blacklist', False)),
                                   'input_observe_only': observe_input},
              'status': 'NOT_STARTED', 'exit': 2,
              'quiet_status': 'NOT_CHECKED', 'quiet_valid': False, 'measurement': 'NOT_RUN', 'command_exit': None,
              'plan_compliant': False, 'thresholds_plan_compliant': thresholds_plan_compliant(args),
              'gate_exit_contract': frozen or gate_exit_contract(command),
              'failure_cause': None, 'started_ns': None, 'ended_ns': None, 'errors': []}
    before = after = None
    write_json(out / 'RESULT.json', result)
    try:
        args.slot_root = validate_slot_root(args.slot_root or shared_slots_root())
        result['preflight'] = batch_preflight(args, probe)
        write_json(out / 'RESULT.json', result)
        # Wait first, then check inside the lease. Neither the preflight nor a
        # previous quiet snapshot authorizes running after waiting for resources.
        with gx_slots.acquire(args.slot_root, 'quiet', args.timeout) as lease:
            before = quiet_snapshot(args, probe, lease=lease)
            write_json(out / 'before.json', before)
            if before['exit']:
                result['quiet_status'] = 'NOT_MET' if before['exit'] == 3 else 'ERROR'
                result['exit'] = before['exit']
                result['errors'].append('start check did not pass; command was not run')
            else:
                environment = dict(os.environ, GX_PERF_BATCH_ID=result['batch_id'], GX_PERF_GUARD_LOG=str(guard_log))
                result.update(status='RUNNING', started_ns=time.time_ns())
                write_json(out / 'RESULT.json', result)
                raised = False
                try:
                    binding = frozen_collector_binding(args, command) if frozen else None
                    if binding:
                        result['frozen_collector'] = binding['evidence']
                        write_json(out / 'RESULT.json', result)
                    with (out / 'command.log').open('w', encoding='utf-8', newline='\n') as log:
                        runner = execute or subprocess.run
                        child = (runner(binding['argv'], input=binding['payload'], cwd=Path.cwd(),
                                        env=environment, stdout=log, stderr=subprocess.STDOUT, shell=False)
                                 if binding else runner(command, env=environment, stdout=log, stderr=subprocess.STDOUT, shell=False))
                        result['command_exit'] = child.returncode
                except (Exception, KeyboardInterrupt) as exc:
                    raised = True
                    result['errors'].append(f'command: {type(exc).__name__}: {exc}')
                finally:
                    result['ended_ns'] = time.time_ns()
                    result['measurement'] = measurement_state(raised, result['command_exit'], result['gate_exit_contract'])
                    if result['command_exit'] == 4 and not result['gate_exit_contract']:
                        result['errors'].append('exit 4 means an absolute gate FAIL only for gx_perf.py win32-* drivers or direct gtk --case p2/p4; '
                                                'this command is not one, so it is a driver/tool error')
                    try:
                        evidence = guard_evidence(guard_log, result['batch_id'])
                    except Exception as exc:  # the end check's input item reports it as an error
                        evidence = exc
                    end = {'evidence': evidence, 'since': before['checks']['input']['raw'], 'injected_mode': args.injected_input}
                    after = quiet_snapshot(args, probe, lease=lease, end=end)
                    write_json(out / 'after.json', after)
                    if observe_input:
                        # A WSL/Xvfb batch never touches the Windows desktop: any guard row says it did.
                        rows = evidence['events'] if isinstance(evidence, dict) else 0
                        mismatch = rows and (f'--input-observe-only is only for batches that never touch the Windows '
                                             f'desktop, but the command wrote {rows} gx_win_gui guard row(s); run it as a '
                                             'desktop batch without --input-observe-only')
                    else:
                        # Input was sent although the batch claimed none: the last-input check is meaningless.
                        mismatch = not args.injected_input and isinstance(evidence, dict) and evidence['injected']
                    product = evidence['product'] if isinstance(evidence, dict) else ()
                    classify_batch(result, before, after, mode_mismatch=mismatch, product_failures=product,
                                   failure_runs=product_failure_runs(driver_out_dir(command), product) if product else ())
    except TimeoutError as exc:
        result.update(exit=3, quiet_status='NOT_MET')
        result['errors'].append(f'slots: {exc}')
    except Exception as exc:
        result['exit'] = 2
        result['errors'].append(f'{type(exc).__name__}: {exc}')
        if result['status'] == 'RUNNING':
            result['status'] = 'ERROR'
    result['guidance'] = BATCH_GUIDANCE.get(result['status'], '')
    write_json(out / 'RESULT.json', result)
    write_json(args.json, result)
    (out / 'SUMMARY.txt').write_text(batch_summary(result, before, after), encoding='utf-8', newline='\n')
    print(json.dumps(result, ensure_ascii=False))
    return result['exit']


# Fixed-width Windows ABI fields keep the raw snapshot decoder testable off Windows.
class NativeThread(ctypes.Structure):
    _fields_ = [("kernel", ctypes.c_int64), ("user", ctypes.c_int64), ("birth", ctypes.c_int64),
                ("wait", ctypes.c_uint32), ("start", ctypes.c_void_p), ("pid", ctypes.c_void_p),
                ("tid", ctypes.c_void_p), ("priority", ctypes.c_int32), ("base_priority", ctypes.c_int32),
                ("switches", ctypes.c_uint32), ("state", ctypes.c_uint32), ("reason", ctypes.c_uint32)]


class NativeString(ctypes.Structure):
    _fields_ = [("length", ctypes.c_uint16), ("maximum", ctypes.c_uint16), ("buffer", ctypes.c_void_p)]


class NativeProcess(ctypes.Structure):
    _fields_ = [("next", ctypes.c_uint32), ("threads", ctypes.c_uint32), ("private_ws", ctypes.c_int64),
                ("faults", ctypes.c_uint32), ("high_threads", ctypes.c_uint32), ("cycles", ctypes.c_uint64),
                ("birth", ctypes.c_int64), ("user", ctypes.c_int64), ("kernel", ctypes.c_int64),
                ("image", NativeString), ("priority", ctypes.c_int32), ("pid", ctypes.c_void_p),
                ("parent", ctypes.c_void_p), ("handles", ctypes.c_uint32), ("session", ctypes.c_uint32),
                ("key", ctypes.c_size_t), ("peak_virtual", ctypes.c_size_t), ("virtual", ctypes.c_size_t),
                ("page_faults", ctypes.c_uint32)] + [(name, ctypes.c_size_t) for name in
                ("peak_ws", "ws", "peak_paged", "paged", "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile", "private")] + [
                (name, ctypes.c_int64) for name in ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]


class ProcessMemory(ctypes.Structure):
    _fields_ = [("cb", ctypes.c_uint32), ("faults", ctypes.c_uint32)] + [(name, ctypes.c_size_t) for name in
                ("peak_ws", "ws", "peak_paged", "paged", "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile", "private")]


def decode_threads(raw: bytes, pid: int) -> dict:
    offset = 0
    header, stride = ctypes.sizeof(NativeProcess), ctypes.sizeof(NativeThread)
    while offset + header <= len(raw):
        item = NativeProcess.from_buffer_copy(raw, offset)
        end = offset + item.next if item.next else len(raw)
        if end > len(raw) or end < offset + header or offset + header + item.threads * stride > end:
            raise PerfError("truncated SystemProcessInformation")
        if item.pid == pid:
            rows = []
            for i in range(item.threads):
                thread = NativeThread.from_buffer_copy(raw, offset + header + i * stride)
                if thread.pid != pid or not thread.tid:
                    raise PerfError("invalid SYSTEM_THREAD_INFORMATION identity")
                rows.append({"tid": thread.tid, "birth": thread.birth, "switches": thread.switches})
            return {"birth": item.birth, "threads": rows}
        if not item.next:
            break
        offset = end
    raise PerfError(f"pid {pid} missing from SystemProcessInformation")


class NativeCounters:
    """GetProcessTimes / PrivateUsage and NT endpoint thread context-switch counters."""
    def __init__(self, gui):
        self.w = gui.win32()
        self.nt = ctypes.WinDLL("ntdll").NtQuerySystemInformation
        self.nt.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
        self.nt.restype = ctypes.c_int32
        self.memory = ctypes.WinDLL("psapi", use_last_error=True).GetProcessMemoryInfo
        self.memory.argtypes = [ctypes.c_void_p, ctypes.POINTER(ProcessMemory), ctypes.c_uint32]
        self.memory.restype = ctypes.c_int32

    def threads(self, pid: int) -> dict:
        length = 1024 * 1024
        for _ in range(8):
            buffer = ctypes.create_string_buffer(length)
            needed = ctypes.c_uint32()
            status = self.nt(5, buffer, length, ctypes.byref(needed))  # SystemProcessInformation
            if status == 0:
                return decode_threads(buffer.raw[:needed.value], pid)
            if status & 0xFFFFFFFF != 0xC0000004:
                raise PerfError(f"NtQuerySystemInformation failed: {status & 0xFFFFFFFF:#x}")
            length = max(length * 2, needed.value + 65536)
        raise PerfError("SystemProcessInformation kept growing")

    def sample(self, instance) -> dict:
        instance.ensure_owned()
        began = time.perf_counter_ns()
        handle = self.w._open(instance.pid, 0x0400 | 0x0010)
        if not handle:
            raise PerfError("cannot open owned process for counters")
        try:
            created, exited, kernel, user = (self.w.FILETIME() for _ in range(4))
            if not self.w.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel), ctypes.byref(user)):
                raise ctypes.WinError(ctypes.get_last_error())
            value = lambda ft: (ft.high << 32) | ft.low
            if value(created) != instance.creation:
                raise PerfError("process birth changed during counter read")
            memory = ProcessMemory()
            memory.cb = ctypes.sizeof(memory)
            if not self.memory(handle, ctypes.byref(memory), memory.cb):
                raise ctypes.WinError(ctypes.get_last_error())
            thread_error = None
            try:
                threads = self.threads(instance.pid)
            except Exception as exc:
                threads = {'birth': instance.creation, 'threads': []}
                thread_error = f'{type(exc).__name__}: {exc}'
            if threads['birth'] != instance.creation:
                raise PerfError("NT process birth differs from held process")
            instance.ensure_owned()
            return {"begin_ns": began, "end_ns": time.perf_counter_ns(), "pid": instance.pid,
                    "birth": value(created), "kernel_100ns": value(kernel), "user_100ns": value(user),
                    "private_bytes": memory.private, "thread_count": None if thread_error else len(threads['threads']),
                    "threads": threads['threads'], 'thread_error': thread_error}
        finally:
            self.w.CloseHandle(handle)

    def gpu(self, instance) -> dict:
        instance.ensure_owned()
        result = gpu_memory(instance.pid)
        instance.ensure_owned()
        return result


def gpu_memory(pid: int) -> dict:
    pdh = ctypes.WinDLL("pdh")
    handle = ctypes.c_void_p
    dword = ctypes.c_uint32
    class Raw(ctypes.Structure):
        _fields_ = [("status", dword), ("time", dword * 2), ("first", ctypes.c_int64),
                    ("second", ctypes.c_int64), ("multi", dword)]
    class Item(ctypes.Structure):
        _fields_ = [("name", ctypes.c_wchar_p), ("raw", Raw)]
    def bind(name, *args):
        fn = getattr(pdh, name)
        fn.argtypes, fn.restype = list(args), dword
        return fn
    open_query = bind('PdhOpenQueryW', ctypes.c_wchar_p, ctypes.c_size_t, ctypes.POINTER(handle))
    add = bind('PdhAddEnglishCounterW', handle, ctypes.c_wchar_p, ctypes.c_size_t, ctypes.POINTER(handle))
    collect_data = bind('PdhCollectQueryData', handle)
    array = bind('PdhGetRawCounterArrayW', handle, ctypes.POINTER(dword), ctypes.POINTER(dword), ctypes.c_void_p)
    close = bind('PdhCloseQuery', handle)
    def check(status):
        if status:
            raise PerfError(f"PDH GPU counter failed: {status:#x}")
    query, counter = handle(), handle()
    check(open_query(None, 0, ctypes.byref(query)))
    path = rf"\GPU Process Memory(pid_{pid}_*)\Dedicated Usage"
    try:
        check(add(query, path, 0, ctypes.byref(counter)))
        check(collect_data(query))
        size, count = dword(), dword()
        status = array(counter, ctypes.byref(size), ctypes.byref(count), None)
        if status != 0x800007D2 or not size.value:  # PDH_MORE_DATA
            raise PerfError(f"GPU instances unavailable: {status:#x}")
        buffer = ctypes.create_string_buffer(size.value)
        check(array(counter, ctypes.byref(size), ctypes.byref(count), buffer))
        rows = []
        for item in ctypes.cast(buffer, ctypes.POINTER(Item * count.value)).contents:
            if item.raw.status not in (0, 1) or item.raw.first < 0 or not item.name.startswith(f'pid_{pid}_'):
                raise PerfError("invalid or foreign GPU counter instance")
            rows.append({"name": item.name, "bytes": item.raw.first})
        if not rows:
            raise PerfError("no GPU Process Memory instances for owned process")
        return {"path": path, "instances": rows, "dedicated_bytes": sum(row['bytes'] for row in rows)}
    finally:
        close(query)


def idle_delta(before: dict, after: dict) -> dict:
    if (before['pid'], before['birth']) != (after['pid'], after['birth']):
        raise PerfError("idle process identity changed")
    cpu_parts = [after[k] - before[k] for k in ('kernel_100ns', 'user_100ns')]
    cpu = sum(cpu_parts) / 10000
    if any(value < 0 for value in cpu_parts) or after['begin_ns'] < before['end_ns']:
        raise PerfError("negative process CPU delta")
    result = {"process.cpu": (cpu, "ms"), "idle.wall": ((after['begin_ns'] - before['end_ns']) / 1e6, "ms")}
    switches = context_switch_diagnostic(before, after)
    if switches['status'] == 'endpoint_complete':
        result['threads.context_switches'] = (switches['matched_switches'], '')
    return result


def context_switch_diagnostic(before, after) -> dict:
    if before.get('thread_error') or after.get('thread_error'):
        return {'status': 'unavailable', 'errors': [before.get('thread_error'), after.get('thread_error')],
                'scope': 'thread counters are diagnostic only, not a P2 gate'}
    old = {(row['tid'], row['birth']): row['switches'] for row in before['threads']}
    new = {(row['tid'], row['birth']): row['switches'] for row in after['threads']}
    return {'status': 'endpoint_complete' if old.keys() == new.keys() else 'partial',
            'matched_switches': sum((new[k] - old[k]) & 0xFFFFFFFF for k in old.keys() & new.keys()),
            'added_threads': sorted(new.keys() - old.keys()), 'removed_threads': sorted(old.keys() - new.keys()),
            'scope': 'diagnostic surviving endpoint threads; transient threads unobservable; not a P2 gate'}


UI_KEYS = {"palette": "ctrl+shift+p", "menu": "ctrl+shift+m", "settings": "ctrl+comma", "keybinds": "ctrl+shift+slash"}


def keybind_frames(text: str) -> list[dict]:
    """Each paint timing ends a frame; count layouts since the previous paint on that thread."""
    pending, frames = {}, []
    for line in text.splitlines():
        match = re.match(r"^\d{2}:\d{2}:\d{2}\.\d{3} \[(\d+)\] ", line)
        thread = match.group(1) if match else "unstamped"
        samples = parse_text(line)
        pending[thread] = pending.get(thread, 0) + sum(samples.values.get('d2d.layout_create', []))
        if 'keybinds.paint' in samples.values:
            frames.append({"thread": thread, "layouts": pending[thread], "paint_ms": samples.values['keybinds.paint'][0]})
            pending[thread] = 0
    return frames


def wait_until(predicate, description: str, timeout: float = 10):
    deadline = time.monotonic() + timeout
    while True:
        result = predicate()
        if result:
            return result
        if time.monotonic() >= deadline:
            raise PerfError(f"timeout waiting for {description}")
        time.sleep(0.02)


def open_ui(instance, name: str):
    previous = {popup.hwnd for popup in instance.popups() if popup.cls == 'GhosttyGxPopup'}
    instance.press(UI_KEYS[name])
    return wait_until(lambda: next((p for p in instance.popups() if p.cls == 'GhosttyGxPopup' and p.hwnd not in previous), None), name)


def arm_samples(text: str, baseline: bool = False) -> Samples:
    if baseline:
        text = re.sub(r'(\(gx_perf\):\s+)scrollbar\.paint(?=\s+\d+(?:\.\d+)?\s*(?:ns|us|ms|s)\b)',
                      r'\1scrollbar.paint_time', text)
    return parse_text(text)


def historical_names(samples: Samples) -> Samples:
    if samples.units.get('scrollbar.paint') == 'ms':
        for value in samples.values.pop('scrollbar.paint'):
            samples.add('scrollbar.paint_time', value, 'ms')
        del samples.units['scrollbar.paint']
    return samples


def metric_capabilities(values: Sequence[str], labels, exes) -> dict:
    result = {label: {} for label in labels}
    for value in values:
        label, separator, path = value.partition(':')
        if not separator or label not in result:
            raise PerfError('--capabilities requires LABEL:JSON_FILE')
        data = read_json(Path(path))
        if data.get('exe_sha256') != hashlib.sha256(exes[labels.index(label)].read_bytes()).hexdigest():
            raise PerfError(f'{path}: capability declaration does not match measured executable')
        metrics = data.get('metrics')
        if not isinstance(metrics, dict) or any(not isinstance(name, str) or unit not in ('', 'ms') for name, unit in metrics.items()):
            raise PerfError(f'{path}: metrics must map names to normalized units (ms or empty string)')
        result[label] = metrics
    return result


def close_ui(instance):
    instance.press('escape')
    wait_until(lambda: not any(p.cls == 'GhosttyGxPopup' for p in instance.popups()), 'popup close')
    time.sleep(0.25)


def main_windows(gui, instance):
    return [w for w in instance.windows() if w.cls == gui.WINDOW_CLASS and not w.toolwindow]


def populate(gui, instance, tabs: int, windows: int):
    """All terminals belong to one owned PID; creation uses default keybindings."""
    for window_index in range(windows):
        if window_index:
            previous = {w.hwnd for w in main_windows(gui, instance)}
            instance.press('ctrl+shift+n')
            current = wait_until(lambda: next((w for w in main_windows(gui, instance)
                                              if w.hwnd not in previous and w.visible and not w.cloaked), None), 'new window')
        else:
            current = instance.require_window()
        if not gui.win32().activate(current.hwnd):
            raise gui.InputBlocked('cannot activate the owned window')
        for _ in range(tabs - 1):
            before = {w.hwnd for w in gui.win32().child_windows(current.hwnd, gui.TERMINAL_CLASS)}
            instance.press(NEW_TAB_KEYS)
            wait_until(lambda: any(w.hwnd not in before and w.visible for w in
                                   gui.win32().child_windows(current.hwnd, gui.TERMINAL_CLASS)), 'new tab')
        actual = len(gui.win32().child_windows(current.hwnd, gui.TERMINAL_CLASS))
        if actual != tabs:
            raise PerfError(f"expected {tabs} terminal children, found {actual}")
    if len(main_windows(gui, instance)) != windows:
        raise PerfError('window count differs from requested topology')
    time.sleep(1)


class CaptureRun:
    def __init__(self, instance, target: Path, report: dict):
        self.instance, self.target, self.report = instance, target, report
        self.samples = Samples()
        report['windows'] = []
        report['observations'] = {}
        report['missing_metrics'] = {}

    def parse(self, text):
        return arm_samples(text, self.report.get('baseline', False))

    def supported(self, name, unit='') -> bool:
        observed = self.parse(self.mark().decode('utf-8', errors='strict'))
        declared = self.report.get('capabilities', {})
        actual = observed.units.get(name, declared.get(name))
        if actual is not None:
            if actual != unit:
                raise PerfError(f'{name}: time/count unit conflict within this arm')
            self.report['missing_metrics'].pop(name, None)
            return True
        self.missing(name, unit)
        return False

    def missing(self, name, unit='', *, required=True):
        self.report['missing_metrics'][name] = {'status': 'not_instrumented', 'n': 0, 'unit': unit}
        if required and not self.report.get('baseline') and not self.report.get('diagnostic', True):
            raise PerfError(f'{name}: instrumentation unproved; provide a hash-bound --capabilities declaration for zero-event counters')

    def drain(self, names: Sequence[str], minimum: float = 0.3, quiet: float = 0.3, timeout: float = 3):
        began = last_change = time.monotonic()
        previous = None
        while True:
            observed = self.parse(self.mark().decode('utf-8', errors='strict'))
            signature = tuple((name, tuple(observed.values.get(name, []))) for name in names)
            now = time.monotonic()
            if signature != previous:
                previous, last_change = signature, now
            if now - began >= minimum and now - last_change >= quiet:
                self.report.setdefault('drains', []).append({'metrics': list(names), 'seconds': now - began,
                                                             'quiet_seconds': quiet, 'status': 'settled'})
                return True
            if now - began >= timeout:
                # Still changing at the limit: count what the window holds and let the
                # numerical gate judge it, so a real regression is a FAIL, not a driver error.
                self.report.setdefault('drains', []).append({'metrics': list(names), 'seconds': now - began,
                                                             'quiet_seconds': quiet, 'status': 'timeout'})
                self.report['measurement_unsettled'] = True
                return False
            time.sleep(0.05)

    def mark(self) -> bytes:
        return self.instance.log.read_bytes() if self.instance.log.exists() else b''

    def window(self, name: str, before: bytes) -> str:
        after = self.mark()
        if not after.startswith(before):
            raise PerfError('log truncated or replaced during measurement')
        text = after[len(before):].decode('utf-8', errors='strict')
        self.report['windows'].append({'name': name, 'start_byte': len(before), 'end_byte': len(after)})
        return text

    def add(self, name: str, value: float, unit: str = ''):
        self.samples.add(name, value, unit or None)

    def count(self, text: str, name: str, *, required=True):
        parsed = self.parse(text)
        if name in parsed.units and parsed.units[name]:
            raise PerfError(f'{name}: expected an unscaled count')
        values = parsed.values.get(name, [])
        if not values and not required:
            full = self.parse(self.mark().decode('utf-8', errors='strict'))
            supported = full.units.get(name, self.report.get('capabilities', {}).get(name)) == ''
            if not supported:
                self.missing(name, required=False)
        else:
            supported = bool(values) or self.supported(name)
        if supported:
            self.add(name, sum(values))
        if name == 'scrollbar.paint' and 'scrollbar.paint_time' in parsed.values:
            for value in parsed.values['scrollbar.paint_time']:
                self.add('scrollbar.paint_time', value, 'ms')
        self.report['observations'][name] = {'events': len(values), 'status': 'observed' if supported else 'not_instrumented',
                                            'zero_requires_support': True}

    def screenshot(self, name: str, info=None):
        info = info or self.instance.require_window()
        self.instance.capture_window(info).save_png(self.target / (name + '.png'))


def measure_ui(gui, instance, capture: CaptureRun, args):
    case = args.case
    if case == 'p3':
        populate(gui, instance, 15, 3)
        current = next(w for w in main_windows(gui, instance) if w.hwnd == gui.win32().foreground())
        scale = instance.scale(current)
        x, y = instance.caption_point(current)
        before = capture.mark()
        instance.drag((round(x), round(y)), (round(x + 120 * scale), round(y + 40 * scale)), steps=60, step_delay=2 / 60)
        capture.drain(['scrollbar.paint'], minimum=0.6, quiet=0.5)
        capture.count(capture.window('drag', before), 'scrollbar.paint')
        moved = next(w for w in main_windows(gui, instance) if w.hwnd == current.hwnd)
        if moved.rect[:2] == current.rect[:2]:
            raise PerfError('title-bar drag did not move the window')
        capture.screenshot('drag', moved)
    elif case == 'p4':
        for name in ('palette', 'menu', 'settings'):
            open_ui(instance, name)
            time.sleep(0.6)
            close_ui(instance)
            hot, totals, scans = [], [], []
            for index in range(3):
                before = capture.mark()
                popup = open_ui(instance, name)
                capture.drain([f'{name}.open.ready', f'{name}.open.total', 'profiles.path_scan'], minimum=0.5)
                text = capture.window(f'{name}-hot-{index + 1}', before)
                parsed = capture.parse(text)
                values = parsed.values.get(f'{name}.open.ready', [])
                if not values:
                    capture.missing(f'{name}.open.ready', 'ms')
                elif len(values) != 1 or parsed.units[f'{name}.open.ready'] != 'ms':
                    raise PerfError(f'{name}: expected one hot .open.ready timing, got {len(values)}')
                hot.extend(values)
                totals.extend(parsed.values.get(f'{name}.open.total', []))
                scans.extend(parsed.values.get('profiles.path_scan', []))
                capture.screenshot(f'{name}-hot-{index + 1}', popup)
                close_ui(instance)
            if hot:
                capture.add(f'{name}.open.ready', statistics.median(hot), 'ms')
            if totals:
                capture.add(f'{name}.open.total', statistics.median(totals), 'ms')
            else:
                capture.report['missing_metrics'][f'{name}.open.total'] = {'status': 'not_instrumented', 'n': 0, 'unit': 'ms'}
            capture.report['observations'][name] = {'hot_ready_ms': hot, 'hot_total_ms': totals, 'profiles.path_scan': scans,
                                                   'gate_metric': f'{name}.open.ready'}
            if capture.supported('profiles.path_scan'):
                capture.add(f'{name}.profiles.path_scan', sum(scans))
            else:
                capture.report['missing_metrics'][f'{name}.profiles.path_scan'] = {'status': 'not_instrumented', 'n': 0, 'unit': ''}
    elif case == 'p5':
        popup = open_ui(instance, 'keybinds')
        time.sleep(0.6)
        instance.press('ctrl+home')
        time.sleep(0.2)
        # Keybinds has no UIA row provider. Sweep every 8 DIP (rows >=32 DIP)
        # and overlap wheel pages, so each visible entry receives hover without
        # invoking a private hook. Crop out the blinking search caret and scrollbar.
        scale = instance.scale(instance.require_window())
        left, top, right, bottom = gui.win32().client_rect(popup.hwnd)
        x = round((left + right) / 2)
        first_y, last_y = round(top + 112 * scale), round(bottom - 8 * scale)
        viewport = (round(left + 24 * scale), first_y, round(right - 24 * scale), last_y)
        frames, pages = [], []
        def fingerprint():
            image = instance.capture_window(popup)
            return hashlib.sha256(gui.crop(image, viewport).bgra).hexdigest()
        for page in range(100):
            before = capture.mark()
            points = list(range(first_y, last_y, max(1, round(8 * scale))))
            if not points:
                raise PerfError('shortcut list viewport is empty')
            for y in points:
                instance.mouse(x, y, action='move')
                time.sleep(0.05)
            time.sleep(0.1)
            frames.extend(keybind_frames(capture.window(f'hover-page-{page + 1}', before)))
            pages.append({'page': page + 1, 'points': len(points)})
            old_image = fingerprint()
            instance.wheel(x, points[-1], delta=-120, count=1)
            time.sleep(0.3)
            if fingerprint() == old_image:
                break
        else:
            raise PerfError('shortcut sheet did not reach its last page')
        capture.report['frames'] = frames
        capture.report['hover_pages'] = pages
        capture.report['hover_strategy'] = '8 DIP vertical sweep, overlapping 3-row wheel pages; unchanged viewport ends traversal'
        layout_supported = capture.supported('d2d.layout_create')
        for frame in frames:
            capture.add('keybinds.paint', frame['paint_ms'], 'ms')
            if layout_supported:
                capture.add('d2d.layout_create.per_frame', frame['layouts'])
        if not layout_supported:
            capture.report['missing_metrics']['d2d.layout_create.per_frame'] = {'status': 'not_instrumented', 'n': 0, 'unit': ''}
        if not frames:
            capture.missing('keybinds.paint', 'ms')
        capture.screenshot('keybinds', popup)
        close_ui(instance)
    else:
        popup = open_ui(instance, 'settings')
        time.sleep(0.6)
        instance.press('ctrl+pagedown')  # Language -> Appearance; default focus is the theme list.
        time.sleep(0.5)
        rows = instance.uia_rows(popup.hwnd)
        items = sum(row.get('type') == 'ControlType.ListItem' for row in rows)
        capture.report['observations']['theme_list_uia'] = {'list_items': items}
        if not items:
            if not capture.report.get('baseline'):
                raise PerfError('theme page has no theme list items')
            # Historical builds predate the settings UIA provider (ui/uia.zig): like a
            # missing metric (M5) this is not_instrumented and never stops AB/BA.
            capture.report.setdefault('missing_preconditions', {})['theme_list_uia'] = {
                'status': 'not_instrumented', 'n': 0, 'scope': 'historical arm only; theme list items not readable through UIA'}
        before = capture.mark()
        instance.hold_key('down', seconds=2, hz=30)
        capture.drain(['theme.reload'], minimum=1, quiet=0.5)
        capture.count(capture.window('theme-hold', before), 'theme.reload')
        capture.screenshot('theme', popup)
        close_ui(instance)


def measure_idle(gui, instance, capture: CaptureRun, args, counters):
    populate(gui, instance, args.tabs, args.windows)
    windows = main_windows(gui, instance)
    if args.state == 'minimized':
        # SW_MINIMIZE of the active window activates the next activatable top-level window, which is
        # another measured window that is still shown: minimizing the foreground one last means this
        # tool never activates a measured window, so a restore seen later is not its own doing.
        foreground = gui.win32().foreground()
        for window in sorted(windows, key=lambda window: window.hwnd == foreground):
            instance.ensure_owned()
            gui.win32().ShowWindow(window.hwnd, 6)  # SW_MINIMIZE, owned windows only.
    elif args.state == 'unfocused':
        # Focus a second owned, isolated Ghostty process. Never activate an unrelated app.
        helper_dir = capture.target / 'focus-env'
        gui.prepare_env_dir(helper_dir, fresh=False)
        helper = gui.launch(Path(instance.exe), helper_dir, config=DEFAULT_WIN32_CONFIG + gui.HARNESS_CONFIG)
        capture.report['focus_helper'] = {'pid': helper.pid, 'creation': helper.creation, 'separate_process': True}
        try:
            helper.wait_window(30)
            helper.activate()
            return idle_interval(gui, instance, capture, args, counters, helper=helper,
                                 entry=idle_state_entry(gui, instance, capture, args))
        finally:
            helper.close()
    return idle_interval(gui, instance, capture, args, counters, entry=idle_state_entry(gui, instance, capture, args))


def idle_state_entry(gui, instance, capture, args) -> dict:
    """The moment the --state arrangement is in place: the GetLastInputInfo tick from which the input
    criterion and instance_self_activated count, and title-free facts about the foreground window.
    This tool's own input is already counted by then: populate ends with a settle sleep after its
    last key, and neither activating the focus helper nor minimizing sends input."""
    w = gui.win32()
    hwnd = w.foreground()
    pid = w.window_pid(hwnd) if hwnd else 0
    entry = {'state': args.state, 'tick': last_input_ticks()[0], 'foreground_pid': pid,
             'foreground_class': w.class_name(hwnd) if hwnd else 'none',
             'foreground_image': gui.image_name(pid) if pid else None}
    capture.report['idle_state_entry'] = entry
    if args.state == 'visible' and pid != instance.pid:
        raise PerfError('idle state entry failed: measured main process does not own the foreground')
    elif args.state == 'minimized':
        windows = main_windows(gui, instance)
        if not windows or any(not w.IsIconic(window.hwnd) for window in windows):
            raise PerfError('idle state entry failed: measured windows are not all minimized')
    elif args.state == 'unfocused' and instance.contains_pid(pid):
        raise PerfError('idle state entry failed: measured process tree still owns the foreground')
    return entry


def idle_state_check(gui, instance, args, helper=None, *, entry_tick: int) -> None:
    """The --state arrangement must still hold after the idle window. A broken one is audited like a
    failed guard (check idle_state_window: the gx-input-guard-v1 fields, title-free other_pid/other_class/
    other_image facts about the foreground window, entry_tick and last_input_tick) and raised with the
    first cause that applies:

    instance_hung           Instance.hang_evidence: the measured process hangs or crashed (PRODUCT_FAIL).
    instance_gone           the measured process ended (ensure_owned audits and raises it), or the unfocused
                            state's focus helper, an owned process of the same build, ended and so handed
                            the foreground back (PRODUCT_FAIL).
    foreign_input           GetLastInputInfo saw input after the state entry (the input criterion, INVALID).
    foreground_lost         another process took the foreground of a visible instance (INVALID).
    instance_self_activated without input since the state entry the measured process took the foreground
                            back from its live focus helper, or one of its own minimized windows was
                            restored, or a descendant took the visible main process's foreground
                            (PRODUCT_FAIL): measure_idle activates and restores none of them.
    In the unfocused state another process in front leaves the instance unfocused: that is no failure.
    """
    instance.ensure_owned()
    w = gui.win32()
    hwnd = w.foreground()
    pid = w.window_pid(hwnd) if hwnd else 0
    details = {}
    unchanged = False
    owned_foreground = False
    if args.state == 'visible':
        unchanged = pid == instance.pid
        owned_foreground = unchanged or instance.contains_pid(pid)
        message = 'visible measured process kept focus' if unchanged else 'visible measured process lost focus'
    elif args.state == 'unfocused':
        if not instance.contains_pid(pid):
            return
        message = 'measured process regained focus'
        if helper is not None:
            details.update(helper_pid=helper.pid, helper_alive=helper.alive())
    else:
        restored = [f'{window.hwnd:#x}' for window in main_windows(gui, instance) if not w.IsIconic(window.hwnd)]
        if not restored:
            return
        message = 'a measured window was restored'
        details['restored'] = restored
    other_class = w.class_name(hwnd) if hwnd else 'none'
    other_image = gui.image_name(pid) if pid else None
    message += f'; the foreground window is {hwnd:#x} ({other_class}, pid {pid})'
    # Read after the facts above: an unchanged tick means no input arrived before they were seen.
    last_input = last_input_ticks()[0]
    details.update(entry_tick=entry_tick, last_input_tick=last_input)
    if hang := instance.hang_evidence(other_class, other_image):
        cause = 'instance_hung'
        message = f'ghostty pid {instance.pid} hangs or crashed ({hang}): {message}'
    elif details.get('helper_alive') is False:
        cause = 'instance_gone'
        message = f'the focus helper ghostty pid {helper.pid} ended during the idle window: {message}'
    elif last_input != entry_tick:
        cause = 'foreign_input'
        message = f'input arrived after the state entry (last input tick {entry_tick} -> {last_input}): {message}'
    elif unchanged:
        return
    elif (args.state == 'visible' and not owned_foreground) or (args.state == 'unfocused' and helper is None):
        cause = 'foreground_lost'  # another process holds the foreground, or no live focus helper is known
    else:
        cause = 'instance_self_activated'
        what = ('handed the foreground to its descendant process' if args.state == 'visible'
                else 'took the foreground back from its live focus helper' if args.state == 'unfocused'
                else 'restored a minimized window')
        message = f'ghostty pid {instance.pid} {what} without input since the state entry: {message}'
    instance.record_input('guard', check='idle_state_window', status='fail', cause=cause, reason=message,
                          state=args.state, other_pid=pid, other_class=other_class, other_image=other_image, **details)
    raise PerfError(message, cause=cause)


def idle_interval(gui, instance, capture, args, counters, helper=None, entry=None):
    time.sleep(2)
    before_log = capture.mark()
    input_before = last_input_ticks()[0]
    # The input criterion counts from the state entry (measure_idle), not just from the counter window.
    start_tick = entry['tick'] if entry else input_before
    before = counters.sample(instance)
    time.sleep(args.seconds)
    after = counters.sample(instance)
    input_after = last_input_ticks()[0]
    capture.report.update(before=before, after=after,
        input_window={'entry_tick': start_tick, 'before_tick': input_before, 'after_tick': input_after},
        context_switch_diagnostic=context_switch_diagnostic(before, after),
        context_switch_source='NtQuerySystemInformation(SystemProcessInformation), matched TID+CreateTime endpoints; diagnostic only',
        context_switch_scope='endpoint-surviving threads only; threads born and exited between endpoints are not observable')
    if input_after != start_tick:
        instance.ensure_owned()
        w = gui.win32()
        hwnd = w.foreground()
        pid = w.window_pid(hwnd) if hwnd else 0
        if hang := instance.hang_evidence(w.class_name(hwnd) if hwnd else 'none', gui.image_name(pid) if pid else None):
            message = f'ghostty pid {instance.pid} hangs or crashed ({hang}) during the idle measurement window'
            instance.record_input('guard', check='idle_input_window', status='fail', cause='instance_hung', reason=message,
                                  before_tick=start_tick, after_tick=input_after)
            raise PerfError(message, cause='instance_hung')
        message = 'external input occurred during the idle measurement window'
        # Audited like a failed guard so quiet-batch reads plan §4 noise (INVALID), not a tool error.
        instance.record_input('guard', check='idle_input_window', status='fail', cause='foreign_input', reason=message,
                              before_tick=start_tick, after_tick=input_after, **({'since': 'state_entry'} if entry else {}))
        raise PerfError(message, cause='foreign_input')
    idle_state_check(gui, instance, args, helper, entry_tick=start_tick)
    text = capture.window('idle', before_log)
    capture.count(text, 'proc.snapshot')
    capture.count(text, 'renderer.present', required=False)
    switches = capture.report['context_switch_diagnostic']['status']
    if switches != 'endpoint_complete':
        # Absent because the endpoint sets differ or NT counters failed, not because
        # the build lacks instrumentation; summaries keep that distinction.
        capture.report['missing_metrics']['threads.context_switches'] = {'status': switches, 'n': 0, 'unit': '',
                                                                         'scope': 'C7 diagnostic only'}
    for name, (value, unit) in idle_delta(before, after).items():
        capture.add(name, value, unit)


def measure_resources(gui, instance, capture: CaptureRun, args, counters):
    samples = []
    for count in (1, 11):
        if count == 11:
            current = instance.require_window()
            for expected in range(2, 12):
                instance.press(NEW_TAB_KEYS)
                wait_until(lambda: len(gui.win32().child_windows(current.hwnd, gui.TERMINAL_CLASS)) == expected, 'terminal count')
        time.sleep(2)
        raw = counters.sample(instance)
        windows = main_windows(gui, instance)
        if len(windows) != 1:
            raise PerfError('resource measurement requires exactly one main window')
        terminals = gui.win32().child_windows(windows[0].hwnd, gui.TERMINAL_CLASS)
        if len(terminals) != count:
            raise PerfError(f'resource measurement expected {count} tabs with one terminal each, got {len(terminals)}')
        visible = sum(info.visible and not info.cloaked for info in terminals)
        if not visible or gui.win32().IsIconic(windows[0].hwnd):
            raise PerfError('resource measurement requires a visible terminal')
        raw['terminal_population'] = {'layout': 'one window; tabs, one terminal per tab', 'total': count, 'visible': visible}
        if args.command == 'win32-gpu':
            raw['gpu'] = counters.gpu(instance)
            capture.add(f'gpu.dedicated.{count}', raw['gpu']['dedicated_bytes'])
            metrics = capture.parse(instance.log_text())
            gauges = {name: values[-1] for name, values in metrics.values.items() if name.startswith(('renderer.targets_', 'renderer.target_'))}
            if any(metrics.units[name] for name in gauges):
                raise PerfError('renderer target gauge unexpectedly has time units')
            raw['target_gauges'] = gauges
            for name, value in gauges.items():
                capture.add(f'{name}.{count}', value)
            if 'renderer.targets_live' in gauges:
                capture.add(f'renderer.targets_live.per_visible_terminal.{count}', gauges['renderer.targets_live'] / visible)
                raw['targets_per_visible_terminal'] = gauges['renderer.targets_live'] / visible
            else:
                capture.missing(f'renderer.targets_live.{count}')
        capture.add(f'process.commit.{count}', raw['private_bytes'])
        if raw['thread_count'] is not None:
            capture.add(f'process.threads.{count}', raw['thread_count'])
        samples.append(raw)
        capture.screenshot(f'terminals-{count}')
    capture.report['resources'] = samples
    capture.report['resource_scope'] = 'PDH increment=(11-tab bytes - 1-tab bytes)/10; target gauge denominator=actually visible terminals, not all tabs'
    added_threads = (samples[1]['thread_count'] - samples[0]['thread_count']) if all(row['thread_count'] is not None for row in samples) else None
    added_commit = samples[1]['private_bytes'] - samples[0]['private_bytes']
    capture.add('process.commit.delta', added_commit)
    if added_threads is not None:
        capture.add('process.threads.delta', added_threads)
    if (added_threads is None or added_threads <= 0) and args.command == 'win32-mem':
        raise PerfError('no positive thread-count increment at 11 terminals')
    if added_threads is not None and added_threads > 0:
        capture.add('process.commit.per_added_thread', added_commit / added_threads)
    capture.report['commit_scope'] = 'whole-process PrivateUsage delta per added thread; includes terminal heaps/atlases, not isolated stack commitment'
    if args.command == 'win32-gpu':
        capture.add('gpu.dedicated.per_added_terminal', (samples[1]['gpu']['dedicated_bytes'] - samples[0]['gpu']['dedicated_bytes']) / 10)


def c7_input_check(gui, instance, args, entry_tick, helper=None):
    """No synthetic input is sent inside the counter window, including output wakeup."""
    instance.ensure_owned()
    w = gui.win32()
    hwnd = w.foreground()
    pid = w.window_pid(hwnd) if hwnd else 0
    hang = instance.hang_evidence(w.class_name(hwnd) if hwnd else 'none', gui.image_name(pid) if pid else None)
    tick = last_input_ticks()[0]
    cause = 'instance_hung' if hang else 'foreign_input' if tick != entry_tick else None
    if cause:
        message = str(hang) if hang else 'input arrived during the C7 observation interval'
        instance.record_input('guard', check='c7_input_window', status='fail', cause=cause,
                              reason=message, before_tick=entry_tick, after_tick=tick)
        raise PerfError(message, cause=cause)
    idle_state_check(gui, instance, args, helper, entry_tick=entry_tick)


def measure_c7(gui, instance, capture, args, counters, shells, pdh_factory=None):
    import gx_perf_stimulus as stimulus
    pdh_factory = pdh_factory or stimulus.PdhThreads
    report = capture.report
    report['c7'] = {'case': args.case, 'terminal_count': args.tabs, 'seconds_requested': args.seconds,
                    'performance_verdict': 'not evaluated', 'visual_review': 'PENDING',
                    'animation_guards': 'separate kitty-animation/custom-shader cells; visual review remains required',
                    'shell_script_sha256': hashlib.sha256(Path(stimulus.__file__).read_bytes()).hexdigest(),
                    'shell_python': sys.executable, 'shell_python_sha256': hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest(),
                    'pdh': {'source': stimulus.PDH_PATHS, 'status': 'running', 'n': 0, 'unit': ''}}
    evidence = report['c7']
    helper = pdh = None
    backdrop = gui.Backdrop(gui.BACKDROP_DEFAULT)
    rows = []
    def shot(name):
        info = instance.require_window()
        path = capture.target / (name + '.png')
        began = time.perf_counter_ns()
        backdrop.capture(instance, info, 'screen', name).save_png(path)
        evidence.setdefault('screenshots', []).append({'path': path.name, 'begin_qpc_ns': began,
            'end_qpc_ns': time.perf_counter_ns(), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'phase': 'observed image; blink/preedit state requires visual review'})
    try:
        populate(gui, instance, args.tabs, 1)
        setup_tick = last_input_ticks()[0]
        wait_until(lambda: shells.ready(gui, instance, args.tabs), 'owned C7 shell receipts')
        evidence['shells'] = [{'pid': pid, 'creation': birth} for pid, birth in shells.identities.items()]
        # Photographs are outside the CPU/PDH measurement window. A delay is not
        # evidence that two photographs captured opposite blink phases.
        if args.case == 'kitty-animation':
            animation_command = shells.command('kitty-animation')
            evidence['animation_command'] = animation_command
            wait_until(lambda: len([r for r in shells.rows() if r['event'] == 'kitty-animation' and
                                    r['id'] == animation_command['id']]) == args.tabs,
                       'owned Kitty animation write receipts')
        for index in range(8):
            shot(f'c7-before-{index + 1}')
            time.sleep(0.15)
        c7_input_check(gui, instance, argparse.Namespace(state='visible'), setup_tick)
        if args.case == 'ime-preedit':
            evidence['ime'] = stimulus.ime_state(gui, instance)
            if evidence['ime']['status'] == 'PENDING':
                raise stimulus.EnvironmentUnavailable(evidence['ime']['reason'])
            for key in 'nihao':
                instance.press(key)
                time.sleep(0.08)
            setup_tick = last_input_ticks()[0]  # Last deliberate input, before the preedit observation.
            time.sleep(0.3)
            evidence['ime']['before_input'] = [r for r in shells.rows() if r['event'] == 'input']
            if evidence['ime']['before_input']:
                raise PerfError('installed IME passed raw keys to the console instead of holding preedit')
            shot('ime-preedit-entry')
            c7_input_check(gui, instance, argparse.Namespace(state='visible'), setup_tick)
        windows = main_windows(gui, instance)
        if args.state == 'minimized':
            foreground = gui.win32().foreground()
            for window in sorted(windows, key=lambda window: window.hwnd == foreground):
                instance.ensure_owned()
                gui.win32().ShowWindow(window.hwnd, 6)
        elif args.state == 'unfocused':
            helper_dir = capture.target / 'focus-env'
            gui.prepare_env_dir(helper_dir, fresh=False)
            helper = gui.launch(Path(instance.exe), helper_dir, config=DEFAULT_WIN32_CONFIG + gui.HARNESS_CONFIG)
            report['focus_helper'] = {'pid': helper.pid, 'creation': helper.creation, 'separate_process': True}
            helper.wait_window(30)
            helper.activate()
        entry = idle_state_entry(gui, instance, capture, args)
        entry['tick'] = setup_tick  # State changes and screenshots sent no input.
        c7_input_check(gui, instance, args, entry['tick'], helper)
        time.sleep(2)
        c7_input_check(gui, instance, args, entry['tick'], helper)
        try:
            pdh = pdh_factory()
        except stimulus.PdhFailure as exc:
            if not exc.unavailable:
                raise
            evidence['pdh'].update(status='PENDING', reason=f'{type(exc).__name__}: {exc}')
        def pdh_sample():
            nonlocal pdh
            if pdh is None:
                return
            try:
                row = pdh.sample()
                rows.append(row)
                stimulus.append_json(capture.target / 'pdh-raw.jsonl', row)
            except stimulus.PdhFailure as exc:
                if not exc.unavailable:
                    raise
                evidence['pdh'].update(status='PENDING', reason=f'{type(exc).__name__}: {exc}')
                stimulus.append_json(capture.target / 'pdh-raw.jsonl',
                                     {'error': str(exc), 'qpc_ns': time.perf_counter_ns()})
                pdh.close()
                pdh = None
        pdh_sample()
        log_before = capture.mark()
        before = counters.sample(instance)
        report['before'] = before
        evidence['cpu_scope'] = 'owned Ghostty PID only; Python stimulus and focus helper CPU excluded'
        began = time.perf_counter()
        deadline = began + args.seconds
        evidence['counter_window_begin_qpc_ns'] = time.perf_counter_ns()
        output = None
        next_sample = began + 1
        while True:
            now = time.perf_counter()
            if now >= deadline:
                break
            time.sleep(max(0, min(next_sample, deadline) - now))
            c7_input_check(gui, instance, args, entry['tick'], helper)
            pdh_sample()
            now = time.perf_counter()
            if args.case == 'output-wakeup' and output is None and now - began >= args.seconds / 2:
                shells.verify(gui, instance)
                evidence['output_log_start_byte'] = len(capture.mark())
                output = shells.command('output', bytes=args.output_bytes)
                evidence['output_command'] = output
            next_sample = now + 1
        after = counters.sample(instance)
        evidence['counter_window_end_qpc_ns'] = time.perf_counter_ns()
        report.update(after=after, context_switch_diagnostic=context_switch_diagnostic(before, after))
        c7_input_check(gui, instance, args, entry['tick'], helper)
        shells.verify(gui, instance)
        text = capture.window('c7-counter-window', log_before)
        capture.count(text, 'renderer.present', required=False)
        for name, (value, unit) in idle_delta(before, after).items():
            if name != 'threads.context_switches':  # NT endpoint numbers never impersonate PDH.
                capture.add(name, value, unit)
        if evidence['pdh']['status'] != 'PENDING':
            evidence['pdh'] = stimulus.pdh_summary(rows, instance.pid)
        evidence['pdh']['creation'] = instance.creation
        if evidence['pdh']['status'] == 'sampled':
            capture.add('threads.context_switches.pdh', evidence['pdh']['switches'])
        else:
            report['missing_metrics']['threads.context_switches.pdh'] = evidence['pdh']
        evidence['input_during_window'] = [r for r in shells.rows() if r['event'] == 'input']
        if evidence['input_during_window']:
            raise PerfError('console received unexpected committed input in the C7 window')
        if output:
            evidence['output_receipts'] = shells.output_receipts(output, evidence['counter_window_end_qpc_ns'])
            if {r['pid'] for r in evidence['output_receipts']} != set(shells.identities):
                raise PerfError('not every owned terminal acknowledged output within the measurement window')
            capture.add('stimulus.output_bytes', sum(r['written_bytes'] for r in evidence['output_receipts']))
            evidence['output_log_end_byte'] = report['windows'][-1]['end_byte']
        if args.state == 'visible':
            for index in range(8):
                shot(f'c7-after-{index + 1}')
                time.sleep(0.15)
                c7_input_check(gui, instance, args, entry['tick'], helper)
        if args.case == 'ime-preedit':
            # This commit happens AFTER the counter/log endpoints. No reset of the
            # window's last-input sentinel is needed to excuse injected input.
            c7_input_check(gui, instance, args, entry['tick'], helper)
            instance.press('space')
            wait_until(lambda: len([r for r in shells.rows() if r['event'] == 'input']) >= 2,
                       'real IME committed Chinese characters', timeout=5)
            committed = [r for r in shells.rows() if r['event'] == 'input']
            evidence['ime']['committed_input'] = committed
            evidence['ime']['commit_text'] = ''.join(r['text'] for r in committed)
            if evidence['ime']['commit_text'] != '你好' or len({r['pid'] for r in committed}) != 1:
                raise PerfError('IME commit verification failed: physical nihao+space did not produce exactly 你好; inspect raw receipts')
            evidence['ime'].update(status='observed_commit',
                preedit_verification='PENDING visual review; no cross-process internal preedit query exists')
        evidence['coverage'] = ('PENDING' if evidence['pdh']['status'] != 'sampled' or
                                'renderer.present' in report['missing_metrics'] else 'captured')
        if hashlib.sha256(Path(stimulus.__file__).read_bytes()).hexdigest() != evidence['shell_script_sha256']:
            raise PerfError('stimulus script changed during run')
    finally:
        if pdh:
            pdh.close()
        evidence['shell_receipts'] = shells.rows()
        report['backdrop'] = backdrop.finish()
        teardown_errors = backdrop.teardown_failures()
        if teardown_errors:
            report['backdrop_teardown_errors'] = teardown_errors
            report.setdefault('errors', []).extend(teardown_errors)
        if helper:
            helper.close()


def run_c7_matrix(args) -> int:
    import copy
    import gx_perf_stimulus as stimulus
    out = new_output(args.out)
    result = {'schema': 'gx-c7-matrix-v1', 'planned_cells': 12, 'planned_animation_guards': 4, 'cells': [],
              'performance_verdict': 'not evaluated', 'visual_and_animation_guards': 'PENDING'}
    write_json(out / 'RESULT.json', result)
    exit_code = 0
    for tabs in (1, 11):
        for case in (*stimulus.CASES, *stimulus.ANIMATION_CASES):
            cell = copy.copy(args)
            cell.tabs, cell.case = tabs, case
            cell.state = case if case in ('unfocused', 'minimized') else 'visible'
            cell.out, cell.json = out / f'{tabs}-{case}', None
            code = run_experiment(cell)
            details = read_json(cell.out / 'RESULT.json')
            result['cells'].append({'tabs': tabs, 'case': case, 'path': cell.out.name,
                                     'exit': code, 'valid': details['valid'],
                                     'measurement_coverage': details.get('measurement_coverage', 'PENDING'),
                                     'environment_pending': details.get('environment_pending', False)})
            result['failure_causes'] = sorted(set(result.get('failure_causes', [])) | set(details.get('failure_causes', [])))
            exit_code = max(exit_code, code)
            write_json(out / 'RESULT.json', result)
            if code and not details.get('environment_pending'):
                result['stopped_after_failure'] = cell.out.name
                break  # No more input after product/guard/tool failure.
        if result.get('stopped_after_failure'):
            break
    result.update(exit=exit_code, status='incomplete' if exit_code else
                  'PENDING' if any(cell['measurement_coverage'] == 'PENDING' for cell in result['cells']) else 'captured',
                  completed_cells=len(result['cells']))
    write_json(out / 'RESULT.json', result)
    write_json(args.json, result)
    (out / 'SUMMARY.txt').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8', newline='\n')
    return exit_code


def absolute_gate(args, capture: CaptureRun) -> dict:
    if capture.report.get('baseline') or args.diagnostic:
        return {'status': 'not_evaluated', 'reason': 'baseline' if capture.report.get('baseline') else 'diagnostic'}
    values = capture.samples.values
    requirements = []
    if args.command == 'win32-idle':
        if args.seconds != 60:
            return {'status': 'not_evaluated', 'reason': 'P2 requires a 60-second window'}
        requirements = [('proc.snapshot', lambda xs: sum(xs) == 0 if args.state == 'minimized' else sum(xs) <= 30)]
    elif args.command == 'win32-ui':
        if args.case == 'p3':
            requirements = [('scrollbar.paint', lambda xs: sum(xs) == 0)]
        elif args.case == 'p4':
            for ui in ('palette', 'menu', 'settings'):
                requirements.extend([(ui+'.open.ready', lambda xs: max(xs) <= 6.25),
                                     (ui+'.profiles.path_scan', lambda xs: sum(xs) == 0)])
        elif args.case == 'p5':
            requirements = [('keybinds.paint', lambda xs: p90(xs) < 2), ('d2d.layout_create.per_frame', lambda xs: max(xs) <= 10)]
        else:
            requirements = [('theme.reload', lambda xs: sum(xs) == 1)]
    checks = {name: ('PASS' if predicate(values[name]) else 'FAIL') if values.get(name) else 'NOT_INSTRUMENTED'
              for name, predicate in requirements}
    return {'status': ('PASS' if all(value == 'PASS' for value in checks.values()) else 'FAIL') if checks else 'not_evaluated',
            'checks': checks, 'scope': 'new-arm absolute numerical gate only; quiet/visual/cross-topology checks remain separate'}


def run_experiment(args, gui=None, counters_factory=NativeCounters) -> int:
    import gx_perf_stimulus as stimulus
    if gui is None:
        import gx_win_gui as gui
    exes = [Path(path).resolve() for path in args.exe]
    if not 1 <= len(exes) <= 2 or any(not exe.is_file() for exe in exes):
        raise PerfError('give one or two existing --exe files')
    labels = labels_for(len(exes), args.label)
    unsupported = set(getattr(args, 'uninstrumented', []))
    if not unsupported <= set(labels):
        raise PerfError('--uninstrumented must name a declared label')
    baseline = labels[0] if len(labels) == 2 else None
    if unsupported - ({baseline} if baseline else set()) and not args.diagnostic:
        raise PerfError('--uninstrumented can mark only the historical first arm outside diagnostic mode')
    capabilities = metric_capabilities(getattr(args, 'capabilities', []), labels, exes)
    try:
        envs = label_environments(labels, ['GHOSTTY_GX_PERF=1', *args.env], args.label_env, gui.env_assignments)
    except gui.GuiError as exc:
        raise PerfError(str(exc)) from None
    if any(env.get('GHOSTTY_GX_PERF') != '1' for env in envs.values()):
        raise PerfError('measurement requires GHOSTTY_GX_PERF=1')
    config = args.config.read_text(encoding='utf-8') if args.config else DEFAULT_WIN32_CONFIG
    config = config.rstrip() + '\n' + gui.HARNESS_CONFIG
    out = new_output(args.out)
    batch = {'schema': 'gx-win32-perf-v1', 'command': args.command, 'case': getattr(args, 'case', None),
             'order': 'AB/BA', 'planned_runs': args.runs, 'labels': labels, 'diagnostic': args.diagnostic,
             'performance_verdict': 'not evaluated', 'runs': [], 'errors': [], 'metrics': {}, 'baseline_label': baseline,
             'measurement_units': {'process.commit.*': 'bytes', 'gpu.dedicated.*': 'bytes',
                                   'process.commit.per_added_thread': 'bytes/thread', 'gpu.dedicated.per_added_terminal': 'bytes/terminal',
                                   'process.threads.*': 'threads', 'time': 'ms', 'other_unitless': 'count/gauge'}}
    sets = {label: Samples() for label in labels}
    missing = {label: {} for label in labels}
    preconditions = {label: {} for label in labels}
    unsettled = []
    resources = []
    for run, label in alternate(labels, args.runs):
        target = out / label / f'run-{run:02d}'
        target.mkdir(parents=True)
        exe = exes[labels.index(label)]
        run_config = config
        shells = None
        if args.command == 'win32-c7':
            shells = stimulus.OwnedShells(target / 'stimulus')
            run_config += shells.config()
            run_config += 'shell-integration = none\n'
            if args.case == 'blink-off':
                run_config += 'cursor-style-blink = false\n'
            if args.case == 'custom-shader':
                shader = target / 'c7-animation.glsl'
                shader.write_text(stimulus.ANIMATION_SHADER, encoding='utf-8', newline='\n')
                run_config += f'custom-shader = {shader.as_posix()}\ncustom-shader-animation = true\n'
        report = {'schema': 'gx-win32-perf-run-v1', 'label': label, 'run': run, 'command': args.command,
                  'baseline': label == baseline or label in unsupported, 'capabilities': capabilities[label],
                  'case': getattr(args, 'case', None), 'env': envs[label], 'config': run_config, 'diagnostic': args.diagnostic,
                  'exe': str(exe), 'exe_sha256': hashlib.sha256(exe.read_bytes()).hexdigest(),
                  'state': getattr(args, 'state', None), 'tabs': getattr(args, 'tabs', None), 'windows_count': getattr(args, 'windows', None),
                  'seconds': getattr(args, 'seconds', None), 'status': 'running', 'errors': []}
        write_json(target / 'run.json', report)
        batch['runs'].append({'label': label, 'run': run, 'path': str(target.relative_to(out)), 'status': 'running'})
        write_json(out / 'RESULT.json', batch)
        instance = capture = None
        try:
            gui.prepare_env_dir(target / 'env', fresh=False)
            instance = gui.launch(exe, target / 'env', config=run_config, env=envs[label])
            report.update(pid=instance.pid, creation=instance.creation)
            write_json(target / 'run.json', report)
            report['startup_ms'] = instance.wait_window(30)
            instance.activate()
            time.sleep(1)
            capture = CaptureRun(instance, target, report)
            if args.command == 'win32-ui':
                measure_ui(gui, instance, capture, args)
            elif args.command == 'win32-idle':
                measure_idle(gui, instance, capture, args, counters_factory(gui))
            elif args.command == 'win32-c7':
                measure_c7(gui, instance, capture, args, counters_factory(gui), shells)
            else:
                measure_resources(gui, instance, capture, args, counters_factory(gui))
            instance.ensure_owned()
            capture.parse(capture.mark().decode('utf-8', errors='strict'))  # Refuse intra-arm conflicts even outside selected windows.
            if hashlib.sha256(exe.read_bytes()).hexdigest() != report['exe_sha256']:
                raise PerfError('executable changed during run')
            report['absolute_gate'] = absolute_gate(args, capture)
            report['status'] = 'completed'
        except Exception as exc:
            report['status'] = 'failed'
            report['errors'].append(str(exc))
            report['failure_cause'] = getattr(exc, 'cause', None) or 'other'
            if isinstance(exc, stimulus.EnvironmentUnavailable):
                report['environment_pending'] = True
                report['status'] = 'pending'
            if getattr(exc, 'instance_pid', None) is not None:
                report['pid'] = exc.instance_pid
        finally:
            if instance:
                try:
                    report['cleanup'] = instance.close()
                except Exception as exc:
                    report['status'] = 'failed'
                    report['environment_pending'] = False
                    report['errors'].append('cleanup: ' + str(exc))
                try:
                    if instance.log.exists():
                        (target / 'ghostty.log').write_bytes(instance.log.read_bytes())
                except Exception as exc:
                    report['status'] = 'failed'
                    report['environment_pending'] = False
                    report['errors'].append('copy raw log: ' + str(exc))
                report['input_events'] = instance.input_events if isinstance(instance.input_events, list) else []
            # Cleanup failure must override an environmental exception caught above.
            # Keep both reasons, but never authorize the matrix to continue input.
            if report.get('backdrop_teardown_errors'):
                report['status'] = 'failed'
                report['environment_pending'] = False
            if capture:
                if report['errors'] and report['status'] == 'completed':
                    report['status'] = 'failed'
                report['metrics'] = summary_table(capture.samples)[1]
                report['metrics'].update({key: value for key, value in report['missing_metrics'].items() if key not in report['metrics']})
                missing[label].update(report['missing_metrics'])
                for name, info in report.get('missing_preconditions', {}).items():
                    preconditions[label].setdefault(name, {**info, 'runs': []})['runs'].append(run)
                if report.get('measurement_unsettled'):
                    unsettled.append({'label': label, 'run': run,
                                      'metrics': [d['metrics'] for d in report.get('drains', []) if d.get('status') == 'timeout']})
                # A dedicated derived file is the only round-level summary input.
                lines = [f"metric {name} {value} {capture.samples.units[name]}".rstrip()
                         for name, values in capture.samples.values.items() for value in values]
                (target / 'samples.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
                if report['status'] == 'completed':
                    sets[label].extend(capture.samples)
            write_json(target / 'run.json', report)
            if report.get('resources'):
                resources.append({'label': label, 'run': run, 'populations': [row['terminal_population'] for row in report['resources']],
                                  'target_ratios': [row.get('targets_per_visible_terminal') for row in report['resources']]})
            batch['runs'][-1]['status'] = report['status']
            if args.command == 'win32-c7':
                batch['runs'][-1]['c7_coverage'] = report.get('c7', {}).get('coverage', 'PENDING')
            if report.get('environment_pending'):
                batch['runs'][-1]['environment_pending'] = True
            if report.get('failure_cause'):
                batch['runs'][-1]['failure_cause'] = report['failure_cause']
            batch['runs'][-1]['absolute_gate'] = report.get('absolute_gate', {'status': 'not_evaluated'})
            batch['errors'].extend(f'{label}/{run}: {error}' for error in report['errors'])
            write_json(out / 'RESULT.json', batch)
        print(f"{TAG} {label}/{run}: {report['status']}", flush=True)
        if report['status'] != 'completed':
            break  # Never retry or continue input after a failed guard.
    batch['valid'] = not batch['errors'] and len(batch['runs']) == args.runs * len(labels)
    batch['environment_pending'] = any(item.get('environment_pending') for item in batch['runs'])
    if args.command == 'win32-c7':
        batch['measurement_coverage'] = ('captured' if batch['valid'] and
            all(item.get('c7_coverage') == 'captured' for item in batch['runs']) else 'PENDING')
        batch['measurement_units']['threads.context_switches.pdh'] = 'context switches per sampled window'
        batch['measurement_units']['stimulus.output_bytes'] = 'bytes written to all owned consoles'
    batch['failure_causes'] = sorted({item['failure_cause'] for item in batch['runs'] if item.get('failure_cause')})
    batch['gate_failed'] = any(item['absolute_gate']['status'] == 'FAIL' for item in batch['runs'])
    # 1 = incomplete driver evidence (any observed gate FAIL stays in absolute_gates);
    # 4 = complete batch whose new-arm absolute gate failed: keep it as FAIL evidence.
    batch['exit'] = 1 if not batch['valid'] else (4 if batch['gate_failed'] else 0)
    texts = []
    for label in labels:
        text, batch['metrics'][label] = summary_table(sets[label])
        absent = {name: info for name, info in missing[label].items() if name not in batch['metrics'][label]}
        batch['metrics'][label].update(absent)
        text += ''.join(f'{name} unit={info["unit"] or "count"} n=0 {info["status"]}\n' for name, info in absent.items())
        texts.append(label + '\n' + text)
    if len(labels) == 2:
        text, batch['comparison'] = compare_table(sets[labels[0]], sets[labels[1]], tuple(labels))
        for name, entry in batch['comparison'].items():
            for label in labels:
                if entry[label] is None:
                    # The arm's own recorded reason (not_instrumented, partial, unavailable), else no samples.
                    entry[label] = batch['metrics'][label].get(name, {'status': 'no_samples', 'n': 0, 'unit': entry['unit']})
        texts.append(text)
    batch['absolute_gates'] = {label: [item['absolute_gate'] for item in batch['runs'] if item['label'] == label] for label in labels}
    batch['missing_preconditions'] = {label: items for label, items in preconditions.items() if items}
    batch['unsettled_runs'] = unsettled
    text = 'Numerical absolute gates apply only to the new arm; baseline missing metrics are not_instrumented (n=0).\n' + '\n'.join(texts)
    text += '\nAbsolute gates: ' + json.dumps(batch['absolute_gates'], ensure_ascii=False) + '\n'
    if batch['missing_preconditions']:
        text += ('Missing preconditions (historical arm only; recorded, not a gate): ' +
                 json.dumps(batch['missing_preconditions'], ensure_ascii=False) + '\n')
    if unsettled:
        text += ('Unsettled metric windows (still changing at the 3 s limit; counted as observed): ' +
                 json.dumps(unsettled, ensure_ascii=False) + '\n')
    text += ('Driver result: ' + ('complete' if batch['valid'] else 'incomplete (driver error)') +
             ('; absolute gate FAIL observed' if batch['gate_failed'] else '') +
             (f"; failure causes {', '.join(batch['failure_causes'])}" if batch['failure_causes'] else '') + f"; exit {batch['exit']}\n")
    if args.command == 'win32-c7':
        text += ('C7 metric coverage: ' + batch['measurement_coverage'] +
                 '; visual blink/preedit/animation checks remain PENDING; NT endpoints do not substitute for PDH.\n')
    if resources:
        batch['resource_populations'] = resources
        text += ('\nP8: one window, 1/11 tabs, one terminal per tab; dedicated-byte increment denominator=10.\n'
                 'renderer.targets_live ratios use the actually visible terminal count at each endpoint; hidden tabs are excluded.\n'
                 'Commit/thread is whole-process PrivateUsage delta and includes heaps, not isolated stack commit.\n' +
                 json.dumps(resources, ensure_ascii=False) + '\n')
    if batch['errors']:
        text += '\nFAILED: ' + '; '.join(batch['errors']) + '\n'
    (out / 'SUMMARY.txt').write_text(text, encoding='utf-8', newline='\n')
    write_json(out / 'RESULT.json', batch)
    write_json(args.json, batch)
    print(text)
    return batch['exit']


def run_remote(args) -> int:
    files = [p for p in sample_files(args.paths) if p.suffix in SAMPLE_SUFFIXES]
    samples = Samples()
    for path in files:
        text = path.read_text(encoding='utf-8', errors='strict')
        parse_text('\n'.join(line for line in text.splitlines() if re.search(r'(?:metric\s+|\(gx_perf\):\s+)remote\.', line)), samples)
    remote = Samples()
    for name, values in samples.values.items():
        if name.startswith('remote.'):
            for value in values:
                remote.add(name, value, samples.units[name] or None)
    if not remote:
        raise PerfError('no remote.* metrics in fixture logs')
    text, report = summary_table(remote)
    result = {'schema': 'gx-remote-perf-v1', 'metrics': report, 'performance_verdict': 'not evaluated',
              'source_files': [str(p) for p in files], 'units': 'ms for timings; unitless gauges/counts'}
    print(text)
    if args.out:
        out = new_output(args.out)
        (out / 'SUMMARY.txt').write_text(text, encoding='utf-8', newline='\n')
        write_json(out / 'RESULT.json', result)
    write_json(args.json, result)
    return 0


# ---------------------------------------------------------------------------
# Measurement runs
# ---------------------------------------------------------------------------


def resize_evidence(gui, instance, target: Path, index: int, width: int, height: int,
                    report: dict, backdrop) -> float:
    """P7 post-operation evidence, explicitly not a renderer/DWM completion fence."""
    target.mkdir(parents=True, exist_ok=True)
    row = {'index': index, 'target_outer_px': [width, height], 'pid': instance.pid,
           'creation': instance.creation, 'status': 'running', 'strict_final_frame': False,
           'synchronization': 'SetWindowPos return + WM_NULL response; neither proves a presented frame',
           'presentation_scope': 'renderer.present counts entry before SwapBuffers, with no size/frame ID',
           'begin_qpc_ns': time.perf_counter_ns(), 'begin_time_ns': time.time_ns()}
    report.setdefault('resizes', []).append(row)
    path = target / f'resize-{index:02d}.json'
    before = instance.log.read_bytes() if instance.log.exists() else b''
    row['log_start_byte'] = len(before)
    try:
        instance.ensure_foreground()
        elapsed = instance.resize(width, height)
        row.update(setwindowpos_ms=elapsed, proxy_timeout=elapsed >= 16.0,
                   setwindowpos_return_qpc_ns=time.perf_counter_ns())
        row['wm_null_responded'] = instance.responsive(2)
        row['wm_null_return_qpc_ns'] = time.perf_counter_ns()
        info = instance.require_window()
        rect = gui.win32().raw_window_rect(info.hwnd)
        row.update(hwnd=info.hwnd, actual_outer_rect_px=list(rect),
                   actual_outer_px=[rect[2] - rect[0], rect[3] - rect[1]])
        row['target_size_matched'] = row['actual_outer_px'] == row['target_outer_px']
        row['terminals'] = [{'hwnd': term.hwnd, 'rect_px': list(term.rect)} for term in instance.terminals(info)]
        row['capture_begin_qpc_ns'] = time.perf_counter_ns()
        png = target / f'resize-{index:02d}.png'
        backdrop.capture(instance, info, 'screen', png.name).save_png(png)
        row.update(capture_end_qpc_ns=time.perf_counter_ns(), screenshot=str(png),
                   screenshot_sha256=hashlib.sha256(png.read_bytes()).hexdigest(), visual_review='PENDING')
        after = instance.log.read_bytes() if instance.log.exists() else b''
        if not after.startswith(before):
            raise PerfError('resize log truncated or replaced')
        row['log_end_byte'] = len(after)
        segment = after[len(before):]
        (target / f'resize-{index:02d}.segment.raw').write_bytes(segment)
        parsed = arm_samples(segment.decode('utf-8', errors='strict'), report.get('baseline', False))
        full = arm_samples(after.decode('utf-8', errors='strict'), report.get('baseline', False))
        row['presentation_metrics'] = {}
        for name, unit in (('renderer.present', ''), ('surface.resize_timeout', 'ms'), ('surface.resize_wait', 'ms')):
            known = full.units.get(name, report.get('capabilities', {}).get(name))
            if known is not None and known != unit:
                raise PerfError(f'{name}: capability/log unit conflict')
            values = parsed.values.get(name, [])
            row['presentation_metrics'][name] = {'unit': unit, 'n': len(values), 'values': values,
                'status': 'observed' if values else 'supported_zero_events' if known is not None else 'not_instrumented'}
        # surface.resize_timeout is historically record(..., 1), i.e. a 1 us
        # timing marker. Count occurrences; never sum its normalized ms as events.
        row['surface_resize_timeout_events'] = (len(parsed.values.get('surface.resize_timeout', []))
            if row['presentation_metrics']['surface.resize_timeout']['status'] != 'not_instrumented' else None)
        if not row['wm_null_responded']:
            instance.record_input('guard', check='p7_wm_null', status='fail', cause='instance_hung',
                                  reason='P7 WM_NULL did not respond')
            raise PerfError('P7 WM_NULL did not respond', cause='instance_hung')
        row['status'] = 'captured'
        return elapsed
    except Exception as exc:
        row.update(status='failed', error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        row['end_qpc_ns'] = time.perf_counter_ns()
        write_json(path, row)


def measure_win32(gui, exe: Path, env_dir: Path, config: str, resizes: int,
                  env: Mapping[str, str] | None = None, report: dict | None = None) -> list[str]:
    """One Windows run: `metric` lines for startup, a new tab, a split and resizes."""
    instance = gui.launch(exe, env_dir, config=config, env=env)
    report = report if report is not None else {}
    report.update(pid=instance.pid, creation=instance.creation)
    backdrop = gui.Backdrop(gui.BACKDROP_DEFAULT) if resizes else None
    lines = [f"# gx_perf win32 run of {exe} (pid {instance.pid})"]
    try:
        for mark, value in instance.wait_window(30).items():
            lines.append(f"metric startup.{mark.removesuffix('_ms')} {value:.1f} ms")
        instance.activate()
        time.sleep(1.0)
        for name, keys in (("new_tab", NEW_TAB_KEYS), ("split", SPLIT_KEYS)):
            window = instance.require_window()
            before = {info.hwnd for info in gui.win32().child_windows(window.hwnd, gui.TERMINAL_CLASS)}
            began = time.perf_counter()
            instance.press(keys)
            deadline = began + 10
            while True:
                visible = [info for info in instance.terminals(window) if info.hwnd not in before]
                if visible:
                    lines.append(f"metric {name}.terminal_visible {(time.perf_counter() - began) * 1000:.1f} ms")
                    break
                if time.perf_counter() > deadline:
                    raise gui.GuiError(f"{name}: no new visible terminal within 10 s")
                time.sleep(0.0005)
            time.sleep(1.0)
        window = instance.require_window()
        left, top, right, bottom = gui.win32().raw_window_rect(window.hwnd)
        width, height = right - left, bottom - top
        resize_tick = last_input_ticks()[0] if resizes else None
        if backdrop:
            # Establish the largest privacy cover before timing; backdrop capture
            # may itself wait for composition. Its timestamps are recorded below.
            backdrop.ensure(instance, capture=window.rect, band=32)
        for index in range(resizes):
            c7_input_check(gui, instance, argparse.Namespace(state='visible'), resize_tick)
            smaller = index % 2 == 0
            elapsed = resize_evidence(gui, instance, Path(report.get('evidence_dir', env_dir / 'resize-evidence')),
                index + 1, width - 240 if smaller else width, height - 160 if smaller else height, report, backdrop)
            lines.append(f"metric resize.setwindowpos {elapsed:.9f} ms")
            lines.append(f"metric resize.proxy_timeout {int(elapsed >= 16.0)}")
            events = report['resizes'][-1]['surface_resize_timeout_events']
            if events is not None:
                lines.append(f"metric resize.surface_timeout_events {events}")
            c7_input_check(gui, instance, argparse.Namespace(state='visible'), resize_tick)
        lines.append(f"metric responsive {1 if instance.responsive(2) else 0}")
    finally:
        active_error = sys.exc_info()[0] is not None
        report['input_events'] = instance.input_events if isinstance(instance.input_events, list) else []
        if backdrop:
            report['backdrop'] = backdrop.finish()
        try:
            instance.close()
        except gui.GuiError as exc:
            report['cleanup_error'] = str(exc)
            if not active_error:
                raise
        if backdrop and backdrop.teardown_failures() and not active_error:
            raise PerfError('privacy backdrop cleanup failed: ' + '; '.join(backdrop.teardown_failures()))
    return lines


def run_win32(args: argparse.Namespace) -> int:
    sys.path.insert(0, str(SCRIPTS))
    import gx_win_gui as gui

    try:
        gui.env_assignments(args.env)
    except gui.UsageError as exc:
        raise PerfError(str(exc)) from None
    exes = [Path(path).resolve() for path in args.exe]
    if not 1 <= len(exes) <= 2:
        raise PerfError("give one or two --exe")
    for exe in exes:
        if not exe.is_file():
            raise PerfError(f"{exe} does not exist")
    labels = labels_for(len(exes), args.label)
    capabilities = metric_capabilities(getattr(args, 'capabilities', []), labels, exes)
    try:
        environments = label_environments(labels, ['GHOSTTY_GX_PERF=1', *args.env], args.label_env, gui.env_assignments)
    except gui.UsageError as exc:
        raise PerfError(str(exc)) from None
    if any(env.get('GHOSTTY_GX_PERF') != '1' for env in environments.values()):
        raise PerfError('measurement requires GHOSTTY_GX_PERF=1')
    config = Path(args.config).read_text(encoding="utf-8") if args.config else DEFAULT_WIN32_CONFIG
    config += "" if config.endswith("\n") else "\n"
    config += gui.HARNESS_CONFIG
    out = new_output(Path(args.out))
    by_label = dict(zip(labels, exes))
    run_records = []
    run_report = {}
    def failed(label, name, exc):
        target = out / label / name
        log = gui.log_path(out / label / 'env')
        if log.is_file():
            target.with_suffix('.log').write_bytes(log.read_bytes())
        result = {**run_report, 'status': 'failed', 'label': label, 'run': name, 'env': environments[label],
                  'error': str(exc), 'failure_cause': getattr(exc, 'cause', None) or 'other'}
        if getattr(exc, 'instance_pid', None) is not None:
            result['pid'] = exc.instance_pid
        write_json(target.with_suffix('.json'), result)
        write_json(out / 'RESULT.json', {'schema': 'gx-p7-batch-v1', 'status': 'failed',
                   'planned_runs': args.runs, 'planned_resizes_per_run': args.resizes,
                   'runs': run_records, 'failure': result, 'performance_verdict': 'not evaluated'})
        write_json(args.json, result)
        (out / 'SUMMARY.txt').write_text(f'FAILED {label}/{name}: {exc}\n', encoding='utf-8', newline='\n')
        return 1
    for label in labels:
        run_report = {'baseline': len(labels) == 2 and label == labels[0], 'phase': 'warmup',
                      'exe': str(by_label[label]), 'exe_sha256': hashlib.sha256(by_label[label].read_bytes()).hexdigest(),
                      'capabilities': capabilities[label], 'config': config}
        env_dir = out / label / "env"
        gui.prepare_env_dir(env_dir, fresh=True)
        print(f"{TAG} {label}: warm-up run (discarded)", flush=True)
        try:
            measure_win32(gui, by_label[label], env_dir, config, 0, environments[label], run_report)
        except Exception as exc:
            print(f"{TAG} {label}: warm-up failed: {exc}", file=sys.stderr)
            return failed(label, 'warmup-failed', exc)
    for run, label in alternate(labels, args.runs):
        run_report = {'baseline': len(labels) == 2 and label == labels[0], 'phase': 'measurement',
                      'exe': str(by_label[label]), 'exe_sha256': hashlib.sha256(by_label[label].read_bytes()).hexdigest(),
                      'capabilities': capabilities[label], 'config': config,
                      'evidence_dir': str(out / label / f'run-{run:02d}-resize')}
        target = out / label / f"run-{run:02d}.txt"
        env_dir = out / label / "env"
        try:
            lines = measure_win32(gui, by_label[label], env_dir, config, args.resizes, environments[label], run_report)
            if hashlib.sha256(by_label[label].read_bytes()).hexdigest() != run_report['exe_sha256']:
                raise PerfError('executable changed during run')
        except Exception as exc:
            print(f"{TAG} {label} run {run} failed: {exc}", file=sys.stderr)
            return failed(label, f'run-{run:02d}', exc)
        lines.insert(0, "# environment " + json.dumps(environments[label], sort_keys=True))
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
        write_json(target.with_suffix(".json"), {**run_report, "label": label, "run": run, "env": environments[label]})
        run_records.append({'label': label, 'run': run, 'path': str(target.with_suffix('.json').relative_to(out)),
                            'pid': run_report.get('pid'), 'exe_sha256': run_report['exe_sha256'],
                            'resizes': len(run_report.get('resizes', []))})
        log = gui.log_path(env_dir)
        if log.is_file():
            target.with_suffix(".log").write_bytes(log.read_bytes())  # Preserve the resize byte offsets exactly.
        print(f"{TAG} {label} run {run}: " + ", ".join(line.split(None, 1)[1] for line in lines if line.startswith("metric ")
                                                      and not line.startswith("metric resize")), flush=True)
    code = report_runs(out, labels, args.json)
    write_json(out / 'RESULT.json', {'schema': 'gx-p7-batch-v1', 'status': 'captured' if code == 0 else 'failed',
        'planned_runs': args.runs, 'planned_resizes_per_run': args.resizes, 'runs': run_records,
        'strict_final_frame': False, 'visual_review': 'PENDING', 'performance_verdict': 'not evaluated', 'exit': code})
    return code


def run_gtk(args: argparse.Namespace) -> int:
    if getattr(args, "case", "standard") != "standard":
        sys.path.insert(0, str(SCRIPTS))
        import gx_perf_gtk
        return gx_perf_gtk.run(args)
    if getattr(args, "capabilities", []):
        raise PerfError("--capabilities is only supported by gtk --case p2 or p4")
    sys.path.insert(0, str(SCRIPTS))
    import gx_wsl

    try:
        gx_wsl.env_assignments(args.env)
    except gx_wsl.GxWslError as exc:
        raise PerfError(str(exc)) from None
    clones = list(args.clone)
    if not 1 <= len(clones) <= 2:
        raise PerfError("give one or two --clone")
    labels = labels_for(len(clones), args.label)
    try:
        environments = label_environments(labels, args.env, args.label_env, gx_wsl.env_assignments)
    except gx_wsl.GxWslError as exc:
        raise PerfError(str(exc)) from None
    out = Path(args.out)
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        raise PerfError(f"{out}: GTK output must be new or empty; old evidence is never deleted")
    out.mkdir(parents=True, exist_ok=True)
    batch = {"schema": "gx-gtk-runs-v1", "planned_runs": args.runs, "labels": labels, "valid": False,
             "warmup": "none (GTK has no automatic warm-up)", "order": "AB/BA", "env": environments,
             "runs": [{"run": run, "label": label, "path": f"{label}/run-{run:02d}", "exit": None, "status": "pending"}
                      for run, label in alternate(labels, args.runs)]}
    write_json(out / "gtk-runs.json", batch)
    print(f"{TAG} GTK: no automatic warm-up; planned {args.runs} runs per build, AB/BA", flush=True)
    for item in batch["runs"]:
        run, label = item["run"], item["label"]
        clone = clones[labels.index(label)]
        target = out / item["path"]
        argv = ["--clone", clone, "smoke", "--perf", "--out", str(target), "--name", "perf"]
        item["env"] = environments[label]
        for name, value in environments[label].items():
            argv += ["--env", f"{name}={value}"]
        if args.distro:
            argv[:0] = ["--distro", args.distro]
        print(f"{TAG} {label} run {run}: gx_wsl.py {' '.join(argv)}", flush=True)
        item["exit"] = gx_wsl.main(argv)
        item["status"] = "completed" if item["exit"] == 0 else "failed"
        write_json(out / "gtk-runs.json", batch)
    return report_gtk_runs(out, batch, args.json)


def canonical_plan(out: Path, batch: dict, require_valid: bool = False) -> list[tuple[dict, Path]]:
    planned, labels, runs = batch.get("planned_runs"), batch.get("labels"), batch.get("runs")
    if batch.get("schema") != "gx-gtk-runs-v1" or type(planned) is not int or planned < 1 or \
            not isinstance(labels, list) or not 1 <= len(labels) <= 2 or \
            labels_for(len(labels), labels) != labels or not isinstance(runs, list) or batch.get("order") != "AB/BA":
        raise PerfError("malformed GTK canonical plan")
    expected = alternate(labels, planned)
    if len(runs) != len(expected):
        raise PerfError("GTK plan length differs from planned_runs")
    root = out.resolve()
    paths = set()
    result = []
    for item, (run, label) in zip(runs, expected):
        relative = f"{label}/run-{run:02d}"
        if not isinstance(item, dict) or type(item.get("run")) is not int or \
                (item.get("label"), item.get("run"), item.get("path")) != (label, run, relative):
            raise PerfError("GTK plan is not the unique canonical AB/BA sequence")
        target = root / label / f"run-{run:02d}"
        resolved = target.resolve()
        key = os.path.normcase(str(resolved))
        if not resolved.is_relative_to(root) or (root / label).is_symlink() or target.is_symlink() or key in paths:
            raise PerfError("GTK run path is not unique within owned output")
        paths.add(key)
        if require_valid and (batch.get("valid") is not True or item.get("exit") != 0 or item.get("status") != "valid" or
                              not re.fullmatch(r"[0-9a-f]{64}", item.get("meta_sha256", ""))):
            raise PerfError("incomplete or failed planned GTK runs")
        result.append((item, target))
    return result


def report_gtk_runs(out: Path, batch: dict, json_path: Path | None) -> int:
    try:
        plan = canonical_plan(out, batch)
    except PerfError as exc:
        text = "GTK comparison rejected: " + str(exc) + "\n"
        batch["valid"], batch["errors"] = False, [str(exc)]
        write_json(out / "gtk-runs.json", batch)
        write_json(out / "RESULT.json", {"validation": {"status": "rejected", "errors": [str(exc)]}})
        write_json(json_path, {"validation": {"status": "rejected", "errors": [str(exc)]}})
        (out / "SUMMARY.txt").write_text(text, encoding="utf-8")
        print(text, end="")
        return 1
    sets = {label: Samples() for label in batch["labels"]}
    identities = {}
    captures = set()
    errors = []
    for item, target in plan:
        try:
            if item["exit"] != 0:
                raise PerfError(f"run exit {item['exit']}")
            manifest = target / "perf-meta.json"
            digest = hashlib.sha256(manifest.read_bytes()).hexdigest() if manifest.is_file() and not manifest.is_symlink() else ""
            if not digest or item.get("meta_sha256", digest) != digest:
                raise PerfError("missing or changed canonical run manifest")
            meta, samples = gtk_evidence(manifest)
            if not meta.get("perf"):
                raise PerfError("not a GTK perf run")
            if meta.get("capture_id") in captures:
                raise PerfError("duplicate actual capture in GTK plan")
            captures.add(meta.get("capture_id"))
            item["meta_sha256"] = digest
            signature = (meta["identity"]["sha256"], meta["version"], meta["commit"], meta["tree"], meta["dirty"],
                         meta["effective_env"] | {"DISPLAY": None, "XDG_CONFIG_HOME": None, "XDG_STATE_HOME": None})
            previous = identities.setdefault(item["label"], signature)
            if previous != signature:
                raise PerfError("build identity or effective environment changed within a label")
            item["status"] = "valid"
            sets[item["label"]].extend(samples)
        except PerfError as exc:
            item["status"], item["error"] = "rejected", str(exc)
            errors.append(f"{item['label']} run {item['run']}: {exc}")
    ordered = [sets[label] for label in batch["labels"]]
    for label, samples in sets.items():
        errors.extend(f'{label} {error}' for error in gtk_sample_errors(samples, batch['planned_runs']))
    if len(ordered) == 2:
        errors.extend(comparison_errors(*ordered, gtk=True, runs=batch["planned_runs"]))
    batch["valid"] = not errors
    batch["errors"] = errors
    batch["valid_runs"] = {label: len(samples.gtk_runs) for label, samples in sets.items()}
    write_json(out / "gtk-runs.json", batch)
    names = set(GTK_REQUIRED).union(*(s.values for s in ordered))
    result = {"validation": {"status": "rejected" if errors else "valid",
                             "identity": "verified" if all(len(s.gtk_runs) == batch["planned_runs"] for s in ordered) else "incomplete",
                             "renderer_path": "unknown", "performance_verdict": "not evaluated",
                             "cpu_contract": "quantized process/endpoint ticks; residual bounds diagnostic-only and unproved",
                             "planned_runs": batch["planned_runs"], "valid_runs": batch["valid_runs"], "errors": errors,
                             "metric_coverage": {label: metric_coverage(s, batch['planned_runs'], names) for label, s in sets.items()},
                             "metric_comparability": {name: metric_comparability(*ordered, name) for name in sorted(names)} if len(ordered) == 2 else {},
                             "optional_metrics_complete": "not asserted; unknown/missing sides remain absent, never synthesized as zero"}}
    if errors:
        text = "GTK comparison rejected; no performance verdict.\n" + "\n".join(errors) + "\n"
    else:
        text, result["metrics"] = compare_table(*ordered, tuple(batch["labels"])) if len(ordered) == 2 else summary_table(ordered[0])
    print(text, end="")
    (out / "SUMMARY.txt").write_text(text, encoding="utf-8")
    write_json(out / "RESULT.json", result)
    write_json(json_path, result)
    return (1 if any(ordered) or any(item["exit"] for item in batch["runs"]) else 2) if errors else 0


def report_runs(out: Path, labels: Sequence[str], json_path: Path | None) -> int:
    batch_path = out / "gtk-runs.json"
    if batch_path.is_file():
        return report_gtk_runs(out, read_json(batch_path), json_path)
    sets = [collect([out / label]) if (out / label).exists() else Samples() for label in labels]
    if len(sets) == 2:
        historical_names(sets[0])
    if not any(sets):
        print(f"{TAG} error: no samples in {out}", file=sys.stderr)
        return 2
    if any(name.startswith("cpu.") for samples in sets for name in samples.values):
        text = "GTK standard report rejected: missing planned-run manifest; identity unverified. Use compare for historical timing only.\n"
        print(text, end="")
        (out / "SUMMARY.txt").write_text(text, encoding="utf-8")
        write_json(json_path, {"_validation": {"status": "rejected", "identity": "unverified", "errors": [text.strip()]}})
        return 1
    if len(labels) == 2:
        text, report = compare_table(sets[0], sets[1], (labels[0], labels[1]))
    else:
        text, report = summary_table(sets[0])
    print(text, end="")
    (out / "SUMMARY.txt").write_text(text, encoding="utf-8")
    write_json(json_path, report)
    return 0


def build_parser() -> argparse.ArgumentParser:
    doc = __doc__ or ""
    parser = argparse.ArgumentParser(prog="gx_perf.py", description=doc.splitlines()[0], epilog=doc.split("\n", 2)[2],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    summarize = commands.add_parser("summarize", allow_abbrev=False, help="summarize samples")
    summarize.add_argument("paths", nargs="+", type=Path, metavar="PATH")
    summarize.add_argument("--json", type=Path)
    compare = commands.add_parser("compare", allow_abbrev=False, help="compare two sample sets")
    compare.add_argument("--old", nargs="+", type=Path, required=True, metavar="PATH")
    compare.add_argument("--new", nargs="+", type=Path, required=True, metavar="PATH")
    compare.add_argument("--json", type=Path)
    win32 = commands.add_parser("win32", allow_abbrev=False, help="measure Windows builds")
    win32.add_argument("--exe", action="append", required=True, metavar="PATH")
    win32.add_argument("--label", action="append", default=[])
    win32.add_argument("--out", type=Path, required=True)
    win32.add_argument("--runs", type=int, default=10)
    win32.add_argument("--resizes", type=int, default=6)
    win32.add_argument("--config", type=Path, help="config.ghostty for the runs (default: cmd.exe, English UI)")
    win32.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                       help="environment variable for every run, e.g. GHOSTTY_GX_PERF=1 (repeatable)")
    win32.add_argument("--json", type=Path)
    win32.add_argument("--label-env", action="append", default=[], metavar="LABEL:NAME=VALUE")
    win32.add_argument('--capabilities', action='append', default=[], metavar='LABEL:JSON')
    gtk = commands.add_parser("gtk", allow_abbrev=False, help="measure GTK builds in WSL clones")
    gtk.add_argument("--clone", action="append", required=True, metavar="PATH")
    gtk.add_argument("--case", choices=("standard", "p2", "p4"), default="standard")
    gtk.add_argument("--capabilities", action="append", default=[], metavar="LABEL:JSON_FILE",
                     help="P2/P4 source/exe-bound instrumentation declaration; missing means unknown")
    gtk.add_argument("--label", action="append", default=[])
    gtk.add_argument("--distro")
    gtk.add_argument("--out", type=Path, required=True)
    gtk.add_argument("--runs", type=int, default=10)
    gtk.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                     help="passed to every `smoke --perf` as --env (repeatable)")
    gtk.add_argument("--json", type=Path)
    gtk.add_argument("--label-env", action="append", default=[], metavar="LABEL:NAME=VALUE")
    quiet = commands.add_parser("quiet", allow_abbrev=False, help="read-only quiet-window checks (0 quiet, 3 busy, 2 error)")
    quiet.add_argument("--out", type=Path, required=True)
    quiet.add_argument("--json", type=Path)
    quiet.add_argument("--slot-root", type=Path)
    quiet.add_argument("--distro", default="Ubuntu-24.04")
    quiet.add_argument("--idle-seconds", type=float, default=600)
    quiet.add_argument("--build-process", action="append", help="add build process names (repeatable)")
    quiet.add_argument("--blacklist", action="append",
                       help="add case-insensitive name/title substrings to the recorded blacklist (repeatable)")
    quiet.add_argument("--strict-blacklist", action="store_true",
                       help="make the blacklist a gate again (the criteria before the r6 13:20 user ruling)")
    quiet.add_argument("--input-observe-only", action="store_true",
                       help="record user input instead of gating it (polling before a WSL/Xvfb-only batch)")
    quiet.add_argument("--observe", action="append", help="add name/title substrings recorded as other programs, never a gate")
    quiet.add_argument("--wait", action="store_true")
    quiet.add_argument("--interval", type=float, default=900)
    quiet.add_argument("--max-attempts", type=int, default=3)
    batch = commands.add_parser('quiet-batch', allow_abbrev=False, help='hold all slots, check before/after a bounded command')
    batch.add_argument('--out', type=Path, required=True)
    batch.add_argument('--json', type=Path)
    batch.add_argument('--slot-root', type=Path)
    batch.add_argument('--distro', default='Ubuntu-24.04')
    batch.add_argument('--idle-seconds', type=float, default=600)
    batch.add_argument('--build-process', action='append')
    batch.add_argument('--blacklist', action='append',
                       help='add case-insensitive name/title substrings to the recorded blacklist (repeatable)')
    batch.add_argument('--strict-blacklist', action='store_true',
                       help='make the blacklist a gate again (the criteria before the r6 13:20 user ruling)')
    batch.add_argument('--observe', action='append', help='add name/title substrings recorded as other programs, never a gate')
    batch.add_argument('--timeout', type=float, default=0)
    batch.add_argument('--frozen-collector', type=Path, help='explicit reviewed external C1 manifest (no implicit wrapper exemption)')
    batch.add_argument('--frozen-collector-sha256', help='full manifest SHA256 selected by the reviewer; rechecked inside the lease')
    input_mode = batch.add_mutually_exclusive_group()
    input_mode.add_argument('--injected-input', action='store_true',
                            help='the command may send input through gx_win_gui (all win32-* drivers): judge input by the '
                                 "batch's guard log; a batch that sent none falls back to no input since the start check")
    input_mode.add_argument('--input-observe-only', action='store_true',
                            help='a batch that runs only in WSL/Xvfb (C1, C5, P9): record the start idle time and the end '
                                 'input check without gating; refuses Windows-desktop drivers')
    batch.add_argument('batch_command', nargs=argparse.REMAINDER)
    remote = commands.add_parser('remote', allow_abbrev=False, help='summarize remote.* fixture logs only')
    remote.add_argument('paths', nargs='+', type=Path)
    remote.add_argument('--out', type=Path)
    remote.add_argument('--json', type=Path)
    for name in WIN32_DRIVERS:
        experiment = commands.add_parser(name, allow_abbrev=False, help='isolated AB/BA Windows measurement')
        experiment.add_argument('--exe', action='append', required=True)
        experiment.add_argument('--label', action='append', default=[])
        experiment.add_argument('--env', action='append', default=[])
        experiment.add_argument('--label-env', action='append', default=[], metavar='LABEL:NAME=VALUE')
        experiment.add_argument('--out', type=Path, required=True)
        experiment.add_argument('--json', type=Path)
        experiment.add_argument('--config', type=Path)
        experiment.add_argument('--runs', type=int, default=10, help='runs per label; odd rounds AB, even rounds BA')
        experiment.add_argument('--diagnostic', action='store_true', help='development smoke; allow absent timing instrumentation')
        experiment.add_argument('--uninstrumented', action='append', default=[], metavar='LABEL', help='explicit historical arm; missing metrics are n=0, never fabricated zero')
        experiment.add_argument('--capabilities', action='append', default=[], metavar='LABEL:JSON', help='hash-bound instrumentation declaration, needed to certify zero-event counters')
        if name == 'win32-ui':
            experiment.add_argument('--case', choices=('p3', 'p4', 'p5', 'p6'), required=True)
        if name == 'win32-idle':
            experiment.add_argument('--tabs', type=int, default=1)
            experiment.add_argument('--windows', type=int, default=1)
            experiment.add_argument('--state', choices=('visible', 'unfocused', 'minimized'), default='visible')
            experiment.add_argument('--seconds', type=float, default=60)
        if name == 'win32-c7':
            import gx_perf_stimulus as stimulus
            experiment.add_argument('--case', choices=('matrix', *stimulus.CASES, *stimulus.ANIMATION_CASES), default='matrix')
            experiment.add_argument('--tabs', type=int, choices=(1, 11), default=1)
            experiment.add_argument('--seconds', type=float, default=60)
            experiment.add_argument('--output-bytes', type=int, default=4096,
                                    help='bytes written by EACH owned terminal at the midpoint')
            experiment.set_defaults(windows=1, state='visible')
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (OSError, ValueError):
                pass
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    # Reject this output before entering the generic error-reporting handler:
    # even a rejection report must not overwrite a frozen batch's evidence.
    if (args.command == 'quiet-batch' and args.json is not None and
            (args.frozen_collector is not None or args.frozen_collector_sha256 is not None)):
        print(f"{TAG} error: frozen collector forbids outer --json", file=sys.stderr)
        return 2
    try:
        if args.command == "quiet":
            return run_quiet(args)
        if args.command == 'quiet-batch':
            return run_quiet_batch(args)
        if args.command == 'remote':
            return run_remote(args)
        if args.command == "summarize":
            samples = collect(args.paths)
            if not samples:
                print(f"{TAG} error: no samples in {', '.join(map(str, args.paths))}", file=sys.stderr)
                return 2
            text, report = summary_table(samples)
            report["_validation"] = validation([samples])
            print(f"{TAG} identity: {report['_validation']['identity']} (summary is not a performance gate)")
            print(text, end="")
            write_json(args.json, report)
            return 0
        if args.command == "compare":
            old, new = historical_names(collect(args.old)), collect(args.new)
            if not old or not new:
                raise PerfError(f"no samples on the {'old' if not old else 'new'} side")
            errors = comparison_errors(old, new)
            if errors:
                raise PerfError("comparison rejected: " + "; ".join(errors))
            text, report = compare_table(old, new)
            report["_validation"] = validation([old, new])
            print(f"{TAG} identity: {report['_validation']['identity']} (unverified history cannot prove the GTK gate)")
            print(text, end="")
            write_json(args.json, report)
            return 0
        if args.runs < 1:
            raise PerfError("--runs must be at least 1")
        if args.command.startswith('win32-'):
            if args.command == 'win32-c7':
                if (not math.isfinite(args.seconds) or args.seconds < 2 or
                        not 64 <= args.output_bytes <= 1048576):
                    raise PerfError('C7 requires seconds >= 2 and output bytes in [64, 1048576]')
                if not args.diagnostic and (args.seconds != 60 or args.runs != 10 or len(args.exe) != 2):
                    raise PerfError('C7 requires 60 seconds, 10 AB/BA pairs and two builds (or explicit --diagnostic)')
                args.state = args.case if args.case in ('unfocused', 'minimized') else 'visible'
                if args.case == 'matrix':
                    return run_c7_matrix(args)
            if args.command == 'win32-idle' and (not 1 <= args.tabs <= 64 or not 1 <= args.windows <= 16 or
                                                not math.isfinite(args.seconds) or args.seconds <= 0):
                raise PerfError('invalid --tabs, --windows or --seconds')
            return run_experiment(args)
        if args.command == "win32":
            if args.resizes < 0:
                raise PerfError('--resizes must be nonnegative')
            return run_win32(args)
        return run_gtk(args)
    except (PerfError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"{TAG} error: {exc}", file=sys.stderr)
        write_json(args.json, {"_validation": {"status": "rejected", "identity": "unverified", "errors": [str(exc)]}})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
