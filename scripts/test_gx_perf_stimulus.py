"""Offline tests: never launch a terminal, query PDH or send desktop input."""
import ctypes
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
import gx_perf_stimulus as stimulus


def pdh_sample(count=10, stamp=100, tid=7, birth=55, pid=42):
    return {'arrays': {key: [{'name': 'ghostty/0', 'status': 0, 'first': value,
                            'second': stamp, 'multi': 1, 'timestamp_100ns': stamp}]
                       for key, value in dict(pid=pid, tid=tid, birth=birth, switches=count).items()}}


class PdhTests(unittest.TestCase):
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
        self.receipt(event='ready')
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


if __name__ == '__main__':
    unittest.main()
