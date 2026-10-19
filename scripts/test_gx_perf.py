#!/usr/bin/env python3
"""Tests for scripts/gx_perf.py: sample parsing, statistics, tables, alternation and the commands
that only read files. The measurement commands (win32, gtk) need a desktop or WSL and are not run.
"""

from __future__ import annotations

import ast
import contextlib
import ctypes
import io
import os
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_perf  # noqa: E402
import gx_wsl  # noqa: E402
from test_gx_wsl import monotonic_times, stat_line  # noqa: E402


class P3FixtureTests(unittest.TestCase):
    def test_tab_transition_waits_for_unique_new_pane_before_input(self):
        for mode in ('settles', 'both', 'old-only', 'foreign'):
            with self.subTest(mode=mode):
                gui, instance, capture, windows, _ = self.fixture()
                old = SimpleNamespace(hwnd=100, visible=True, cloaked=False, rect=(0, 40, 800, 600))
                new = SimpleNamespace(hwnd=101, visible=True, cloaked=False, rect=old.rect)
                api = gui.win32.return_value
                phase = [0]
                polls = [0]
                def children(*_):
                    if phase[0] == 0:
                        return [old]
                    polls[0] += 1
                    if mode == 'settles' and polls[0] >= 3:
                        old.visible = False
                    return [old] if mode == 'old-only' else [old, new]
                api.child_windows.side_effect = children
                api.window_pid.side_effect = lambda hwnd: 999 if mode == 'foreign' and hwnd == 101 else 123
                def populate(*_, prepare):
                    prepare(windows[0])
                    self.assertEqual(2, instance.type_text.call_count)
                    phase[0] = 1
                    prepare(windows[0], {100})
                    raise RuntimeError('prepared new pane')
                with mock.patch.object(gx_perf, 'populate', side_effect=populate), \
                        mock.patch.object(gx_perf.time, 'monotonic', side_effect=range(1000)), \
                        mock.patch.object(gx_perf.time, 'sleep'):
                    if mode == 'settles':
                        with self.assertRaisesRegex(RuntimeError, 'prepared new pane'):
                            gx_perf.prepare_p3(gui, instance, capture)
                        self.assertEqual(4, instance.type_text.call_count)
                        self.assertEqual([100, 101], [r['hwnd'] for r in capture.report['p3_fixture']['terminals']])
                    else:
                        with self.assertRaises(gx_perf.PerfError):
                            gx_perf.prepare_p3(gui, instance, capture)
                        self.assertEqual(2, instance.type_text.call_count)  # no input after the first pane
                        wait = capture.report['p3_fixture']['terminal_waits'][-1]
                        self.assertEqual('failed', wait['status'])
                        self.assertEqual(100, wait['candidates'][0]['hwnd'])
                        self.assertTrue(wait['candidates'][0]['visible'])
                        self.assertEqual(123, wait['candidates'][0]['pid'])

    def fixture(self, *, baseline=False, count=45, foreign=False, bar_state=2, bar_visible=True, acknowledge=True):
        gui, instance, capture = mock.Mock(), mock.Mock(), mock.Mock()
        gui.TERMINAL_CLASS = 'GhosttyTerminal'
        instance.pid = 123
        instance.scale.return_value = 1
        instance.caption_point.return_value = (400, 20)
        capture.report = {'config': gx_perf.DEFAULT_WIN32_CONFIG, 'baseline': baseline}
        windows = [SimpleNamespace(hwnd=i, rect=(0, 0, 800, 600)) for i in (1, 2, 3)]
        terminals = {w.hwnd: [SimpleNamespace(hwnd=w.hwnd * 100 + i, visible=False, cloaked=False,
                                              rect=(0, 40, 800, 600)) for i in range(15)] for w in windows}
        api = gui.win32.return_value
        api.child_windows.side_effect = lambda hwnd, cls: terminals[hwnd]
        api.window_pid.return_value = 999 if foreign else instance.pid
        api.foreground.return_value = 3
        api.window_text.side_effect = lambda hwnd: instance.type_text.call_args.args[0].removeprefix('title ') if acknowledge else ''
        bar = SimpleNamespace(hwnd=999, cls='GhosttyScrollbar', visible=bar_visible, cloaked=False, rect=(790, 40, 800, 600))
        instance.windows.return_value = [bar]
        api.GetWindow.return_value = 314
        api.send_message.return_value = bar_state

        def populate(_gui, _instance, tabs, nwindow, prepare=None):
            self.assertEqual((15, 3), (tabs, nwindow))
            done = 0
            for window in windows:
                for terminal in terminals[window.hwnd]:
                    for other in terminals[window.hwnd]:
                        other.visible = False
                    terminal.visible = True
                    if done < count:
                        prepare(window)
                    done += 1

        return gui, instance, capture, windows, populate

    def run_fixture(self, **kwargs):
        gui, instance, capture, windows, populate = self.fixture(**kwargs)
        with mock.patch.object(gx_perf, 'populate', side_effect=populate), \
                mock.patch.object(gx_perf, 'main_windows', return_value=windows), \
                mock.patch.object(gx_perf.time, 'monotonic', side_effect=range(1000)), \
                mock.patch.object(gx_perf.time, 'monotonic_ns', return_value=123456), \
                mock.patch.object(gx_perf.time, 'sleep'):
            result = gx_perf.prepare_p3(gui, instance, capture)
        return gui, instance, capture, result

    def test_both_arms_prepare_all_terminals_with_identical_real_stimulus(self):
        old = self.run_fixture(baseline=True)
        new = self.run_fixture(baseline=False)
        for gui, instance, capture, result in (old, new):
            evidence = capture.report['p3_fixture']
            self.assertEqual((3, 45), (evidence['actual_windows'], evidence['actual_terminals']))
            self.assertEqual(45, len({row['marker'] for row in evidence['terminals']}))
            self.assertTrue(all(row['title_acknowledged'] and row['output_lines'] == 300 for row in evidence['terminals']))
            self.assertEqual('prepared', evidence['status'])
            self.assertEqual('PENDING', evidence['image_review'])
            self.assertEqual(3, result.hwnd)
            instance.wheel.assert_called_once_with(400, 320, delta=120, count=3)
            capture.screenshot.assert_called_once_with('p3-before-drag', result)
            self.assertEqual('unknown', evidence['before_drag'][0]['total'])
            self.assertTrue(all(call.args == (999, 0x0401, 0) for call in gui.win32.return_value.send_message.call_args_list))
        self.assertEqual(old[1].type_text.call_args_list, new[1].type_text.call_args_list)
        self.assertEqual(old[1].press.call_args_list, new[1].press.call_args_list)

    def test_missing_visible_bar_wrong_pid_count_and_title_timeout_fail(self):
        for kwargs, message in [({'bar_state': 0}, 'timeout'), ({'bar_visible': False}, 'timeout'),
                                ({'foreign': True}, 'foreign PID'), ({'count': 44}, '45 terminals'),
                                ({'acknowledge': False}, 'output completion title')]:
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(gx_perf.PerfError, message):
                self.run_fixture(**kwargs)

    def test_bar_owner_and_protocol_timeout_fail(self):
        for owner, pid, state in [(9999, 123, 2), (314, 999, 2), (314, 123, None)]:
            gui, instance, capture, windows, populate = self.fixture()
            api = gui.win32.return_value
            api.GetWindow.return_value = owner
            api.window_pid.side_effect = lambda hwnd: pid if hwnd == 999 else 123
            api.send_message.return_value = state
            with mock.patch.object(gx_perf, 'populate', side_effect=populate), \
                    mock.patch.object(gx_perf, 'main_windows', return_value=windows), \
                    mock.patch.object(gx_perf.time, 'monotonic', side_effect=range(1000)), \
                    mock.patch.object(gx_perf.time, 'sleep'), self.assertRaises(gx_perf.PerfError):
                gx_perf.prepare_p3(gui, instance, capture)

    def test_custom_shell_or_include_is_explicitly_rejected_before_input(self):
        for config in ('command = pwsh.exe\n', gx_perf.DEFAULT_WIN32_CONFIG + 'config-file = other\n'):
            gui, instance, capture, _, _ = self.fixture()
            capture.report['config'] = config
            with self.assertRaisesRegex(gx_perf.PerfError, 'custom configuration'):
                gx_perf.prepare_p3(gui, instance, capture)
            instance.type_text.assert_not_called()

    def test_top_level_owner_is_bound_by_active_terminal_geometry(self):
        gui, instance, capture, windows, populate = self.fixture()
        gui.win32.return_value.GetWindow.return_value = 3
        with mock.patch.object(gx_perf, 'populate', side_effect=populate), \
                mock.patch.object(gx_perf, 'main_windows', return_value=windows):
            gx_perf.prepare_p3(gui, instance, capture)
        self.assertEqual(3, capture.report['p3_fixture']['before_drag'][0]['owner'])

    def test_populate_calls_prepare_for_first_and_every_added_tab(self):
        gui, instance = mock.Mock(), mock.Mock()
        gui.TERMINAL_CLASS = 'GhosttyTerminal'
        windows = [SimpleNamespace(hwnd=1, visible=True, cloaked=False)]
        terminals = {1: [SimpleNamespace(hwnd=100, visible=True)]}
        instance.require_window.return_value = windows[0]
        gui.win32.return_value.child_windows.side_effect = lambda hwnd, cls: list(terminals[hwnd])
        def press(key):
            if key == 'ctrl+shift+n':
                hwnd = len(windows) + 1
                windows.append(SimpleNamespace(hwnd=hwnd, visible=True, cloaked=False))
                terminals[hwnd] = [SimpleNamespace(hwnd=hwnd * 100, visible=True)]
            else:
                self.assertEqual(gx_perf.NEW_TAB_KEYS, key)
                children = terminals[windows[-1].hwnd]
                children.append(SimpleNamespace(hwnd=children[0].hwnd + len(children), visible=True))
        instance.press.side_effect = press
        prepared = []
        with mock.patch.object(gx_perf, 'main_windows', side_effect=lambda *a: list(windows)), \
                mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.populate(gui, instance, 15, 3,
                             prepare=lambda window, previous=(): prepared.append(terminals[window.hwnd][-1].hwnd))
        self.assertEqual(45, len(set(prepared)))

    def test_measurement_mark_follows_preconditions_and_drag_keeps_original_contract(self):
        gui, instance, capture = mock.Mock(), mock.Mock(), mock.Mock()
        capture.report = {'p3_fixture': {'drag_start': (400, 20), 'drag_end': (520, 60)}}
        current = SimpleNamespace(hwnd=1, rect=(0, 0, 800, 600))
        moved = SimpleNamespace(hwnd=1, rect=(120, 40, 920, 640))
        instance.scale.return_value = 1
        instance.caption_point.return_value = (400, 20)
        order = []
        def prepare(*_):
            order.append('prepared')
            return current
        capture.mark.side_effect = lambda: order.append('mark') or b''
        instance.drag.side_effect = lambda *a, **k: order.append('drag')
        with mock.patch.object(gx_perf, 'prepare_p3', side_effect=prepare), \
                mock.patch.object(gx_perf, 'p3_scrollbars', return_value=[]), \
                mock.patch.object(gx_perf, 'main_windows', return_value=[moved]):
            gx_perf.measure_ui(gui, instance, capture, SimpleNamespace(case='p3'))
        self.assertEqual(['prepared', 'mark', 'drag'], order)
        instance.drag.assert_called_once_with((400, 20), (520, 60), steps=60, step_delay=2/60)
        capture.count.assert_called_once_with(capture.window.return_value, 'scrollbar.paint')

    def test_caption_probe_fade_rejects_before_mark_or_drag(self):
        gui, instance, capture, windows, populate = self.fixture()
        def caption(_):
            # Model a blocking caption probe outlasting the overlay's auto-fade.
            gui.win32.return_value.send_message.return_value = 0
            instance.windows.return_value[0].visible = False
            return (400, 20)
        instance.caption_point.side_effect = caption
        with mock.patch.object(gx_perf, 'populate', side_effect=populate), \
                mock.patch.object(gx_perf, 'main_windows', return_value=windows):
            with self.assertRaisesRegex(gx_perf.PerfError, 'faded before measurement'):
                gx_perf.measure_ui(gui, instance, capture, SimpleNamespace(case='p3'))
        instance.drag.assert_not_called()
        capture.mark.assert_not_called()
        capture.window.assert_not_called()
        capture.count.assert_not_called()
        self.assertNotEqual('prepared', capture.report['p3_fixture']['status'])


def ticks(idle_seconds: float, now: int = 50_000_000) -> dict:
    """A fake QuietProbe.input_ticks() result with the given idle time."""
    return {'last_input_tick': (now - round(idle_seconds * 1000)) & 0xFFFFFFFF, 'tick_count': now & 0xFFFFFFFF}


def windows_data(*rows) -> dict:
    """A fake QuietProbe.windows() result: Win32_Process plus Get-Process rows."""
    cim = [{'pid': row['pid'], 'ppid': row.get('ppid', 0), 'name': row['name'], 'created': row.get('created', 1),
            'command_line': row.get('command_line')} for row in rows]
    processes = [{'pid': row['pid'], 'name': row['name'], 'title': row.get('title')} for row in rows]
    return {'inventory_pid': None, 'cim': cim, 'processes': processes}


def gtk_fixture(root: Path, thread_comm: str | None = None) -> dict:
    root.mkdir(parents=True, exist_ok=True)
    before = "\n".join((stat_line(10, "ghostty", 0, 0, 0, 0), stat_line(11, "renderer", 0, 0, 0, 0)))
    after = "\n".join((stat_line(10, "ghostty", 0, 0, 0, 0), stat_line(11, "renderer", 0, 0, 100, 0)))
    if thread_comm is not None:
        before += "\n" + stat_line(12, thread_comm, 0, 0, 0, 0)
        after += "\n" + stat_line(12, thread_comm, 0, 0, 0, 0)
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


class GtkClockEvidenceTests(unittest.TestCase):
    def fixture(self, root):
        meta = gtk_fixture(root)
        meta.update(schema="gx-gtk-perf-v2", clock_schema="gx-gtk-monotonic-ns-v1", clock_unit="ns")
        values = monotonic_times()
        self.persist(root, meta, values)
        return meta, values

    def persist(self, root, meta, values):
        times = "\n".join(f"{key} {value}" for key, value in values.items()) + "\n"
        (root / "perf-times.txt").write_text(times, encoding="utf-8", newline="\n")
        for name in meta["files"]:
            meta["artifact_sha256"][name] = gx_perf.hashlib.sha256((root / name).read_bytes()).hexdigest()
        (root / "perf-meta.json").write_text(json.dumps(meta), encoding="utf-8")

    def test_collector_accepts_v2_wall_jumps_and_v1_history(self):
        for modern in (False, True):
            with self.subTest(modern=modern), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self.fixture(root) if modern else gtk_fixture(root)
                meta, samples = gx_perf.gtk_evidence(root / "perf-meta.json")
                self.assertEqual("gx-gtk-perf-v2" if modern else "gx-gtk-perf-v1", meta["schema"])
                self.assertEqual([1000.0], samples.values["window_seconds"])

    def test_collector_rejects_clock_corruption_even_with_updated_artifact_hash(self):
        for fault in ("missing", "reverse", "nanoseconds", "duration", "unit", "version", "strip-all", "downgrade", "meta-unit"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                meta, values = self.fixture(root)
                if fault == "missing":
                    del values["workload_begin_monotonic_ns"]
                elif fault == "reverse":
                    values["window_monotonic_ns"] = values["launch_monotonic_ns"] - 1
                elif fault == "nanoseconds":
                    values["window_monotonic_ns"] += 1
                elif fault == "duration":
                    values["window_seconds"] = 1.000000002  # Same displayed ms, different raw ns.
                elif fault == "unit":
                    values["clock_unit"] = "us"
                elif fault == "version":
                    values["clock_schema"] = "unknown"
                elif fault == "strip-all":
                    values = {k: v for k, v in values.items() if not k.startswith("clock_") and not k.endswith("_monotonic_ns")}
                elif fault == "downgrade":
                    meta["schema"] = "gx-gtk-perf-v1"
                    del meta["clock_schema"], meta["clock_unit"]
                elif fault == "meta-unit":
                    meta["clock_unit"] = "s"
                self.persist(root, meta, values)
                with self.assertRaises(gx_perf.PerfError):
                    gx_perf.gtk_evidence(root / "perf-meta.json")

    def test_historical_negative_window_is_not_repaired(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            meta = gtk_fixture(root)
            values = {"pid": 10, "workload_finished": 1, "run_exit": 0,
                      "window_seconds": -0.36676621437072754, "workload_seconds": 1}
            self.persist(root, meta, values)
            with self.assertRaisesRegex(gx_perf.PerfError, "missing or invalid window_seconds"):
                gx_perf.gtk_evidence(root / "perf-meta.json")


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


class QuietTests(unittest.TestCase):
    def test_wsl_build_runner_detection_does_not_persist_command_lines(self):
        with mock.patch.object(gx_perf, 'command_output', side_effect=[
                'Ubuntu-24.04\n', 'Ubuntu-24.04\n', '10 python3 python3 scripts/run_unittests.py test_x\n11 ps ps -eo pid=,comm=,args=\n']):
            data = gx_perf.QuietProbe().wsl('Ubuntu-24.04')
        self.assertTrue(data['processes'][0]['build_runner'])
        self.assertFalse(data['processes'][1]['build_runner'])
        self.assertNotIn('argv', data['processes'][0])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.args = gx_perf.build_parser().parse_args(['quiet', '--out', self.temp.name + '/out',
                                                     '--slot-root', self.temp.name + '/locks'])
        self.probe = mock.Mock()
        self.probe.windows.return_value = windows_data({'pid': 10, 'name': 'ghostty', 'title': 'test'})
        self.probe.wsl.return_value = {'running': False, 'processes': []}
        self.probe.vm.return_value = {'win11': {'exists': True, 'owned': True, 'running': False}}
        self.probe.slots.return_value = True
        self.probe.input_ticks.return_value = ticks(600)
        self.probe.session.return_value = {'interactive_console': True, 'process_session': 1, 'active_console_session': 1}
        self.probe.cpu.return_value = {'cpu': 100, 'top': []}
        self.probe.containers.return_value = 0

    def test_cpu_is_not_a_gate_and_threshold_is_inclusive(self):
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual(0, result['exit'])
        self.assertTrue(result['quiet'])
        self.assertTrue(result['plan_compliant'])
        self.assertTrue(result['thresholds_plan_compliant'])
        self.probe.cpu.side_effect = OSError('PDH missing')
        self.assertEqual(0, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])

    def test_running_container_count_is_only_an_observation(self):
        self.probe.containers.return_value = 3
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual((0, 'recorded', 3), (result['exit'], result['docker_containers']['status'], result['docker_containers']['running']))
        self.probe.containers.side_effect = gx_perf.PerfError('docker ps exited 1')
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual((0, 'unavailable'), (result['exit'], result['docker_containers']['status']))
        import gx_windows_vm
        with mock.patch.object(gx_windows_vm, 'docker_executable', return_value='docker'), \
                mock.patch.object(gx_perf, 'command_output', return_value='abc\ndef\n\n') as command:
            self.assertEqual(2, gx_perf.QuietProbe().containers())
        command.assert_called_once_with(['docker', 'ps', '-q'])

    def test_each_gate_and_probe_error_fail_closed(self):
        # A blacklisted program is recorded, not a gate (r6 13:20 user ruling): see the blacklist tests.
        for method, value in [('windows', windows_data({'pid': 1, 'name': 'ZiG.ExE'})),
                              ('wsl', {'processes': [{'pid': 2, 'name': 'cc1plus'}]}),
                              ('vm', {'win11': {'running': True}}), ('slots', False), ('input_ticks', ticks(599.9))]:
            operation = getattr(self.probe, method)
            original = operation.return_value
            operation.return_value = value
            with self.subTest(method=method):
                self.assertEqual(3, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])
            operation.return_value = original
        self.probe.wsl.side_effect = OSError('unavailable')
        self.assertEqual(2, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])

    def test_polling_writes_every_attempt_without_overwriting(self):
        self.args.wait = True
        self.probe.input_ticks.side_effect = [ticks(20), ticks(600)]
        sleeper = mock.Mock()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.run_quiet(self.args, self.probe, sleeper))
        sleeper.assert_called_once_with(900)
        paths = sorted(self.args.out.glob('attempt-*.json'))
        self.assertEqual([3, 0], [json.loads(p.read_text(encoding='utf-8'))['exit'] for p in paths])
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.run_quiet(self.args, self.probe, sleeper)

    def test_wsl_stopped_is_not_started_and_vm_daemon_failure_is_error(self):
        with mock.patch.object(gx_perf, 'command_output', side_effect=['Ubuntu-24.04\n', '']) as command:
            self.assertFalse(gx_perf.QuietProbe().wsl('Ubuntu-24.04')['running'])
            self.assertEqual(2, command.call_count)
        import gx_windows_vm
        with mock.patch.object(gx_windows_vm, 'docker_executable', return_value='docker'), mock.patch.object(gx_perf, 'command_output', side_effect=gx_perf.PerfError('daemon')):
            with self.assertRaises(gx_perf.PerfError):
                gx_perf.QuietProbe().vm(self.args.slot_root)

    def test_unknown_distro_and_wrong_or_missing_slots_are_errors(self):
        with mock.patch.object(gx_perf, 'command_output', return_value='Other\n'):
            with self.assertRaises(gx_perf.PerfError):
                gx_perf.QuietProbe().wsl('typo')
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=self.args.slot_root):
            with self.assertRaises(gx_perf.PerfError):
                gx_perf.QuietProbe().slots(self.args.slot_root)
            self.assertFalse(self.args.slot_root.exists())
            with self.assertRaises(gx_perf.PerfError):
                gx_perf.QuietProbe().slots(Path(self.temp.name))

    def test_other_running_distro_is_checked(self):
        with mock.patch.object(gx_perf, 'command_output', side_effect=['Ubuntu-24.04\nOther\n', 'Other\n', '1 zig zig build\n']):
            raw = gx_perf.QuietProbe().wsl('Ubuntu-24.04')
        self.assertFalse(raw['running'])
        self.assertEqual('Other', raw['processes'][0]['distro'])
        self.assertEqual('zig', raw['processes'][0]['name'])

    def test_null_titles_redaction_plan_compliance_and_session_errors(self):
        self.probe.windows.return_value = windows_data({'pid': 5, 'name': 'app', 'title': None},
                                                       {'pid': 6, 'name': 'browser', 'title': 'private ToDesk title'})
        self.args.idle_seconds = 5
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertFalse(result['plan_compliant'])
        self.assertFalse(result['thresholds_plan_compliant'])
        self.assertNotIn('private', json.dumps(result))
        self.assertEqual(['ToDesk'], result['blacklist_observation']['matches'][0]['matches'])
        self.assertEqual('running in the active console session', result['checks']['session']['reason'])
        self.probe.session.return_value = {'interactive_console': False}
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual((2, 'error'), (result['exit'], result['checks']['session']['status']))
        self.assertIn('not in the active console session', result['checks']['session']['reason'])

    def test_blacklist_is_the_plan_list_matched_case_insensitively_and_kimi_cu_is_only_observed(self):
        self.assertEqual(('Devin', 'devin', 'ToDesk', 'Kimi Code', '哔哩哔哩'), gx_perf.BLACKLIST)
        rows = [{'pid': 1, 'name': 'kimi-cu.exe', 'title': 'kimi-cu'}, {'pid': 2, 'name': 'todesk-lookalike', 'title': 'KIMI CODE'},
                {'pid': 3, 'name': 'devin', 'title': ''}, {'pid': 4, 'name': 'Kimi Code.exe', 'title': ''},
                {'pid': 5, 'name': 'player', 'title': '哔哩哔哩 (゜-゜)つロ'}, {'pid': 6, 'name': 'todesk.exe', 'title': ''},
                {'pid': 7, 'name': 'TODESK.EXE', 'title': ''}, {'pid': 8, 'name': 'WindowsTerminal', 'title': 'Kimi code'},
                {'pid': 9, 'name': 'DEVIN.EXE', 'title': ''}]
        expected = {2: ['Kimi Code', 'ToDesk'], 3: ['Devin'], 4: ['Kimi Code'], 5: ['哔哩哔哩'], 6: ['ToDesk'],
                    7: ['ToDesk'], 8: ['Kimi Code'], 9: ['Devin']}
        self.probe.windows.return_value = windows_data(*rows)
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual(expected, {row['pid']: row['matches'] for row in result['blacklist_observation']['matches']})
        self.assertIn('case-insensitive', result['blacklist_matching'])
        self.assertEqual(result['blacklist_matching'], result['blacklist_observation']['matching'])
        self.assertEqual('recorded', result['other_programs']['status'])
        self.assertEqual([1], [row['pid'] for row in result['other_programs']['matches']])
        self.assertNotIn('つロ', gx_perf.json.dumps(result, ensure_ascii=False))
        # With --strict-blacklist each spelling is a gate again; kimi-cu alone never is.
        self.args.strict_blacklist = True
        self.assertEqual(expected, {row['pid']: row['matches'] for row in
                                    gx_perf.quiet_snapshot(self.args, self.probe)['checks']['blacklist']['raw']})
        for variant in rows[1], rows[5], rows[6], rows[7]:
            with self.subTest(name=variant['name'], title=variant['title']):
                self.probe.windows.return_value = windows_data(rows[0], variant)
                self.assertEqual('fail', gx_perf.quiet_snapshot(self.args, self.probe)['checks']['blacklist']['status'])
        self.probe.windows.return_value = windows_data(rows[0])
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual(0, result['exit'])
        self.assertEqual([1], [row['pid'] for row in result['other_programs']['matches']])
        self.args.blacklist = ['KIMI-CU']  # additions fold too
        self.assertEqual(3, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])
        self.args.strict_blacklist = False
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual((0, [1]), (result['exit'], [row['pid'] for row in result['blacklist_observation']['matches']]))

    def test_blacklisted_programs_are_recorded_not_gated_since_the_1320_ruling(self):
        # r6-contract.md §6 13:20 (user ruling): other software is recorded like CPU; quiet, exit and
        # plan_compliant ignore it. --strict-blacklist restores the gate of the earlier criteria.
        self.probe.windows.return_value = windows_data({'pid': 10, 'name': 'ghostty', 'title': 'test'},
                                                       {'pid': 77, 'name': 'Kimi Code.exe', 'title': 'private chat title'})
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual((0, True, True), (result['exit'], result['quiet'], result['plan_compliant']))
        self.assertEqual(('r6-13:20 user ruling', {'strict_blacklist': False, 'input_observe_only': False}),
                         (result['criteria'], result['criteria_options']))
        self.assertNotIn('blacklist', result['checks'])
        self.assertEqual(['input', 'session', 'slots', 'vm', 'windows', 'wsl'], sorted(result['gates']))
        self.assertIn('blacklist', result['observed_only'])
        observation = result['blacklist_observation']
        self.assertEqual(('recorded', [{'pid': 77, 'name': 'Kimi Code.exe', 'matches': ['Kimi Code']}]),
                         (observation['status'], observation['matches']))
        self.assertIn('never a quiet gate', observation['scope'])
        self.assertIn('casefold', observation['matching'])
        self.assertNotIn('private chat title', json.dumps(result, ensure_ascii=False))
        self.args.strict_blacklist = True
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual((3, False, False), (result['exit'], result['quiet'], result['plan_compliant']))
        self.assertEqual(('fail', [77]), (result['checks']['blacklist']['status'],
                                          [row['pid'] for row in result['checks']['blacklist']['raw']]))
        self.assertTrue(result['criteria_options']['strict_blacklist'])
        self.assertEqual(['blacklist', 'input', 'session', 'slots', 'vm', 'windows', 'wsl'], sorted(result['gates']))
        self.assertNotIn('blacklist', result['observed_only'])
        # An unavailable Windows inventory is a tool error only for the strict gate (the windows check errs anyway).
        self.probe.windows.side_effect = OSError('CIM unavailable')
        self.assertEqual('error', gx_perf.quiet_snapshot(self.args, self.probe)['checks']['blacklist']['status'])
        self.args.strict_blacklist = False
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual(('unavailable', 'Windows inventory unavailable'),
                         (result['blacklist_observation']['status'], result['blacklist_observation']['reason']))
        self.assertNotIn('blacklist', result['checks'])
        # Both switches reach the parser of `quiet`.
        args = gx_perf.build_parser().parse_args(['quiet', '--out', 'x', '--strict-blacklist', '--input-observe-only'])
        self.assertEqual((True, True), (args.strict_blacklist, args.input_observe_only))

    def test_input_observe_only_records_the_idle_time_without_gating(self):
        self.args.input_observe_only = True
        self.probe.input_ticks.return_value = ticks(5)
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual((0, True, True, True), (result['exit'], result['quiet'], result['plan_compliant'],
                                                 result['thresholds_plan_compliant']))
        row = result['checks']['input']
        self.assertEqual(('observed', 'fail', 5.0), (row['status'], row['observed'], row['raw']['idle_seconds']))
        self.assertEqual('observe only (--input-observe-only, a WSL/Xvfb batch): idle 5.000s; required 600s', row['reason'])
        self.assertNotIn('input', result['gates'])
        self.assertIn('input', result['observed_only'])
        # This project's own load still gates, and a failing input probe is still a tool error.
        self.probe.wsl.return_value = {'running': True, 'processes': [{'pid': 2, 'name': 'zig'}]}
        self.assertEqual(3, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])
        self.probe.wsl.return_value = {'running': False, 'processes': []}
        self.probe.input_ticks.side_effect = OSError('GetLastInputInfo failed')
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual((2, 'error'), (result['exit'], result['checks']['input']['status']))

    def test_ancestor_exemption_covers_runner_command_lines_only(self):
        me = gx_perf.os.getpid()
        self.probe.windows.return_value = {'inventory_pid': 900, 'cim': [
            {'pid': 900, 'ppid': me, 'name': 'powershell.exe', 'created': 40, 'command_line': 'powershell -NoProfile'},
            {'pid': me, 'ppid': 50, 'name': 'python.exe', 'created': 30, 'command_line': 'python scripts/gx_perf.py quiet --out x'},
            {'pid': 50, 'ppid': 60, 'name': 'Kimi Code.exe', 'created': 20, 'command_line': 'python scripts/run_unittests.py test_x'},
            {'pid': 60, 'ppid': 0, 'name': 'ninja.exe', 'created': 10, 'command_line': 'ninja -C out'}],
            'processes': [{'pid': 50, 'name': 'Kimi Code', 'title': 'Kimi Code'}]}
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        windows = result['checks']['windows']
        self.assertEqual({900: 'inventory', me: 'self', 50: 'ancestor', 60: 'ancestor'},
                         {row['pid']: row['reason'] for row in windows['raw']['runner_exclusions']})
        self.assertTrue(next(row for row in windows['raw']['runner_exclusions'] if row['pid'] == 50)['runner_match_suppressed'])
        # The exemption hides only the runner command lines: an ancestor's build name still gates and its
        # blacklist name is still recorded (a gate with --strict-blacklist).
        self.assertEqual('fail', windows['status'])
        self.assertIn('[60]', windows['reason'])
        self.assertNotIn('blacklist', result['checks'])
        self.assertEqual([50], [row['pid'] for row in result['blacklist_observation']['matches']])
        self.args.strict_blacklist = True
        strict = gx_perf.quiet_snapshot(self.args, self.probe)['checks']['blacklist']
        self.assertEqual(('fail', [50]), (strict['status'], [row['pid'] for row in strict['raw']]))
        self.args.strict_blacklist = False
        self.assertEqual('root', windows['raw']['ancestor_chain_end'])
        self.assertNotIn('run_unittests', gx_perf.json.dumps(result))

    def test_recycled_parent_pid_is_not_exempt(self):
        me = gx_perf.os.getpid()
        self.probe.windows.return_value = {'inventory_pid': None, 'cim': [
            {'pid': me, 'ppid': 50, 'name': 'python.exe', 'created': 30, 'command_line': 'python scripts/gx_perf.py quiet'},
            {'pid': 50, 'ppid': 0, 'name': 'python.exe', 'created': 31, 'command_line': 'python scripts/zig_test.py --suite main'}],
            'processes': [{'pid': me, 'name': 'python', 'title': ''}]}
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        windows = result['checks']['windows']
        self.assertEqual('parent_pid_reused_or_unverifiable', windows['raw']['ancestor_chain_end'])
        self.assertEqual([me], [row['pid'] for row in windows['raw']['runner_exclusions']])
        self.assertEqual('fail', windows['status'])
        self.assertIn('[50]', windows['reason'])
        excluded, end = gx_perf.ancestor_exclusions([{'pid': 7, 'ppid': 8, 'created': 5}], 7)
        self.assertEqual(({7: 'self'}, 'parent_exited'), (excluded, end))
        self.assertEqual(({}, 'self_missing'), gx_perf.ancestor_exclusions([{'pid': 7, 'ppid': 0}], 9))
        unverifiable = [{'pid': 7, 'ppid': 8, 'created': 5}, {'pid': 8, 'ppid': 0, 'created': None}]
        self.assertEqual('parent_pid_reused_or_unverifiable', gx_perf.ancestor_exclusions(unverifiable, 7)[1])

    def test_probe_unexpected_exception_is_recorded(self):
        self.probe.windows.side_effect = AttributeError('unexpected')
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual(2, result['exit'])
        self.assertEqual('error', result['checks']['windows']['status'])


