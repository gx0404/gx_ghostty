#!/usr/bin/env python3
"""Tests for scripts/gx_perf.py: sample parsing, statistics, tables, alternation and the commands
that only read files. The measurement commands (win32, gtk) need a desktop or WSL and are not run.
"""

from __future__ import annotations

import contextlib
import ctypes
import io
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
        self.probe.windows.return_value = [{'pid': 10, 'name': 'ghostty', 'title': 'test'}]
        self.probe.wsl.return_value = {'running': False, 'processes': []}
        self.probe.vm.return_value = {'win11': {'exists': True, 'owned': True, 'running': False}}
        self.probe.slots.return_value = True
        self.probe.idle.return_value = 600
        self.probe.session.return_value = {'interactive_console': True, 'process_session': 1, 'active_console_session': 1}
        self.probe.cpu.return_value = {'cpu': 100, 'top': []}

    def test_cpu_is_not_a_gate_and_threshold_is_inclusive(self):
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual(0, result['exit'])
        self.assertTrue(result['quiet'])
        self.probe.cpu.side_effect = OSError('PDH missing')
        self.assertEqual(0, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])

    def test_each_gate_and_probe_error_fail_closed(self):
        for method, value in [('windows', [{'pid': 1, 'name': 'ZiG.ExE'}]),
                              ('windows', [{'pid': 1, 'name': 'app', 'title': 'Kimi Code'}]),
                              ('wsl', {'processes': [{'pid': 2, 'name': 'cc1plus'}]}),
                              ('vm', {'win11': {'running': True}}), ('slots', False), ('idle', 599.9)]:
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
        self.probe.idle.side_effect = [20, 600]
        sleeper = mock.Mock()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.run_quiet(self.args, self.probe, sleeper))
        sleeper.assert_called_once_with(900)
        paths = sorted(self.args.out.glob('attempt-*.json'))
        self.assertEqual([3, 0], [json.loads(p.read_text())['exit'] for p in paths])
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
        self.probe.windows.return_value = [{'pid': 5, 'name': 'app', 'title': None},
                                          {'pid': 6, 'name': 'browser', 'title': 'private ToDesk title'}]
        self.args.idle_seconds = 5
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertFalse(result['plan_compliant'])
        self.assertNotIn('private', json.dumps(result))
        self.assertEqual(['todesk'], result['checks']['blacklist']['raw'][0]['matches'])
        self.probe.session.return_value = {'interactive_console': False}
        self.assertEqual(2, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])

    def test_probe_unexpected_exception_is_recorded(self):
        self.probe.windows.side_effect = AttributeError('unexpected')
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual(2, result['exit'])
        self.assertEqual('error', result['checks']['windows']['status'])


class QuietBatchTests(unittest.TestCase):
    setUp = QuietTests.setUp
    def batch_args(self, *extra):
        import gx_slots
        with gx_slots.acquire(self.args.slot_root, 'quiet'):
            pass
        return gx_perf.build_parser().parse_args(['quiet-batch', '--out', str(self.args.out),
            '--slot-root', str(self.args.slot_root), *extra, '--', 'dummy-command'])

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
        self.probe.idle.assert_called_once()
        for name in ('before', 'after'):
            data = json.loads((args.out / (name+'.json')).read_text())
            self.assertEqual('all four locks held by this batch', data['checks']['slots']['reason'])

    def test_before_busy_never_runs_command_and_after_busy_invalidates(self):
        args = self.batch_args()
        self.probe.idle.return_value = 5
        runner = mock.Mock(return_value=SimpleNamespace(returncode=0))
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(3, gx_perf.run_quiet_batch(args, self.probe, runner))
        runner.assert_not_called()
        args.out = args.out.parent / 'second'
        self.probe.idle.side_effect = [600, 5]
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(3, gx_perf.run_quiet_batch(args, self.probe, runner))
        result = json.loads((args.out/'RESULT.json').read_text())
        self.assertEqual('INVALID', result['status'])
        self.assertFalse(result['batch_valid'])

    def test_missing_or_failed_guards_and_command_exception_are_invalid(self):
        args = self.batch_args('--injected-input')
        for index, failure in enumerate(('missing', 'failed', 'exception')):
            args.out = self.args.out.parent / f'bad-{index}'
            def runner(command, **kwargs):
                if failure == 'exception':
                    raise RuntimeError('child setup')
                if failure == 'failed':
                    row = {'schema': 'gx-input-guard-v1', 'batch_id': kwargs['env']['GX_PERF_BATCH_ID'], 'event': 'guard', 'status': 'fail'}
                    Path(kwargs['env']['GX_PERF_GUARD_LOG']).write_text(json.dumps(row)+'\n')
                return SimpleNamespace(returncode=0)
            with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
                self.assertNotEqual(0, gx_perf.run_quiet_batch(args, self.probe, runner))
            self.assertEqual('INVALID', json.loads((args.out/'RESULT.json').read_text())['status'])


