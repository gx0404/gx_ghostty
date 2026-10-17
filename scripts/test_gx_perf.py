#!/usr/bin/env python3
"""Tests for scripts/gx_perf.py: sample parsing, statistics, tables, alternation and the commands
that only read files. The measurement commands (win32, gtk) need a desktop or WSL and are not run.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_perf  # noqa: E402
import gx_wsl  # noqa: E402
from test_gx_wsl import stat_line  # noqa: E402


def gtk_fixture(root: Path) -> dict:
    root.mkdir(parents=True, exist_ok=True)
    before = "\n".join((stat_line(10, "ghostty", 0, 0, 0, 0), stat_line(11, "renderer", 0, 0, 0, 0)))
    after = "\n".join((stat_line(10, "ghostty", 0, 0, 0, 0), stat_line(11, "renderer", 0, 0, 100, 0)))
    times = "pid 10\nwindow_seconds 1\nworkload_seconds 1\nworkload_finished 1\nrun_exit 0\n"
    program = {"__name__": "test_gtk_fixture"}
    exec(gx_wsl.PERF_PROGRAM, program)
    version = "Ghostty 1.3.2-HEAD+bbbbbbbbb\n  - build mode    : .ReleaseFast\n"
    source = {"commit": "b" * 40, "tree": "c" * 40, "dirty": False, "dirty_paths": ""}
    image = {"sha256": "a" * 64, "device": 1, "inode": 2, "size": 3, "mtime_ns": 4}
    executable = {"path": "/own/ghostty", **image}
    receipt = {"schema": "gx-gtk-build-v1", "producer": "gx_wsl.py build", "build_exit": 0, "perf_eligible": True,
               "build_argv": ["python3", "scripts/zigw.py", "build", "-Dapp-runtime=gtk", "-Doptimize=ReleaseFast"],
               "source_before": source, "source_after": source, "executable": executable, "version": version, "version_exit": 0}
    receipt_text = json.dumps(receipt, indent=2) + "\n"
    def process(ticks, start):
        stat = stat_line(10, "ghostty", 0, 0, ticks, 0).split("\t", 1)[1]
        return {"pre_stat": stat, "post_stat": stat, "begin_ns": start, "end_ns": start + 1_000_000}
    process_before, process_after = process(0, 1_000_000_000), process(100, 3_000_000_000)
    files = {"perf.log": "info(gx_perf): config_load 10us\n", "perf-version.txt": version,
             "perf-times.txt": times, "perf-tasks-before.txt": before, "perf-tasks-after.txt": after,
             "perf-status-before.txt": "Pid: 10\n", "perf-status-after.txt": "Pid: 10\n",
             "perf.png": "image", "perf-perf.png": "image", "perf-build-receipt.json": receipt_text,
             "perf-process-before.json": json.dumps(process_before), "perf-process-after.json": json.dumps(process_after),
             "perf-perf.txt": program["report"](before, after, times, "info(gx_perf): config_load 10us\n", 100, process_before, process_after)}
    for name, text in files.items():
        (root / name).write_text(text, encoding="utf-8", newline="\n")
    identity = {"pid": 10, "starttime": 100, "exe": "/own/ghostty", **image}
    meta = {"schema": "gx-gtk-perf-v1", "perf": True, "valid": True, "exit": 0, "errors": [], "identity": identity,
            "workload_finished": True, "workload_exit": "0", "build_mode": "ReleaseFast", "cleanup_identity": "verified",
            "cleanup": "owned pidfd SIGTERM", "child_exit": -15, "executable": executable, "version_exit": 0,
            **source, "source_end": source, "version": version, "effective_env": {}, "clk_tck": 100,
            "capture_id": gx_perf.hashlib.sha256(str(root).encode()).hexdigest()[:32],
            "build_receipt_sha256": gx_perf.hashlib.sha256(receipt_text.encode()).hexdigest(),
            "cpu_accounting": program["cpu_accounting"](before, after, process_before, process_after, "10", 100),
            "identity_checks": [identity | {"stage": stage} for stage in
                                ("launch", "before before", "before after", "after before", "after after", "finished", "cleanup")],
            "files": list(files),
            "artifact_sha256": {name: gx_perf.hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}}
    (root / "perf-meta.json").write_text(json.dumps(meta), encoding="utf-8")
    return meta


LOG = """18:15:01.100 [1] info(gx_perf): first_frame 183456us
18:15:01.200 [1] info(gx_perf): first_frame 200000us
18:15:01.358 [43384] debug(win32): window shown after 31ms first_frame=true
18:15:01.400 [1] warning(gx_perf): not a sample 12us
garbage metric line
"""
PERF_TXT = """# gx-wsl smoke --perf
metric window_seconds 1.500 s
metric cpu.renderer 3.250 s
metric dmabuf_warnings 23
metric resize.setwindowpos 12.5 ms
metric tiny 250 us
"""
# A Windows file log that starts just before midnight; only the first line of each milestone counts.
WIN32_LOG = """23:59:59.900 [1] info: ghostty version=1.3.2
23:59:59.950 [1] info(opengl): system OpenGL 4.3 vendor=NVIDIA Corporation renderer=X
00:00:00.010 [1] info: reading configuration file path=C:/x/ghostty/config.ghostty
00:00:00.040 [1] info(font_shared_grid_set): font regular: JetBrainsMono NF Regular
00:00:00.070 [2] info(io_exec): started subcommand path=cmd.exe pid=anyopaque@4d0
00:00:00.090 [3] info(opengl): loaded OpenGL 4.6
00:00:00.090 [3] info(opengl): loaded OpenGL 4.6 vendor=NVIDIA Corporation renderer=X software=false
00:00:01.000 [4] info(io_exec): started subcommand path=cmd.exe pid=anyopaque@9c8
"""


class ParseTests(unittest.TestCase):
    def test_prefixed_counts_gauges_and_time_conflicts(self):
        samples = gx_perf.parse_text("12:00:00.123 [42] info(gx_perf): metric remote.frame_bytes 1048576\r\n"
                                     "info(gx_perf): metric remote.frame_bytes 8\ninfo(gx_perf): remote.map 123us\n")
        text, report = gx_perf.summary_table(samples)
        self.assertEqual(1048584, report['remote.frame_bytes']['sum'])
        self.assertEqual('', report['remote.frame_bytes']['unit'])
        self.assertNotIn('sum', report['remote.map'])
        self.assertIn('sum', text)
        _, comparison = gx_perf.compare_table(samples, samples)
        self.assertEqual(1048584, comparison['remote.frame_bytes']['old']['sum'])
        for lines in ("info(gx_perf): metric a 1\ninfo(gx_perf): a 2us\n",
                      "info(gx_perf): a 2us\ninfo(gx_perf): metric a 1\n"):
            with self.assertRaisesRegex(gx_perf.PerfError, 'conflict'):
                gx_perf.parse_text(lines)

    def test_label_environment_overrides_are_local(self):
        result = gx_perf.label_environments(['old', 'new'], ['GSK_RENDERER=ngl'],
                                           ['new:GSK_RENDERER=cairo', 'new:EMPTY='], gx_wsl.env_assignments)
        self.assertEqual({'GSK_RENDERER': 'ngl'}, result['old'])
        self.assertEqual({'GSK_RENDERER': 'cairo', 'EMPTY': ''}, result['new'])
        for value in ('absent:X=1', 'old', 'old:1INVALID=x'):
            with self.assertRaises((gx_perf.PerfError, gx_wsl.GxWslError)):
                gx_perf.label_environments(['old'], [], [value], gx_wsl.env_assignments)

    def test_lines_of_every_source(self):
        samples = gx_perf.parse_text(LOG + PERF_TXT.replace("\n", "\r\n"))
        self.assertEqual([183.456, 200.0], samples.values["first_frame"])
        self.assertEqual([31.0], samples.values["log.window_shown"])
        self.assertEqual([1.0], samples.values["log.first_frame_drawn"])
        self.assertEqual([1500.0], samples.values["window_seconds"])
        self.assertEqual([3250.0], samples.values["cpu.renderer"])
        self.assertEqual([23.0], samples.values["dmabuf_warnings"])
        self.assertEqual([12.5], samples.values["resize.setwindowpos"])
        self.assertEqual([0.25], samples.values["tiny"])
        self.assertEqual("ms", samples.units["first_frame"])
        self.assertEqual("", samples.units["dmabuf_warnings"])
        self.assertNotIn("not", samples.values)

    def test_log_milestones_count_from_the_first_line_across_midnight(self):
        samples = gx_perf.parse_text(WIN32_LOG)
        self.assertEqual({"log.opengl_probed": [50.0], "log.config_read": [110.0], "log.font_loaded": [140.0],
                          "log.pty_started": [170.0], "log.renderer_context": [190.0]}, samples.values)
        self.assertEqual({"ms"}, set(samples.units.values()))

    def test_gx_perf_units(self):
        samples = gx_perf.parse_text("x info(gx_perf): a 1.5ms\nx info(gx_perf): b=2500ns\nx info(gx_perf): c 2s\n")
        self.assertEqual({"a": [1.5], "b": [0.0025], "c": [2000.0]}, samples.values)

    def test_arbitrary_signed_metrics_remain_summarizable(self):
        samples = gx_perf.parse_text("metric arbitrary.delta -1.25 ms\nmetric signed_count -2\n")
        _, data = gx_perf.summary_table(samples)
        self.assertEqual(-1.25, data["arbitrary.delta"]["median"])
        self.assertEqual(-2, data["signed_count"]["median"])
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.parse_text("metric cpu.main -0.980 s\n")

    def test_run_json_startup_marks(self):
        samples = gx_perf.parse_run_json({"startup_ms": {"created_ms": 220.5, "shown_ms": 515}})
        self.assertEqual({"startup.created": [220.5], "startup.shown": [515.0]}, samples.values)
        self.assertFalse(gx_perf.parse_run_json({}))

    def test_an_empty_sample_set_still_collects(self):
        samples = gx_perf.Samples()
        self.assertFalse(samples)
        gx_perf.parse_text("metric a 1 ms\n", samples)
        self.assertEqual([1.0], samples.values["a"])


class StatisticsTests(unittest.TestCase):
    def test_median_and_nearest_rank_p90(self):
        values = [float(v) for v in range(10, 0, -1)]
        self.assertEqual({"n": 10, "median": 5.5, "p90": 9.0, "min": 1.0, "max": 10.0}, gx_perf.stats(values))
        self.assertEqual(7.0, gx_perf.p90([7.0]))
        self.assertEqual(18.0, gx_perf.p90([float(v) for v in range(1, 21)]))

    def test_zero_baseline_is_json_null_not_nan(self):
        old = gx_perf.parse_text("metric cpu.main 0 s\n")
        new = gx_perf.parse_text("metric cpu.main 0 s\n")
        text, report = gx_perf.compare_table(old, new)
        self.assertIn("n/a", text)
        self.assertIsNone(report["cpu.main"]["delta_percent"])
        json.dumps(report, allow_nan=False)

    def test_tables(self):
        old, new = gx_perf.Samples(), gx_perf.Samples()
        for value in (500, 520, 510):
            old.add("startup.shown", value, "ms")
        for value in (400, 410, 405):
            new.add("startup.shown", value, "ms")
        new.add("only.new", 3, None)
        text, report = gx_perf.compare_table(old, new)
        line = next(row for row in text.splitlines() if row.startswith("startup.shown"))
        self.assertIn("510.0", line)
        self.assertIn("405.0", line)
        self.assertIn("-105.0", line)
        self.assertIn("-20.6", line)
        self.assertAlmostEqual(-105.0, report["startup.shown"]["delta_median"])
        self.assertIsNone(report["only.new"]["old"])
        summary, data = gx_perf.summary_table(old)
        self.assertIn("startup.shown", summary)
        self.assertEqual(3, data["startup.shown"]["n"])

    def test_alternation_and_labels(self):
        self.assertEqual([(1, "old"), (1, "new"), (2, "new"), (2, "old"), (3, "old"), (3, "new")],
                         gx_perf.alternate(["old", "new"], 3))
        self.assertEqual([(1, "build"), (2, "build")], gx_perf.alternate(["build"], 2))
        self.assertEqual(["old", "new"], gx_perf.labels_for(2, []))
        self.assertEqual(["a"], gx_perf.labels_for(1, ["a"]))
        for count, labels in ((2, ["x"]), (2, ["x", "x"]), (1, ["a b"]), (1, ["."]), (1, [".."])):
            with self.subTest(labels=labels), self.assertRaises(gx_perf.PerfError):
                gx_perf.labels_for(count, labels)


class CommandTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def run_main(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = gx_perf.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_summarize_skips_the_profile_copy_of_a_log(self):
        run = self.root / "W01"
        (run / "env" / "ghostty" / "logs").mkdir(parents=True)
        (run / "env" / ".gx-win-gui-env").write_text("", encoding="utf-8")
        (run / "env" / "ghostty" / "logs" / "ghostty.log").write_text(LOG, encoding="utf-8")
        (run / "ghostty.log").write_text(LOG, encoding="utf-8")
        (run / "run.json").write_text(json.dumps({"startup_ms": {"shown_ms": 500}}), encoding="utf-8")
        report = self.root / "out" / "report.json"
        code, out, _ = self.run_main("summarize", str(self.root), "--json", str(report))
        self.assertEqual(0, code)
        self.assertIn("first_frame", out)
        data = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(2, data["first_frame"]["n"])
        self.assertEqual(1, data["startup.shown"]["n"])

    def test_compare_and_missing_samples(self):
        old, new = self.root / "old.txt", self.root / "new.txt"
        old.write_text("metric startup.shown 500 ms\n", encoding="utf-8")
        new.write_text("metric startup.shown 400 ms\n", encoding="utf-8")
        code, out, _ = self.run_main("compare", "--old", str(old), "--new", str(new))
        self.assertEqual(0, code)
        self.assertIn("-100.0", out)
        (self.root / "empty.txt").write_text("nothing\n", encoding="utf-8")
        code, _, err = self.run_main("compare", "--old", str(old), "--new", str(self.root / "empty.txt"))
        self.assertEqual(2, code)
        self.assertIn("no samples on the new side", err)
        code, _, err = self.run_main("summarize", str(self.root / "missing"))
        self.assertEqual(2, code)
        self.assertIn("does not exist", err)

    def test_measurement_commands_validate_their_arguments(self):
        code, _, err = self.run_main("win32", "--exe", str(self.root / "no.exe"), "--out", str(self.root / "o"))
        self.assertEqual(2, code)
        self.assertIn("does not exist", err)
        code, _, _ = self.run_main("win32", "--exe", "a", "--out", "o", "--runs", "0")
        self.assertEqual(2, code)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, gx_perf.main(["gtk", "--out", "o"]))

    def test_duplicate_and_overlapping_paths_are_one_sample(self):
        path = self.root / "run.txt"
        path.write_text("metric a 1 ms\n", encoding="utf-8")
        samples = gx_perf.collect([path, path, self.root, path.parent / "." / path.name])
        self.assertEqual([1.0], samples.values["a"])

    def test_time_count_conflict_is_rejected(self):
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.parse_text("info(gx_perf): a 10us\nmetric a 10\n")
        old = gx_perf.parse_text("metric a 1 ms\n")
        new = gx_perf.parse_text("metric a 1\n")
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.compare_table(old, new)

    def test_compare_rejects_missing_renderer_and_unequal_n(self):
        old, new = self.root / "old.txt", self.root / "new.txt"
        old.write_text("metric cpu.main 1 s\nmetric cpu.renderer 1 s\nmetric cpu.total 2 s\n", encoding="utf-8")
        new.write_text("metric cpu.main 1 s\nmetric cpu.total 2 s\n", encoding="utf-8")
        code, _, _ = self.run_main("compare", "--old", str(old), "--new", str(new))
        self.assertNotEqual(0, code)
        old.write_text("metric a 1 ms\nmetric a 2 ms\n", encoding="utf-8")
        new.write_text("metric a 1 ms\n", encoding="utf-8")
        code, _, _ = self.run_main("compare", "--old", str(old), "--new", str(new))
        self.assertNotEqual(0, code)

    def test_rejected_gtk_evidence_cannot_supply_samples(self):
        (self.root / "perf.log").write_text("info(gx_perf): a 10us\n", encoding="utf-8")
        (self.root / "perf-perf.txt").write_text("metric cpu.renderer 1 s\n", encoding="utf-8")
        (self.root / "perf-meta.json").write_text(json.dumps({"schema": "gx-gtk-perf-v1", "valid": False,
                                                              "exit": 1, "errors": ["identity changed"]}), encoding="utf-8")
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.collect([self.root])

    def test_gtk_output_must_be_new_and_preserve_planned_runs(self):
        out = self.root / "g"
        out.mkdir()
        (out / "stale.txt").write_text("metric cpu.main 1 s\n", encoding="utf-8")
        with mock.patch.object(gx_wsl, "main", return_value=0) as smoke:
            code, _, _ = self.run_main("gtk", "--clone", "~/c", "--out", str(out))
        self.assertNotEqual(0, code)
        smoke.assert_not_called()
        fresh = self.root / "fresh"
        with mock.patch.object(gx_wsl, "main", return_value=1):
            code, _, _ = self.run_main("gtk", "--clone", "~/c", "--out", str(fresh))
        self.assertNotEqual(0, code)
        data = json.loads((fresh / "gtk-runs.json").read_text(encoding="utf-8"))
        self.assertEqual(10, data["planned_runs"])
        self.assertEqual(10, len(data["runs"]))
        self.assertFalse(data["valid"])

    def test_env_is_validated_and_passed_to_every_smoke(self):
        code, _, err = self.run_main("win32", "--exe", "a", "--out", "o", "--env", "BAD")
        self.assertEqual(2, code)
        self.assertIn("NAME=VALUE", err)
        code, _, err = self.run_main("gtk", "--clone", "~/c", "--out", "o", "--env", "1X=2")
        self.assertEqual(2, code)
        self.assertIn("NAME=VALUE", err)
        with mock.patch.object(gx_wsl, "main", return_value=0) as smoke:
            code, _, _ = self.run_main("gtk", "--clone", "~/c", "--out", str(self.root / "g"), "--runs", "2",
                                       "--env", "GHOSTTY_GX_PERF=1", "--env", "GSK_RENDERER=cairo")
        self.assertEqual(2, code, "the stubbed runs leave no samples")
        self.assertEqual(2, smoke.call_count)
        argv = smoke.call_args.args[0]
        self.assertEqual(["--clone", "~/c", "smoke", "--perf"], argv[:4])
        self.assertEqual(["--env", "GHOSTTY_GX_PERF=1", "--env", "GSK_RENDERER=cairo"], argv[-4:])

    def test_verified_gtk_collects_once_and_rejects_changed_raw(self):
        root = self.root / "run"
        gtk_fixture(root)
        samples = gx_perf.collect([root, root / "perf-perf.txt", root / "perf.log"])
        self.assertEqual([0.0], samples.values["cpu.main"])
        self.assertEqual([1000.0], samples.values["cpu.renderer"])
        self.assertEqual(1, len(samples.gtk_runs))
        self.assertFalse(samples.unverified)
        (root / "perf-tasks-after.txt").write_text(stat_line(10, "ghostty", 0, 0, 100, 0, 200), encoding="utf-8")
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.collect([root])

    def test_gtk_planned_twenty_runs_are_not_filtered_into_success(self):
        out = self.root / "pairs"
        def smoke(argv):
            target = Path(argv[argv.index("--out") + 1])
            gtk_fixture(target)
            return 1 if "new" in target.parts and target.name == "run-04" else 0
        with mock.patch.object(gx_wsl, "main", side_effect=smoke) as calls:
            code, _, _ = self.run_main("gtk", "--clone", "~/old", "--clone", "~/new", "--out", str(out))
        self.assertEqual(1, code)
        self.assertEqual(20, calls.call_count)
        batch = json.loads((out / "gtk-runs.json").read_text(encoding="utf-8"))
        result = json.loads((out / "RESULT.json").read_text(encoding="utf-8"))
        self.assertEqual(10, batch["planned_runs"])
        self.assertEqual(20, len(batch["runs"]))
        self.assertEqual({"old": 10, "new": 9}, batch["valid_runs"])
        self.assertFalse(batch["valid"])
        self.assertEqual("rejected", result["validation"]["status"])
        self.assertNotIn("metrics", result)
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.collect([out / "old"])

    def test_valid_gtk_batch_and_historical_timing_are_distinct(self):
        out = self.root / "valid"
        def smoke(argv):
            gtk_fixture(Path(argv[argv.index("--out") + 1]))
            return 0
        with mock.patch.object(gx_wsl, "main", side_effect=smoke):
            code, _, _ = self.run_main("gtk", "--clone", "~/c", "--out", str(out), "--runs", "2")
        self.assertEqual(0, code)
        self.assertEqual(2, len(gx_perf.collect([out]).gtk_runs))
        old, new = self.root / "a.txt", self.root / "b.txt"
        old.write_text("metric arbitrary 1 ms\n", encoding="utf-8")
        new.write_text("metric arbitrary 2 ms\n", encoding="utf-8")
        report = self.root / "history.json"
        code, text, _ = self.run_main("compare", "--old", str(old), "--new", str(new), "--json", str(report))
        self.assertEqual(0, code)
        self.assertIn("unverified", text)
        self.assertEqual("unverified", json.loads(report.read_text(encoding="utf-8"))["_validation"]["identity"])

    def test_legacy_gtk_standard_report_is_unverified(self):
        out = self.root / "legacy"
        for label, metrics in (("old", "metric cpu.renderer 1 s\n"), ("new", "metric cpu.main 1 s\n")):
            path = out / label
            path.mkdir(parents=True)
            (path / "run.txt").write_text(metrics, encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1, gx_perf.report_runs(out, ["old", "new"], out / "result.json"))
        self.assertEqual("rejected", json.loads((out / "result.json").read_text())["_validation"]["status"])

    def test_old_nonzero_smoke_meta_cannot_be_accepted_as_history(self):
        (self.root / "perf.log").write_text("info(gx_perf): config_load 1us\n", encoding="utf-8")
        (self.root / "perf-meta.txt").write_text("commit: abc\nexit: 1\nperf: seq 1 3000000\n", encoding="utf-8")
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.collect([self.root / "perf.log"])

    def batch_fixture(self, out, planned=10):
        batch = {"schema": "gx-gtk-runs-v1", "planned_runs": planned, "labels": ["old", "new"],
                 "valid": True, "order": "AB/BA", "runs": []}
        for run, label in gx_perf.alternate(batch["labels"], planned):
            relative = f"{label}/run-{run:02d}"
            gtk_fixture(out / relative)
            batch["runs"].append({"label": label, "run": run, "path": relative, "exit": 0, "status": "valid"})
        return batch

    def test_reporter_rejects_duplicate_run01_and_noncanonical_order(self):
        import copy
        out = self.root / "plan"
        original = self.batch_fixture(out)
        cases = {}
        duplicate = copy.deepcopy(original)
        for item in duplicate["runs"]:
            item.update(run=1, path=f"{item['label']}/run-01")
        cases["repeat run01"] = duplicate
        swapped = copy.deepcopy(original)
        swapped["runs"][2:4] = reversed(swapped["runs"][2:4])
        cases["AB instead of BA"] = swapped
        escaped = copy.deepcopy(original)
        escaped["runs"][0]["path"] = "../old/run-01"
        cases["outside out"] = escaped
        for reason, batch in cases.items():
            with self.subTest(reason=reason), contextlib.redirect_stdout(io.StringIO()):
                code = gx_perf.report_gtk_runs(out, batch, None)
                self.assertNotEqual(0, code)
                self.assertFalse(json.loads((out / "RESULT.json").read_text())["validation"]["status"] == "valid")

    def test_declared_ten_pair_batch_cannot_compare_one_selected_round(self):
        out = self.root / "selected"
        batch = self.batch_fixture(out)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.report_gtk_runs(out, batch, None))
        code, _, _ = self.run_main("compare", "--old", str(out / "old/run-01"), "--new", str(out / "new/run-01"))
        self.assertNotEqual(0, code)
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.collect([out / "old/run-01/perf-perf.txt"])

    def test_cpu_contract_does_not_certify_a_linux_rounding_bound(self):
        root = self.root / "diagnostic"
        meta = gtk_fixture(root)
        samples = gx_perf.collect([root])
        info = gx_perf.validation([samples])
        self.assertIn("diagnostic-only", info["cpu_contract"])
        self.assertIn("unproved", info["cpu_contract"])
        self.assertTrue(meta["cpu_accounting"]["diagnostic_only"])
        self.assertNotIn("comparable", meta["cpu_accounting"])
        self.assertNotIn("error_bound_ticks", meta["cpu_accounting"])

    def test_contradictory_metadata_is_not_verified(self):
        root = self.root / "contradiction"
        for key, value in (("dirty", True), ("commit", "f" * 40), ("child_exit", -11),
                           ("executable", {"sha256": "b" * 64}), ("version_exit", 1)):
            meta = gtk_fixture(root)
            meta[key] = value
            (root / "perf-meta.json").write_text(json.dumps(meta), encoding="utf-8")
            with self.subTest(field=key), self.assertRaises(gx_perf.PerfError):
                gx_perf.collect([root])


if __name__ == "__main__":
    unittest.main()