class QuietBatchTests(unittest.TestCase):
    def test_gtk_action_exit4_and_standard_remains_error(self):
        for index, case in enumerate(('p2', 'p4', 'standard')):
            args = self.batch_args('--input-observe-only', command=(
                'just', 'perf', 'gtk', '--case=' + case, '--clone', '/clone', '--out', 'measure'))
            args.out = self.args.out.parent / f'gtk-gate-{index}'
            code, result = self.run_batch(args, self.command(4))
            self.assertEqual((2, 'ERROR', 'DRIVER_ERROR') if case == 'standard' else (4, 'FAIL', 'GATE_FAIL'),
                             (code, result['status'], result['measurement']))
            self.assertEqual(str(Path.cwd() / 'scripts/gx_perf.py'), result['command'][1])

    def test_gtk_case_never_unwraps_non_wsl_entry(self):
        for command in (
                ['python', 'scripts/gx_perf.py', 'win32-ui', '--case', 'p4'],
                ['python', 'wrapper.py', 'gtk', '--case', 'p2'],
                ['cmd', '/c', 'python scripts/gx_perf.py gtk --case p4'],
                ['python', '-m', 'gx_perf', 'gtk', '--case', 'p4']):
            self.assertTrue(gx_perf.desktop_command(gx_perf.normalize_observe_command(command)))

    def test_gtk_gate_parses_options_not_value_substrings(self):
        prefix = ['python', 'scripts/gx_perf.py', 'gtk', '--clone', '/clone', '--out', 'measure']
        for tail, accepted in ((['--case', 'p2'], True), (['--case=p4'], True),
                               ([], False), (['--env=VALUE=--case=p4'], False),
                               (['--case', 'p4', '--case=standard'], False),
                               (['--case', 'p4', '&&', 'ghostty.exe'], False),
                               (['--case=win32-ui'], False)):
            self.assertEqual(accepted, gx_perf.gate_exit_contract(prefix + tail), tail)

    setUp = QuietTests.setUp
    DRIVER = ('python', 'scripts/gx_perf.py', 'win32-ui', '--case', 'p4')  # exit 4 = complete batch, gate FAIL

    def batch_args(self, *extra, command=('dummy-command',)):
        import gx_slots
        with gx_slots.acquire(self.args.slot_root, 'quiet'):
            pass
        return gx_perf.build_parser().parse_args(['quiet-batch', '--out', str(self.args.out),
            '--slot-root', str(self.args.slot_root), *extra, '--', *command])

    def test_checks_are_inside_lease_and_injected_end_uses_guards(self):
        import gx_slots
        args = self.batch_args('--injected-input')
        def run(command, **kwargs):
            with self.assertRaises(TimeoutError):
                with gx_slots.acquire(args.slot_root, 'quiet'):
                    pass
            row = {'schema': 'gx-input-guard-v1', 'batch_id': kwargs['env']['GX_PERF_BATCH_ID'],
                   'event': 'guard', 'check': 'ensure_foreground', 'status': 'pass'}
            Path(kwargs['env']['GX_PERF_GUARD_LOG']).write_text(json.dumps(row)+'\n', encoding='utf-8')
            return SimpleNamespace(returncode=0)
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.run_quiet_batch(args, self.probe, run))
        self.probe.input_ticks.assert_called_once()
        for name in ('before', 'after'):
            data = json.loads((args.out / (name+'.json')).read_text(encoding='utf-8'))
            self.assertEqual('all four locks held by this batch', data['checks']['slots']['reason'])
        result = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual(('gx-quiet-batch-v2', 'VALID', 'VALID', 'COMPLETE', True, True),
                         (result['schema'], result['status'], result['quiet_status'], result['measurement'],
                          result['quiet_valid'], result['plan_compliant']))
        self.assertTrue((args.out / 'SUMMARY.txt').read_text(encoding='utf-8').startswith('VALID exit=0 quiet=VALID measurement=COMPLETE'))

    def test_before_busy_never_runs_command_and_after_busy_invalidates(self):
        args = self.batch_args()
        self.probe.input_ticks.return_value = ticks(5)
        runner = mock.Mock(return_value=SimpleNamespace(returncode=0))
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(3, gx_perf.run_quiet_batch(args, self.probe, runner))
        runner.assert_not_called()
        result = json.loads((args.out/'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual(('NOT_STARTED', 'NOT_MET', 'NOT_RUN'), (result['status'], result['quiet_status'], result['measurement']))
        args.out = args.out.parent / 'second'
        self.probe.input_ticks.side_effect = [ticks(600), ticks(5)]
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(3, gx_perf.run_quiet_batch(args, self.probe, runner))
        result = json.loads((args.out/'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual(('INVALID', 'INVALID', 'COMPLETE'), (result['status'], result['quiet_status'], result['measurement']))
        self.assertFalse(result['quiet_valid'])
        self.assertFalse(result['plan_compliant'])
        self.assertEqual(('foreign_input', ['input']), (result['failure_cause'], result['failed_checks']))
        # A failed non-input criterion is reported as such.
        args.out = args.out.parent / 'third'
        self.probe.input_ticks.side_effect = None
        self.probe.input_ticks.return_value = ticks(600)
        self.probe.vm.side_effect = [{'win11': {'exists': True, 'owned': True, 'running': False}},
                                     {'win11': {'exists': True, 'owned': True, 'running': True}}]
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(3, gx_perf.run_quiet_batch(args, self.probe, runner))
        result = json.loads((args.out/'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual(('INVALID', 'quiet_criteria', ['vm']), (result['status'], result['failure_cause'], result['failed_checks']))

    def test_uninjected_end_check_rejects_any_input_after_the_start(self):
        start = 0xFFFFFF00  # the tick clock wraps during this batch
        for label, last_input, valid in (('input-during-batch', (start + 500_000) & 0xFFFFFFFF, False),
                                         ('no-input', (start - 700_000) & 0xFFFFFFFF, True)):
            args = self.batch_args()
            args.out = self.args.out.parent / label
            # The command takes 1200 s; with input 500 s in, the end idle (700 s) still exceeds 600 s.
            self.probe.input_ticks.side_effect = [ticks(700, start),
                                                  {'last_input_tick': last_input, 'tick_count': (start + 1_200_000) & 0xFFFFFFFF}]
            runner = mock.Mock(return_value=SimpleNamespace(returncode=0))
            with self.subTest(label), mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0 if valid else 3, gx_perf.run_quiet_batch(args, self.probe, runner))
                after = json.loads((args.out / 'after.json').read_text(encoding='utf-8'))['checks']['input']
                self.assertEqual('pass' if valid else 'fail', after['status'])
                self.assertEqual(None if valid else 'foreign_input',
                                 json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))['failure_cause'])
                self.assertEqual(1200, after['raw']['batch_seconds'])
                self.assertEqual(start, after['raw']['batch_start_tick'])

    def run_batch(self, args, runner):
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            code = gx_perf.run_quiet_batch(args, self.probe, runner)
        return code, json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))

    @staticmethod
    def command(code=0, guard=None, **extra):
        def runner(command, **kwargs):
            if code == 'raise':
                raise RuntimeError('child setup')
            if guard:
                # Like gx_win_gui.input_guard: the guard that precedes a SendInput.
                row = {'schema': 'gx-input-guard-v1', 'batch_id': kwargs['env']['GX_PERF_BATCH_ID'], 'event': 'guard',
                       'check': 'ensure_foreground', 'status': guard, **extra}
                Path(kwargs['env']['GX_PERF_GUARD_LOG']).write_text(json.dumps(row) + '\n', encoding='utf-8')
            return SimpleNamespace(returncode=code)
        return runner

    def test_injected_batch_that_sent_no_input_falls_back_to_last_input(self):
        start = 50_000_000
        for label, last_input, expected, status in (('no-input', start - 700_000, 0, 'VALID'),
                                                    ('input-during-batch', start + 30_000, 3, 'INVALID')):
            args = self.batch_args('--injected-input')
            args.out = self.args.out.parent / label
            # Start: idle 700 s. End after 90 s: either still no input (idle 790 s) or input 30 s in (idle 60 s).
            self.probe.input_ticks.side_effect = [ticks(700, start), {'last_input_tick': last_input, 'tick_count': start + 90_000}]
            with self.subTest(label):
                exit_code, result = self.run_batch(args, self.command(0))  # zero guard rows: nothing was injected
                self.assertEqual((expected, status), (exit_code, result['status']))
                raw = json.loads((args.out / 'after.json').read_text(encoding='utf-8'))['checks']['input']['raw']
                self.assertEqual(('last_input', 'last_input', 0, False, 90), (raw['mode'], raw['fallback'], raw['guards'],
                                                                             raw['injected'], raw['batch_seconds']))
        # A guard that failed before any input was sent also counts as no injection, but it fails the criterion.
        args = self.batch_args('--injected-input')
        args.out = self.args.out.parent / 'failed-first-guard'
        self.probe.input_ticks.side_effect = None
        self.probe.input_ticks.return_value = ticks(700)
        exit_code, result = self.run_batch(args, self.command(0, guard='fail', cause='foreground_lost'))
        self.assertEqual((3, 'INVALID'), (exit_code, result['status']))
        raw = json.loads((args.out / 'after.json').read_text(encoding='utf-8'))['checks']['input']['raw']
        self.assertEqual(('guards', False), (raw['mode'], raw['injected']))

    def test_preflight_rejects_a_session_that_cannot_see_the_console_user(self):
        import gx_slots
        args = self.batch_args('--timeout', '14400')
        self.probe.session.return_value = {'interactive_console': False, 'process_session': 2, 'active_console_session': 1}
        runner = mock.Mock(return_value=SimpleNamespace(returncode=0))
        with mock.patch.object(gx_slots, 'acquire', side_effect=AssertionError('waited for locks')):
            exit_code, result = self.run_batch(args, runner)
        self.assertEqual((2, 'NOT_STARTED', 'NOT_RUN', 'NOT_CHECKED'),
                         (exit_code, result['status'], result['measurement'], result['quiet_status']))
        self.assertIn('not in the active console session', ' '.join(result['errors']))
        self.assertNotIn('preflight', result)
        self.assertFalse((args.out / 'before.json').exists())
        runner.assert_not_called()
        self.probe.registered.assert_called_once_with('Ubuntu-24.04')
        self.probe.input_ticks.assert_not_called()
        # A failing session probe is a tool error too, still before any lock.
        args.out = self.args.out.parent / 'session-error'
        self.probe.session.side_effect = OSError('WTSGetActiveConsoleSessionId failed')
        with mock.patch.object(gx_slots, 'acquire', side_effect=AssertionError('waited for locks')):
            exit_code, result = self.run_batch(args, runner)
        self.assertEqual((2, 'NOT_STARTED'), (exit_code, result['status']))
        self.assertIn('WTSGetActiveConsoleSessionId failed', ' '.join(result['errors']))

    def test_exit_4_is_a_gate_fail_only_for_gx_perf_win32_drivers(self):
        commands = [  # (command, gate contract)
            (self.DRIVER, True),
            ((r'C:\Py\python.exe', '-X', 'utf8', r'E:\gx\scripts\GX_PERF.PY', 'win32-idle', '--tabs', '11'), True),
            (('just', 'perf', 'win32-gpu', '--exe', 'new.exe'), True),
            (('just.exe', '--justfile', 'justfile', 'perf', 'win32-mem'), True),
            (('python', 'scripts/gx_perf.py', 'gtk', '--clone', 'x'), False),
            (('python', 'scripts/gx_perf.py', 'win32', '--exe', 'x'), False),
            (('perf', 'win32-ui'), False),
            (('measure.cmd', 'win32-ui'), False),
            (('dummy-command',), False),
        ]
        for index, (command, contract) in enumerate(commands):
            self.assertEqual(contract, gx_perf.gate_exit_contract(list(command)), command)
            args = self.batch_args(command=command)
            args.out = self.args.out.parent / f'exit4-{index}'
            with self.subTest(command=command):
                exit_code, result = self.run_batch(args, self.command(4))
                self.assertEqual((4, 'FAIL', 'GATE_FAIL') if contract else (2, 'ERROR', 'DRIVER_ERROR'),
                                 (exit_code, result['status'], result['measurement']))
                self.assertEqual(contract, result['gate_exit_contract'])
                self.assertEqual(not contract, any('only for gx_perf.py win32-* drivers' in error for error in result['errors']))

    def test_preflight_rejects_impossible_batches_before_waiting_for_locks(self):
        import gx_slots
        args = self.batch_args('--timeout', '14400')
        self.probe.registered.side_effect = gx_perf.PerfError('WSL distribution is not registered: typo')
        with mock.patch.object(gx_slots, 'acquire', side_effect=AssertionError('waited for locks')):
            exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((2, 'NOT_STARTED', 'NOT_RUN'), (exit_code, result['status'], result['measurement']))
        self.assertIn('not registered', ' '.join(result['errors']))
        self.assertFalse((args.out / 'before.json').exists())
        self.probe.registered.side_effect = None
        args.out = self.args.out.parent / 'nested'
        born = gx_perf.FILETIME_UNIX_EPOCH + (gx_perf.time.time_ns() - 10_000_000_000) // 100
        self.probe.windows.return_value = {'inventory_pid': None, 'processes': [{'pid': 1, 'name': 'x', 'title': ''}],
                                           'cim': [{'pid': gx_perf.os.getpid(), 'ppid': 0, 'name': 'python.exe', 'created': born}]}
        with gx_slots.acquire(args.slot_root, 'heavy'), mock.patch.object(gx_slots, 'acquire', side_effect=AssertionError('waited')):
            exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((2, 'NOT_STARTED'), (exit_code, result['status']))
        self.assertIn('never inside gx_slots.py, Invoke-Heavy or Invoke-Desktop', ' '.join(result['errors']))
        # A record left by another (or recycled) PID is not nesting: the batch proceeds.
        args.out = self.args.out.parent / 'foreign-record'
        (args.slot_root / 'heavy-2.lock').write_bytes(b'\0' + json.dumps({'pid': 999999, 'kind': 'heavy', 'started_ns': 1}).encode())
        self.probe.windows.return_value = windows_data({'pid': 10, 'name': 'ghostty', 'title': 'test'})
        exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((0, 'VALID'), (exit_code, result['status']))
        self.assertEqual([999999], [row['pid'] for row in result['preflight']['slot_holders']])

    def test_gate_fail_under_valid_checks_is_fail_not_invalid(self):
        cases = [  # (flags, command exit, guard, exit, status, quiet, measurement)
            ((), 4, None, 4, 'FAIL', 'VALID', 'GATE_FAIL'),
            (('--injected-input',), 4, 'pass', 4, 'FAIL', 'VALID', 'GATE_FAIL'),
            ((), 1, None, 2, 'ERROR', 'VALID', 'DRIVER_ERROR'),
            (('--injected-input',), 1, 'pass', 2, 'ERROR', 'VALID', 'DRIVER_ERROR'),
            # The driver failed before its first input: nothing was injected, so the last-input check decides.
            (('--injected-input',), 1, None, 2, 'ERROR', 'VALID', 'DRIVER_ERROR'),
            (('--injected-input',), 'raise', None, 2, 'ERROR', 'VALID', 'DRIVER_ERROR'),
        ]
        for index, (flags, code, guard, expected, status, quiet, measurement) in enumerate(cases):
            args = self.batch_args(*flags, command=self.DRIVER)
            args.out = self.args.out.parent / f'case-{index}'
            with self.subTest(flags=flags, code=code, guard=guard):
                exit_code, result = self.run_batch(args, self.command(code, guard))
                self.assertEqual((expected, status, quiet, measurement),
                                 (exit_code, result['status'], result['quiet_status'], result['measurement']))
                self.assertEqual(quiet == 'VALID', result['quiet_valid'])
                self.assertEqual(None if code == 'raise' else code, result['command_exit'])
        after = json.loads((self.args.out.parent / 'case-4' / 'after.json').read_text(encoding='utf-8'))
        self.assertEqual(('pass', 'last_input'), (after['checks']['input']['status'], after['checks']['input']['raw']['fallback']))
        self.assertNotIn('unverified_checks', after)
        summary = (self.args.out.parent / 'case-0' / 'SUMMARY.txt').read_text(encoding='utf-8')
        self.assertIn('never rerun to replace it', summary)

    def test_guard_evidence_failures_are_invalid_or_tool_errors(self):
        for index, (code, guard, expected, status) in enumerate(((0, 'fail', 3, 'INVALID'), (1, 'fail', 3, 'INVALID'))):
            args = self.batch_args('--injected-input')
            args.out = self.args.out.parent / f'guard-{index}'
            with self.subTest(code=code, guard=guard):
                exit_code, result = self.run_batch(args, self.command(code, guard, cause='foreground_lost'))
                self.assertEqual((expected, status), (exit_code, result['status']))
        foreign = self.args.out.parent / 'foreign.jsonl'
        foreign.write_text(json.dumps({'schema': 'gx-input-guard-v1', 'batch_id': 'other', 'event': 'guard', 'status': 'pass'}) + '\n', encoding='utf-8')
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.guard_evidence(foreign, 'mine')
        release = self.args.out.parent / 'release.jsonl'
        release.write_text(json.dumps({'schema': 'gx-input-guard-v1', 'batch_id': 'b', 'event': 'release', 'status': 'fail', 'reason': 'UIPI'}) + '\n', encoding='utf-8')
        evidence = gx_perf.guard_evidence(release, 'b')
        self.assertEqual((1, False), (len(evidence['unexplained']), evidence['injected']))
        with self.assertRaisesRegex(gx_perf.PerfError, 'UIPI'):
            gx_perf.end_input({'evidence': evidence, 'since': ticks(700), 'injected_mode': True}, self.probe, 600)
        self.assertEqual({'events': 0, 'guards': 0, 'passed_guards': 0, 'injected': False, 'environment': [], 'product': [],
                          'unexplained': [], 'sha256': None}, gx_perf.guard_evidence(self.args.out.parent / 'absent.jsonl', 'b'))

    @staticmethod
    def audited(code, *rows):
        """A command that leaves the given gx-input-guard-v1 rows, like gx_win_gui does."""
        def runner(command, **kwargs):
            with Path(kwargs['env']['GX_PERF_GUARD_LOG']).open('a', encoding='utf-8') as log:
                for row in rows:
                    log.write(json.dumps({'schema': 'gx-input-guard-v1', 'batch_id': kwargs['env']['GX_PERF_BATCH_ID'],
                                          'instance_pid': 42, **row}) + '\n')
            return SimpleNamespace(returncode=code)
        return runner

    def test_instance_gone_is_product_fail_never_invalid(self):
        sent = {'event': 'guard', 'check': 'ensure_foreground', 'status': 'pass'}
        gone = {'event': 'instance', 'status': 'fail', 'cause': 'instance_gone', 'reason': 'Ghostty 实例 42 已结束'}
        gone_guard = {'event': 'guard', 'check': 'ensure_foreground', 'status': 'fail', 'cause': 'instance_gone', 'reason': 'gone'}
        lost = {'event': 'guard', 'check': 'ensure_point', 'status': 'fail', 'cause': 'pointer_target_lost', 'reason': 'covered'}
        cases = [  # (label, flags, command exit, rows, quiet status)
            ('crash-mid-input', ('--injected-input',), 1, (sent, gone, gone_guard), 'VALID'),
            ('crash-and-noise', ('--injected-input',), 1, (sent, lost, gone), 'INVALID'),
            # A one-tab win32-idle sends no input; the instance died during the idle window.
            ('crash-without-input', (), 1, (gone,), 'VALID'),
            ('helper-crash-command-ok', ('--injected-input',), 0, (sent, gone), 'VALID'),
        ]
        for label, flags, code, rows, quiet in cases:
            args = self.batch_args(*flags)
            args.out = self.args.out.parent / label
            with self.subTest(label):
                exit_code, result = self.run_batch(args, self.audited(code, *rows))
                self.assertEqual((6, 'PRODUCT_FAIL', 'instance_gone', quiet),
                                 (exit_code, result['status'], result['failure_cause'], result['quiet_status']))
                self.assertIn('instance_gone: Ghostty pid 42', ' '.join(result['errors']))
                self.assertIn('(arm unknown: no driver run.json names that pid)', ' '.join(result['errors']))
                self.assertIn('never rerun to replace it', result['guidance'])
                self.assertIn('failure_cause=instance_gone', (args.out / 'SUMMARY.txt').read_text(encoding='utf-8'))

    def test_a_product_failure_names_the_arm_and_run_of_its_instance(self):
        self.assertEqual(Path('M'), gx_perf.driver_out_dir(['python', 'scripts/gx_perf.py', 'win32-ui', '--out', 'M']))
        self.assertEqual(Path('M'), gx_perf.driver_out_dir(['just', 'perf', 'win32-idle', '--out=M']))
        self.assertIsNone(gx_perf.driver_out_dir(['python', 'other.py', '--out', 'M']))
        measurement = self.args.out.parent / 'measurement'
        def runner(command, **kwargs):
            for label, run, pid, baseline in (('old', 1, 41, True), ('new', 2, 42, False)):
                target = measurement / label / f'run-{run:02d}'
                target.mkdir(parents=True)
                (target / 'run.json').write_text(json.dumps({'label': label, 'run': run, 'pid': pid, 'baseline': baseline}),
                                                 encoding='utf-8')
            with Path(kwargs['env']['GX_PERF_GUARD_LOG']).open('a', encoding='utf-8') as log:
                for pid, cause in ((41, 'instance_gone'), (42, 'instance_hung')):
                    log.write(json.dumps({'schema': 'gx-input-guard-v1', 'batch_id': kwargs['env']['GX_PERF_BATCH_ID'],
                                          'event': 'instance', 'status': 'fail', 'cause': cause, 'instance_pid': pid,
                                          'reason': f'pid {pid}'}) + '\n')
            return SimpleNamespace(returncode=1)
        args = self.batch_args(command=('python', 'scripts/gx_perf.py', 'win32-ui', '--out', str(measurement), '--case', 'p4'))
        exit_code, result = self.run_batch(args, runner)
        self.assertEqual((6, 'PRODUCT_FAIL', 'instance_gone'), (exit_code, result['status'], result['failure_cause']))
        self.assertEqual([{'instance_pid': 41, 'label': 'old', 'run': 1, 'baseline': True, 'path': 'old/run-01'},
                          {'instance_pid': 42, 'label': 'new', 'run': 2, 'baseline': False, 'path': 'new/run-02'}],
                         result['product_failure_runs'])
        self.assertIn('instance_gone: Ghostty pid 41 ended or changed identity mid-batch in arm old run 1 (the historical '
                      'arm): pid 41', result['errors'])
        self.assertIn('root rules on a crash of the historical arm', result['guidance'])
        self.assertEqual([{'instance_pid': 7, 'label': None, 'run': None, 'baseline': None, 'path': None}],
                         gx_perf.product_failure_runs(None, [{'instance_pid': 7}, {'instance_pid': 7}]))

    def test_a_hung_instance_is_product_fail_too(self):
        import gx_win_gui as real
        sent = {'event': 'guard', 'check': 'ensure_foreground', 'status': 'pass'}
        hung = {'event': 'guard', 'check': 'ensure_foreground', 'status': 'fail', 'cause': 'instance_hung',
                'reason': 'ghostty pid 42 hangs or crashed (IsHungAppWindow reports its GhosttyWindow 0x10)',
                'other_class': 'Ghost', 'other_image': 'dwm.exe'}
        args = self.batch_args('--injected-input')
        exit_code, result = self.run_batch(args, self.audited(1, sent, hung))
        self.assertEqual((6, 'PRODUCT_FAIL', 'instance_hung'), (exit_code, result['status'], result['failure_cause']))
        self.assertIn('instance_hung: Ghostty pid 42 hangs or crashed mid-batch', ' '.join(result['errors']))
        self.assertIn('instance_hung', gx_perf.PRODUCT_CAUSES)
        self.assertNotIn('instance_hung', gx_perf.ENVIRONMENT_CAUSES)
        self.assertEqual(set(real.InputBlocked.CAUSES) - {'other'},
                         set(gx_perf.PRODUCT_CAUSES) | set(gx_perf.ENVIRONMENT_CAUSES))

    def test_environment_causes_are_invalid_and_unknown_causes_are_tool_errors(self):
        sent = {'event': 'guard', 'check': 'ensure_foreground', 'status': 'pass'}
        foreign = {'event': 'guard', 'check': 'idle_input_window', 'status': 'fail', 'cause': 'foreign_input',
                   'reason': 'external input occurred during the idle measurement window'}
        cases = [  # (label, flags, command exit, rows, exit, status, failure cause)
            ('foreground', ('--injected-input',), 1, (sent, {'event': 'guard', 'check': 'ensure_foreground', 'status': 'fail',
                                                            'cause': 'foreground_lost', 'other_image': 'explorer.exe'}),
             3, 'INVALID', 'foreground_lost'),
            ('pointer', ('--injected-input',), 1, (sent, {'event': 'guard', 'check': 'ensure_point', 'status': 'fail',
                                                         'cause': 'pointer_target_lost'}), 3, 'INVALID', 'pointer_target_lost'),
            # Multi-tab win32-idle: setup input passed its guards, then the driver saw foreign input and exited 1.
            ('idle-foreign-input', ('--injected-input',), 1, (sent, foreign), 3, 'INVALID', 'foreign_input'),
            # Without the flag a failed check is still noise, not a mode mismatch: nothing was sent.
            ('idle-foreign-input-uninjected', (), 1, (foreign,), 3, 'INVALID', 'foreign_input'),
            ('unknown-cause', ('--injected-input',), 1, (sent, {'event': 'guard', 'check': 'ensure_point', 'status': 'fail',
                                                               'cause': 'other'}), 2, 'ERROR', 'end_check_error'),
            ('legacy-row-without-cause', ('--injected-input',), 1, (sent, {'event': 'guard', 'check': 'ensure_point',
                                                                          'status': 'fail'}), 2, 'ERROR', 'end_check_error'),
        ]
        for label, flags, code, rows, expected, status, cause in cases:
            args = self.batch_args(*flags)
            args.out = self.args.out.parent / label
            with self.subTest(label):
                exit_code, result = self.run_batch(args, self.audited(code, *rows))
                self.assertEqual((expected, status, cause), (exit_code, result['status'], result['failure_cause']))
        after = json.loads((self.args.out.parent / 'idle-foreign-input' / 'after.json').read_text(encoding='utf-8'))
        self.assertEqual(('fail', 'foreign_input'), (after['checks']['input']['status'], after['checks']['input']['raw']['cause']))
        self.assertEqual(['input'], json.loads((self.args.out.parent / 'idle-foreign-input' / 'RESULT.json').read_text(encoding='utf-8'))['failed_checks'])

    def test_idle_state_rows_are_classified_by_their_cause(self):
        # gx_perf win32-idle audits a broken --state arrangement as a failed idle_state_window guard row.
        sent = {'event': 'guard', 'check': 'ensure_foreground', 'status': 'pass'}
        lost = {'event': 'guard', 'check': 'idle_state_window', 'status': 'fail', 'cause': 'foreground_lost', 'state': 'visible',
                'other_pid': 7, 'other_class': 'Chrome_WidgetWin_1', 'other_image': 'chrome.exe',
                'reason': 'visible measured process lost focus; the foreground window is 0x77 (Chrome_WidgetWin_1, pid 7)'}
        hung = dict(lost, cause='instance_hung', reason='ghostty pid 42 hangs or crashed (IsHungAppWindow reports its '
                                                        'GhosttyWindow 0x10): visible measured process lost focus')
        helper_gone = dict(lost, cause='instance_gone', state='unfocused', helper_pid=50, helper_alive=False,
                           reason='the focus helper ghostty pid 50 ended during the idle window: measured process regained focus')
        cases = [  # (label, flags, rows, exit, status, failure cause)
            # A one-tab win32-idle sends no input; another window took the foreground.
            ('state-lost', (), (lost,), 3, 'INVALID', 'foreground_lost'),
            # A multi-tab win32-idle: its setup input passed the guards first.
            ('state-lost-injected', ('--injected-input',), (sent, lost), 3, 'INVALID', 'foreground_lost'),
            ('state-hung', (), (hung,), 6, 'PRODUCT_FAIL', 'instance_hung'),
            ('state-helper-gone', ('--injected-input',), (sent, helper_gone), 6, 'PRODUCT_FAIL', 'instance_gone'),
        ]
        for label, flags, rows, expected, status, cause in cases:
            args = self.batch_args(*flags)
            args.out = self.args.out.parent / label
            with self.subTest(label):
                exit_code, result = self.run_batch(args, self.audited(1, *rows))
                self.assertEqual((expected, status, cause), (exit_code, result['status'], result['failure_cause']))
        raw = json.loads((self.args.out.parent / 'state-lost' / 'after.json').read_text(encoding='utf-8'))['checks']['input']
        self.assertEqual(('fail', 'foreground_lost'), (raw['status'], raw['raw']['cause']))
        self.assertIn('input check idle_state_window failed', raw['raw']['reason'])

    def test_self_activation_rows_are_product_failures(self):
        # root 13:15: instance_self_activated (win32-idle, no input since the state entry) is a product
        # failure, PRODUCT_FAIL with or without injected input: never INVALID, never ERROR.
        sent = {'event': 'guard', 'check': 'ensure_foreground', 'status': 'pass'}
        unfocused = {'event': 'guard', 'check': 'idle_state_window', 'status': 'fail', 'cause': 'instance_self_activated',
                     'state': 'unfocused', 'other_pid': 42, 'other_class': 'GhosttyWindow', 'other_image': 'ghostty.exe',
                     'helper_pid': 50, 'helper_alive': True, 'entry_tick': 1, 'last_input_tick': 1,
                     'reason': 'ghostty pid 42 took the foreground back from its live focus helper without input since '
                               'the state entry'}
        minimized = {'event': 'guard', 'check': 'idle_state_window', 'status': 'fail', 'cause': 'instance_self_activated',
                     'state': 'minimized', 'restored': ['0x20'], 'other_pid': 7, 'other_class': 'Shell_TrayWnd',
                     'other_image': 'explorer.exe', 'entry_tick': 1, 'last_input_tick': 1,
                     'reason': 'ghostty pid 42 restored a minimized window without input since the state entry'}
        for label, flags, rows in (('self-unfocused', (), (unfocused,)),
                                   ('self-minimized-injected', ('--injected-input',), (sent, minimized))):
            args = self.batch_args(*flags)
            args.out = self.args.out.parent / label
            with self.subTest(label):
                exit_code, result = self.run_batch(args, self.audited(1, *rows))
                self.assertEqual((6, 'PRODUCT_FAIL', 'instance_self_activated', 'VALID'),
                                 (exit_code, result['status'], result['failure_cause'], result['quiet_status']))
                self.assertIn('instance_self_activated: Ghostty pid 42 activated or restored itself without input mid-batch',
                              ' '.join(result['errors']))
                self.assertIn('never rerun to replace it', result['guidance'])
        self.assertIn('instance_self_activated', gx_perf.PRODUCT_CAUSES)
        self.assertNotIn('instance_self_activated', gx_perf.ENVIRONMENT_CAUSES)

    WSL_BATCH = ('python', 'scripts/gx_wsl.py', 'smoke')

    def test_observe_just_uses_checked_python_argv_without_shell(self):
        # These are inert argv fixtures. Never execute the shell-control payloads.
        for index, (recipe, tail) in enumerate([
                ('wsl', ['smoke', '--out', 'M', '&', 'python', 'scripts/gx_wsl.py', 'run']),
                ('perf', ['gtk', '--out', 'M', '&&', 'python', 'scripts/gx_win_gui.py', 'run']),
                ('wsl', ['--clone', '~/src/frozen', 'scenario', '--out', 'M;echo x', '|', 'cmd']),
                ('perf', ['gtk', '--env', 'VALUE=$(echo x)', '--out', 'M with spaces'])]):
            args = self.batch_args('--input-observe-only', command=['just', recipe, *tail])
            args.out = self.args.out.parent / f'normalized-{index}'
            expected = [sys.executable, str(Path.cwd() / 'scripts' / f'gx_{recipe}.py'), *tail]
            runner = mock.Mock(return_value=SimpleNamespace(returncode=0))
            original_check = gx_perf.desktop_command
            checked = []
            def check(command):
                self.assertFalse(args.out.exists())
                checked.append(list(command))
                return original_check(command)
            with self.subTest(recipe=recipe, tail=tail), \
                    mock.patch.object(gx_perf, 'desktop_command', side_effect=check), \
                    mock.patch.object(gx_perf.subprocess, 'run', runner):
                code, result = self.run_batch(args, None)
                self.assertEqual(0, code)
                self.assertEqual([expected], checked)
                self.assertEqual(expected, runner.call_args.args[0])
                self.assertIs(False, runner.call_args.kwargs['shell'])
                self.assertEqual(expected, result['command'])
                self.assertEqual(['just', recipe, *tail], result['requested_command'])

    def test_observe_normalization_keeps_measurement_cwd_and_frozen_scripts(self):
        frozen = self.args.out.parent / 'frozen measurement'
        (frozen / 'scripts').mkdir(parents=True)
        (frozen / 'scripts/gx_perf.py').write_text('# frozen measurement collector\n', encoding='utf-8')
        original_cwd = Path.cwd()
        try:
            os.chdir(frozen)
            for index, requested in enumerate([['just', 'perf', 'gtk'],
                                                ['python', 'scripts/gx_perf.py', 'gtk'],
                                                ['just', 'perf', 'gtk', '--case', 'p2'],
                                                ['just', 'perf', 'gtk', '--case=p4'],
                                                ['python', 'scripts/gx_perf.py', 'gtk', '--case', 'p2'],
                                                ['python', 'scripts/gx_perf.py', 'gtk', '--case=p4']]):
                args = self.batch_args('--input-observe-only', command=requested)
                args.out = self.args.out.parent / f'frozen-{index}'
                seen = []
                def runner(command, **kwargs):
                    seen.append((list(command), Path.cwd()))
                    return SimpleNamespace(returncode=0)
                code, result = self.run_batch(args, runner)
                expected = [sys.executable, str(frozen / 'scripts/gx_perf.py'), *requested[2:]] if requested[0] == 'just' else requested
                self.assertEqual((0, [(expected, frozen)]), (code, seen))
                self.assertEqual(expected, result['command'])
                self.assertEqual(str(frozen), result['command_cwd'])
        finally:
            os.chdir(original_cwd)

    def test_observe_only_rejects_wrappers_and_unknown_commands(self):
        for index, command in enumerate([('pwsh', '-Command', 'python scripts/gx_perf.py gtk'),
                        ('cmd', '/c', 'just wsl smoke'), ('python', '-m', 'gx_perf', 'gtk'),
                        ('python', 'wrapper.py', 'scripts/gx_perf.py', 'gtk'),
                        ('python', 'scripts/gx_wsl.py', 'run'), ('just', 'wsl', 'run'),
                        ('python', 'scripts/gx_perf.py', 'remote', 'LOGS')]):
            args = self.batch_args('--input-observe-only', command=command)
            args.out = self.args.out.parent / f'wrapper-{index}'
            with self.subTest(command=command), self.assertRaises(gx_perf.PerfError):
                gx_perf.run_quiet_batch(args, self.probe, self.command(0))

    def test_input_observe_only_batch_records_foreign_input_and_stays_valid(self):
        # r6 13:20 item (4): a batch that runs only in WSL/Xvfb records user input, never gates on it.
        args = self.batch_args('--input-observe-only', command=self.WSL_BATCH)
        # The user is at the computer: 5 s idle at the start, input 99 s into the 100 s batch.
        self.probe.input_ticks.side_effect = [ticks(5), ticks(1, 50_100_000)]
        exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((0, 'VALID', 'VALID', [], True, True),
                         (exit_code, result['status'], result['quiet_status'], result['failed_checks'], result['plan_compliant'],
                          result['thresholds_plan_compliant']))
        self.assertEqual(('r6-13:20 user ruling', {'strict_blacklist': False, 'input_observe_only': True}, True),
                         (result['criteria'], result['criteria_options'], result['input_observe_only']))
        before = json.loads((args.out / 'before.json').read_text(encoding='utf-8'))['checks']['input']
        after = json.loads((args.out / 'after.json').read_text(encoding='utf-8'))['checks']['input']
        self.assertEqual(('observed', 'fail', 5.0), (before['status'], before['observed'], before['raw']['idle_seconds']))
        self.assertEqual(('observed', 'fail', 1.0, 100.0, 'foreign_input'),
                         (after['status'], after['observed'], after['raw']['idle_seconds'], after['raw']['batch_seconds'],
                          after['raw']['cause']))
        self.assertTrue(after['reason'].startswith('observe only (--input-observe-only, a WSL/Xvfb batch): idle 1.000s'))
        self.assertIn('criteria: r6-13:20 user ruling strict_blacklist=false input_observe_only=true',
                      (args.out / 'SUMMARY.txt').read_text(encoding='utf-8'))
        # The same batch without the switch is INVALID: the default stays the desktop rule.
        args = self.batch_args(command=self.WSL_BATCH)
        args.out = self.args.out.parent / 'gated'
        self.probe.input_ticks.side_effect = [ticks(600), ticks(1, 50_100_000)]
        exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((3, 'INVALID', 'foreign_input'), (exit_code, result['status'], result['failure_cause']))
        # This project's own load still gates an observe-only batch: a validation VM started meanwhile.
        args = self.batch_args('--input-observe-only', command=self.WSL_BATCH)
        args.out = self.args.out.parent / 'vm'
        self.probe.input_ticks.side_effect = [ticks(5), ticks(1, 50_100_000)]
        self.probe.vm.side_effect = [{'win11': {'exists': True, 'owned': True, 'running': False}},
                                     {'win11': {'exists': True, 'owned': True, 'running': True}}]
        exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((3, 'INVALID', 'quiet_criteria', ['vm']),
                         (exit_code, result['status'], result['failure_cause'], result['failed_checks']))

    def test_input_observe_only_excludes_injected_input_and_the_windows_desktop(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(2, gx_perf.main(['quiet-batch', '--out', str(self.args.out.parent / 'both'), '--injected-input',
                                              '--input-observe-only', '--', 'cmd']))
        self.assertIn('not allowed with argument', stderr.getvalue())
        self.assertFalse((self.args.out.parent / 'both').exists())
        args = self.batch_args('--input-observe-only', command=self.WSL_BATCH)
        args.injected_input = True  # built without the parser
        with self.assertRaisesRegex(gx_perf.PerfError, 'mutually exclusive'):
            gx_perf.run_quiet_batch(args, self.probe, self.command(0))
        self.assertFalse(args.out.exists())
        for command in (('python', 'scripts/gx_perf.py', 'win32-idle', '--exe', 'g.exe', '--out', 'M'),
                        ('python', 'E:/r/scripts/gx_perf.py', 'win32', '--exe', 'g.exe', '--out', 'M'),
                        ('just', 'perf', 'win32-ui', '--case', 'p4'), ('python', 'scripts/gx_win_gui.py', 'run', 'W02'),
                        ('just', 'win-gui', 'run', 'W13'), ('python', 'test\\windows\\gx_remote_fixture.py', '--exe', 'g.exe'),
                        ('E:/r6/zig-out/bin/ghostty.exe', '--config-default-files=false')):
            with self.subTest(command=command):
                self.assertTrue(gx_perf.desktop_command(command))
                args = self.batch_args('--input-observe-only', command=command)
                with self.assertRaisesRegex(gx_perf.PerfError, 'drives the Windows desktop'):
                    gx_perf.run_quiet_batch(args, self.probe, self.command(0))
        for command in (self.WSL_BATCH, ('python', 'scripts/gx_perf.py', 'gtk', '--clone=~/src/gx_ghostty', '--out', 'M'),
                        ('just', 'perf', 'gtk'), ('just', 'wsl', '--clone', '~/src/gx', 'scenario')):
            self.assertFalse(gx_perf.desktop_command(gx_perf.normalize_observe_command(command)))
        # Any gx_win_gui guard row shows the batch touched the desktop after all: an ERROR, never VALID.
        args = self.batch_args('--input-observe-only', command=self.WSL_BATCH)
        args.out = self.args.out.parent / 'guarded'
        self.probe.input_ticks.side_effect = [ticks(5), ticks(1, 50_100_000)]
        exit_code, result = self.run_batch(args, self.command(0, guard='pass'))
        self.assertEqual((2, 'ERROR', 'mode_mismatch'), (exit_code, result['status'], result['failure_cause']))
        self.assertIn('--input-observe-only is only for batches that never touch the Windows desktop', ' '.join(result['errors']))

    def test_noncompliant_thresholds_mode_mismatch_and_end_check_errors(self):
        args = self.batch_args('--idle-seconds', '5')
        self.probe.input_ticks.return_value = ticks(30)
        exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((5, 'NONCOMPLIANT', 'VALID', False, False),
                         (exit_code, result['status'], result['quiet_status'], result['plan_compliant'], result['thresholds_plan_compliant']))
        self.assertIn('plan_compliant=false', (args.out / 'SUMMARY.txt').read_text(encoding='utf-8'))
        self.probe.input_ticks.return_value = ticks(600)
        args = self.batch_args()
        args.out = self.args.out.parent / 'mismatch'
        exit_code, result = self.run_batch(args, self.command(0, guard='pass'))
        self.assertEqual((2, 'ERROR'), (exit_code, result['status']))
        self.assertIn('--injected-input was not given', ' '.join(result['errors']))
        args = self.batch_args()
        args.out = self.args.out.parent / 'end-error'
        self.probe.wsl.side_effect = [{'running': False, 'processes': []}, OSError('wsl.exe vanished')]
        exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((2, 'ERROR', 'ERROR', 'COMPLETE'), (exit_code, result['status'], result['quiet_status'], result['measurement']))

class CounterTests(unittest.TestCase):
    def test_c7_cpu_endpoint_keeps_getprocesstimes_identity_without_nt_or_memory(self):
        import ctypes
        class FileTime(ctypes.Structure):
            _fields_ = [('low', ctypes.c_uint32), ('high', ctypes.c_uint32)]
        counters = gx_perf.NativeCounters.__new__(gx_perf.NativeCounters)
        counters.w = mock.Mock(FILETIME=FileTime)
        counters.w._open.return_value = 99
        counters.memory = mock.Mock(side_effect=AssertionError('memory probe in C7 endpoint'))
        counters.threads = mock.Mock(side_effect=AssertionError('NT probe in C7 endpoint'))
        instance = mock.Mock(pid=42, creation=123)
        def read(_handle, birth, _exit, kernel, user):
            birth._obj.low, kernel._obj.low, user._obj.low = 123, 700, 900
            return 1
        counters.w.GetProcessTimes.side_effect = read
        with mock.patch.object(gx_perf.time, 'perf_counter_ns', side_effect=[100, 101]):
            row = counters.cpu_sample(instance)
        self.assertEqual((700, 900, 100, 101),
                         (row['kernel_100ns'], row['user_100ns'], row['begin_ns'], row['end_ns']))
        counters.w.CloseHandle.assert_called_once_with(99)
        counters.memory.assert_not_called()
        counters.threads.assert_not_called()
        instance.creation = 124
        with self.assertRaisesRegex(gx_perf.PerfError, 'birth changed'):
            counters.cpu_sample(instance)
        self.assertEqual(2, counters.w.CloseHandle.call_count)

    def test_nt_snapshot_decoder_rejects_truncation_and_foreign_threads(self):
        process, thread = gx_perf.NativeProcess(), gx_perf.NativeThread()
        process.pid, process.birth, process.threads = 42, 123, 1
        thread.pid, thread.tid, thread.birth, thread.switches = 42, 43, 124, 10
        raw = bytes(process) + bytes(thread)
        self.assertEqual({'birth': 123, 'threads': [{'tid': 43, 'birth': 124, 'switches': 10}]}, gx_perf.decode_threads(raw, 42))
        for damaged in (raw[:-1], bytes(process), raw[:20]):
            with self.assertRaises(gx_perf.PerfError):
                gx_perf.decode_threads(damaged, 42)
        thread.pid = 99
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.decode_threads(bytes(process) + bytes(thread), 42)

    def test_cpu_uses_process_times_and_switches_match_thread_birth(self):
        before = dict(pid=1, birth=2, user_100ns=10, kernel_100ns=20, begin_ns=0, end_ns=1,
                      threads=[dict(tid=3, birth=4, switches=0xfffffffe)])
        after = dict(before, user_100ns=10010, kernel_100ns=20020, begin_ns=60000000001,
                     threads=[dict(tid=3, birth=4, switches=2)])
        result = gx_perf.idle_delta(before, after)
        self.assertEqual((3, 'ms'), result['process.cpu'])
        self.assertEqual((4, ''), result['threads.context_switches'])
        self.assertEqual((60000, 'ms'), result['idle.wall'])
        after['threads'][0]['birth'] = 5
        delta = gx_perf.idle_delta(before, after)
        self.assertEqual((3, 'ms'), delta['process.cpu'])
        self.assertNotIn('threads.context_switches', delta)
        after['thread_error']='query unavailable'
        self.assertEqual('unavailable',gx_perf.context_switch_diagnostic(before,after)['status'])
        self.assertEqual((3,'ms'),gx_perf.idle_delta(before,after)['process.cpu'])

    def test_paint_frames_do_not_mix_threads_or_count_trailing_layouts(self):
        text = ('00:00:00.100 [1] info(gx_perf): metric d2d.layout_create 2\n'
                '00:00:00.100 [2] info(gx_perf): metric d2d.layout_create 99\n'
                '00:00:00.101 [1] info(gx_perf): keybinds.paint 500us\n'
                '00:00:00.102 [1] info(gx_perf): keybinds.paint 1000us\n'
                '00:00:00.103 [1] info(gx_perf): metric d2d.layout_create 8\n')
        self.assertEqual([{'thread': '1', 'layouts': 2, 'paint_ms': .5},
                          {'thread': '1', 'layouts': 0, 'paint_ms': 1}], gx_perf.keybind_frames(text))

    @unittest.skipUnless(sys.platform == 'win32', 'Windows ABI only')
    def test_native_structure_sizes(self):
        if ctypes.sizeof(ctypes.c_void_p) == 8:
            self.assertEqual(256, ctypes.sizeof(gx_perf.NativeProcess))
            self.assertEqual(80, ctypes.sizeof(gx_perf.NativeThread))
            self.assertEqual(80, ctypes.sizeof(gx_perf.ProcessMemory))
        else:
            self.assertEqual(44, ctypes.sizeof(gx_perf.ProcessMemory))


class PopupClassTests(unittest.TestCase):
    def setUp(self):
        self.now = 0.0
        patches = contextlib.ExitStack()
        self.addCleanup(patches.close)
        patches.enter_context(mock.patch.object(gx_perf.time, 'monotonic', side_effect=lambda: self.now))
        self.sleep = patches.enter_context(mock.patch.object(gx_perf.time, 'sleep', side_effect=self.advance))
        self.instance = mock.Mock()

    def advance(self, seconds):
        self.now += seconds

    def popup_sequence(self, *snapshots):
        sequence = iter(snapshots)
        self.instance.popups.side_effect = lambda: next(sequence, snapshots[-1])

    def test_open_accepts_exact_popup_classes(self):
        for cls in ('GhosttyGxPopup', 'GhosttyGxPopupShadow'):
            for name in ('palette', 'menu', 'settings'):
                with self.subTest(cls=cls, name=name):
                    popup = SimpleNamespace(hwnd=2, cls=cls)
                    self.instance.reset_mock()
                    self.popup_sequence([], [], [popup])
                    self.assertIs(popup, gx_perf.open_ui(self.instance, name))
                    self.assertEqual(3, self.instance.popups.call_count)
                    self.instance.press.assert_called_once_with(gx_perf.UI_KEYS[name])

    def test_open_ignores_preexisting_shadow_until_new_popup(self):
        old = SimpleNamespace(hwnd=1, cls='GhosttyGxPopupShadow')
        new = SimpleNamespace(hwnd=2, cls='GhosttyGxPopupShadow')
        self.popup_sequence([old], [old], [old, new])
        self.assertIs(new, gx_perf.open_ui(self.instance, 'palette'))
        self.assertEqual(3, self.instance.popups.call_count)

    def test_open_times_out_with_only_preexisting_shadow(self):
        old = SimpleNamespace(hwnd=1, cls='GhosttyGxPopupShadow')
        self.instance.popups.return_value = [old]
        with self.assertRaisesRegex(gx_perf.PerfError, 'timeout waiting for palette'):
            gx_perf.open_ui(self.instance, 'palette')

    def test_close_waits_until_popup_disappears(self):
        for cls in ('GhosttyGxPopup', 'GhosttyGxPopupShadow'):
            with self.subTest(cls=cls):
                popup = SimpleNamespace(hwnd=1, cls=cls)
                self.instance.reset_mock()
                self.sleep.reset_mock()
                self.popup_sequence([popup], [popup], [])
                gx_perf.close_ui(self.instance)
                self.assertEqual(3, self.instance.popups.call_count)
                self.instance.press.assert_called_once_with('escape')
                self.assertEqual([mock.call(.02), mock.call(.02), mock.call(.25)], self.sleep.call_args_list)

    def test_close_times_out_while_shadow_remains_visible(self):
        self.instance.popups.return_value = [SimpleNamespace(hwnd=1, cls='GhosttyGxPopupShadow')]
        with self.assertRaisesRegex(gx_perf.PerfError, 'timeout waiting for popup close'):
            gx_perf.close_ui(self.instance)
        self.assertNotIn(mock.call(.25), self.sleep.call_args_list)

    def test_open_recognizes_reused_hidden_host_when_shown_again(self):
        for cls in ('GhosttyGxPopup', 'GhosttyGxPopupShadow'):
            with self.subTest(cls=cls):
                popup = SimpleNamespace(hwnd=1, cls=cls)
                # Instance.popups owns visibility/cloaking filtering: a hidden
                # host is absent, even though its HWND still exists for reuse.
                self.instance.reset_mock()
                self.popup_sequence([], [popup], [popup], [], [], [], [popup])
                self.assertIs(popup, gx_perf.open_ui(self.instance, 'palette'))
                gx_perf.close_ui(self.instance)
                self.assertIs(popup, gx_perf.open_ui(self.instance, 'palette'))
                self.assertEqual(7, self.instance.popups.call_count)
                self.instance.windows.assert_not_called()

    def test_other_classes_neither_open_nor_block_close(self):
        for cls in ('GhosttyGxPopupExtra', 'GhosttyGxPopupShadowExtra', 'GhosttyGx', 'Other'):
            with self.subTest(cls=cls):
                popup = SimpleNamespace(hwnd=2, cls=cls)
                # The unrelated window appears only after the opening key,
                # so previous cannot hide an overly broad class predicate.
                self.instance.popups.side_effect = lambda: [] if not self.instance.press.called else [popup]
                self.instance.press.reset_mock()
                with self.assertRaisesRegex(gx_perf.PerfError, 'timeout waiting for palette'):
                    gx_perf.open_ui(self.instance, 'palette')
                gx_perf.close_ui(self.instance)


class ExperimentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.exe = self.root / 'ghostty.exe'
        self.exe.write_bytes(b'fake executable')

    def args(self, command='win32-ui', *extra):
        return gx_perf.build_parser().parse_args([command, '--exe', str(self.exe), '--out', str(self.root / 'out'),
                                                 '--runs', '1', *(['--case', 'p4'] if command == 'win32-ui' else []), *extra])

    def test_baseline_count_is_missing_and_legacy_timing_is_renamed(self):
        instance = mock.Mock()
        instance.log = self.root/'old.log'
        text = 'info(gx_perf): scrollbar.paint 200us\n'
        instance.log.write_text(text, encoding='utf-8')
        capture = gx_perf.CaptureRun(instance,self.root,{'baseline': True,'diagnostic':False})
        capture.count(text,'scrollbar.paint')
        self.assertEqual([.2],capture.samples.values['scrollbar.paint_time'])
        self.assertNotIn('scrollbar.paint',capture.samples.values)
        self.assertEqual(0,capture.report['missing_metrics']['scrollbar.paint']['n'])
        history=gx_perf.historical_names(gx_perf.parse_text(text))
        self.assertEqual([.2],history.values['scrollbar.paint_time'])
        self.assertNotIn('scrollbar.paint',history.units)
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.arm_samples('info(gx_perf): x 1us\ninfo(gx_perf): metric x 1\n',True)

    def test_zero_count_requires_hash_bound_support_in_new_arm(self):
        instance = mock.Mock()
        instance.log = self.root/'new.log'
        instance.log.write_text('', encoding='utf-8')
        capture = gx_perf.CaptureRun(instance,self.root,{'baseline':False,'diagnostic':False})
        with self.assertRaisesRegex(gx_perf.PerfError,'unproved'):
            capture.count('', 'scrollbar.paint')
        manifest = self.root/'capabilities.json'
        manifest.write_text(json.dumps({'exe_sha256':gx_perf.hashlib.sha256(self.exe.read_bytes()).hexdigest(),
                                        'metrics':{'scrollbar.paint':''}}), encoding='utf-8')
        capabilities=gx_perf.metric_capabilities(['new:'+str(manifest)],['new'],[self.exe])
        capture.report['capabilities']=capabilities['new']
        capture.count('', 'scrollbar.paint')
        self.assertEqual([0],capture.samples.values['scrollbar.paint'])
        self.exe.write_bytes(b'changed')
        with self.assertRaisesRegex(gx_perf.PerfError,'executable'):
            gx_perf.metric_capabilities(['new:'+str(manifest)],['new'],[self.exe])

    def test_p4_old_without_metrics_completes_but_new_uses_ready_not_total(self):
        instance = mock.Mock()
        instance.log=self.root/'blank.log'
        instance.log.write_text('', encoding='utf-8')
        capture=gx_perf.CaptureRun(instance,self.root,{'baseline':True,'diagnostic':False})
        with mock.patch.object(gx_perf,'open_ui'),mock.patch.object(gx_perf,'close_ui'),mock.patch.object(capture,'drain'),mock.patch.object(gx_perf.time,'sleep'):
            gx_perf.measure_ui(mock.Mock(),instance,capture,self.args())
        self.assertFalse(capture.samples)
        self.assertEqual('not_instrumented',capture.report['missing_metrics']['menu.open.ready']['status'])
        capture.report['baseline']=False
        for ui in ('palette','menu','settings'):
            capture.add(ui+'.open.ready',6,'ms')
            capture.add(ui+'.open.total',200,'ms')
            capture.add(ui+'.profiles.path_scan',0)
        self.assertEqual('PASS',gx_perf.absolute_gate(self.args(),capture)['status'])
        capture.samples.values['menu.open.ready']=[7]
        self.assertEqual('FAIL',gx_perf.absolute_gate(self.args(),capture)['status'])

    def test_old_and_new_keep_abba_missing_n_zero(self):
        args=self.args('win32-ui','--exe',str(self.exe),'--runs','2')
        gui=self.fake_gui()
        def measure(_,instance,capture,args):
            if capture.report['baseline']:
                for ui in ('palette','menu','settings'):
                    capture.missing(ui+'.open.ready','ms')
            else:
                for ui in ('palette','menu','settings'):
                    capture.add(ui+'.open.ready',2,'ms')
                    capture.add(ui+'.profiles.path_scan',0)
        with mock.patch.object(gx_perf,'measure_ui',side_effect=measure),mock.patch.object(gx_perf.time,'sleep'),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0,gx_perf.run_experiment(args,gui))
        result=json.loads((args.out/'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual(['old','new','new','old'],[row['label'] for row in result['runs']])
        self.assertEqual(0,result['metrics']['old']['menu.open.ready']['n'])
        self.assertEqual(2,result['metrics']['new']['menu.open.ready']['n'])
        self.assertFalse(result['comparison']['menu.open.ready']['comparable'])
        self.assertEqual(0,result['comparison']['menu.open.ready']['old']['n'])

    def test_complete_gate_fail_exits_4_but_incomplete_evidence_stays_1(self):
        gui, calls = self.fake_gui(), []
        def measure(_, instance, capture, args):
            calls.append(capture.report['run'])
            if len(calls) == 3:
                raise gx_perf.PerfError('popup vanished')
            for ui in ('palette', 'menu', 'settings'):
                capture.add(ui + '.open.ready', 7 if ui == 'menu' else 2, 'ms')
                capture.add(ui + '.profiles.path_scan', 0)
        args = self.args()
        with mock.patch.object(gx_perf, 'measure_ui', side_effect=measure), mock.patch.object(gx_perf.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(4, gx_perf.run_experiment(args, gui))
        result = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual((True, True, 4), (result['valid'], result['gate_failed'], result['exit']))
        self.assertEqual('FAIL', result['runs'][0]['absolute_gate']['status'])
        self.assertIn('complete; absolute gate FAIL observed; exit 4', (args.out / 'SUMMARY.txt').read_text(encoding='utf-8'))
        args = self.args('win32-ui', '--runs', '2')
        args.out = self.root / 'incomplete'
        with mock.patch.object(gx_perf, 'measure_ui', side_effect=measure), mock.patch.object(gx_perf.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1, gx_perf.run_experiment(args, gui))
        result = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual((False, True, 1), (result['valid'], result['gate_failed'], result['exit']))

    def test_comparison_keeps_each_arms_own_reason_for_absent_metrics(self):
        args = self.args('win32-idle', '--exe', str(self.exe))
        gui = self.fake_gui()
        def measure(_, instance, capture, args, counters):
            capture.add('proc.snapshot', 2)
            if capture.report['baseline']:
                capture.add('threads.context_switches', 40)
                capture.add('process.cpu', 3, 'ms')
            else:
                capture.report['missing_metrics']['threads.context_switches'] = {'status': 'partial', 'n': 0, 'unit': ''}
        with mock.patch.object(gx_perf, 'measure_idle', side_effect=measure), mock.patch.object(gx_perf.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.run_experiment(args, gui, counters_factory=mock.Mock()))
        result = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual('partial', result['comparison']['threads.context_switches']['new']['status'])
        self.assertEqual('no_samples', result['comparison']['process.cpu']['new']['status'])
        self.assertIn('threads.context_switches unit=count n=0 partial', (args.out / 'SUMMARY.txt').read_text(encoding='utf-8'))

    def test_driver_records_the_failure_cause_of_a_run(self):
        import gx_win_gui as real
        args, gui = self.args('win32-ui', '--runs', '2'), self.fake_gui()
        with mock.patch.object(gx_perf, 'measure_ui', side_effect=real.InputBlocked('Ghostty 实例 1 已结束', cause='instance_gone')), \
                mock.patch.object(gx_perf.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1, gx_perf.run_experiment(args, gui))
        self.assertEqual('instance_gone', json.loads((args.out / 'build/run-01/run.json').read_text(encoding='utf-8'))['failure_cause'])
        result = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual((['instance_gone'], 'instance_gone'), (result['failure_causes'], result['runs'][0]['failure_cause']))
        self.assertIn('failure causes instance_gone', (args.out / 'SUMMARY.txt').read_text(encoding='utf-8'))

    def test_unexpected_driver_exception_retains_failed_evidence(self):
        args,gui=self.args(),self.fake_gui()
        with mock.patch.object(gx_perf,'measure_ui',side_effect=StopIteration('window vanished')),mock.patch.object(gx_perf.time,'sleep'),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1,gx_perf.run_experiment(args,gui))
        self.assertEqual('failed',json.loads((args.out/'build/run-01/run.json').read_text(encoding='utf-8'))['status'])
        self.assertTrue((args.out/'SUMMARY.txt').is_file())

    def test_open_ui_ignores_preexisting_popup(self):
        instance=mock.Mock()
        old=SimpleNamespace(hwnd=1,cls='GhosttyGxPopup')
        new=SimpleNamespace(hwnd=2,cls='GhosttyGxPopup')
        instance.popups.side_effect=[[old],[old],[old,new]]
        with mock.patch.object(gx_perf.time,'sleep'):
            self.assertIs(new,gx_perf.open_ui(instance,'menu'))

    def test_drain_waits_for_late_count_then_quiet_interval(self):
        instance=mock.Mock()
        instance.log=self.root/'drain.log'
        instance.log.write_text('', encoding='utf-8')
        capture=gx_perf.CaptureRun(instance,self.root,{})
        now=[0.0]
        def sleep(seconds):
            now[0]+=seconds
            if now[0] >= .4 and instance.log.stat().st_size == 0:
                instance.log.write_text('info(gx_perf): metric scrollbar.paint 1\n', encoding='utf-8')
        with mock.patch.object(gx_perf.time,'monotonic',side_effect=lambda:now[0]),mock.patch.object(gx_perf.time,'sleep',side_effect=sleep):
            capture.drain(['scrollbar.paint'],minimum=.6,quiet=.5)
        self.assertGreaterEqual(now[0],.9)

    def test_unsettled_metric_window_is_counted_not_a_driver_error(self):
        instance = mock.Mock()
        instance.log = self.root / 'busy.log'
        instance.log.write_text('', encoding='utf-8')
        capture = gx_perf.CaptureRun(instance, self.root, {'baseline': False, 'diagnostic': False})
        now = [0.0]
        def sleep(seconds):
            now[0] += seconds
            with instance.log.open('a', encoding='utf-8') as stream:
                stream.write('info(gx_perf): metric scrollbar.paint 1\n')
        with mock.patch.object(gx_perf.time, 'monotonic', side_effect=lambda: now[0]), \
                mock.patch.object(gx_perf.time, 'sleep', side_effect=sleep):
            self.assertFalse(capture.drain(['scrollbar.paint'], minimum=.6, quiet=.5))
        self.assertTrue(capture.report['measurement_unsettled'])
        self.assertEqual('timeout', capture.report['drains'][-1]['status'])
        capture.count(instance.log.read_text(encoding='utf-8'), 'scrollbar.paint')
        args = self.args()
        args.case = 'p3'
        self.assertEqual('FAIL', gx_perf.absolute_gate(args, capture)['status'])
        gui = self.fake_gui()
        def measure(_, instance, capture, args):
            capture.report['measurement_unsettled'] = True
            capture.report['drains'] = [{'metrics': ['scrollbar.paint'], 'status': 'timeout'}]
            capture.add('scrollbar.paint', 3)
        with mock.patch.object(gx_perf, 'measure_ui', side_effect=measure), mock.patch.object(gx_perf.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(4, gx_perf.run_experiment(args, gui))
        result = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual([{'label': 'build', 'run': 1, 'metrics': [['scrollbar.paint']]}], result['unsettled_runs'])
        self.assertIn('Unsettled metric windows', (args.out / 'SUMMARY.txt').read_text(encoding='utf-8'))

    def test_legacy_win32_guard_failure_is_not_retried(self):
        import gx_win_gui as gui
        out = self.root / 'legacy'
        calls = []
        def measure(*args):
            calls.append(args)
            log = gui.log_path(args[1])
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text('raw failure evidence\n', encoding='utf-8')
            if len(calls) == 1:
                args[-1]['resize_input_tick'] = 123
                return ['metric startup.shown 1 ms']
            raise gui.InputBlocked('foreground changed')
        with mock.patch.object(gx_perf, 'measure_win32_bounded', side_effect=measure), mock.patch.object(gx_perf, 'last_input_ticks', return_value=(123,1000)), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = gx_perf.main(['win32', '--exe', str(self.exe), '--out', str(out), '--runs', '1'])
        self.assertEqual(1, code)
        self.assertEqual(2, len(calls))
        self.assertEqual('raw failure evidence\n', (out / 'build/run-01.log').read_text(encoding='utf-8'))

    def test_startup_failure_keeps_pid_and_arm(self):
        import gx_win_gui as real
        args, gui = self.args(), self.fake_gui()
        instance = gui.launch(self.exe, self.root / 'fake-env')
        instance.wait_window.side_effect = real.InputBlocked('startup crashed', cause='instance_gone')
        gui.launch.side_effect = None
        gui.launch.return_value = instance
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1, gx_perf.run_experiment(args, gui))
        report = json.loads((args.out / 'build/run-01/run.json').read_text(encoding='utf-8'))
        self.assertEqual((1, 'build', 'instance_gone'), (report.get('pid'), report['label'], report['failure_cause']))

    def test_legacy_startup_failure_keeps_pid_and_arm(self):
        import gx_win_gui as real
        instance = mock.Mock(pid=73, creation=123)
        instance.wait_window.side_effect = real.InputBlocked('startup crashed', cause='instance_gone')
        out = self.root / 'legacy-startup'
        # Exercise the real measurement function locally; the process boundary
        # and result propagation have separate real-Job coverage.
        def measure(exe, env_dir, config, resizes, env, report):
            return gx_perf.measure_win32(real, exe, env_dir, config, resizes, env, report)
        with mock.patch.object(real, 'launch', return_value=instance), \
                mock.patch.object(gx_perf, 'measure_win32_bounded', side_effect=measure), \
                mock.patch.object(gx_perf, 'last_input_ticks', return_value=(123,1000)), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(1, gx_perf.main(['win32', '--exe', str(self.exe), '--out', str(out), '--runs', '1']))
        report = json.loads((out / 'build/warmup-failed.json').read_text(encoding='utf-8'))
        self.assertEqual((73, 'build', 'instance_gone'), (report.get('pid'), report['label'], report.get('failure_cause')))
        failures = gx_perf.product_failure_runs(out, [{'instance_pid': 73}])
        self.assertEqual('build', failures[0]['label'])
        self.assertEqual(out, gx_perf.driver_out_dir(['python', 'scripts/gx_perf.py', 'win32', '--out', str(out)]))

    def fake_gui(self):
        import gx_win_gui as real
        gui = mock.Mock(GuiError=real.GuiError, InputBlocked=real.InputBlocked, HARNESS_CONFIG='', env_assignments=real.env_assignments)
        def launch(exe, env_dir, **kwargs):
            env_dir.mkdir(parents=True, exist_ok=True)
            log = env_dir / 'app.log'
            log.write_text('info(gx_perf): metric proc.snapshot 1\n', encoding='utf-8')
            return mock.Mock(pid=1, creation=2, log=log, wait_window=mock.Mock(return_value={'shown_ms': 1}),
                             close=mock.Mock(return_value='closed'))
        gui.launch.side_effect = launch
        return gui

    def test_alternating_batch_preserves_env_raw_and_does_not_double_count(self):
        args = self.args('win32-ui', '--exe', str(self.exe), '--runs', '2', '--label-env', 'new:TEST=1', '--diagnostic')
        gui = self.fake_gui()
        def measure(_, instance, capture, args):
            capture.add('palette.open.total', 2, 'ms')
        with mock.patch.object(gx_perf, 'measure_ui', side_effect=measure), mock.patch.object(gx_perf.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.run_experiment(args, gui))
        batch = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual(['old', 'new', 'new', 'old'], [r['label'] for r in batch['runs']])
        self.assertEqual([None, '1', '1', None], [c.kwargs['env'].get('TEST') for c in gui.launch.call_args_list])
        self.assertEqual([2, 2], gx_perf.collect([args.out / 'old']).values['palette.open.total'])
        self.assertTrue((args.out / 'new/run-02/ghostty.log').is_file())
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.run_experiment(args, gui)

    def test_guard_failure_stops_batch_and_retains_failed_run(self):
        import gx_win_gui as real
        args, gui = self.args('win32-ui', '--runs', '3'), self.fake_gui()
        with mock.patch.object(gx_perf, 'measure_ui', side_effect=real.InputBlocked('foreground changed')), mock.patch.object(gx_perf.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1, gx_perf.run_experiment(args, gui))
        self.assertEqual(1, gui.launch.call_count)
        run = json.loads((args.out / 'build/run-01/run.json').read_text(encoding='utf-8'))
        self.assertEqual('failed', run['status'])
        self.assertIn('foreground changed', run['errors'])
        self.assertTrue((args.out / 'build/run-01/ghostty.log').exists())
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.collect([args.out])

    def test_p4_excludes_warmup_and_reduces_three_hot_opens(self):
        instance = mock.Mock()
        target = self.root
        instance.log = target / 'app.log'
        instance.log.write_text('', encoding='utf-8')
        capture = gx_perf.CaptureRun(instance, target, {})
        counts = {}
        def opened(_, name):
            n = counts.get(name, 0)
            counts[name] = n + 1
            with instance.log.open('a', encoding='utf-8') as log:
                log.write(f'info(gx_perf): {name}.open.ready {[900000, 1000, 3000, 2000][n]}us\n')
                log.write(f'info(gx_perf): {name}.open.total {[900000, 1000, 3000, 2000][n]}us\n')
                log.write('info(gx_perf): metric profiles.path_scan 1\n')
            return mock.Mock()
        with mock.patch.object(gx_perf, 'open_ui', side_effect=opened), mock.patch.object(gx_perf, 'close_ui'), mock.patch.object(gx_perf.time, 'sleep'), mock.patch.object(capture, 'drain'):
            gx_perf.measure_ui(mock.Mock(), instance, capture, self.args())
        for name in ('palette', 'menu', 'settings'):
            self.assertEqual([2], capture.samples.values[name + '.open.ready'])
            self.assertEqual([2], capture.samples.values[name + '.open.total'])
            self.assertEqual([3], capture.samples.values[name + '.profiles.path_scan'])
        self.assertEqual({'palette': 4, 'menu': 4, 'settings': 4}, counts)

    def test_resource_measurement_reports_commit_per_added_thread(self):
        args = self.args('win32-mem')
        counters = mock.Mock()
        counters.sample.side_effect = [dict(private_bytes=100, thread_count=4), dict(private_bytes=500, thread_count=14)]
        instance, gui = mock.Mock(), mock.Mock()
        window=SimpleNamespace(hwnd=1)
        gui.win32.return_value.child_windows.side_effect = [[SimpleNamespace(visible=True,cloaked=False)],
            [SimpleNamespace(visible=i==10,cloaked=False) for i in range(11)]]
        gui.win32.return_value.IsIconic.return_value=False
        capture = gx_perf.CaptureRun(instance, self.root, {})
        with mock.patch.object(gx_perf, 'main_windows',return_value=[window]), mock.patch.object(gx_perf, 'wait_until', return_value=True), mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.measure_resources(gui, instance, capture, args, counters)
        self.assertEqual([40], capture.samples.values['process.commit.per_added_thread'])
        self.assertEqual(10, instance.press.call_count)

    def test_gpu_keeps_last_gauge_and_dedicated_bytes_per_terminal(self):
        counters, instance = mock.Mock(), mock.Mock()
        gui=mock.Mock()
        gui.win32.return_value.IsIconic.return_value=False
        gui.win32.return_value.child_windows.side_effect = [[SimpleNamespace(visible=True,cloaked=False)],
            [SimpleNamespace(visible=i==10,cloaked=False) for i in range(11)]]
        counters.sample.side_effect = [dict(private_bytes=100, thread_count=4), dict(private_bytes=500, thread_count=14)]
        counters.gpu.side_effect = [dict(dedicated_bytes=1024), dict(dedicated_bytes=11264)]
        instance.log_text.return_value = ('info(gx_perf): metric renderer.targets_live 2\ninfo(gx_perf): metric renderer.targets_live 22\n'
                                        'info(gx_perf): metric renderer.target_objects_live 1\ninfo(gx_perf): metric renderer.target_textures_live 1\n')
        capture = gx_perf.CaptureRun(instance, self.root, {})
        with mock.patch.object(gx_perf, 'main_windows',return_value=[SimpleNamespace(hwnd=1)]), mock.patch.object(gx_perf, 'wait_until', return_value=True), mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.measure_resources(gui, instance, capture, self.args('win32-gpu'), counters)
        self.assertEqual([1024], capture.samples.values['gpu.dedicated.per_added_terminal'])
        self.assertEqual([22], capture.samples.values['renderer.targets_live.11'])
        self.assertEqual([22],capture.samples.values['renderer.targets_live.per_visible_terminal.11'])
        self.assertEqual([1],capture.samples.values['renderer.target_textures_live.11'])
        self.assertEqual(1,capture.report['resources'][1]['terminal_population']['visible'])
        self.assertEqual(11,capture.report['resources'][1]['terminal_population']['total'])

    def test_idle_interval_excludes_setup_events_and_records_cpu(self):
        instance, gui, counters = mock.Mock(), mock.Mock(), mock.Mock()
        instance.hang_evidence.return_value = None
        gui.win32.return_value.foreground.return_value = 0x77
        gui.win32.return_value.window_pid.return_value = instance.pid
        instance.log = self.root / 'idle.log'
        instance.log.write_text('info(gx_perf): metric proc.snapshot 99\n', encoding='utf-8')
        before = dict(pid=1, birth=2, user_100ns=0, kernel_100ns=0, begin_ns=0, end_ns=1,
                      threads=[dict(tid=3, birth=4, switches=10)])
        after = dict(before, user_100ns=20000, begin_ns=60000000001,
                     threads=[dict(tid=3, birth=4, switches=20)])
        counters.sample.side_effect = [before, after]
        capture = gx_perf.CaptureRun(instance, self.root, {})
        def sleep(seconds):
            if seconds == 60:
                with instance.log.open('a', encoding='utf-8') as stream:
                    stream.write('info(gx_perf): metric proc.snapshot 2\ninfo(gx_perf): metric renderer.present 4\n')
        with mock.patch.object(gx_perf.time, 'sleep', side_effect=sleep), mock.patch.object(gx_perf, 'last_input_ticks', return_value=(1, 10)):
            gx_perf.idle_interval(gui, instance, capture, self.args('win32-idle'), counters)
        self.assertEqual([2], capture.samples.values['proc.snapshot'])
        self.assertEqual([2], capture.samples.values['process.cpu'])
        self.assertEqual([10], capture.samples.values['threads.context_switches'])

    def test_idle_thread_churn_preserves_p2_but_foreign_input_rejects(self):
        instance, gui, counters = mock.Mock(), mock.Mock(), mock.Mock()
        gui.win32.return_value.foreground.return_value = 0x77
        instance.hang_evidence.return_value = None
        instance.log = self.root/'idle.log'
        instance.log.write_text('', encoding='utf-8')
        gui.win32.return_value.window_pid.return_value = instance.pid
        before = dict(pid=1,birth=2,user_100ns=0,kernel_100ns=0,begin_ns=0,end_ns=1,
                      threads=[dict(tid=3,birth=4,switches=10)])
        after = dict(before,begin_ns=60000000001,threads=[])
        counters.sample.side_effect = [before, after, before, after]
        def sleep(seconds):
            if seconds == 60:
                with instance.log.open('a', encoding='utf-8') as stream:
                    stream.write('info(gx_perf): metric proc.snapshot 2\n')
        capture = gx_perf.CaptureRun(instance, self.root, {'diagnostic':False,'capabilities':{'proc.snapshot':''}})
        with mock.patch.object(gx_perf.time,'sleep',side_effect=sleep), mock.patch.object(gx_perf,'last_input_ticks',return_value=(10,20)):
            gx_perf.idle_interval(gui,instance,capture,self.args('win32-idle'),counters)
        self.assertEqual([2],capture.samples.values['proc.snapshot'])
        self.assertEqual('partial',capture.report['context_switch_diagnostic']['status'])
        self.assertEqual('partial', capture.report['missing_metrics']['threads.context_switches']['status'])
        self.assertEqual('not_instrumented',capture.report['missing_metrics']['renderer.present']['status'])
        with mock.patch.object(gx_perf.time,'sleep',side_effect=sleep), mock.patch.object(gx_perf,'last_input_ticks',side_effect=[(10,20),(11,21)]):
            with self.assertRaisesRegex(gx_perf.PerfError,'input') as raised:
                gx_perf.idle_interval(gui,instance,capture,self.args('win32-idle'),counters)
        self.assertEqual('foreign_input', raised.exception.cause)
        instance.record_input.assert_called_once_with('guard', check='idle_input_window', status='fail', cause='foreign_input',
                                                      reason='external input occurred during the idle measurement window',
                                                      before_tick=10, after_tick=11)

    def idle_end(self, state, foreground_pid, *, helper=None, restored=(), hang=None, ticks=None, entry=None, descendants=False):
        """idle_interval against a fake desktop; (the PerfError it raised or None, the instance)."""
        instance, gui, counters = mock.Mock(pid=42), mock.Mock(), mock.Mock()
        instance.log = self.root / f'idle-{state}-{foreground_pid}.log'
        instance.log.write_text('', encoding='utf-8')
        instance.hang_evidence.return_value = hang
        instance.contains_pid.side_effect = lambda pid: pid == 42 or descendants
        w = gui.win32.return_value
        w.foreground.return_value = 0x77
        w.window_pid.return_value = foreground_pid
        w.class_name.return_value = 'GhosttyWindow' if foreground_pid == 42 else 'Chrome_WidgetWin_1'
        w.IsIconic.side_effect = lambda hwnd: hwnd not in restored
        gui.image_name.return_value = 'ghostty.exe' if foreground_pid == 42 else 'chrome.exe'
        sample = dict(pid=1, birth=2, user_100ns=0, kernel_100ns=0, begin_ns=0, end_ns=1, threads=[])
        counters.sample.side_effect = [sample, dict(sample, begin_ns=60000000001)]
        extra = {} if entry is None else {'entry': entry}
        input_ticks = {'side_effect': ticks} if ticks else {'return_value': (1, 10)}
        windows = [SimpleNamespace(hwnd=0x10), SimpleNamespace(hwnd=0x20)]
        with mock.patch.object(gx_perf.time, 'sleep'), mock.patch.object(gx_perf, 'last_input_ticks', **input_ticks), \
                mock.patch.object(gx_perf, 'main_windows', return_value=windows):
            try:
                gx_perf.idle_interval(gui, instance, gx_perf.CaptureRun(instance, self.root, {}),
                                      self.args('win32-idle', '--state', state), counters, helper=helper, **extra)
            except gx_perf.PerfError as exc:
                return exc, instance
        return None, instance

    def test_hang_wins_over_input(self):
        raised, instance = self.idle_end('visible', 42, hang='hung window', ticks=[(1, 10), (2, 20)])
        self.assertEqual('instance_hung', raised.cause)
        self.assertEqual('instance_hung', instance.record_input.call_args.kwargs['cause'])

    def test_descendant_regaining_focus_is_self_activation(self):
        raised, _ = self.idle_end('unfocused', 84, descendants=True,
                                  helper=mock.Mock(pid=50, **{'alive.return_value': True}))
        self.assertEqual('instance_self_activated', raised.cause)

    def test_visible_descendants_hang_and_input_priority(self):
        for pid in (84, 85):  # child and grandchild are both proven by contains_pid
            for hang, tick, expected in [(None, 1, 'instance_self_activated'),
                                          (None, 2, 'foreign_input'),
                                          ('hung window', 1, 'instance_hung'),
                                          ('hung window', 2, 'instance_hung')]:
                with self.subTest(pid=pid, hang=hang, tick=tick):
                    raised, instance = self.idle_end('visible', pid, descendants=True, hang=hang,
                                                     ticks=[(1, 10), (1, 20), (tick, 21)])
                    self.assertEqual(expected, getattr(raised, 'cause', None))
                    self.assertEqual(expected, instance.record_input.call_args.kwargs['cause'])

    def test_visible_main_process_remains_valid_but_hang_or_input_is_reported(self):
        for hang, tick, expected in [(None, 1, None), (None, 2, 'foreign_input'),
                                      ('hung window', 1, 'instance_hung'), ('hung window', 2, 'instance_hung')]:
            with self.subTest(hang=hang, tick=tick):
                raised, instance = self.idle_end('visible', 42, hang=hang,
                                                 ticks=[(1, 10), (1, 20), (tick, 21)])
                self.assertEqual(expected, getattr(raised, 'cause', None))
                if expected is None:
                    instance.record_input.assert_not_called()

    def test_visible_entry_requires_main_process_in_foreground(self):
        for pid in (0, 7, 42, 84, 85):
            instance, gui = mock.Mock(pid=42), mock.Mock()
            instance.contains_pid.side_effect = lambda value: value in (42, 84, 85)
            gui.win32.return_value.window_pid.return_value = pid
            with self.subTest(pid=pid), mock.patch.object(gx_perf, 'last_input_ticks', return_value=(1, 2)):
                capture = SimpleNamespace(report={})
                if pid == 42:
                    entry = gx_perf.idle_state_entry(gui, instance, capture, SimpleNamespace(state='visible'))
                    self.assertEqual(42, entry['foreground_pid'])
                else:
                    with self.assertRaises(gx_perf.PerfError) as raised:
                        gx_perf.idle_state_entry(gui, instance, capture, SimpleNamespace(state='visible'))
                    self.assertIsNone(raised.exception.cause)
                instance.record_input.assert_not_called()

    def test_state_entry_rejects_failed_arrangement(self):
        instance, gui = mock.Mock(pid=42), mock.Mock()
        gui.win32.return_value.window_pid.return_value = 42
        gui.win32.return_value.IsIconic.return_value = False
        instance.contains_pid.return_value = True
        for state in ('unfocused', 'minimized'):
            with self.subTest(state=state), mock.patch.object(gx_perf, 'last_input_ticks', return_value=(1, 2)), \
                    mock.patch.object(gx_perf, 'main_windows', return_value=[SimpleNamespace(hwnd=10)]), \
                    self.assertRaises(gx_perf.PerfError) as raised:
                gx_perf.idle_state_entry(gui, instance, SimpleNamespace(report={}), SimpleNamespace(state=state))
        instance.record_input.assert_not_called()

    def test_idle_state_breaks_keep_their_environment_and_product_causes(self):
        # Kept from round 7 (48ed500a3), end to end through idle_interval without any input: another
        # process in front of a visible instance is foreground_lost (INVALID), a hung instance is
        # instance_hung and an ended focus helper instance_gone (PRODUCT_FAIL); another process in
        # front of an unfocused instance leaves it unfocused, which is no failure.
        ended = mock.Mock(pid=50, **{'alive.return_value': False})
        hung = 'IsHungAppWindow reports its GhosttyWindow 0x10'
        for state, pid, helper, hang, cause in (('visible', 7, None, None, 'foreground_lost'),
                                                ('visible', 7, None, hung, 'instance_hung'),
                                                ('unfocused', 42, ended, None, 'instance_gone')):
            with self.subTest(state=state, cause=cause):
                raised, instance = self.idle_end(state, pid, helper=helper, hang=hang)
                self.assertEqual(cause, getattr(raised, 'cause', None))
                row = instance.record_input.call_args
                self.assertEqual(('guard', 'idle_state_window', 'fail', cause, state, pid),
                                 (row.args[0], row.kwargs['check'], row.kwargs['status'], row.kwargs['cause'],
                                  row.kwargs['state'], row.kwargs['other_pid']))
        raised, instance = self.idle_end('unfocused', 7, helper=mock.Mock(pid=50, **{'alive.return_value': True}))
        self.assertIsNone(raised)
        instance.record_input.assert_not_called()

    def test_idle_self_activation_without_input_is_a_product_failure(self):
        # root 13:15: without input since the state entry, the measured process taking the foreground
        # back from its live focus helper, or one of its own minimized windows being restored, is
        # instance_self_activated (PRODUCT_FAIL), not foreground_lost: a real defect that recurs on
        # every attempt must not be rerun as INVALID until the batch is BLOCKED.
        raised, instance = self.idle_end('unfocused', 42, helper=mock.Mock(pid=50, **{'alive.return_value': True}))
        self.assertEqual('instance_self_activated', getattr(raised, 'cause', None))
        row = instance.record_input.call_args.kwargs
        self.assertEqual(('idle_state_window', 50, True, 42, 'GhosttyWindow', 'ghostty.exe', 1, 1),
                         (row['check'], row['helper_pid'], row['helper_alive'], row['other_pid'], row['other_class'],
                          row['other_image'], row['entry_tick'], row['last_input_tick']))
        self.assertEqual('ghostty pid 42 took the foreground back from its live focus helper without input since the '
                         'state entry: measured process regained focus; the foreground window is 0x77 (GhosttyWindow, '
                         'pid 42)', row['reason'])
        # Its own window was restored; it need not hold the foreground (a restore without activation counts).
        raised, instance = self.idle_end('minimized', 7, restored=(0x20,))
        self.assertEqual('instance_self_activated', getattr(raised, 'cause', None))
        row = instance.record_input.call_args.kwargs
        self.assertEqual((['0x20'], 7, 'chrome.exe'), (row['restored'], row['other_pid'], row['other_image']))
        self.assertTrue(row['reason'].startswith('ghostty pid 42 restored a minimized window without input since the '
                                                 'state entry: a measured window was restored'))

    def test_input_after_the_state_entry_is_foreign_input_not_self_activation(self):
        live = mock.Mock(pid=50, **{'alive.return_value': True})
        # Input between the state entry (tick 1) and the counter window (tick 5): the input window starts
        # at the entry now, so this is foreign_input (INVALID), never instance_self_activated.
        raised, instance = self.idle_end('unfocused', 42, helper=live, ticks=[(5, 10), (5, 70)], entry={'tick': 1})
        self.assertEqual('foreign_input', getattr(raised, 'cause', None))
        instance.record_input.assert_called_once_with('guard', check='idle_input_window', status='fail',
                                                      cause='foreign_input',
                                                      reason='external input occurred during the idle measurement window',
                                                      before_tick=1, after_tick=5, since='state_entry')
        # Input after the input window but before the state facts were read: still foreign_input.
        raised, instance = self.idle_end('minimized', 7, restored=(0x20,), ticks=[(1, 10), (1, 70), (2, 71)], entry={'tick': 1})
        self.assertEqual('foreign_input', getattr(raised, 'cause', None))
        row = instance.record_input.call_args.kwargs
        self.assertEqual(('idle_state_window', 1, 2), (row['check'], row['entry_tick'], row['last_input_tick']))
        self.assertTrue(row['reason'].startswith('input arrived after the state entry (last input tick 1 -> 2): '))

    def test_idle_state_check_records_one_row_with_the_entry_and_last_input_ticks(self):
        import gx_win_gui as real

        def check(state, pid, *, helper=None, hang=None):
            instance, gui = mock.Mock(pid=42), mock.Mock()
            instance.contains_pid.side_effect = lambda value: value == 42
            instance.hang_evidence.return_value = hang
            w = gui.win32.return_value
            w.foreground.return_value = 0x77
            w.window_pid.return_value = pid
            w.class_name.return_value = 'GhosttyWindow' if pid == 42 else 'Chrome_WidgetWin_1'
            gui.image_name.return_value = 'ghostty.exe' if pid == 42 else 'chrome.exe'
            with mock.patch.object(gx_perf, 'last_input_ticks', return_value=(3, 10)), \
                    self.assertRaises(gx_perf.PerfError) as raised:
                gx_perf.idle_state_check(gui, instance, SimpleNamespace(state=state), helper, entry_tick=3)
            self.assertEqual(1, instance.record_input.call_count)
            return raised.exception.cause, instance

        cause, instance = check('visible', 7)
        instance.record_input.assert_called_once_with(
            'guard', check='idle_state_window', status='fail', cause='foreground_lost',
            reason='visible measured process lost focus; the foreground window is 0x77 (Chrome_WidgetWin_1, pid 7)',
            state='visible', other_pid=7, other_class='Chrome_WidgetWin_1', other_image='chrome.exe',
            entry_tick=3, last_input_tick=3)
        instance.hang_evidence.assert_called_once_with('Chrome_WidgetWin_1', 'chrome.exe')
        # Hang evidence comes first.
        self.assertEqual('instance_hung', check('unfocused', 42, helper=mock.Mock(pid=50, **{'alive.return_value': True}),
                                                hang='IsHungAppWindow reports its GhosttyWindow 0x10')[0])
        # Without a known live focus helper nothing shows that the measured process took the foreground itself.
        self.assertEqual('foreground_lost', check('unfocused', 42)[0])
        # The measured process ended: ensure_owned audits and raises instance_gone before a window is read.
        instance, gui = mock.Mock(pid=42), mock.Mock()
        instance.ensure_owned.side_effect = real.InputBlocked('ghostty pid 42 has ended', cause='instance_gone')
        with self.assertRaises(real.InputBlocked) as raised:
            gx_perf.idle_state_check(gui, instance, SimpleNamespace(state='visible'), entry_tick=3)
        self.assertEqual('instance_gone', raised.exception.cause)
        gui.win32.return_value.foreground.assert_not_called()
        instance.record_input.assert_not_called()

    def test_minimized_state_minimizes_the_foreground_window_last_and_records_the_entry(self):
        # root 13:15 item 3: SW_MINIMIZE of the active window activates the next shown top-level window,
        # so minimizing in z-order would make this tool activate the other measured windows itself.
        instance, gui, counters = mock.Mock(pid=42), mock.Mock(), mock.Mock()
        windows = [SimpleNamespace(hwnd=0x10), SimpleNamespace(hwnd=0x20), SimpleNamespace(hwnd=0x30)]  # 0x10 in front
        w = gui.win32.return_value
        w.foreground.side_effect = [0x10, 0x99]  # before minimizing, then at the state entry
        w.window_pid.side_effect = lambda hwnd: 42 if hwnd == 0x10 else 7
        w.class_name.side_effect = lambda hwnd: 'GhosttyWindow' if hwnd == 0x10 else 'Shell_TrayWnd'
        gui.image_name.side_effect = lambda pid: 'ghostty.exe' if pid == 42 else 'explorer.exe'
        order = []
        w.ShowWindow.side_effect = lambda hwnd, command: order.append((hwnd, command))
        capture = gx_perf.CaptureRun(instance, self.root, {})
        with mock.patch.object(gx_perf, 'populate'), mock.patch.object(gx_perf, 'main_windows', return_value=windows), \
                mock.patch.object(gx_perf, 'last_input_ticks', return_value=(7, 10)), \
                mock.patch.object(gx_perf, 'idle_interval') as interval:
            gx_perf.measure_idle(gui, instance, capture, self.args('win32-idle', '--state', 'minimized', '--windows', '3'),
                                 counters)
        self.assertEqual([(0x20, 6), (0x30, 6), (0x10, 6)], order)
        entry = {'state': 'minimized', 'tick': 7, 'foreground_pid': 7, 'foreground_class': 'Shell_TrayWnd',
                 'foreground_image': 'explorer.exe'}
        self.assertEqual(entry, interval.call_args.kwargs['entry'])
        self.assertEqual(entry, capture.report['idle_state_entry'])

    def test_idle_state_check_runs_after_the_input_window_with_the_focus_helper(self):
        instance, gui, counters = mock.Mock(pid=42, exe=str(self.exe)), mock.Mock(HARNESS_CONFIG=''), mock.Mock()
        instance.contains_pid.return_value = False
        args = self.args('win32-idle', '--state', 'unfocused')
        helper = gui.launch.return_value
        with mock.patch.object(gx_perf, 'populate'), mock.patch.object(gx_perf, 'main_windows', return_value=[]), \
                mock.patch.object(gx_perf, 'last_input_ticks', return_value=(5, 10)), \
                mock.patch.object(gx_perf, 'idle_interval') as interval:
            gx_perf.measure_idle(gui, instance, gx_perf.CaptureRun(instance, self.root, {}), args, counters)
        self.assertIs(helper, interval.call_args.kwargs['helper'])
        self.assertEqual(5, interval.call_args.kwargs['entry']['tick'])  # read after the helper took the foreground
        helper.activate.assert_called_once_with()
        helper.close.assert_called_once_with()
        instance.log = self.root / 'idle-wiring.log'
        instance.log.write_text('', encoding='utf-8')
        sample = dict(pid=1, birth=2, user_100ns=0, kernel_100ns=0, begin_ns=0, end_ns=1, threads=[])
        counters.sample.side_effect = [sample, dict(sample, begin_ns=60000000001)]
        failure = gx_perf.PerfError('measured process regained focus', cause='instance_self_activated')
        with mock.patch.object(gx_perf.time, 'sleep'), mock.patch.object(gx_perf, 'last_input_ticks', return_value=(5, 10)), \
                mock.patch.object(gx_perf, 'idle_state_check', side_effect=failure) as state_check:
            with self.assertRaises(gx_perf.PerfError) as raised:
                gx_perf.idle_interval(gui, instance, gx_perf.CaptureRun(instance, self.root, {}), args, counters,
                                      helper=helper, entry={'tick': 5})
        state_check.assert_called_once_with(gui, instance, args, helper, entry_tick=5)
        self.assertEqual('instance_self_activated', raised.exception.cause)
        self.assertEqual(2, counters.sample.call_count)  # both endpoints were sampled before the check

    def test_p3_drags_real_caption_and_p6_holds_key_at_30hz(self):
        gui, instance, capture = mock.Mock(), mock.Mock(), mock.Mock()
        capture.report = {'observations': {}, 'p3_fixture': {'drag_start': (500, 20), 'drag_end': (620, 60)}}
        old = SimpleNamespace(hwnd=10, rect=(0, 0, 800, 600))
        new = SimpleNamespace(hwnd=10, rect=(100, 50, 900, 650))
        gui.win32.return_value.foreground.return_value = 10
        instance.scale.return_value = 1
        instance.caption_point.return_value = (500, 20)
        with mock.patch.object(gx_perf, 'prepare_p3', return_value=old) as prepare, \
                mock.patch.object(gx_perf, 'p3_scrollbars', return_value=[]), \
                mock.patch.object(gx_perf, 'main_windows', return_value=[new]), mock.patch.object(gx_perf.time, 'sleep'):
            args = self.args()
            args.case = 'p3'
            gx_perf.measure_ui(gui, instance, capture, args)
        prepare.assert_called_once_with(gui, instance, capture)
        instance.drag.assert_called_once_with((500, 20), (620, 60), steps=60, step_delay=2/60)
        instance.uia_rows.side_effect = [
            UiWorkloadProofTests.snapshot([UiWorkloadProofTests.theme(), UiWorkloadProofTests.theme('Beta', selected=False)]),
            UiWorkloadProofTests.snapshot([UiWorkloadProofTests.theme(selected=False), UiWorkloadProofTests.theme('Beta')])]
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui'), mock.patch.object(gx_perf.time, 'sleep'):
            args.case = 'p6'
            gx_perf.measure_ui(gui, instance, capture, args)
        instance.hold_key.assert_called_once_with('down', seconds=2, hz=30)
        instance.press.assert_called_with('ctrl+pagedown')

    def test_p6_theme_list_uia_is_required_only_in_the_new_arm(self):
        args = self.args('win32-ui', '--exe', str(self.exe), '--runs', '2', '--case', 'p6', '--label-env', 'new:GX_TEST_ARM=new')
        gui = self.fake_gui()
        launch = gui.launch.side_effect
        def launch_arm(exe, env_dir, **kwargs):
            instance = launch(exe, env_dir, **kwargs)
            new = kwargs['env'].get('GX_TEST_ARM') == 'new'
            # The historical image has no settings UIA provider: no theme list items, no theme.reload counter.
            instance.uia_rows.side_effect = ([
                UiWorkloadProofTests.snapshot([UiWorkloadProofTests.theme(), UiWorkloadProofTests.theme('Beta', selected=False)]),
                UiWorkloadProofTests.snapshot([UiWorkloadProofTests.theme(selected=False), UiWorkloadProofTests.theme('Beta')])]
                if new else [[{'type': 'ControlType.Window'}]])
            def hold(*_, **__):
                if new:
                    with instance.log.open('a', encoding='utf-8') as log:
                        log.write('info(gx_perf): metric theme.reload 1\n')
            instance.hold_key.side_effect = hold
            return instance
        gui.launch.side_effect = launch_arm
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui'), mock.patch.object(gx_perf.time, 'sleep'), \
                mock.patch.object(gx_perf.CaptureRun, 'drain'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.run_experiment(args, gui))
        result = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertEqual(['completed'] * 4, [row['status'] for row in result['runs']])
        self.assertEqual({'theme_list_uia': {'status': 'not_instrumented', 'n': 0, 'runs': [1, 2],
                                             'scope': 'historical arm only; theme list items not readable through UIA'}},
                         result['missing_preconditions']['old'])
        self.assertNotIn('new', result['missing_preconditions'])
        self.assertEqual(['not_evaluated', 'not_evaluated'], [gate['status'] for gate in result['absolute_gates']['old']])
        self.assertEqual(['PASS', 'PASS'], [gate['status'] for gate in result['absolute_gates']['new']])
        self.assertIn('Missing preconditions (historical arm only', (args.out / 'SUMMARY.txt').read_text(encoding='utf-8'))
        instance = mock.Mock()
        instance.uia_rows.return_value = []
        capture = gx_perf.CaptureRun(instance, self.root, {'baseline': False, 'diagnostic': False})
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf.time, 'sleep'), \
                self.assertRaisesRegex(gx_perf.PerfError, 'no theme list items'):
            gx_perf.measure_ui(mock.Mock(), instance, capture, args)
        instance.hold_key.assert_not_called()

    def test_p6_old_real_uia_parser_empty_tree_still_holds_but_bad_json_stops(self):
        import gx_win_gui as gui
        for raw in (b'[]', b'broken-json', b'[{}]'):
            with self.subTest(raw=raw):
                instance, backend = mock.Mock(), mock.Mock()
                instance.pid = 42
                instance.log = self.root / 'old-uia.log'
                instance.log.write_text('', encoding='utf-8')
                backend.window_pid.return_value = 42
                instance.uia_rows.side_effect = lambda _: gui.Instance.uia_rows(instance, 100)
                capture = gx_perf.CaptureRun(instance, self.root, {'baseline': True, 'diagnostic': False})
                args = self.args(); args.case = 'p6'
                result = SimpleNamespace(returncode=0, stdout=raw, stderr=b'probe detail')
                with mock.patch.object(gui, 'win32', return_value=backend), \
                        mock.patch.object(gui.subprocess, 'run', return_value=result), \
                        mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui'), \
                        mock.patch.object(capture, 'screenshot'), mock.patch.object(capture, 'drain', return_value=True), \
                        mock.patch.object(gx_perf.time, 'sleep'):
                    if raw != b'[]':
                        reason = 'invalid node schema.*row 0' if raw == b'[{}]' else 'invalid JSON.*broken-json'
                        with self.assertRaisesRegex(gui.GuiError, reason + '.*probe detail'):
                            gx_perf.measure_ui(gui, instance, capture, args)
                        instance.hold_key.assert_not_called()
                        self.assertNotIn('missing_preconditions', capture.report)
                        continue
                    gx_perf.measure_ui(gui, instance, capture, args)
                instance.hold_key.assert_called_once_with('down', seconds=2, hz=30)
                self.assertEqual(0, capture.report['missing_preconditions']['theme_list_uia']['n'])
                self.assertEqual(0, capture.report['missing_metrics']['theme.reload']['n'])
                self.assertNotIn('theme.reload', capture.samples.values)

    def test_p5_sweeps_every_entry_until_end_anchor_and_extra_down(self):
        import gx_win_gui as gui
        instance, capture, backend = mock.Mock(), mock.Mock(), mock.Mock()
        backend.client_rect.return_value = (0, 0, 400, 220)
        instance.scale.return_value = 1
        # End, stable End, Home, after Home hover, Down, after last hover, extra Down.
        instance.capture_window.side_effect = [gui.Image(400, 220, bytes([n]) * (400 * 220 * 4))
                                              for n in (2, 2, 1, 1, 2, 2, 2)]
        capture.window.return_value = 'info(gx_perf): keybinds.paint 400us\n'
        capture.report = {}
        args = self.args()
        args.case = 'p5'
        with mock.patch.object(gui, 'win32', return_value=backend), mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui'), mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.measure_ui(gui, instance, capture, args)
        instance.wheel.assert_not_called()
        self.assertEqual([mock.call('ctrl+end'), mock.call('ctrl+home'), mock.call('down'), mock.call('down')],
                         instance.press.call_args_list)
        self.assertGreater(instance.mouse.call_count, 10)
        self.assertEqual(2, len(capture.report['frames']))

    def test_p6_existing_provider_with_no_movement_fails_even_with_reload(self):
        instance, capture = mock.Mock(), mock.Mock()
        rows = UiWorkloadProofTests.snapshot([UiWorkloadProofTests.theme(), UiWorkloadProofTests.theme('Beta', selected=False)])
        instance.uia_rows.return_value = rows
        capture.report = {'observations': {}, 'baseline': False}
        args = self.args(); args.case = 'p6'
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf.time, 'sleep'), \
                self.assertRaisesRegex(gx_perf.PerfError, 'did not move'):
            gx_perf.measure_ui(mock.Mock(), instance, capture, args)
        instance.hold_key.assert_called_once_with('down', seconds=2, hz=30)
        capture.count.assert_called_once()

    def test_p6_saved_theme_preparation_is_outside_counted_hold(self):
        instance = mock.Mock()
        instance.log = self.root / 'theme-preparation.log'
        instance.log.write_text('', encoding='utf-8')
        def snapshot(selected, apply):
            items = [UiWorkloadProofTests.theme(name, selected=name == selected)
                     for name in ('Alpha', 'Beta', 'Gamma')]
            items[2]['rect'][1] = 312
            rows = UiWorkloadProofTests.snapshot(items)
            rows[4]['rect'][3] = 108
            return rows if apply else [r for r in rows if r.get('name') != 'Theme: Apply Theme']
        instance.uia_rows.side_effect = [snapshot('Alpha', False), snapshot('Beta', True), snapshot('Gamma', True)]
        capture = gx_perf.CaptureRun(instance, self.root, {'baseline': False, 'diagnostic': False,
                                                         'capabilities': {'theme.reload': ''}})
        def press(key):
            if key == 'down':
                with instance.log.open('a', encoding='utf-8') as log:
                    log.write('info(gx_perf): metric theme.reload 1\n')
        instance.press.side_effect = press
        def hold(*_, **__):
            with instance.log.open('a', encoding='utf-8') as log:
                log.write('info(gx_perf): metric theme.reload 1\n')
        instance.hold_key.side_effect = hold
        args = self.args(); args.case = 'p6'
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui'), \
                mock.patch.object(capture, 'screenshot'), mock.patch.object(capture, 'drain', return_value=True), \
                mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.measure_ui(mock.Mock(), instance, capture, args)
        self.assertEqual([mock.call('ctrl+pagedown'), mock.call('down')], instance.press.call_args_list)
        instance.hold_key.assert_called_once_with('down', seconds=2, hz=30)
        self.assertEqual([1], capture.samples.values['theme.reload'])
        self.assertEqual(2, instance.log.read_text(encoding='utf-8').count('theme.reload'))
        self.assertEqual('Beta', capture.report['observations']['theme_selection_before']['selected'])

    def test_p6_preparation_failure_never_starts_formal_hold(self):
        import copy
        initial = UiWorkloadProofTests.snapshot([
            UiWorkloadProofTests.theme(), UiWorkloadProofTests.theme('Beta', selected=False)])
        initial = [r for r in initial if r.get('name') != 'Theme: Apply Theme']
        for failure in ('missing_anchor', 'unchanged', 'no_successor', 'unsettled'):
            with self.subTest(failure=failure):
                instance, capture = mock.Mock(), mock.Mock()
                capture.report = {'observations': {}, 'baseline': False}
                if failure == 'missing_anchor':
                    after = copy.deepcopy(initial)
                else:
                    after = UiWorkloadProofTests.snapshot([
                        UiWorkloadProofTests.theme(selected=failure == 'unchanged'),
                        UiWorkloadProofTests.theme('Beta', selected=failure != 'unchanged')])
                if failure == 'unsettled':
                    gamma = UiWorkloadProofTests.theme('Gamma', selected=False)
                    gamma['rect'][1] = 312
                    after = UiWorkloadProofTests.snapshot([
                        UiWorkloadProofTests.theme(selected=False), UiWorkloadProofTests.theme('Beta'), gamma])
                    after[4]['rect'][3] = 108
                instance.uia_rows.side_effect = [initial, after]
                capture.drain.return_value = failure != 'unsettled'
                args = self.args(); args.case = 'p6'
                with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf.time, 'sleep'), \
                        self.assertRaises(gx_perf.PerfError):
                    gx_perf.measure_ui(mock.Mock(), instance, capture, args)
                instance.hold_key.assert_not_called()
                capture.mark.assert_not_called()
                capture.count.assert_not_called()

    def test_p6_without_visible_successor_stops_before_hold_without_claiming_end(self):
        instance, capture = mock.Mock(), mock.Mock()
        instance.uia_rows.return_value = UiWorkloadProofTests.snapshot([
            UiWorkloadProofTests.theme(selected=False), UiWorkloadProofTests.theme('Beta')])
        capture.report = {'observations': {}, 'baseline': False}
        args = self.args(); args.case = 'p6'
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf.time, 'sleep'), \
                self.assertRaisesRegex(gx_perf.PerfError, 'no visible following item'):
            gx_perf.measure_ui(mock.Mock(), instance, capture, args)
        instance.hold_key.assert_not_called()
        capture.count.assert_not_called()

    def test_p6_provider_disappearance_after_hold_is_not_historical_missing(self):
        for baseline in (False, True):
            with self.subTest(baseline=baseline):
                instance, capture = mock.Mock(), mock.Mock()
                instance.uia_rows.side_effect = [UiWorkloadProofTests.snapshot([
                    UiWorkloadProofTests.theme(), UiWorkloadProofTests.theme('Beta', selected=False)]), []]
                capture.report = {'observations': {}, 'baseline': baseline}
                args = self.args(); args.case = 'p6'
                with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf.time, 'sleep'), \
                        self.assertRaisesRegex(gx_perf.PerfError, 'structure is absent'):
                    gx_perf.measure_ui(mock.Mock(), instance, capture, args)
                instance.hold_key.assert_called_once_with('down', seconds=2, hz=30)
                self.assertNotIn('missing_preconditions', capture.report)

    def test_p5_false_end_and_empty_hover_never_complete(self):
        import gx_win_gui as gui
        for pixels, raw, reason in [
                ((2, 2, 1, 1, 1), 'info(gx_perf): keybinds.paint 400us\n', 'stalled'),
                ((2, 2, 1), '', 'no paint'),
                ((2, 2, 2), '', 'indistinguishable'),
                ((2, 3), '', 'unstable')]:
            with self.subTest(reason=reason):
                instance, capture, backend = mock.Mock(), mock.Mock(), mock.Mock()
                backend.client_rect.return_value = (0, 0, 400, 220)
                instance.scale.return_value = 1
                instance.capture_window.side_effect = [gui.Image(400, 220, bytes([n]) * (400 * 220 * 4))
                                                      for n in pixels]
                capture.window.return_value = raw
                capture.report = {}
                args = self.args(); args.case = 'p5'
                with mock.patch.object(gui, 'win32', return_value=backend), \
                        mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui') as close, \
                        mock.patch.object(gx_perf.time, 'sleep'), self.assertRaisesRegex(gx_perf.PerfError, reason):
                    gx_perf.measure_ui(gui, instance, capture, args)
                close.assert_not_called()

    def test_p5_real_capture_old_missing_continues_but_new_empty_rejects(self):
        import gx_win_gui as gui
        for baseline in (True, False):
            with self.subTest(baseline=baseline):
                instance, backend = mock.Mock(), mock.Mock()
                instance.log = self.root / ('old-empty.log' if baseline else 'new-empty.log')
                instance.log.write_text('', encoding='utf-8')
                instance.scale.return_value = 1
                backend.client_rect.return_value = (0, 0, 400, 220)
                instance.capture_window.side_effect = [gui.Image(400, 220, bytes([n]) * (400 * 220 * 4))
                                                      for n in (2, 2, 1, 1, 2, 2, 2)]
                capture = gx_perf.CaptureRun(instance, self.root, {
                    'baseline': baseline, 'diagnostic': False,
                    'capabilities': {} if baseline else {'keybinds.paint': 'ms', 'd2d.layout_create': ''}})
                args = self.args(); args.case = 'p5'
                with mock.patch.object(gui, 'win32', return_value=backend), \
                        mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui') as close, \
                        mock.patch.object(capture, 'screenshot'), mock.patch.object(gx_perf.time, 'sleep'):
                    if not baseline:
                        with self.assertRaisesRegex(gx_perf.PerfError, 'no paint frames'):
                            gx_perf.measure_ui(gui, instance, capture, args)
                        close.assert_not_called()
                        self.assertNotEqual('PASS', gx_perf.absolute_gate(args, capture)['status'])
                        continue
                    gx_perf.measure_ui(gui, instance, capture, args)
                self.assertEqual([mock.call('ctrl+end'), mock.call('ctrl+home'),
                                  mock.call('down'), mock.call('down')], instance.press.call_args_list)
                self.assertEqual([0, 0], [page['frames'] for page in capture.report['hover_pages']])
                for name in ('keybinds.paint', 'd2d.layout_create.per_frame'):
                    self.assertNotIn(name, capture.samples.values)
                    self.assertEqual(0, capture.report['missing_metrics'][name]['n'])
                    self.assertEqual('not_instrumented', capture.report['missing_metrics'][name]['status'])
                self.assertEqual('not_evaluated', gx_perf.absolute_gate(args, capture)['status'])

    def test_p6_no_move_batch_cannot_have_pass_gate(self):
        args = self.args('win32-ui', '--case', 'p6')
        gui = self.fake_gui()
        launch = gui.launch.side_effect
        def launch_arm(*argv, **kwargs):
            instance = launch(*argv, **kwargs)
            instance.uia_rows.return_value = UiWorkloadProofTests.snapshot([UiWorkloadProofTests.theme(),
                                             UiWorkloadProofTests.theme('Beta', selected=False)])
            def hold(*_, **__):
                with instance.log.open('a', encoding='utf-8') as log:
                    log.write('info(gx_perf): metric theme.reload 1\n')
            instance.hold_key.side_effect = hold
            return instance
        gui.launch.side_effect = launch_arm
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui'), \
                mock.patch.object(gx_perf.CaptureRun, 'drain'), mock.patch.object(gx_perf.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1, gx_perf.run_experiment(args, gui))
        result = json.loads((args.out / 'RESULT.json').read_text(encoding='utf-8'))
        self.assertFalse(result['valid'])
        self.assertNotEqual('PASS', result['runs'][0]['absolute_gate']['status'])

    def test_p5_p6_original_numeric_thresholds_are_unchanged(self):
        args = self.args(); args.case = 'p6'
        capture = gx_perf.CaptureRun(mock.Mock(), self.root, {'baseline': False})
        for count, expected in ((0, 'FAIL'), (1, 'PASS'), (2, 'FAIL')):
            capture.samples.values['theme.reload'] = [count]
            self.assertEqual(expected, gx_perf.absolute_gate(args, capture)['status'])
        args.case = 'p5'
        for paint, layouts, expected in ((1.999, 10, 'PASS'), (2, 10, 'FAIL'), (1, 11, 'FAIL')):
            capture.samples.values['keybinds.paint'] = [paint]
            capture.samples.values['d2d.layout_create.per_frame'] = [layouts]
            self.assertEqual(expected, gx_perf.absolute_gate(args, capture)['status'])

    def test_remote_accepts_unknown_remote_names_and_ignores_other_metrics(self):
        log = self.root / 'remote.log'
        log.write_text('info(gx_perf): metric remote.frame_bytes 100\ninfo(gx_perf): remote.future 200us\n'
                       'info(gx_perf): other 1us\ninfo(gx_perf): metric other 4\n', encoding='utf-8')
        out = self.root / 'remote'
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.main(['remote', str(log), '--out', str(out)]))
        report = json.loads((out / 'RESULT.json').read_text(encoding='utf-8'))['metrics']
        self.assertEqual({'remote.frame_bytes', 'remote.future'}, set(report))
        self.assertEqual(100, report['remote.frame_bytes']['sum'])
        self.assertEqual(.2, report['remote.future']['median'])


