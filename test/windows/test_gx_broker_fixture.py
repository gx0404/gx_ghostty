"""Offline contracts; all native APIs are mocked and files are temporary."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_drop_broker_fixture as broker


class BrokerPreviewTests(unittest.TestCase):
    def test_multiline_respond_reaches_reviewed_preview_button(self):
        self.respond_preview('GhosttyGxPopup')

    def test_multiline_respond_accepts_shadow_popup_class(self):
        self.respond_preview('GhosttyGxPopupShadow')

    def respond_preview(self, popup_class):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            work = root / 'cases' / 'multiline'
            work.mkdir(parents=True)
            broker.save(work / 'report.json', {'target': {'token': {'integrity': 'high'}}, 'case': 'multiline'})
            popup = SimpleNamespace(hwnd=3, cls=popup_class, title='Paste into elevated terminal?', rect=(0, 0, 400, 200))
            target = mock.Mock(pid=42)
            target.popups.return_value = [popup]
            target.require_window.return_value = popup
            args = SimpleNamespace(root=root, name='multiline', command='respond', popup_hwnd=3,
                                   decision='allow', x=50, y=100, stage='broker-preview', delay_ms=0)
            with mock.patch.object(broker, 'owner', return_value=target), mock.patch.object(broker, 'require_level'), \
                    mock.patch.object(broker, 'same_session'), mock.patch.object(broker.gui, 'win32') as api, \
                    mock.patch.object(broker.time, 'sleep'):
                api.return_value.foreground.return_value = 3
                api.return_value.class_name.return_value = popup.cls
                api.return_value.window_pid.return_value = 42
                api.return_value.window_at.return_value = 3
                broker.inspect_or_respond(args, {})
            target.mouse.assert_called_once_with(50, 100)
            target.press.assert_not_called()

    def test_multiline_can_approve_only_broker_preview_never_protected_paste(self):
        broker.require_broker_preview('multiline', 'broker-preview', 'Paste into elevated terminal?')
        for stage, title in (('protected-paste', 'Warning: Potentially Unsafe Paste'),
                             ('broker-preview', 'Warning: Potentially Unsafe Paste'),
                             ('protected-paste', 'Paste into elevated terminal?')):
            with self.subTest(stage=stage, title=title), self.assertRaises(ValueError):
                broker.require_broker_preview('multiline', stage, title)


if __name__ == "__main__":
    unittest.main()
