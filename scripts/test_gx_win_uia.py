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


if __name__ == '__main__':
    unittest.main()
