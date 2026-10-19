"""Safety bounds and hard-timeout reporting of the owned-window UIA probe."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_win_uia as probe


class UiaProbeTests(unittest.TestCase):
    def test_notifications_use_sdk_class_that_exposes_iuiautomation5(self):
        self.assertEqual('e22ad333-b25f-460c-83d0-0581107395c9', probe.automation_clsid(1000))
        self.assertEqual('ff48dba4-60ef-4201-aa87-54103eef594e', probe.automation_clsid(0))

    def test_failure_freezes_stage_hresult_and_accumulated_actions(self):
        diagnostic = {'stage': 'action.invoke', 'node_id': 'gx-2', 'pattern_id': 10002,
                      'call': 'SetValue', 'hresult': '0x80040201', 'action_results': [{'call': 'Expand', 'hresult': '0x00000000'}]}
        failure = probe.ProbeFailure('COM failure 0x80040201', diagnostic)
        diagnostic['stage'] = 'cleanup'
        diagnostic['action_results'].clear()
        with mock.patch.object(probe, 'run_worker', side_effect=failure):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(1, probe.main(self.args('--worker')))
        result = json.loads(output.getvalue())
        self.assertEqual('action.invoke', result['stage'])
        self.assertEqual('SetValue', result['call'])
        self.assertEqual('gx-2', result['node_id'])
        self.assertEqual(10002, result['pattern_id'])
        self.assertEqual('0x80040201', result['hresult'])
        self.assertEqual(1, len(result['action_results']))

    def test_failure_report_keeps_the_events_seen_before_it(self):
        # A missing FocusChanged must be told apart from one of another
        # element or process (UIA-05): the failure carries what was seen.
        focus = [{'pid': 42, 'automation_id': 'gx-terminal-5', 'after_ready': True}]
        seen = probe.observed_events(focus, {'foreign': 3, 'callback_errors': 0}, [], {'foreign': 0, 'callback_errors': 1})
        focus.append({'pid': 42, 'automation_id': 'later'})
        self.assertEqual(['gx-terminal-5'], [event['automation_id'] for event in seen['focus_events']])
        self.assertEqual((3, 0, [], 0, 1), (seen['foreign_focus_events'], seen['focus_callback_errors'], seen['selection_events'],
                                            seen['foreign_selection_events'], seen['selection_callback_errors']))
        failure = probe.ProbeFailure('focus expectations not met within 3 s', {'stage': 'action.focus', 'action_results': []})
        failure.diagnostic.update(seen)
        with mock.patch.object(probe, 'run_worker', side_effect=failure):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(1, probe.main(self.args('--worker')))
        result = json.loads(output.getvalue())
        self.assertEqual(('action.focus', 'gx-terminal-5', 3),
                         (result['stage'], result['focus_events'][0]['automation_id'], result['foreign_focus_events']))
        # Both failure paths of the worker attach them.
        source = Path(probe.__file__).read_text(encoding='utf-8')
        self.assertIn('error.diagnostic.update(seen)', source)
        self.assertIn('diagnostic.update(seen)\n        raise ProbeFailure(str(error), diagnostic) from error', source)

    def test_parent_keeps_failed_worker_diagnostic_without_retry(self):
        payload = {'status': 'FAIL', 'error': 'COM failure 0x80040201', 'stage': 'action.pattern',
                   'node_id': 'gx-2', 'pattern_id': 10002, 'call': 'IUIAutomationElement.GetCurrentPattern',
                   'hresult': '0x80040201', 'action_results': []}
        result = subprocess.CompletedProcess(['worker'], 1, json.dumps(payload), '')
        with mock.patch.object(probe.subprocess, 'run', return_value=result) as run:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(1, probe.main(self.args()))
            self.assertEqual(1, run.call_count)
        observed = json.loads(output.getvalue())
        self.assertEqual(payload['stage'], observed['stage'])
        self.assertEqual(payload['hresult'], observed['hresult'])
        self.assertEqual(1, observed['worker_exit_code'])

    def args(self, *extra):
        return ['--hwnd', '0x123', '--pid', '42', '--birth', '12345', '--exe', 'ghostty.exe', *extra]

    def test_identity_and_limits_are_required(self):
        probe.validate_args(probe.parser().parse_args(self.args()))
        for extra in [('--hwnd', '0'), ('--birth', '0'), ('--max-depth', '17'),
                      ('--max-nodes', '513'), ('--timeout', '0'), ('--expect-notification',),
                      ('--timeout', '2', '--listen-ms', '2000')]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                probe.validate_args(probe.parser().parse_args(self.args(*extra)))

    def test_timeout_reports_fail_and_never_retries_or_scans_desktop(self):
        with mock.patch.object(probe.subprocess, 'run', side_effect=subprocess.TimeoutExpired('worker', 15)) as run:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(1, probe.main(self.args()))
            self.assertEqual('FAIL', json.loads(output.getvalue())['status'])
            self.assertEqual(1, run.call_count)
            command = run.call_args.args[0]
            self.assertIn('--worker', command)
            self.assertIn('--hwnd', command)
            self.assertIn('--birth', command)
            self.assertEqual(15, run.call_args.kwargs['timeout'])

    def test_actions_require_hash_and_bounded_exact_targets(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'actions.json'
            good = {'name': 'Search', 'pattern': 'value', 'operation': 'set', 'value': '中文 🧪'}
            path.write_text(json.dumps([good]), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'SHA-256'):
                probe.validate_args(probe.parser().parse_args(self.args('--action-plan', str(path))))
            probe.validate_args(probe.parser().parse_args(self.args('--action-plan', str(path), '--sha256', 'a' * 64)))
            for bad in ({**good, 'value': 'x' * 4097}, {**good, 'operation': 'delete'},
                        {**good, 'expect_unavailable': True}, {'pattern': 'invoke', 'operation': 'invoke'}):
                path.write_text(json.dumps([bad]), encoding='utf-8')
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    probe.read_plan(path)
            path.write_bytes(b' ' * 65537)
            with self.assertRaisesRegex(ValueError, '64 KiB'):
                probe.read_plan(path)

    def test_transition_signal_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as folder:
            ready, proceed = Path(folder) / 'ready', Path(folder) / 'continue'
            args = self.args('--ready-file', str(ready), '--continue-file', str(proceed))
            probe.validate_args(probe.parser().parse_args(args))
            proceed.touch()
            with self.assertRaises(ValueError):
                probe.validate_args(probe.parser().parse_args(args))

    def test_event_observation_needs_a_bounded_window_after_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            ready, proceed = Path(folder) / 'ready', Path(folder) / 'continue'
            window = ('--ready-file', str(ready), '--continue-file', str(proceed), '--listen-ms', '5000')
            for flag in ('--observe-focus', '--observe-selection'):
                with self.subTest(flag=flag):
                    probe.validate_args(probe.parser().parse_args(self.args(flag, *window)))
                    for missing in (window[:2], window[2:]):
                        with self.assertRaises(ValueError):
                            probe.validate_args(probe.parser().parse_args(self.args(flag, *missing)))

    def test_selection_events_use_the_sdk_event_scope_and_slots(self):
        # UIA_SelectionItem_ElementSelectedEventId, TreeScope_Subtree; IUIAutomationVtbl
        # slots 32/33 are AddAutomationEventHandler/RemoveAutomationEventHandler.
        self.assertEqual((20012, 7), (probe.ELEMENT_SELECTED_EVENT, probe.TREE_SCOPE_SUBTREE))
        source = Path(probe.__file__).read_text(encoding='utf-8')
        self.assertIn('method(automation, 32, HRESULT, C.c_int, pointer, C.c_int, pointer, pointer)', source)
        self.assertIn('method(automation, 33, HRESULT, C.c_int, pointer, pointer)', source)

    def test_controller_for_reads_the_client_element_array(self):
        # UIA-06 N3: a client's GetCurrentPropertyValue(ControllerFor) hands back
        # an IUIAutomationElementArray (VT_UNKNOWN), not the provider's SAFEARRAY;
        # both are read (get_Length/GetElement are slots 3/4), and the VARIANT type
        # is reported so an empty list is never ambiguous.
        source = Path(probe.__file__).read_text(encoding='utf-8')
        for needle in ('14314595-b4bc-4055-95f2-58f2e42c9855', 'method(array, 3, HRESULT, C.POINTER(C.c_int))',
                       'method(array, 4, HRESULT, C.c_int, C.POINTER(pointer))', '"controller_for_vt"'):
            self.assertTrue(needle in source, f'gx_win_uia.py lacks {needle}')

    def test_all_required_patterns_have_client_operations(self):
        self.assertEqual({'invoke', 'selection_item', 'value', 'toggle', 'expand_collapse'}, set(probe.PATTERNS))
        self.assertEqual((10005, {'expand': 3, 'collapse': 4}), probe.PATTERNS['expand_collapse'])

    def test_windowless_client_requires_physical_coordinate_context(self):
        import ctypes
        user = mock.Mock()
        user.SetThreadDpiAwarenessContext.return_value = 1
        probe.physical_coordinates(user)
        self.assertEqual((-4) % (1 << (ctypes.sizeof(ctypes.c_void_p) * 8)), user.SetThreadDpiAwarenessContext.call_args.args[0].value)
        user.SetThreadDpiAwarenessContext.return_value = 0
        with self.assertRaisesRegex(RuntimeError, 'coordinates'):
            probe.physical_coordinates(user)


class ReadyHandshakeTests(unittest.TestCase):
    """Review round 4: the controller acts as soon as the ready file exists,
    so the events of its actions must already count as after-ready and the
    file must appear whole."""

    def test_events_count_as_after_ready_before_the_whole_file_appears(self):
        with tempfile.TemporaryDirectory() as folder:
            ready = Path(folder) / 'worker.ready.json'
            marker = [False]
            seen = []
            real_replace = probe.os.replace

            def replace(source, target):
                # The moment a controller polling for the file can see it.
                seen.append((marker[0], json.loads(Path(source).read_text(encoding='utf-8')), Path(target).exists()))
                real_replace(source, target)

            payload = {'registered': False, 'focus_registered': True, 'selection_registered': True}
            with mock.patch.object(probe.os, 'replace', side_effect=replace):
                probe.publish_ready(ready, payload, marker)
            self.assertEqual([(True, payload, False)], seen)
            self.assertEqual(payload, json.loads(ready.read_text(encoding='utf-8')))
            self.assertEqual(['worker.ready.json'], [path.name for path in Path(folder).iterdir()])

    def test_a_failed_publication_leaves_no_partial_ready_file(self):
        with tempfile.TemporaryDirectory() as folder:
            ready = Path(folder) / 'worker.ready.json'
            with mock.patch.object(probe.os, 'replace', side_effect=OSError('denied')):
                with self.assertRaises(OSError):
                    probe.publish_ready(ready, {'registered': True}, [False])
            self.assertEqual([], list(Path(folder).iterdir()))


class StaleActionTests(unittest.TestCase):
    """round3-batch-20261018-112356 UIA-02: GetCurrentPattern on a hidden
    palette's retained element answered S_OK with no pattern, so the expected
    UIA_E_ELEMENTNOTAVAILABLE never surfaced at that call."""
    UNAVAILABLE = 0x80040201 - (1 << 32)

    def test_an_error_from_get_current_pattern_decides_without_a_followup(self):
        followup = mock.Mock()
        self.assertEqual(self.UNAVAILABLE, probe.stale_action_hresult(self.UNAVAILABLE, False, followup))
        followup.assert_not_called()

    def test_a_returned_pattern_goes_on_to_the_action_call(self):
        followup = mock.Mock()
        self.assertIsNone(probe.stale_action_hresult(0, True, followup))
        followup.assert_not_called()

    def test_no_pattern_with_s_ok_is_decided_by_the_providers_own_property_answer(self):
        followup = mock.Mock(return_value=self.UNAVAILABLE)
        self.assertEqual(self.UNAVAILABLE, probe.stale_action_hresult(0, False, followup))
        followup.assert_called_once_with()

    def test_a_stale_element_that_still_answers_is_not_inert(self):
        self.assertEqual(0, probe.stale_action_hresult(0, False, mock.Mock(return_value=0)))


class FocusPlanTests(unittest.TestCase):
    """UIA-01 after the dynamic focus fix: a client moves the focus with
    IUIAutomationElement.SetFocus, then reads HasKeyboardFocus on elements it
    already holds, GetFocusedElement and its FocusChanged events."""

    def plan(self, rows):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'plan.json'
            path.write_text(json.dumps(rows), encoding='utf-8')
            return probe.read_plan(path)

    def test_element_focus_actions_and_their_expectations_are_accepted(self):
        rows = [{'automation_id': 'gx-4', 'pattern': 'element', 'operation': 'check_focus', 'expect_focus': True},
                {'automation_id': 'gx-3', 'pattern': 'element', 'operation': 'set_focus', 'expect_focus': True,
                 'expect_focused_element': True, 'expect_focus_event': True},
                {'automation_id': 'gx-4', 'pattern': 'element', 'operation': 'check_focus', 'expect_focus': False},
                {'automation_id': 'gx-3', 'pattern': 'toggle', 'operation': 'toggle'}]
        self.assertEqual(rows, self.plan(rows))

    def test_focus_expectations_must_be_checkable(self):
        for row in ({'name': 'OK', 'pattern': 'element', 'operation': 'check_focus'},
                    {'name': 'OK', 'pattern': 'element', 'operation': 'set_focus', 'expect_focus': 'yes'},
                    {'name': 'OK', 'pattern': 'element', 'operation': 'set_focus', 'expect_focus_event': False},
                    {'name': 'OK', 'pattern': 'element', 'operation': 'check_focus', 'expect_focus': True,
                     'after_signal': True, 'expect_unavailable': True},
                    {'name': 'OK', 'pattern': 'element', 'operation': 'invoke'},
                    {'name': 'OK', 'pattern': 'toggle', 'operation': 'toggle', 'expect_focus': True,
                     'after_signal': True, 'expect_unavailable': True}):
            with self.subTest(row=row), self.assertRaises(ValueError):
                self.plan([row])

    def test_expectations_hold_only_when_every_requested_fact_matches(self):
        action = {'expect_focus': False, 'expect_focused_element': True, 'expect_focus_event': True}
        facts = {'has_keyboard_focus': False, 'focused_element_same': True, 'focus_event': True}
        self.assertTrue(probe.focus_expectations_hold(action, facts))
        for fact in facts:
            changed = dict(facts, **{fact: not facts[fact]})
            with self.subTest(fact=fact):
                self.assertFalse(probe.focus_expectations_hold(action, changed))
        self.assertTrue(probe.focus_expectations_hold({'pattern': 'toggle'}, {}))

    def test_set_focus_is_the_element_vtable_slot_from_the_sdk(self):
        # uiautomationclient.h IUIAutomationElementVtbl: QueryInterface, AddRef, Release, SetFocus.
        self.assertEqual({'set_focus': 3, 'check_focus': None}, probe.ELEMENT_OPERATIONS)

    def test_only_a_later_event_from_the_target_process_and_element_counts(self):
        events = [{'pid': 42, 'automation_id': 'gx-3'}, {'pid': 42, 'automation_id': 'gx-4'}]
        self.assertTrue(probe.focus_event_seen(events, 1, 42, 'gx-4'))
        self.assertFalse(probe.focus_event_seen(events, 1, 42, 'gx-3'))
        self.assertFalse(probe.focus_event_seen(events, 0, 7, 'gx-3'))



class RetainedPatternTests(unittest.TestCase):
    def setUp(self):
        import ctypes as C
        self.C = C
        self.events = []
        self.thread = 71
        self.lookup_hr, self.output = 0, 101
        self.method_hr = StaleActionTests.UNAVAILABLE
        self.diagnostic = {}
        self.action = {'name': 'Search', 'pattern': 'value', 'operation': 'set',
                       'value': 'marker', 'after_signal': True, 'retain_pattern': True,
                       'expect_unavailable': True}
        self.bstr = BstrMemory()
        self.pool = probe.RetainedPatterns(self.method, self.release, lambda: self.thread,
                                          self.stage, self.diagnostic, self.bstr)

    def stage(self, name, call, **facts):
        self.diagnostic.update(stage=name, call=call, **facts)

    def release(self, obj):
        self.events.append(('release', obj.value, self.thread))

    def method(self, obj, slot, result, *types):
        def call(this, *args):
            if slot == 14:
                self.assertEqual(probe.PATTERN_IIDS[self.action["pattern"]], str(__import__("uuid").UUID(bytes_le=bytes(args[1]._obj))))
                self.events.append(('lookup', this.value, args[0], self.thread))
                self.C.cast(args[2], self.C.POINTER(self.C.c_void_p))[0] = self.output
                return self.lookup_hr
            if self.action['pattern'] == 'value':
                self.assertEqual((self.C.c_void_p,), types)
                args = (self.bstr.read(args[0]),)
            self.events.append(('method', this.value, slot, args, self.thread))
            return self.method_hr
        return call

    def acquire(self, index=0):
        self.pool.acquire(index, self.action, self.C.c_void_p(11), 'gx-search')

    def test_acquire_before_ready_method_after_signal_and_release_once(self):
        try:
            self.acquire()
            self.events.append(('ready',))
            self.events.append(('signal',))
            result = self.pool.invoke(0, self.action)
            self.assertEqual('0x80040201', result['hresult'])
            self.assertEqual('retained_pattern_method', result['decided_by'])
            self.assertEqual('SetValue', result['call'])
            self.assertEqual(71, result['thread'])
        finally:
            self.pool.close()
        self.pool.close()
        self.assertEqual(['lookup', 'ready', 'signal', 'method', 'release'], [e[0] for e in self.events])
        self.assertEqual(('method', 101, 3, ('marker',), 71), self.events[3])
        self.assertEqual((1, 1), (self.pool.audit['acquired'], self.pool.audit['released']))
        self.assertEqual('before_ready', self.pool.audit['interfaces'][0]['acquired_at'])
        self.assertEqual(71, self.pool.audit['interfaces'][0]['release_thread'])

    def test_null_or_failed_lookup_never_calls_method_even_if_unavailable(self):
        for hr, output in ((0, None), (self.method_hr, None), (self.method_hr, 101)):
            with self.subTest(hr=hr, output=output):
                self.setUp()
                self.lookup_hr, self.output = hr, output
                try:
                    with self.assertRaises(probe.ProbeFailure):
                        self.acquire()
                finally:
                    self.pool.close()
                self.assertFalse(any(e[0] == 'method' for e in self.events))
                self.assertEqual(int(bool(output)), sum(e[0] == 'release' for e in self.events))

    def test_partial_acquisition_and_timeout_release_every_reference_once(self):
        for failure in ('lookup', 'timeout', 'method'):
            with self.subTest(failure=failure):
                self.setUp()
                try:
                    self.acquire()
                    if failure == 'lookup':
                        self.lookup_hr = self.method_hr
                        with self.assertRaises(probe.ProbeFailure):
                            self.acquire(1)
                    elif failure == 'method':
                        self.method_hr = -2147467259
                        with self.assertRaises(probe.ProbeFailure):
                            self.pool.invoke(0, self.action)
                    else:
                        with self.assertRaises(TimeoutError):
                            raise TimeoutError('controller transition signal timed out')
                finally:
                    self.pool.close()
                expected = 2 if failure == 'lookup' else 1
                self.assertEqual(expected, sum(e[0] == 'release' for e in self.events))
                self.assertTrue(all(e[-1] == 71 for e in self.events))

    def test_only_exact_unavailable_method_hresult_passes(self):
        for hr in (0, 1, -2147467259):
            with self.subTest(hr=hr):
                self.setUp()
                try:
                    self.acquire()
                    self.method_hr = hr
                    with self.assertRaises(probe.ProbeFailure):
                        self.pool.invoke(0, self.action)
                finally:
                    self.pool.close()

    def test_client_iids_match_the_sdk_not_provider_iids(self):
        self.assertEqual({
            'invoke': 'fb377fbe-8ea6-46d5-9c73-6499642d3059',
            'value': 'a94cd8b1-0844-4cd6-9d2d-640537ab39e9',
            'selection_item': 'a8efa66a-0fda-421a-9194-38021f3578ea',
            'toggle': '94cf8058-9b8d-4ab9-8bfd-4cd0a33c8c70',
            'expand_collapse': '619be086-1f4e-4ee4-bafa-210128738730'}, probe.PATTERN_IIDS)

    def test_all_patterns_use_existing_method_slots(self):
        for pattern, (_, operations) in probe.PATTERNS.items():
            for operation, slot in operations.items():
                with self.subTest(pattern=pattern, operation=operation):
                    self.setUp()
                    self.action.update(pattern=pattern, operation=operation)
                    try:
                        self.acquire()
                        self.pool.invoke(0, self.action)
                        self.assertEqual(slot, self.events[-1][2])
                    finally:
                        self.pool.close()

    def test_close_continues_after_release_exception(self):
        self.pool.refs = {0: (self.C.c_void_p(101), {}), 1: (self.C.c_void_p(102), {})}
        calls = []
        def release(obj):
            calls.append(obj.value)
            if obj.value == 102:
                raise OSError('first Release failed')
        self.pool.release = release
        try:
            self.pool.close()
        except BaseException:
            pass  # Check attempts, not just the first exception.
        self.assertEqual([102, 101], calls)
        self.assertEqual(1, self.pool.audit['released'])
        self.pool.close()
        self.assertEqual([102, 101], calls)

    def test_other_thread_cannot_call_or_release(self):
        self.acquire()
        self.thread = 72
        with self.assertRaises(RuntimeError):
            self.pool.invoke(0, self.action)
        with self.assertRaises(RuntimeError):
            self.pool.close()
        self.thread = 71
        self.pool.close()
        self.assertEqual(['lookup', 'release'], [e[0] for e in self.events])


class RetainPlanTests(unittest.TestCase):
    plan = FocusPlanTests.plan

    def test_opt_in_validation_and_legacy_default(self):
        base = {'name': 'OK', 'pattern': 'invoke', 'operation': 'invoke', 'after_signal': True}
        for value in (True, False):
            row = dict(base, retain_pattern=value)
            self.assertEqual([row], self.plan([row]))
        self.assertEqual([base], self.plan([base]))
        for changes in ({'retain_pattern': 1}, {'retain_pattern': 'true'}, {'retain_pattern': None},
                        {'retain_pattern': True, 'after_signal': False},
                        {'retain_pattern': True, 'after_signal': 1},
                        {'retain_pattern': False, 'after_signal': False},
                        {'retain_pattern': True, 'pattern': 'element', 'operation': 'set_focus'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.plan([dict(base, **changes)])



class BstrMemory:
    """A real length-prefixed UTF-16 layout, kept alive until the mock free."""
    def __init__(self):
        self.buffers = {}
        self.allocated, self.freed = [], []
        self.null = False
        self.free_error = None
        self.SysAllocStringLen = mock.Mock(side_effect=self.allocate)
        self.SysFreeString = mock.Mock(side_effect=self.free)

    def allocate(self, source, units):
        import ctypes as C
        if self.null:
            return None
        raw = C.string_at(source, units * 2)
        buffer = C.create_string_buffer((units * 2).to_bytes(4, 'little') + raw + b'\0\0')
        address = C.addressof(buffer) + 4
        self.buffers[address] = buffer
        self.allocated.append((address, units, raw))
        return address

    def read(self, address):
        import ctypes as C
        if not isinstance(address, int) or address not in self.buffers:
            raise AssertionError('SetValue did not receive an allocated BSTR')
        size = int.from_bytes(C.string_at(address - 4, 4), 'little')
        return C.string_at(address, size).decode('utf-16-le', errors='surrogatepass')

    def free(self, address):
        self.freed.append(address)
        del self.buffers[address]  # A double free fails immediately.
        if self.free_error:
            raise self.free_error


class WorkerRetainedIntegrationTests(unittest.TestCase):
    """Run the real worker, including its wait/finally, against mock COM vtables.
    Native identity APIs are emulated; no DLL or desktop access is performed.
    """
    def run_worker(self, *, retain=True, failure=None, count=1, immediate=False, release_failure=None, observe=False, cleanup_failure=None, value="marker"):
        import ctypes as C
        from types import SimpleNamespace
        events, anchors, refs = [], [], {}
        callbacks = {}
        thread = 71
        signaled = False
        lookups = 0
        release_attempts = {}
        bstr = BstrMemory()
        bstr.null = failure == "bstr_alloc"
        if cleanup_failure == "bstr_free":
            bstr.free_error = OSError("mock SysFreeString failure")

        def object_(name):
            table = (C.c_void_p * 70)()
            for slot in range(70):
                token = len(callbacks) + 1
                callbacks[token] = (name, slot)
                table[slot] = token
            obj = C.pointer(C.cast(table, C.POINTER(C.c_void_p)))
            anchors.extend((table, obj))
            refs[name] = 0
            return C.cast(obj, C.c_void_p).value

        objects = {name: object_(name) for name in ('automation', 'automation5', 'root', 'walker', 'unknown', 'pattern')}
        strings = {30024: 'GhosttyGX', 30005: 'Search', 30011: 'gx-search'}
        buffers = {key: C.create_unicode_buffer(value) for key, value in strings.items()}
        anchors.extend(buffers.values())

        def output(out, name):
            out._obj.value = objects[name]
            refs[name] += 1

        def dispatch(token):
            name, slot = callbacks[token]
            def call(this, *args):
                nonlocal lookups
                events.append((name, slot, signaled, thread))
                if slot == 1:
                    refs[name] += 1
                    return refs[name]
                if slot == 2:
                    release_attempts[name] = release_attempts.get(name, 0) + 1
                    if name == 'pattern' and release_attempts[name] == 1 and release_failure:
                        raise release_failure
                    if name == 'walker' and cleanup_failure == 'walker':
                        raise OSError('mock walker Release failure')
                    refs[name] -= 1
                    self.assertGreaterEqual(refs[name], 0)
                    return refs[name]
                if name == 'automation':
                    if slot == 0:
                        if observe:
                            output(args[-1], 'automation5')
                            return 0
                        return -2147467262  # No notification interface; no events requested.
                    if slot in (32, 33, 39, 40):
                        if slot == 33 and cleanup_failure == 'selection':
                            return -2147467259
                        if slot == 40 and cleanup_failure == 'focus':
                            raise OSError('mock focus unsubscription failure')
                        return 0
                    output(args[-1], 'root' if slot == 6 else 'walker')
                    return 0
                if name == 'automation5':
                    if slot == 69 and cleanup_failure == 'notification':
                        raise OSError('mock notification unsubscription failure')
                    return 0
                if name == 'walker':
                    return 0  # No children.
                if name == 'unknown':
                    self.fail('IUnknown vtable used as typed pattern')
                if name == 'pattern':
                    self.assertEqual(value, bstr.read(args[0]))
                    self.assertTrue(signaled or immediate)
                    if failure == 'interrupt':
                        raise KeyboardInterrupt('mock interrupted method')
                    if failure == 'method_exception':
                        raise OSError('mock method failure')
                    return -2147467259 if failure == 'method' else (0 if immediate else StaleActionTests.UNAVAILABLE)
                if slot == 16:
                    output(args[-1], 'unknown')
                    return 0
                if slot == 14:
                    self.assertEqual('a94cd8b1-0844-4cd6-9d2d-640537ab39e9',
                                     str(__import__('uuid').UUID(bytes_le=bytes(args[1]._obj))))
                    lookups += 1
                    if signaled or failure == 'null':
                        return 0
                    output(args[-1], 'pattern')
                    if failure == 'lookup_exception':
                        raise OSError('mock lookup failure after out-pointer write')
                    return StaleActionTests.UNAVAILABLE if failure == 'lookup' and lookups == count else 0
                if slot == 10:
                    if signaled:
                        return StaleActionTests.UNAVAILABLE
                    prop, out = args
                    variant = out._obj
                    if prop in strings:
                        variant.tag = 8
                        variant.data.pointer = C.addressof(buffers[prop])
                    elif prop == 30002:
                        variant.tag, variant.data.integer = 3, 42
                    elif prop in (30010, 30031, 30043):
                        variant.tag, variant.data.integer = 11, 1
                    return 0
                self.fail(f'unexpected COM call {name}:{slot}')
            return call

        dll = mock.Mock()
        dll.SysAllocStringLen = bstr.SysAllocStringLen
        dll.SysFreeString = bstr.SysFreeString
        dll.SetThreadDpiAwarenessContext.return_value = 1
        dll.CoInitializeEx.return_value = 0
        dll.GetCurrentThreadId.return_value = thread
        dll.CoCreateInstance.side_effect = lambda *args: (output(args[-1], 'automation'), 0)[1]
        dll.GetWindowThreadProcessId.side_effect = lambda hwnd, out: (setattr(out._obj, 'value', 42), 1)[1]
        dll.OpenProcess.return_value = 1
        dll.GetProcessTimes.side_effect = lambda handle, creation, *rest: (setattr(creation._obj, 'dwLowDateTime', 123), 1)[1]
        dll.QueryFullProcessImageNameW.side_effect = lambda handle, flags, path, length: (setattr(path, 'value', 'fake.exe'), 1)[1]
        dll.SysStringLen.side_effect = lambda ptr: len(C.wstring_at(ptr))
        if cleanup_failure == 'uninitialize':
            dll.CoUninitialize.side_effect = OSError('mock CoUninitialize failure')
        ready_payload = None
        error = result = None
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            plan = folder / 'plan.json'
            action = {'name': 'Search', 'pattern': 'value', 'operation': 'set', 'value': value,
                      'after_signal': True, 'expect_unavailable': True}
            if immediate:
                action.update(after_signal=False, expect_unavailable=False)
            if retain:
                action['retain_pattern'] = True
            plan.write_text(json.dumps([action] * count), encoding='utf-8')
            args = SimpleNamespace(hwnd=9, pid=42, birth=123, exe='fake.exe', sha256=None,
                framework='GhosttyGX', action_plan=plan, max_nodes=4, max_depth=4,
                listen_ms=1000, ready_file=folder / 'ready.json', continue_file=folder / 'continue',
                query_interval_ms=0, observe_focus=observe, observe_selection=observe, expect_notification=False)
            real_publish = probe.publish_ready
            def publish(path, payload, marker):
                nonlocal ready_payload, signaled
                if failure == 'ready':
                    raise OSError('mock ready publication failure')
                real_publish(path, payload, marker)
                ready_payload = json.loads(path.read_text(encoding='utf-8'))
                events.append(('ready', 0, False, thread))
                if failure != 'timeout':
                    args.continue_file.write_text('transition', encoding='utf-8')
                    signaled = True
                    events.append(('signal', 0, True, thread))
            ticks = iter(range(1000))
            def factory(*types):
                return lambda token: C.CFUNCTYPE(*types)(token) if callable(token) else dispatch(token)
            with mock.patch.object(probe.os, 'name', 'nt'), \
                    mock.patch.object(C, 'WinDLL', return_value=dll, create=True), \
                    mock.patch.object(C, 'WINFUNCTYPE', side_effect=factory, create=True), \
                    mock.patch.object(probe, 'publish_ready', side_effect=publish), \
                    mock.patch.object(probe.time, 'monotonic', side_effect=lambda: next(ticks) * 0.1), \
                    mock.patch.object(probe.time, 'sleep'):
                try:
                    result = probe.run_worker(args)
                except BaseException as caught:
                    error = caught
        expected_refs = dict.fromkeys(refs, 0)
        if release_failure:
            expected_refs['pattern'] = 1  # Release raised: ownership outcome is unknown, never retry.
            self.assertEqual(count, release_attempts.get('pattern'))
        if cleanup_failure == 'walker':
            expected_refs['walker'] = 1
        self.assertEqual(expected_refs, refs, events)
        dll.CoUninitialize.assert_called_once_with()
        self.assertEqual({}, bstr.buffers)
        self.assertEqual([address for address, _, _ in bstr.allocated], bstr.freed)
        for _, units, raw in bstr.allocated:
            self.assertEqual(value.encode('utf-16-le', errors='surrogatepass'), raw)
            self.assertEqual(len(raw) // 2, units)
        return result, error, events, ready_payload

    def test_real_worker_gets_pattern_before_ready_calls_after_signal(self):
        result, error, events, ready = self.run_worker()
        self.assertIsNone(error)
        lookup = next(i for i, e in enumerate(events) if e[:2] == ('root', 14))
        publish = next(i for i, e in enumerate(events) if e[0] == 'ready')
        signal = next(i for i, e in enumerate(events) if e[0] == 'signal')
        call = next(i for i, e in enumerate(events) if e[:2] == ('pattern', 3))
        self.assertLess(lookup, publish)
        self.assertLess(signal, call)
        self.assertFalse(any(e[0] == 'root' and e[1] in (10, 14, 16) and e[2] for e in events))
        self.assertEqual(1, ready['retained_patterns']['acquired'])
        self.assertEqual(1, result['retained_patterns']['released'])
        self.assertEqual('retained_pattern_method', result['actions'][0]['decided_by'])

    def test_real_worker_failure_paths_balance_all_com_references(self):
        for failure, count in (('null', 1), ('lookup', 2), ('lookup_exception', 2), ('ready', 2),
                               ('timeout', 2), ('method', 2), ('method_exception', 2)):
            with self.subTest(failure=failure):
                result, error, events, ready = self.run_worker(failure=failure, count=count)
                self.assertIsNone(result)
                self.assertIsInstance(error, probe.ProbeFailure)
                expected = {'null': 'cannot retain', 'lookup': 'cannot retain',
                            'lookup_exception': 'mock lookup failure', 'ready': 'mock ready publication failure',
                            'timeout': 'controller transition signal timed out',
                            'method': 'stale pattern method did not return', 'method_exception': 'mock method failure'}
                self.assertIn(expected[failure], str(error))
                audit = error.diagnostic['retained_patterns']
                self.assertEqual(audit['acquired'], audit['released'])
                if failure in ('null', 'lookup', 'lookup_exception', 'ready'):
                    self.assertIsNone(ready)
                if failure not in ('method', 'method_exception'):
                    self.assertFalse(any(e[:2] == ('pattern', 3) for e in events))

    def test_set_value_uses_bstr_for_empty_nonbmp_and_embedded_null(self):
        for value in ('', '中文😀', 'before\0after'):
            for immediate in (False, True):
                with self.subTest(value=value, immediate=immediate):
                    result, error, _, _ = self.run_worker(value=value, immediate=immediate, retain=not immediate)
                    self.assertIsNone(error)
                    self.assertEqual('PASS', result['status'])

    def test_bstr_allocation_failure_never_calls_method(self):
        result, error, events, _ = self.run_worker(failure='bstr_alloc')
        self.assertIsNone(result)
        self.assertIsInstance(error, probe.ProbeFailure)
        self.assertIn('SysAllocStringLen', str(error))
        self.assertFalse(error.diagnostic['retained_patterns']['interfaces'][0]['method_called'])
        self.assertFalse(any(e[:2] == ('pattern', 3) for e in events))

    def test_bstr_free_failure_preserves_method_failure(self):
        result, error, _, _ = self.run_worker(failure='method', cleanup_failure='bstr_free')
        self.assertIsNone(result)
        self.assertIn('stale pattern method did not return', str(error))
        self.assertIn('mock SysFreeString failure', error.diagnostic['cleanup_error'])

    def test_immediate_pattern_uses_typed_interface_too(self):
        result, error, events, _ = self.run_worker(retain=False, immediate=True)
        self.assertIsNone(error)
        self.assertEqual('0x00000000', result['actions'][0]['hresult'])
        self.assertFalse(any(e[0] == 'unknown' for e in events))
        self.assertTrue(any(e[:2] == ('root', 14) for e in events))

    def test_release_failure_preserves_primary_and_finishes_every_cleanup(self):
        result, error, events, _ = self.run_worker(failure='method', count=2,
            release_failure=OSError('mock Release failure'), observe=True)
        self.assertIsNone(result)
        self.assertIsInstance(error, probe.ProbeFailure)
        self.assertIn('stale pattern method did not return', str(error))
        self.assertIn('mock Release failure', error.diagnostic['cleanup_error'])
        self.assertEqual(('action.invoke', 'SetValue', '0x80004005'),
                         tuple(error.diagnostic[key] for key in ('stage', 'call', 'hresult')))
        audit = error.diagnostic['retained_patterns']
        self.assertEqual((2, 2, 1), (audit['acquired'], audit['release_attempts'], audit['released']))
        self.assertEqual([True, False], [row['release_succeeded'] for row in audit['interfaces']])
        self.assertTrue(any(e[:2] == ('automation5', 69) for e in events))
        for slot in (33, 40):
            self.assertTrue(any(e[:2] == ('automation', slot) for e in events))

    def test_each_worker_cleanup_failure_keeps_later_cleanups_running(self):
        for failure in ('notification', 'selection', 'focus', 'walker', 'uninitialize', 'bstr_free'):
            with self.subTest(failure=failure):
                result, error, events, _ = self.run_worker(observe=True, cleanup_failure=failure)
                self.assertIsNone(result)
                self.assertIsInstance(error, probe.ProbeFailure)
                self.assertEqual(1, sum(not row['succeeded'] for row in error.diagnostic['cleanup']))
                for name, slot in (('automation5', 69), ('automation', 33), ('automation', 40),
                                   ('walker', 2), ('root', 2), ('automation5', 2), ('automation', 2)):
                    self.assertTrue(any(e[:2] == (name, slot) for e in events))

    def test_immediate_typed_acquisition_failure_cleans_nonnull_output(self):
        for failure in ('null', 'lookup', 'lookup_exception', 'method', 'method_exception'):
            with self.subTest(failure=failure):
                result, error, events, ready = self.run_worker(retain=False, immediate=True, failure=failure)
                self.assertIsNone(result)
                self.assertIsInstance(error, probe.ProbeFailure)
                self.assertIsNone(ready)
                self.assertFalse(any(e[0] == 'unknown' for e in events))
                self.assertEqual(0 if failure == 'null' else 1,
                                 sum(e[:2] == ('pattern', 2) for e in events))

    def test_immediate_method_failure_is_not_masked_by_release_failure(self):
        result, error, _, _ = self.run_worker(retain=False, immediate=True, failure='method',
                                             release_failure=OSError('mock Release failure'))
        self.assertIsNone(result)
        self.assertIsInstance(error, probe.ProbeFailure)
        self.assertIn('COM failure 0x80004005', str(error))
        self.assertIn('mock Release failure', error.diagnostic['cleanup_error'])

    def test_cleanup_failure_without_primary_is_not_pass(self):
        result, error, _, _ = self.run_worker(count=2, release_failure=OSError('mock Release failure'))
        self.assertIsNone(result)
        self.assertIsInstance(error, probe.ProbeFailure)
        self.assertIn('mock Release failure', str(error))

    def test_interrupts_are_reraised_after_cleanup(self):
        for failure, release_failure, expected in (
                ('interrupt', OSError('mock Release failure'), KeyboardInterrupt),
                (None, KeyboardInterrupt('cleanup interrupted'), KeyboardInterrupt),
                (None, SystemExit(7), SystemExit)):
            with self.subTest(failure=failure, expected=expected):
                result, error, _, _ = self.run_worker(failure=failure, count=2, release_failure=release_failure)
                self.assertIsNone(result)
                self.assertIsInstance(error, expected)

    def test_default_worker_keeps_property_fallback_without_retention(self):
        result, error, events, ready = self.run_worker(retain=False)
        self.assertIsNone(error)
        self.assertEqual(0, ready['retained_patterns']['acquired'])
        self.assertEqual('IUIAutomationElement.GetCurrentPropertyValue', result['actions'][0]['decided_by'])
        self.assertFalse(any(e[0] == 'pattern' for e in events))


if __name__ == '__main__':
    unittest.main()
