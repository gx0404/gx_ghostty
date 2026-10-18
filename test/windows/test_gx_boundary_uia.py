"""Offline boundary regression; no native UI or process operations."""
import struct
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_popup_uia_fixture as popup_fixture


class PopupBoundaryTests(unittest.TestCase):

    def test_palette_shadow_class_is_a_real_popup_not_a_missing_transition(self):
        palette = SimpleNamespace(hwnd=3, cls='GhosttyGxPopupShadow')
        self.assertIs(palette, popup_fixture.choose_popup([palette]))

    def test_ime_composition_failure_still_restores_open_mode_and_language(self):
        pinyin = PinyinEmulator(open_=0, mode=0x0400)
        report, error = run_compose(pinyin, press=RuntimeError("composition input failed"))
        self.assertIsInstance(error, RuntimeError)  # the original failure is not masked
        # Native bit added with the other bits kept, then undone newest first, each confirmed.
        self.assertEqual([("open", 1), ("mode", 0x0401), ("mode", 0x0400), ("open", 0)], pinyin.sets)
        self.assertEqual({"open": 0, "mode": 0}, pinyin.state)  # closing reset the mode
        self.assertEqual("closed-mode-not-comparable", report["ime_restore"])
        self.assertEqual([["mode", True], ["open", True]], report["ime_undo"])
        self.assertTrue(report["input_language"]["restored"])

    def test_activation_transient_is_not_taken_as_the_saved_state(self):
        # round3-batch-20261018-101019/102024: the first read after the layout
        # switch was (open 0, mode 1); restoring that read back gave (0, 0).
        pinyin = PinyinEmulator(open_=1, mode=1, transient={"open": 0, "mode": 1}, transient_reads=4)
        report, error = run_compose(pinyin)
        self.assertIsNone(error)
        self.assertEqual({"open": 0, "mode": 1}, report["ime_first_read"])
        self.assertEqual({"open": 1, "mode": 1}, report["ime_before"])
        self.assertEqual(({"open": 1, "mode": 1}, "exact"), (report["ime_after"], report["ime_restore"]))
        self.assertEqual(([], {"open": 1, "mode": 1}), (pinyin.sets, pinyin.state))  # nothing to change or undo

    def test_only_what_composition_changed_is_undone(self):
        # round3-batch-20261018-110320: from (0, 1) the redundant writes
        # open=1, mode=1 before closing left Microsoft Pinyin open at (1, 1025).
        pinyin = PinyinEmulator(open_=0, mode=1)
        report, error = run_compose(pinyin)
        self.assertIsNone(error)
        self.assertEqual([("open", 1), ("open", 0)], pinyin.sets)
        self.assertEqual(({"open": 0, "mode": 0}, "closed-mode-not-comparable"), (report["ime_after"], report["ime_restore"]))

    def test_a_close_that_is_never_confirmed_fails(self):
        pinyin = PinyinEmulator(open_=0, mode=1, ignore_close=True)
        report, error = run_compose(pinyin)
        self.assertIsInstance(error, AssertionError)
        self.assertEqual(([["open", False]], "mismatch"), (report["ime_undo"], report["ime_restore"]))

    def test_an_open_status_that_does_not_come_back_fails(self):
        pinyin = PinyinEmulator(open_=1, mode=1, close_on_escape=True)
        report, error = run_compose(pinyin)
        self.assertIsInstance(error, AssertionError)
        self.assertIn("not restored", str(error))
        self.assertEqual("mismatch", report["ime_restore"])
        self.assertTrue(report["input_language"]["restored"])