class UiWorkloadProofTests(unittest.TestCase):
    @staticmethod
    def theme(name='Alpha', parent='themes', selected=True):
        return {'type': 'ControlType.ListItem', 'name': name, 'id': name, 'runtime_id': name,
                'rect': [220, 240 if name == 'Alpha' else 276, 360, 36],
                'selection_item': True, 'selected': selected,
                'parent': {'runtime_id': parent, 'name': '', 'type': 'ControlType.List'}}

    @staticmethod
    def snapshot(items):
        root = {'hwnd': 100, 'runtime_id': 'root', 'name': 'Settings',
                'type': 'ControlType.Window', 'rect': [0, 0, 640, 500]}
        rows = [
            {'runtime_id': 'sections', 'name': 'Settings', 'type': 'ControlType.Tab',
             'parent': root, 'rect': [10, 80, 170, 400]},
            {'runtime_id': 'appearance', 'name': 'Appearance', 'type': 'ControlType.TabItem',
             'parent': {'runtime_id': 'sections'}, 'selected': True, 'selection_item': True,
             'rect': [10, 120, 170, 40]},
            {'runtime_id': 'apply', 'name': 'Theme: Apply Theme', 'type': 'ControlType.Button',
             'parent': root, 'rect': [500, 130, 100, 30]},
            {'runtime_id': 'search', 'name': '', 'type': 'ControlType.Edit',
             'parent': root, 'rect': [210, 190, 390, 30]},
            {'runtime_id': 'themes', 'name': '', 'type': 'ControlType.List',
             'parent': root, 'rect': [220, 240, 360, 72]},
            *items]
        return [{**row, 'root': dict(root)} for row in rows]

    def test_empty_name_real_provider_shape_and_structural_rejections(self):
        import copy
        rows = self.snapshot([self.theme(), self.theme('Beta', selected=False)])
        self.assertEqual('Alpha', gx_perf.theme_selection(rows)['selected'])
        for defect in ('section', 'position', 'ambiguous', 'owner', 'parent', 'search', 'button'):
            bad = copy.deepcopy(rows)
            if defect == 'section': bad[1]['name'] = 'Font'
            elif defect == 'position': bad[4]['rect'][0] = 5
            elif defect == 'ambiguous': bad.insert(4, {**bad[4], 'runtime_id': 'another-list'})
            elif defect == 'owner': bad[-1]['root']['hwnd'] = 200
            elif defect == 'parent': bad[4]['parent'] = {'runtime_id': 'foreign'}
            elif defect == 'search': bad[3]['rect'][1] = 350
            else: bad[2]['name'] = 'Font: Apply Font'
            with self.subTest(defect=defect), self.assertRaises(gx_perf.PerfError):
                gx_perf.theme_selection(bad)

    def test_optional_apply_is_preparation_only_and_list_may_be_inset(self):
        rows = self.snapshot([self.theme(), self.theme('Beta', selected=False)])
        # List bounds are the visible child union, not the width of the search.
        rows[4]['rect'][0:3:2] = [280, 200]
        for item in rows[5:]:
            item['rect'][0:3:2] = [280, 200]
        rows[2]['rect'][0] = 450  # Apply can leave space at the right edge.
        gx_perf.theme_selection(rows)
        rows = [r for r in rows if r.get('name') != 'Theme: Apply Theme']
        self.assertIsNone(gx_perf.theme_selection(rows, require_apply=False)['apply_rect'])
        with self.assertRaisesRegex(gx_perf.PerfError, 'apply button'):
            gx_perf.theme_selection(rows)

    def test_tab_and_list_must_have_own_snapshot_identity_and_correct_parent(self):
        import copy
        rows = self.snapshot([self.theme(), self.theme('Beta', selected=False)])
        for index, key in ((0, 'runtime_id'), (4, 'runtime_id'), (0, 'parent'), (4, 'parent')):
            bad = copy.deepcopy(rows)
            bad[index].pop(key)
            with self.subTest(index=index, key=key), self.assertRaises(gx_perf.PerfError):
                gx_perf.theme_selection(bad, require_apply=False)

    def test_theme_selection_requires_unique_theme_container_and_selection(self):
        rows = [self.theme(), self.theme('Beta', selected=False)]
        self.assertEqual('Alpha', gx_perf.theme_selection(self.snapshot(rows))['selected'])
        for bad in ([], [self.theme(selected=False)],
                    [self.theme(), self.theme('Beta')],
                    [{**self.theme(), 'selected': None}],
                    [{**self.theme(), 'selection_item': False}],
                    [{**self.theme(), 'parent': {'name': 'Font', 'type': 'ControlType.List', 'runtime_id': 'x'}}],
                    [self.theme(), self.theme('Beta', parent='other', selected=False)]):
            with self.subTest(rows=bad), self.assertRaises(gx_perf.PerfError):
                gx_perf.theme_selection(self.snapshot(bad))

    def test_theme_selection_movement_is_semantic_not_item_id(self):
        before = gx_perf.theme_selection(self.snapshot([self.theme(), self.theme('Beta', selected=False)]))
        changed_id = self.theme(); changed_id['id'] = 'replacement'
        same = gx_perf.theme_selection(self.snapshot([changed_id, self.theme('Beta', selected=False)]))
        with self.assertRaisesRegex(gx_perf.PerfError, 'did not move'):
            gx_perf.theme_movement(before, same)
        after = gx_perf.theme_selection(self.snapshot([self.theme(selected=False), self.theme('Beta')]))
        gx_perf.theme_movement(before, after)
        after['container']['name'] = 'Font'
        with self.assertRaisesRegex(gx_perf.PerfError, 'container'):
            gx_perf.theme_movement(before, after)

    def test_provider_rebuild_is_allowed_but_not_evidence_of_selection_movement(self):
        def rebuilt(value):
            if isinstance(value, list):
                return [rebuilt(item) for item in value]
            if isinstance(value, dict):
                return {key: (item + '-rebuilt' if key in ('runtime_id', 'id') and isinstance(item, str)
                              else rebuilt(item)) for key, item in value.items()}
            return value
        rows = self.snapshot([self.theme(), self.theme('Beta', selected=False)])
        before = gx_perf.theme_selection(rows)
        with self.assertRaisesRegex(gx_perf.PerfError, 'did not move'):
            gx_perf.theme_movement(before, gx_perf.theme_selection(rebuilt(rows)))
        rows = self.snapshot([self.theme(selected=False), self.theme('Beta')])
        after = gx_perf.theme_selection(rebuilt(rows))
        gx_perf.theme_movement(before, after)
        after['search_rect'][0] += 20
        with self.assertRaisesRegex(gx_perf.PerfError, 'column moved'):
            gx_perf.theme_movement(before, after)

    def test_visible_candidates_are_sorted_by_geometry_not_uia_enumeration(self):
        rows = self.snapshot([self.theme('Beta', selected=False), self.theme()])
        state = gx_perf.theme_selection(rows)
        self.assertEqual(['Alpha', 'Beta'], state['visible_names'])
        self.assertIn('not the complete', state['coverage'])

    def test_p5_unchanged_is_only_terminal_at_independent_anchor(self):
        self.assertTrue(gx_perf.keybind_end('end', 'end', 'end', set()))
        self.assertFalse(gx_perf.keybind_end('first', 'next', 'end', {'first'}))
        for before, after, seen in [('middle', 'middle', set()), ('a', 'b', {'b'})]:
            with self.assertRaises(gx_perf.PerfError):
                gx_perf.keybind_end(before, after, 'end', seen)


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
        _, report = gx_perf.compare_table(old, new)
        self.assertFalse(report['a']['comparable'])
        self.assertNotIn('delta_median', report['a'])

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
        self.assertEqual("rejected", json.loads((out / "result.json").read_text(encoding='utf-8'))["_validation"]["status"])

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
                self.assertFalse(json.loads((out / "RESULT.json").read_text(encoding='utf-8'))["validation"]["status"] == "valid")

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


