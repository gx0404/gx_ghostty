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
        The same for GTK builds through `scripts/gx_wsl.py smoke --perf` in WSL clones
        (each clone must have a GTK build); DIR/<label>/run-NN/ holds each smoke's evidence.

Samples come from these lines:
  - `info(gx_perf): <metric> <value><unit>` (unit ns, us, ms or s) written when
    GHOSTTY_GX_PERF=1 (src/gx/perf.zig);
  - `metric <name> <value> [s|ms|us]` from `gx_wsl.py smoke --perf` and from this tool's runs;
  - the Debug-build log line `window shown after <n>ms first_frame=<bool>` (log.window_shown);
  - the `startup_ms` block of a scripts/gx_win_gui.py run.json (startup.<mark>).
Times are reported in milliseconds; metrics without a unit are counts. p90 is the nearest-rank
90th percentile. Exit codes: 0 success, 1 a failed measurement run, 2 usage errors or no samples.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import statistics
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

    def add(self, name: str, value: float, unit: str | None) -> None:
        self.values.setdefault(name, []).append(to_ms(value, unit))
        self.units.setdefault(name, "" if unit is None else "ms")

    def extend(self, other: "Samples") -> None:
        for name, values in other.values.items():
            for value in values:
                self.values.setdefault(name, []).append(value)
            self.units.setdefault(name, other.units[name])

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


def sample_files(paths: Iterable[Path]) -> list[Path]:
    files = []
    for path in paths:
        if path.is_dir():
            files += sorted(p for p in path.rglob("*") if p.is_file() and (p.suffix in SAMPLE_SUFFIXES or p.name == "run.json")
                            and not in_profile(p, path))
        elif path.is_file():
            files.append(path)
        else:
            raise PerfError(f"{path} does not exist")
    return files


def collect(paths: Iterable[Path]) -> Samples:
    samples = Samples()
    for path in sample_files(paths):
        if path.name == "run.json":
            try:
                parse_run_json(json.loads(path.read_text(encoding="utf-8")), samples)
            except (ValueError, OSError):
                continue
        else:
            parse_text(path.read_text(encoding="utf-8", errors="replace"), samples)
    return samples


def p90(values: Sequence[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.9 * len(ordered)) - 1)]


def stats(values: Sequence[float]) -> dict[str, float]:
    return {"n": len(values), "median": statistics.median(values), "p90": p90(values), "min": min(values),
            "max": max(values)}


def fmt(value: float, unit: str) -> str:
    return f"{value:.1f}" if unit == "ms" else (f"{value:.0f}" if float(value).is_integer() else f"{value:.2f}")


def summary_table(samples: Samples) -> tuple[str, dict]:
    rows = [f"{'metric':<34} {'unit':<4} {'n':>4} {'median':>10} {'p90':>10} {'min':>10} {'max':>10}"]
    report = {}
    for name in sorted(samples.values):
        values = samples.values[name]
        if not values:
            continue
        unit = samples.units[name]
        summary = stats(values)
        report[name] = {"unit": unit, **summary}
        rows.append(f"{name:<34} {unit:<4} {summary['n']:>4} {fmt(summary['median'], unit):>10} "
                    f"{fmt(summary['p90'], unit):>10} {fmt(summary['min'], unit):>10} {fmt(summary['max'], unit):>10}")
    return "\n".join(rows) + "\n", report


