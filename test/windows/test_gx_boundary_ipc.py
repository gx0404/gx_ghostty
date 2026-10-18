"""Offline boundary regression; no native UI or process operations."""
import struct
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_boundary_ipc as ipc


class IpcBoundaryTests(unittest.TestCase):

    def test_forged_hello_preserves_valid_frame_and_changes_only_native_claim(self):
        original = b'GXIH\x01\0\0\0' + bytes(range(1, 17)) + bytes(140)
        self.assertEqual(164, len(original))
        changed = ipc.forged_hello(original, 55, 123456)
        self.assertEqual(original[:24], changed[:24])
        self.assertEqual(original[36:], changed[36:])
        self.assertEqual((55, 123456), struct.unpack_from('<IQ', changed, 24))
        for invalid in (original[:-1], b'NOPE' + original[4:], original[:8] + bytes(16) + original[24:]):
            with self.assertRaises(ValueError):
                ipc.forged_hello(invalid, 55, 123456)

    def test_replay_is_attributed_to_the_exact_launcher_pid_and_birth(self):
        text = ('06:41:24.512 [47440] info(win32): fixture_ipc_replay pid=55 birth=900 outcome=completed\n'
                '06:41:25.000 [47441] info(win32): fixture_ipc_replay pid=55 birth=901 outcome=completed\n'
                '06:41:25.100 [47442] info(win32): fixture_ipc_replay pid=56 birth=900 outcome=rejected\n')
        self.assertEqual(['completed'], ipc.replay_rows(text, 55, 900))
        self.assertEqual([], ipc.replay_rows(text, 55, 902))
        # The round-2 line without identity can no longer satisfy the assertion.
        self.assertEqual([], ipc.replay_rows('info(win32): fixture_ipc_replay outcome=completed\n', 55, 900))


if __name__ == "__main__":
    unittest.main()
