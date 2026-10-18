"""Offline C6 contract tests; never launch a desktop."""
import sys
import json
import hashlib
import itertools
from types import SimpleNamespace
import unittest
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_perf
from test_gx_win_gui import observe_startup


class C6ContractTests(unittest.TestCase):
    def test_registered_desktop_driver(self):
        self.assertIn('win32-c6', gx_perf.WIN32_DRIVERS)
        argv = ['python', 'gx_perf.py', 'win32-c6', '--exe', 'a', '--exe', 'b',
                '--out', 'out', '--font-manifest', 'manifest.json']
        self.assertTrue(gx_perf.desktop_command(argv))
        self.assertTrue(gx_perf.gate_exit_contract(argv))
        self.assertEqual(gx_perf.build_parser().parse_args(argv[2:]).runs, 10)

    def test_exact_ten_pairs(self):
        plan = gx_perf.alternate(['warmup', 'no-warmup'], 10)
        self.assertEqual(len(plan), 20)
        self.assertEqual([label for _, label in plan[:4]],
                         ['warmup', 'no-warmup', 'no-warmup', 'warmup'])

    def test_generic_fallback_is_not_cjk_proof(self):
        import gx_perf_font as font
        with self.assertRaisesRegex(gx_perf.PerfError, 'codepoint'):
            font.validate_discovery('', 'metric font.first_fallback 2 ms\n')

    def test_early_duplicate_missing_and_wrong_codepoint(self):
        import gx_perf_font as font
        good = 'metric font.first_fallback 2 ms\nmetric font.first_fallback.codepoint 20013\n'
        for before, after in [('metric font.first_fallback 1 ms\n', good),
                              ('', good + good), ('', ''),
                              ('', good.replace('20013', '65'))]:
            with self.subTest(before=before, after=after), self.assertRaises(gx_perf.PerfError):
                font.validate_discovery(before, after)

    def test_proposed_codepoint_contract_crlf(self):
        import gx_perf_font as font
        text = ('metric font.first_fallback 2 ms\r\nmetric font.first_fallback.codepoint 20013\r\n'
                'metric font.first_fallback.success 1\r\n')
        self.assertEqual(font.validate_discovery('', text), 2)

    def test_error_or_absent_success_is_never_completed(self):
        import gx_perf_font as font
        prefix = 'metric font.first_fallback 2 ms\nmetric font.first_fallback.codepoint 20013\n'
        for suffix in ('', 'metric font.first_fallback.success 0\n',
                       'metric font.first_fallback.success 1 ms\n',
                       'metric font.first_fallback.success 1\n' * 2):
            with self.subTest(suffix=suffix), self.assertRaises(gx_perf.PerfError):
                font.validate_discovery('', prefix + suffix)

    def test_isolation_resets_map_and_defines_diagnostic_scope(self):
        import gx_perf_font as font
        with tempfile.TemporaryDirectory() as tmp:
            shell = font.OwnedFontShell(Path(tmp) / 'shell')
            self.assertIn('font-codepoint-map =\n', shell.config())
            self.assertIn('font-family = JetBrains Mono\n', shell.config())
        self.assertEqual(font.SCOPE, 'c6-ordinary-fallback-raster-ready-v1')

    def test_product_emits_claim_identity_and_result(self):
        source = (Path(__file__).resolve().parents[1] / 'src/font/directwrite/discovery.zig').read_text(encoding='utf-8')
        self.assertIn('recorder.count("font.first_fallback.codepoint", cp);', source)
        self.assertIn('recorder.count("font.first_fallback.success", @intFromBool(success));', source)

    def test_only_warmup_visibility_may_differ(self):
        import gx_perf_font as font
        a = 'head\n    pub fn warmup() void {\nbody\n'
        b = a.replace('pub fn warmup', 'fn warmup')
        font.validate_source_delta(a, b)
        for other in (a, b + 'extra', b.replace('body', 'changed')):
            with self.subTest(other=other), self.assertRaises(gx_perf.PerfError):
                font.validate_source_delta(a, other)

    def test_payload_is_fixed_single_cjk(self):
        import gx_perf_font as font
        self.assertEqual(font.PAYLOAD.decode('utf-8'), 'GX C6 CJK:\r\n中\r\n')
        self.assertTrue(font.READY.isascii())

    def test_receipt_rejects_foreign_duplicate_partial_and_early_output(self):
        import gx_perf_font as font
        with tempfile.TemporaryDirectory() as tmp:
            shell = font.OwnedFontShell(Path(tmp) / 'shell')
            shell.identities = {12: 34}
            command = {'id': 'owned', 'qpc_ns': 100}
            row = dict(event='cjk', pid=12, id='owned', payload_hex=font.PAYLOAD.hex(),
                       written_bytes=len(font.PAYLOAD), write_begin_qpc_ns=101, qpc_ns=102)
            with mock.patch.object(shell, 'rows', return_value=[row]):
                self.assertEqual(shell.receipt(command), row)
            for changes in ({'pid': 13}, {'id': 'foreign'}, {'written_bytes': 1},
                            {'payload_hex': '41'}, {'write_begin_qpc_ns': 99}, {'qpc_ns': 100}):
                with self.subTest(changes=changes), mock.patch.object(shell, 'rows', return_value=[dict(row, **changes)]):
                    with self.assertRaises(gx_perf.PerfError):
                        shell.receipt(command)
            with mock.patch.object(shell, 'rows', return_value=[row, row]):
                with self.assertRaises(gx_perf.PerfError):
                    shell.receipt(command)

    def test_discovery_only_cannot_be_reported_as_original_target(self):
        import gx_perf_font as font
        with self.assertRaises(gx_perf.PerfError):
            font.validate_fallback('', 'metric font.first_fallback 2 ms\n'
                                   'metric font.first_fallback.codepoint 20013\n'
                                   'metric font.first_fallback.success 1\n')

    def test_early_partial_identity_and_failed_ascii_are_rejected(self):
        import gx_perf_font as font
        good = ('metric font.first_fallback 1 ms\nmetric font.first_fallback.codepoint 20013\n'
                'metric font.first_fallback.success 1\n')
        for before in ('metric font.first_fallback.codepoint 65\n',
                       'metric font.first_fallback.success 0\n'):
            with self.subTest(before=before), self.assertRaises(gx_perf.PerfError):
                font.validate_discovery(before, good)


