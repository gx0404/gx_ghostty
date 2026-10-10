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
        for count, labels in ((2, ["x"]), (2, ["x", "x"]), (1, ["a b"])):
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


if __name__ == "__main__":
    unittest.main()
