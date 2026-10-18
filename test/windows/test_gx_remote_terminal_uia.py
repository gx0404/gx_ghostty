"""UIA-05r (D-29 for a remote pane) offline judgments; native APIs are mocked."""
import unittest
from unittest import mock
import gx_remote_fixture as remote


class RemoteTerminalUiaTests(unittest.TestCase):
    ROOT = {"name": "cmd", "control_type": 50033, "localized_type": "Terminal",
            "automation_id": "gx-terminal-9", "native_window_handle": 0x2040}

    def fixture(self, window_nodes, root=None):
        fixture = remote.Fixture.__new__(remote.Fixture)
        fixture.focus_remote = mock.Mock(return_value=mock.Mock(hwnd=0x2040))
        fixture.capture, fixture.record = mock.Mock(), mock.Mock()
        probes = {"remote-terminal-uia-root": {"nodes": [root or self.ROOT]},
                  "remote-terminal-uia-focus": {"nodes": [root or self.ROOT]},
                  "remote-terminal-uia-window": {"nodes": window_nodes}}
        fixture.remote_uia_probe = mock.Mock(side_effect=lambda target, hwnd, cls, name, rows=None: probes[name])
        return fixture

    def window(self, *extra):
        return [{"name": "cmd", "control_type": 50032, "automation_id": "gx-1"}, self.ROOT, *extra]

    def test_the_named_remote_terminal_once_in_its_window_passes(self):
        fixture = self.fixture(self.window())
        fixture.case_terminal_uia(mock.Mock(), mock.Mock(hwnd=0x1000))
        rows = fixture.remote_uia_probe.call_args_list[1].args[4]
        self.assertEqual([{"automation_id": "gx-terminal-9", "pattern": "element", "operation": "check_focus",
                           "expect_focus": True, "expect_focused_element": True}], rows)
        self.assertEqual("remote-terminal-uia", fixture.record.call_args.args[0])
        self.assertEqual("UIA-05r", remote.CASE_IDS["remote-terminal-uia"])

    def test_a_window_twin_or_an_anonymous_root_fails(self):
        twin = {"name": "cmd", "control_type": 50033, "automation_id": "gx-7"}
        with self.assertRaisesRegex(AssertionError, "exactly once"):
            self.fixture(self.window(twin)).case_terminal_uia(mock.Mock(), mock.Mock(hwnd=0x1000))
        anonymous = {"name": "", "control_type": 50033, "localized_type": "pane", "automation_id": "gx-1", "native_window_handle": 0x2040}
        with self.assertRaisesRegex(AssertionError, "root facts"):
            self.fixture(self.window(), anonymous).case_terminal_uia(mock.Mock(), mock.Mock(hwnd=0x1000))


if __name__ == "__main__":
    unittest.main()