class C6FormalTests(unittest.TestCase):
    def test_real_wait_window_startup_reaches_c6_without_native_metric(self):
        import gx_perf_font as font
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            instance, marks = observe_startup(root, evidence=True)
            self.assertEqual(marks['shown_ms'], 10)
            instance.log.parent.mkdir(parents=True)
            instance.log.write_bytes(b'ASCII only\n')
            capture = gx_perf.CaptureRun(instance, root, dict(font_build={}, pid=instance.pid,
                creation=instance.creation, startup_ms=marks))
            shell = mock.Mock()
            shell.identities = {12: 34}
            shell.ready.return_value = True
            shell.rows.return_value = [dict(event='ready', payload_hex=font.READY.hex(), written_bytes=len(font.READY))]
            def trigger(_action):
                with instance.log.open('ab') as stream:
                    stream.write(self.good().encode())
                return dict(id='owned', qpc_ns=3)
            shell.command.side_effect = trigger
            shell.receipt.return_value = dict(write_begin_qpc_ns=4, qpc_ns=5)
            counters = mock.Mock()
            counters.sample.side_effect = [
                dict(pid=instance.pid, birth=instance.creation, begin_ns=1, end_ns=2, private_bytes=1000),
                dict(pid=instance.pid, birth=instance.creation, begin_ns=6, end_ns=7, private_bytes=2000)]
            ticks = itertools.count()
            with mock.patch.object(gx_perf, 'wait_until', side_effect=lambda fn, _: fn()), \
                 mock.patch.object(gx_perf, 'last_input_ticks', return_value=(1, 0)), \
                 mock.patch.object(gx_perf, 'c7_input_check'), \
                 mock.patch.object(font.time, 'monotonic', side_effect=lambda: next(ticks) / 10), \
                 mock.patch.object(font.time, 'sleep'), mock.patch.object(capture, 'screenshot'):
                font.measure(None, instance, capture, object(), counters, shell)
            self.assertEqual(capture.samples.values['startup.shown'], [marks['shown_ms']])
            self.assertNotIn(b'startup.shown', instance.log.read_bytes())
            (root / 'ghostty.log').write_bytes(instance.log.read_bytes() + b'cleanup\n')
            self.assertEqual(font.validate_run_raw(capture.report, root)['startup.shown'], marks['shown_ms'])
            self.assertEqual(instance.log.read_bytes(), b'ASCII only\n' + self.good().encode())

    @staticmethod
    def good():
        return ('info(gx_perf): metric font.first_cjk_fallback.started 1\n'
                'info(gx_perf): metric font.first_cjk_fallback.codepoint 20013\n'
                'info(gx_perf): metric font.first_cjk_fallback.request 1\n'
                'info(gx_perf): metric font.first_cjk_fallback.grid 1\n'
                'info(gx_perf): metric font.first_cjk_fallback.font_index 7\n'
                'info(gx_perf): metric font.first_cjk_fallback.glyph 99\n'
                'info(gx_perf): metric font.first_cjk_fallback.bound 1\n'
                'info(gx_perf): font.first_cjk_fallback.raster_ready 2500us\n'
                'info(gx_perf): metric font.first_cjk_fallback.completed 1\n')

    def test_ordered_claim_accepts_full_target_and_crlf(self):
        import gx_perf_font as font
        before = 'ASCII only\n'
        for newline in ('\n', '\r\n'):
            after = (before + self.good()).replace('\n', newline)
            identity = font.validate_target(before.replace('\n', newline), after)
            self.assertEqual(identity['duration_ms'], 2.5)
            self.assertEqual((identity['codepoint'], identity['font_index'], identity['glyph']), (20013, 7, 99))

    def test_missing_duplicate_or_reordered_stage_fails(self):
        import gx_perf_font as font
        rows = self.good().splitlines(keepends=True)
        for index in range(len(rows)):
            for altered in (rows[:index] + rows[index + 1:], rows[:index] + [rows[index]] + rows[index:]):
                with self.subTest(index=index), self.assertRaises(gx_perf.PerfError):
                    font.validate_target('', ''.join(altered))
        with self.assertRaises(gx_perf.PerfError):
            font.validate_target('', ''.join(reversed(rows)))

    def test_invalid_or_early_identity_rejects(self):
        import gx_perf_font as font
        for old, new in (('codepoint 20013', 'codepoint 65'), ('glyph 99', 'glyph 0'),
                         ('font_index 7', 'font_index 65536'), ('request 1', 'request 2'),
                         ('grid 1', 'grid 2'), ('started 1', 'started 1 ms'),
                         ('2500us', '2500'), ('2500us', '-1us'), ('2500us', 'nanus'),
                         ('completed 1', 'completed 0')):
            with self.subTest(new=new), self.assertRaises(gx_perf.PerfError):
                font.validate_target('', self.good().replace(old, new))
        with self.assertRaises(gx_perf.PerfError):
            font.validate_target(self.good().splitlines(keepends=True)[0], self.good())
        with self.assertRaises(gx_perf.PerfError):
            font.validate_target('old log', self.good())

    def test_each_rejection_and_later_success_stays_rejected(self):
        import gx_perf_font as font
        for reason in range(1, 15):
            with self.subTest(reason=reason), self.assertRaisesRegex(gx_perf.PerfError, 'rejected'):
                font.validate_target('', f'metric {font.PREFIX}rejected {reason}\n' + self.good())

    def test_timestamp_prefix_and_unrelated_discovery_are_independent(self):
        import gx_perf_font as font
        raw = ''.join('12:00:00.000 [123] ' + row + '\n' for row in self.good().splitlines())
        self.assertEqual(font.validate_fallback('', raw + 'metric font.first_fallback 900 ms\n'), 2.5)
        with self.assertRaises(gx_perf.PerfError):
            font.validate_target('', raw + 'metric ' + font.PREFIX + 'unknown 1\n')

    def test_manifest_binds_same_reference_tree_and_formal_scope(self):
        import gx_perf_font as font
        warm = 'head\n    pub fn warmup() void {\nbody\n'
        cold = warm.replace('pub fn warmup', 'fn warmup')
        commits = ['a' * 40, 'b' * 40]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            exes = [root / 'warm.exe', root / 'cold.exe']
            log = root / 'build.log'
            log.write_bytes(b'verified build log')
            manifest = dict(schema='gx-c6-builds-v2', scope=font.SCOPE, repository=str(root),
                            reference_commit=commits[0], instrumentation='GX-0056', arms={})
            for index, label in enumerate(('warmup', 'no-warmup')):
                exes[index].write_bytes(label.encode())
                manifest['arms'][label] = dict(source_commit=commits[index], source_clean=True,
                    optimize='ReleaseFast', exe_sha256=hashlib.sha256(exes[index].read_bytes()).hexdigest(),
                    build_command='root wrapper command', build_log=str(log),
                    build_log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
                    source_exe_attested_by='root',
                    build_options=['-Doptimize=ReleaseFast', '-Dtarget=x86_64-windows-gnu'])
            args = SimpleNamespace(runs=10, config=None, env=[], label_env=[], diagnostic=False,
                                   uninstrumented=[], font_manifest=root / 'manifest.json')
            def git(argv):
                if argv[3] == 'show':
                    return (warm if argv[4].startswith(commits[0]) else cold).encode()
                if argv[4] == '--name-only':
                    return (font.SOURCE + '\n').encode()
                return b'warmup visibility only'
            with mock.patch.object(font.subprocess, 'check_output', side_effect=git):
                args.font_manifest.write_text(json.dumps(manifest), encoding='utf-8')
                self.assertEqual(font.validate_manifest(args, exes, ['warmup', 'no-warmup'])['scope'], font.SCOPE)
                for key, bad in (('schema', 'gx-c6-builds-v1'), ('scope', 'c6-discoverFallback-diagnostic-v1'),
                                 ('reference_commit', 'c' * 40), ('instrumentation', 'unknown')):
                    changed = dict(manifest, **{key: bad})
                    args.font_manifest.write_text(json.dumps(changed), encoding='utf-8')
                    with self.subTest(key=key), self.assertRaises(gx_perf.PerfError):
                        font.validate_manifest(args, exes, ['warmup', 'no-warmup'])
                args.font_manifest.write_text(json.dumps(manifest), encoding='utf-8')
                exes[0].write_bytes(b'other executable')
                with self.assertRaises(gx_perf.PerfError):
                    font.validate_manifest(args, exes, ['warmup', 'no-warmup'])

    def test_measure_reaches_formal_capture_and_refuses_discovery_only(self):
        import gx_perf_font as font
        for completed in (True, False):
            with self.subTest(completed=completed), tempfile.TemporaryDirectory() as tmp:
                shell = mock.Mock()
                shell.identities = {12: 34}
                shell.ready.return_value = True
                shell.rows.return_value = [dict(event='ready', payload_hex=font.READY.hex(), written_bytes=len(font.READY))]
                shell.command.return_value = dict(id='owned', qpc_ns=100)
                shell.receipt.return_value = dict(pid=12, id='owned', payload_hex=font.PAYLOAD.hex(),
                    written_bytes=len(font.PAYLOAD), write_begin_qpc_ns=101, qpc_ns=102)
                capture = mock.Mock()
                capture.target = Path(tmp)
                instance, marks = observe_startup(capture.target, evidence=True)
                capture.report = dict(font_build={}, pid=instance.pid, creation=instance.creation, startup_ms=marks)
                before = b'ASCII only\n'
                after = before + (self.good() if completed else 'metric font.first_fallback 2 ms\n').encode()
                capture.mark.side_effect = lambda: after if shell.command.called else before
                counters = mock.Mock()
                counters.sample.side_effect = [
                    dict(pid=instance.pid, birth=instance.creation, begin_ns=1, end_ns=2, private_bytes=1000),
                    dict(pid=instance.pid, birth=instance.creation, begin_ns=103, end_ns=104, private_bytes=2000)]
                ticks = itertools.count()
                with mock.patch.object(gx_perf, 'wait_until', side_effect=lambda fn, _: fn()), \
                     mock.patch.object(gx_perf, 'last_input_ticks', return_value=(1, 0)), \
                     mock.patch.object(gx_perf, 'c7_input_check'), \
                     mock.patch.object(font.time, 'monotonic', side_effect=lambda: next(ticks) / 10), \
                     mock.patch.object(font.time, 'sleep'):
                    if completed:
                        font.measure(None, instance, capture, object(), counters, shell)
                        capture.add.assert_any_call(font.METRIC, 2.5, 'ms')
                        capture.add.assert_any_call('process.commit.delta', 1000)
                        self.assertEqual(capture.report['c6']['coverage'], 'captured')
                        self.assertEqual(capture.report['c6']['visual_review'], 'PENDING')
                    else:
                        with self.assertRaises(gx_perf.PerfError) as caught:
                            font.measure(None, instance, capture, object(), counters, shell)
                        self.assertEqual(caught.exception.cause, 'c6_target_incomplete')
                        self.assertNotIn('coverage', capture.report['c6'])

    def test_ten_samples_preserve_p90_and_inclusive_iqr(self):
        import gx_perf_font as font
        result = font.distributions(list(range(10)))
        self.assertEqual((result['median'], result['p90'], result['iqr']), (4.5, 8, 4.5))
        for values in ([], [1] * 9, [1] * 11, [float('nan')] * 10):
            with self.subTest(n=len(values)), self.assertRaises(gx_perf.PerfError):
                font.distributions(values)

    def batch_fixture(self, root):
        import gx_perf_font as font
        batch = dict(valid=True, exit=0, errors=[], runs=[], font_manifest={'arms': {}})
        for label in ('warmup', 'no-warmup'):
            exe = root / (label + '.exe')
            exe.write_bytes(label.encode())
            log = root / (label + '-build.log')
            log.write_bytes(b'root build')
            batch['font_manifest']['arms'][label] = dict(source_commit=('a' if label == 'warmup' else 'b') * 40,
                exe_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(), build_log=str(log),
                build_log_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
        for number, label in gx_perf.alternate(['warmup', 'no-warmup'], 10):
            path = root / label / str(number)
            path.mkdir(parents=True)
            instance, marks = observe_startup(path, evidence=True)
            before = b'ASCII only\r\n'
            after = before + self.good().encode() + b'tail\r\n'
            (path / 'before-cjk.log').write_bytes(before)
            (path / 'after-cjk.log').write_bytes(after)
            (path / 'ghostty.log').write_bytes(after + b'cleanup\r\n')
            metrics = {name: dict(n=1, median=value, unit=unit) for name, value, unit in
                       [(font.METRIC, 2.5, 'ms'), ('startup.shown', marks['shown_ms'], 'ms'),
                        ('process.commit.before', 1000, ''), ('process.commit.after', 2000, ''),
                        ('process.commit.delta', 1000, '')]}
            report = dict(status='completed', label=label, run=number, metrics=metrics,
                          pid=instance.pid, creation=instance.creation, startup_ms=marks,
                          errors=[], exe=str(root / (label + '.exe')),
                          exe_sha256=batch['font_manifest']['arms'][label]['exe_sha256'],
                          font_build=batch['font_manifest']['arms'][label].copy(),
                          c6=dict(scope=font.SCOPE, coverage='captured',
                              source=batch['font_manifest']['arms'][label].copy(),
                              identity=font.validate_target(before.decode(), after.decode()),
                              commit_before=dict(pid=42, birth=123, begin_ns=1, end_ns=2, private_bytes=1000),
                              trigger=dict(qpc_ns=3), actual_output=dict(write_begin_qpc_ns=4, qpc_ns=5),
                              commit_after=dict(pid=42, birth=123, begin_ns=6, end_ns=7, private_bytes=2000)))
            font.startup_guard(report, path, collect=True)
            (path / 'run.json').write_text(json.dumps(report), encoding='utf-8')
            batch['runs'].append(dict(run=number, label=label, status='completed', path=str(path.relative_to(root))))
        return batch

    def test_finalization_rechecks_all_twenty_raw_runs(self):
        import gx_perf_font as font
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            batch = self.batch_fixture(root)
            font.finalize_batch(batch, root)
            self.assertTrue(batch['valid'])
            self.assertEqual(batch['c6']['measurement_coverage'], 'captured')
            self.assertEqual(batch['c6']['visual_review'], 'PENDING')
            self.assertEqual(batch['c6']['distributions']['warmup'][font.METRIC]['n'], 10)
            path = root / batch['runs'][-1]['path'] / 'ghostty.log'
            path.write_text(self.good() + self.good(), encoding='utf-8')
            font.finalize_batch(batch, root)
            self.assertFalse(batch['valid'])
            self.assertEqual(batch['exit'], 1)


    def test_raw_gui_startup_and_negative_private_delta(self):
        import gx_perf_font as font
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            batch = self.batch_fixture(root)
            for row in batch['runs']:
                path = root / row['path']
                self.assertNotIn(b'startup.shown', (path / 'ghostty.log').read_bytes())
                run = json.loads((path / 'run.json').read_text())
                run['c6']['commit_after']['private_bytes'] = 900
                run['metrics']['process.commit.after']['median'] = 900
                run['metrics']['process.commit.delta']['median'] = -100
                (path / 'run.json').write_text(json.dumps(run))
            font.finalize_batch(batch, root)
            self.assertTrue(batch['valid'], batch['errors'])
            self.assertEqual(batch['c6']['distributions']['warmup']['process.commit.delta']['median'], -100)

    def test_startup_raw_fields_reject_even_with_rehashed_reference(self):
        import gx_perf_font as font
        changes = [
            (('shown_ms',), 10), (('confirmation', 'error'), 'query failed'),
            (('schema',), 'unknown'), (('producer',), 'native'), (('pid',), 43), (('pid',), True),
            (('window_kind',), 'quick'), (('start_filetime_100ns',), 124),
            (('start_filetime_100ns',), True), (('end_filetime_100ns',), 122),
            (('end_filetime_100ns',), 1.5), (('end_filetime_100ns',), 2**64),
            (('clock', 'unit'), 'ns'), (('clock', 'start_source'), 'CreateProcess.before'),
            (('clock', 'end_source'), 'QueryPerformanceCounter'),
            (('clock', 'end_phase'), 'after_window_enumeration'),
            (('window', 'hwnd'), 0), (('window', 'hwnd'), True), (('window', 'hwnd'), 102),
            (('window', 'cls'), 'OtherWindow'), (('window', 'visible'), False),
            (('window', 'visible'), 1), (('window', 'cloaked'), True), (('window', 'cloaked'), 0),
            (('window', 'toolwindow'), True), (('confirmation', 'hwnd'), 102),
            (('confirmation', 'pid'), 43), (('confirmation', 'birth'), 124),
            (('confirmation', 'visible'), False), (('confirmation', 'cloaked'), 1),
            (('confirmation', 'cloaked'), False), (('confirmation', 'cloak_hresult'), -1),
            (('confirmation', 'cloak_hresult'), False), (('confirmation', 'toolwindow'), True),
        ]
        for key in ('schema', 'producer', 'pid', 'clock', 'window_kind', 'start_filetime_100ns',
                    'end_filetime_100ns', 'window', 'confirmation'):
            changes.append(((key,), None))
        for key in ('hwnd', 'pid', 'birth', 'visible', 'cloaked', 'cloak_hresult', 'toolwindow', 'cls'):
            changes.append((('confirmation', key), None))
        for keys, value in changes:
            with self.subTest(keys=keys, value=value), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                instance, marks = observe_startup(root, evidence=True)
                run = dict(pid=instance.pid, creation=instance.creation, startup_ms=marks, c6={})
                font.startup_guard(run, root, collect=True)
                path = root / font.STARTUP_FILE
                raw = json.loads(path.read_text(encoding='utf-8'))
                target = raw
                for key in keys[:-1]:
                    target = target[key]
                if value is None:
                    del target[keys[-1]]
                else:
                    target[keys[-1]] = value
                path.write_text(json.dumps(raw), encoding='utf-8')
                run['c6']['startup_observation']['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
                with self.assertRaisesRegex(gx_perf.PerfError, 'startup observation'):
                    font.startup_guard(run, root)

    def test_raw_startup_cannot_be_replaced_by_summary_or_log(self):
        import gx_perf_font as font
        for case in ('missing_raw', 'different_hash', 'duplicate_key', 'fake_report', 'bool_report',
                     'missing_report', 'missing_reference', 'wrong_path', 'wrong_reference_schema',
                     'native_row', 'synthetic_row', 'duplicate_native', 'malformed_native', 'wrong_report_pid',
                     'wrong_report_birth'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                batch = self.batch_fixture(root)
                path = root / batch['runs'][-1]['path']
                run_path = path / 'run.json'
                run = json.loads(run_path.read_text(encoding='utf-8'))
                raw_path = path / font.STARTUP_FILE
                if case == 'missing_raw':
                    raw_path.unlink()
                    # The old invented log must not substitute for raw observation.
                    final = path / 'ghostty.log'
                    final.write_bytes(final.read_bytes() + b'metric startup.shown 10 ms\n')
                elif case == 'different_hash':
                    raw_path.write_bytes(raw_path.read_bytes() + b'\n')
                elif case == 'duplicate_key':
                    raw_path.write_bytes(raw_path.read_bytes().replace(b'"pid": 42', b'"pid": 42, "pid": 42', 1))
                    run['c6']['startup_observation']['sha256'] = hashlib.sha256(raw_path.read_bytes()).hexdigest()
                elif case in ('fake_report', 'bool_report'):
                    run['startup_ms']['shown_ms'] = True if case == 'bool_report' else 11
                elif case == 'missing_report':
                    del run['startup_ms']
                elif case == 'missing_reference':
                    del run['c6']['startup_observation']
                elif case == 'wrong_path':
                    run['c6']['startup_observation']['path'] = '../startup-observation.json'
                elif case == 'wrong_reference_schema':
                    run['c6']['startup_observation']['schema'] = 'qpc'
                elif case in ('wrong_report_pid', 'wrong_report_birth'):
                    run['pid' if case == 'wrong_report_pid' else 'creation'] += 1
                else:
                    line = {'native_row': b'12:00:00.000 [42] info(gx_perf): startup.shown 10000us\n',
                            'synthetic_row': b'metric startup.shown 10 ms\n',
                            'duplicate_native': b'metric startup.shown 10 ms\n' * 2,
                            'malformed_native': b'metric startup.shown broken\n'}[case]
                    for name in ('before-cjk.log', 'after-cjk.log', 'ghostty.log'):
                        log = path / name
                        log.write_bytes(line + log.read_bytes())
                run_path.write_text(json.dumps(run), encoding='utf-8')
                font.finalize_batch(batch, root)
                self.assertFalse(batch['valid'], case)
                self.assertEqual(len(batch['runs']), 20)
                self.assertNotIn('distributions', batch['c6'])

    def test_finalization_rejects_raw_or_identity_corruption(self):
        import gx_perf_font as font
        cases = ('missing_after', 'missing_before', 'missing_final', 'truncate_final_tail',
                 'replace_after', 'newline_rewrite', 'different_identity_same_time', 'record_identity',
                 'raw_error', 'run_error', 'row_error', 'missing_endpoint', 'wrong_pid',
                 'wrong_birth', 'reverse_qpc', 'overlap_qpc', 'trigger_order', 'output_order',
                 'negative_bytes', 'bool_bytes', 'fake_delta', 'fake_before', 'fake_after',
                 'missing_startup', 'duplicate_startup', 'malformed_startup', 'fake_startup',
                 'exe_replaced', 'source_replaced', 'c6_source_replaced', 'build_log_replaced', 'startup_trailing_garbage', 'endpoint_error', 'false_count')
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                batch = self.batch_fixture(root)
                row = batch['runs'][-1]
                path = root / row['path']
                report_path = path / 'run.json'
                run = json.loads(report_path.read_text())
                final = path / 'ghostty.log'
                after = path / 'after-cjk.log'
                if case.startswith('missing_') and case[8:] in ('after', 'before', 'final'):
                    (path / {'after': 'after-cjk.log', 'before': 'before-cjk.log', 'final': 'ghostty.log'}[case[8:]]).unlink()
                elif case == 'truncate_final_tail':
                    final.write_bytes(after.read_bytes().replace(b'tail\r\n', b''))
                elif case == 'replace_after':
                    after.write_bytes(b'replaced')
                elif case == 'newline_rewrite':
                    final.write_bytes(final.read_bytes().replace(b'\r\n', b'\n'))
                elif case == 'different_identity_same_time':
                    for raw in (after, final):
                        raw.write_bytes(raw.read_bytes().replace(b'glyph 99', b'glyph 98'))
                elif case == 'record_identity':
                    run['c6']['identity']['font_index'] = 8
                elif case == 'raw_error':
                    final.write_bytes(final.read_bytes() + b'error(gx_perf): failed\n')
                elif case == 'run_error':
                    run['errors'] = ['counter read failed']
                elif case == 'row_error':
                    row['errors'] = ['failed']
                elif case == 'missing_endpoint':
                    del run['c6']['commit_before']
                elif case in ('wrong_pid', 'wrong_birth', 'reverse_qpc', 'overlap_qpc', 'negative_bytes', 'bool_bytes'):
                    key, value = {'wrong_pid': ('pid', 43), 'wrong_birth': ('birth', 124),
                        'reverse_qpc': ('end_ns', 0), 'overlap_qpc': ('begin_ns', 1),
                        'negative_bytes': ('private_bytes', -1), 'bool_bytes': ('private_bytes', True)}[case]
                    run['c6']['commit_after'][key] = value
                elif case == 'trigger_order':
                    run['c6']['trigger']['qpc_ns'] = 1
                elif case == 'output_order':
                    run['c6']['actual_output']['qpc_ns'] = 8
                elif case.startswith('fake_'):
                    name = 'startup.shown' if case == 'fake_startup' else 'process.commit.' + case[5:]
                    run['metrics'][name]['median'] += 1
                elif case in ('missing_startup', 'duplicate_startup', 'malformed_startup'):
                    raw = path / font.STARTUP_FILE
                    if case == 'missing_startup':
                        raw.unlink()
                    elif case == 'duplicate_startup':
                        raw.write_bytes(raw.read_bytes() * 2)
                    else:
                        raw.write_text('{broken', encoding='utf-8')
                elif case == 'exe_replaced':
                    Path(run['exe']).write_bytes(b'changed between rounds')
                elif case == 'source_replaced':
                    run['font_build']['source_commit'] = 'c' * 40
                elif case == 'c6_source_replaced':
                    run['c6']['source']['source_commit'] = 'c' * 40
                elif case == 'startup_trailing_garbage':
                    for raw in (path / 'before-cjk.log', after, final):
                        raw.write_bytes(b'info(gx_perf): startup.shown 10000us junk\r\n' + raw.read_bytes())
                elif case == 'endpoint_error':
                    run['c6']['commit_after']['error'] = 'failed'
                elif case == 'false_count':
                    run['metrics']['startup.shown']['n'] = True
                elif case == 'build_log_replaced':
                    Path(run['font_build']['build_log']).write_bytes(b'other build')
                report_path.write_text(json.dumps(run))
                font.finalize_batch(batch, root)
                self.assertFalse(batch['valid'], case)
                self.assertEqual(batch['exit'], 1)
                self.assertNotIn('distributions', batch['c6'])
                self.assertEqual(len(batch['runs']), 20)

    def test_partial_or_reordered_batch_never_filters_to_success(self):
        import gx_perf_font as font
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            batch = self.batch_fixture(root)
            batch['runs'][0], batch['runs'][1] = batch['runs'][1], batch['runs'][0]
            font.finalize_batch(batch, root)
            self.assertFalse(batch['valid'])
            self.assertEqual(batch['c6']['measurement_coverage'], 'PENDING')
            batch['runs'].pop()
            font.finalize_batch(batch, root)
            self.assertEqual(batch['c6']['measurement_coverage'], 'PENDING')



if __name__ == '__main__':
    unittest.main()