def compare_table(old: Samples, new: Samples, labels: tuple[str, str] = ("old", "new")) -> tuple[str, dict]:
    a, b = labels
    rows = [f"{'metric':<34} {'unit':<4} {a + ' n':>6} {a + ' med':>10} {a + ' p90':>10} "
            f"{b + ' n':>6} {b + ' med':>10} {b + ' p90':>10} {'Δ med':>10} {'Δ%':>7}"]
    report = {}
    for name in sorted(set(old.values) | set(new.values)):
        unit = old.units.get(name) or new.units.get(name, "")
        left = stats(old.values[name]) if old.values.get(name) else None
        right = stats(new.values[name]) if new.values.get(name) else None
        entry: dict = {"unit": unit, a: left, b: right}
        cells = []
        for side in (left, right):
            cells += [f"{side['n']:>6}", f"{fmt(side['median'], unit):>10}", f"{fmt(side['p90'], unit):>10}"] if side \
                else [f"{'-':>6}", f"{'-':>10}", f"{'-':>10}"]
        if left and right:
            delta = right["median"] - left["median"]
            percent = (delta / left["median"] * 100) if left["median"] else float("nan")
            entry["delta_median"], entry["delta_percent"] = delta, percent
            cells += [f"{('+' if delta >= 0 else '') + fmt(delta, unit):>10}",
                      f"{'n/a' if math.isnan(percent) else f'{percent:+.1f}':>7}"]
        else:
            cells += [f"{'-':>10}", f"{'-':>7}"]
        report[name] = entry
        rows.append(f"{name:<34} {unit:<4} " + " ".join(cells))
    return "\n".join(rows) + "\n", report


def write_json(path: Path | None, data: Mapping) -> None:
    if path is not None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


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
    if len(set(labels)) != len(labels) or not all(re.fullmatch(r"[A-Za-z0-9._-]+", label) for label in labels):
        raise PerfError("labels must be distinct and use letters, digits, '.', '_' or '-'")
    return labels


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
            measure_win32(gui, by_label[label], env_dir, config, 0, env)
        except gui.GuiError as exc:
            print(f"{TAG} {label}: warm-up failed: {exc}", file=sys.stderr)
    for run, label in alternate(labels, args.runs):
        target = out / label / f"run-{run:02d}.txt"
        env_dir = out / label / "env"
        for attempt in (1, 2):
            try:
                lines = measure_win32(gui, by_label[label], env_dir, config, args.resizes, env)
                break
            except gui.GuiError as exc:
                print(f"{TAG} {label} run {run} attempt {attempt} failed: {exc}", file=sys.stderr)
                lines = None
        if lines is None:
            failures += 1
            continue
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
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
    out = Path(args.out)
    failures = 0
    for run, label in alternate(labels, args.runs):
        clone = clones[labels.index(label)]
        target = out / label / f"run-{run:02d}"
        argv = ["--clone", clone, "smoke", "--perf", "--out", str(target), "--name", "perf"]
        for assignment in args.env:
            argv += ["--env", assignment]
        if args.distro:
            argv[:0] = ["--distro", args.distro]
        print(f"{TAG} {label} run {run}: gx_wsl.py {' '.join(argv)}", flush=True)
        code = gx_wsl.main(argv)
        failures += code != 0
    return report_runs(out, labels, args.json) or (1 if failures else 0)


def report_runs(out: Path, labels: Sequence[str], json_path: Path | None) -> int:
    sets = [collect([out / label]) if (out / label).exists() else Samples() for label in labels]
    if not any(sets):
        print(f"{TAG} error: no samples in {out}", file=sys.stderr)
        return 2
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
    gtk = commands.add_parser("gtk", allow_abbrev=False, help="measure GTK builds in WSL clones")
    gtk.add_argument("--clone", action="append", required=True, metavar="PATH")
    gtk.add_argument("--label", action="append", default=[])
    gtk.add_argument("--distro")
    gtk.add_argument("--out", type=Path, required=True)
    gtk.add_argument("--runs", type=int, default=10)
    gtk.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                     help="passed to every `smoke --perf` as --env (repeatable)")
    gtk.add_argument("--json", type=Path)
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
        if args.command == "summarize":
            samples = collect(args.paths)
            if not samples:
                print(f"{TAG} error: no samples in {', '.join(map(str, args.paths))}", file=sys.stderr)
                return 2
            text, report = summary_table(samples)
            print(text, end="")
            write_json(args.json, report)
            return 0
        if args.command == "compare":
            old, new = collect(args.old), collect(args.new)
            if not old or not new:
                print(f"{TAG} error: no samples on the {'old' if not old else 'new'} side", file=sys.stderr)
                return 2
            text, report = compare_table(old, new)
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
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
