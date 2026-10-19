"""Offline tests: never launch a terminal, query PDH or send desktop input."""
import ctypes
import copy
import json
import os
from pathlib import Path
import tempfile
import sys
import subprocess
import time
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
import gx_perf_stimulus as stimulus


def pdh_sample(count=10, stamp=100, tid=7, birth=55, pid=42):
    return {'arrays': {key: [{'name': 'ghostty/0', 'status': 0, 'first': value,
                            'second': stamp, 'multi': 1, 'timestamp_100ns': stamp}]
                       for key, value in dict(pid=pid, tid=tid, birth=birth, switches=count).items()}}


class ConsoleUtf8Tests(unittest.TestCase):
    def kernel(self, before=936, after=65001, set_ok=1, mode_ok=1, handle=123):
        dll = mock.Mock()
        dll.GetStdHandle.return_value = handle
        def get_mode(_handle, mode):
            mode._obj.value = 7  # processed output, wrapping and VT
            return mode_ok
        dll.GetConsoleMode.side_effect = get_mode
        dll.GetConsoleOutputCP.side_effect = [before, after]
        dll.SetConsoleOutputCP.return_value = set_ok
        return dll

    def test_verified_utf8_receipt_keeps_console_mode(self):
        for before in (936, 65001):
            dll = self.kernel(before=before)
            with self.subTest(before=before), mock.patch.object(ctypes, 'WinDLL', return_value=dll, create=True):
                value = stimulus.console_output_utf8()
            self.assertEqual(value, dict(before=before, after=65001, set_success=True, stdout_mode=7))
            dll.SetConsoleOutputCP.assert_called_once_with(65001)
            dll.SetConsoleMode.assert_not_called()
            dll.SetConsoleCP.assert_not_called()

    def test_missing_console_or_failed_set_or_readback_is_closed(self):
        for kwargs in ({'handle': 0}, {'handle': ctypes.c_void_p(-1).value},
                       {'mode_ok': 0}, {'before': 0}, {'set_ok': 0}, {'after': 0}, {'after': 936}):
            dll = self.kernel(**kwargs)
            with self.subTest(kwargs=kwargs), mock.patch.object(ctypes, 'WinDLL', return_value=dll, create=True):
                with self.assertRaises((OSError, ValueError)):
                    stimulus.console_output_utf8()
            if 'handle' in kwargs or 'mode_ok' in kwargs or 'before' in kwargs:
                dll.SetConsoleOutputCP.assert_not_called()

    def test_c6_c7_failure_precedes_any_payload(self):
        import gx_perf_font as font
        for module in (font, stimulus):
            with self.subTest(module=module.__name__), tempfile.TemporaryDirectory() as tmp, \
                 mock.patch.dict(sys.modules, {'msvcrt': mock.Mock(kbhit=mock.Mock(return_value=False))}), \
                 mock.patch.object(module.os, 'O_BINARY', 0x8000, create=True), \
                 mock.patch.object(stimulus, 'console_output_utf8', side_effect=OSError('no console'), create=True), \
                 mock.patch.object(module.os, 'write') as write, \
                 mock.patch.object(stimulus, 'append_json') as append, \
                 mock.patch.object(module.time, 'sleep', side_effect=RuntimeError('unexpected polling')):
                with self.assertRaisesRegex(OSError, 'no console'):
                    module.shell_main(Path(tmp), 'owned-token')
                write.assert_not_called()
                append.assert_not_called()