class FrozenCollectorTests(unittest.TestCase):
    """Portable fixtures: no Git objects, frozen checkout, WSL or host paths."""
    setUp = QuietTests.setUp
    batch_args = QuietBatchTests.batch_args
    run_batch = QuietBatchTests.run_batch

    def fixture(self):
        import copy
        root = self.args.out.parent.resolve()
        cwd = root / 'frozen'
        (cwd / 'scripts').mkdir(parents=True)
        entry = root / 'task-adapter.py'
        entry.write_text('def main(payload):\n    print("BOUND_ORIGINAL")\n    return 0\n', encoding='utf-8')
        files = {'adapter': {'path': str(entry), 'sha256': gx_perf.hashlib.sha256(entry.read_bytes()).hexdigest()}}
        for name in gx_perf.FROZEN_C1_FILES[1:]:
            path = cwd / 'scripts' / name
            path.write_text('# synthetic frozen file\n', encoding='utf-8')
            files[name] = {'path': str(path), 'sha256': gx_perf.hashlib.sha256(path.read_bytes()).hexdigest()}
        command = [sys.executable, str(entry), 'gtk', '--pair', 'base-vs-gate', '--out', str(self.args.out / 'measure'),
                   '--json', str(self.args.out / 'measurement-result.json')]
        manifest = {'schema': 'gx-c1-frozen-collector-v3', 'distro': 'Ubuntu-24.04', 'cwd': str(cwd), 'argv': command, 'files': files,
                    'contract': copy.deepcopy(gx_perf.FROZEN_C1_CONTRACT), 'builds': {label: {} for label in ('base', 'gate', 'combined')}}
        path = root / 'manifest.json'
        gx_perf.write_json(path, manifest)
        digest = gx_perf.hashlib.sha256(path.read_bytes()).hexdigest()
        args = self.batch_args('--input-observe-only', '--frozen-collector', str(path), '--frozen-collector-sha256', digest,
                               command=command)
        return args, manifest, entry, cwd

    def test_explicit_manifest_binds_cwd_argv_hash_units_and_outputs(self):
        import copy
        args, manifest, entry, cwd = self.fixture()
        command = manifest['argv']
        with mock.patch.object(Path, 'cwd', return_value=cwd):
            binding = gx_perf.frozen_collector_binding(args, command)
        self.assertEqual(command, binding['evidence']['requested_argv'])
        self.assertIn(b'"adapter"', binding['payload'])
        self.assertTrue(gx_perf.desktop_command(command), 'unflagged external entry is not a basename exemption')
        self.assertFalse(gx_perf.gate_exit_contract(command))
        with self.assertRaisesRegex(gx_perf.PerfError, 'cwd'):
            gx_perf.frozen_collector_binding(args, command)
        for change in ('hash', 'duplicate', 'unknown', 'argv', 'count', 'module_location', 'missing_module', 'distro_missing', 'distro_empty', 'fresh'):
            data = copy.deepcopy(manifest)
            request = command[:]
            if change == 'unknown':
                data['unknown'] = True
            elif change == 'argv':
                request[-1] = 'different'
            elif change == 'count':
                data['contract']['runs_per_arm'] = 1
            elif change == 'module_location':
                data['files']['gx_wsl.py']['path'] = str(entry)
            elif change == 'missing_module':
                del data['files']['test_gx_perf.py']
            elif change == 'distro_missing':
                del data['distro']
            elif change == 'distro_empty':
                data['distro'] = ''
            elif change == 'fresh':
                (args.out / 'measure').mkdir(parents=True)
            text = json.dumps(data)
            if change == 'duplicate':
                text = text[:-1] + ', "cwd": ' + json.dumps(str(cwd)) + '}'
            args.frozen_collector.write_text(text, encoding='utf-8')
            args.frozen_collector_sha256 = '0' * 64 if change == 'hash' else gx_perf.hashlib.sha256(args.frozen_collector.read_bytes()).hexdigest()
            with self.subTest(change=change), mock.patch.object(Path, 'cwd', return_value=cwd), self.assertRaises(gx_perf.PerfError):
                gx_perf.frozen_collector_binding(args, request)

    def test_pin_mode_does_not_admit_wrappers_options_or_naked_adapter(self):
        args, data, _, cwd = self.fixture()
        for command in ([sys.executable, '-m', 'wrapper', *data['argv'][2:]],
                        ['bash', *data['argv']], ['python', *data['argv'][1:]],
                        [*data['argv'], '--runs', '1']):
            data['argv'] = command
            gx_perf.write_json(args.frozen_collector, data)
            args.frozen_collector_sha256 = gx_perf.hashlib.sha256(args.frozen_collector.read_bytes()).hexdigest()
            with self.subTest(command=command), mock.patch.object(Path, 'cwd', return_value=cwd), self.assertRaises(gx_perf.PerfError):
                gx_perf.frozen_collector_binding(args, command)
        args.input_observe_only = False
        with self.assertRaisesRegex(gx_perf.PerfError, 'requires --input-observe-only'):
            gx_perf.run_quiet_batch(args, self.probe, mock.Mock())

    def test_outer_json_is_rejected_before_any_output_or_dispatch(self):
        args, data, _, cwd = self.fixture()
        historical = args.out.parent / 'historical-result.json'
        historical.write_bytes(b'original evidence\n')
        for target in (historical, args.out / 'collector-identity.json',
                       args.out / 'measurement-result.json', args.out / 'collector-outcome.json',
                       args.out / 'RESULT.json'):
            args.json = target
            runner = mock.Mock()
            with self.subTest(target=target), mock.patch.object(Path, 'cwd', return_value=cwd):
                with self.assertRaisesRegex(gx_perf.PerfError, 'outer --json'):
                    gx_perf.run_quiet_batch(args, self.probe, runner)
            runner.assert_not_called()
            self.assertFalse(args.out.exists())
            self.assertEqual(b'original evidence\n', historical.read_bytes())

    def test_outer_distro_must_match_manifest_before_probe_or_dispatch(self):
        args, data, _, cwd = self.fixture()
        args.distro = 'Different-Distribution'
        runner, probe = mock.Mock(), mock.Mock()
        with mock.patch.object(Path, 'cwd', return_value=cwd):
            with self.assertRaisesRegex(gx_perf.PerfError, 'distro'):
                gx_perf.run_quiet_batch(args, probe, runner)
        self.assertFalse(args.out.exists())
        runner.assert_not_called()
        self.assertEqual([], probe.mock_calls)

    def test_frozen_main_and_cli_preserve_every_outer_json_target(self):
        import subprocess
        args, data, _, cwd = self.fixture()
        targets = (args.out.parent / 'historical-result.json', args.out / 'collector-identity.json',
                   args.out / 'measurement-result.json', args.out / 'collector-outcome.json', args.out / 'RESULT.json')
        for target in targets:
            target.parent.mkdir(parents=True, exist_ok=True)
            argv = ['quiet-batch', '--out', str(args.out), '--input-observe-only', '--distro', 'Ubuntu-24.04',
                    '--frozen-collector', str(args.frozen_collector),
                    '--frozen-collector-sha256', args.frozen_collector_sha256, '--json', str(target), '--', *data['argv']]
            for route in ('main', 'cli'):
                with self.subTest(target=target.name, route=route):
                    original = b'original evidence\r\n\x00\xff'
                    target.write_bytes(original)
                    if route == 'main':
                        with contextlib.redirect_stderr(io.StringIO()), mock.patch.object(Path, 'cwd', return_value=cwd):
                            code = gx_perf.main(argv)
                    else:
                        child = subprocess.run([sys.executable, str(SCRIPTS / 'gx_perf.py'), *argv], cwd=cwd,
                                               capture_output=True, timeout=20)
                        code = child.returncode
                        self.assertIn(b'outer --json', child.stderr)
                    self.assertEqual(2, code)
                    self.assertEqual(original, target.read_bytes())

    def test_partial_frozen_options_do_not_create_outer_json_but_normal_errors_do(self):
        args, data, _, cwd = self.fixture()
        target = args.out.parent / 'must-not-be-created.json'
        options = (['--frozen-collector', str(args.frozen_collector)],
                   ['--frozen-collector-sha256', args.frozen_collector_sha256])
        for option in options:
            argv = ['quiet-batch', '--out', str(args.out), '--input-observe-only', *option,
                    '--json', str(target), '--', *data['argv']]
            with self.subTest(option=option[0]), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(2, gx_perf.main(argv))
                self.assertFalse(target.exists())
                self.assertFalse(args.out.exists())
        # The restriction is scoped to frozen mode, not normal error reports.
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, gx_perf.main(['compare', '--old', str(cwd / 'missing-old'),
                                            '--new', str(cwd / 'missing-new'), '--json', str(target)]))
        self.assertEqual('rejected', json.loads(target.read_text(encoding='utf-8'))['_validation']['status'])

    def test_isolated_child_cannot_import_shadow_modules_from_task_paths(self):
        import subprocess
        args, data, entry, cwd = self.fixture()
        for directory in (entry.parent, cwd / 'scripts', cwd):
            (directory / 'statistics.py').write_text('raise RuntimeError("UNBOUND_SHADOW")\n', encoding='utf-8')
            (directory / 'task_only.py').write_text('raise RuntimeError("UNBOUND_EXTRA")\n', encoding='utf-8')
        entry.write_text(
            'import sys\n'
            'def main(payload):\n'
            '    from pathlib import Path\n'
            '    for path in (Path(__file__).parent, Path.cwd() / "scripts", Path.cwd()):\n'
            '        sys.path.insert(0, str(path))\n'
            '    import statistics\n'
            '    import subprocess\n'
            '    assert statistics.mean([2, 4]) == 3\n'
            '    try:\n'
            '        import task_only\n'
            '    except ImportError:\n'
            '        pass\n'
            '    else:\n'
            '        raise AssertionError("unbound module admitted")\n'
            '    print("TRUSTED_STDLIB_ONLY")\n'
            '    return 0\n', encoding='utf-8')
        data['files']['adapter']['sha256'] = gx_perf.hashlib.sha256(entry.read_bytes()).hexdigest()
        gx_perf.write_json(args.frozen_collector, data)
        args.frozen_collector_sha256 = gx_perf.hashlib.sha256(args.frozen_collector.read_bytes()).hexdigest()
        with mock.patch.object(Path, 'cwd', return_value=cwd):
            binding = gx_perf.frozen_collector_binding(args, data['argv'])
        result = subprocess.run(binding['argv'], input=binding['payload'], cwd=cwd, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr.decode())
        self.assertIn(b'TRUSTED_STDLIB_ONLY', result.stdout)

    def test_changed_entry_during_slot_wait_is_rejected_before_execution(self):
        import gx_slots
        args, data, entry, cwd = self.fixture()
        acquire = gx_slots.acquire
        @contextlib.contextmanager
        def wait_then_acquire(*values, **options):
            entry.write_text('raise RuntimeError("changed while waiting")\n', encoding='utf-8')
            with acquire(*values, **options) as lease:
                yield lease
        runner = mock.Mock(return_value=SimpleNamespace(returncode=0))
        with mock.patch.object(Path, 'cwd', return_value=cwd), mock.patch.object(gx_slots, 'acquire', side_effect=wait_then_acquire):
            code, result = self.run_batch(args, runner)
        self.assertEqual(0, runner.call_count, 'changed entry must never reach dispatch')
        self.assertEqual((2, 'ERROR', 'DRIVER_ERROR'), (code, result['status'], result['measurement']))
        self.assertTrue(any('SHA256 mismatch' in error for error in result['errors']))

    def test_changed_manifest_or_module_during_wait_is_rejected(self):
        import gx_slots
        args, data, _, cwd = self.fixture()
        original = args.frozen_collector.read_bytes()
        acquire = gx_slots.acquire
        for index, path in enumerate((args.frozen_collector, Path(data['files']['gx_wsl.py']['path']))):
            if index:
                args.frozen_collector.write_bytes(original)
                args.out = args.out.parent / 'other-batch'
                data['argv'][-3] = str(args.out / 'measure')
                data['argv'][-1] = str(args.out / 'measurement-result.json')
                gx_perf.write_json(args.frozen_collector, data)
                args.frozen_collector_sha256 = gx_perf.hashlib.sha256(args.frozen_collector.read_bytes()).hexdigest()
                args.batch_command = ['--', *data['argv']]
            @contextlib.contextmanager
            def wait_then_acquire(*values, **options):
                path.write_bytes(path.read_bytes() + b'\n')
                with acquire(*values, **options) as lease:
                    yield lease
            runner = mock.Mock()
            with self.subTest(path=path), mock.patch.object(Path, 'cwd', return_value=cwd), \
                    mock.patch.object(gx_slots, 'acquire', side_effect=wait_then_acquire):
                code, result = self.run_batch(args, runner)
                runner.assert_not_called()
                self.assertEqual(2, code)
                self.assertTrue(any('SHA256 mismatch' in error for error in result['errors']))

    def test_dispatch_executes_captured_bytes_even_if_file_changes_after_binding(self):
        import subprocess
        args, data, entry, cwd = self.fixture()
        def runner(command, **kwargs):
            entry.write_text('raise RuntimeError("unverified replacement executed")\n', encoding='utf-8')
            Path(data['files']['gx_wsl.py']['path']).write_text('changed after binding\n', encoding='utf-8')
            self.assertEqual(['-I', '-S', '-B', '-c'], command[1:5])
            return subprocess.run(command, **kwargs)
        with mock.patch.object(Path, 'cwd', return_value=cwd):
            code, result = self.run_batch(args, runner)
        self.assertEqual(0, code)
        self.assertIn('BOUND_ORIGINAL', (args.out / 'command.log').read_text(encoding='utf-8'))
        self.assertEqual(data['files'], result['frozen_collector']['files'])

    def test_output_created_during_wait_is_rejected_without_overwrite(self):
        import gx_slots
        args, _, _, cwd = self.fixture()
        acquire = gx_slots.acquire
        marker = args.out / 'measurement-result.json'
        @contextlib.contextmanager
        def wait_then_acquire(*values, **options):
            marker.write_text('existing original', encoding='utf-8')
            with acquire(*values, **options) as lease:
                yield lease
        runner = mock.Mock()
        with mock.patch.object(Path, 'cwd', return_value=cwd), mock.patch.object(gx_slots, 'acquire', side_effect=wait_then_acquire):
            code, result = self.run_batch(args, runner)
        runner.assert_not_called()
        self.assertEqual(2, code)
        self.assertIn('fresh', ' '.join(result['errors']))
        self.assertEqual('existing original', marker.read_text(encoding='utf-8'))


