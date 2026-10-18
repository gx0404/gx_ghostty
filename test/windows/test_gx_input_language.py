"""Offline contracts for host-safe keyboard layout switching; Win32 is mocked.

The host never loads a keyboard layout: only layouts GetKeyboardLayoutList
already reports are switched to. LoadKeyboardLayoutW exists only behind the
VM-only allow_load path, and whatever it adds is unloaded again.
"""
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
WM_INPUTLANGCHANGEREQUEST = 0x0050


class FakeUser32:
    """GetKeyboardLayoutList / LoadKeyboardLayoutW / UnloadKeyboardLayout of one user session."""

    def __init__(self, loaded, load_result=0x04090409):
        self.loaded, self.load_result = list(loaded), load_result
        self.loads, self.unloads = [], []

    def GetKeyboardLayoutList(self, count, buffer):
        if not buffer:
            return len(self.loaded)
        for index, value in enumerate(self.loaded[:count]):
            buffer[index] = value
        return min(count, len(self.loaded))

    def LoadKeyboardLayoutW(self, klid, flags):
        self.loads.append((klid, flags))
        self.loaded.append(self.load_result)
        return self.load_result

    def UnloadKeyboardLayout(self, handle):
        self.unloads.append(handle)
        return 1


def thread(layout):
    """A gx_win_gui Win32 mock whose owned GUI thread follows WM_INPUTLANGCHANGEREQUEST."""
    state = {"layout": layout}
    api = mock.Mock()
    api.keyboard_layout.side_effect = lambda hwnd: state["layout"]
    api.focus_window.return_value = 77

    def post(hwnd, message, wparam, lparam):
        if message == WM_INPUTLANGCHANGEREQUEST:
            state["layout"] = lparam & 0xFFFFFFFF
        return 1
    api.PostMessageW.side_effect = post
    return api, state


class SwitchToUsTests(unittest.TestCase):
    def setUp(self):
        import gx_input_language
        self.language = gx_input_language

    def test_a_loaded_us_layout_is_used_and_nothing_is_loaded(self):
        user, (api, state), added = FakeUser32([0x08040804, 0x04090409]), thread(0x08040804), []
        result = self.language.switch_to_us(api, 5, user=user, added=added)
        self.assertEqual(("loaded-list", True, "0x04090409"), (result["method"], result["switched"], result["layout"]))
        api.PostMessageW.assert_called_once_with(77, WM_INPUTLANGCHANGEREQUEST, 0, 0x04090409)
        self.assertEqual((0x04090409, [], []), (state["layout"], user.loads, added))

    def test_plain_us_is_preferred_over_a_loaded_variant(self):
        user, (api, state) = FakeUser32([0xF0020409, 0x04090409]), thread(0x08040804)
        self.language.switch_to_us(api, 5, user=user, added=[])
        self.assertEqual(0x04090409, state["layout"])

    def test_a_missing_us_layout_is_refused_without_loading_one(self):
        user, (api, state) = FakeUser32([0x08040804]), thread(0x08040804)
        with self.assertRaisesRegex(self.language.LayoutUnavailable, "never loads"):
            self.language.switch_to_us(api, 5, user=user, added=[])
        self.assertEqual(([], 0x08040804), (user.loads, state["layout"]))
        api.PostMessageW.assert_not_called()

    def test_vm_allow_load_loads_once_and_unloads_only_what_it_added(self):
        user, (api, state), added = FakeUser32([0x08040804]), thread(0x08040804), []
        result = self.language.switch_to_us(api, 5, user=user, added=added, allow_load=True)
        self.assertEqual([("00000409", 0x80)], user.loads)  # KLF_NOTELLSHELL, not activated
        self.assertEqual(([0x04090409], True, 0x04090409), (added, result["switched"], state["layout"]))
        self.assertIn("allow-load-layouts", result["method"])
        self.assertEqual([{"layout": "0x04090409", "unloaded": True}], self.language.unload_layouts(added, user=user))
        self.assertEqual(([0x04090409], []), (user.unloads, added))

    def test_a_high_bit_layout_is_posted_sign_extended(self):
        user, (api, state) = FakeUser32([0x08040804, 0xF0020409]), thread(0x08040804)
        self.language.switch_to_us(api, 5, user=user, added=[])
        api.PostMessageW.assert_called_once_with(77, WM_INPUTLANGCHANGEREQUEST, 0, -0x0FFDFBF7)

    def test_an_already_us_thread_posts_nothing(self):
        user, (api, state) = FakeUser32([0x04090409]), thread(0x04090409)
        self.assertEqual("already", self.language.switch_to_us(api, 5, user=user, added=[])["method"])
        api.PostMessageW.assert_not_called()

    def test_a_thread_that_does_not_follow_is_reported_not_switched(self):
        user, (api, state) = FakeUser32([0x08040804, 0x04090409]), thread(0x08040804)
        api.PostMessageW.side_effect = None
        clock = iter(range(0, 100))
        with mock.patch.object(self.language.time, "monotonic", side_effect=lambda: next(clock)), \
                mock.patch.object(self.language.time, "sleep"):
            result = self.language.switch_to_us(api, 5, user=user, added=[], timeout=3)
        self.assertEqual((False, "0x08040804"), (result["switched"], result["current"]))


