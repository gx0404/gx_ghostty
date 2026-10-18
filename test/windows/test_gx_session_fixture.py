"""Offline contracts; all native APIs are mocked and files are temporary."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_session_ipc_fixture as sessions


class SessionContractTests(unittest.TestCase):
    def test_launcher_birth_is_recorded_before_resume_without_optional_subprocess_constants(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            exe = root / 'fixture.exe'
            exe.write_bytes(b'fixture')
            fixture = sessions.Fixture(exe, root / 'out', 'unit')
            identity = SimpleNamespace(pid=42, creation=123, exe=str(exe), ensure_owned=mock.Mock())
            with mock.patch.object(sessions.gui, 'win32') as api, mock.patch.object(sessions.gui, 'Instance', return_value=identity), \
                    mock.patch.object(sessions.subprocess, 'Popen') as popen, mock.patch.object(fixture, 'resume') as resume:
                api.return_value.process_creation.return_value = 123
                popen.return_value.pid = 42
                result = fixture.start(root, resume=False)
                self.assertIs(identity, result)
                self.assertEqual(0x00000004, popen.call_args.kwargs['creationflags'])
                self.assertEqual(123, fixture.report['processes'][0]['birth'])
                resume.assert_not_called()

    def test_roundtrip_detects_active_zoom_ratio_title_font_and_cwd_loss(self):
        seed = sessions.complex_document(Path('C:/private fixture'))
        expected = sessions.layout_contract(seed)
        for label, change in (
            ('active', lambda t: t.update(active=1)),
            ('zoom', lambda t: t.update(zoom=None)),
            ('ratio', lambda t: t['nodes'][0]['split'].update(ratio=0.5)),
            ('title', lambda t: t.update(title_override='wrong')),
            ('font', lambda t: t['nodes'][1]['leaf'].update(font_size=24)),
            ('cwd', lambda t: t['nodes'][1]['leaf'].update(cwd=None)),
        ):
            document = json.loads(json.dumps(seed))
            change(document['windows'][0]['tabs'][0])
            with self.subTest(label=label):
                self.assertNotEqual(expected, sessions.layout_contract(document))

    def test_privacy_rejects_nested_extra_fields_and_marker_content(self):
        document = sessions.complex_document(Path('C:/private'))
        sessions.assert_private_document(document)
        document['windows'][0]['tabs'][0]['nodes'][1]['leaf']['argv'] = []
        with self.assertRaisesRegex(AssertionError, 'unexpected fields'):
            sessions.assert_private_document(document)
        del document['windows'][0]['tabs'][0]['nodes'][1]['leaf']['argv']
        with self.assertRaisesRegex(AssertionError, 'dynamic title'):
            sessions.assert_private_document(document, ('中文',))

    def capture_setup(self, root, exstyle, owner=0x100, owner_pid=42):
        exe = root / 'fixture.exe'
        exe.write_bytes(b'fixture')
        fixture = sessions.Fixture(exe, root / 'out', 'unit')
        target = sessions.gui.WindowInfo(0x200, 'GhosttyGxPopup', '', (10, 10, 110, 60), True, False, False)
        image = mock.Mock()
        instance = SimpleNamespace(pid=42, ensure_owned=mock.Mock(), capture_window=mock.Mock(return_value=image))
        api = mock.Mock()
        api.GetWindowLongPtrW.return_value = exstyle
        api.GetAncestor.side_effect = lambda hwnd, flag: owner if flag == 3 else hwnd
        api.window_pid.side_effect = lambda hwnd: owner_pid if hwnd == owner else 42
        api.info.return_value = target
        api.window_at.return_value = target.hwnd
        return fixture, target, instance, api, image

    def test_a_menu_popup_is_captured_with_its_owner_holding_the_foreground(self):
        # A menu popup (WS_EX_NOACTIVATE) never becomes the foreground window, so
        # asking to activate it fails; its owned root owner holds the foreground.
        with tempfile.TemporaryDirectory() as folder:
            fixture, popup, instance, api, image = self.capture_setup(Path(folder), 0x08000000 | 0x80)
            api.activate.side_effect = lambda hwnd: hwnd == 0x100
            with mock.patch.object(sessions.gui, 'win32', return_value=api), \
                    mock.patch.object(sessions, 'native_snapshot', return_value={}), mock.patch.object(sessions.time, 'sleep'):
                fixture.capture(instance, 'menu', popup)
            api.activate.assert_called_once_with(0x100)
            instance.capture_window.assert_called_once_with(popup, 'screen')
            image.save_png.assert_called_once_with(fixture.out / 'menu.png')
            record = fixture.report['captures'][-1]
            self.assertEqual((True, 0x100), (record['foreground'], record['foreground_hwnd']))

    def test_a_menu_popup_owned_by_another_process_or_closed_by_the_activation_is_not_captured(self):
        for label, owner_pid, visible in (('foreign owner', 7, True), ('closed', 42, False)):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as folder:
                fixture, popup, instance, api, _ = self.capture_setup(Path(folder), 0x08000000, owner_pid=owner_pid)
                api.activate.return_value = True
                api.info.return_value = sessions.gui.WindowInfo(popup.hwnd, popup.cls, '', popup.rect, visible, False, False)
                with mock.patch.object(sessions.gui, 'win32', return_value=api), \
                        mock.patch.object(sessions, 'native_snapshot', return_value={}), mock.patch.object(sessions.time, 'sleep'), \
                        self.assertRaises((sessions.gui.InputBlocked, AssertionError)):
                    fixture.capture(instance, 'menu', popup)
                instance.capture_window.assert_not_called()

    def test_an_activatable_window_must_itself_hold_the_foreground(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, window, instance, api, _ = self.capture_setup(Path(folder), 0)
            api.activate.return_value = False
            with mock.patch.object(sessions.gui, 'win32', return_value=api), self.assertRaisesRegex(sessions.gui.InputBlocked, 'foreground denied'):
                fixture.capture(instance, 'palette', window)
            api.activate.assert_called_once_with(window.hwnd)
            instance.capture_window.assert_not_called()


if __name__ == "__main__":
    unittest.main()
