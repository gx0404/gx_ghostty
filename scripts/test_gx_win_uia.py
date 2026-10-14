"""Safety bounds and hard-timeout reporting of the owned-window UIA probe."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
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


if __name__ == '__main__':
    unittest.main()