class FixtureCallSiteTests(unittest.TestCase):
    def test_no_fixture_loads_a_layout_on_the_host_path(self):
        """gx_win_gui's old ime_off/request_us_layout call LoadKeyboardLayoutW."""
        offenders = []
        for path in sorted(HERE.glob("gx_*.py")):
            text = path.read_text(encoding="utf-8")
            for needle in ("request_us_layout(", ".ime_off(", "LoadKeyboardLayout"):
                if needle in text and not (path.name == "gx_input_language.py" and needle == "LoadKeyboardLayout"):
                    offenders.append(f"{path.name}: {needle}")
        self.assertEqual([], offenders)

    def test_controller_us_uses_loaded_layouts_and_reports_missing_as_environment(self):
        import gx_boundary_controller as controller
        instance = mock.Mock(pid=42)
        for loaded, allow in (([0x08040804, 0x04090409], False), ([0x08040804], False)):
            fixture = SimpleNamespace(report={}, check=mock.Mock(), args=SimpleNamespace(allow_load_layouts=allow))
            api, state = thread(0x08040804)
            with mock.patch.object(controller.gui, "win32", return_value=api), \
                    mock.patch("gx_input_language._user32", return_value=FakeUser32(loaded)):
                language = controller.InputLanguage(fixture, instance, 5)
                if 0x04090409 in loaded:
                    language.us()
                    self.assertEqual(0x04090409, state["layout"])
                else:
                    with self.assertRaisesRegex(controller.EnvironmentUnavailable, "never loads"):
                        language.us()
        instance.ime_off.assert_not_called()

    def test_remote_fixture_uses_loaded_layouts_and_blocks_when_us_is_missing(self):
        import gx_remote_fixture as remote
        fixture = remote.Fixture.__new__(remote.Fixture)
        fixture.layout_saved, fixture.report, fixture.save = None, {}, mock.Mock()
        fixture.allow_load_layouts, fixture.layouts_added = False, []
        api, state = thread(0x08040804)
        api.request_us_layout.side_effect = AssertionError("the host must not load a layout")
        with mock.patch.object(remote.gui, "win32", return_value=api), \
                mock.patch("gx_input_language._user32", return_value=FakeUser32([0x08040804])):
            self.assertFalse(fixture.use_us_layout(mock.Mock(), 5))
        self.assertIn("never loads", fixture.report["input_language"]["us"])
        with mock.patch.object(remote.gui, "win32", return_value=api), \
                mock.patch("gx_input_language._user32", return_value=FakeUser32([0x08040804, 0x04090409])):
            self.assertTrue(fixture.use_us_layout(mock.Mock(), 5))
        self.assertEqual(0x04090409, state["layout"])
        api.request_us_layout.assert_not_called()


if __name__ == "__main__":
    unittest.main()
