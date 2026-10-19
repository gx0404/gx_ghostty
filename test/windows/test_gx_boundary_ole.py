"""Offline boundary regression; no native UI or process operations."""
import struct
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
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


class LifecyclePathTests(unittest.TestCase):
    def setUp(self):
        self.api = mock.Mock()
        self.api.GetAncestor.side_effect = lambda hwnd, kind: {12: 11, 13: 11}.get(hwnd, hwnd)
        self.api.window_pid.side_effect = lambda hwnd: 20 if hwnd == 21 else 10 if hwnd in (11, 12, 13) else 30
        self.drag = SimpleNamespace(source_hwnd=21, target_hwnd=11, process=SimpleNamespace(pid=20),
                                    instance=SimpleNamespace(pid=10), terminal=SimpleNamespace(hwnd=12),
                                    check_foreground=mock.Mock(), last_point=None)

    def test_preflight_accepts_owned_routes_in_both_directions_and_negative_coordinates(self):
        for start, end in (((10, 10), (90, 10)), ((90, 90), (10, 20)), ((-90, -50), (-10, -20))):
            with self.subTest(start=start, end=end), mock.patch.object(boundary.gui, "win32", return_value=self.api):
                self.api.window_at.side_effect = lambda x, y: 21 if (x, y) == start else 12
                boundary.preflight_lifecycle_path(self.drag, [start, end])
                self.api.send.assert_not_called()

    def test_preflight_refuses_gap_between_owned_endpoints_without_input(self):
        self.api.window_at.side_effect = lambda x, y: 21 if x < 40 else 12 if x > 60 else 31
        with mock.patch.object(boundary.gui, "win32", return_value=self.api), self.assertRaises(ole.gui.InputBlocked):
            boundary.preflight_lifecycle_path(self.drag, [(10, 10), (90, 10)])
        self.api.send.assert_not_called()

    def test_preflight_refuses_foreign_occlusion_and_wrong_target_pane(self):
        for hit in (31, 13):
            with self.subTest(hit=hit), mock.patch.object(boundary.gui, "win32", return_value=self.api):
                self.api.window_at.side_effect = lambda x, y: 21 if x == 10 else hit
                with self.assertRaises(ole.gui.InputBlocked):
                    boundary.preflight_lifecycle_path(self.drag, [(10, 10), (20, 10)])
                self.api.send.assert_not_called()

    def test_runtime_mouse_guard_still_refuses_occlusion_after_preflight(self):
        with mock.patch.object(boundary.gui, "win32", return_value=self.api):
            self.api.window_at.side_effect = lambda x, y: 21 if x == 10 else 12
            boundary.preflight_lifecycle_path(self.drag, [(10, 10), (20, 10)])
            self.api.window_at.side_effect = None
            self.api.window_at.return_value = 31
            with self.assertRaises(ole.gui.InputBlocked):
                ole.OwnedDrag.mouse(self.drag, 20, 10)
        self.api.send.assert_not_called()

    def test_layout_fits_source_inside_target_and_keeps_terminal_endpoint_exposed(self):
        for target, terminal in (((33, 654, 1215, 1425), (1120, 700, 1215, 1425)),
                                 ((-1200, -800, -20, -40), (-1190, -790, -1000, -600)),
                                 ((0, 0, 1200, 780), (0, 0, 1200, 780))):
            with self.subTest(target=target):
                (x, y, width, height), end = boundary.lifecycle_drag_layout(target, (1500, 800, 1800, 960), terminal)
                self.assertTrue(target[0] <= x < x + width <= target[2])
                self.assertTrue(target[1] <= y < y + height <= target[3])
                self.assertTrue(terminal[0] <= end[0] < terminal[2] and terminal[1] <= end[1] < terminal[3])
                self.assertFalse(x <= end[0] < x + width and y <= end[1] < y + height)

    def test_layout_refuses_source_that_cannot_fit(self):
        with self.assertRaises(ole.gui.InputBlocked):
            boundary.lifecycle_drag_layout((0, 0, 200, 100), (0, 0, 300, 160), (0, 0, 200, 100))

    def test_preexisting_left_down_refuses_lifecycle_before_stage_or_input(self):
        for state in (0x8000, -32767):
            fixture = SimpleNamespace(case_id="OLE-08", stage=mock.Mock(side_effect=AssertionError("stage must not start")))
            self.api.user32.GetAsyncKeyState.return_value = state
            with self.subTest(state=state), mock.patch.object(boundary.gui, "win32", return_value=self.api):
                with self.assertRaisesRegex(ole.gui.InputBlocked, "already down"):
                    boundary.run(fixture)
            fixture.stage.assert_not_called()
            self.api.send.assert_not_called()
            self.api.activate.assert_not_called()

    def test_left_up_allows_low_transition_bit_without_input(self):
        for state in (0, 1):
            self.api.user32.GetAsyncKeyState.return_value = state
            with self.subTest(state=state), mock.patch.object(boundary.gui, "win32", return_value=self.api):
                boundary.require_left_button_up()
        self.api.send.assert_not_called()


    def test_prepare_moves_source_inside_target_before_read_only_path_check(self):
        target, terminal = (0, 0, 1200, 780), (1100, 0, 1200, 780)
        source = [(1150, 16, 1450, 176)]
        self.api.client_rect.side_effect = lambda hwnd: target if hwnd == 11 else terminal
        self.api.raw_window_rect.side_effect = lambda hwnd: source[0]

        def place(hwnd, after, x, y, width, height, flags):
            self.assertEqual((21, None, 0x0014), (hwnd, after, flags))
            source[0] = (x, y, x + width, y + height)
            return 1

        def hit(x, y):
            rect = source[0]
            return 21 if rect[0] <= x < rect[2] and rect[1] <= y < rect[3] else 12 if x >= 1100 else 13

        self.api.SetWindowPos.side_effect = place
        self.api.window_at.side_effect = hit
        self.drag.check_identity = mock.Mock()
        self.drag.activate_source = mock.Mock()
        self.drag.start_point = lambda: ((source[0][0] + source[0][2]) // 2, (source[0][1] + source[0][3]) // 2)
        with mock.patch.object(boundary.gui, "win32", return_value=self.api):
            points = boundary.prepare_lifecycle_drag(self.drag)
        self.assertEqual(17, len(points))
        self.assertLessEqual(source[0][2], target[2])
        self.assertEqual(12, hit(*points[-1]))
        self.api.send.assert_not_called()


class LifecycleReleaseTests(unittest.TestCase):
    def setUp(self):
        self.instance = mock.Mock()
        self.api = mock.Mock()
        self.api.foreground.return_value = 21
        self.api.GetAncestor.side_effect = lambda hwnd, kind: hwnd
        self.api.IsWindow.return_value = True
        self.api.class_name.return_value = "GxOwnedOleDragSource"
        self.api.process_creation.return_value = 200
        self.api.process_image.return_value = "source.exe"
        self.api.window_pid.return_value = 20
        self.process = mock.Mock(pid=20)
        self.process.poll.return_value = None

    def release(self):
        return boundary.release_lifecycle_button(self.instance, Path("source.exe"), "source-hash", self.process, 200, 21)

    def test_target_foreground_uses_original_guard_even_when_source_exited(self):
        self.api.foreground.return_value = 11
        self.process.poll.return_value = 3
        with mock.patch.object(boundary.gui, "win32", return_value=self.api):
            self.release()
        self.instance.ensure_foreground.assert_called_once_with()
        self.api.send.assert_called_once()
        self.api.activate.assert_not_called()

    def test_changed_source_identity_or_window_refuses_cleanup_input(self):
        for field, value in (("process_creation", 201), ("process_image", "other.exe"),
                             ("IsWindow", False), ("class_name", "OtherWindow"), ("window_pid", 99)):
            self.setUp()
            getattr(self.api, field).return_value = value
            with self.subTest(field=field), mock.patch.object(boundary.gui, "win32", return_value=self.api), \
                    mock.patch.object(boundary, "sha256", return_value="source-hash"):
                with self.assertRaises(ole.gui.InputBlocked):
                    self.release()
            self.api.send.assert_not_called()
            self.api.activate.assert_not_called()

    def test_changed_source_hash_refuses_cleanup_input(self):
        with mock.patch.object(boundary.gui, "win32", return_value=self.api), \
                mock.patch.object(boundary, "sha256", return_value="changed"):
            with self.assertRaises(ole.gui.InputBlocked):
                self.release()
        self.api.send.assert_not_called()

    def test_foreground_change_during_identity_check_refuses_cleanup_input(self):
        self.api.foreground.side_effect = [21, 31]
        with mock.patch.object(boundary.gui, "win32", return_value=self.api), \
                mock.patch.object(boundary, "sha256", return_value="source-hash"):
            with self.assertRaises(ole.gui.InputBlocked):
                self.release()
        self.api.send.assert_not_called()

    def test_another_window_of_source_process_is_not_authorized(self):
        self.api.foreground.return_value = 22
        self.instance.ensure_foreground.side_effect = ole.gui.InputBlocked("not the target")
        with mock.patch.object(boundary.gui, "win32", return_value=self.api):
            with self.assertRaises(ole.gui.InputBlocked):
                self.release()
        self.api.send.assert_not_called()
        self.instance.activate.assert_not_called()


class LifecycleCleanupTests(unittest.TestCase):
    def run_lifecycle_failure(self, *, foreground=21, send_error=False, down_error=False, late_down=False,
                              interrupt_phase=None):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            source = work / "source.exe"
            source.write_bytes(b"owned source")
            fixture = SimpleNamespace(args=SimpleNamespace(ole_source=source), out=work,
                                      exe=work / "app.exe", report={"app_sha256": "a" * 64},
                                      case_id="OLE-08", check=mock.Mock())
            instance = mock.Mock(pid=10, creation=100, exe=fixture.exe)
            instance.ensure_foreground.side_effect = ole.gui.InputBlocked("target is not foreground")
            first, destination = mock.Mock(hwnd=11), mock.Mock(hwnd=14)
            first.tree.return_value = {"active_core": 1, "nodes": [{"leaf": {"core": 1, "hwnd": 12}}]}
            api = mock.Mock()
            api.info.return_value = SimpleNamespace(hwnd=12, rect=(0, 0, 500, 300))
            api.process_creation.return_value = 200
            api.process_image.return_value = str(source)
            api.foreground.return_value = foreground
            api.GetAncestor.side_effect = lambda hwnd, kind: hwnd
            api.window_pid.side_effect = lambda hwnd: 20 if hwnd == 21 else 10 if hwnd == 11 else 30
            api.IsWindow.return_value = True
            api.class_name.return_value = "GxOwnedOleDragSource"
            api.key_input.side_effect = lambda key, up: ("key", key, up)
            api.mouse_input.side_effect = lambda flags: ("mouse", flags)
            if send_error:
                api.send.side_effect = OSError("release failed")
            if interrupt_phase == "button_release":
                api.send.side_effect = KeyboardInterrupt("button cleanup interrupted")
            process = mock.Mock(pid=20)
            stopped = [False]
            process.poll.side_effect = lambda: 3 if stopped[0] else None
            process.terminate.side_effect = lambda: stopped.__setitem__(0, True)
            if interrupt_phase == "source_exit":
                process.terminate.side_effect = KeyboardInterrupt("source cleanup interrupted")
            process.wait.return_value = 3

            def launch(*args, **kwargs):
                folder = work / "ole-source" / "gx-ole-20-1"
                folder.mkdir()
                facts = {"source_pid": 20, "source_hwnd": 21, "target_pid": 10, "target_birth": 100,
                         "target_hwnd": 12, "app_sha256": "a" * 64}
                (folder / "ready.json").write_text(json.dumps(facts), encoding="utf-8")
                return process

            drag = mock.Mock(target_hwnd=11)
            drag.start_point.return_value = (10, 10)

            def mouse(*args, action="move", **kwargs):
                if action != "down" or down_error:
                    raise ValueError("original drag failure")

            drag.mouse.side_effect = mouse
            checks = [None, ole.gui.InputBlocked("left button is already down")] if late_down else None
            with mock.patch.object(boundary.gui, "win32", return_value=api), \
                    mock.patch.object(boundary, "OwnedDrag", return_value=drag), \
                    mock.patch.object(boundary, "prepare_lifecycle_drag", return_value=[(10, 10), (20, 10)], create=True), \
                    mock.patch.object(boundary, "require_left_button_up", side_effect=checks, create=True), \
                    mock.patch.object(boundary.subprocess, "CREATE_NO_WINDOW", 0x08000000, create=True), \
                    mock.patch.object(boundary.subprocess, "Popen", side_effect=launch), \
                    mock.patch.object(boundary.time, "sleep"):
                try:
                    with self.assertRaisesRegex(ole.gui.InputBlocked if late_down else ValueError,
                                                "already down" if late_down else "original drag failure"):
                        boundary.lifecycle(fixture, instance, first, destination)
                except KeyboardInterrupt as error:
                    self.fail(f"cleanup interrupt replaced the original failure: {error}")
            if interrupt_phase == "button_release":
                process.terminate.assert_called_once_with()
                process.wait.assert_called_once_with(timeout=5)
            instance.activate.assert_not_called()
            api.activate.assert_not_called()
            return fixture.report, api, drag

    def test_failure_on_owned_source_cancels_and_preserves_original_exception(self):
        report, api, _ = self.run_lifecycle_failure()
        self.assertEqual("original drag failure", report["ole_lifecycle_failure"]["reason"])
        api.send.assert_called_once_with([("key", 0x1b, False), ("key", 0x1b, True), ("mouse", 4)])
        self.assertFalse(report["ole_lifecycle_cleanup"]["button_release_pending"])

    def test_foreign_foreground_preserves_original_and_records_cleanup_refusal(self):
        report, api, _ = self.run_lifecycle_failure(foreground=31)
        api.send.assert_not_called()
        cleanup = report["ole_lifecycle_cleanup"]
        self.assertTrue(cleanup["button_release_pending"])
        self.assertIn("target is not foreground", cleanup["errors"][0]["error"])

    def test_release_failure_does_not_clear_button_or_replace_original(self):
        report, _, _ = self.run_lifecycle_failure(send_error=True)
        self.assertTrue(report["ole_lifecycle_cleanup"]["button_release_pending"])
        self.assertIn("release failed", report["ole_lifecycle_cleanup"]["errors"][0]["error"])

    def test_partial_down_failure_still_attempts_owned_release(self):
        report, api, _ = self.run_lifecycle_failure(down_error=True)
        api.send.assert_called_once()
        self.assertFalse(report["ole_lifecycle_cleanup"]["button_release_pending"])

    def test_left_down_during_preflight_never_becomes_fixture_owned(self):
        report, api, drag = self.run_lifecycle_failure(late_down=True)
        drag.mouse.assert_not_called()
        api.send.assert_not_called()
        self.assertFalse(report["ole_lifecycle_cleanup"]["button_release_pending"])


    def test_cleanup_interrupts_preserve_primary_failure_and_finish_other_phase(self):
        for phase in ("button_release", "source_exit"):
            with self.subTest(phase=phase):
                report, _, _ = self.run_lifecycle_failure(interrupt_phase=phase)
                self.assertEqual("original drag failure", report["ole_lifecycle_failure"]["reason"])
                cleanup = report["ole_lifecycle_cleanup"]
                self.assertEqual(phase == "button_release", cleanup["button_release_pending"])
                self.assertEqual([(phase, "KeyboardInterrupt")],
                                 [(item["phase"], item["type"]) for item in cleanup["errors"]])


class LifecycleInterruptTests(unittest.TestCase):
    def test_cleanup_without_primary_reraises_original_interrupt_after_recording(self):
        for phase in ("button_release", "source_exit", "both"):
            with self.subTest(phase=phase):
                report, instance, process = {}, mock.Mock(), mock.Mock()
                process.poll.return_value = None
                button_interrupt = KeyboardInterrupt("button cleanup interrupted")
                source_interrupt = KeyboardInterrupt("source cleanup interrupted")
                if phase in ("source_exit", "both"):
                    process.terminate.side_effect = source_interrupt
                with mock.patch.object(boundary, "release_lifecycle_button") as release, \
                        mock.patch.object(boundary, "verify_lifecycle_source") as verify:
                    if phase in ("button_release", "both"):
                        release.side_effect = button_interrupt
                    with self.assertRaises(KeyboardInterrupt) as caught:
                        boundary.cleanup_lifecycle(report, instance, Path("source.exe"), "hash", process, 200, 21, True, None)
                self.assertIs(button_interrupt if phase in ("button_release", "both") else source_interrupt,
                              caught.exception)
                self.assertEqual("FAIL", report["status"])
                self.assertEqual("KeyboardInterrupt", report["interruption_type"])
                self.assertEqual(str(caught.exception), report["reason"])
                release.assert_called_once()
                verify.assert_called_once()
                process.terminate.assert_called_once_with()
                if phase == "button_release":
                    process.wait.assert_called_once_with(timeout=5)
                cleanup = report["ole_lifecycle_cleanup"]
                self.assertEqual(phase != "source_exit", cleanup["button_release_pending"])
                expected = ["button_release", "source_exit"] if phase == "both" else [phase]
                self.assertEqual(expected, [item["phase"] for item in cleanup["errors"]])
                self.assertTrue(all(item["type"] == "KeyboardInterrupt" for item in cleanup["errors"]))
                instance.activate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