class GtkMetricCoverageTests(unittest.TestCase):
    def core(self):
        samples = gx_perf.Samples()
        for name in gx_perf.GTK_REQUIRED:
            for _ in range(10):
                samples.add(name, 1, "ms")
        samples.gtk_runs = [{} for _ in range(10)]
        return samples

    def test_optional_group_absence_is_unknown_not_a_zero_sample(self):
        old, new = self.core(), self.core()
        for _ in range(5):
            old.add("cpu.pool", 0, "ms")
        self.assertEqual([], gx_perf.comparison_errors(old, new, gtk=True, runs=10))
        _, table = gx_perf.compare_table(old, new)
        self.assertEqual(5, table['cpu.pool']['old']['n'])
        self.assertIsNone(table['cpu.pool']['new'])
        self.assertFalse(table['cpu.pool']['comparable'])
        self.assertNotIn('delta_median', table['cpu.pool'])
        self.assertNotIn('cpu.pool', new.values)

    def test_shared_partial_cpu_groups_still_require_equal_counts(self):
        old, new = self.core(), self.core()
        for samples, n in ((old, 5), (new, 6)):
            for _ in range(n):
                samples.add('cpu.pool', 0, 'ms')
        errors = gx_perf.comparison_errors(old, new, gtk=True, runs=10)
        self.assertEqual(['cpu.pool: sample counts differ (5 vs 6)'], errors)
        _, table = gx_perf.compare_table(old, new)
        self.assertFalse(table['cpu.pool']['comparable'])
        self.assertNotIn('delta_median', table['cpu.pool'])
        new.values['cpu.pool'].pop()
        self.assertEqual([], gx_perf.comparison_errors(old, new, gtk=True, runs=10))

    def test_optional_non_cpu_counts_remain_descriptive_and_units_still_gate(self):
        old, new = self.core(), self.core()
        old.add('pipeline.uploads', 4, None)
        new.add('pipeline.uploads', 7, None)
        new.add('pipeline.uploads', 8, None)
        self.assertEqual([], gx_perf.comparison_errors(old, new, gtk=True, runs=10))
        _, table = gx_perf.compare_table(old, new)
        self.assertFalse(table['pipeline.uploads']['comparable'])
        self.assertNotIn('delta_median', table['pipeline.uploads'])
        new.units['pipeline.uploads'] = 'ms'
        self.assertIn('pipeline.uploads: time/count unit conflict',
                      gx_perf.comparison_errors(old, new, gtk=True, runs=10))

    def test_every_required_metric_needs_ten_finite_nonnegative_times(self):
        for name in gx_perf.GTK_REQUIRED:
            for failure in ('missing', 'nine', 'count', 'negative', 'nan'):
                old, new = self.core(), self.core()
                if failure == 'missing':
                    old.values.pop(name)
                elif failure == 'nine':
                    old.values[name].pop()
                elif failure == 'count':
                    old.units[name] = ''
                else:
                    old.values[name][0] = -1 if failure == 'negative' else float('nan')
                with self.subTest(name=name, failure=failure):
                    self.assertTrue(gx_perf.comparison_errors(old, new, gtk=True, runs=10))

    def test_optional_cpu_unit_and_negative_are_rejected_even_without_peer(self):
        for unit, value in (('', 0), ('ms', -1), ('ms', float('inf'))):
            old, new = self.core(), self.core()
            old.values['cpu.pool'], old.units['cpu.pool'] = [value], unit
            with self.subTest(unit=unit, value=value):
                self.assertTrue(gx_perf.comparison_errors(old, new, gtk=True, runs=10))

    def test_raw_cpu_groups_must_not_be_dropped_or_filled_in(self):
        for change in ('drop', 'zero', 'unit', 'negative', 'rename'):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                meta = gtk_fixture(root, 'pool')
                path = root / 'perf-perf.txt'
                text = path.read_text(encoding='utf-8')
                if change == 'drop':
                    text = text.replace('metric cpu.pool 0.000 s\n', '')
                elif change == 'zero':
                    text += 'metric cpu.pool-ghostty 0.000 s\n'
                elif change == 'unit':
                    text = text.replace('metric cpu.pool 0.000 s', 'metric cpu.pool 0')
                elif change == 'negative':
                    text = text.replace('metric cpu.pool 0.000 s', 'metric cpu.pool -0.001 s')
                else:
                    text = text.replace('metric cpu.pool ', 'metric cpu.pool-ghostty ')
                path.write_text(text, encoding='utf-8')
                meta['artifact_sha256'][path.name] = gx_perf.hashlib.sha256(path.read_bytes()).hexdigest()
                gx_perf.write_json(root / 'perf-meta.json', meta)
                with self.subTest(change=change), self.assertRaises(gx_perf.PerfError):
                    gx_perf.gtk_evidence(root / 'perf-meta.json')

    def batch(self, root, limits):
        batch = {'schema': 'gx-gtk-runs-v1', 'planned_runs': 10, 'labels': ['old', 'new'],
                 'valid': False, 'order': 'AB/BA', 'runs': []}
        for run, label in gx_perf.alternate(batch['labels'], 10):
            relative = f'{label}/run-{run:02d}'
            gtk_fixture(root / relative, 'pool' if run <= limits[label] else 'pool-ghostty')
            batch['runs'].append({'label': label, 'run': run, 'path': relative, 'exit': 0, 'status': 'completed'})
        return batch

    def test_rejected_batch_reports_all_actual_n_without_comparison_or_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            batch = self.batch(root, {'old': 5, 'new': 6})
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(1, gx_perf.report_gtk_runs(root, batch, None))
            result = gx_perf.read_json(root / 'RESULT.json')
            self.assertEqual('rejected', result['validation']['status'])
            self.assertEqual({'old': 10, 'new': 10}, result['validation']['valid_runs'])
            self.assertEqual(20, len(batch['runs']))
            self.assertNotIn('metrics', result)
            coverage = result['validation']['metric_coverage']
            for label, n in (('old', 5), ('new', 6)):
                self.assertEqual(n, coverage[label]['cpu.pool']['n'])
                self.assertEqual(10 - n, coverage[label]['cpu.pool-ghostty']['n'])
                for name in gx_perf.GTK_REQUIRED:
                    self.assertEqual(10, coverage[label][name]['n'])
            self.assertFalse(result['validation']['metric_comparability']['cpu.pool']['comparable'])
            with self.assertRaises(gx_perf.PerfError):
                gx_perf.collect([root / 'old', root / 'new'])

    def test_partial_groups_do_not_allow_any_proper_subset_of_valid_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            batch = self.batch(root, {'old': 5, 'new': 5})
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, gx_perf.report_gtk_runs(root, batch, None))
            for label in batch['labels']:
                for omitted in range(1, 11):
                    paths = [root / label / f'run-{i:02d}' for i in range(1, 11) if i != omitted]
                    with self.subTest(label=label, omitted=omitted), self.assertRaisesRegex(gx_perf.PerfError, 'partial GTK subsets'):
                        gx_perf.collect(paths)
            self.assertEqual(20, len(gx_perf.collect([root]).gtk_runs))
            truncated = dict(batch, runs=batch['runs'][:-1])
            with self.assertRaises(gx_perf.PerfError):
                gx_perf.canonical_plan(root, truncated)


