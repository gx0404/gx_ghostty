"""Offline boundary regression; no native UI or process operations."""
import struct
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_boundary_ipc as ipc


class IpcBoundaryTests(unittest.TestCase):

    def run_impostor(self, *, error=None, poll=1, code=1, children=(), windows=(),
                     sent=True, server_error=None, log_mode="rotate", message=b"DifferentImage\n"):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name)
        log = ipc.gui.log_path(path)
        log.parent.mkdir(parents=True)
        log.write_bytes(b"old DifferentImage\n")
        host = mock.Mock(pid=40, log=log)
        host.wait_log.return_value = "fixture_hello " + (b'GXIH\x01\0\0\0' + bytes(range(1, 17)) + bytes(140)).hex()
        launcher = mock.Mock(pid=41, log=log)
        launcher.alive.side_effect = [True, False]
        process = mock.Mock()
        if isinstance(poll, Exception):
            process.poll.side_effect = poll
        else:
            process.poll.return_value = poll
        process.wait.return_value = code
        fixture = mock.Mock(case_id="IPC-04b", processes={41: process})
        fixture.environment.return_value = path
        fixture.windows.side_effect = error
        fixture.windows.return_value = windows

        def start(_path):
            if fixture.start.call_count == 1:
                return host
            if log_mode == "rotate":
                log.replace(log.with_name(log.name + ".1"))
                log.write_bytes(message)
            elif log_mode == "append":
                with log.open("ab") as stream:
                    stream.write(message)
            elif log_mode == "truncate":
                log.write_bytes(message)
            elif log_mode == "unbound":
                log.replace(log.with_name(log.name + ".2"))
                log.with_name(log.name + ".1").write_bytes(b"unrelated log\n")
                log.write_bytes(message)
            return launcher

        fixture.start.side_effect = start
        server = mock.Mock(sent=sent, error=server_error)
        with mock.patch.object(ipc, "pipe_names", side_effect=[set(), {"owned"}]), \
             mock.patch.object(ipc, "Native"), mock.patch.object(ipc, "PipeApi") as pipe, \
             mock.patch.object(ipc, "FakeEndpoint", return_value=server), \
             mock.patch.object(ipc, "process_identity", return_value={"pid": 50, "birth": 60}), \
             mock.patch.object(ipc, "wait"), mock.patch.object(ipc.time, "sleep"), \
             mock.patch.object(ipc.gui, "win32") as win32:
            pipe.return_value.api.CreateFileW.return_value = 99
            def server_pid(_handle, target):
                target._obj.value = host.pid
                return True
            pipe.return_value.api.GetNamedPipeServerProcessId.side_effect = server_pid
            win32.return_value.child_processes.return_value = children
            try:
                ipc.run(fixture)
            finally:
                server.finish.assert_called_once_with()
        fixture.check.assert_called_once()
        process.wait.assert_called_once_with(timeout=2)
        return process

    def test_fast_nonzero_rejection_after_alive_probe(self):
        process = self.run_impostor(error=ipc.gui.InputBlocked("ended", cause="instance_gone"))
        process.poll.assert_called_once_with()

    def test_instance_gone_requires_original_process_exit(self):
        with self.assertRaises(ipc.gui.InputBlocked):
            self.run_impostor(error=ipc.gui.InputBlocked("identity changed", cause="instance_gone"), poll=None)

    def test_original_handle_errors_are_not_treated_as_exit(self):
        with self.assertRaises(PermissionError):
            self.run_impostor(error=ipc.gui.InputBlocked("ended", cause="instance_gone"),
                              poll=PermissionError("handle denied"))

    def test_other_guard_and_permission_errors_remain_failures(self):
        for cause in ipc.gui.InputBlocked.CAUSES:
            if cause == "instance_gone":
                continue
            with self.subTest(cause=cause), self.assertRaises(ipc.gui.InputBlocked):
                self.run_impostor(error=ipc.gui.InputBlocked("blocked", cause=cause))
        with self.assertRaises(PermissionError):
            self.run_impostor(error=PermissionError("denied"))

    def test_rejection_keeps_all_strict_assertions(self):
        for changes in ({"code": 0}, {"children": [(42, "cmd.exe")]},
                        {"sent": False}, {"server_error": "write failed"},
                        {"message": b"OtherError\n"}):
            with self.subTest(changes=changes), self.assertRaises(AssertionError):
                self.run_impostor(error=ipc.gui.InputBlocked("ended", cause="instance_gone"), **changes)
        with self.assertRaises(AssertionError):
            self.run_impostor(windows=[object()])

    def test_previous_shared_log_cannot_supply_different_image(self):
        with self.assertRaises(AssertionError):
            self.run_impostor(log_mode="unchanged")

    def test_append_without_new_rejection_cannot_reuse_old_log(self):
        with self.assertRaises(AssertionError):
            self.run_impostor(log_mode="append", message=b"OtherError\n")

    def test_new_rejection_after_rotation_or_offset(self):
        for mode in ("rotate", "append"):
            with self.subTest(mode=mode):
                self.run_impostor(log_mode=mode)

    def test_truncation_without_rotation_binding_fails_closed(self):
        with self.assertRaises(AssertionError):
            self.run_impostor(log_mode="truncate")

    def test_unrelated_rotation_cannot_supply_rejection(self):
        with self.assertRaises(AssertionError):
            self.run_impostor(log_mode="unbound")

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
