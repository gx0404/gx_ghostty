"""Safety bounds and hard-timeout reporting of the owned-window UIA probe."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_win_uia as probe


class UiaProbeTests(unittest.TestCase):
    def args(self, *extra):
        return ['--hwnd', '0x123', '--pid', '42', '--birth', '12345', '--exe', 'ghostty.exe', *extra]

    def test_identity_and_limits_are_required(self):
        probe.validate_args(probe.parser().parse_args(self.args()))
        for extra in [('--hwnd', '0'), ('--birth', '0'), ('--max-depth', '17'),
                      ('--max-nodes', '513'), ('--timeout', '0'), ('--expect-notification',),
                      ('--timeout', '2', '--listen-ms', '2000')]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                probe.validate_args(probe.parser().parse_args(self.args(*extra)))

    def test_timeout_reports_fail_and_never_retries_or_scans_desktop(self):
        with mock.patch.object(probe.subprocess, 'run', side_effect=subprocess.TimeoutExpired('worker', 15)) as run:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(1, probe.main(self.args()))
            self.assertEqual('FAIL', json.loads(output.getvalue())['status'])
            self.assertEqual(1, run.call_count)
            command = run.call_args.args[0]
            self.assertIn('--worker', command)
            self.assertIn('--hwnd', command)
            self.assertIn('--birth', command)
            self.assertEqual(15, run.call_args.kwargs['timeout'])

    def test_actions_require_hash_and_bounded_exact_targets(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'actions.json'
            good = {'name': 'Search', 'pattern': 'value', 'operation': 'set', 'value': '中文 🧪'}
            path.write_text(json.dumps([good]), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'SHA-256'):
                probe.validate_args(probe.parser().parse_args(self.args('--action-plan', str(path))))
            probe.validate_args(probe.parser().parse_args(self.args('--action-plan', str(path), '--sha256', 'a' * 64)))
            for bad in ({**good, 'value': 'x' * 4097}, {**good, 'operation': 'delete'},
                        {**good, 'expect_unavailable': True}, {'pattern': 'invoke', 'operation': 'invoke'}):
                path.write_text(json.dumps([bad]), encoding='utf-8')
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    probe.read_plan(path)
            path.write_bytes(b' ' * 65537)
            with self.assertRaisesRegex(ValueError, '64 KiB'):
                probe.read_plan(path)

    def test_transition_signal_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as folder:
            ready, proceed = Path(folder) / 'ready', Path(folder) / 'continue'
            args = self.args('--ready-file', str(ready), '--continue-file', str(proceed))
            probe.validate_args(probe.parser().parse_args(args))
            proceed.touch()
            with self.assertRaises(ValueError):
                probe.validate_args(probe.parser().parse_args(args))

    def test_all_required_patterns_have_client_operations(self):
        self.assertEqual({'invoke', 'selection_item', 'value', 'toggle', 'expand_collapse'}, set(probe.PATTERNS))
        self.assertEqual((10005, {'expand': 3, 'collapse': 4}), probe.PATTERNS['expand_collapse'])

    def test_windowless_client_requires_physical_coordinate_context(self):
        import ctypes
        user = mock.Mock()
        user.SetThreadDpiAwarenessContext.return_value = 1
        probe.physical_coordinates(user)
        self.assertEqual((-4) % (1 << (ctypes.sizeof(ctypes.c_void_p) * 8)), user.SetThreadDpiAwarenessContext.call_args.args[0].value)
        user.SetThreadDpiAwarenessContext.return_value = 0
        with self.assertRaisesRegex(RuntimeError, 'coordinates'):
            probe.physical_coordinates(user)


if __name__ == '__main__':
    unittest.main()
