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


def ticks(idle_seconds: float, now: int = 50_000_000) -> dict:
    """A fake QuietProbe.input_ticks() result with the given idle time."""
    return {'last_input_tick': (now - round(idle_seconds * 1000)) & 0xFFFFFFFF, 'tick_count': now & 0xFFFFFFFF}


def windows_data(*rows) -> dict:
    """A fake QuietProbe.windows() result: Win32_Process plus Get-Process rows."""
    cim = [{'pid': row['pid'], 'ppid': row.get('ppid', 0), 'name': row['name'], 'created': row.get('created', 1),
            'command_line': row.get('command_line')} for row in rows]
    processes = [{'pid': row['pid'], 'name': row['name'], 'title': row.get('title')} for row in rows]
    return {'inventory_pid': None, 'cim': cim, 'processes': processes}


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
        for method, value in [('windows', windows_data({'pid': 1, 'name': 'ZiG.ExE'})),
                              ('windows', windows_data({'pid': 1, 'name': 'app', 'title': 'Kimi Code'})),
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
        self.probe.windows.return_value = windows_data({'pid': 5, 'name': 'app', 'title': None},
                                                       {'pid': 6, 'name': 'browser', 'title': 'private ToDesk title'})
        self.args.idle_seconds = 5
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertFalse(result['plan_compliant'])
        self.assertFalse(result['thresholds_plan_compliant'])
        self.assertNotIn('private', json.dumps(result))
        self.assertEqual(['ToDesk'], result['checks']['blacklist']['raw'][0]['matches'])
        self.probe.session.return_value = {'interactive_console': False}
        self.assertEqual(2, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])

    def test_blacklist_is_the_exact_plan_list_and_kimi_cu_is_only_observed(self):
        self.assertEqual(('Devin', 'devin', 'ToDesk', 'Kimi Code', '哔哩哔哩'), gx_perf.BLACKLIST)
        rows = [{'pid': 1, 'name': 'kimi-cu.exe', 'title': 'kimi-cu'}, {'pid': 2, 'name': 'todesk-lookalike', 'title': 'KIMI CODE'},
                {'pid': 3, 'name': 'devin', 'title': ''}, {'pid': 4, 'name': 'Kimi Code.exe', 'title': ''},
                {'pid': 5, 'name': 'player', 'title': '哔哩哔哩 (゜-゜)つロ'}]
        self.probe.windows.return_value = windows_data(*rows)
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual({3: ['devin'], 4: ['Kimi Code'], 5: ['哔哩哔哩']},
                         {row['pid']: row['matches'] for row in result['checks']['blacklist']['raw']})
        self.assertEqual('recorded', result['other_programs']['status'])
        self.assertEqual([1], [row['pid'] for row in result['other_programs']['matches']])
        self.assertNotIn('つロ', gx_perf.json.dumps(result, ensure_ascii=False))
        self.probe.windows.return_value = windows_data(rows[0], rows[1])
        result = gx_perf.quiet_snapshot(self.args, self.probe)
        self.assertEqual(0, result['exit'])
        self.assertEqual([1], [row['pid'] for row in result['other_programs']['matches']])
        self.args.blacklist = ['kimi-cu']
        self.assertEqual(3, gx_perf.quiet_snapshot(self.args, self.probe)['exit'])

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
        # The exemption hides only the runner command lines: an ancestor's build name and blacklist name still count.
        self.assertEqual('fail', windows['status'])
        self.assertIn('[60]', windows['reason'])
        self.assertEqual('fail', result['checks']['blacklist']['status'])
        self.assertEqual([50], [row['pid'] for row in result['checks']['blacklist']['raw']])
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
        self.probe.input_ticks.assert_called_once()
        for name in ('before', 'after'):
            data = json.loads((args.out / (name+'.json')).read_text())
            self.assertEqual('all four locks held by this batch', data['checks']['slots']['reason'])
        result = json.loads((args.out / 'RESULT.json').read_text())
        self.assertEqual(('gx-quiet-batch-v2', 'VALID', 'VALID', 'COMPLETE', True, True),
                         (result['schema'], result['status'], result['quiet_status'], result['measurement'],
                          result['quiet_valid'], result['plan_compliant']))
        self.assertTrue((args.out / 'SUMMARY.txt').read_text().startswith('VALID exit=0 quiet=VALID measurement=COMPLETE'))

    def test_before_busy_never_runs_command_and_after_busy_invalidates(self):
        args = self.batch_args()
        self.probe.input_ticks.return_value = ticks(5)
        runner = mock.Mock(return_value=SimpleNamespace(returncode=0))
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(3, gx_perf.run_quiet_batch(args, self.probe, runner))
        runner.assert_not_called()
        result = json.loads((args.out/'RESULT.json').read_text())
        self.assertEqual(('NOT_STARTED', 'NOT_MET', 'NOT_RUN'), (result['status'], result['quiet_status'], result['measurement']))
        args.out = args.out.parent / 'second'
        self.probe.input_ticks.side_effect = [ticks(600), ticks(5)]
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(3, gx_perf.run_quiet_batch(args, self.probe, runner))
        result = json.loads((args.out/'RESULT.json').read_text())
        self.assertEqual(('INVALID', 'INVALID', 'COMPLETE'), (result['status'], result['quiet_status'], result['measurement']))
        self.assertFalse(result['quiet_valid'])
        self.assertFalse(result['plan_compliant'])

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
                after = json.loads((args.out / 'after.json').read_text())['checks']['input']
                self.assertEqual('pass' if valid else 'fail', after['status'])
                self.assertEqual(1200, after['raw']['batch_seconds'])
                self.assertEqual(start, after['raw']['batch_start_tick'])

    def run_batch(self, args, runner):
        with mock.patch.object(gx_perf, 'shared_slots_root', return_value=args.slot_root), contextlib.redirect_stdout(io.StringIO()):
            code = gx_perf.run_quiet_batch(args, self.probe, runner)
        return code, json.loads((args.out / 'RESULT.json').read_text())

    @staticmethod
    def command(code=0, guard=None):
        def runner(command, **kwargs):
            if code == 'raise':
                raise RuntimeError('child setup')
            if guard:
                row = {'schema': 'gx-input-guard-v1', 'batch_id': kwargs['env']['GX_PERF_BATCH_ID'], 'event': 'guard', 'status': guard}
                Path(kwargs['env']['GX_PERF_GUARD_LOG']).write_text(json.dumps(row) + '\n', encoding='utf-8')
            return SimpleNamespace(returncode=code)
        return runner

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
            # The driver failed before its first input: the input criterion is not applicable, not failed.
            (('--injected-input',), 1, None, 2, 'ERROR', 'UNVERIFIED', 'DRIVER_ERROR'),
            (('--injected-input',), 'raise', None, 2, 'ERROR', 'UNVERIFIED', 'DRIVER_ERROR'),
        ]
        for index, (flags, code, guard, expected, status, quiet, measurement) in enumerate(cases):
            args = self.batch_args(*flags)
            args.out = self.args.out.parent / f'case-{index}'
            with self.subTest(flags=flags, code=code, guard=guard):
                exit_code, result = self.run_batch(args, self.command(code, guard))
                self.assertEqual((expected, status, quiet, measurement),
                                 (exit_code, result['status'], result['quiet_status'], result['measurement']))
                self.assertEqual(quiet == 'VALID', result['quiet_valid'])
                self.assertEqual(None if code == 'raise' else code, result['command_exit'])
        after = json.loads((self.args.out.parent / 'case-4' / 'after.json').read_text())
        self.assertEqual('not_applicable', after['checks']['input']['status'])
        self.assertEqual(['input'], after['unverified_checks'])
        self.assertFalse(after['quiet'])
        summary = (self.args.out.parent / 'case-0' / 'SUMMARY.txt').read_text()
        self.assertIn('never rerun to replace it', summary)

    def test_guard_evidence_failures_are_invalid_or_tool_errors(self):
        for index, (code, guard, expected, status) in enumerate(((0, None, 2, 'ERROR'), (0, 'fail', 3, 'INVALID'),
                                                                  (1, 'fail', 3, 'INVALID'))):
            args = self.batch_args('--injected-input')
            args.out = self.args.out.parent / f'guard-{index}'
            with self.subTest(code=code, guard=guard):
                exit_code, result = self.run_batch(args, self.command(code, guard))
                self.assertEqual((expected, status), (exit_code, result['status']))
        foreign = self.args.out.parent / 'foreign.jsonl'
        foreign.write_text(json.dumps({'schema': 'gx-input-guard-v1', 'batch_id': 'other', 'event': 'guard', 'status': 'pass'}) + '\n')
        with self.assertRaises(gx_perf.PerfError):
            gx_perf.guard_evidence(foreign, 'mine', command_failed=True)
        release = self.args.out.parent / 'release.jsonl'
        release.write_text(json.dumps({'schema': 'gx-input-guard-v1', 'batch_id': 'b', 'event': 'release', 'status': 'fail', 'reason': 'UIPI'}) + '\n')
        with self.assertRaisesRegex(gx_perf.PerfError, 'UIPI'):
            gx_perf.guard_evidence(release, 'b')

    def test_noncompliant_thresholds_mode_mismatch_and_end_check_errors(self):
        args = self.batch_args('--idle-seconds', '5')
        self.probe.input_ticks.return_value = ticks(30)
        exit_code, result = self.run_batch(args, self.command(0))
        self.assertEqual((5, 'NONCOMPLIANT', 'VALID', False, False),
                         (exit_code, result['status'], result['quiet_status'], result['plan_compliant'], result['thresholds_plan_compliant']))
        self.assertIn('plan_compliant=false', (args.out / 'SUMMARY.txt').read_text())
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
        instance.log.write_text(text)
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
        instance.log.write_text('')
        capture = gx_perf.CaptureRun(instance,self.root,{'baseline':False,'diagnostic':False})
        with self.assertRaisesRegex(gx_perf.PerfError,'unproved'):
            capture.count('', 'scrollbar.paint')
        manifest = self.root/'capabilities.json'
        manifest.write_text(json.dumps({'exe_sha256':gx_perf.hashlib.sha256(self.exe.read_bytes()).hexdigest(),
                                        'metrics':{'scrollbar.paint':''}}))
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
        instance.log.write_text('')
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
        result=json.loads((args.out/'RESULT.json').read_text())
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
        result = json.loads((args.out / 'RESULT.json').read_text())
        self.assertEqual((True, True, 4), (result['valid'], result['gate_failed'], result['exit']))
        self.assertEqual('FAIL', result['runs'][0]['absolute_gate']['status'])
        self.assertIn('complete; absolute gate FAIL observed; exit 4', (args.out / 'SUMMARY.txt').read_text())
        args = self.args('win32-ui', '--runs', '2')
        args.out = self.root / 'incomplete'
        with mock.patch.object(gx_perf, 'measure_ui', side_effect=measure), mock.patch.object(gx_perf.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1, gx_perf.run_experiment(args, gui))
        result = json.loads((args.out / 'RESULT.json').read_text())
        self.assertEqual((False, True, 1), (result['valid'], result['gate_failed'], result['exit']))

    def test_unexpected_driver_exception_retains_failed_evidence(self):
        args,gui=self.args(),self.fake_gui()
        with mock.patch.object(gx_perf,'measure_ui',side_effect=StopIteration('window vanished')),mock.patch.object(gx_perf.time,'sleep'),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1,gx_perf.run_experiment(args,gui))
        self.assertEqual('failed',json.loads((args.out/'build/run-01/run.json').read_text())['status'])
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
        instance.log.write_text('')
        capture=gx_perf.CaptureRun(instance,self.root,{})
        now=[0.0]
        def sleep(seconds):
            now[0]+=seconds
            if now[0] >= .4 and instance.log.stat().st_size == 0:
                instance.log.write_text('info(gx_perf): metric scrollbar.paint 1\n')
        with mock.patch.object(gx_perf.time,'monotonic',side_effect=lambda:now[0]),mock.patch.object(gx_perf.time,'sleep',side_effect=sleep):
            capture.drain(['scrollbar.paint'],minimum=.6,quiet=.5)
        self.assertGreaterEqual(now[0],.9)

    def test_unsettled_metric_window_is_counted_not_a_driver_error(self):
        instance = mock.Mock()
        instance.log = self.root / 'busy.log'
        instance.log.write_text('')
        capture = gx_perf.CaptureRun(instance, self.root, {'baseline': False, 'diagnostic': False})
        now = [0.0]
        def sleep(seconds):
            now[0] += seconds
            with instance.log.open('a') as stream:
                stream.write('info(gx_perf): metric scrollbar.paint 1\n')
        with mock.patch.object(gx_perf.time, 'monotonic', side_effect=lambda: now[0]), \
                mock.patch.object(gx_perf.time, 'sleep', side_effect=sleep):
            self.assertFalse(capture.drain(['scrollbar.paint'], minimum=.6, quiet=.5))
        self.assertTrue(capture.report['measurement_unsettled'])
        self.assertEqual('timeout', capture.report['drains'][-1]['status'])
        capture.count(instance.log.read_text(), 'scrollbar.paint')
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
        result = json.loads((args.out / 'RESULT.json').read_text())
        self.assertEqual([{'label': 'build', 'run': 1, 'metrics': [['scrollbar.paint']]}], result['unsettled_runs'])
        self.assertIn('Unsettled metric windows', (args.out / 'SUMMARY.txt').read_text())

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
        args = self.args('win32-ui', '--exe', str(self.exe), '--runs', '2', '--label-env', 'new:TEST=1', '--diagnostic')
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
        with mock.patch.object(gx_perf.time, 'sleep', side_effect=sleep), mock.patch.object(gx_perf, 'last_input_ticks', return_value=(1, 10)):
            gx_perf.idle_interval(gui, instance, capture, self.args('win32-idle'), counters)
        self.assertEqual([2], capture.samples.values['proc.snapshot'])
        self.assertEqual([2], capture.samples.values['process.cpu'])
        self.assertEqual([10], capture.samples.values['threads.context_switches'])

    def test_idle_thread_churn_preserves_p2_but_foreign_input_rejects(self):
        instance, gui, counters = mock.Mock(), mock.Mock(), mock.Mock()
        instance.log = self.root/'idle.log'
        instance.log.write_text('')
        gui.win32.return_value.window_pid.return_value = instance.pid
        before = dict(pid=1,birth=2,user_100ns=0,kernel_100ns=0,begin_ns=0,end_ns=1,
                      threads=[dict(tid=3,birth=4,switches=10)])
        after = dict(before,begin_ns=60000000001,threads=[])
        counters.sample.side_effect = [before, after, before, after]
        def sleep(seconds):
            if seconds == 60:
                with instance.log.open('a') as stream:
                    stream.write('info(gx_perf): metric proc.snapshot 2\n')
        capture = gx_perf.CaptureRun(instance, self.root, {'diagnostic':False,'capabilities':{'proc.snapshot':''}})
        with mock.patch.object(gx_perf.time,'sleep',side_effect=sleep), mock.patch.object(gx_perf,'last_input_ticks',return_value=(10,20)):
            gx_perf.idle_interval(gui,instance,capture,self.args('win32-idle'),counters)
        self.assertEqual([2],capture.samples.values['proc.snapshot'])
        self.assertEqual('partial',capture.report['context_switch_diagnostic']['status'])
        self.assertEqual('not_instrumented',capture.report['missing_metrics']['renderer.present']['status'])
        with mock.patch.object(gx_perf.time,'sleep',side_effect=sleep), mock.patch.object(gx_perf,'last_input_ticks',side_effect=[(10,20),(11,21)]):
            with self.assertRaisesRegex(gx_perf.PerfError,'input'):
                gx_perf.idle_interval(gui,instance,capture,self.args('win32-idle'),counters)

    def test_p3_drags_real_caption_and_p6_holds_key_at_30hz(self):
        gui, instance, capture = mock.Mock(), mock.Mock(), mock.Mock()
        capture.report = {'observations': {}}
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

    def test_p6_theme_list_uia_is_required_only_in_the_new_arm(self):
        args = self.args('win32-ui', '--exe', str(self.exe), '--runs', '2', '--case', 'p6', '--label-env', 'new:GX_TEST_ARM=new')
        gui = self.fake_gui()
        launch = gui.launch.side_effect
        def launch_arm(exe, env_dir, **kwargs):
            instance = launch(exe, env_dir, **kwargs)
            new = kwargs['env'].get('GX_TEST_ARM') == 'new'
            # The historical image has no settings UIA provider: no theme list items, no theme.reload counter.
            instance.uia_rows.return_value = [{'type': 'ControlType.ListItem'}] if new else [{'type': 'ControlType.Window'}]
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
        result = json.loads((args.out / 'RESULT.json').read_text())
        self.assertEqual(['completed'] * 4, [row['status'] for row in result['runs']])
        self.assertEqual({'theme_list_uia': {'status': 'not_instrumented', 'n': 0, 'runs': [1, 2],
                                             'scope': 'historical arm only; theme list items not readable through UIA'}},
                         result['missing_preconditions']['old'])
        self.assertNotIn('new', result['missing_preconditions'])
        self.assertEqual(['not_evaluated', 'not_evaluated'], [gate['status'] for gate in result['absolute_gates']['old']])
        self.assertEqual(['PASS', 'PASS'], [gate['status'] for gate in result['absolute_gates']['new']])
        self.assertIn('Missing preconditions (historical arm only', (args.out / 'SUMMARY.txt').read_text())
        instance = mock.Mock()
        instance.uia_rows.return_value = []
        capture = gx_perf.CaptureRun(instance, self.root, {'baseline': False, 'diagnostic': False})
        with mock.patch.object(gx_perf, 'open_ui'), mock.patch.object(gx_perf.time, 'sleep'), \
                self.assertRaisesRegex(gx_perf.PerfError, 'no theme list items'):
            gx_perf.measure_ui(mock.Mock(), instance, capture, args)
        instance.hold_key.assert_not_called()

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
