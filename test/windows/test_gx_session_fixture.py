"""Offline contracts; all native APIs are mocked and files are temporary."""
import json
from contextlib import ExitStack, nullcontext, redirect_stdout
import io
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


class AclRollbackTests(unittest.TestCase):
    sid = 'S-1-5-21-123'

    def exercise(self, original, restored=None, verified=None):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        directory = root / 'state'; directory.mkdir()
        snapshots = iter([original, restored or original, verified or original])
        def command(*args):
            if '/save' in args:
                entries = next(snapshots)
                Path(args[2]).write_text(''.join(f'{key}\n{value}\n' for key, value in entries.items()),
                                         encoding='utf-16-le')
        calls = mock.Mock(side_effect=command)
        reader = io.BytesIO(b'original')
        opened = self.enterContext(mock.patch.object(sessions, 'open_shared_archive', return_value=reader))
        repair = self.enterContext(mock.patch.object(sessions, 'restore_dacl_metadata'))
        evidence = {}
        context = sessions.deny_state_writes(directory, directory/'archive', self.sid,
                                            root/'before.acl', root/'after.acl', calls, evidence)
        return context, calls, opened, reader, repair, evidence

    def test_explicit_allow_rejected_before_any_mutation(self):
        for kind in ('A', 'OA'):
            for flags in ('', 'OI', 'CI', 'OICI', 'IO', 'OICIIO', 'NP'):
                with self.subTest(kind=kind, flags=flags):
                    ace = f'({kind};{flags};FA;;;{self.sid})'
                    context, calls, opened, _, _, _ = self.exercise({'state': 'D:' + ace})
                    with self.assertRaisesRegex(AssertionError, 'explicit.*allow'):
                        with context: self.fail('unsafe injection accepted')
                    opened.assert_not_called()
                    self.assertEqual(1, calls.call_count)

    def test_inherited_allow_and_other_sid_are_not_rejected(self):
        for kind in ('A', 'OA'):
            for flags, sid in (('ID', self.sid), ('OICIID', self.sid), ('OICIIOID', self.sid),
                               ('', self.sid + '4'), ('', 'S-1-5-18')):
                with self.subTest(kind=kind, flags=flags, sid=sid):
                    context, _, _, reader, repair, evidence = self.exercise(
                        {'state': f'D:({kind};{flags};FA;;;{sid})'})
                    with context: pass
                    self.assertTrue(reader.closed)
                    repair.assert_not_called()
                    self.assertTrue(evidence['exact_dacl_match'])

    def test_original_deny_including_object_and_inherited_is_rejected(self):
        for kind in ('D', 'OD'):
            for flags in ('', 'ID', 'OICIIOID'):
                with self.subTest(kind=kind, flags=flags):
                    context, calls, opened, _, _, _ = self.exercise(
                        {'state': 'D:', 'state/archive': f'D:({kind};{flags};WD;;;{self.sid})'})
                    with self.assertRaisesRegex(AssertionError, 'already denies'):
                        with context: self.fail('unsafe injection accepted')
                    opened.assert_not_called()
                    self.assertEqual(1, calls.call_count)

    def test_object_guids_callback_and_sid_boundaries(self):
        guid = '00112233-4455-6677-8899-aabbccddeeff'
        for kind in ('OA', 'XA', 'ZA', 'OD', 'XD', 'ZD'):
            for trustee in (self.sid, self.sid.lower(), self.sid + '4'):
                with self.subTest(kind=kind, trustee=trustee):
                    suffix = ';(@User.flag == 1)' if kind in ('XA', 'ZA', 'XD', 'ZD') else ''
                    ace = f'({kind};OICI;0x1f01ff;{guid};{guid};{trustee}{suffix})'
                    context, calls, opened, _, _, _ = self.exercise({'state': 'D:', 'state/archive': 'D:' + ace})
                    if trustee.casefold() == self.sid.casefold():
                        with self.assertRaisesRegex(AssertionError, 'explicit.*allow|already denies'):
                            with context: self.fail('unsafe injection accepted')
                        opened.assert_not_called()
                        self.assertEqual(1, calls.call_count)
                    else:
                        with context: pass

    def test_only_ai_metadata_is_repaired_and_exact_snapshot_verified(self):
        for prefix in ('D:', 'D:P'):
            with self.subTest(prefix=prefix):
                original = {'state': prefix + '(A;;FA;;;SY)', 'state/archive': 'D:AI(A;;FR;;;SY)'}
                changed = dict(original, state=prefix + 'AI(A;;FA;;;SY)')
                context, calls, _, reader, repair, evidence = self.exercise(original, changed)
                with context: pass
                self.assertEqual(5, calls.call_count)
                self.assertEqual({'state': original['state']}, repair.call_args.args[1])
                self.assertTrue(reader.closed)
                self.assertTrue(evidence['exact_dacl_match'])

    def test_failed_exact_verification_after_ai_repair_is_rejected(self):
        original = {'state': 'D:(A;;FA;;;SY)'}
        changed = {'state': 'D:AI(A;;FA;;;SY)'}
        context, _, _, reader, repair, evidence = self.exercise(original, changed, changed)
        with self.assertRaisesRegex(AssertionError, 'DACL differs'):
            with context: pass
        repair.assert_called_once()
        self.assertTrue(reader.closed)
        self.assertNotIn('exact_dacl_match', evidence)

    def test_real_ace_or_control_or_entry_difference_never_repaired(self):
        for changed in ({'state': 'D:AI(A;;FR;;;SY)'}, {'state': 'D:PAI(A;;FA;;;SY)'},
                        {'state': 'D:AI(A;;FA;;;SY)', 'state/new': 'D:'}):
            with self.subTest(changed=changed):
                context, _, _, reader, repair, _ = self.exercise({'state': 'D:(A;;FA;;;SY)'}, changed)
                with self.assertRaisesRegex(AssertionError, 'DACL differs'):
                    with context: pass
                repair.assert_not_called()
                self.assertTrue(reader.closed)

    def test_metadata_repair_failure_closes_reader_without_claiming_restored(self):
        context, _, _, reader, repair, evidence = self.exercise(
            {'state': 'D:(A;;FA;;;SY)'}, {'state': 'D:AI(A;;FA;;;SY)'})
        repair.side_effect = OSError('metadata repair failed')
        with self.assertRaises(OSError):
            with context: pass
        self.assertTrue(reader.closed)
        self.assertEqual('RESTORE_PENDING', evidence['status'])
        self.assertNotIn('exact_dacl_match', evidence)