class C7TimingTests(unittest.TestCase):
    def endpoints(self):
        def endpoint(t, sequence):
            return {'begin_ns': t, 'end_ns': t,
                    'log': {'begin_ns': t, 'end_ns': t, 'byte_offset': sequence},
                    'cpu': {'begin_ns': t, 'end_ns': t},
                    'pdh': {'sequence': sequence, 'collection_qpc_begin_ns': t, 'collection_qpc_end_ns': t}}
        start, end = endpoint(10_000_000_000, 1), endpoint(70_000_000_000, 61)
        rows = []
        for second in range(61):
            t = start['begin_ns'] + second * 1_000_000_000
            ep = endpoint(t, second + 1)
            rows.append(dict(ep['pdh'], phase='start' if second == 0 else 'end' if second == 60 else 'periodic',
                             scheduled_qpc_ns=t if 0 < second < 60 else None,
                             timestamp_100ns=t // 100, recorded_qpc_ns=t))
        return start, end, rows

    def test_exact_requested_window_and_explicit_precision(self):
        start, end, rows = self.endpoints()
        result = gx_perf.c7_window_timing(start, end, rows, 60, 0, [])
        self.assertEqual('valid', result['status'])
        self.assertEqual(61, len(rows))
        self.assertEqual(60_000_000_000, result['pdh_timestamp_duration_ns'])
        self.assertEqual('PENDING', gx_perf.c7_window_timing(start, end, rows, 60, None, [])['status'])

    def test_planned_periodic_slots_must_be_complete_unique_and_in_order(self):
        for issue in ('endpoints-only', 'first-missing', 'last-missing', 'duplicate', 'wrong-order', 'wrong-phase'):
            with self.subTest(issue=issue):
                start, end, rows = self.endpoints()
                if issue == 'endpoints-only':
                    rows = [rows[0], rows[-1]]
                elif issue == 'first-missing':
                    del rows[1]
                elif issue == 'last-missing':
                    del rows[-2]
                elif issue == 'duplicate':
                    rows[2]['scheduled_qpc_ns'] = rows[1]['scheduled_qpc_ns']
                elif issue == 'wrong-order':
                    rows[1]['scheduled_qpc_ns'], rows[2]['scheduled_qpc_ns'] = (
                        rows[2]['scheduled_qpc_ns'], rows[1]['scheduled_qpc_ns'])
                else:
                    rows[1]['phase'] = 'start'
                result = gx_perf.c7_window_timing(start, end, rows, 60, 50, [])
                self.assertEqual('PENDING', result['status'])
                self.assertIn('planned periodic slots', result['reason'])

    def test_finite_explicit_precision_preserves_actual_interval(self):
        start, end, rows = self.endpoints()
        for key in ('begin_ns', 'end_ns'):
            end[key] += 500_000
            end['log'][key] += 500_000
            end['cpu'][key] += 500_000
        for key in ('collection_qpc_begin_ns', 'collection_qpc_end_ns'):
            end['pdh'][key] += 500_000
            rows[-1][key] += 500_000
        rows[-1]['timestamp_100ns'] += 5000
        result = gx_perf.c7_window_timing(start, end, rows, 60, 1, [])
        self.assertEqual('valid', result['status'])
        self.assertEqual([60_000_500_000] * 2, result['duration_bounds_ns']['cpu'])
        self.assertEqual(60_000_500_000, result['pdh_timestamp_duration_ns'])
        self.assertEqual(1_000_000, result['endpoint_budget_ns'])
        self.assertEqual('PENDING', gx_perf.c7_window_timing(start, end, rows, 60, 0.4, [])['status'])

    def test_formal_cli_requires_explicit_finite_precision(self):
        argv = ['win32-c7', '--exe', 'old', '--exe', 'new', '--out', 'out']
        with mock.patch.object(gx_perf, 'run_c7_matrix', return_value=0) as run, \
                contextlib.redirect_stderr(io.StringIO()):
            for suffix in ([], ['--endpoint-budget-ms', '-1'], ['--endpoint-budget-ms', 'nan'],
                           ['--endpoint-budget-ms', 'inf']):
                self.assertEqual(2, gx_perf.main(argv + suffix))
            run.assert_not_called()
            self.assertEqual(0, gx_perf.main(argv + ['--endpoint-budget-ms', '1']))
            self.assertEqual(1, run.call_args.args[0].endpoint_budget_ms)

    def test_slow_collect_shifted_endpoint_missing_stream_and_clock_jump_reject(self):
        for issue in ('late', 'early-pdh', 'cpu', 'pdh', 'log', 'stamp', 'periodic-overrun'):
            with self.subTest(issue=issue):
                start, end, rows = self.endpoints()
                if issue == 'late':
                    end['end_ns'] += 8_000_000_000
                elif issue == 'early-pdh':
                    start['pdh']['collection_qpc_begin_ns'] -= 8_000_000_000
                elif issue in ('cpu', 'pdh', 'log'):
                    end[issue] = None
                elif issue == 'stamp':
                    rows[-1]['timestamp_100ns'] += 80_000_000
                else:
                    rows.insert(1, dict(rows[0], phase='periodic', recorded_qpc_ns=end['end_ns'] + 1))
                result = gx_perf.c7_window_timing(start, end, rows, 60, 1, [])
                self.assertEqual('PENDING', result['status'])

    def test_each_missing_metric_prevents_partial_formal_values(self):
        names = ('process.cpu', 'threads.context_switches.pdh', 'renderer.present')
        for absent in names:
            capture = SimpleNamespace(samples=gx_perf.Samples(), report={'missing_metrics': {}})
            for name in names:
                if name != absent:
                    capture.samples.add(name, 0, 'ms' if name == 'process.cpu' else None)
            evidence = {'timing': {'status': 'valid'}}
            gx_perf.c7_complete_metrics(capture, evidence)
            self.assertEqual('PENDING', evidence['coverage'])
            self.assertFalse(capture.samples.values)
            self.assertEqual(set(names), set(capture.report['missing_metrics']))


class P7C7Tests(unittest.TestCase):
    def run_capture_case(self, case='ime-preedit'):
        import gx_perf_stimulus as stimulus
        capture = gx_perf.CaptureRun(self.instance, self.root, {'capabilities': {}, 'errors': []})
        self.capture = capture
        args = SimpleNamespace(case=case, tabs=1, state='visible', seconds=0)
        shells = mock.Mock()
        shells.python_identity = dict(executable='python.exe', executable_sha256='a' * 64,
                                      launcher='launcher.exe', launcher_sha256='b' * 64)
        shells.identities = {42: 123}
        shells.rows.side_effect = lambda: ([{'event': 'input', 'pid': 42, 'text': c} for c in '你好']
                                          if mock.call('space') in self.instance.press.call_args_list else [])
        before = {'pid': 42, 'birth': 123, 'kernel_100ns': 0, 'user_100ns': 0,
                  'begin_ns': 0, 'end_ns': 1, 'threads': []}
        counters = mock.Mock()
        counters.sample.side_effect = [before, {**before, 'begin_ns': 1_000_000_001}]
        counters.cpu_sample = counters.sample
        with mock.patch.object(gx_perf, 'populate'), mock.patch.object(gx_perf, 'main_windows', return_value=[]), \
                mock.patch.object(gx_perf, 'last_input_ticks', return_value=(10, 100)), \
                mock.patch.object(gx_perf.time, 'sleep'), \
                mock.patch.object(stimulus, 'ime_state', return_value={'status': 'ready'}):
            gx_perf.measure_c7(self.gui, self.instance, capture, args, counters, shells,
                               pdh_factory=mock.Mock(side_effect=stimulus.PdhFailure('add', 0xc0000bb9)))
        return capture.report['c7']

    def test_c7_ime_capture_is_target_only_with_explicit_unverified_metadata(self):
        image = self.backdrop.capture.return_value
        def capture(_instance, _info, method, label):
            if label == 'ime-preedit-entry' or label.startswith('c7-after-'):
                if method == 'screen':
                    raise RuntimeError('covered by external IME window')
            return image
        self.backdrop.capture.side_effect = capture
        evidence = self.run_capture_case()
        shots = evidence['screenshots']
        self.assertEqual(['screen'] * 8 + ['print'] * 9, [s['method'] for s in shots])
        for shot in shots[8:]:
            self.assertEqual('target-window-only', shot['capture_scope'])
            self.assertEqual('unknown', shot['rendered_pixels'])
        self.assertEqual('PENDING', evidence['visual_review'])
        self.assertEqual('你好', evidence['ime']['commit_text'])
        self.assertEqual([mock.call(k) for k in 'nihao'] + [mock.call('space')],
                         self.instance.press.call_args_list)

    def test_c7_non_ime_keeps_screen_default(self):
        evidence = self.run_capture_case('visible')
        self.assertEqual(['screen'] * 16, [s['method'] for s in evidence['screenshots']])
        self.instance.press.assert_not_called()

    def test_c7_refuses_existing_raw_instead_of_merging_or_relabelling_it(self):
        path = self.root / 'pdh-raw.jsonl'
        path.write_bytes(b'preserved old raw\n')
        with self.assertRaisesRegex(gx_perf.PerfError, 'fresh evidence directory required'):
            self.run_capture_case('visible')
        self.assertEqual(b'preserved old raw\n', path.read_bytes())

    def test_c7_screen_privacy_failure_still_stops_before_ime_input(self):
        self.backdrop.capture.side_effect = RuntimeError('screen privacy coverage failed')
        with self.assertRaisesRegex(RuntimeError, 'screen privacy coverage failed'):
            self.run_capture_case()
        self.backdrop.capture.assert_called_once_with(
            self.instance, self.instance.require_window.return_value, 'screen', 'c7-before-1')
        self.instance.press.assert_not_called()

    def test_c7_ime_print_failure_is_fatal_without_screen_fallback(self):
        image = self.backdrop.capture.return_value
        def capture(_instance, _info, method, label):
            if label == 'ime-preedit-entry':
                self.assertEqual('print', method)
                raise RuntimeError('PrintWindow failed')
            return image
        self.backdrop.capture.side_effect = capture
        with self.assertRaisesRegex(RuntimeError, 'PrintWindow failed'):
            self.run_capture_case()
        self.assertEqual(9, self.backdrop.capture.call_count)
        self.assertEqual(8, len(self.capture.report['c7']['screenshots']))
        self.assertNotIn(mock.call('space'), self.instance.press.call_args_list)
        self.backdrop.finish.assert_called_once()

    def test_c7_ime_print_does_not_waive_foreground_or_input_guards(self):
        for failure in ('foreground', 'input', 'ownership'):
            with self.subTest(failure=failure):
                self.gui.win32().foreground.return_value = 9
                self.gui.win32().window_pid.side_effect = lambda hwnd: 42 if hwnd == 9 else 55528
                self.instance.contains_pid.return_value = False
                self.instance.ensure_owned.side_effect = None
                self.instance.press.reset_mock()
                image = self.backdrop.capture.return_value
                def capture(_instance, _info, method, label):
                    if label == 'ime-preedit-entry':
                        self.assertEqual('print', method)
                        if failure == 'foreground':
                            self.gui.win32().foreground.return_value = 999
                        elif failure == 'input':
                            gx_perf.last_input_ticks.return_value = (11, 100)
                        else:
                            self.instance.ensure_owned.side_effect = RuntimeError('ownership lost')
                    return image
                self.backdrop.capture.side_effect = capture
                with self.assertRaises((gx_perf.PerfError, RuntimeError)):
                    self.run_capture_case()
                self.assertFalse((self.root / 'ime-preedit-entry.png').exists())
                self.assertEqual(8, len(self.capture.report['c7']['screenshots']))
                self.assertNotIn(mock.call('space'), self.instance.press.call_args_list)

    def test_c7_ime_guard_failure_blocks_print_before_capture(self):
        def press(key):
            if key == 'o':
                self.gui.win32().window_pid.return_value = 55528
                self.instance.contains_pid.return_value = False
        self.instance.press.side_effect = press
        with self.assertRaises(gx_perf.PerfError) as raised:
            self.run_capture_case()
        self.assertEqual('foreground_lost', raised.exception.cause)
        self.assertEqual(8, self.backdrop.capture.call_count)
        self.assertFalse((self.root / 'ime-preedit-entry.png').exists())
        self.assertNotIn(mock.call('space'), self.instance.press.call_args_list)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.instance = mock.Mock(pid=42, creation=123, exe=str(self.root / 'ghostty.exe'))
        self.instance.log = self.root / 'ghostty.log'
        self.instance.log.write_bytes(b'old log\r\n')
        import ctypes.wintypes
        import gx_perf_stimulus as stimulus
        composition = mock.patch.object(stimulus, 'dwm_flush')
        composition.start()
        self.addCleanup(composition.stop)
        self.instance.responsive.return_value = True
        self.instance.hang_evidence.return_value = None
        self.instance.require_window.return_value = SimpleNamespace(hwnd=9, rect=(0, 0, 800, 600))
        self.instance.terminals.return_value = [SimpleNamespace(hwnd=10, rect=(0, 30, 800, 600))]
        self.gui = mock.Mock()
        self.gui.win32().raw_window_rect.return_value = (0, 0, 800, 600)
        self.gui.win32().process_creation.return_value = 123
        self.gui.win32().send_message.return_value = 0
        self.gui.win32().RECT = ctypes.wintypes.RECT
        def client_rect(hwnd, result):
            rect = self.gui.win32().raw_window_rect.return_value
            result._obj.right, result._obj.bottom = rect[2]-rect[0], rect[3]-rect[1]
            return 1
        self.gui.win32().GetClientRect.side_effect = client_rect
        self.gui.win32().foreground.return_value = 9
        self.gui.win32().window_pid.return_value = 42
        self.gui.win32().class_name.return_value = 'GhosttyWindow'
        self.gui.image_name.return_value = 'ghostty.exe'
        self.backdrop = mock.Mock()
        self.backdrop.finish.return_value = {}
        self.backdrop.teardown_failures.return_value = []
        self.gui.Backdrop.return_value = self.backdrop
        self.backdrop.capture.return_value.save_png.side_effect = lambda path: path.write_bytes(b'fake screenshot')

    def test_p7_boundary_original_units_and_present_are_not_a_frame_fence(self):
        report = {'capabilities': {'renderer.present': '', 'surface.resize_timeout': 'ms'}}
        for index, elapsed in enumerate((15.9999, 16, 16.0001), 1):
            def resize(_width, _height):
                with self.instance.log.open('ab') as stream:
                    stream.write(b'info(gx_perf): metric renderer.present 1\r\ninfo(gx_perf): surface.resize_timeout 1us\r\n')
                return elapsed
            self.instance.resize.side_effect = resize
            actual = gx_perf.resize_evidence(self.gui, self.instance, self.root, index, 800, 600, report, self.backdrop)
            self.assertEqual(elapsed, actual)
            row = report['resizes'][-1]
            self.assertEqual(elapsed >= 16, row['proxy_timeout'])
            self.assertFalse(row['strict_final_frame'])
            self.assertEqual(1, row['surface_resize_timeout_events'])
            self.assertEqual([.001], row['presentation_metrics']['surface.resize_timeout']['values'])
            self.assertEqual('ms', row['presentation_metrics']['surface.resize_timeout']['unit'])
            self.assertTrue(row['target_size_matched'])
            self.assertTrue((self.root / f'resize-{index:02d}.png').is_file())
        self.assertTrue(report['resizes'][1]['log_start_byte'] == report['resizes'][0]['log_end_byte'])
        self.assertEqual(3, self.instance.resize.call_count)

    def test_p7_missing_counter_does_not_fabricate_zero(self):
        self.instance.resize.return_value = 10
        report = {}
        gx_perf.resize_evidence(self.gui, self.instance, self.root, 1, 800, 600, report, self.backdrop)
        self.assertIsNone(report['resizes'][0]['surface_resize_timeout_events'])
        self.assertEqual('not_instrumented', report['resizes'][0]['presentation_metrics']['renderer.present']['status'])

    def test_p7_capture_failure_keeps_sequence_dimensions_and_timing(self):
        self.instance.resize.return_value = 21
        self.backdrop.capture.side_effect = RuntimeError('covered')
        with self.assertRaisesRegex(RuntimeError, 'covered'):
            gx_perf.resize_evidence(self.gui, self.instance, self.root, 4, 800, 600, {}, self.backdrop)
        row = json.loads((self.root / 'resize-04.json').read_text(encoding='utf-8'))
        self.assertEqual(('failed', 4, 21, [800, 600]),
                         (row['status'], row['index'], row['setwindowpos_ms'], row['actual_outer_px']))

    def test_p7_truncated_log_and_unit_conflict_fail_with_raw_evidence(self):
        self.instance.resize.return_value = 5
        image = self.backdrop.capture.return_value
        def replace_log(*_args):
            self.instance.log.write_bytes(b'replaced\n')
            return image
        self.backdrop.capture.side_effect = replace_log
        with self.assertRaisesRegex(gx_perf.PerfError, 'truncated or replaced'):
            gx_perf.resize_evidence(self.gui, self.instance, self.root, 1, 800, 600, {}, self.backdrop)
        self.assertEqual('failed', json.loads((self.root / 'resize-01.json').read_text(encoding='utf-8'))['status'])
        self.backdrop.capture.side_effect = None
        with self.assertRaisesRegex(gx_perf.PerfError, 'unit conflict'):
            gx_perf.resize_evidence(self.gui, self.instance, self.root, 2, 800, 600,
                                   {'capabilities': {'surface.resize_timeout': ''}}, self.backdrop)

    def test_legacy_resizes_six_captures_every_operation(self):
        self.gui.launch.return_value = self.instance
        self.instance.wait_window.return_value = {'shown_ms': 1}
        self.gui.win32().child_windows.return_value = []
        self.instance.resize.return_value = 10
        def resize(width, height):
            self.gui.win32().raw_window_rect.return_value = (0, 0, width, height)
            self.instance.require_window.return_value.rect = (0, 0, width, height)
            return 10
        self.instance.resize.side_effect = resize
        report = {'evidence_dir': str(self.root / 'resize')}
        with mock.patch.object(gx_perf.time, 'sleep'), mock.patch.object(gx_perf, 'last_input_ticks', return_value=(1, 100)):
            lines = gx_perf.measure_win32(self.gui, self.root / 'ghostty.exe', self.root, '', 6, report=report)
        self.assertEqual(6, self.instance.resize.call_count)
        self.assertEqual(6, len(list((self.root / 'resize').glob('*.png'))))
        self.assertEqual(6, len([line for line in lines if line.startswith('metric resize.proxy_timeout')]))
        self.assertEqual(list(range(1, 7)), [row['index'] for row in report['resizes']])

    def test_c7_parser_matrix_requires_contract_and_no_observe_bypass(self):
        args = gx_perf.build_parser().parse_args(['win32-c7', '--exe', 'old', '--exe', 'new', '--out', 'out'])
        self.assertEqual(('matrix', 60, 10), (args.case, args.seconds, args.runs))
        self.assertTrue(gx_perf.desktop_command(['python', 'scripts/gx_perf.py', 'win32-c7', '--out', 'out']))
        with mock.patch.object(gx_perf, 'run_c7_matrix') as run, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, gx_perf.main(['win32-c7', '--exe', 'a', '--exe', 'b', '--out', 'out', '--seconds', '1']))
            run.assert_not_called()

    def test_c7_input_is_never_waived_and_hang_has_priority(self):
        args = SimpleNamespace(state='visible')
        with mock.patch.object(gx_perf, 'last_input_ticks', return_value=(11, 100)):
            with self.assertRaises(gx_perf.PerfError) as raised:
                gx_perf.c7_input_check(self.gui, self.instance, args, 10)
            self.assertEqual('foreign_input', raised.exception.cause)
            self.instance.hang_evidence.return_value = 'hung'
            with self.assertRaises(gx_perf.PerfError) as raised:
                gx_perf.c7_input_check(self.gui, self.instance, args, 10)
            self.assertEqual('instance_hung', raised.exception.cause)

    def test_matrix_product_failure_keeps_nested_arm_attribution(self):
        path = self.root / '11-output-wakeup' / 'new' / 'run-03' / 'run.json'
        gx_perf.write_json(path, {'pid': 42, 'label': 'new', 'run': 3, 'baseline': False})
        rows = [{'instance_pid': 42, 'cause': 'instance_gone'}]
        result = gx_perf.product_failure_runs(self.root, rows)
        self.assertEqual(('new', 3), (result[0]['label'], result[0]['run']))

    def test_c7_periodic_pdh_output_midpoint_and_raw_failure_preservation(self):
        import gx_perf_stimulus as stimulus
        from test_gx_perf_stimulus import pdh_sample
        self.instance.log.write_bytes(b'')
        capture = gx_perf.CaptureRun(self.instance, self.root,
                                    {'capabilities': {'renderer.present': ''}, 'errors': []})
        args = SimpleNamespace(case='output-wakeup', tabs=11, state='visible', seconds=60, output_bytes=4096,
                               endpoint_budget_ms=0)
        shells = mock.Mock()
        shells.python_identity = dict(executable="actual.exe", executable_sha256="a" * 64,
                                      launcher="launcher.exe", launcher_sha256="b" * 64)
        shells.identities = {42: 123, 43: 124}
        shells.rows.return_value = []
        shells.command.return_value = {'id': 'wakeup', 'bytes': 4096}
        shells.output_receipts.return_value = [{'pid': 42, 'written_bytes': 4096}, {'pid': 43, 'written_bytes': 4096}]
        before = {'pid': 42, 'birth': 123, 'kernel_100ns': 10, 'user_100ns': 20,
                  'begin_ns': 0, 'end_ns': 1, 'threads': []}
        after = {**before, 'kernel_100ns': 110, 'begin_ns': 60_000_000_001, 'end_ns': 60_000_000_002}
        counters = mock.Mock()
        counters.sample.side_effect = [before, after]
        clock, commands = [0.0], []
        endpoints = iter((before, after))
        counters.cpu_sample.side_effect = lambda _instance: dict(next(endpoints),
            begin_ns=round(clock[0] * 1e9), end_ns=round(clock[0] * 1e9))
        def command(*argv, **kwargs):
            commands.append(clock[0])
            return {'id': 'wakeup', 'bytes': 4096}
        shells.command.side_effect = command
        pdh = mock.Mock()
        pdh.prepare.return_value = {}
        sequence = [0]
        def collect():
            sequence[0] += 1
            return dict(sequence=sequence[0], collection_qpc_begin_ns=round(clock[0] * 1e9),
                        collection_qpc_end_ns=round(clock[0] * 1e9))
        pdh.capture.side_effect = collect
        pdh.read.side_effect = lambda token: dict(pdh_sample(int(clock[0]) + 10, round(clock[0] * 1e7) + 100), **token)
        with mock.patch.object(gx_perf, 'populate'), mock.patch.object(gx_perf, 'main_windows', return_value=[]), \
                mock.patch.object(gx_perf, 'last_input_ticks', return_value=(10, 100)), \
                mock.patch.object(gx_perf.time, 'sleep', side_effect=lambda n: clock.__setitem__(0, clock[0] + n)), \
                mock.patch.object(gx_perf.time, 'perf_counter', side_effect=lambda: clock[0]), \
                mock.patch.object(gx_perf.time, 'perf_counter_ns', side_effect=lambda: round(clock[0] * 1e9)):
            gx_perf.measure_c7(self.gui, self.instance, capture, args, counters, shells, pdh_factory=lambda: pdh)
        self.assertEqual(capture.report['c7']['shell_python'], 'actual.exe')
        self.assertEqual(capture.report['c7']['shell_python_sha256'], 'a' * 64)
        self.assertEqual(capture.report['c7']['shell_python_launcher'], 'launcher.exe')
        self.assertEqual(capture.report['c7']['shell_python_launcher_sha256'], 'b' * 64)
        self.assertEqual(61, pdh.capture.call_count)
        self.assertEqual('captured', capture.report['c7']['coverage'])
        self.assertEqual('valid', capture.report['c7']['timing']['status'])
        self.assertAlmostEqual(33.2, commands[0])
        self.assertEqual([60], capture.samples.values['threads.context_switches.pdh'])
        self.assertNotIn('threads.context_switches', capture.samples.values)
        self.assertEqual([8192], capture.samples.values['stimulus.output_bytes'])
        self.assertEqual(61, len(stimulus.read_rows(self.root / 'pdh-raw.jsonl')))
        pdh.close.assert_called_once()
        self.instance.press.assert_not_called()  # Output wakeup needs no injected desktop input.

    def test_c7_missing_os_counter_is_pending_without_synthetic_zero(self):
        import gx_perf_stimulus as stimulus
        capture = gx_perf.CaptureRun(self.instance, self.root, {'capabilities': {'renderer.present': ''}, 'errors': []})
        args = SimpleNamespace(case='visible', tabs=1, state='visible', seconds=2, output_bytes=4096)
        shells = mock.Mock()
        shells.python_identity = dict(executable="actual.exe", executable_sha256="a" * 64,
                                      launcher="launcher.exe", launcher_sha256="b" * 64)
        shells.identities, shells.rows.return_value = {42: 123}, []
        before = {'pid': 42, 'birth': 123, 'kernel_100ns': 0, 'user_100ns': 0,
                  'begin_ns': 0, 'end_ns': 1, 'threads': []}
        counters = mock.Mock()
        counters.sample.side_effect = [before, {**before, 'begin_ns': 2_000_000_001}]
        counters.cpu_sample = counters.sample
        clock = [0.0]
        with mock.patch.object(gx_perf, 'populate'), mock.patch.object(gx_perf, 'main_windows', return_value=[]), \
                mock.patch.object(gx_perf, 'last_input_ticks', return_value=(10, 100)), \
                mock.patch.object(gx_perf.time, 'sleep', side_effect=lambda n: clock.__setitem__(0, clock[0] + n)), \
                mock.patch.object(gx_perf.time, 'perf_counter', side_effect=lambda: clock[0]), \
                mock.patch.object(gx_perf.time, 'perf_counter_ns', side_effect=lambda: round(clock[0] * 1e9)):
            gx_perf.measure_c7(self.gui, self.instance, capture, args, counters, shells,
                               pdh_factory=mock.Mock(side_effect=stimulus.PdhFailure('add', 0xc0000bb9)))
        self.assertEqual('PENDING', capture.report['c7']['coverage'])
        self.assertEqual(0, capture.report['missing_metrics']['threads.context_switches.pdh']['n'])
        self.assertNotIn('threads.context_switches.pdh', capture.samples.values)
        self.assertIn('0xc0000bb9', capture.report['c7']['pdh']['reason'])

    def test_c7_slow_collection_and_incomplete_streams_never_become_formal_samples(self):
        from test_gx_perf_stimulus import pdh_sample
        for issue in ('none', 'slow-start', 'cross-deadline', 'late-periodic', 'cpu-skew', 'cpu-missing',
                      'pdh-missing', 'present-missing', 'thread-change', 'last-slot-sleep',
                      'last-slot-guard', 'slow-start-read'):
            with self.subTest(issue=issue):
                target = self.root / issue
                target.mkdir()
                self.instance.log.write_bytes(b'')
                capture = gx_perf.CaptureRun(self.instance, target, {
                    'capabilities': {} if issue == 'present-missing' else {'renderer.present': ''}, 'errors': []})
                slot_case = issue in ('last-slot-sleep', 'last-slot-guard', 'slow-start-read')
                args = SimpleNamespace(case='visible', tabs=1, state='visible', seconds=60 if slot_case else 2,
                                       diagnostic=False, endpoint_budget_ms=50 if slot_case else 0)
                clock, sequence, window_start = [0.0], [0], [None]
                shells = mock.Mock()
                shells.python_identity = dict(executable='python.exe', executable_sha256='a'*64,
                    launcher='python.exe', launcher_sha256='a'*64)
                shells.identities, shells.rows.return_value = {42: 123}, []
                counters = mock.Mock()
                def cpu(_instance):
                    if issue == 'cpu-missing':
                        raise OSError('CPU read unavailable')
                    t = round(clock[0] * 1e9)
                    return dict(pid=42, birth=123, kernel_100ns=round(clock[0]*10000), user_100ns=0,
                        begin_ns=t-1 if issue == 'cpu-skew' else t, end_ns=t, threads=[])
                counters.cpu_sample.side_effect = cpu
                pdh = mock.Mock()
                def prepare():
                    clock[0] += 8  # Expensive discovery MUST precede both endpoints.
                    return {'qpc_end_ns': round(clock[0]*1e9)}
                pdh.prepare.side_effect = prepare
                def collect():
                    if issue == 'pdh-missing':
                        return None
                    sequence[0] += 1
                    begin = round(clock[0]*1e9)
                    if sequence[0] == 1:
                        window_start[0] = clock[0]
                    if (issue == 'slow-start' and sequence[0] == 1 or
                            issue == 'cross-deadline' and sequence[0] == 2):
                        clock[0] += 8
                    if issue == 'late-periodic' and sequence[0] == 2:
                        clock[0] += 0.01  # Inside the window, outside its explicit 0 ms budget.
                    return dict(sequence=sequence[0], collection_qpc_begin_ns=begin,
                                collection_qpc_end_ns=round(clock[0]*1e9))
                pdh.capture.side_effect = collect
                def read(token):
                    row = dict(pdh_sample(sequence[0]*10, round(clock[0]*1e7),
                        tid=9 if issue == 'thread-change' and sequence[0] > 1 else 7), **token)
                    if issue == 'slow-start-read' and sequence[0] == 1:
                        clock[0] += 60.01
                    return row
                pdh.read.side_effect = read
                def sleep(seconds):
                    clock[0] += seconds
                    if issue == 'last-slot-sleep' and sequence[0] == 59:
                        clock[0] = window_start[0] + 60.01
                def input_ticks():
                    if (issue == 'last-slot-guard' and sequence[0] == 59 and
                            clock[0] >= window_start[0] + 59):
                        clock[0] = window_start[0] + 60.01
                    return 10, 100
                with mock.patch.object(gx_perf, 'populate'), mock.patch.object(gx_perf, 'main_windows', return_value=[]), \
                        mock.patch.object(gx_perf, 'last_input_ticks', side_effect=input_ticks), \
                        mock.patch.object(gx_perf.time, 'sleep', side_effect=sleep), \
                        mock.patch.object(gx_perf.time, 'perf_counter_ns', side_effect=lambda: round(clock[0]*1e9)):
                    if issue == 'none':
                        gx_perf.measure_c7(self.gui, self.instance, capture, args, counters, shells, lambda: pdh)
                        self.assertEqual('captured', capture.report['c7']['coverage'])
                        self.assertEqual(2_000_000_000, capture.report['c7']['timing']['pdh_timestamp_duration_ns'])
                    else:
                        with self.assertRaisesRegex(gx_perf.PerfError, 'coordinated counter window incomplete'):
                            gx_perf.measure_c7(self.gui, self.instance, capture, args, counters, shells, lambda: pdh)
                        self.assertEqual('PENDING', capture.report['c7']['coverage'])
                        for name in ('process.cpu', 'threads.context_switches.pdh', 'renderer.present'):
                            self.assertNotIn(name, capture.samples.values)
                    self.assertGreaterEqual(capture.report['c7']['counter_window_begin_qpc_ns'], 8_000_000_000)
                    pdh.prepare.assert_called_once()
                    pdh.close.assert_called_once()
                if issue == 'cross-deadline':
                    self.assertEqual(2, pdh.capture.call_count)  # No extra late collect or retry.
                    self.assertEqual(2, len((target/'pdh-raw.jsonl').read_text(encoding='utf-8').splitlines()))
                if issue in ('last-slot-sleep', 'last-slot-guard'):
                    timing = capture.report['c7']['timing']
                    self.assertIn('planned periodic slots', timing['reason'])
                    self.assertEqual(60, pdh.capture.call_count)  # 59th periodic slot missing, no catch-up.
                    self.assertLessEqual(timing['end']['end_ns'], timing['deadline_qpc_ns'] + 50_000_000)
                if issue == 'slow-start-read':
                    self.assertEqual(1, pdh.capture.call_count)

    def test_c7_classification_combinations_keep_control_and_stop_matrix(self):
        import gx_perf_stimulus as stimulus
        import gx_win_gui as real
        # Exercise the real measurement, experiment finalizer and matrix together.
        # Only OS boundaries, clocks and counters are replaced; no desktop is used.
        for outcome in ('commit', 'pending', 'success'):
            for teardown in (False, True):
                with self.subTest(outcome=outcome, teardown=teardown):
                    exe = self.root / 'ghostty.exe'
                    exe.write_bytes(b'fake executable')
                    out = self.root / f'{outcome}-{teardown}'
                    args = gx_perf.build_parser().parse_args([
                        'win32-c7', '--exe', str(exe), '--exe', str(exe),
                        '--out', str(out), '--runs', '2', '--diagnostic'])
                    args.seconds = 0  # Deterministic protocol test, never performance evidence.
                    self.gui.HARNESS_CONFIG = ''
                    self.gui.env_assignments = real.env_assignments
                    self.gui.GuiError = real.GuiError
                    self.instance.wait_window.return_value = {'shown_ms': 1}
                    self.instance.close.return_value = 'closed'
                    self.instance.input_events = []
                    self.instance.log.write_bytes(b'')
                    shells = mock.Mock()
                    shells.python_identity = dict(executable="actual.exe", executable_sha256="a" * 64,
                                                  launcher="launcher.exe", launcher_sha256="b" * 64)
                    shells.config.return_value = ''
                    shells.identities = {42: 123}
                    active = {'candidate': False, 'committed': False}
                    early = [{'event': 'input', 'pid': 42, 'text': 'n'}]
                    committed = [{'event': 'input', 'pid': 42, 'text': text} for text in '你好']
                    def launch(_exe, env_dir, **_kwargs):
                        active.update(candidate=env_dir.parent.parent.name == 'new', committed=False)
                        self.instance.press.reset_mock()
                        self.backdrop.teardown_failures.return_value = (
                            ['privacy backdrop teardown failed'] if active['candidate'] and teardown else [])
                        return self.instance
                    def press(key):
                        if key == 'space':
                            active['committed'] = True
                    def rows():
                        if active['candidate'] and outcome == 'commit' and self.instance.press.called:
                            return early
                        return committed if active['committed'] else []
                    def ime_state(*_args):
                        if active['candidate'] and outcome == 'pending':
                            return {'status': 'PENDING', 'reason': 'owned target is not zh-CN'}
                        return {'status': 'ready', 'layout': '0x00000804', 'open': 1, 'conversion': 1}
                    self.gui.launch.side_effect = launch
                    self.instance.press.side_effect = press
                    shells.rows.side_effect = rows
                    sample = {'pid': 42, 'birth': 123, 'kernel_100ns': 0, 'user_100ns': 0,
                              'begin_ns': 0, 'end_ns': 1, 'threads': []}
                    counters = mock.Mock()
                    def cpu_sample(_instance):
                        sample['begin_ns'] += 1_000_000
                        sample['end_ns'] += 1_000_000
                        return dict(sample)
                    counters.sample.side_effect = cpu_sample
                    counters.cpu_sample = counters.sample
                    pdh = mock.Mock()
                    pdh.prepare.return_value = {}
                    pdh.capture.return_value = None
                    experiment = gx_perf.run_experiment
                    def run(cell):
                        return experiment(cell, self.gui, counters_factory=lambda _gui: counters)
                    with mock.patch.object(stimulus, 'CASES', ('ime-preedit', 'visible')), \
                            mock.patch.object(stimulus, 'ANIMATION_CASES', ()), \
                            mock.patch.object(stimulus, 'OwnedShells', return_value=shells), \
                            mock.patch.object(stimulus, 'ime_state', side_effect=ime_state), \
                            mock.patch.object(stimulus, 'PdhThreads', return_value=pdh) as native_pdh, \
                            mock.patch.object(stimulus, 'pdh_summary', return_value={'status': 'sampled', 'switches': 0}), \
                            mock.patch.object(gx_perf, 'populate'), \
                            mock.patch.object(gx_perf, 'main_windows', return_value=[]), \
                            mock.patch.object(gx_perf, 'idle_state_entry', return_value={}), \
                            mock.patch.object(gx_perf, 'last_input_ticks', return_value=(10, 100)), \
                            mock.patch.object(gx_perf.time, 'sleep'), \
                            mock.patch.object(gx_perf, 'run_experiment', side_effect=run), \
                            contextlib.redirect_stdout(io.StringIO()):
                        code = gx_perf.run_c7_matrix(args)
                    self.assertTrue(native_pdh.call_args_list)
                    self.assertTrue(all(call == mock.call(pid=self.instance.pid)
                                        for call in native_pdh.call_args_list))
                    matrix = gx_perf.read_json(out / 'RESULT.json')
                    cell = gx_perf.read_json(out / '1-ime-preedit/RESULT.json')
                    control = gx_perf.read_json(out / '1-ime-preedit/old/run-01/run.json')
                    self.assertEqual('completed', control['status'], control['errors'])
                    candidate = gx_perf.read_json(out / '1-ime-preedit/new/run-01/run.json')
                    fatal = outcome == 'commit' or teardown
                    pending = outcome == 'pending' and not teardown
                    self.assertEqual('completed', control['status'])
                    self.assertEqual('你好', control['c7']['ime']['commit_text'])
                    self.assertTrue((out / '1-ime-preedit/old/run-01/samples.txt').is_file())
                    self.assertEqual('failed' if fatal else 'pending' if pending else 'completed', candidate['status'])
                    self.assertEqual(pending, candidate.get('environment_pending', False))
                    self.assertEqual(pending, cell['environment_pending'])
                    self.assertEqual(pending, matrix['cells'][0]['environment_pending'])
                    self.assertEqual(1 if fatal else 4, matrix['completed_cells'])
                    self.assertEqual('1-ime-preedit' if fatal else None, matrix.get('stopped_after_failure'))
                    self.assertEqual(1 if fatal or pending else 0, code)
                    self.assertEqual(2 if fatal or pending else 4, len(cell['runs']))
                    if outcome == 'commit':
                        self.assertEqual(early, candidate['c7']['ime']['before_input'])
                        self.assertTrue(any('instead of holding preedit' in e for e in candidate['errors']))
                    if outcome == 'pending':
                        self.assertIn('owned target is not zh-CN', candidate['errors'])
                        self.assertNotIn('before_input', candidate['c7']['ime'])
                    if teardown:
                        self.assertIn('privacy backdrop teardown failed', candidate['errors'])

    def test_matrix_keeps_all_twelve_cells_and_stops_only_on_non_environment_failure(self):
        args = gx_perf.build_parser().parse_args(['win32-c7', '--exe', 'old', '--exe', 'new', '--out', str(self.root / 'matrix')])
        calls = []
        def run(cell):
            calls.append((cell.tabs, cell.case))
            cell.out.mkdir()
            pending = cell.case == 'ime-preedit'
            gx_perf.write_json(cell.out / 'RESULT.json', {'valid': not pending, 'environment_pending': pending})
            return int(pending)
        with mock.patch.object(gx_perf, 'run_experiment', side_effect=run):
            self.assertEqual(1, gx_perf.run_c7_matrix(args))
        self.assertEqual(16, len(calls))
        self.assertEqual(2, sum(case == 'ime-preedit' for _, case in calls))
        args.out = self.root / 'matrix-fail'
        def failed(cell):
            cell.out.mkdir()
            gx_perf.write_json(cell.out / 'RESULT.json', {'valid': False, 'environment_pending': False})
            return 1
        with mock.patch.object(gx_perf, 'run_experiment', side_effect=failed) as measured:
            self.assertEqual(1, gx_perf.run_c7_matrix(args))
        self.assertEqual(1, measured.call_count)


class EncodingGuardTests(unittest.TestCase):
    """Text files these tools write hold non-ASCII reasons; with Python's UTF-8 mode off (cp936 on a
    Chinese Windows host) any read or write that leaves the encoding to the locale breaks."""

    FILES = ("gx_perf.py", "gx_slots.py", "gx_win_gui.py", "test_gx_perf.py", "test_gx_slots.py",
             "test_gx_win_gui.py")

    @staticmethod
    def unnamed_encodings(source: str):
        def keyword(call, name):
            return next((item.value for item in call.keywords if item.arg == name), None)

        for node in ast.walk(ast.parse(source)):
            if not isinstance(node, ast.Call) or keyword(node, "encoding") is not None:
                continue
            func = node.func
            name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", "")
            if name in ("read_text", "write_text"):
                yield node.lineno, f"{name}()"
            elif name == "open" and not (isinstance(func, ast.Attribute) and getattr(func.value, "id", "") == "os"):
                position = 0 if isinstance(func, ast.Attribute) else 1
                mode = keyword(node, "mode") or (node.args[position] if len(node.args) > position else None)
                # A mode that is not a string constant (window.open(area)) is not a text file.
                text = "r" if mode is None else (mode.value if isinstance(mode, ast.Constant) else None)
                if isinstance(text, str) and "b" not in text:
                    yield node.lineno, f"open(mode={text!r})"
            elif name in ("run", "check_output", "check_call", "call", "Popen"):
                flag = keyword(node, "text") or keyword(node, "universal_newlines")
                if isinstance(flag, ast.Constant) and flag.value is True:
                    yield node.lineno, f"subprocess.{name}(text=True)"

    def test_every_text_read_and_write_names_its_encoding(self):
        for name in self.FILES:
            with self.subTest(file=name):
                found = list(self.unnamed_encodings((SCRIPTS / name).read_text(encoding="utf-8")))
                self.assertEqual([], found, f"{name}: give these an explicit encoding")

    def test_the_guard_sees_what_the_locale_would_decode(self):
        source = ("p.read_text()\np.write_text(t)\nopen(p)\nopen(p, 'a')\np.open()\np.open('w')\n"
                  "subprocess.run(a, text=True)\n"
                  "p.read_text(encoding='utf-8')\nopen(p, 'rb')\np.open('ab')\nos.open(p, 1)\nwindow.open(area)\n"
                  "subprocess.run(a, text=True, encoding='utf-8')\n")
        self.assertEqual([1, 2, 3, 4, 5, 6, 7], [line for line, _ in self.unnamed_encodings(source)])


class GtkWiringTests(unittest.TestCase):
    def test_cases_delegate_only_to_gtk_module(self):
        import gx_perf_gtk
        import gx_wsl
        for case in ('p2', 'p4'):
            with mock.patch.object(gx_perf_gtk, 'run', return_value=4) as driver, \
                    mock.patch.object(gx_wsl, 'main') as standard:
                self.assertEqual(4, gx_perf.main(['gtk', '--clone', '/clone', '--out', 'M', '--case', case,
                                                  '--capabilities', 'build:identity.json']))
                self.assertEqual(case, driver.call_args.args[0].case)
                self.assertEqual(['build:identity.json'], driver.call_args.args[0].capabilities)
                standard.assert_not_called()

    def test_default_and_explicit_standard_keep_smoke_perf_argv(self):
        import gx_perf_gtk
        import gx_wsl
        with tempfile.TemporaryDirectory() as tmp:
            commands = []
            for index, extra in enumerate(([], ['--case', 'standard'])):
                target = Path(tmp) / str(index)
                with mock.patch.object(gx_wsl, 'main', return_value=0) as smoke, \
                        mock.patch.object(gx_perf, 'report_gtk_runs', return_value=0), \
                        mock.patch.object(gx_perf_gtk, 'run') as actions, contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(0, gx_perf.main(['gtk', '--clone', '/frozen', '--out', str(target),
                                                      '--runs', '2', '--env', 'GSK_RENDERER=cairo', *extra]))
                    actions.assert_not_called()
                calls = [list(call.args[0]) for call in smoke.call_args_list]
                for call in calls:
                    self.assertIn('--perf', call)
                    call[call.index('--out') + 1] = 'OUT'
                commands.append(calls)
            self.assertEqual(commands[0], commands[1])
            self.assertEqual(2, len(commands[0]))

    def test_invalid_case_rejected_before_driver_and_capabilities_not_ignored(self):
        import gx_perf_gtk
        with mock.patch.object(gx_perf_gtk, 'run') as driver, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, gx_perf.main(['gtk', '--clone', '/c', '--out', 'M', '--case=win32']))
            self.assertEqual(2, gx_perf.main(['gtk', '--clone', '/c', '--out', 'M',
                                             '--capabilities', 'build:identity.json']))
            driver.assert_not_called()




