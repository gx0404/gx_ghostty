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




if __name__ == '__main__':
    unittest.main()