class PopupTransitionTests(unittest.TestCase):
    """round3-batch-20261018-125657 UIA-03: after Escape the closing menu was
    still listed, was taken for the modal dialog, and was gone by the capture."""

    def instance(self, frames):
        frames = iter(frames)
        last = []

        def popups():
            nonlocal last
            last = next(frames, last)
            return [SimpleNamespace(hwnd=hwnd) for hwnd in last]
        return SimpleNamespace(popups=popups, press=mock.Mock())

    def test_dismissal_waits_until_every_popup_visible_before_it_is_gone(self):
        import gx_boundary_uia as boundary
        instance = self.instance([[7, 8], [7, 8], [8], []])
        with mock.patch.object(boundary.time, "sleep"):
            boundary.dismiss_popups(instance)
        instance.press.assert_called_once_with("escape")
        self.assertEqual([], instance.popups())

    def test_a_dismissed_popup_that_stays_fails_instead_of_standing_in(self):
        import gx_boundary_uia as boundary
        instance = self.instance([[7], [7]])
        ticks = iter(range(100000))
        with mock.patch("gx_session_ipc_fixture.time.monotonic", side_effect=lambda: next(ticks)), \
                mock.patch("gx_session_ipc_fixture.time.sleep"), self.assertRaises(AssertionError):
            boundary.dismiss_popups(instance)


class PinyinEmulator:
    """Microsoft Pinyin through WM_IME_CONTROL as observed on the host: the first
    reads after a layout switch may show an activation state, a conversion mode
    set while closed is ignored, and closing resets the mode to 0."""

    def __init__(self, *, open_, mode, transient=None, transient_reads=0, close_on_escape=False, ignore_close=False):
        self.state = {"open": open_, "mode": mode}
        self.transient, self.transient_reads = transient, transient_reads
        self.close_on_escape, self.stuck, self.ignore_close = close_on_escape, False, ignore_close
        self.sets = []

    def press(self, key):
        if key == "escape" and self.close_on_escape:
            self.state.update(open=0, mode=0)
            self.stuck = True  # an IME that refuses to reopen

    def send_message(self, hwnd, message, command, value=0, timeout_ms=0):
        if command in (0x0006, 0x0002):
            self.sets.append(("open" if command == 0x0006 else "mode", value))
            self.transient_reads = 0
            if command == 0x0006 and not self.stuck and not (self.ignore_close and value == 0):
                self.state["open"] = value
                if value == 0:
                    self.state["mode"] = 0
            elif command == 0x0002 and self.state["open"]:
                self.state["mode"] = value
            return 0
        source = self.state
        if self.transient_reads:
            self.transient_reads -= 1
            source = self.transient
        return source["open" if command == 0x0005 else "mode"]


def run_compose(pinyin, press=None):
    """compose_ime against the emulator with a fake clock; returns (report, error)."""
    import gx_boundary_uia as boundary
    api = mock.Mock()
    api.focus_window.return_value = 55
    api.window_pid.return_value = 42
    api.class_name.return_value = boundary.gui.TERMINAL_CLASS
    api.keyboard_layout.return_value = 0x08040804
    api.IsWindow.return_value = True
    api.send_message.side_effect = pinyin.send_message

    def layouts(count, array):
        if array:
            array[0] = 0x08040804
        return 1
    native_dll = mock.Mock()
    native_dll.GetKeyboardLayoutList.side_effect = layouts
    native_dll.ImmGetDefaultIMEWnd.return_value = 77
    instance = mock.Mock(pid=42)

    def pressed(key):
        if press is not None:
            raise press
        pinyin.press(key)
    instance.press.side_effect = pressed
    events = iter(range(1000))
    native = mock.Mock(hwnd=9)
    native.query.side_effect = lambda selector, *rest: next(events)
    fixture = SimpleNamespace(report={}, check=mock.Mock())
    ticks = iter(range(100000))
    error = None
    with mock.patch.object(boundary.gui, "win32", return_value=api), \
            mock.patch("gx_boundary_controller.gui.win32", return_value=api), \
            mock.patch.object(boundary.C, "WinDLL", return_value=native_dll), \
            mock.patch.object(boundary.time, "monotonic", side_effect=lambda: next(ticks) * 0.05), \
            mock.patch.object(boundary.time, "sleep"):
        try:
            boundary.compose_ime(fixture, instance, native)
        except Exception as caught:  # noqa: BLE001 - returned to the test
            error = caught
    report = fixture.check.call_args.kwargs if fixture.check.call_args else {}
    return report, error

if __name__ == "__main__":
    unittest.main()
