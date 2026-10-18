"""Offline A2r adapter regression: signed LRESULTs, capability-first baselines."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

import gx_boundary_controller as controller
import gx_boundary_remote as remote

BITS = struct.calcsize("P") * 8
CONTRACT = {"version": 1, "query_message": 1107, "capability": {"selector": 0, "value": 0x47585233},
            "ack_drop": {"message": 1108, "wparam": 1, "lparam": 0x47585233},
            "scrollback_total": 1, "scrollback_viewport": 2, "scrollback_offset": 3,
            "input_applied": 4, "input_query_count": 5, "ack_dropped": 6}


def unsigned(value):
    """What SendMessageTimeoutW's DWORD_PTR result reports for a signed LRESULT."""
    return value & ((1 << BITS) - 1)


class RemoteControlsTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / "remote-controls.json"
        path.write_text(json.dumps(CONTRACT), encoding="utf-8")
        self.controls = remote.RemoteControls(path)
        self.instance = mock.Mock(pid=42)
        patcher = mock.patch.object(remote.gui, "win32")
        self.api = patcher.start().return_value
        self.addCleanup(patcher.stop)
        self.api.window_pid.return_value = 42
        self.api.class_name.return_value = "GhosttyRemotePane"

    def answer(self, *values):
        self.api.send_message.side_effect = [unsigned(value) for value in values]

    def test_negative_lresults_are_errors_never_counter_growth(self):
        self.answer(-2)
        with self.assertRaisesRegex(AssertionError, "not ready or disconnected"):
            self.controls.query(self.instance, 9, "ack_dropped")
        self.answer(-1)
        with self.assertRaisesRegex(AssertionError, "invalid argument"):
            self.controls.query(self.instance, 9, "input_query_count")
        self.answer(5)
        self.assertEqual(5, self.controls.query(self.instance, 9, "input_applied"))
        self.api.send_message.assert_called_with(9, 1107, 4, 0, timeout_ms=2500)

    def test_capability_is_polled_until_magic_before_any_baseline(self):
        self.answer(-2, -2, 0x47585233)
        with mock.patch.object(remote.time, "sleep"):
            self.assertEqual(0x47585233, self.controls.wait_ready(self.instance, 9))
        self.assertEqual(3, self.api.send_message.call_count)
        self.api.send_message.side_effect = lambda *args, **kwargs: unsigned(-2)
        with self.assertRaisesRegex(AssertionError, "did not become ready"):
            self.controls.wait_ready(self.instance, 9, timeout=0.1)
        # DefWindowProcW's 0 (gate off or interface absent) is not a capability.
        self.api.send_message.side_effect = lambda *args, **kwargs: 0
        with self.assertRaises(controller.PeerInterfaceUnavailable):
            self.controls.wait_ready(self.instance, 9, timeout=0.1)

    def test_arming_waits_for_capability_and_requires_exactly_one(self):
        self.answer(0x47585233, -1)
        with self.assertRaisesRegex(AssertionError, "duplicate arming"):
            self.controls.arm(self.instance, 9)
        self.answer(-2, 0x47585233, 1)
        with mock.patch.object(remote.time, "sleep"):
            self.assertEqual(1, self.controls.arm(self.instance, 9))
        self.assertEqual(mock.call(9, 1108, 1, 0x47585233, timeout_ms=2500), self.api.send_message.call_args)

    def test_foreign_or_non_pane_window_is_never_messaged(self):
        self.api.class_name.return_value = "GhosttyWindow"
        with self.assertRaises(remote.gui.InputBlocked):
            self.controls.query(self.instance, 9, "ack_dropped")
        self.api.send_message.assert_not_called()

    def test_monotonic_counter_must_settle_without_decreasing(self):
        reads = iter([3, 4, 5, 5])
        with mock.patch.object(remote.time, "sleep"):
            self.assertEqual(5, remote.settle_counter(lambda: next(reads), 3))
        reads = iter([4, 2])
        with mock.patch.object(remote.time, "sleep"), self.assertRaisesRegex(AssertionError, "decreased"):
            remote.settle_counter(lambda: next(reads), 3)


if __name__ == "__main__":
    unittest.main()
