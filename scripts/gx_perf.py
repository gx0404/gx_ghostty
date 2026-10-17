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

Samples come from these lines:
  - `info(gx_perf): <metric> <value>us` written when GHOSTTY_GX_PERF=1 (src/gx/perf.zig);
    historical ns/ms/s time lines are also accepted, not counts;
  - `metric <name> <value> [s|ms|us]` from `gx_wsl.py smoke --perf` and from this tool's runs;
  - the Debug-build log line `window shown after <n>ms first_frame=<bool>` (log.window_shown);
  - the `startup_ms` block of a scripts/gx_win_gui.py run.json (startup.<mark>).
Times are reported in milliseconds; metrics without a unit are counts. p90 is the nearest-rank
90th percentile. Exit codes: 0 success, 1 a failed measurement run, 2 usage errors or no samples.
"""

from __future__ import annotations

import argparse
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
    """A usage problem (exit 2)."""


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
    for name in old.units.keys() & new.units.keys():
        if old.units[name] != new.units[name]:
            raise PerfError(f"metric {name}: time/count unit conflict")
    rows = [f"{'metric':<34} {'unit':<4} {a + ' n':>6} {a + ' med':>10} {a + ' p90':>10} "
            f"{b + ' n':>6} {b + ' med':>10} {b + ' p90':>10} {'Δ med':>10} {'Δ%':>7} {a + ' sum':>10} {b + ' sum':>10}"]
    report = {}
    for name in sorted(set(old.values) | set(new.values)):
        unit = old.units.get(name) or new.units.get(name, "")
        left = stats(old.values[name], unit) if old.values.get(name) else None
        right = stats(new.values[name], unit) if new.values.get(name) else None
        entry: dict = {"unit": unit, a: left, b: right}
        cells = []
        for side in (left, right):
            cells += [f"{side['n']:>6}", f"{fmt(side['median'], unit):>10}", f"{fmt(side['p90'], unit):>10}"] if side \
                else [f"{'-':>6}", f"{'-':>10}", f"{'-':>10}"]
        if left and right:
            delta = right["median"] - left["median"]
            percent = (delta / left["median"] * 100) if left["median"] else float("nan")
            entry["delta_median"], entry["delta_percent"] = delta, percent if math.isfinite(percent) else None
            cells += [f"{('+' if delta >= 0 else '') + fmt(delta, unit):>10}",
                      f"{'n/a' if math.isnan(percent) else f'{percent:+.1f}':>7}"]
        else:
            cells += [f"{'-':>10}", f"{'-':>7}"]
        report[name] = entry
        cells += [f"{fmt(side['sum'], unit) if side and not unit else '-':>10}" for side in (left, right)]
        rows.append(f"{name:<34} {unit:<4} " + " ".join(cells))
    return "\n".join(rows) + "\n", report


def comparison_errors(old: Samples, new: Samples, gtk: bool = False, runs: int | None = None) -> list[str]:
    errors = []
    if gtk or any(name.startswith("cpu.") for name in set(old.values) | set(new.values)):
        for side, samples in (("old", old), ("new", new)):
            for name in GTK_REQUIRED:
                values = samples.values.get(name, [])
                expected = runs if runs is not None else len(samples.values.get("cpu.main", []))
                if not values or len(values) != expected or samples.units.get(name) != "ms" or any(value < 0 for value in values):
                    errors.append(f"{side} {name}: requires {expected} time samples, got {len(values)}")
    for name in sorted(set(old.values) | set(new.values)):
        if not old.values.get(name) or not new.values.get(name):
            errors.append(f"{name}: metric missing on one side")
        elif len(old.values[name]) != len(new.values[name]):
            errors.append(f"{name}: sample counts differ ({len(old.values[name])} vs {len(new.values[name])})")
        elif old.units[name] != new.units[name]:
            errors.append(f"{name}: time/count unit conflict")
    return errors


def validation(samples: Sequence[Samples]) -> dict:
    return {"status": "valid", "identity": "unverified" if any(s.unverified for s in samples) else "verified",
            "verified_gtk_runs": [len(s.gtk_runs) for s in samples],
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
BLACKLIST = ("Devin", "devin", "ToDesk", "Kimi Code", "哔哩哔哩")
BUILD_RUNNER_RE = r'(?:run_unittests\.py|zig_test\.py|zigw\.py\s+build|(?:^|\s)-m\s+(?:unittest|pytest)(?:\s|$)|(?:^|[/\\\s])test_[^\s]+\.py)'


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
    # Worktrees must contend with the main checkout, not with worktree-local locks.
    common = command_output(["git", "-C", str(REPO_ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"]).strip()
    return Path(common).parent / ".local" / "kernel-slots"


def user_idle_seconds() -> float:
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
    return ((kernel.GetTickCount() - info.dwTime) & 0xFFFFFFFF) / 1000


def process_name(name: str) -> str:
    return name.replace("\\", "/").rsplit("/", 1)[-1].casefold().removesuffix(".exe")


class QuietProbe:
    def windows(self) -> list[dict]:
        data = powershell_json("$runners=@{}; Get-CimInstance Win32_Process | ForEach-Object {"
                               f"$runners[[int]$_.ProcessId]=[bool]($_.CommandLine -match '{BUILD_RUNNER_RE}')}}; "
                               "@(Get-Process | Select-Object @{n='pid';e={$_.Id}},"
                               "@{n='name';e={$_.ProcessName}},@{n='title';e={$_.MainWindowTitle}},"
                               "@{n='build_runner';e={$runners[$_.Id]}}) | ConvertTo-Json -Compress")
        if not isinstance(data, list) or not data:
            raise PerfError("Windows process inventory is missing")
        return data

    def wsl(self, distro: str) -> dict:
        running = command_output(["wsl.exe", "--list", "--running", "--quiet"])
        if distro.casefold() not in {line.strip().casefold() for line in running.splitlines()}:
            return {"distro": distro, "running": False, "processes": []}
        output = command_output(["wsl.exe", "--distribution", distro, "--exec", "ps", "-eo", "pid=,comm=,args="])
        rows = []
        for line in output.splitlines():
            pid, name, argv = line.strip().split(None, 2)
            rows.append({"pid": int(pid), "name": name, "build_runner": bool(re.search(BUILD_RUNNER_RE, argv))})
        if not rows:
            raise PerfError("WSL process inventory is empty")
        return {"distro": distro, "running": True, "processes": rows}

    def vm(self, slots: Path) -> dict:
        # status historically treats a failed docker inspect as an absent VM.
        # Verify daemon access first so an unavailable daemon cannot look quiet.
        docker = os.environ.get("GX_GHOSTTY_DOCKER", "docker")
        command_output([docker, "info", "--format", "{{json .ServerVersion}}"])
        data = json.loads(command_output([sys.executable, str(SCRIPTS / "gx_windows_vm.py"), "status",
                                         "--root", str(slots.parent / "windows-vm")]))
        if not isinstance(data, dict) or not data or any(not isinstance(row, dict) or
                type(row.get("running")) is not bool or type(row.get("exists")) is not bool for row in data.values()):
            raise PerfError("VM status is incomplete")
        return data

    def slots(self, root: Path) -> bool:
        import gx_slots
        try:
            with gx_slots.acquire(root, "quiet", timeout=0):
                pass
            return True
        except TimeoutError:
            return False

    def idle(self) -> float:
        return user_idle_seconds()

    def cpu(self) -> dict:
        return powershell_json("@{cpu=@(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | "
                               "Where-Object Name -eq '_Total' | Select-Object PercentProcessorTime); "
                               "top=@(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | "
                               "Where-Object {$_.IDProcess -ne 0 -and $_.Name -ne '_Total'} | "
                               "Sort-Object PercentProcessorTime -Descending | Select-Object -First 10 "
                               "IDProcess,Name,PercentProcessorTime)} | ConvertTo-Json -Depth 5 -Compress")


def quiet_snapshot(args, probe=None) -> dict:
    probe = probe or QuietProbe()
    checks = {}
    def check(name, operation, assess):
        try:
            raw = operation()
            passed, reason = assess(raw)
            checks[name] = {"status": "pass" if passed else "fail", "reason": reason, "raw": raw}
        except (OSError, ValueError, PerfError, subprocess.SubprocessError) as exc:
            checks[name] = {"status": "error", "reason": str(exc)}
    builds = {process_name(name) for name in (args.build_process or BUILD_PROCESSES)}
    blacklist = [name.casefold() for name in (args.blacklist or BLACKLIST)]
    def build_check(rows):
        found = [row for row in rows if process_name(row['name']) in builds or row.get('build_runner')]
        return not found, "no build/test processes" if not found else f"build/test processes: {found}"
    check("windows", probe.windows, build_check)
    windows = checks["windows"]
    if windows['status'] == 'error':
        checks['blacklist'] = {"status": "error", "reason": "Windows inventory unavailable"}
    else:
        found = [row for row in windows['raw'] if any(name in row['name'].casefold() or
                 name in row.get('title', '').casefold() for name in blacklist)]
        checks['blacklist'] = {"status": "fail" if found else "pass", "raw": found,
                               "reason": "blacklisted process present" if found else "no blacklisted processes"}
    check("wsl", lambda: probe.wsl(args.distro), lambda data: build_check(data['processes']))
    check("vm", lambda: probe.vm(args.slot_root), lambda data: (
        not any(row['running'] for row in data.values()),
        "all validation VM containers stopped" if not any(row['running'] for row in data.values()) else "VM container running"))
    check("slots", lambda: probe.slots(args.slot_root), lambda free: (free, "all four locks acquired and released" if free else "slot occupied"))
    check("input", probe.idle, lambda seconds: (seconds >= args.idle_seconds, f"idle {seconds:.3f}s; required {args.idle_seconds:g}s"))
    try:
        observation = {"status": "recorded", "raw": probe.cpu()}
    except (OSError, ValueError, PerfError, subprocess.SubprocessError) as exc:
        observation = {"status": "unavailable", "reason": str(exc)}
    code = 2 if any(row['status'] == 'error' for row in checks.values()) else (
        3 if any(row['status'] == 'fail' for row in checks.values()) else 0)
    return {"schema": "gx-quiet-v1", "time_ns": time.time_ns(), "quiet": code == 0, "exit": code,
            "slot_root": str(args.slot_root), "checks": checks, "cpu_observation": observation,
            "build_processes": sorted(builds), "blacklist": blacklist,
            "scope": "point-in-time probe; locks released, not a reservation"}


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


# ---------------------------------------------------------------------------
# Measurement runs
# ---------------------------------------------------------------------------


def measure_win32(gui, exe: Path, env_dir: Path, config: str, resizes: int,
                  env: Mapping[str, str] | None = None) -> list[str]:
    """One Windows run: `metric` lines for startup, a new tab, a split and resizes."""
    instance = gui.launch(exe, env_dir, config=config, env=env)
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
        for index in range(resizes):
            smaller = index % 2 == 0
            elapsed = instance.resize(width - 240 if smaller else width, height - 160 if smaller else height)
            lines.append(f"metric resize.setwindowpos {elapsed:.2f} ms")
            time.sleep(0.4)
        lines.append(f"metric responsive {1 if instance.responsive(2) else 0}")
    finally:
        try:
            instance.close()
        except gui.GuiError:
            pass
    return lines


def run_win32(args: argparse.Namespace) -> int:
    sys.path.insert(0, str(SCRIPTS))
    import gx_win_gui as gui

    try:
        env = gui.env_assignments(args.env)
    except gui.UsageError as exc:
        raise PerfError(str(exc)) from None
    exes = [Path(path).resolve() for path in args.exe]
    if not 1 <= len(exes) <= 2:
        raise PerfError("give one or two --exe")
    for exe in exes:
        if not exe.is_file():
            raise PerfError(f"{exe} does not exist")
    labels = labels_for(len(exes), args.label)
    try:
        environments = label_environments(labels, args.env, args.label_env, gui.env_assignments)
    except gui.UsageError as exc:
        raise PerfError(str(exc)) from None
    config = Path(args.config).read_text(encoding="utf-8") if args.config else DEFAULT_WIN32_CONFIG
    config += "" if config.endswith("\n") else "\n"
    config += gui.HARNESS_CONFIG
    out = Path(args.out)
    by_label = dict(zip(labels, exes))
    failures = 0
    for label in labels:
        env_dir = out / label / "env"
        gui.prepare_env_dir(env_dir, fresh=True)
        print(f"{TAG} {label}: warm-up run (discarded)", flush=True)
        try:
            measure_win32(gui, by_label[label], env_dir, config, 0, environments[label])
        except gui.GuiError as exc:
            print(f"{TAG} {label}: warm-up failed: {exc}", file=sys.stderr)
    for run, label in alternate(labels, args.runs):
        target = out / label / f"run-{run:02d}.txt"
        env_dir = out / label / "env"
        for attempt in (1, 2):
            try:
                lines = measure_win32(gui, by_label[label], env_dir, config, args.resizes, environments[label])
                break
            except gui.GuiError as exc:
                print(f"{TAG} {label} run {run} attempt {attempt} failed: {exc}", file=sys.stderr)
                lines = None
        if lines is None:
            failures += 1
            continue
        lines.insert(0, "# environment " + json.dumps(environments[label], sort_keys=True))
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
        write_json(target.with_suffix(".json"), {"label": label, "run": run, "env": environments[label]})
        log = gui.log_path(env_dir)
        if log.is_file():
            target.with_suffix(".log").write_text(log.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
        print(f"{TAG} {label} run {run}: " + ", ".join(line.split(None, 1)[1] for line in lines if line.startswith("metric ")
                                                      and not line.startswith("metric resize")), flush=True)
    return report_runs(out, labels, args.json) or (1 if failures else 0)


def run_gtk(args: argparse.Namespace) -> int:
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
        for name in GTK_REQUIRED:
            if len(samples.values.get(name, [])) != batch["planned_runs"]:
                errors.append(f"{label} {name}: {len(samples.values.get(name, []))}/{batch['planned_runs']} planned samples")
    if len(ordered) == 2:
        errors.extend(comparison_errors(*ordered, gtk=True, runs=batch["planned_runs"]))
    batch["valid"] = not errors
    batch["errors"] = errors
    batch["valid_runs"] = {label: len(samples.gtk_runs) for label, samples in sets.items()}
    write_json(out / "gtk-runs.json", batch)
    result = {"validation": {"status": "rejected" if errors else "valid",
                             "identity": "verified" if all(len(s.gtk_runs) == batch["planned_runs"] for s in ordered) else "incomplete",
                             "renderer_path": "unknown", "performance_verdict": "not evaluated",
                             "cpu_contract": "quantized process/endpoint ticks; residual bounds diagnostic-only and unproved",
                             "planned_runs": batch["planned_runs"], "valid_runs": batch["valid_runs"], "errors": errors}}
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
    gtk = commands.add_parser("gtk", allow_abbrev=False, help="measure GTK builds in WSL clones")
    gtk.add_argument("--clone", action="append", required=True, metavar="PATH")
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
    quiet.add_argument("--build-process", action="append", help="replace default build process names (repeatable)")
    quiet.add_argument("--blacklist", action="append", help="replace default name/title substrings (repeatable)")
    quiet.add_argument("--wait", action="store_true")
    quiet.add_argument("--interval", type=float, default=900)
    quiet.add_argument("--max-attempts", type=int, default=3)
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
    try:
        if args.command == "quiet":
            return run_quiet(args)
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
            old, new = collect(args.old), collect(args.new)
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
        if args.command == "win32":
            return run_win32(args)
        return run_gtk(args)
    except PerfError as exc:
        print(f"{TAG} error: {exc}", file=sys.stderr)
        write_json(args.json, {"_validation": {"status": "rejected", "identity": "unverified", "errors": [str(exc)]}})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