class P7StrictWiringTests(unittest.TestCase):
    def test_same_prefix_file_replacement_after_freeze_fails_closed(self):
        import gx_perf_stimulus as stimulus
        from test_gx_perf_stimulus import PresentFixture
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture = PresentFixture()
            fixture.instance.log = root/'ghostty.log'
            original = b'info(gx_perf): metric renderer.present 1\r\n'
            fixture.instance.log.write_bytes(original)
            def capture(gui, instance, width, height, png, backdrop, raw, **kwargs):
                raw.update(status='PASS', strict_final_frame=True, screenshot=str(png),
                           screenshot_sha256='fixture', snapshots=[{'geometry':{'outer':[0,0,900,650]}}])
                return 16.0
            parse = gx_perf.arm_samples
            calls = []
            def replace(text, baseline):
                calls.append(text)
                if len(calls) == 2:
                    other = root/'replacement.log'
                    other.write_bytes(original)
                    other.replace(fixture.instance.log)
                return parse(text, baseline)
            with mock.patch.object(stimulus, 'strict_resize_capture', capture), \
                    mock.patch.object(gx_perf, 'arm_samples', replace):
                with self.assertRaisesRegex(gx_perf.PerfError, 'file identity'):
                    gx_perf.resize_evidence(fixture.gui, fixture.instance, root, 1, 900, 650, {}, fixture.backdrop)
            row = json.loads((root/'resize-01.json').read_text(encoding='utf-8'))
            self.assertFalse(row['strict_final_frame'])
            self.assertEqual('FAIL', row['strict_frame_evidence']['status'])
            self.assertEqual(b'', (root/'resize-01.segment.raw').read_bytes())
            self.assertEqual(original, (root/'resize-01.failure-log.raw').read_bytes())

    def test_bounded_wiring_keeps_input_epoch_and_recovers_timeout_queries(self):
        import gx_perf_stimulus as stimulus
        for mode in ('timeout', 'input', 'success'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                report = {'evidence_dir': str(out), 'worker_entry_input_tick': 123}
                def supervise(command, directory, **kwargs):
                    request = json.loads((directory/'worker-request.json').read_text(encoding='utf-8'))
                    self.assertEqual(123, request['report']['worker_entry_input_tick'])
                    self.assertEqual(120.0, kwargs['timeout'])
                    stimulus.durable_json(directory/'supervisor.json', {'status':'FAIL' if mode == 'timeout' else 'PASS'})
                    if mode == 'timeout':
                        stimulus.durable_json(directory/'resize-01.json', {'index':1,'status':'running'})
                        stimulus.durable_json(directory/'resize-01.before_capture.query.json',
                            {'queries':[{'qpc_ns':42, 'answer':123}], 'status':'running'})
                        raise stimulus.StrictFrameError('P7 worker timeout')
                    result = {'status':'PASS', 'report':{'resize_input_tick':123}, 'lines':['metric fixture 1']}
                    stimulus.durable_json(directory/'worker-result.json', result)
                with mock.patch.object(stimulus, 'supervise_p7', supervise), \
                        mock.patch.object(gx_perf, 'last_input_ticks', return_value=(456 if mode=='input' else 123,1000)):
                    if mode == 'success':
                        self.assertEqual(['metric fixture 1'], gx_perf.measure_win32_bounded(
                            out/'app.exe', out, '', 6, {}, report))
                    else:
                        with self.assertRaises((stimulus.StrictFrameError, gx_perf.PerfError)):
                            gx_perf.measure_win32_bounded(out/'app.exe', out, '', 6, {}, report)
                        self.assertFalse(report['strict_final_frame'])
                if mode == 'timeout':
                    row = json.loads((out/'resize-01.worker-failure.json').read_text(encoding='utf-8'))
                    self.assertEqual(123, row['strict_frame_evidence']['queries'][0]['answer'])
                    self.assertEqual('FAIL', row['strict_frame_evidence']['status'])
                    self.assertTrue((out/'resize-01.before_capture.query.json').exists())

    def test_third_log_read_cannot_replace_frozen_metric_bytes(self):
        import gx_perf_stimulus as stimulus
        from test_gx_perf_stimulus import PresentFixture
        for mode in ('append', 'truncate', 'replace'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                fixture = PresentFixture()
                fixture.instance.log = root / 'ghostty.log'
                before = b'initial\r\n'
                segment = b'info(gx_perf): metric renderer.present 1\r\n'
                frozen = before + segment
                fixture.instance.log.write_bytes(before)
                original_read = Path.read_bytes
                reads = []
                def read(path):
                    if path != fixture.instance.log:
                        return original_read(path)
                    reads.append(path)
                    if len(reads) == 1:
                        return before
                    if len(reads) == 2:
                        return frozen
                    return (frozen + b'info(gx_perf): metric renderer.present 2\r\n'
                            if mode == 'append' else frozen[:-5] if mode == 'truncate' else b'replaced')
                def capture(gui, instance, width, height, png, backdrop, raw, **kwargs):
                    raw.update(status='PASS', strict_final_frame=True, screenshot=str(png),
                               screenshot_sha256='fixture', snapshots=[{'geometry':{'outer':[0,0,900,650]}}])
                    return 16.0
                report = {}
                with mock.patch.object(Path, 'read_bytes', read), \
                        mock.patch.object(stimulus, 'strict_resize_capture', capture):
                    if mode == 'append':
                        gx_perf.resize_evidence(fixture.gui, fixture.instance, root, 1, 900, 650, report, fixture.backdrop)
                    else:
                        with self.assertRaisesRegex(gx_perf.PerfError, 'truncated|replaced'):
                            gx_perf.resize_evidence(fixture.gui, fixture.instance, root, 1, 900, 650, report, fixture.backdrop)
                row = json.loads((root/'resize-01.json').read_text(encoding='utf-8'))
                self.assertEqual(segment, (root/'resize-01.segment.raw').read_bytes())
                self.assertEqual(len(frozen), row['log_end_byte'])
                self.assertEqual([1.0], row['presentation_metrics']['renderer.present']['values'])
                self.assertEqual('captured' if mode == 'append' else 'failed', row['status'])
                if mode != 'append':
                    self.assertFalse(row['strict_final_frame'])
                    self.assertTrue((root/'resize-01.failure-log.raw').exists())

    def test_native_query_success_pending_and_deadline_evidence_on_disk(self):
        import gx_perf_stimulus as stimulus
        from test_gx_perf_stimulus import PresentFixture
        for mode in ('success', 'legacy', 'failedpresent'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                fixture = PresentFixture(count=2)
                fixture.instance.log = root / 'ghostty.log'
                fixture.instance.log.write_bytes(b'initial\r\n')
                if mode == 'legacy':
                    fixture.absent = True
                if mode == 'failedpresent':
                    fixture.change = lambda stage: setattr(fixture, 'sequence', 10)
                original_resize = fixture.resize
                def resize(width, height):
                    with fixture.instance.log.open('ab') as stream:
                        stream.write(b'preserved timeout bytes\r\n')
                    return original_resize(width, height)
                fixture.instance.resize.side_effect = resize
                original = stimulus.PresentQuery.snapshot
                def snapshot(probe, stage, deadline):
                    fixture.stage(stage)
                    return original(probe, stage, deadline)
                clock = [0.0]
                def now():
                    clock[0] += 0.0005
                    return clock[0]
                report = {}
                with mock.patch.object(stimulus.PresentQuery, 'snapshot', snapshot), \
                        mock.patch.object(stimulus, 'dwm_flush'), \
                        mock.patch.object(stimulus.time, 'perf_counter', side_effect=now), \
                        mock.patch.object(stimulus.time, 'sleep'):
                    if mode == 'failedpresent':
                        with self.assertRaisesRegex(stimulus.StrictFrameError, 'strict_final_frame_timeout'):
                            gx_perf.resize_evidence(fixture.gui, fixture.instance, root, 1, 900, 650, report, fixture.backdrop)
                    else:
                        gx_perf.resize_evidence(fixture.gui, fixture.instance, root, 1, 900, 650, report, fixture.backdrop)
                row = json.loads((root/'resize-01.json').read_text(encoding='utf-8'))
                strict = row['strict_frame_evidence']
                self.assertEqual({'success':'PASS','legacy':'PENDING','failedpresent':'FAIL'}[mode], strict['status'])
                self.assertEqual(mode == 'success', row['strict_final_frame'])
                self.assertEqual(16.0, row['setwindowpos_ms'])
                self.assertTrue(row['proxy_timeout'])
                self.assertTrue(strict['queries'])
                self.assertEqual(b'preserved timeout bytes\r\n', (root/'resize-01.segment.raw').read_bytes())
                self.assertEqual(mode != 'failedpresent', (root/'resize-01.png').exists())


if __name__ == "__main__":
    unittest.main()
