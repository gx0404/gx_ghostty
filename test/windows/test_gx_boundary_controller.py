"""Deterministic negative contracts for native boundary controllers."""
import copy
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import gx_boundary_controller as controller
import gx_boundary_remote as remote


def tree():
    def leaf(core):
        return {'leaf': {'core': core, 'hwnd': core + 100, 'parent': 42, 'pty': {'pid': core + 200, 'birth': 123},
                         'title_hash': core, 'total': 300, 'viewport': 24, 'offset': 276}}
    return {'nodes': [{'split': {'axis': 0, 'ratio': 0.3125, 'first': 1, 'second': 2}}, leaf(1), leaf(2)],
            'active_core': 2, 'zoom': 2, 'title_hash': 543}


class BoundaryTests(unittest.TestCase):
    def test_native_control_preserves_negative_win32_lresult(self):
        native = controller.Native.__new__(controller.Native)
        native.instance, native.hwnd, native.window_id = mock.Mock(), 3, 111
        native.guard = mock.Mock()
        with mock.patch.object(controller.gui, 'win32') as api:
            api.return_value.send_message.return_value = (1 << (struct.calcsize('P') * 8)) - 1
            self.assertEqual(-1, native.control(3, 44))


    def test_continuity_allows_reparent_but_rejects_core_history_or_process_replacement(self):
        before = tree()
        after = copy.deepcopy(before)
        after['nodes'][1]['leaf']['parent'] = 77
        controller.assert_continuity(before, after)
        for field, value in (('hwnd', 999), ('total', 299), ('title_hash', 999), ('pty', {'pid': 201, 'birth': 124})):
            changed = copy.deepcopy(after)
            changed['nodes'][1]['leaf'][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                controller.assert_continuity(before, changed)
        changed = copy.deepcopy(after)
        changed['active_core'] = 1
        with self.assertRaises(AssertionError):
            controller.assert_continuity(before, changed)

    def test_cycle_alias_or_orphan_cannot_make_continuity_vacuous(self):
        for field in ('first', 'second'):
            broken = tree()
            broken['nodes'][0]['split'][field] = 0
            with self.assertRaises(AssertionError):
                controller.logical_tree(broken)
        broken = tree()
        broken['nodes'].append(copy.deepcopy(broken['nodes'][1]))
        with self.assertRaises(AssertionError):
            controller.logical_tree(broken)

    def test_reused_hwnd_blocks_control_even_with_same_pid(self):
        native = controller.Native.__new__(controller.Native)
        native.instance = mock.Mock(pid=42)
        native.hwnd, native.window_id = 3, 111
        with mock.patch.object(controller.gui, 'win32') as api:
            api.return_value.window_pid.return_value = 42
            api.return_value.send_message.return_value = 222
            with self.assertRaisesRegex(controller.gui.InputBlocked, 'reused'):
                native.control(8)
            self.assertEqual(1, api.return_value.send_message.call_count)
            self.assertEqual(controller.QUERY, api.return_value.send_message.call_args.args[1])


    def test_missing_remote_interface_never_guesses_selectors(self):
        with self.assertRaises(controller.PeerInterfaceUnavailable):
            remote.RemoteControls(None)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'contract.json'
            path.write_text(json.dumps({'version': 1, 'query_message': 0x450}), encoding='utf-8')
            with self.assertRaises(ValueError):
                remote.RemoteControls(path)



class LayoutAndGestureTests(unittest.TestCase):
    def fixture(self):
        fixture = controller.BoundaryFixture.__new__(controller.BoundaryFixture)
        fixture.report = {'native': [], 'captures': []}
        fixture.capture_native = mock.Mock()
        fixture.place = mock.Mock()
        return fixture

    @staticmethod
    def natives(source_tabs=1, target_tabs=64):
        source, target = mock.Mock(hwnd=11), mock.Mock(hwnd=22)
        source.query.side_effect = lambda field, *args: {4: source_tabs}[field]
        target.query.side_effect = lambda field, *args: {4: target_tabs}[field]
        source.tree.return_value = tree()
        return source, target

    @staticmethod
    def drop(delta, moved=(600, -27), pointer=(600, -27)):
        return {'delta': delta, 'loop_rect': (0, 0, 10, 10), 'moving_rect': (moved[0], moved[1], 10, 10),
                'loop_cursor': (0, 0), 'release_cursor': pointer}

    def test_side_by_side_windows_stay_inside_the_primary_work_area(self):
        area = (0, 0, 2560, 1392)
        slots = controller.side_by_side(area)
        self.assertEqual(slots[0][2:], slots[1][2:])
        for x, y, w, h in slots:
            self.assertTrue(controller.contains(area, (x, y, x + w, y + h)))
        self.assertLess(slots[1][0] + slots[1][2], 2560)
        with self.assertRaises(controller.EnvironmentUnavailable):
            controller.side_by_side((0, 0, 1000, 600))

    def test_full_target_rejects_a_drop_that_never_reached_the_refusal(self):
        fixture = self.fixture()
        for delta in ({'drops': 0, 'full_refusals': 0, 'merges': 0}, {'drops': 1, 'full_refusals': 0, 'merges': 1},
                      {'drops': 1, 'full_refusals': 0, 'merges': 0}):
            source, target = self.natives()
            fixture.cross_window_drop = mock.Mock(return_value=self.drop(delta))
            with self.subTest(delta=delta), mock.patch.object(controller.gui, 'win32'), \
                    self.assertRaisesRegex(AssertionError, 'full-target refusal'):
                fixture.full_target(mock.Mock(), source, target, tree())

    def test_full_target_requires_the_window_to_follow_the_native_move_loop(self):
        fixture = self.fixture()
        source, target = self.natives()
        refused = self.drop({'drops': 1, 'full_refusals': 1, 'merges': 0}, moved=(0, 0))
        fixture.cross_window_drop = mock.Mock(return_value=refused)
        with mock.patch.object(controller.gui, 'win32'), self.assertRaisesRegex(AssertionError, 'follow the pointer'):
            fixture.full_target(mock.Mock(), source, target, tree())

    def test_full_target_requires_a_merging_positive_control(self):
        fixture = self.fixture()
        source, target = self.natives()
        target.control.return_value = 1
        counts = iter([64, 64, 63, 63])
        target.query.side_effect = lambda field, *args: next(counts) if field == 4 else 0
        refused = self.drop({'drops': 1, 'full_refusals': 1, 'merges': 0})
        missed = self.drop({'drops': 1, 'full_refusals': 0, 'merges': 0})
        fixture.cross_window_drop = mock.Mock(side_effect=[refused, missed])
        with mock.patch.object(controller.gui, 'win32') as api, mock.patch.object(controller.time, 'sleep'), \
                self.assertRaisesRegex(AssertionError, 'control drop did not merge'):
            api.return_value.IsWindow.return_value = True
            fixture.full_target(mock.Mock(), source, target, tree())
        target.control.assert_called_once_with(8)

    def test_settled_reads_twice_after_the_input_queue_had_time(self):
        reads = iter([0, 1])
        with mock.patch.object(controller.time, 'sleep') as sleep:
            self.assertEqual([0, 1], controller.BoundaryFixture.settled(lambda: next(reads)))
        self.assertEqual([mock.call(controller.SETTLE_S)] * 2, sleep.call_args_list)

    def test_calibration_corrects_an_off_by_one_absolute_mapping(self):
        sent = []
        api = mock.Mock()
        api.virtual_screen.return_value = (0, 0, 2560, 1440)
        api.send.side_effect = lambda items: sent.append((items[0].u.mi.dx, items[0].u.mi.dy))
        api.mouse_input.side_effect = lambda *args: SimpleNamespace(u=SimpleNamespace(mi=SimpleNamespace(dx=0, dy=0)))
        # The fake desktop maps one normalized unit range one pixel to the left.
        pixel = lambda: (sent[-1][0] * 2560 // 65536 - 1, sent[-1][1] * 1440 // 65536)
        with mock.patch.object(controller.gui, 'win32', return_value=api), \
                mock.patch.object(controller, 'poll_cursor', side_effect=lambda point, timeout=0.5: pixel()):
            normalized = controller.calibrate(mock.Mock(), (1000, 700))
        self.assertEqual((1000, 700), (normalized[0] * 2560 // 65536 - 1, normalized[1] * 1440 // 65536))
        with mock.patch.object(controller.gui, 'win32', return_value=api), \
                mock.patch.object(controller, 'poll_cursor', return_value=(5, 5)), \
                self.assertRaises(controller.EnvironmentUnavailable):
            controller.calibrate(mock.Mock(), (1000, 700))

    def test_button_up_is_never_sent_into_a_foreign_foreground(self):
        fixture = self.fixture()
        instance = mock.Mock(pid=42)
        api = mock.Mock()
        api.IsWindow.return_value = True
        api.window_pid.side_effect = lambda hwnd: 42 if hwnd in (11, 12) else 7
        api.foreground.return_value = 99
        with mock.patch.object(controller.gui, 'win32', return_value=api), \
                mock.patch.object(controller, 'thread_state', return_value={'move_size': 0, 'capture': 0}), \
                self.assertRaises(controller.gui.InputBlocked):
            fixture.release(instance, (11,))
        api.send.assert_not_called()
        with mock.patch.object(controller.gui, 'win32', return_value=api), \
                mock.patch.object(controller, 'thread_state', return_value={'move_size': 0, 'capture': 12}):
            fixture.release(instance, (11,))
        api.send.assert_called_once()


class InputLanguageTests(unittest.TestCase):
    def test_restore_falls_back_to_an_owned_window_after_the_app_exited(self):
        fixture = SimpleNamespace(report={}, check=mock.Mock())
        instance = mock.Mock(pid=42)
        instance.alive.return_value = False
        with mock.patch.object(controller.gui, 'win32') as api:
            api.return_value.keyboard_layout.return_value = 0x08040804
            language = controller.InputLanguage(fixture, instance, 5)
            with mock.patch.object(controller, 'owned_helper_language', return_value={'method': 'owned-helper-window', 'restored': True}) as helper:
                self.assertTrue(language.restore()['restored'])
            helper.assert_called_once_with(0x08040804)
            with mock.patch.object(controller, 'owned_helper_language', return_value={'method': 'owned-helper-window', 'restored': False}), \
                    self.assertRaisesRegex(AssertionError, 'not restored'):
                language.restore()
        self.assertEqual([True, False], [item['restored'] for item in fixture.report['input_language']])

    def test_sign_extended_hkl(self):
        self.assertEqual(0x08040804, controller.full_hkl(0x08040804))
        self.assertEqual(-0x0FFDFBF7, controller.full_hkl(0xF0020409))


if __name__ == '__main__':
    unittest.main()