class PythonImageTests(unittest.TestCase):
    def native(self, path, result=None):
        dll = mock.Mock()
        def filename(module, buffer, size):
            self.assertIsNone(module)
            buffer.value = path
            return len(path.encode('utf-16-le')) // 2 if result is None else result
        dll.GetModuleFileNameW.side_effect = filename
        return dll

    def test_native_image_wins_over_launcher_and_base_hint(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / 'actual python.exe'
            image.write_bytes(b'actual image')
            with mock.patch.object(sys, 'platform', 'win32'), \
                 mock.patch.object(sys, 'executable', str(Path(tmp) / 'launcher.exe')), \
                 mock.patch.object(sys, '_base_executable', 'untrusted-hint.exe', create=True), \
                 mock.patch.object(ctypes, 'WinDLL', return_value=self.native(str(image)), create=True):
                self.assertEqual(str(image.resolve()), stimulus.current_python_image())

    def test_native_non_bmp_path_uses_utf16_units(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / 'python-\U0001f680.exe'
            image.write_bytes(b'actual image')
            path = str(image)
            self.assertEqual(len(path.encode('utf-16-le')) // 2, len(path) + 1)
            with mock.patch.object(sys, 'platform', 'win32'), \
                 mock.patch.object(ctypes, 'WinDLL', return_value=self.native(path), create=True):
                self.assertEqual(str(image.resolve()), stimulus.current_python_image())
            # A count in Python code points is not a valid native receipt.
            with mock.patch.object(sys, 'platform', 'win32'), \
                 mock.patch.object(ctypes, 'WinDLL', return_value=self.native(path, len(path)), create=True):
                with self.assertRaisesRegex(ValueError, 'resolve'):
                    stimulus.current_python_image()

    def test_native_failure_empty_truncated_relative_or_missing_is_closed(self):
        for path, result in [('', 0), ('', 1), ('relative.exe', None),
                             ('missing-python.exe', 32768), ('Z:/absent/python.exe', None)]:
            with self.subTest(path=path, result=result), \
                 mock.patch.object(sys, 'platform', 'win32'), \
                 mock.patch.object(ctypes, 'WinDLL', return_value=self.native(path, result), create=True):
                with self.assertRaises((ValueError, OSError)):
                    stimulus.current_python_image()
        with mock.patch.object(sys, 'platform', 'win32'), \
             mock.patch.object(ctypes, 'WinDLL', side_effect=OSError('native API failed'), create=True):
            with self.assertRaises(OSError):
                stimulus.current_python_image()

    def test_c6_c7_ready_receipts_use_native_identity_without_changing_payload(self):
        import gx_perf_font as font
        identity = dict(executable='actual.exe', executable_sha256='a' * 64,
                        launcher='entry.exe', launcher_sha256='b' * 64)
        for module, expected in ((stimulus, b'GX C7 owned console\r\n'), (font, font.READY)):
            with self.subTest(module=module.__name__), tempfile.TemporaryDirectory() as tmp, \
                 mock.patch.dict(sys.modules, {'msvcrt': mock.Mock(kbhit=mock.Mock(return_value=False))}), \
                 mock.patch.object(module.os, 'O_BINARY', 0x8000, create=True), \
                 mock.patch.object(stimulus, 'console_output_utf8', return_value=dict(before=936, after=65001, set_success=True, stdout_mode=7)), \
                 mock.patch.object(stimulus, 'python_identity', return_value=identity), \
                 mock.patch.object(stimulus, 'append_json') as append, \
                 mock.patch.object(module.os, 'write', side_effect=lambda fd, data: len(data)) as write, \
                 mock.patch.object(module.time, 'sleep', side_effect=StopIteration):
                with self.assertRaises(StopIteration):
                    module.shell_main(Path(tmp), 'owned-token')
                self.assertEqual(write.call_args.args[1], expected)
                row = append.call_args.args[1]
                self.assertEqual(row['console_output_cp'], dict(before=936, after=65001, set_success=True, stdout_mode=7))
                self.assertEqual(row['event'], 'ready')
                self.assertEqual(row['token'], 'owned-token')
                for key, value in identity.items():
                    self.assertEqual(row[key], value)

    def test_c6_c7_launch_hash_and_receipt_bind_actual_image(self):
        import gx_perf_font as font
        with tempfile.TemporaryDirectory() as tmp:
            image, launcher = Path(tmp) / 'real python.exe', Path(tmp) / 'launcher.exe'
            image.write_bytes(b'actual'); launcher.write_bytes(b'launcher')
            with mock.patch.object(sys, 'platform', 'win32'), \
                 mock.patch.object(sys, 'executable', str(launcher)), \
                 mock.patch.object(ctypes, 'WinDLL', return_value=self.native(str(image)), create=True):
                for i, cls in enumerate((stimulus.OwnedShells, font.OwnedFontShell)):
                    shell = cls(Path(tmp) / str(i))
                    self.assertIn(subprocess.list2cmdline([str(image.resolve())]), shell.config())
                    identity = stimulus.python_identity()
                    self.assertEqual(shell.python_identity, identity)
                    self.assertNotIn(str(launcher), shell.config())
                    self.assertEqual(identity['executable_sha256'], stimulus.hashlib.sha256(b'actual').hexdigest())
                    self.assertEqual(identity['launcher'], str(launcher))
                    gui, instance = mock.Mock(), mock.Mock()
                    gui.same_path.side_effect = lambda a, b: a == b
                    gui.win32().process_image.return_value = str(image.resolve())
                    gui.win32().process_creation.return_value = 900
                    instance.contains_pid.return_value = True
                    row = dict(event='ready', pid=42, token=shell.token, **identity)
                    with mock.patch.object(shell, 'rows', return_value=[row]):
                        self.assertTrue(shell.ready(gui, instance, 1))
                        shell.verify(gui, instance)
                        for changes in ({'executable': str(launcher)}, {'executable': ''},
                                        {'executable_sha256': '0' * 64}):
                            with self.subTest(changes=changes), mock.patch.object(shell, 'rows', return_value=[dict(row, **changes)]):
                                with self.assertRaisesRegex(ValueError, 'identity'):
                                    shell.ready(gui, instance, 1)
                        for image_path, birth, owned in [(str(launcher), 900, True),
                                                       ('', 900, True), (str(image.resolve()), None, True),
                                                       (str(image.resolve()), 900, False)]:
                            gui.win32().process_image.return_value = image_path
                            gui.win32().process_creation.return_value = birth
                            instance.contains_pid.return_value = owned
                            with self.assertRaisesRegex(ValueError, 'identity'):
                                shell.ready(gui, instance, 1)
                            with self.assertRaisesRegex(ValueError, 'identity'):
                                shell.verify(gui, instance)


class PdhTests(unittest.TestCase):
    def assert_pending(self, sample):
        value = stimulus.pdh_summary([pdh_sample(), sample], 42)
        self.assertEqual(('PENDING', 0), (value['status'], value['n']))
        self.assertNotIn('switches', value)

    def test_foreign_duplicate_names_do_not_invalidate_owned_threads(self):
        samples = [pdh_sample(), pdh_sample(31, 200)]
        for sample in samples:
            for key, rows in sample['arrays'].items():
                for pid in (91, 92):
                    rows.append(dict(rows[0], name='other/0', first=pid))
                # Independent ordering is deliberately different per counter.
                if key in ('tid', 'switches'):
                    rows.reverse()
        value = stimulus.pdh_summary(samples, 42)
        self.assertEqual(('sampled', 1, 21), (value['status'], value['n'], value.get('switches')))

    def test_owned_identity_explicitly_includes_pid_tid_and_raw_birth(self):
        self.assertEqual({(42, 7, 55)}, set(stimulus.pdh_owned(pdh_sample(), 42)))

    def test_independently_reordered_owned_arrays_preserve_counts(self):
        samples = [pdh_sample(), pdh_sample(31, 200)]
        for index, sample in enumerate(samples):
            other = pdh_sample(100 + index * 9, 100 + index * 100, tid=8, birth=56)
            for key, rows in sample['arrays'].items():
                rows.append(dict(other['arrays'][key][0], name='ghostty/1'))
                if (key in ('pid', 'birth')) != bool(index):
                    rows.reverse()
            owned = stimulus.pdh_owned(sample, 42)
            self.assertEqual({(42, 7, 55): 10 if index == 0 else 31,
                              (42, 8, 56): 100 + index * 9},
                             {identity: row['first'] for identity, row in owned.items()})
        value = stimulus.pdh_summary(samples, 42)
        self.assertEqual(('sampled', 30), (value['status'], value['switches']))

    def test_target_name_collision_never_uses_first_or_occurrence_order(self):
        for foreign in (False, True):
            for reverse in (False, True):
                with self.subTest(foreign=foreign, reverse=reverse):
                    sample = pdh_sample(31, 200)
                    other = pdh_sample(500, 200, tid=8, birth=99, pid=91 if foreign else 42)
                    for key, rows in sample['arrays'].items():
                        rows.extend(other['arrays'][key])
                        if reverse:
                            rows.reverse()
                    self.assert_pending(sample)

    def test_missing_or_extra_array_rows_cannot_hide_owned_identity(self):
        for key in stimulus.PDH_PATHS:
            for change in ('missing', 'extra', 'renamed'):
                with self.subTest(counter=key, change=change):
                    sample = pdh_sample(31, 200)
                    if change == 'missing':
                        sample['arrays'][key].clear()
                    elif change == 'extra':
                        sample['arrays'][key].append(dict(sample['arrays'][key][0], name='orphan/0'))
                    else:
                        sample['arrays'][key][0]['name'] = 'orphan/0'
                    self.assert_pending(sample)

    def test_foreign_invalid_pid_cannot_be_silently_ignored(self):
        sample = pdh_sample(31, 200)
        for key, rows in sample['arrays'].items():
            rows.append(dict(rows[0], name='other/0', first=91,
                             status=0xc0000bba if key == 'pid' else 0))
        self.assert_pending(sample)

    def test_target_invalid_fields_and_mixed_collection_timestamps(self):
        mutations = [('tid', 'first', 0), ('tid', 'first', True),
                     ('birth', 'first', 0), ('birth', 'first', -1),
                     ('birth', 'first', 1.5), ('switches', 'first', -1),
                     ('switches', 'first', 2.5), ('pid', 'first', True)]
        mutations += [(key, 'timestamp_100ns', 201) for key in stimulus.PDH_PATHS]
        mutations += [(key, 'status', 0xc0000bba) for key in stimulus.PDH_PATHS]
        for key, field, value in mutations:
            with self.subTest(counter=key, field=field, value=value):
                sample = pdh_sample(31, 200)
                sample['arrays'][key][0][field] = value
                self.assert_pending(sample)

    def test_two_names_for_same_tid_are_ambiguous_even_with_different_birth(self):
        for birth in (55, 56):
            sample = pdh_sample(31, 200)
            other = pdh_sample(31, 200, birth=birth)
            for key, rows in sample['arrays'].items():
                rows.append(dict(other['arrays'][key][0], name='ghostty/1'))
            self.assert_pending(sample)

    def test_new_data_status_and_zero_delta_are_valid_without_synthesis(self):
        first, last = pdh_sample(), pdh_sample(10, 200)
        for sample in (first, last):
            for rows in sample['arrays'].values():
                rows[0]['status'] = 1
        original = copy.deepcopy([first, last])
        result = stimulus.pdh_summary([first, last], 42)
        self.assertEqual(('sampled', 0), (result['status'], result['switches']))
        self.assertEqual(original, [first, last])


    def test_raw_counts_are_joined_by_pid_tid_and_birth(self):
        first, last = pdh_sample(), pdh_sample(31, 200)
        # Instance names may be reused/renumbered. The actual identity wins.
        for rows in last['arrays'].values():
            rows[0]['name'] = 'ghostty#1/0'
        value = stimulus.pdh_summary([first, last], 42)
        self.assertEqual(('sampled', 1, 21), (value['status'], value['n'], value['switches']))
        self.assertEqual('', value['unit'])

    def test_churn_reused_tid_and_absent_pid_are_not_zero(self):
        for last in (pdh_sample(0, 200, tid=8), pdh_sample(0, 200, birth=56), pdh_sample(10, 200, pid=99)):
            value = stimulus.pdh_summary([pdh_sample(), last], 42)
            self.assertEqual(('PENDING', 0), (value['status'], value['n']))
            self.assertNotIn('switches', value)

    def test_missing_bad_status_duplicate_and_regressed_counters(self):
        samples = []
        missing = pdh_sample(20, 200)
        missing['arrays']['switches'] = []
        samples.append(missing)
        invalid = pdh_sample(20, 200)
        invalid['arrays']['switches'][0]['status'] = 0xc0000bba
        samples.append(invalid)
        duplicate = pdh_sample(20, 200)
        duplicate['arrays']['pid'] *= 2
        samples += [duplicate, pdh_sample(9, 200), pdh_sample(20, 100)]
        for sample in samples:
            with self.subTest(sample=sample):
                result = stimulus.pdh_summary([pdh_sample(), sample], 42)
                self.assertEqual(0, result['n'])
                self.assertNotIn('switches', result)

    def test_counter_failure_classification_is_not_blanket_environment_pending(self):
        self.assertTrue(stimulus.PdhFailure('add', 0xc0000bb9).unavailable)
        self.assertFalse(stimulus.PdhFailure('query', 0xc0000bbc).unavailable)

    def test_live_query_binds_english_paths_and_closes_on_add_failure(self):
        dll = mock.Mock()
        def opened(_source, _context, handle):
            handle._obj.value = 123
            return 0
        dll.PdhOpenQueryW.side_effect = opened
        dll.PdhAddEnglishCounterW.return_value = 0xc0000bb9
        with mock.patch.object(ctypes, 'WinDLL', return_value=dll, create=True):
            with self.assertRaises(stimulus.PdhFailure):
                stimulus.PdhThreads()
        self.assertEqual(stimulus.PDH_PATHS['pid'], dll.PdhAddEnglishCounterW.call_args.args[1])
        dll.PdhCloseQuery.assert_called_once()

    def test_sampling_failure_preserves_operation_and_unsigned_status(self):
        with self.assertRaises(stimulus.PdhFailure) as raised:
            stimulus.PdhThreads.check('raw array', 0x800007d5)
        self.assertIn('0x800007d5', str(raised.exception))
        self.assertEqual('raw array', raised.exception.operation)


def indexed_pdh_sample(count=10, stamp=100, target_index=1):
    """Two native paths, with identical wildcard szName and independent order."""
    target = pdh_sample(count, stamp)
    helper = pdh_sample(900, stamp, pid=91, tid=8, birth=56)
    types = dict(pid=65536, tid=65536, birth=807666944, switches=272696320)
    sample = {'arrays': {}, 'indexed': {'source': dict(stimulus.PDH_PATHS), 'types': types, 'arrays': {}}}
    for key in stimulus.PDH_PATHS:
        rows = [target['arrays'][key][0], helper['arrays'][key][0]]
        sample['arrays'][key] = copy.deepcopy(rows[::-1] if key in ('tid', 'birth') else rows)
        sample['indexed']['arrays'][key] = [dict(row, type=types[key], path=stimulus.PDH_PATHS[key].replace(
            '*', 'ghostty/0' + ('#1' if index else '')))
            for index, row in ((target_index, rows[0]), (1 - target_index, rows[1]))]
        if key in ('pid', 'switches'):
            sample['indexed']['arrays'][key].reverse()
    return sample


class IndexedPdhTests(unittest.TestCase):
    def test_non_multi_counter_types_do_not_compare_unused_multicount(self):
        samples = [indexed_pdh_sample(), indexed_pdh_sample(31, 200)]
        for sample in samples:
            for rows in sample['arrays'].values():
                for row in rows:
                    row['multi'] = 0  # Native wildcard=0, scalar=1.
        original = copy.deepcopy(samples)
        value = stimulus.pdh_summary(samples, 42)
        self.assertEqual(('sampled', 21), (value['status'], value.get('switches')))
        self.assertEqual(original, samples)
        for kind in ('no-types', 'unknown-type', 'multi-type', 'scalar-type', 'missing-scalar-type'):
            with self.subTest(kind=kind):
                changed = copy.deepcopy(samples)
                indexed = changed[-1]['indexed']
                if kind == 'no-types':
                    del indexed['types']
                elif kind in ('unknown-type', 'multi-type'):
                    indexed['types']['pid'] = 0 if kind == 'unknown-type' else 0x02010000
                elif kind == 'scalar-type':
                    indexed['arrays']['pid'][0]['type'] = 0x02010000
                else:
                    del indexed['arrays']['pid'][0]['type']
                value = stimulus.pdh_summary(changed, 42)
                self.assertEqual(('PENDING', 0), (value['status'], value['n']))
                self.assertNotIn('switches', value)

    def test_native_machine_prefix_matches_only_recorded_local_machine(self):
        samples = [indexed_pdh_sample(), indexed_pdh_sample(31, 200)]
        for sample in samples:
            sample['indexed']['local_machine'] = 'GX'
            for rows in sample['indexed']['arrays'].values():
                for row in rows:
                    row['path'] = r'\\GX' + row['path']
        original = copy.deepcopy(samples)
        value = stimulus.pdh_summary(samples, 42)
        self.assertEqual(('sampled', 21), (value['status'], value.get('switches')))
        self.assertEqual(original, samples)
        for change in ('missing-machine', 'foreign-machine', 'foreign-source', 'object', 'counter'):
            with self.subTest(change=change):
                changed = copy.deepcopy(samples)
                indexed = changed[-1]['indexed']
                if change == 'missing-machine':
                    del indexed['local_machine']
                elif change in ('foreign-machine', 'foreign-source'):
                    for key, rows in indexed['arrays'].items():
                        for row in rows:
                            row['path'] = row['path'].replace(r'\\GX', r'\\OTHER')
                        if change == 'foreign-source':
                            indexed['source'][key] = r'\\OTHER' + indexed['source'][key]
                else:
                    row = indexed['arrays']['pid'][0]
                    row['path'] = row['path'].replace('Thread(', 'Process(') if change == 'object' else row['path'].replace('ID Process', 'ID Thread')
                value = stimulus.pdh_summary(changed, 42)
                self.assertEqual(('PENDING', 0), (value['status'], value['n']))
                self.assertNotIn('switches', value)

    def test_native_index_paths_disambiguate_without_array_order(self):
        samples = [indexed_pdh_sample(), indexed_pdh_sample(31, 200, target_index=0)]
        original = copy.deepcopy(samples)
        value = stimulus.pdh_summary(samples, 42)
        self.assertEqual(('sampled', 1, 21), (value['status'], value['n'], value.get('switches')))
        self.assertEqual(original, samples)

    def test_old_raw_duplicates_still_fail_without_native_path_evidence(self):
        sample = indexed_pdh_sample(31, 200)
        del sample['indexed']
        value = stimulus.pdh_summary([indexed_pdh_sample(), sample], 42)
        self.assertEqual(('PENDING', 0), (value['status'], value['n']))
        self.assertIn('duplicate owned', value['reason'])
        self.assertNotIn('switches', value)

    def test_new_scalar_data_status_is_valid_and_raw_is_not_relabelled(self):
        samples = [indexed_pdh_sample(), indexed_pdh_sample(31, 200)]
        for sample in samples:
            for rows in sample['indexed']['arrays'].values():
                for row in rows:
                    row['status'] = 1
        original = copy.deepcopy(samples)
        value = stimulus.pdh_summary(samples, 42)
        self.assertEqual(('sampled', 21), (value['status'], value.get('switches')))
        self.assertEqual(original, samples)

    def test_indexed_coverage_and_identity_fail_closed(self):
        def wrong_source(sample):
            sample['indexed']['source']['pid'] = r'\Process(*)\ID Process'
        def duplicate_zero(sample):
            for key, rows in sample['indexed']['arrays'].items():
                for row in rows:
                    row['path'] = stimulus.PDH_PATHS[key].replace('*', 'ghostty/0#0')
        mutations = [wrong_source, duplicate_zero]
        for key in stimulus.PDH_PATHS:
            mutations += [lambda s, k=key: s['indexed']['arrays'][k].pop(),
                          lambda s, k=key: s['indexed']['arrays'][k][0].update(first=12345),
                          lambda s, k=key: s['indexed']['arrays'][k][0].update(timestamp_100ns=201),
                          lambda s, k=key: s['indexed']['arrays'][k][0].update(status=0xc0000bba),
                          lambda s, k=key: s['indexed']['arrays'][k][0].update(path=r'\Thread(*)\ID Process')]
        for i, mutate in enumerate(mutations):
            with self.subTest(mutation=i):
                sample = indexed_pdh_sample(31, 200)
                mutate(sample)
                value = stimulus.pdh_summary([indexed_pdh_sample(), sample], 42)
                self.assertEqual(('PENDING', 0), (value['status'], value['n']))
                self.assertNotIn('switches', value)

    def test_indexed_path_birth_and_thread_churn_remain_missing(self):
        for key, changed in [('birth', 99), ('tid', 9), ('switches', 9)]:
            sample = indexed_pdh_sample(31, 200)
            # Change the same target in both native views, so coverage is valid.
            for row in sample['arrays'][key]:
                if row['first'] == {'birth': 55, 'tid': 7, 'switches': 31}[key]:
                    row['first'] = changed
            for row in sample['indexed']['arrays'][key]:
                if '#1)' in row['path']:
                    row['first'] = changed
            value = stimulus.pdh_summary([indexed_pdh_sample(), sample], 42)
            self.assertEqual(('PENDING', 0), (value['status'], value['n']))
            self.assertNotIn('switches', value)


class FakeIndexedPdh:
    """PDH ABI fixture: native path handles, never array position, select values."""
    class Raw(ctypes.Structure):
        _fields_ = [('status', ctypes.c_uint32), ('timestamp', ctypes.c_uint32 * 2),
                    ('first', ctypes.c_int64), ('second', ctypes.c_int64), ('multi', ctypes.c_uint32)]

    def __init__(self):
        self.dll = mock.Mock()
        self.handles = {}
        self.keepalive = []
        self.snapshot = indexed_pdh_sample()
        self.paths = {key: rf'\线程(*)\{name}' for key, name in
                      zip(stimulus.PDH_PATHS, ('进程标识', '线程标识', '运行时间', '上下文切换/秒'))}
        self.expansions = [self.paths['pid'].replace('*', name) for name in ('ghostty/0', 'ghostty/0#1')]
        self.collects = 0
        self.add_failure = 0
        self.expand_failure = 0
        self.grow_once = False
        self.on_collect = None
        self.dll.PdhOpenQueryW.side_effect = self.open
        self.dll.PdhAddEnglishCounterW.side_effect = self.add_english
        self.dll.PdhGetCounterInfoW.side_effect = self.info
        self.dll.PdhExpandWildCardPathW.side_effect = self.expand
        self.dll.PdhAddCounterW.side_effect = self.add_localized
        self.dll.PdhRemoveCounter.side_effect = self.remove
        self.dll.PdhCollectQueryData.side_effect = self.collect
        self.dll.PdhGetRawCounterArrayW.side_effect = self.array
        self.dll.PdhGetRawCounterValue.side_effect = self.value
        self.dll.PdhCloseQuery.return_value = 0
        self.dll.GetComputerNameW.side_effect = self.computer_name

    def computer_name(self, buffer, size):
        buffer.value = 'GX'
        size._obj.value = 2
        return 1

    def open(self, _source, _context, handle):
        handle._obj.value = 123
        return 0

    def add_handle(self, path, handle):
        handle._obj.value = max(self.handles, default=0) + 1
        self.handles[handle._obj.value] = path
        return 0

    def add_english(self, _query, path, _context, handle):
        key = next(key for key, value in stimulus.PDH_PATHS.items() if value == path)
        return self.add_handle(self.paths[key], handle)

    def add_localized(self, _query, path, _context, handle):
        return self.add_failure or self.add_handle(path, handle)

    def remove(self, handle):
        del self.handles[handle.value]
        return 0

    def info(self, handle, _explain, size, buffer):
        class Header(ctypes.Structure):
            _fields_ = [('fixed', ctypes.c_uint32 * 6), ('contexts', ctypes.c_size_t * 2),
                        ('path', ctypes.c_wchar_p)]
        size._obj.value = ctypes.sizeof(Header)
        if buffer is None:
            return 0x800007d2
        header = Header.from_buffer(buffer)
        header.path = self.handles[handle.value]
        key = next(key for key, path in self.paths.items() if path == header.path)
        header.fixed[1] = self.snapshot['indexed']['types'][key]
        self.keepalive.append(header)
        return 0

    def expand(self, _source, path, buffer, size, flags):
        assert path == self.paths['pid'] and flags in (0, 4)
        if buffer is not None:
            assert flags == 0
        if self.expand_failure:
            return self.expand_failure
        text = '\0'.join(self.expansions) + '\0\0'
        size._obj.value = len(text)
        if buffer is None:
            return 0x800007d2
        if self.grow_once:
            self.grow_once = False
            size._obj.value = 999999  # Not a trustworthy resize result.
            return 0x800007d2
        buffer[:len(text)] = text
        return 0

    def collect(self, _query):
        self.collects += 1
        if self.on_collect:
            self.on_collect(self.collects)
        return 0

    def set_raw(self, raw, row):
        raw.status, raw.first, raw.second, raw.multi = (row[key] for key in ('status', 'first', 'second', 'multi'))
        raw.timestamp[:] = (row['timestamp_100ns'] & 0xffffffff, row['timestamp_100ns'] >> 32)

    def array(self, handle, size, count, buffer):
        key = next(key for key, path in self.paths.items() if path == self.handles[handle.value])
        rows = self.snapshot['arrays'][key]
        class Item(ctypes.Structure):
            _fields_ = [('name', ctypes.c_wchar_p), ('raw', FakeIndexedPdh.Raw)]
        count._obj.value, size._obj.value = len(rows), len(rows) * ctypes.sizeof(Item)
        if buffer is None:
            return 0x800007d2
        items = (Item * len(rows)).from_buffer(buffer)
        for item, row in zip(items, rows):
            item.name = row['name']
            self.set_raw(item.raw, row)
        self.keepalive.append(items)
        return 0

    def value(self, handle, _type, raw):
        path = self.handles[handle.value]
        key = next(key for key, source in self.paths.items() if path.rsplit('\\', 1)[1] == source.rsplit('\\', 1)[1])
        instance = path.split('(', 1)[1].split(')', 1)[0]
        row = next(row for row in self.snapshot['indexed']['arrays'][key]
                   if row['path'].split('(', 1)[1].split(')', 1)[0] == instance)
        self.set_raw(raw._obj, row)
        if _type is not None:
            _type._obj.value = row['type']
        return 0


class PdhExpansionTests(unittest.TestCase):
    def collector(self, expand):
        collector = stimulus.PdhThreads.__new__(stimulus.PdhThreads)
        collector.expand = expand
        return collector

    def test_refreshes_once_and_returns_every_path_from_the_native_list(self):
        paths = [r'\\GX\Thread(ghostty/0)\ID Process']
        flags_seen = []
        def expand(_source, _path, buffer, size, flags):
            flags_seen.append(flags)
            if flags & 4:
                paths.append(rf'\\GX\Thread(worker/{len(paths)})\ID Process')
            text = '\0'.join(paths) + '\0\0'
            supplied = size._obj.value
            size._obj.value = len(text)
            if buffer is None or supplied < len(text):
                return 0x800007d2
            buffer[:len(text)] = text
            return 0
        result = self.collector(expand).expanded_paths(stimulus.PDH_PATHS['pid'])
        self.assertEqual(paths, result)
        self.assertEqual([4, 0], flags_seen)

    def test_growth_resizes_from_zero_length_query_not_failed_data_length(self):
        paths = [r'\\GX\Thread(ghostty/0)\ID Process']
        flags_seen, capacities = [], []
        def expand(_source, _path, buffer, size, flags):
            flags_seen.append(flags)
            if buffer is not None:
                capacities.append(size._obj.value)
                if len(capacities) == 1:
                    paths.extend(rf'\\GX\Thread(worker/{i})\ID Process' for i in range(100))
                    size._obj.value = 0xffffffff  # Documented as untrustworthy on this failure.
                    return 0x800007d2
            text = '\0'.join(paths) + '\0\0'
            supplied = size._obj.value
            size._obj.value = len(text)
            if buffer is None or supplied < len(text):
                return 0x800007d2
            buffer[:len(text)] = text
            return 0
        result = self.collector(expand).expanded_paths(stimulus.PDH_PATHS['pid'])
        self.assertEqual(paths, result)
        self.assertEqual([4, 0, 0, 0], flags_seen)
        self.assertGreater(capacities[1], capacities[0])
        self.assertLess(capacities[1], 100_000)

    def test_continuous_growth_still_fails_after_four_data_attempts(self):
        flags_seen, capacities = [], []
        def expand(_source, _path, buffer, size, flags):
            flags_seen.append(flags)
            if buffer is None:
                size._obj.value = 64
            else:
                capacities.append(size._obj.value)
                size._obj.value = 0xffffffff
            return 0x800007d2
        with self.assertRaisesRegex(stimulus.PdhFailure, 'retry limit'):
            self.collector(expand).expanded_paths(stimulus.PDH_PATHS['pid'])
        self.assertEqual(4, len(capacities))
        self.assertEqual(1, flags_seen.count(4))
        self.assertTrue(all(b > a for a, b in zip(capacities, capacities[1:])))

    def test_oversized_required_list_rejects_without_allocating_or_dropping_paths(self):
        def expand(_source, _path, _buffer, size, _flags):
            size._obj.value = 0xffffffff
            return 0x800007d2
        with mock.patch.object(ctypes, 'create_unicode_buffer', side_effect=AssertionError('unbounded allocation')):
            with self.assertRaisesRegex(ValueError, 'buffer budget'):
                self.collector(expand).expanded_paths(stimulus.PDH_PATHS['pid'])

    def test_multisz_zero_padding_is_not_an_empty_instance(self):
        path = r'\\GX\Thread(ghostty/0#1)\ID Process'
        def expand(_source, _path, buffer, size, _flags):
            if buffer is None:
                size._obj.value = len(path) + 8
                return 0x800007d2
            text = path + '\0\0' + '\0' * 6
            buffer[:len(text)] = text
            size._obj.value = len(text)
            return 0
        self.assertEqual([path], self.collector(expand).expanded_paths(stimulus.PDH_PATHS['pid']))

    def test_nonzero_data_after_multisz_terminator_is_not_silently_dropped(self):
        text = '\\Thread(ghostty/0)\\ID Process\0\0\\Thread(ghostty/0#1)\\ID Process\0\0'
        def expand(_source, _path, buffer, size, _flags):
            size._obj.value = len(text)
            if buffer is None:
                return 0x800007d2
            buffer[:len(text)] = text
            return 0
        with self.assertRaises(ValueError):
            self.collector(expand).expanded_paths(stimulus.PDH_PATHS['pid'])


class NativeIndexedPdhTests(unittest.TestCase):
    def test_prebound_collection_never_discovers_or_recollects_in_window(self):
        fake = FakeIndexedPdh()
        with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
            collector = stimulus.PdhThreads(pid=42)
            try:
                preparation = collector.prepare()
                expanded = fake.dll.PdhExpandWildCardPathW.call_count
                before = fake.collects
                token = collector.capture()
                row = collector.read(token)
                self.assertEqual(before + 1, fake.collects)
                self.assertEqual(expanded, fake.dll.PdhExpandWildCardPathW.call_count)
                self.assertEqual(8, fake.dll.PdhAddCounterW.call_count)
                self.assertLessEqual(preparation['qpc_end_ns'], row['collection_qpc_begin_ns'])
                self.assertLessEqual(row['collection_qpc_end_ns'], row['qpc_end_ns'])
                collector.capture()
                with self.assertRaisesRegex(ValueError, 'overwritten'):
                    collector.read(token)
            finally:
                collector.close()

    def test_recorded_types_support_native_multicount_difference(self):
        fake = FakeIndexedPdh()
        fake.expansions = [r'\\GX' + path for path in fake.expansions]
        for rows in fake.snapshot['arrays'].values():
            for row in rows:
                row['multi'] = 0
        with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
            collector = stimulus.PdhThreads(pid=42)
            try:
                row = collector.sample()
            finally:
                collector.close()
        self.assertEqual({(42, 7, 55)}, set(stimulus.pdh_owned(row, 42)))
        self.assertEqual(fake.snapshot['indexed']['types'], row['indexed']['types'])
        self.assertEqual({0}, {x['multi'] for x in row['arrays']['pid']})
        self.assertEqual({1}, {x['multi'] for x in row['indexed']['arrays']['pid']})

    def test_native_machine_qualified_expansion_from_local_source(self):
        fake = FakeIndexedPdh()
        fake.expansions = [r'\\GX' + path for path in fake.expansions]
        with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
            collector = stimulus.PdhThreads(pid=42)
            try:
                first = collector.sample()
                fake.snapshot = indexed_pdh_sample(31, 200)
                last = collector.sample()
            finally:
                collector.close()
        value = stimulus.pdh_summary([first, last], 42)
        self.assertEqual(('sampled', 21), (value['status'], value.get('switches')))
        self.assertEqual('GX', last['indexed']['local_machine'])
        self.assertEqual(fake.paths, last['indexed']['source'])
        fake.dll.GetComputerNameW.assert_called_once()

    def test_untrusted_machine_or_counter_is_rejected_before_adding_handles(self):
        for kind in ('remote', 'counter', 'counter-type', 'missing-local-name'):
            with self.subTest(kind=kind):
                fake = FakeIndexedPdh()
                if kind == 'remote':
                    fake.expansions = [r'\\OTHER' + path for path in fake.expansions]
                elif kind == 'counter':
                    fake.expansions[0] = fake.expansions[0].replace('进程标识', '线程标识')
                elif kind == 'counter-type':
                    fake.snapshot['indexed']['types']['pid'] = 0
                else:
                    fake.dll.GetComputerNameW.side_effect = None
                    fake.dll.GetComputerNameW.return_value = 0
                with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
                    collector = stimulus.PdhThreads(pid=42)
                    try:
                        row = collector.sample()
                    finally:
                        collector.close()
                self.assertIn('indexed_error', row)
                fake.dll.PdhAddCounterW.assert_not_called()
                value = stimulus.pdh_summary([row, row], 42)
                self.assertEqual(('PENDING', 0), (value['status'], value['n']))

    def test_localized_native_paths_resolve_helper_and_index_renumbering(self):
        fake = FakeIndexedPdh()
        fake.grow_once = True
        with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
            collector = stimulus.PdhThreads(pid=42)
            try:
                first = collector.sample()
                fake.snapshot = indexed_pdh_sample(31, 200, target_index=0)
                last = collector.sample()
            finally:
                collector.close()
                collector.close()
        value = stimulus.pdh_summary([first, last], 42)
        self.assertEqual(('sampled', 21), (value['status'], value.get('switches')))
        self.assertEqual(3, fake.collects)  # one discovery, two measured collections
        self.assertEqual(fake.snapshot['arrays'], last['arrays'])
        self.assertEqual(fake.paths, last['indexed']['source'])
        self.assertEqual(8, fake.dll.PdhAddCounterW.call_count)
        self.assertTrue(all('线程(' in call.args[1] for call in fake.dll.PdhAddCounterW.call_args_list))
        fake.dll.PdhCloseQuery.assert_called_once()

    def test_native_path_unavailable_or_duplicate_preserves_raw_pending(self):
        for failure in ('missing', 'duplicate', 'no_index', 'add'):
            with self.subTest(failure=failure):
                fake = FakeIndexedPdh()
                if failure == 'missing':
                    fake.expand_failure = 0xc0000bb8
                elif failure == 'duplicate':
                    fake.expansions *= 2
                elif failure == 'no_index':
                    fake.expansions = fake.expansions[:1]
                else:
                    fake.add_failure = 0xc0000bb9
                with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
                    collector = stimulus.PdhThreads(pid=42)
                    try:
                        row = collector.sample()
                    finally:
                        collector.close()
                self.assertEqual(fake.snapshot['arrays'], row['arrays'])
                value = stimulus.pdh_summary([row, row], 42)
                self.assertEqual(('PENDING', 0), (value['status'], value['n']))
                self.assertNotIn('switches', value)

    def test_discovery_and_measurement_are_not_mixed_across_collections(self):
        fake = FakeIndexedPdh()
        def change_on_second(n):
            if n == 2:
                fake.snapshot = indexed_pdh_sample(31, 200, target_index=0)
        fake.on_collect = change_on_second
        with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
            collector = stimulus.PdhThreads(pid=42)
            try:
                row = collector.sample()
            finally:
                collector.close()
        owned = stimulus.pdh_owned(row, 42)
        self.assertEqual(31, owned[(42, 7, 55)]['first'])
        self.assertEqual(200, owned[(42, 7, 55)]['timestamp_100ns'])

    def test_uncovered_thread_arrival_after_discovery_is_pending(self):
        fake = FakeIndexedPdh()
        def add_on_second(n):
            if n == 2:
                extra = pdh_sample(50, pid=42, tid=10, birth=60)
                for key, rows in fake.snapshot['arrays'].items():
                    rows.extend(extra['arrays'][key])
        fake.on_collect = add_on_second
        with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
            collector = stimulus.PdhThreads(pid=42)
            try:
                row = collector.sample()
            finally:
                collector.close()
        value = stimulus.pdh_summary([row, row], 42)
        self.assertEqual(('PENDING', 0), (value['status'], value['n']))
        self.assertIn('coverage', value['reason'])

    def test_legacy_factory_and_unique_target_do_not_expand_foreign_duplicates(self):
        for pid in (None, 123):
            fake = FakeIndexedPdh()
            if pid == 123:
                for key, rows in fake.snapshot['arrays'].items():
                    rows.append(dict(pdh_sample(pid=123)['arrays'][key][0], name='target/0'))
            with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
                collector = stimulus.PdhThreads(pid=pid)
                try:
                    row = collector.sample()
                finally:
                    collector.close()
            self.assertEqual(2, fake.collects)  # preparation plus one measurement
            fake.dll.PdhExpandWildCardPathW.assert_not_called()
            self.assertNotIn('indexed', row)

    def test_unknown_native_failure_is_not_converted_to_environment_pending(self):
        fake = FakeIndexedPdh()
        fake.expand_failure = 0xc0000bbc
        with mock.patch.object(ctypes, 'WinDLL', return_value=fake.dll, create=True):
            collector = stimulus.PdhThreads(pid=42)
            try:
                with self.assertRaises(stimulus.PdhFailure):
                    collector.sample()
            finally:
                collector.close()
        fake.dll.PdhCloseQuery.assert_called_once()


class ShellEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.shells = stimulus.OwnedShells(Path(self.temp.name) / 'console')

    def receipt(self, **fields):
        stimulus.append_json(self.shells.directory / 'shell-42.jsonl',
                             {'pid': 42, 'token': self.shells.token, **fields})

    def test_receipts_accept_crlf_and_defer_partial_lines(self):
        path = self.shells.directory / 'shell-42.jsonl'
        path.write_bytes(b'{"event":"ready"}\r\n{"event":')
        self.assertEqual([{'event': 'ready'}], stimulus.read_rows(path))

    def test_animation_payload_uses_protocol_frames_not_repeated_screen_output(self):
        data = stimulus.kitty_animation_payload()
        self.assertEqual(3, data.count(b'\x1b_G'))
        self.assertEqual(3, data.count(b'\x1b\\'))
        self.assertIn(b'a=f,i=7,f=24,s=1,v=1,z=250', data)
        self.assertIn(b'a=a,i=7,r=1,z=250,s=3,v=1', data)
        self.assertIn('sin(iTime', stimulus.ANIMATION_SHADER)

    def test_output_command_and_ack_keep_bytes_clock_and_writer(self):
        self.shells.identities[42] = 900
        command = self.shells.command('output', bytes=4096)
        self.assertTrue(command['qpc_ns'] > 0 and command['time_ns'] > 0)
        self.receipt(event='output', id=command['id'], written_bytes=4096,
                     requested_bytes=4096, sha256=stimulus.hashlib.sha256(stimulus.output_payload(command)).hexdigest(),
                     write_begin_qpc_ns=command['qpc_ns'] + 1, qpc_ns=command['qpc_ns'] + 2)
        self.assertEqual(4096, self.shells.output_receipts(command)[0]['written_bytes'])
        with self.assertRaisesRegex(ValueError, 'outside'):
            self.shells.output_receipts(command, command['qpc_ns'] + 1)
        self.assertEqual([], list(self.shells.directory.glob('*.tmp')))

    def test_foreign_token_wrong_bytes_and_duplicate_ack_are_rejected(self):
        self.shells.identities[42] = 900
        command = self.shells.command('output', bytes=4096)
        self.receipt(event='output', id=command['id'], written_bytes=99)
        with self.assertRaisesRegex(ValueError, 'byte count'):
            self.shells.output_receipts(command)
        self.receipt(event='output', id=command['id'], written_bytes=4096)
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.shells.output_receipts(command)
        stimulus.append_json(self.shells.directory / 'shell-99.jsonl', {'token': 'foreign'})
        with self.assertRaisesRegex(ValueError, 'token'):
            self.shells.rows()

    def test_shell_ownership_binds_creation_and_image(self):
        self.receipt(event='ready', **self.shells.python_identity)
        gui, instance = mock.Mock(), mock.Mock()
        instance.contains_pid.return_value = True
        gui.same_path.return_value = True
        gui.win32().process_creation.return_value = 900
        self.assertTrue(self.shells.ready(gui, instance, 1))
        gui.win32().process_creation.return_value = 901
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.shells.verify(gui, instance)

    def test_ime_requires_existing_chinese_layout_without_loading_or_unicode(self):
        gui, instance = mock.Mock(), mock.Mock()
        gui.win32().keyboard_layout.return_value = 0x04090409
        instance.focused_terminal.return_value = 9
        result = stimulus.ime_state(gui, instance)
        self.assertEqual('PENDING', result['status'])
        self.assertFalse(result['layout_changed'])
        instance.type_text.assert_not_called()
        instance.layout.assert_not_called()
        gui.win32().PostMessageW.assert_not_called()

    def test_ime_queries_owned_default_window_without_setting_mode(self):
        gui, instance, dll = mock.Mock(), mock.Mock(), mock.Mock()
        instance.pid, instance.focused_terminal.return_value = 42, 9
        gui.win32().keyboard_layout.return_value = 0x08040804
        gui.win32().window_pid.return_value = 42
        gui.win32().send_message.side_effect = [1, 1]
        dll.ImmGetDefaultIMEWnd.return_value = 10
        with mock.patch.object(ctypes, 'WinDLL', return_value=dll, create=True):
            result = stimulus.ime_state(gui, instance)
        self.assertEqual('ready', result['status'])
        self.assertEqual([mock.call(10, 0x283, 5), mock.call(10, 0x283, 1)],
                         gui.win32().send_message.call_args_list)
        instance.press.assert_not_called()


class PresentFixture:
    class RECT(ctypes.Structure):
        _fields_ = [(name, ctypes.c_long) for name in ('left', 'top', 'right', 'bottom')]

    def __init__(self, count=1, sequence=10):
        self.count, self.sequence = count, sequence
        self.outer = [0, 0, 1000, 700]
        self.size, self.frame_size = [900, 650], [900, 650]
        self.birth, self.revision, self.generation = 900, 3, 2
        self.status, self.absent, self.version = 1, False, 1
        self.events, self.polls = [], 0
        self.change = lambda stage: None
        self.instance = mock.Mock(pid=42, creation=900)
        self.instance.require_window.side_effect = lambda: SimpleNamespace(hwnd=1, rect=tuple(self.outer))
        self.instance.terminals.side_effect = lambda info: [SimpleNamespace(hwnd=10 + i) for i in range(self.count)]
        self.instance.resize.side_effect = self.resize
        self.gui = SimpleNamespace(win32=lambda: self)
        self.backdrop = mock.Mock()
        self.backdrop.capture.return_value.save_png.side_effect = self.save

    def resize(self, width, height):
        self.events.append('resize')
        self.outer = [0, 0, width, height]
        self.size = [width - 100, height - 50]
        return 16.0

    def save(self, path):
        self.events.append('capture')
        path.write_bytes(b'owned fixture image')
        self.change('capture')

    def process_creation(self, pid):
        return self.birth

    def window_pid(self, hwnd):
        return 42

    def raw_window_rect(self, hwnd):
        return self.outer if hwnd == 1 else [0, 0, *self.size]

    def GetClientRect(self, hwnd, rect):
        rect._obj.right, rect._obj.bottom = self.size
        return 1

    def send_message(self, hwnd, message, selector, argument, timeout_ms):
        assert message == 0x450 and timeout_ms > 0
        if self.absent:
            return 0
        if selector == 13:
            return self.count
        if selector == 17:
            # Intentionally return signed LRESULT to exercise wrap/high-bit replies.
            word = self.sequence << 32 | self.frame_size[1] << 16 | self.frame_size[0]
            return ctypes.c_int64(word).value
        if selector == 18:
            return self.size[1] << 32 | self.size[0]
        field, leaf = argument & 255, argument >> 8
        return [stimulus.P7_MAGIC << 32 | self.version << 16 | self.status,
                self.size[1] << 32 | self.size[0], self.generation,
                self.revision, 91, 92, 41 + leaf, 9 + leaf][field]

    def stage(self, stage):
        self.events.append(stage)
        if stage == 'poll':
            self.polls += 1
            self.sequence = (self.sequence + 1) & 0xffffffff
            # An advanced OLD-sized frame must not release the screenshot.
            if self.polls >= 2:
                self.frame_size = self.size[:]
        self.change(stage)


class StrictPresentTests(unittest.TestCase):
    def run_capture(self, fixture, *, raises=None, timeout=0.15):
        raw = {}
        clock = [0.0]
        def now():
            clock[0] += 0.00002
            return clock[0]
        original = stimulus.PresentQuery.snapshot
        def snapshot(probe, stage, deadline):
            fixture.stage(stage)
            return original(probe, stage, deadline)
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(stimulus.PresentQuery, 'snapshot', snapshot), \
                mock.patch.object(stimulus.time, 'perf_counter', side_effect=now), \
                mock.patch.object(stimulus.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                mock.patch.object(stimulus, 'dwm_flush', side_effect=lambda: fixture.events.append('flush')):
            png = Path(tmp) / 'resize.png'
            if raises:
                with self.assertRaisesRegex(stimulus.StrictFrameError, raises):
                    stimulus.strict_resize_capture(fixture.gui, fixture.instance, 900, 650, png,
                                                    fixture.backdrop, raw, timeout)
                self.assertEqual('FAIL', raw['status'])
                self.assertFalse(raw['strict_final_frame'])
            else:
                self.assertEqual(16.0, stimulus.strict_resize_capture(fixture.gui, fixture.instance, 900, 650,
                                 png, fixture.backdrop, raw, timeout))
            raw['png_retained'] = png.exists()
        return raw

    def test_new_successful_size_all_leaves_then_flush_and_protected_capture(self):
        fixture = PresentFixture(count=2)
        raw = self.run_capture(fixture)
        self.assertEqual(('PASS', True), (raw['status'], raw['strict_final_frame']))
        self.assertEqual(2, fixture.polls)
        self.assertEqual(['before_setwindowpos', 'resize', 'after_setwindowpos', 'poll', 'poll',
                          'flush', 'before_capture', 'capture', 'after_capture'], fixture.events)
        self.assertEqual(2, len(raw['matched']['leaves']))
        self.assertTrue(raw['queries'])
        fixture.instance.responsive.assert_not_called()
        fixture.backdrop.capture.assert_called_once()

    def test_failed_present_and_no_advance_timeout_keep_raw_without_capture(self):
        for mode in ('failedpresent', 'noadvance', 'wrongsize'):
            fixture = PresentFixture()
            def change(stage):
                if mode != 'wrongsize':
                    fixture.sequence = 10
                else:
                    fixture.frame_size = [640, 480]
            fixture.change = change
            raw = self.run_capture(fixture, raises='strict_final_frame_timeout')
            self.assertGreater(len(raw['queries']), 1)
            self.assertTrue(raw['snapshots'])
            self.assertNotIn('capture', fixture.events)
            self.assertNotIn('flush', fixture.events)

    def test_sequence_wrap_is_forward_and_signed_word_survives(self):
        fixture = PresentFixture(sequence=0xfffffffe)
        raw = self.run_capture(fixture)
        self.assertEqual(0, raw['matched']['leaves'][0]['frame']['sequence'])
        self.assertTrue(stimulus.present_advanced(0xffffffff, 0))
        self.assertFalse(stimulus.present_advanced(0, 0xffffffff))
        self.assertFalse(stimulus.present_advanced(0, 0x80000000))
        self.assertFalse(stimulus.present_frame(0xffff0000)['size_supported'])

    def test_absent_disabled_oversized_and_version_are_pending_not_success(self):
        for mode in ('legacy', 'disabled', 'oversize', 'version'):
            with self.subTest(mode=mode):
                fixture = PresentFixture()
                if mode == 'legacy':
                    fixture.absent = True
                elif mode == 'version':
                    fixture.version = 2
                else:
                    fixture.status = 5 if mode == 'disabled' else 2
                raw = self.run_capture(fixture)
                self.assertEqual(('PENDING', False, True), (raw['status'], raw['strict_final_frame'], raw['png_retained']))
                self.assertEqual(0, fixture.polls)

    def test_identity_reset_migration_and_pid_reuse_stop_each_stage(self):
        for stage in ('after_setwindowpos', 'poll', 'before_capture', 'capture'):
            for field in ('birth', 'revision', 'generation'):
                with self.subTest(stage=stage, field=field):
                    fixture = PresentFixture()
                    fixture.change = lambda s, stage=stage, field=field: setattr(fixture, field,
                        getattr(fixture, field) + 1) if s == stage else None
                    raw = self.run_capture(fixture, raises='identity|attachment|birth')
                    if stage == 'capture':
                        self.assertTrue(raw['png_retained'])
                        self.assertIn('screenshot_sha256', raw)

    def test_last_size_drift_and_frame_reset_fail_even_after_first_match(self):
        for stage in ('before_capture', 'capture'):
            for mode in ('geometry', 'frame', 'reset', 'disabled'):
                fixture = PresentFixture()
                def change(s):
                    if s != stage:
                        return
                    if mode == 'geometry':
                        fixture.outer[2] += 1
                    elif mode == 'frame':
                        fixture.frame_size = [640, 480]
                    elif mode == 'disabled':
                        fixture.status = 4
                    else:
                        fixture.sequence = 11  # Still newer than baseline, but older than matched=12.
                fixture.change = change
                self.run_capture(fixture, raises='geometry|no longer matches|reset/backwards|support')

    def test_client_mismatch_and_unreached_outer_are_failures(self):
        fixture = PresentFixture()
        original = fixture.GetClientRect
        def wrong(hwnd, rect):
            original(hwnd, rect)
            rect._obj.right += 1
            return 1
        fixture.GetClientRect = wrong
        self.run_capture(fixture, raises='GetClientRect')
        fixture = PresentFixture()
        fixture.change = lambda s: fixture.outer.__setitem__(2, 901) if s == 'after_setwindowpos' else None
        self.run_capture(fixture, raises='target size not reached')

    def test_one_lagging_leaf_and_torn_metadata_cannot_release_capture(self):
        fixture = PresentFixture(count=2)
        send = fixture.send_message
        def lagging(hwnd, message, selector, argument, timeout_ms):
            if selector == 17 and argument == 2:
                return 10 << 32 | 650 << 16 | 900
            return send(hwnd, message, selector, argument, timeout_ms)
        fixture.send_message = lagging
        self.run_capture(fixture, raises='strict_final_frame_timeout')
        fixture = PresentFixture()
        send = fixture.send_message
        def torn(hwnd, message, selector, argument, timeout_ms):
            result = send(hwnd, message, selector, argument, timeout_ms)
            if selector == 17:
                fixture.revision += 1
            return result
        fixture.send_message = torn
        self.run_capture(fixture, raises='changed during query')

    def test_query_support_loss_and_topology_change_fail_without_retry(self):
        for mode in ('support', 'topology'):
            fixture = PresentFixture()
            def change(stage):
                if stage != 'after_setwindowpos':
                    return
                if mode == 'support':
                    fixture.absent = True
                else:
                    fixture.count = 2
            fixture.change = change
            raw = self.run_capture(fixture, raises='identity|support')
            self.assertNotIn('capture', fixture.events)
            self.assertEqual('FAIL', raw['status'])

    def test_privacy_disabled_never_captures(self):
        fixture = PresentFixture()
        fixture.backdrop.color = None
        self.run_capture(fixture, raises='privacy backdrop')
        self.assertEqual([], fixture.events)

    def test_unresponsive_query_and_composition_failure_preserve_evidence(self):
        fixture = PresentFixture()
        fixture.send_message = lambda *args, **kwargs: None
        raw = self.run_capture(fixture, raises='did not respond')
        self.assertIsNone(raw['queries'][0]['answer'])
        dll = mock.Mock()
        dll.DwmFlush.return_value = -1
        with mock.patch.object(ctypes, 'WinDLL', return_value=dll, create=True):
            with self.assertRaisesRegex(stimulus.StrictFrameError, 'DwmFlush failed'):
                stimulus.dwm_flush()


class P7WorkerTests(unittest.TestCase):
    def test_graceful_cleanup_never_terminates_by_pid(self):
        gui, instance = mock.Mock(), mock.Mock()
        gui.WINDOW_CLASS, gui.WM_CLOSE = 'GhosttyWindow', 16
        instance.windows.return_value = [SimpleNamespace(hwnd=9, cls='GhosttyWindow')]
        instance.alive.side_effect = [True, False]
        with mock.patch.object(stimulus.time, 'sleep'):
            stimulus.close_p7_instance(gui, instance)
        gui.win32().PostMessageW.assert_called_once_with(9, 16, 0, 0)
        gui.win32().terminate.assert_not_called()
        instance.close.assert_not_called()

    def test_checkpoint_failure_prevents_blocking_operation(self):
        fixture = PresentFixture()
        original = stimulus.PresentQuery.snapshot
        def snapshot(probe, stage, deadline):
            fixture.stage(stage)
            return original(probe, stage, deadline)
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(stimulus.PresentQuery, 'snapshot', snapshot), \
                mock.patch.object(stimulus, 'durable_json', side_effect=OSError('disk failure')), \
                mock.patch.object(stimulus, 'dwm_flush') as flush:
            with self.assertRaisesRegex(OSError, 'disk failure'):
                stimulus.strict_resize_capture(fixture.gui, fixture.instance, 900, 650,
                                               Path(tmp) / 'resize.png', fixture.backdrop, {})
            flush.assert_not_called()
            fixture.instance.resize.assert_not_called()
            fixture.backdrop.capture.assert_not_called()

    def test_capture_past_round_deadline_retains_image_and_fails(self):
        fixture = PresentFixture()
        original = stimulus.PresentQuery.snapshot
        clock = [0.0]
        def snapshot(probe, stage, deadline):
            fixture.stage(stage)
            return original(probe, stage, deadline)
        fixture.change = lambda stage: clock.__setitem__(0, 121.0) if stage == 'capture' else None
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(stimulus.PresentQuery, 'snapshot', snapshot), \
                mock.patch.object(stimulus.time, 'perf_counter', side_effect=lambda: clock[0]), \
                mock.patch.object(stimulus, 'dwm_flush'):
            raw = {}
            with self.assertRaises(stimulus.StrictFrameError):
                stimulus.strict_resize_capture(fixture.gui, fixture.instance, 900, 650,
                    Path(tmp) / 'resize.png', fixture.backdrop, raw, round_deadline=120.0)
            self.assertEqual('FAIL', raw['status'])
            self.assertFalse(raw['strict_final_frame'])
            self.assertEqual(stimulus.hashlib.sha256(b'owned fixture image').hexdigest(), raw['screenshot_sha256'])

    @unittest.skipUnless(sys.platform == 'win32', 'Windows Job contract')
    def test_success_exit_failure_and_unrelated_process_is_untouched(self):
        sentinel = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            for code in (0, 7):
                with self.subTest(code=code), tempfile.TemporaryDirectory() as tmp:
                    command = [sys.executable, '-c',
                               f'import sys; sys.exit({code} if sys.stdin.buffer.readline()==b"P7_GO\\n" else 8)']
                    if code:
                        with self.assertRaisesRegex(stimulus.StrictFrameError, 'abnormal exit 7'):
                            stimulus.supervise_p7(command, Path(tmp), timeout=2, cleanup_timeout=2)
                    else:
                        result = stimulus.supervise_p7(command, Path(tmp), timeout=2, cleanup_timeout=2)
                        self.assertEqual('PASS', result['status'])
                    self.assertIsNone(sentinel.poll())
        finally:
            sentinel.kill()  # Exact test-owned handle, never a name or process inventory.
            sentinel.wait(timeout=2)

    @unittest.skipUnless(sys.platform == 'win32', 'Windows Job contract')
    def test_cleanup_confirmation_error_is_not_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            # The real Job still kills its members on close, but a failed query
            # cannot be reported as verified cleanup.
            with mock.patch.object(stimulus.WindowsJob, 'active', side_effect=OSError('query denied')):
                with self.assertRaisesRegex(stimulus.StrictFrameError, 'cleanup failed'):
                    stimulus.supervise_p7([sys.executable, '-c', 'import sys; sys.stdin.buffer.readline()'],
                                          Path(tmp), timeout=2, cleanup_timeout=2)
            result = json.loads((Path(tmp) / 'supervisor.json').read_text(encoding='utf-8'))
            self.assertEqual('FAIL', result['status'])
            self.assertFalse(result['cleanup']['tree_exited'])
            self.assertTrue(result['cleanup']['errors'])

    @unittest.skipUnless(sys.platform == 'win32', 'Windows Job contract')
    def test_worker_entrypoint_keeps_failure_result_and_inherited_guard_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            collector = out / 'collector.py'
            collector.write_text('import os\n'
                'def last_input_ticks(): return (123, 1000)\n'
                'def measure_win32(gui, exe, env_dir, config, resizes, env, report):\n'
                ' report.update(batch=os.environ["GX_PERF_BATCH_ID"], guard=os.environ["GX_PERF_GUARD_LOG"])\n'
                ' raise RuntimeError("fixture failure")\n', encoding='utf-8')
            stimulus.durable_json(out / 'request.json', {'collector': str(collector), 'scripts': str(SCRIPTS),
                'exe': 'unused.exe', 'env_dir': str(out), 'config': '', 'resizes': 6, 'env': {},
                'report': {'worker_entry_input_tick': 123}})
            environment = dict(os.environ, GX_PERF_BATCH_ID='original-batch', GX_PERF_GUARD_LOG=str(out/'guards.jsonl'))
            with self.assertRaisesRegex(stimulus.StrictFrameError, 'abnormal exit 1'):
                stimulus.supervise_p7([sys.executable, str(SCRIPTS/'gx_perf_stimulus.py'), '--p7-worker',
                                      str(out/'request.json')], out, timeout=2, cleanup_timeout=2,
                                     environment=environment)
            result = json.loads((out/'worker-result.json').read_text(encoding='utf-8'))
            self.assertEqual('FAIL', result['status'])
            self.assertIn('fixture failure', result['error'])
            self.assertEqual('original-batch', result['report']['batch'])
            self.assertEqual(str(out/'guards.jsonl'), result['report']['guard'])

    @unittest.skipUnless(sys.platform == 'win32', 'Windows Job contract')
    def test_input_arriving_across_gate_cannot_start_measurement(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            collector = out / 'collector.py'
            collector.write_text('from pathlib import Path\n'
                'class PerfError(RuntimeError):\n'
                ' def __init__(self, text, cause=None): super().__init__(text); self.cause=cause\n'
                'def last_input_ticks(): return (124, 1000)\n'
                'def measure_win32(*args): Path(__file__).with_suffix(".started").touch()\n', encoding='utf-8')
            stimulus.durable_json(out / 'request.json', {'collector': str(collector), 'scripts': str(SCRIPTS),
                'exe': 'unused.exe', 'env_dir': str(out), 'config': '', 'resizes': 6, 'env': {},
                'report': {'worker_entry_input_tick': 123}})
            with self.assertRaisesRegex(stimulus.StrictFrameError, 'abnormal exit 1'):
                stimulus.supervise_p7([sys.executable, str(SCRIPTS/'gx_perf_stimulus.py'), '--p7-worker',
                                      str(out/'request.json')], out, timeout=2, cleanup_timeout=2)
            result = json.loads((out/'worker-result.json').read_text(encoding='utf-8'))
            self.assertEqual('foreign_input', result['failure_cause'])
            self.assertFalse(collector.with_suffix('.started').exists())

    @unittest.skipUnless(sys.platform == 'win32', 'Windows Job contract')
    def test_blocked_flush_capture_save_and_child_are_terminated_with_checkpoint(self):
        for stage in ('flush', 'capture', 'save'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                began = time.monotonic()
                with self.assertRaisesRegex(stimulus.StrictFrameError, 'timeout'):
                    stimulus.supervise_p7(
                        [sys.executable, __file__, '--p7-block-fixture', tmp, stage],
                        out, timeout=2.0, cleanup_timeout=2.0)
                self.assertLess(time.monotonic() - began, 4.5)
                result = json.loads((out / 'supervisor.json').read_text(encoding='utf-8'))
                self.assertEqual('FAIL', result['status'])
                self.assertTrue(result['cleanup']['tree_exited'])
                self.assertEqual(0, result['cleanup']['active_processes'])
                checkpoint = out / ('resize.before_dwm_flush.query.json' if stage == 'flush'
                                    else 'resize.before_capture.query.json')
                raw = json.loads(checkpoint.read_text(encoding='utf-8'))
                self.assertTrue(raw['queries'])
                self.assertEqual(900, raw['snapshots'][0]['geometry']['birth'])
                self.assertTrue((out / 'descendant.pid').exists())
                marker = (out / 'heartbeat').read_bytes()
                time.sleep(0.15)
                self.assertEqual(marker, (out / 'heartbeat').read_bytes())

    @unittest.skipUnless(sys.platform == 'win32', 'Windows Job contract')
    def test_assignment_failure_never_opens_worker_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            with mock.patch.object(stimulus.WindowsJob, 'assign', side_effect=OSError('assign denied')):
                with self.assertRaisesRegex(stimulus.StrictFrameError, 'assign denied'):
                    stimulus.supervise_p7([sys.executable, __file__, '--p7-block-fixture', tmp, 'flush'],
                                          out, timeout=2, cleanup_timeout=2)
            self.assertFalse((out / 'descendant.pid').exists())
            result = json.loads((out / 'supervisor.json').read_text(encoding='utf-8'))
            self.assertFalse(result['gate_released'])
            self.assertTrue(result['cleanup']['tree_exited'])


def blocked_p7_fixture(directory, stage):
    # No app, child, thread or GUI action is permitted before this exact gate.
    if sys.stdin.buffer.readline() != b'P7_GO\n':
        return 2
    out = Path(directory)
    code = ('import pathlib,time; p=pathlib.Path(' + repr(str(out / 'heartbeat')) + '); '
            '\nwhile True:\n p.write_text(str(time.monotonic()), encoding="utf-8"); time.sleep(.02)')
    child = subprocess.Popen([sys.executable, '-c', code], stdin=subprocess.DEVNULL)
    (out / 'descendant.pid').write_text(str(child.pid), encoding='utf-8')
    fixture = PresentFixture()
    original = stimulus.PresentQuery.snapshot
    def snapshot(probe, name, deadline):
        fixture.stage(name)
        return original(probe, name, deadline)
    def block(*args, **kwargs):
        while True:
            time.sleep(1)
    if stage == 'capture':
        fixture.backdrop.capture.side_effect = block
    elif stage == 'save':
        fixture.backdrop.capture.return_value.save_png.side_effect = block
    with mock.patch.object(stimulus.PresentQuery, 'snapshot', snapshot), \
            mock.patch.object(stimulus, 'dwm_flush', side_effect=block if stage == 'flush' else None):
        stimulus.strict_resize_capture(fixture.gui, fixture.instance, 900, 650,
                                       out / 'resize.png', fixture.backdrop, {})
    return 0


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--p7-block-fixture':
        raise SystemExit(blocked_p7_fixture(*sys.argv[2:]))
    unittest.main()
