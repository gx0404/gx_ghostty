"""Offline contracts; all native APIs are mocked and files are temporary."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_remote_fixture as remote


class RemoteInputTests(unittest.TestCase):
    def test_paced_input_never_sends_enter_and_checks_owner_each_sample(self):
        fixture = remote.Fixture.__new__(remote.Fixture)
        fixture.perf_count, fixture.perf_interval_ms = 3, 200
        fixture.source_child = {'pid': 1, 'birth': 2}
        fixture.focus_remote = mock.Mock(return_value=mock.Mock(hwnd=123))
        fixture.fresh, fixture.same_process = mock.Mock(), mock.Mock()
        fixture.capture, fixture.record = mock.Mock(), mock.Mock()
        target, window = mock.Mock(), mock.Mock(hwnd=99)
        with mock.patch.object(remote.gui, 'win32') as api, mock.patch.object(remote, 'native_snapshot', return_value={}), \
                mock.patch.object(remote.time, 'sleep'), mock.patch.object(remote.time, 'perf_counter', return_value=1):
            api.return_value.focus_window.return_value = 123
            fixture.case_perf_input(target, window)
        self.assertEqual(['a', 'b', 'c'], [call.args[0] for call in target.type_text.call_args_list])
        target.press.assert_not_called()
        self.assertEqual(3, target.ensure_foreground.call_count)
        self.assertEqual(3, fixture.record.call_args.kwargs['count'])


if __name__ == "__main__":
    unittest.main()
