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