class CounterTests(unittest.TestCase):
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
        with self.assertRaisesRegex(gx_perf.PerfError, 'population'):
            gx_perf.idle_delta(before, after)

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

    def test_legacy_win32_guard_failure_is_not_retried(self):
        import gx_win_gui as gui
        out = self.root / 'legacy'
        calls = []
        def measure(*args):
            calls.append(args)
            log = gui.log_path(args[2])
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text('raw failure evidence\n', encoding='utf-8')
            if len(calls) == 1:
                return ['metric startup.shown 1 ms']
            raise gui.InputBlocked('foreground changed')
        with mock.patch.object(gx_perf, 'measure_win32', side_effect=measure), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = gx_perf.main(['win32', '--exe', str(self.exe), '--out', str(out), '--runs', '1'])
        self.assertEqual(1, code)
        self.assertEqual(2, len(calls))
        self.assertEqual('raw failure evidence\n', (out / 'build/run-01.log').read_text())

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
        args = self.args('win32-ui', '--exe', str(self.exe), '--runs', '2', '--label-env', 'new:TEST=1')
        gui = self.fake_gui()
        def measure(_, instance, capture, args):
            capture.add('palette.open.total', 2, 'ms')
        with mock.patch.object(gx_perf, 'measure_ui', side_effect=measure), mock.patch.object(gx_perf.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.run_experiment(args, gui))
        batch = json.loads((args.out / 'RESULT.json').read_text())
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
        run = json.loads((args.out / 'build/run-01/run.json').read_text())
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
                log.write(f'info(gx_perf): {name}.open.total {[900000, 1000, 3000, 2000][n]}us\n')
                log.write('info(gx_perf): metric profiles.path_scan 1\n')
            return mock.Mock()
        with mock.patch.object(gx_perf, 'open_ui', side_effect=opened), mock.patch.object(gx_perf, 'close_ui'), mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.measure_ui(mock.Mock(), instance, capture, self.args())
        for name in ('palette', 'menu', 'settings'):
            self.assertEqual([2], capture.samples.values[name + '.open.total'])
            self.assertEqual([3], capture.samples.values[name + '.profiles.path_scan'])
        self.assertEqual({'palette': 4, 'menu': 4, 'settings': 4}, counts)

    def test_resource_measurement_reports_commit_per_added_thread(self):
        args = self.args('win32-mem')
        counters = mock.Mock()
        counters.sample.side_effect = [dict(private_bytes=100, thread_count=4), dict(private_bytes=500, thread_count=14)]
        instance, gui = mock.Mock(), mock.Mock()
        capture = gx_perf.CaptureRun(instance, self.root, {})
        with mock.patch.object(gx_perf, 'wait_until', return_value=True), mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.measure_resources(gui, instance, capture, args, counters)
        self.assertEqual([40], capture.samples.values['process.commit.per_added_thread'])
        self.assertEqual(10, instance.press.call_count)

    def test_gpu_keeps_last_gauge_and_dedicated_bytes_per_terminal(self):
        counters, instance = mock.Mock(), mock.Mock()
        counters.sample.side_effect = [dict(private_bytes=100, thread_count=4), dict(private_bytes=500, thread_count=14)]
        counters.gpu.side_effect = [dict(dedicated_bytes=1024), dict(dedicated_bytes=11264)]
        instance.log_text.return_value = 'info(gx_perf): metric renderer.targets_live 2\ninfo(gx_perf): metric renderer.targets_live 22\n'
        capture = gx_perf.CaptureRun(instance, self.root, {})
        with mock.patch.object(gx_perf, 'wait_until', return_value=True), mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.measure_resources(mock.Mock(), instance, capture, self.args('win32-gpu'), counters)
        self.assertEqual([1024], capture.samples.values['gpu.dedicated.per_added_terminal'])
        self.assertEqual([22], capture.samples.values['renderer.targets_live.11'])

    def test_idle_interval_excludes_setup_events_and_records_cpu(self):
        instance, gui, counters = mock.Mock(), mock.Mock(), mock.Mock()
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
                with instance.log.open('a') as stream:
                    stream.write('info(gx_perf): metric proc.snapshot 2\ninfo(gx_perf): metric renderer.present 4\n')
        with mock.patch.object(gx_perf.time, 'sleep', side_effect=sleep):
            gx_perf.idle_interval(gui, instance, capture, self.args('win32-idle'), counters)
        self.assertEqual([2], capture.samples.values['proc.snapshot'])
        self.assertEqual([2], capture.samples.values['process.cpu'])
        self.assertEqual([10], capture.samples.values['threads.context_switches'])

    def test_p3_drags_real_caption_and_p6_holds_key_at_30hz(self):
        gui, instance, capture = mock.Mock(), mock.Mock(), mock.Mock()
        old = SimpleNamespace(hwnd=10, rect=(0, 0, 800, 600))
        new = SimpleNamespace(hwnd=10, rect=(100, 50, 900, 650))
        gui.win32.return_value.foreground.return_value = 10
        instance.scale.return_value = 1
        instance.caption_point.return_value = (500, 20)
        with mock.patch.object(gx_perf, 'populate') as populate, mock.patch.object(gx_perf, 'main_windows', side_effect=[[old], [new]]), mock.patch.object(gx_perf.time, 'sleep'):
            args = self.args()
            args.case = 'p3'
            gx_perf.measure_ui(gui, instance, capture, args)
        populate.assert_called_once_with(gui, instance, 15, 3)
        instance.drag.assert_called_once_with((500, 20), (620, 60), steps=60, step_delay=2/60)
        instance.uia_rows.return_value = [{'type': 'ControlType.ListItem'}]
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui'), mock.patch.object(gx_perf.time, 'sleep'):
            args.case = 'p6'
            gx_perf.measure_ui(gui, instance, capture, args)
        instance.hold_key.assert_called_once_with('down', seconds=2, hz=30)
        instance.press.assert_called_with('ctrl+pagedown')

    def test_p5_sweeps_overlapping_pages_until_viewport_stops(self):
        import gx_win_gui as gui
        instance, capture, backend = mock.Mock(), mock.Mock(), mock.Mock()
        backend.client_rect.return_value = (0, 0, 400, 220)
        instance.scale.return_value = 1
        image = gui.Image(400, 220, bytes(400 * 220 * 4))
        instance.capture_window.return_value = image
        capture.window.return_value = 'info(gx_perf): keybinds.paint 400us\n'
        capture.report = {}
        args = self.args()
        args.case = 'p5'
        with mock.patch.object(gui, 'win32', return_value=backend), mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf, 'close_ui'), mock.patch.object(gx_perf.time, 'sleep'):
            gx_perf.measure_ui(gui, instance, capture, args)
        self.assertEqual(1, instance.wheel.call_count)
        self.assertGreater(instance.mouse.call_count, 10)
        self.assertEqual(1, len(capture.report['frames']))

    def test_remote_accepts_unknown_remote_names_and_ignores_other_metrics(self):
        log = self.root / 'remote.log'
        log.write_text('info(gx_perf): metric remote.frame_bytes 100\ninfo(gx_perf): remote.future 200us\n'
                       'info(gx_perf): other 1us\ninfo(gx_perf): metric other 4\n', encoding='utf-8')
        out = self.root / 'remote'
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, gx_perf.main(['remote', str(log), '--out', str(out)]))
        report = json.loads((out / 'RESULT.json').read_text())['metrics']
        self.assertEqual({'remote.frame_bytes', 'remote.future'}, set(report))
        self.assertEqual(100, report['remote.frame_bytes']['sum'])
        self.assertEqual(.2, report['remote.future']['median'])


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
