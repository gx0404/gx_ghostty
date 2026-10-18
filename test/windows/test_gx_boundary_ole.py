"""Offline boundary regression; no native UI or process operations."""
import struct
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_ole_fixture as ole
import gx_boundary_ole as boundary


class OleBoundaryTests(unittest.TestCase):

    def test_cleanup_never_reactivates_after_foreground_guard_loss(self):
        instance = mock.Mock()
        instance.ensure_foreground.side_effect = ole.gui.InputBlocked('foreground changed')
        with self.assertRaises(ole.gui.InputBlocked):
            boundary.release_on_owned_app(instance)
        instance.activate.assert_not_called()
        instance.mouse.assert_not_called()

    def test_drag_owner_comes_from_terminal_not_another_top_level_window(self):
        instance = mock.Mock()
        instance.require_window.return_value.hwnd = 99
        with mock.patch.object(ole.gui, 'win32') as api, mock.patch.object(ole.OwnedDrag, 'check_identity'):
            api.return_value.GetAncestor.return_value = 44
            drag = ole.OwnedDrag(instance, Path('app'), 'a', Path('source'), 'b', mock.Mock(), 1, 2, SimpleNamespace(hwnd=3))
        self.assertEqual(44, drag.target_hwnd)

    def test_cleanup_quits_every_new_private_window_even_without_attribution(self):
        def shell(action, directory, *, hwnd=0, name=""):
            if action == "list":
                return [1, 2, 3]
            if hwnd == 3:
                raise ole.gui.InputBlocked("Explorer navigated away; no action permitted")
            return {"hwnd": hwnd, "action": action}
        with mock.patch.object(boundary, "shell_windows", side_effect=shell) as calls, \
                mock.patch.object(boundary.time, "sleep"):
            closed, errors = boundary.close_private_explorer(Path("private"), {1}, None, settle=0)
        self.assertEqual([2], closed)
        self.assertEqual(1, len(errors))
        self.assertNotIn(mock.call("close", Path("private"), hwnd=1), calls.call_args_list)


if __name__ == "__main__":
    unittest.main()