class AclMetadataApiTests(unittest.TestCase):
    def harness(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        directory = root / 'state'; directory.mkdir()
        api, kernel = mock.Mock(), mock.Mock()
        def convert(sddl, revision, output, size):
            sessions.ctypes.cast(output, sessions.ctypes.POINTER(sessions.ctypes.c_void_p))[0] = 1234
            return 1
        api.ConvertStringSecurityDescriptorToSecurityDescriptorW.side_effect = convert
        api.SetFileSecurityW.return_value = 1
        self.enterContext(mock.patch.object(sessions.ctypes, 'WinDLL', create=True,
                                           side_effect=lambda name, **kw: api if name == 'advapi32' else kernel))
        self.enterContext(mock.patch.object(sessions.ctypes, 'WinError', create=True, return_value=OSError('native failure')))
        self.enterContext(mock.patch.object(sessions.ctypes, 'get_last_error', create=True, return_value=5))
        return root, directory, api, kernel

    def test_sets_only_dacl_and_frees_descriptor(self):
        _, directory, api, kernel = self.harness()
        sessions.restore_dacl_metadata(directory, {'state': 'D:(A;;FA;;;SY)'})
        args = api.SetFileSecurityW.call_args.args
        self.assertEqual((str(directory.resolve()), 4, 1234), (args[0], args[1], args[2].value))
        kernel.LocalFree.assert_called_once_with(args[2])
        self.assertEqual(('D:(A;;FA;;;SY)', 1), api.ConvertStringSecurityDescriptorToSecurityDescriptorW.call_args.args[:2])

    def test_set_failure_still_frees_descriptor(self):
        _, directory, api, kernel = self.harness()
        api.SetFileSecurityW.return_value = 0
        with self.assertRaises(OSError):
            sessions.restore_dacl_metadata(directory, {'state': 'D:'})
        kernel.LocalFree.assert_called_once()
        self.assertEqual(1234, kernel.LocalFree.call_args.args[0].value)

    def test_conversion_failure_does_not_set_or_free_unallocated_descriptor(self):
        _, directory, api, kernel = self.harness()
        api.ConvertStringSecurityDescriptorToSecurityDescriptorW.side_effect = None
        api.ConvertStringSecurityDescriptorToSecurityDescriptorW.return_value = 0
        with self.assertRaises(OSError):
            sessions.restore_dacl_metadata(directory, {'state': 'D:'})
        api.SetFileSecurityW.assert_not_called()
        kernel.LocalFree.assert_not_called()

    def test_escape_is_rejected_before_conversion(self):
        root, directory, api, _ = self.harness()
        (root/'outside').write_bytes(b'')
        for relative in ('outside', 'state/../outside', str(root/'outside')):
            with self.subTest(relative=relative), self.assertRaisesRegex(AssertionError, 'escapes'):
                sessions.restore_dacl_metadata(directory, {relative: 'D:'})
        api.ConvertStringSecurityDescriptorToSecurityDescriptorW.assert_not_called()
        api.SetFileSecurityW.assert_not_called()

    def test_reparse_on_target_or_parent_or_root_is_rejected(self):
        _, directory, api, _ = self.harness()
        parent = directory/'nested'; parent.mkdir()
        target = parent/'archive'; target.write_bytes(b'')
        original_lstat = Path.lstat
        for unsafe in (target, parent, directory):
            def lstat(path, *args, **kwargs):
                result = original_lstat(path, *args, **kwargs)
                if path == unsafe:
                    return SimpleNamespace(st_file_attributes=0x400, st_mode=result.st_mode)
                return result
            with self.subTest(unsafe=unsafe), mock.patch.object(Path, 'lstat', lstat):
                # A junction is not a symlink; stat follows it and loses the
                # reparse attribute, while lstat describes the junction itself.
                self.assertFalse(unsafe.is_symlink())
                self.assertFalse(getattr(unsafe.stat(), 'st_file_attributes', 0) & 0x400)
                self.assertTrue(unsafe.lstat().st_file_attributes & 0x400)
                with self.assertRaisesRegex(AssertionError, 'reparse'):
                    sessions.restore_dacl_metadata(directory, {'state/nested/archive': 'D:'})
        api.ConvertStringSecurityDescriptorToSecurityDescriptorW.assert_not_called()
        api.SetFileSecurityW.assert_not_called()

    def assert_native_junction_rejected(self, *, at_root):
        root, _, api, kernel = self.harness()
        outside = root/'outside'/'state'; outside.mkdir(parents=True)
        archive = outside/'archive'; archive.write_bytes(b'outside sentinel')
        private = root/'private'; private.mkdir()
        directory = private/'state'
        if at_root:
            junction = directory
            relative = 'state/archive'
        else:
            directory.mkdir()
            junction = directory/'nested'
            relative = 'state/nested/archive'
        # Both endpoints are owned by this TemporaryDirectory. Remove only
        # the junction before TemporaryDirectory recursively cleans real dirs.
        self.assertTrue(junction.parent.resolve().is_relative_to(root.resolve()))
        self.assertTrue(outside.resolve().is_relative_to(root.resolve()))
        try:
            result = sessions.subprocess.run(
                ['cmd.exe', '/d', '/c', 'mklink', '/J', str(junction), str(outside)],
                capture_output=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse(junction.is_symlink())
            self.assertFalse(junction.stat().st_file_attributes & 0x400)
            self.assertTrue(junction.lstat().st_file_attributes & 0x400)
            self.assertEqual(outside.resolve(), junction.resolve())
            with self.assertRaisesRegex(AssertionError, 'reparse'):
                sessions.restore_dacl_metadata(directory, {relative: 'D:'})
            api.ConvertStringSecurityDescriptorToSecurityDescriptorW.assert_not_called()
            api.SetFileSecurityW.assert_not_called()
            kernel.LocalFree.assert_not_called()
        finally:
            if junction.is_junction():
                sessions.os.rmdir(junction)
            self.assertFalse(junction.exists())
            self.assertEqual(b'outside sentinel', archive.read_bytes())

    @unittest.skipUnless(sessions.os.name == 'nt', 'Windows junction required')
    def test_native_root_junction_cannot_redefine_private_boundary(self):
        self.assert_native_junction_rejected(at_root=True)

    @unittest.skipUnless(sessions.os.name == 'nt', 'Windows junction required')
    def test_native_parent_junction_is_rejected_before_resolution(self):
        self.assert_native_junction_rejected(at_root=False)

    def test_symlink_is_rejected_before_conversion(self):
        _, directory, api, _ = self.harness()
        with mock.patch.object(Path, 'is_symlink', return_value=True):
            with self.assertRaisesRegex(AssertionError, 'reparse'):
                sessions.restore_dacl_metadata(directory, {'state': 'D:'})
        api.ConvertStringSecurityDescriptorToSecurityDescriptorW.assert_not_called()


class SharedArchiveHandleTests(unittest.TestCase):
    def harness(self):
        kernel = mock.Mock()
        kernel.CreateFileW.return_value = 123
        runtime = SimpleNamespace(open_osfhandle=mock.Mock(return_value=456))
        self.enterContext(mock.patch.dict(sessions.sys.modules, msvcrt=runtime))
        self.enterContext(mock.patch.object(sessions.ctypes, 'WinDLL', create=True, return_value=kernel))
        self.enterContext(mock.patch.object(sessions.os, 'O_BINARY', 0, create=True))
        return kernel, runtime

    def test_create_failure_does_not_close_invalid_handle(self):
        kernel, runtime = self.harness()
        kernel.CreateFileW.return_value = sessions.ctypes.c_void_p(-1).value
        with mock.patch.object(sessions.ctypes, 'WinError', create=True, return_value=OSError('open failed')), \
                mock.patch.object(sessions.ctypes, 'get_last_error', create=True, return_value=5):
            with self.assertRaises(OSError): sessions.open_shared_archive(Path('archive'))
        runtime.open_osfhandle.assert_not_called()
        kernel.CloseHandle.assert_not_called()

    def test_handle_transfer_failure_closes_native_handle(self):
        kernel, runtime = self.harness()
        runtime.open_osfhandle.side_effect = OSError('transfer failed')
        with self.assertRaises(OSError): sessions.open_shared_archive(Path('archive'))
        kernel.CloseHandle.assert_called_once_with(123)

    def test_fdopen_failure_closes_transferred_fd_not_handle_twice(self):
        kernel, _ = self.harness()
        with mock.patch.object(sessions.os, 'fdopen', side_effect=OSError('fdopen failed')), \
                mock.patch.object(sessions.os, 'close') as close:
            with self.assertRaises(OSError): sessions.open_shared_archive(Path('archive'))
        close.assert_called_once_with(456)
        kernel.CloseHandle.assert_not_called()

    def test_success_transfers_ownership_and_preserves_share_delete(self):
        kernel, runtime = self.harness()
        reader = io.BytesIO(b'original')
        with mock.patch.object(sessions.os, 'fdopen', return_value=reader) as fdopen:
            with sessions.open_shared_archive(Path('archive')) as result:
                self.assertIs(reader, result)
            fdopen.assert_called_once_with(456, 'rb', buffering=0)
        self.assertTrue(reader.closed)
        self.assertEqual(7, kernel.CreateFileW.call_args.args[2])
        runtime.open_osfhandle.assert_called_once()
        kernel.CloseHandle.assert_not_called()


class StartupBaselineTests(unittest.TestCase):
    def harness(self, folder, *, layout_bad=False, never_ready=False, mutate=False,
                old_error=False, new_error=True, restore_error=False):
        root = Path(folder)
        exe = root / 'fixture.exe'; exe.write_bytes(b'fixture')
        fixture = sessions.Fixture(exe, root / 'out', 'unit')
        path = root / 'private'; path.mkdir()
        log = root / 'ghostty.log'
        log.write_bytes(b'session save failed: old startup error\n' if old_error else b'')
        dialog = sessions.gui.WindowInfo(200, 'GhosttyGxPopup', 'Confirm', (0, 0, 100, 50), True, False, True)
        instance = SimpleNamespace(pid=42, creation=123, exe=str(exe), log=log,
            ensure_owned=mock.Mock(), activate=mock.Mock(), require_window=mock.Mock(return_value=SimpleNamespace(hwnd=100)),
            popups=mock.Mock(return_value=[dialog]), wait_log=mock.Mock())
        state = {'time': 0, 'saved': False, 'acl': [], 'quit': 0, 'action_generation': None}
        def startup_save():
            if state['saved'] or never_ready: return
            document = sessions.complex_document(path); document['generation'] = 8
            if layout_bad: document['windows'][0]['tabs'][0]['nodes'][1]['leaf']['font_size'] = 99
            fixture.session(path).write_text(json.dumps(document), encoding='utf-8')
            state['saved'] = True
        def sleep(seconds):
            state['time'] += seconds
            startup_save()
        def capture(*args):
            startup_save()  # Legitimate first-only save, not the action under test.
        def press(key):
            if key == 'escape':
                instance.popups.return_value = []
                if mutate:
                    target = fixture.session(path); target.write_bytes(target.read_bytes() + b' ')
            elif key == 'ctrl+shift+t':
                state['action_generation'] = json.loads(fixture.session(path).read_bytes())['generation']
                if new_error:
                    with log.open('ab') as stream: stream.write(b'session save failed: injected\n')
                if mutate:
                    target = fixture.session(path); target.write_bytes(target.read_bytes() + b' ')
        instance.press = mock.Mock(side_effect=press)
        def post(*args):
            state['action_generation'] = json.loads(fixture.session(path).read_bytes())['generation']
        api = mock.Mock(); api.PostMessageW.side_effect = post
        def acl_run(argv, **kwargs):
            state['acl'].append(argv)
            # Another realistic delivery point during preparation of DACL.
            if '/save' in argv:
                startup_save()
                Path(argv[argv.index('/save') + 1]).write_text(
                    'ghostty\nD:AI(A;;FA;;;SY)\nghostty\\gx-session.json\nD:AI(A;;FA;;;SY)\n',
                    encoding='utf-16')
            return SimpleNamespace(returncode=1 if restore_error and '/remove:d' in argv else 0,
                                   stdout='', stderr='restore failed' if restore_error else '')
        original_open = Path.open
        def file_open(p, *args, **kwargs):
            if p.name == 'denied-write-probe': raise PermissionError('private test DACL')
            return original_open(p, *args, **kwargs)
        stack = ExitStack(); self.addCleanup(stack.close)
        for name, value in [('environment', mock.Mock(return_value=path)), ('start', mock.Mock(return_value=instance)),
                            ('windows', mock.Mock(return_value=[1, 2])), ('capture', mock.Mock(side_effect=capture)),
                            ('quit', mock.Mock(side_effect=lambda _: state.update(quit=state['quit']+1)))]:
            stack.enter_context(mock.patch.object(fixture, name, value))
        stack.enter_context(mock.patch.object(sessions.time, 'monotonic', side_effect=lambda: state['time']))
        stack.enter_context(mock.patch.object(sessions.time, 'sleep', side_effect=sleep))
        stack.enter_context(mock.patch.object(sessions.gui, 'win32', return_value=api))
        stack.enter_context(mock.patch.object(sessions.gui, 'write_config'))
        stack.enter_context(mock.patch.object(sessions.subprocess, 'check_output', return_value='"user","S-1-5-21-test"\n'))
        stack.enter_context(mock.patch.object(sessions.subprocess, 'run', side_effect=acl_run))
        stack.enter_context(mock.patch.object(Path, 'open', file_open))
        stack.enter_context(mock.patch.object(sessions, 'open_shared_archive',
                                             side_effect=lambda p: original_open(p, 'rb', buffering=0)))
        return fixture, path, instance, state

    def test_cancel_close_waits_for_legitimate_startup_save_before_baseline(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, _, state = self.harness(folder)
            fixture.cancel_close()
            self.assertEqual(8, state['action_generation'])
            self.assertEqual(1, state['quit'])
            self.assertEqual('PASS', fixture.report['cases'][-1]['status'])

    def test_write_failure_waits_for_legitimate_startup_save_before_dacl(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, _, state = self.harness(folder)
            fixture.write_failure()
            self.assertEqual(8, state['action_generation'])
            self.assertEqual(1, state['quit'])
            self.assertTrue(any('/remove:d' in argv for argv in state['acl']))
            self.assertEqual('PASS', fixture.report['cases'][-1]['status'])

    def test_denied_new_reads_still_compare_live_archive_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, path, _, state = self.harness(folder)
            original_read = Path.read_bytes
            def read(target):
                denied = state['acl'] and '/deny' in state['acl'][-1]
                if target == fixture.session(path) and denied and state['action_generation'] is not None:
                    raise PermissionError('new read handles denied by the injected ACL')
                return original_read(target)
            with mock.patch.object(Path, 'read_bytes', read):
                fixture.write_failure()
            self.assertEqual('PASS', fixture.report['cases'][-1]['status'])
            self.assertEqual(1, state['quit'])

    def test_restore_does_not_require_restore_privilege(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, _, state = self.harness(folder)
            original_run = sessions.subprocess.run.side_effect
            def run(argv, **kwargs):
                if '/restore' in argv:
                    return SimpleNamespace(returncode=1300, stdout='', stderr='privilege not held')
                return original_run(argv, **kwargs)
            sessions.subprocess.run.side_effect = run
            fixture.write_failure()
            self.assertTrue(any('/remove:d' in argv for argv in state['acl']))
            self.assertFalse(any('/restore' in row['argv'] for row in fixture.report['acl_commands']))

    def test_retained_old_handle_does_not_hide_replaced_archive_path(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, path, _, state = self.harness(folder)
            sessions.open_shared_archive.side_effect = lambda p: io.BytesIO(p.read_bytes())
            def replace_on_quit(_):
                state['quit'] += 1
                target = fixture.session(path)
                replacement = target.with_suffix('.new')
                replacement.write_bytes(target.read_bytes() + b' ')
                replacement.replace(target)
            fixture.quit.side_effect = replace_on_quit
            with self.assertRaises(AssertionError):
                fixture.write_failure()
            self.assertEqual('RESTORED', fixture.report['write_failure_acl']['status'])
            self.assertFalse(fixture.report['cases'])

    def test_dacl_mismatch_after_removal_cannot_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, _, _ = self.harness(folder)
            original_run = sessions.subprocess.run.side_effect
            def run(argv, **kwargs):
                result = original_run(argv, **kwargs)
                if '/save' in argv and 'restored' in str(argv[argv.index('/save') + 1]):
                    Path(argv[argv.index('/save') + 1]).write_text('ghostty\nD:AI\n', encoding='utf-16')
                return result
            sessions.subprocess.run.side_effect = run
            with self.assertRaisesRegex(AssertionError, 'DACL differs'):
                fixture.write_failure()
            self.assertFalse(fixture.report['cases'])

    def test_existing_deny_is_rejected_before_injection(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, instance, state = self.harness(folder)
            original_run = sessions.subprocess.run.side_effect
            def run(argv, **kwargs):
                result = original_run(argv, **kwargs)
                if '/save' in argv:
                    Path(argv[argv.index('/save') + 1]).write_text(
                        'ghostty\nD:(D;;WD;;;S-1-5-21-test)\n', encoding='utf-16')
                return result
            sessions.subprocess.run.side_effect = run
            with self.assertRaisesRegex(AssertionError, 'already denies'):
                fixture.write_failure()
            self.assertFalse(any('/deny' in argv or '/remove:d' in argv for argv in state['acl']))
            instance.press.assert_not_called()

    def test_partial_deny_command_failure_still_rolls_back(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, instance, state = self.harness(folder)
            original_run = sessions.subprocess.run.side_effect
            def run(argv, **kwargs):
                result = original_run(argv, **kwargs)
                if '/deny' in argv:
                    result.returncode = 1
                return result
            sessions.subprocess.run.side_effect = run
            with self.assertRaisesRegex(AssertionError, 'ACL operation failed'):
                fixture.write_failure()
            self.assertTrue(any('/remove:d' in argv for argv in state['acl']))
            self.assertEqual('RESTORED', fixture.report['write_failure_acl']['status'])
            instance.press.assert_not_called()

    def assert_late_readiness_rejected(self, late_stage):
        for case in ('cancel_close', 'write_failure'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as folder:
                fixture, _, instance, state = self.harness(folder)
                normal_sleep = sessions.time.sleep.side_effect
                sleeps = 0
                def advance(seconds):
                    nonlocal sleeps
                    normal_sleep(seconds)
                    sleeps += 1
                    # Seed -> first saved sample -> stable success poll starts
                    # before the deadline, but finishes after it.
                    if sleeps == 2:
                        state['time'] = 14.99
                sessions.time.sleep.side_effect = advance
                if late_stage == 'poll':
                    def windows(_):
                        if fixture.windows.call_count == 3:
                            state['time'] = 15.01
                        return [1, 2]
                    fixture.windows.side_effect = windows
                else:
                    def owned():
                        if instance.ensure_owned.call_count == 4:
                            state['time'] = 15.01
                    instance.ensure_owned.side_effect = owned
                with self.assertRaisesRegex(AssertionError, 'deadline'):
                    getattr(fixture, case)()
                self.assertIsNone(state['action_generation'])
                self.assertEqual([], state['acl'])
                instance.press.assert_not_called()
                fixture.capture.assert_not_called()
                fixture.quit.assert_not_called()
                self.assertEqual('FAIL', fixture.report['startup_readiness'][case]['status'])

    def test_successful_readiness_poll_crossing_deadline_is_rejected(self):
        self.assert_late_readiness_rejected('poll')

    def test_final_owned_check_crossing_deadline_is_rejected(self):
        self.assert_late_readiness_rejected('identity')

    def test_readiness_timeout_or_wrong_layout_never_performs_action_or_acl(self):
        for case in ('cancel_close', 'write_failure'):
            for defect in ('timeout', 'layout'):
                with self.subTest(case=case, defect=defect), tempfile.TemporaryDirectory() as folder:
                    fixture, _, instance, state = self.harness(folder, never_ready=defect == 'timeout',
                                                               layout_bad=defect == 'layout')
                    with self.assertRaises(AssertionError):
                        getattr(fixture, case)()
                    self.assertIsNone(state['action_generation'])
                    self.assertEqual([], state['acl'])
                    self.assertEqual(0, state['quit'])
                    instance.press.assert_not_called()
                    self.assertEqual('FAIL', fixture.report['startup_readiness'][case]['status'])
                    self.assertLessEqual(state['time'], 15.05)

    def test_real_byte_changes_after_cancel_or_denied_write_still_fail(self):
        for case in ('cancel_close', 'write_failure'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as folder:
                fixture, path, _, state = self.harness(folder, mutate=True)
                with self.assertRaises(AssertionError):
                    getattr(fixture, case)()
                # Only whitespace changed: logical equality must NOT replace the
                # original post-action byte equality predicate.
                self.assertTrue(fixture.session(path).read_bytes().endswith(b' '))
                self.assertEqual('READY', fixture.report['startup_readiness'][case]['status'])
                self.assertFalse(fixture.report['cases'])
                if case == 'write_failure':
                    self.assertTrue(any('/remove:d' in argv for argv in state['acl']))

    def test_old_error_alone_is_not_evidence_and_readonly_bytes_remain_protected(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, path, instance, state = self.harness(folder, old_error=True, new_error=False)
            with self.assertRaisesRegex(AssertionError, 'bounded wait'):
                fixture.write_failure()
            self.assertEqual('FAIL', fixture.report['write_failure_log']['status'])
            self.assertEqual(len(b'session save failed: old startup error\n'),
                             fixture.report['write_failure_log']['start_byte'])
            raw = fixture.session(path).read_bytes()
            self.assertEqual(sessions.hashlib.sha256(raw).hexdigest(),
                             fixture.report['startup_readiness']['write_failure']['sha256'])
            self.assertTrue(any('/remove:d' in argv for argv in state['acl']))
            instance.wait_log.assert_not_called()
            self.assertFalse(fixture.report['cases'])

    def test_new_error_after_old_error_is_accepted_with_offset_and_acl_restored(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, path, _, state = self.harness(folder, old_error=True, new_error=True)
            fixture.write_failure()
            evidence = fixture.report['write_failure_log']
            self.assertEqual('OBSERVED', evidence['status'])
            self.assertGreater(evidence['end_byte'], evidence['start_byte'])
            self.assertEqual(8, json.loads(fixture.session(path).read_bytes())['generation'])
            self.assertTrue(any('/remove:d' in argv for argv in state['acl']))

    def test_acl_restore_failure_is_fatal_even_after_successful_observation(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, path, _, state = self.harness(folder, restore_error=True)
            with self.assertRaisesRegex(AssertionError, 'ACL operation failed'):
                fixture.write_failure()
            self.assertEqual('OBSERVED', fixture.report['write_failure_log']['status'])
            self.assertEqual(1, state['quit'])
            self.assertEqual('/remove:d', state['acl'][-1][2])
            self.assertEqual(1, fixture.report['acl_commands'][-1]['exit_code'])
            self.assertFalse(fixture.report['cases'])
            self.assertEqual(8, json.loads(fixture.session(path).read_bytes())['generation'])

    def test_readiness_rechecks_owned_identity_and_does_not_accept_seed_generation(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, instance, state = self.harness(folder)
            instance.ensure_owned.side_effect = [None, AssertionError('owned birth changed')]
            with self.assertRaisesRegex(AssertionError, 'owned birth changed'):
                fixture.cancel_close()
            self.assertIsNone(state['action_generation'])
            self.assertEqual('FAIL', fixture.report['startup_readiness']['cancel_close']['status'])

    def test_log_replacement_after_injection_is_not_silently_treated_as_new_error(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, instance, state = self.harness(folder, old_error=True)
            original = instance.press.side_effect
            def press(key):
                original(key)
                if key == 'ctrl+shift+t': instance.log.write_bytes(b'session save failed: replaced log\n')
            instance.press.side_effect = press
            with self.assertRaisesRegex(AssertionError, 'truncated or replaced'):
                fixture.write_failure()
            self.assertTrue(any('/remove:d' in argv for argv in state['acl']))
            self.assertFalse(fixture.report['cases'])

    def test_continuing_valid_saves_never_count_as_byte_stable_readiness(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, path, instance, state = self.harness(folder)
            def changing():
                document = sessions.complex_document(path)
                document['generation'] = 8 + int(state['time'] * 100)
                fixture.session(path).write_text(json.dumps(document), encoding='utf-8')
            instance.ensure_owned.side_effect = changing
            with self.assertRaisesRegex(AssertionError, 'bounded wait'):
                fixture.write_failure()
            self.assertLessEqual(state['time'], 15.05)
            self.assertEqual([], state['acl'])
            self.assertIsNone(state['action_generation'])

    def test_readonly_archive_is_compared_again_after_normal_quit(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, path, _, state = self.harness(folder)
            def quit_mutation(_):
                state['quit'] += 1
                target = fixture.session(path); target.write_bytes(target.read_bytes() + b' ')
            fixture.quit.side_effect = quit_mutation
            with self.assertRaises(AssertionError):
                fixture.write_failure()
            self.assertEqual(1, state['quit'])
            self.assertTrue(any('/remove:d' in argv for argv in state['acl']))
            self.assertFalse(fixture.report['cases'])


@unittest.skipUnless(sessions.os.name == 'nt', 'Windows native file sharing and DACL required')
class NativeArchiveAclTests(unittest.TestCase):
    def replace_like_zig(self, source, target):
        # Match pinned Zig 0.16 Io.Threaded.dirRenameWindowsInner: RenameEx
        # with REPLACE_IF_EXISTS | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE.
        # Python's MoveFileEx replacement does not request POSIX semantics.
        c = sessions.ctypes
        class Rename(c.Structure):
            _fields_ = [('flags', c.c_uint32), ('root', c.c_void_p),
                        ('length', c.c_uint32), ('name', c.c_uint16 * 1)]
        class Status(c.Structure):
            _fields_ = [('status', c.c_void_p), ('information', c.c_size_t)]
        kernel = c.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [c.c_wchar_p, c.c_uint32, c.c_uint32, c.c_void_p,
                                       c.c_uint32, c.c_uint32, c.c_void_p]
        kernel.CreateFileW.restype = c.c_void_p
        kernel.CloseHandle.argtypes = [c.c_void_p]
        native = c.WinDLL('ntdll').NtSetInformationFile
        native.argtypes = [c.c_void_p, c.POINTER(Status), c.c_void_p, c.c_uint32, c.c_uint32]
        native.restype = c.c_int32
        name = ('\\??\\' + str(target)).encode('utf-16-le')
        buffer = c.create_string_buffer(Rename.name.offset + len(name))
        header = c.cast(buffer, c.POINTER(Rename)).contents
        header.flags, header.root, header.length = 0x43, None, len(name)
        c.memmove(c.addressof(buffer) + Rename.name.offset, name, len(name))
        handle = kernel.CreateFileW(str(source), 0x40110000, 7, None, 3, 0x80, None)
        self.assertNotEqual(c.c_void_p(-1).value, handle, c.get_last_error())
        try:
            result = native(handle, c.byref(Status()), buffer, len(buffer), 65)
            self.assertEqual(0, result, f'NtSetInformationFile RenameEx: {result & 0xffffffff:#x}')
        finally:
            kernel.CloseHandle(handle)

    def test_retained_reader_allows_atomic_replacement_without_injection(self):
        with tempfile.TemporaryDirectory(prefix='gx-archive-share-') as folder:
            target = Path(folder) / 'archive.json'
            target.write_bytes(b'old')
            with sessions.open_shared_archive(target) as reader:
                replacement = target.with_suffix('.new')
                replacement.write_bytes(b'new')
                self.replace_like_zig(replacement, target)
                self.assertEqual(b'old', reader.read())
                self.assertEqual(b'new', target.read_bytes())
            self.assertTrue(reader.closed)

    def test_native_denial_retains_read_access_and_restores_exact_dacl(self):
        with tempfile.TemporaryDirectory(prefix='gx-archive-acl-') as folder:
            root = Path(folder)
            directory = root / 'state'; directory.mkdir()
            target = directory / 'archive.json'; target.write_bytes(b'baseline')
            sid = list(sessions.csv.reader(sessions.subprocess.check_output(
                ['whoami', '/user', '/fo', 'csv', '/nh'], text=True).splitlines()))[0][1]
            def command(*args):
                result = sessions.subprocess.run(['icacls', *map(str, args)], cwd=root,
                                                capture_output=True, text=True)
                self.assertEqual(0, result.returncode, result.stderr)
            evidence = {}
            with sessions.deny_state_writes(directory, target, sid, root/'before.acl', root/'after.acl',
                                             command, evidence) as reader:
                with self.assertRaises(PermissionError):
                    (directory/'new-file').write_bytes(b'denied')
                self.assertEqual(b'baseline', reader.read())
                reader.seek(0)
                self.assertEqual(b'baseline', reader.read())
            self.assertTrue(reader.closed)
            self.assertEqual(b'baseline', target.read_bytes())
            self.assertEqual('RESTORED', evidence['status'])
            self.assertTrue(evidence['exact_dacl_match'])


class DualWriterTests(unittest.TestCase):
    def harness(self, folder, *, change=None, busy=True, capture_error=False, second_exit=0,
                popup_class='GhosttyGxPopup', popup_title=None, popup_visible=True, popup_cloaked=False):
        root = Path(folder)
        exe = root / 'fixture.exe'
        exe.write_bytes(b'fixture')
        fixture = sessions.Fixture(exe, root / 'out', 'unit')
        path = (root / 'private').resolve()
        first = SimpleNamespace(pid=42, creation=123, exe=str(exe), ensure_owned=mock.Mock())
        second = SimpleNamespace(pid=43, creation=124, exe=str(exe), ensure_owned=mock.Mock(),
                                 wait_window=mock.Mock())
        popup = sessions.gui.WindowInfo(0x200, popup_class,
                                       sessions.SESSION_BUSY if popup_title is None else popup_title,
                                       (10, 10, 110, 60), popup_visible, popup_cloaked, True)
        second.windows = mock.Mock(return_value=[popup] if busy else [])
        second.popups = mock.Mock(return_value=[popup] if busy and popup_visible and not popup_cloaked else [])
        process = mock.Mock(pid=42, _handle=77)
        process.poll.return_value = None
        peer = mock.Mock(pid=43, _handle=78)
        peer.poll.return_value = None
        peer.wait.return_value = second_exit
        process.wait.return_value = 0
        fixture.processes.update({42: process, 43: peer})
        control = mock.Mock()
        control.identity.return_value = dict(pid=42, birth=123, exe=str(exe), live=True)
        control.suspend.return_value = control.resume.return_value = 0
        timer = mock.Mock()
        events = []

        def save(generation):
            document = sessions.complex_document(path)
            document['generation'] = generation
            fixture.session(path).write_text(json.dumps(document, ensure_ascii=False), encoding='utf-8')

        def suspend(handle):
            self.assertEqual(77, handle)
            # The legitimate first writer can save after the readiness sample,
            # before the process has actually stopped. Baseline must be later.
            save(9)
            events.append('suspend')
            return 0

        def resume(handle):
            self.assertEqual(77, handle)
            events.append('resume')
            return 0

        control.suspend.side_effect, control.resume.side_effect = suspend, resume

        def start(_):
            if not fixture.owned:
                fixture.owned.append(first)
                save(8)
                return first
            fixture.owned.append(second)
            if 'suspend' not in events:
                save(9)  # Old fixture falsely attributes this first-only save.
            events.append('second-start')
            return second

        def close(instance):
            self.assertIs(instance, second)
            events.append('second-close')
            if change:
                target = fixture.session(path)
                document = json.loads(target.read_bytes())
                change(document)
                target.write_text(json.dumps(document), encoding='utf-8')
            peer.poll.return_value = second_exit
            if second_exit:
                raise AssertionError('owned app crashed during close')

        def quit_first(instance):
            self.assertIs(instance, first)
            self.assertIn('resume', events)
            events.append('first-quit')
            save(10)
            process.poll.return_value = 0

        def capture(instance, name, window=None):
            self.assertIs(instance, second)
            if capture_error:
                raise RuntimeError('capture failed')
            if window is None:
                window = sessions.gui.WindowInfo(0x100, sessions.gui.WINDOW_CLASS, 'fallback terminal',
                                                (0, 0, 200, 100), True, False, False)
            fixture.report['captures'].append(dict(file=name + '.png', window=sessions.asdict(window),
                                                   identity=dict(process=dict(pid=43, birth=124))))

        def fast_wait(predicate, seconds=15):
            self.assertLessEqual(seconds, 15)
            for _ in range(5):
                result = predicate()
                if result:
                    return result
            raise AssertionError('bounded wait failed')

        api = mock.Mock()
        api.window_pid.return_value = 43
        api.GetAncestor.return_value = 0x100
        stack = ExitStack()
        self.addCleanup(stack.close)
        for name, replacement in (('environment', mock.Mock(return_value=path)),
                                  ('start', mock.Mock(side_effect=start)), ('close', mock.Mock(side_effect=close)),
                                  ('quit', mock.Mock(side_effect=quit_first)), ('capture', mock.Mock(side_effect=capture)),
                                  ('windows', mock.Mock(return_value=[1, 2]))):
            stack.enter_context(mock.patch.object(fixture, name, replacement))
        stack.enter_context(mock.patch.object(sessions, 'wait', side_effect=fast_wait))
        stack.enter_context(mock.patch.object(sessions, 'ProcessControl', return_value=control, create=True))
        stack.enter_context(mock.patch('threading.Timer', return_value=timer))
        stack.enter_context(mock.patch.object(sessions.gui, 'win32', return_value=api))
        stack.enter_context(mock.patch.object(sessions, 'native_snapshot',
                                             side_effect=lambda instance: dict(process=dict(pid=instance.pid, birth=instance.creation))))
        return fixture, path, control, timer, events, api

    def test_first_only_save_is_not_attributed_to_second_and_raw_baseline_is_after_pause(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, control, _, events, _ = self.harness(folder)
            fixture.dual_writer()
            before = (fixture.out / 'dual-writer-before.raw').read_bytes()
            after = (fixture.out / 'dual-writer-after.raw').read_bytes()
            self.assertEqual(9, json.loads(before)['generation'])
            self.assertEqual(before, after)
            self.assertEqual(['suspend', 'second-start', 'second-close', 'resume', 'first-quit'], events)
            control.resume.assert_called_once_with(77)
            self.assertEqual('PASS', fixture.report['cases'][-1]['status'])
            self.assertEqual('OBSERVED_NATIVE', fixture.report['dual_writer']['busy']['status'])
            self.assertEqual(sessions.SESSION_BUSY, fixture.capture.call_args.args[2].title)
            self.assertTrue(fixture.report['dual_writer']['pause']['resume_verified'])

    def test_busy_toast_accepts_exact_shadow_and_nonshadow_native_classes(self):
        # Toast.ensurePopup requests shadow=true; Popup.create therefore uses
        # CLASS_NAME_SHADOW. Both registered popup classes are legitimate.
        for cls in ('GhosttyGxPopupShadow', 'GhosttyGxPopup'):
            with self.subTest(cls=cls), tempfile.TemporaryDirectory() as folder:
                fixture, _, control, _, _, _ = self.harness(folder, popup_class=cls)
                fixture.dual_writer()
                self.assertEqual(cls, fixture.capture.call_args.args[2].cls)
                self.assertEqual('PASS', fixture.report['cases'][-1]['status'])
                self.assertEqual('OBSERVED_NATIVE', fixture.report['dual_writer']['busy']['status'])
                control.resume.assert_called_once_with(77)

    def test_busy_receipt_rejects_near_classes_wrong_titles_and_hidden_windows(self):
        cases = [{'popup_class': cls} for cls in ('GhosttyGxPopupShadowExtra', 'GhosttyGxPopupShadow ',
                                                'ghosttygxpopupshadow', 'OtherPopup', '#32770')]
        cases += [{'popup_title': sessions.SESSION_BUSY + ' '}, {'popup_title': 'Another message'},
                  {'popup_visible': False}, {'popup_cloaked': True}]
        for changes in cases:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as folder:
                fixture, _, control, _, _, _ = self.harness(folder, **changes)
                with self.assertRaises(AssertionError):
                    fixture.dual_writer()
                fixture.capture.assert_not_called()
                control.resume.assert_called_once_with(77)
                self.assertEqual('second-busy', fixture.report['dual_writer']['failed_phase'])

    def test_shadow_toast_rejects_foreign_owner_and_changed_process_birth(self):
        for label in ('owner', 'birth'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as folder:
                fixture, _, control, _, _, api = self.harness(folder, popup_class='GhosttyGxPopupShadow')
                if label == 'owner':
                    api.window_pid.side_effect = lambda hwnd: 999 if hwnd == 0x100 else 43
                else:
                    original = fixture.start.side_effect

                    def start(path):
                        instance = original(path)
                        if instance.pid == 43:
                            instance.ensure_owned.side_effect = sessions.gui.InputBlocked('PID birth changed')
                        return instance

                    fixture.start.side_effect = start
                with self.assertRaises(sessions.gui.InputBlocked):
                    fixture.dual_writer()
                fixture.capture.assert_not_called()
                control.resume.assert_called_once_with(77)

    def test_capture_must_retain_the_matched_busy_class_title_and_native_identity(self):
        for field in ('class', 'title', 'pid', 'birth'):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as folder:
                fixture, _, control, _, _, _ = self.harness(folder)
                original = fixture.capture.side_effect

                def capture(*args):
                    original(*args)
                    record = fixture.report['captures'][-1]
                    if field == 'class':
                        record['window']['cls'] = 'GhosttyGxPopupShadowExtra'
                    elif field == 'title':
                        record['window']['title'] = 'Another message'
                    else:
                        record['identity']['process'][field] = 999

                fixture.capture.side_effect = capture
                with self.assertRaises(AssertionError):
                    fixture.dual_writer()
                control.resume.assert_called_once_with(77)

    def test_busy_timeout_keeps_bounded_actual_second_window_observations(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, control, _, _, _ = self.harness(folder, busy=False)
            original = fixture.start.side_effect
            windows = [sessions.gui.WindowInfo(0x300 + n, 'Unknown' + 'X' * 300, 'message' + 'Y' * 300,
                                               (0, 0, 100, 50), n % 2 == 0, n % 3 == 0, True)
                       for n in range(80)]

            def start(path):
                instance = original(path)
                if instance.pid == 43:
                    instance.windows.return_value = windows
                    instance.popups.return_value = [w for w in windows if w.visible and not w.cloaked]
                return instance

            fixture.start.side_effect = start
            with self.assertRaises(AssertionError):
                fixture.dual_writer()
            busy = fixture.report['dual_writer']['busy']
            self.assertEqual('NOT_OBSERVED', busy['status'])
            self.assertEqual(32, len(busy['observations']))
            self.assertGreater(busy['observations_dropped'], 0)
            self.assertGreater(busy['polls'], 0)
            self.assertEqual(len(windows) * busy['polls'], busy['text_truncated_count'])
            for row in busy['observations']:
                actual = windows[row['hwnd'] - 0x300]
                self.assertEqual(43, row['pid'])
                self.assertEqual(actual.visible, row['visible'])
                self.assertEqual(actual.cloaked, row['cloaked'])
                self.assertEqual(actual.cls[:256], row['class'])
                self.assertEqual(actual.title[:256], row['title'])
                self.assertTrue(row['text_truncated'])
            fixture.capture.assert_not_called()
            control.resume.assert_called_once_with(77)

    def test_busy_truncation_total_survives_eviction_of_every_truncated_record(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, _, _, _, _ = self.harness(folder, busy=False)
            original = fixture.start.side_effect
            long_rows = [sessions.gui.WindowInfo(0x300 + n, cls, title, (0, 0, 100, 50), True, False, True)
                         for n, (cls, title) in enumerate((('X' * 300, 'short'), ('Unknown', 'Y' * 300),
                                                          ('X' * 300, 'Y' * 300)))]
            short_rows = [sessions.gui.WindowInfo(0x400 + n, 'Unknown', 'short', (0, 0, 100, 50), True, False, True)
                          for n in range(40)]

            def start(path):
                instance = original(path)
                if instance.pid == 43:
                    polls = iter([long_rows, short_rows])
                    instance.windows.side_effect = lambda: next(polls, short_rows)
                return instance

            fixture.start.side_effect = start
            with self.assertRaises(AssertionError):
                fixture.dual_writer()
            busy = fixture.report['dual_writer']['busy']
            self.assertGreater(busy['observations_dropped'], 0)
            self.assertEqual(32, len(busy['observations']))
            self.assertFalse(any(row['text_truncated'] for row in busy['observations']))
            # Count window samples, not individual fields: both-long is one.
            self.assertEqual(3, busy['text_truncated_count'])

    def test_cancel_close_recognizes_both_popup_classes_and_native_dialog(self):
        for cls in ('GhosttyGxPopupShadow', 'GhosttyGxPopup', '#32770'):
            with self.subTest(cls=cls), tempfile.TemporaryDirectory() as folder:
                fixture, _, _, _, _, _ = self.harness(folder)
                original = fixture.start.side_effect
                dialog = sessions.gui.WindowInfo(0x200, cls, 'Confirm close', (0, 0, 100, 50), True, False, True)

                def start(path):
                    instance = original(path)
                    instance.require_window = mock.Mock(return_value=SimpleNamespace(hwnd=0x100))
                    instance.popups = mock.Mock(return_value=[dialog])
                    instance.press = mock.Mock(side_effect=lambda key: setattr(instance.popups, 'return_value', [])
                                               if key == 'escape' else None)
                    return instance

                fixture.start.side_effect = start
                with mock.patch.object(fixture, 'capture') as capture, mock.patch.object(fixture, 'quit'), \
                        mock.patch.object(sessions.gui, 'write_config'), mock.patch.object(sessions.time, 'sleep'):
                    fixture.cancel_close()
                self.assertIs(dialog, capture.call_args_list[0].args[2])
                self.assertEqual('PASS', fixture.report['cases'][-1]['status'])

    def test_no_first_process_or_gui_queries_are_made_while_paused(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, _, control, _, events, _ = self.harness(folder)
            original = control.suspend.side_effect

            def suspend(handle):
                first = fixture.owned[0]
                first.ensure_owned.side_effect = AssertionError('first queried while suspended')
                fixture.windows.side_effect = AssertionError('first windows queried while suspended')
                return original(handle)

            control.suspend.side_effect = suspend
            fixture.dual_writer()
            self.assertIn('first-quit', events)

    def test_generation_only_and_layout_writes_are_failures_with_original_bytes_retained(self):
        for label, change in (('generation', lambda d: d.update(generation=d['generation'] + 1)),
                              ('layout', lambda d: d.update(windows=[]))):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as folder:
                fixture, _, control, _, events, _ = self.harness(folder, change=change)
                with self.assertRaisesRegex(AssertionError, 'archive changed while first writer was suspended'):
                    fixture.dual_writer()
                self.assertNotEqual((fixture.out / 'dual-writer-before.raw').read_bytes(),
                                    (fixture.out / 'dual-writer-after.raw').read_bytes())
                control.resume.assert_called_once_with(77)
                self.assertNotIn('first-quit', events)
                self.assertTrue(fixture.report['dual_writer']['failed_phase'])

    def test_missing_busy_receipt_and_foreign_popup_cannot_pass(self):
        for label in ('missing', 'foreign'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as folder:
                fixture, _, control, _, _, api = self.harness(folder, busy=label != 'missing')
                if label == 'foreign':
                    api.window_pid.return_value = 999
                with self.assertRaises((AssertionError, sessions.gui.InputBlocked)):
                    fixture.dual_writer()
                fixture.capture.assert_not_called()
                self.assertTrue((fixture.out / 'dual-writer-before.raw').is_file())
                self.assertTrue((fixture.out / 'dual-writer-after.raw').is_file())
                control.resume.assert_called_once_with(77)

    def test_capture_and_exit_failure_preserve_boundary_and_resume_first(self):
        for label in ('capture', 'exit'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as folder:
                fixture, _, control, _, _, _ = self.harness(folder, capture_error=label == 'capture',
                                                          second_exit=3 if label == 'exit' else 0)
                with self.assertRaises((AssertionError, RuntimeError)):
                    fixture.dual_writer()
                self.assertTrue((fixture.out / 'dual-writer-before.raw').is_file())
                self.assertTrue((fixture.out / 'dual-writer-after.raw').is_file())
                control.resume.assert_called_once_with(77)
                self.assertTrue(fixture.report['dual_writer']['failed_phase'])
                self.assertEqual(3 if label == 'exit' else 0, fixture.report['dual_writer']['second_exit'])

    def test_start_failure_and_corrupt_archive_preserve_bytes_and_resume(self):
        for label in ('start', 'corrupt'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as folder:
                fixture, path, control, _, _, _ = self.harness(folder)
                if label == 'start':
                    original = fixture.start.side_effect

                    def start(value):
                        if fixture.owned:
                            raise RuntimeError('second start failed')
                        return original(value)

                    fixture.start.side_effect = start
                else:
                    original = fixture.close.side_effect

                    def close(instance):
                        original(instance)
                        fixture.session(path).write_bytes(b'{corrupt')

                    fixture.close.side_effect = close
                with self.assertRaises((AssertionError, RuntimeError)):
                    fixture.dual_writer()
                self.assertTrue((fixture.out / 'dual-writer-before.raw').is_file())
                after = (fixture.out / 'dual-writer-after.raw').read_bytes()
                if label == 'corrupt':
                    self.assertEqual(b'{corrupt', after)
                control.resume.assert_called_once_with(77)

    def test_quit_must_advance_generation_and_preserve_the_full_nonempty_layout(self):
        for label in ('generation', 'empty', 'font'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as folder:
                fixture, path, control, _, _, _ = self.harness(folder)
                original = fixture.quit.side_effect

                def quit_first(instance):
                    original(instance)
                    document = json.loads(fixture.session(path).read_bytes())
                    if label == 'generation':
                        document['generation'] = 9
                    elif label == 'empty':
                        document['windows'] = []
                    else:
                        document['windows'][0]['tabs'][0]['nodes'][1]['leaf']['font_size'] = 24
                    fixture.session(path).write_text(json.dumps(document), encoding='utf-8')

                fixture.quit.side_effect = quit_first
                with self.assertRaises(AssertionError):
                    fixture.dual_writer()
                self.assertTrue((fixture.out / 'dual-writer-first-quit.raw').is_file())
                control.resume.assert_called_once_with(77)

    def test_shared_logs_keep_phase_source_and_rotation_without_pid_attribution(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture, path, _, _, _, _ = self.harness(folder)
            log = sessions.gui.log_path(path)
            log.parent.mkdir(parents=True)
            log.write_bytes(b'first log')
            original = fixture.start.side_effect

            def start(value):
                if fixture.owned:
                    log.replace(log.with_name(log.name + '.1'))
                    log.write_bytes(b'second log')
                return original(value)

            fixture.start.side_effect = start
            fixture.dual_writer()
            self.assertEqual(b'first log', (fixture.out / 'dual-writer-before-shared-ghostty.log').read_bytes())
            self.assertEqual(b'second log', (fixture.out / 'dual-writer-after-shared-ghostty.log').read_bytes())
            self.assertEqual(b'first log', (fixture.out / 'dual-writer-after-shared-ghostty.log.1').read_bytes())
            records = fixture.report['dual_writer']['logs']
            self.assertTrue(all(row['attribution'] == 'shared path; not a per-PID log' for row in records))
            self.assertTrue(all(Path(row['source']).parent == log.parent for row in records))

    def test_ready_requires_new_generation_and_exact_layout_before_starting_second(self):
        for label in ('old generation', 'wrong layout'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as folder:
                fixture, path, control, _, _, _ = self.harness(folder)
                original = fixture.start.side_effect

                def not_ready(value):
                    result = original(value)
                    document = sessions.complex_document(path)
                    if label == 'wrong layout':
                        document.update(generation=8, windows=[])
                    fixture.session(path).write_text(json.dumps(document), encoding='utf-8')
                    return result

                fixture.start.side_effect = not_ready
                with self.assertRaises(AssertionError):
                    fixture.dual_writer()
                self.assertEqual(1, fixture.start.call_count)
                control.suspend.assert_not_called()

    def test_owned_handle_mismatches_are_rejected_before_suspend(self):
        for field, value in (('pid', 99), ('birth', 999), ('exe', 'C:/foreign.exe'), ('live', False)):
            with self.subTest(field=field):
                process = SimpleNamespace(pid=42, _handle=77)
                instance = SimpleNamespace(pid=42, creation=123, exe='C:/fixture.exe')
                control = mock.Mock()
                identity = dict(pid=42, birth=123, exe='C:/fixture.exe', live=True)
                identity[field] = value
                control.identity.return_value = identity
                with self.assertRaisesRegex(AssertionError, 'owned process'):
                    with sessions.PausedProcess(process, instance, {}, control=control):
                        self.fail('unowned process entered pause body')
                control.suspend.assert_not_called()
                control.resume.assert_not_called()

    def test_watchdog_only_resumes_original_handle_and_marks_timeout_failure(self):
        process = SimpleNamespace(pid=42, _handle=77)
        instance = SimpleNamespace(pid=42, creation=123, exe='C:/fixture.exe')
        control = mock.Mock()
        control.identity.return_value = dict(pid=42, birth=123, exe=instance.exe, live=True)
        control.suspend.return_value = control.resume.return_value = 0
        evidence = {}
        with mock.patch('threading.Timer') as timer, self.assertRaisesRegex(AssertionError, 'pause budget'):
            with sessions.PausedProcess(process, instance, evidence, control=control):
                self.assertLessEqual(timer.call_args.args[0], 45)
                timer.call_args.args[1]()  # Fire without waiting on wall-clock time.
        control.resume.assert_called_once_with(77)
        self.assertTrue(evidence['timed_out'])
        self.assertEqual(0, evidence['resume_status'])
        control.terminate.assert_not_called()

    def test_pause_setup_and_resume_failures_are_not_reported_as_restored(self):
        for label in ('timer start', 'resume', 'suspend', 'post-resume identity'):
            with self.subTest(label=label), mock.patch('threading.Timer') as timer:
                process = SimpleNamespace(pid=42, _handle=77, terminate=mock.Mock(), wait=mock.Mock(return_value=1))
                instance = SimpleNamespace(pid=42, creation=123, exe='C:/fixture.exe')
                control, evidence = mock.Mock(), {}
                identity = dict(pid=42, birth=123, exe=instance.exe, live=True)
                control.identity.return_value = identity
                control.suspend.return_value = control.resume.return_value = 0
                if label == 'timer start':
                    timer.return_value.start.side_effect = RuntimeError('cannot start watchdog')
                elif label == 'resume':
                    control.resume.return_value = -1
                elif label == 'suspend':
                    control.suspend.return_value = -1
                else:
                    control.identity.side_effect = [identity, {**identity, 'birth': 999}]
                with self.assertRaises((AssertionError, RuntimeError)):
                    with sessions.PausedProcess(process, instance, evidence, control=control):
                        pass
                if label == 'suspend':
                    control.resume.assert_not_called()
                else:
                    control.resume.assert_called_once_with(77)
                self.assertEqual(label == 'timer start', bool(evidence.get('resume_verified')))

    def test_suspend_effect_before_exception_or_evidence_failure_still_resumes_once(self):
        class FailingEvidence(dict):
            def __setitem__(self, key, value):
                if key == 'suspend_status':
                    raise RuntimeError('cannot record suspend status')
                super().__setitem__(key, value)

        for label in ('unknown suspend result', 'suspend evidence'):
            with self.subTest(label=label), mock.patch('threading.Timer'):
                process = SimpleNamespace(pid=42, _handle=77)
                instance = SimpleNamespace(pid=42, creation=123, exe='C:/fixture.exe')
                control, active = mock.Mock(), [False]
                evidence = FailingEvidence() if label == 'suspend evidence' else {}
                control.identity.return_value = dict(pid=42, birth=123, exe=instance.exe, live=True)

                def suspend(handle):
                    self.assertEqual(77, handle)
                    active[0] = True
                    if label == 'unknown suspend result':
                        raise KeyboardInterrupt('suspend took effect before ctypes returned')
                    return 0

                def resume(handle):
                    self.assertEqual(77, handle)
                    self.assertTrue(active[0])
                    active[0] = False
                    return 0

                control.suspend.side_effect, control.resume.side_effect = suspend, resume
                with self.assertRaises((KeyboardInterrupt, RuntimeError)):
                    with sessions.PausedProcess(process, instance, evidence, control=control):
                        self.fail('failed suspension entry must not reach the body')
                self.assertFalse(active[0])
                control.resume.assert_called_once_with(77)
                self.assertEqual('unknown' if label == 'unknown suspend result' else 'success',
                                 evidence['suspend_outcome'])
                self.assertTrue(evidence['resume_verified'])

    def test_resume_effect_before_exception_or_evidence_failure_is_never_retried(self):
        class FailingEvidence(dict):
            def __setitem__(self, key, value):
                if key == 'resume_status':
                    raise RuntimeError('cannot record resume status')
                super().__setitem__(key, value)

        for label in ('unknown resume result', 'resume evidence'):
            with self.subTest(label=label), mock.patch('threading.Timer') as timer:
                process = SimpleNamespace(pid=42, _handle=77, terminate=mock.Mock(), wait=mock.Mock(return_value=1))
                instance = SimpleNamespace(pid=42, creation=123, exe='C:/fixture.exe')
                control, active = mock.Mock(), [False]
                evidence = FailingEvidence() if label == 'resume evidence' else {}
                control.identity.return_value = dict(pid=42, birth=123, exe=instance.exe, live=True)

                def suspend(handle):
                    active[0] = True
                    return 0

                def resume(handle):
                    self.assertEqual(77, handle)
                    self.assertTrue(active[0], 'duplicate resume would decrement another suspend count')
                    active[0] = False
                    if label == 'unknown resume result':
                        raise KeyboardInterrupt('resume took effect before ctypes returned')
                    return 0

                control.suspend.side_effect, control.resume.side_effect = suspend, resume
                paused = sessions.PausedProcess(process, instance, evidence, control=control)
                with self.assertRaises((KeyboardInterrupt, RuntimeError)):
                    with paused:
                        pass
                timer.call_args.args[1]()  # A racing watchdog cannot retry an ambiguous/completed resume.
                self.assertFalse(active[0])
                control.resume.assert_called_once_with(77)
                self.assertEqual('unknown' if label == 'unknown resume result' else 'success',
                                 evidence['resume_outcome'])
                self.assertFalse(evidence['resume_verified'])
                if label == 'unknown resume result':
                    process.terminate.assert_called_once_with()
                    process.wait.assert_called_once_with(timeout=5)
                else:
                    process.terminate.assert_not_called()

    def test_watchdog_evidence_failure_does_not_prevent_its_resume(self):
        class FailingEvidence(dict):
            def __setitem__(self, key, value):
                if key == 'timed_out':
                    raise RuntimeError('cannot record timeout')
                super().__setitem__(key, value)

        process = SimpleNamespace(pid=42, _handle=77)
        instance = SimpleNamespace(pid=42, creation=123, exe='C:/fixture.exe')
        control, evidence = mock.Mock(), FailingEvidence()
        control.identity.return_value = dict(pid=42, birth=123, exe=instance.exe, live=True)
        control.suspend.return_value = control.resume.return_value = 0
        with mock.patch('threading.Timer') as timer:
            paused = sessions.PausedProcess(process, instance, evidence, control=control)
            paused.__enter__()
            try:
                # Check outside assertRaises so cleanup cannot mask a callback
                # that failed to recover the process itself.
                try:
                    timer.call_args.args[1]()
                except RuntimeError:
                    pass
                control.resume.assert_called_once_with(77)
            finally:
                with self.assertRaises((AssertionError, RuntimeError)):
                    paused.__exit__(None, None, None)


class FailedRestoreCleanupTests(unittest.TestCase):
    def setup_pause(self, *, resume='before-effect', terminate_error=False, wait_error=False):
        state = dict(paused=False, live=True)
        events, evidence = [], {}
        process = SimpleNamespace(pid=42, _handle=77, returncode=None)
        instance = SimpleNamespace(pid=42, creation=123, exe='C:/fixture.exe',
                                   alive=mock.Mock(side_effect=AssertionError('no PID/GUI fallback')),
                                   close=mock.Mock(side_effect=AssertionError('no GUI close')))
        control = mock.Mock()
        identity = dict(pid=42, birth=123, exe=instance.exe, live=True)
        control.identity.return_value = identity

        def suspend(handle):
            self.assertEqual(77, handle)
            events.append('suspend')
            state['paused'] = True
            return 0

        def resume_process(handle):
            self.assertEqual(77, handle)
            events.append('resume')
            if resume == 'before-effect':
                raise KeyboardInterrupt('resume did NOT take effect')
            if resume == 'negative':
                return -1
            state['paused'] = False
            if resume == 'after-effect':
                raise KeyboardInterrupt('resume result unknown after effect')
            return 0

        def terminate():
            self.assertEqual(77, process._handle)
            events.append('terminate')
            if terminate_error:
                raise OSError('TerminateProcess failed')

        def confirm_exit(timeout):
            self.assertEqual(5, timeout)
            self.assertEqual(77, process._handle)
            events.append('wait')
            if wait_error:
                raise sessions.subprocess.TimeoutExpired('owned first handle', timeout)
            state.update(live=False, paused=False)
            process.returncode = 1
            return 1

        process.terminate = mock.Mock(side_effect=terminate)
        process.wait = mock.Mock(side_effect=confirm_exit)
        process.poll = mock.Mock(side_effect=lambda: process.returncode)
        control.suspend.side_effect, control.resume.side_effect = suspend, resume_process
        if resume == 'verification':
            control.identity.side_effect = [identity, {**identity, 'birth': 999}]
        paused = sessions.PausedProcess(process, instance, evidence, control=control)
        return paused, process, instance, control, evidence, state, events

    def test_unknown_and_failed_resume_terminate_and_confirm_only_the_original_process(self):
        for mode in ('before-effect', 'after-effect', 'negative', 'verification'):
            with self.subTest(mode=mode), mock.patch('threading.Timer') as timer:
                paused, process, instance, control, evidence, state, events = self.setup_pause(resume=mode)
                with self.assertRaises((KeyboardInterrupt, AssertionError)):
                    with paused:
                        pass
                self.assertEqual(['suspend', 'resume', 'terminate', 'wait'], events)
                self.assertFalse(state['live'])
                self.assertFalse(state['paused'])
                self.assertEqual('EXIT_CONFIRMED', evidence['failure_cleanup']['status'])
                self.assertEqual(1, evidence['failure_cleanup']['exit_code'])
                self.assertIs(False, evidence['failure_cleanup']['normal_quit'])
                self.assertFalse(evidence['resume_verified'])
                timer.call_args.args[1]()
                control.resume.assert_called_once_with(77)
                process.terminate.assert_called_once_with()
                process.wait.assert_called_once_with(timeout=5)
                instance.alive.assert_not_called()
                instance.close.assert_not_called()

    def test_termination_errors_still_wait_and_only_observed_exit_confirms_cleanup(self):
        for terminate_error, wait_error in ((True, True), (False, True), (True, False)):
            with self.subTest(terminate_error=terminate_error, wait_error=wait_error), mock.patch('threading.Timer'):
                paused, process, instance, control, evidence, state, _ = self.setup_pause(
                    terminate_error=terminate_error, wait_error=wait_error)
                with self.assertRaises((KeyboardInterrupt, AssertionError, sessions.subprocess.TimeoutExpired)):
                    with paused:
                        pass
                process.terminate.assert_called_once_with()
                process.wait.assert_called_once_with(timeout=5)
                control.resume.assert_called_once_with(77)
                cleanup = evidence['failure_cleanup']
                self.assertEqual('EXIT_UNCONFIRMED' if wait_error else 'EXIT_CONFIRMED', cleanup['status'])
                self.assertEqual(wait_error, state['live'])
                self.assertFalse(cleanup['normal_quit'])
                if terminate_error:
                    self.assertIn('TerminateProcess failed', cleanup['attempts'][0]['terminate_error'])
                if wait_error:
                    self.assertIsNone(cleanup['exit_code'])
                    self.assertIn('wait_error', cleanup['attempts'][0])
                instance.alive.assert_not_called()
                instance.close.assert_not_called()

    def test_runner_preserves_failure_and_never_falls_back_to_suspended_gui_cleanup(self):
        for wait_error in (False, True):
            with self.subTest(wait_error=wait_error), tempfile.TemporaryDirectory() as folder, mock.patch('threading.Timer'):
                root = Path(folder)
                exe = root / 'fixture.exe'; exe.write_bytes(b'fixture')
                fixture = sessions.Fixture(exe, root / 'out', 'unit')
                paused, process, instance, control, evidence, _, _ = self.setup_pause(wait_error=wait_error)
                # Set this explicitly so the old runner's unsafe GUI fallback
                # is exercised by RED, rather than failing on a missing field.
                fixture.pause_guards = {}

                def fail_restore():
                    fixture.owned.append(instance)
                    fixture.processes[instance.pid] = process
                    fixture.pause_guards[instance.pid] = paused
                    fixture.report['dual_writer'] = {'pause': evidence}
                    with paused:
                        pass

                with mock.patch.object(fixture, 'dual_writer', side_effect=fail_restore), \
                        mock.patch.object(sessions, 'fixture_slots', return_value=nullcontext()), redirect_stdout(io.StringIO()):
                    if wait_error:
                        self.assertEqual(1, fixture.run(['dual_writer']))
                    else:
                        with self.assertRaises(KeyboardInterrupt):
                            fixture.run(['dual_writer'])
                instance.alive.assert_not_called()
                instance.close.assert_not_called()
                control.resume.assert_called_once_with(77)
                report = json.loads((fixture.out / 'report.json').read_text(encoding='utf-8'))
                self.assertTrue(report['cases'])
                self.assertTrue(all(row['status'] == 'FAIL' for row in report['cases']))
                self.assertFalse(report['dual_writer']['pause']['failure_cleanup']['normal_quit'])


if __name__ == "__main__":
    unittest.main()
