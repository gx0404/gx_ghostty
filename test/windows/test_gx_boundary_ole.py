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


class ExplorerDragStartTests(unittest.TestCase):
    # Shape of round3-batch-20261018-105235 OLE-07: a details-view row wider
    # than the 720x480 owned Explorer window; its center was behind the window.
    WINDOW = (63, 734, 783, 1214)
    ROW = {"depth": 7, "control_type": 50007, "name": "GX_A3_Explorer.txt", "bounds": [335.0, 987.0, 1013.0, 37.0]}
    CELLS = [{"depth": 8, "automation_id": "System.ItemNameDisplay", "bounds": [368.0, 992.0, 405.0, 29.0]},
             {"depth": 8, "automation_id": "System.DateModified", "bounds": [773.0, 992.0, 243.0, 29.0]}]

    def test_drag_starts_on_the_name_cell_inside_the_owned_window(self):
        nodes = [{"depth": 6, "bounds": [314.0, 938.0, 458.0, 227.0]}, self.ROW, *self.CELLS, {"depth": 7, "bounds": [0, 0, 1, 1]}]
        x, y = boundary.explorer_drag_start(nodes, 1, self.WINDOW)
        self.assertEqual((570, 1006), (x, y))
        self.assertTrue(self.WINDOW[0] <= x < self.WINDOW[2] and self.WINDOW[1] <= y < self.WINDOW[3])

    def test_a_row_without_a_name_cell_is_clipped_to_the_window(self):
        x, y = boundary.explorer_drag_start([self.ROW], 0, self.WINDOW)
        self.assertEqual((559, 1006), (x, y))
        self.assertLess(x, self.WINDOW[2])

    def test_a_cell_of_another_item_is_not_used(self):
        other = {"depth": 7, "control_type": 50007, "bounds": [335.0, 1030.0, 1013.0, 37.0]}
        nodes = [self.ROW, other, {"depth": 8, "automation_id": "System.ItemNameDisplay", "bounds": [368.0, 1035.0, 405.0, 29.0]}]
        self.assertEqual((559, 1006), boundary.explorer_drag_start(nodes, 0, self.WINDOW))

    def test_an_item_outside_the_window_is_refused(self):
        row = dict(self.ROW, bounds=[900.0, 987.0, 300.0, 37.0])
        with self.assertRaises(boundary.gui.InputBlocked):
            boundary.explorer_drag_start([row], 0, self.WINDOW)


if __name__ == "__main__":
    unittest.main()
