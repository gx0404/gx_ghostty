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
        import gx_boundary_uia as boundary
        ime_state = {'open': 0, 'mode': 0x0400}
        sets = []

        def send_message(hwnd, message, command, value=0, timeout_ms=0):
            if command in (0x0006, 0x0002):
                sets.append((command, value))
                ime_state['open' if command == 0x0006 else 'mode'] = value
                if command == 0x0006 and value == 0:
                    ime_state['mode'] = 0  # Pinyin: closing resets the conversion mode.
                return 0
            return ime_state['open' if command == 0x0005 else 'mode']

        api = mock.Mock()
        api.focus_window.return_value = 55
        api.window_pid.return_value = 42
        api.class_name.return_value = boundary.gui.TERMINAL_CLASS
        api.keyboard_layout.return_value = 0x08040804
        api.IsWindow.return_value = True
        api.send_message.side_effect = send_message

        def layouts(count, array):
            if array is not None:
                array[0] = 0x08040804
            return 1
        native_dll = mock.Mock()
        native_dll.GetKeyboardLayoutList.side_effect = layouts
        native_dll.ImmGetDefaultIMEWnd.return_value = 77
        instance = mock.Mock(pid=42)
        instance.press.side_effect = RuntimeError('composition input failed')
        fixture = SimpleNamespace(report={}, check=mock.Mock())
        with mock.patch.object(boundary.gui, 'win32', return_value=api), \
                mock.patch('gx_boundary_controller.gui.win32', return_value=api), \
                mock.patch.object(boundary.C, 'WinDLL', return_value=native_dll), \
                self.assertRaisesRegex(RuntimeError, 'composition input failed'):
            boundary.compose_ime(fixture, instance, mock.Mock(hwnd=9))
        self.assertIn((0x0002, 0x0401), sets)  # native bit added, other mode bits kept
        self.assertEqual({'open': 0, 'mode': 0x0400}, ime_state)
        self.assertTrue(fixture.report['input_language'][0]['restored'])


if __name__ == "__main__":
    unittest.main()
