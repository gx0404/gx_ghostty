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
                mock.patch.object(boundary.time, "sleep"), \
                mock.patch.object(boundary.time, "monotonic", side_effect=[10, 10, 11]):
            closed, errors = boundary.close_private_explorer(Path("private"), {1}, None, settle=0)
        self.assertEqual([2], closed)
        self.assertEqual(1, len(errors))
        self.assertNotIn(mock.call("close", Path("private"), hwnd=1), calls.call_args_list)

    def test_cleanup_zero_or_negative_settle_scans_once_without_sleep(self):
        for settle in (0, -1):
            with self.subTest(settle=settle), \
                    mock.patch.object(boundary, "shell_windows", return_value=[]) as shell, \
                    mock.patch.object(boundary.time, "monotonic", side_effect=[10, 10, 11]), \
                    mock.patch.object(boundary.time, "sleep") as sleep:
                self.assertEqual(([], []), boundary.close_private_explorer(Path("private"), set(), None, settle))
                self.assertEqual([mock.call("list", Path("private"))], shell.call_args_list)
                sleep.assert_not_called()

    def test_cleanup_settle_boundary_includes_late_window_without_oversleep(self):
        for settle in (0.25, 0.5, 1.0):
            now = [10.0]
            sleeps, actions = [], []

            def sleep(seconds):
                sleeps.append(seconds)
                now[0] += seconds

            def shell(action, directory, *, hwnd=0):
                actions.append((action, hwnd))
                if action == "list":
                    return [1, 2] if now[0] >= 10 + settle else [1]
                return {"hwnd": hwnd}

            with self.subTest(settle=settle), \
                    mock.patch.object(boundary, "shell_windows", side_effect=shell), \
                    mock.patch.object(boundary.time, "monotonic", side_effect=lambda: now[0]), \
                    mock.patch.object(boundary.time, "sleep", side_effect=sleep):
                self.assertEqual(([2], []), boundary.close_private_explorer(Path("private"), {1}, None, settle))
            self.assertEqual(settle, sum(sleeps))
            self.assertEqual([("close", 2)], [item for item in actions if item[0] == "close"])

    def test_cleanup_does_not_retry_failed_or_navigated_window_while_waiting(self):
        for reason in ("Explorer navigated away; no action permitted", "Quit failed"):
            now = [10.0]
            attempts = []

            def sleep(seconds):
                now[0] += seconds

            def shell(action, directory, *, hwnd=0):
                if action == "list":
                    return [1, 2, 3, 4] if now[0] >= 10.5 else [1, 2, 3]
                attempts.append(hwnd)
                if hwnd == 3 and attempts.count(3) == 1:
                    raise ole.gui.InputBlocked(reason)
                return {"hwnd": hwnd}

            with self.subTest(reason=reason), \
                    mock.patch.object(boundary, "shell_windows", side_effect=shell), \
                    mock.patch.object(boundary.time, "monotonic", side_effect=lambda: now[0]), \
                    mock.patch.object(boundary.time, "sleep", side_effect=sleep):
                closed, errors = boundary.close_private_explorer(Path("private"), {1}, None, settle=1)
            self.assertEqual([2, 4], closed)
            self.assertEqual([f"0x3: {reason}"], errors)
            self.assertEqual([2, 3, 4], attempts)

    def test_cleanup_prior_window_is_protected_even_if_attributed(self):
        with mock.patch.object(boundary, "shell_windows", return_value=[1]) as shell:
            self.assertEqual(([], []), boundary.close_private_explorer(Path("private"), {1}, 1))
        self.assertEqual([mock.call("list", Path("private"))], shell.call_args_list)

    def test_cleanup_list_failure_still_allows_late_private_window(self):
        now = [10.0]

        def sleep(seconds):
            now[0] += seconds

        def shell(action, directory, *, hwnd=0):
            if action == "list":
                if now[0] == 10:
                    raise ole.gui.InputBlocked("enumeration failed")
                return [1, 2]
            return {"hwnd": hwnd}

        with mock.patch.object(boundary, "shell_windows", side_effect=shell) as calls, \
                mock.patch.object(boundary.time, "monotonic", side_effect=lambda: now[0]), \
                mock.patch.object(boundary.time, "sleep", side_effect=sleep):
            self.assertEqual(([2], ["enumeration failed"]),
                             boundary.close_private_explorer(Path("private"), {1}, None, settle=0.5))
        self.assertEqual([mock.call("close", Path("private"), hwnd=2)],
                         [call for call in calls.call_args_list if call.args[0] == "close"])


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
