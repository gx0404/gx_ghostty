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


if __name__ == "__main__":
    unittest.main()
