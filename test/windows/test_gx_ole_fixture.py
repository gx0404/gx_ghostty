"""Offline OLE fixture regressions; all native UI and process calls are mocked."""
from contextlib import ExitStack, nullcontext, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import gx_ole_fixture as ole


class OleFixtureTests(unittest.TestCase):
    def run_fixture(self, *, case="quoted_path", exit_code=2, effect=1, gets=2,
                    releases=1, owned_error=None, foreground_error_at=None,
                    changed_hash=False, capture_error=None):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as patches:
            root = Path(temporary)
            exe, source, out = root / "app.exe", root / "source.exe", root / "evidence"
            exe.write_bytes(b"owned app")
            source.write_bytes(b"owned source")
            app_hash = hashlib.sha256(exe.read_bytes()).hexdigest()
            instance = mock.Mock(pid=100, creation=200, exe=exe, log=root / "absent.log")
            instance.alive.return_value = False
            window = SimpleNamespace(hwnd=300)
            terminal = SimpleNamespace(hwnd=301, rect=(0, 0, 800, 600))
            instance.terminals.return_value = [terminal]
            events = []

            def require_window():
                events.append("window")
                return window

            def ensure_owned():
                events.append("owned")
                if owned_error:
                    raise ole.gui.InputBlocked(owned_error)

            foreground_calls = 0

            def ensure_foreground(*, probe=False):
                nonlocal foreground_calls
                foreground_calls += 1
                events.append("foreground")
                if foreground_calls == foreground_error_at:
                    raise ole.gui.InputBlocked("foreground moved to an unrelated app")

            def capture(*args):
                events.append("capture")
                image = mock.Mock()

                def save(path):
                    events.append(path.name)
                    if path.name == "failure-after.png" and capture_error:
                        raise OSError(capture_error)

                image.save_png.side_effect = save
                return image

            instance.require_window.side_effect = require_window
            instance.ensure_owned.side_effect = ensure_owned
            instance.ensure_foreground.side_effect = ensure_foreground
            instance.capture_window.side_effect = capture
            snapshot_calls = 0

            def snapshot(_):
                nonlocal snapshot_calls
                snapshot_calls += 1
                events.append("snapshot")
                return {"process": {"pid": 100, "birth": 200, "exe": str(exe),
                                    "sha256": "0" * 64 if changed_hash and snapshot_calls > 1 else app_hash}}

            process = mock.Mock(pid=400, returncode=exit_code)
            finished = False

            def finish(timeout):
                nonlocal finished
                finished = True
                return exit_code

            process.poll.side_effect = lambda: exit_code if finished else None
            process.wait.side_effect = finish

            def popen(argv, **kwargs):
                work = Path(next(arg.split("=", 1)[1] for arg in argv if arg.startswith("--work-dir=")))
                folder = work / "gx-ole-400-1"
                folder.mkdir()
                ready = {"source_pid": 400, "source_hwnd": 401, "target_pid": 100,
                         "target_birth": 200, "target_hwnd": 301, "app_sha256": app_hash}
                native = {"effect": effect, "get_data_calls": 999, "get_data": gets,
                          "medium_releases": releases, "paste_completed": "PENDING_TARGET_VERIFICATION"}
                (folder / "ready.json").write_text(json.dumps(ready), encoding="utf-8")
                (folder / "evidence.json").write_text(json.dumps(native), encoding="utf-8")
                return process

            argv = ["gx_ole_fixture.py", "--exe", str(exe), "--sha256", app_hash,
                    "--source", str(source), "--out", str(out), "--source-window", "--case", case]
            if exit_code == 2:
                argv.extend(["--case", "multiline"])
            patches.enter_context(mock.patch.object(ole.sys, "argv", argv))
            patches.enter_context(mock.patch.object(ole, "fixture_slots", return_value=nullcontext()))
            patches.enter_context(mock.patch.object(ole.gui, "prepare_env_dir"))
            patches.enter_context(mock.patch.object(ole.gui, "write_config"))
            patches.enter_context(mock.patch.object(ole.gui, "launch", return_value=instance))
            api = patches.enter_context(mock.patch.object(ole.gui, "win32"))
            api.return_value.process_creation.return_value = 500
            drag = patches.enter_context(mock.patch.object(ole, "OwnedDrag"))
            drag.return_value.start_point.return_value = (10, 10)
            patches.enter_context(mock.patch.object(ole, "native_snapshot", side_effect=snapshot))
            launch = patches.enter_context(mock.patch.object(ole.subprocess, "Popen", side_effect=popen))
            # Popen is mocked, but its Windows-only argument is evaluated first.
            patches.enter_context(mock.patch.object(ole.subprocess, "CREATE_NO_WINDOW", 0x08000000, create=True))
            patches.enter_context(mock.patch.object(ole.time, "sleep"))
            review = patches.enter_context(mock.patch.object(ole, "write_review"))
            with redirect_stdout(io.StringIO()):
                result = ole.main()
            report = json.loads((out / "report.json").read_text(encoding="utf-8"))
            self.assertEqual(1, launch.call_count)
            self.assertEqual(1, len(report["cases"]))
            return result, report["cases"][0], instance, events, review

    def assert_native_failure(self, result, record, instance, review, reason):
        self.assertEqual(1, result)
        self.assertEqual("FAIL", record["status"])
        self.assertEqual(reason, record["reason"])
        self.assertIn(f"AssertionError: {reason}", record["traceback"])
        self.assertEqual("FAIL", review.call_args.args[4])
        instance.activate.assert_called_once_with()
        instance.press.assert_not_called()
        instance.mouse.assert_not_called()

    def test_native_failure_keeps_original_error_and_captures_under_both_guards(self):
        result, record, instance, events, review = self.run_fixture()
        self.assert_native_failure(result, record, instance, review, "DoDragDrop source returned 2")
        self.assertEqual(["before.png", "failure-after.png"], record["captures"])
        self.assertEqual(["owned", "foreground", "snapshot", "window", "owned", "foreground",
                          "capture", "failure-after.png"], events[-8:])
        self.assertEqual(2, record["native"]["get_data"])
        self.assertEqual(1, record["native"]["medium_releases"])

    def test_capture_exception_does_not_replace_original_failure(self):
        result, record, instance, _, review = self.run_fixture(capture_error="screenshot write failed")
        self.assert_native_failure(result, record, instance, review, "DoDragDrop source returned 2")
        self.assertEqual("screenshot write failed", record["failure_after_error"])
        self.assertEqual(["before.png"], record["captures"])

    def test_changed_identity_prevents_failure_capture(self):
        result, record, instance, _, review = self.run_fixture(owned_error="owned process changed")
        self.assert_native_failure(result, record, instance, review, "DoDragDrop source returned 2")
        self.assertEqual("owned process changed", record["failure_after_error"])
        self.assertEqual(1, instance.capture_window.call_count)

    def test_changed_foreground_prevents_failure_capture_before_and_after_snapshot(self):
        for call in (2, 3):
            with self.subTest(foreground_call=call):
                result, record, instance, _, review = self.run_fixture(foreground_error_at=call)
                self.assert_native_failure(result, record, instance, review, "DoDragDrop source returned 2")
                self.assertEqual("foreground moved to an unrelated app", record["failure_after_error"])
                self.assertEqual(1, instance.capture_window.call_count)

    def test_changed_image_hash_prevents_failure_capture(self):
        result, record, instance, _, review = self.run_fixture(changed_hash=True)
        self.assert_native_failure(result, record, instance, review, "DoDragDrop source returned 2")
        self.assertEqual("app hash changed before failure capture", record["failure_after_error"])
        self.assertEqual(1, instance.capture_window.call_count)

    def test_copy_is_still_rejected_for_malformed_payload_even_with_balanced_media(self):
        for exit_code, reason in ((0, "DoDragDrop source returned 0"), (4, "unexpected OLE admission effect")):
            with self.subTest(exit_code=exit_code):
                result, record, instance, _, review = self.run_fixture(exit_code=exit_code, gets=1)
                self.assert_native_failure(result, record, instance, review, reason)
                self.assertIn("failure-after.png", record["captures"])

    def test_unreleased_medium_is_still_a_failure_when_drop_is_rejected(self):
        result, record, instance, _, review = self.run_fixture(exit_code=4, effect=0)
        self.assert_native_failure(result, record, instance, review, "OLE storage medium was not released exactly once")
        self.assertIn("failure-after.png", record["captures"])

    def test_balanced_rejection_does_not_count_failed_getdata_calls_as_media(self):
        result, record, _, _, review = self.run_fixture(exit_code=4, effect=0, gets=1)
        self.assertEqual(0, result)
        self.assertEqual("NATIVE_PASS_VISUAL_PENDING", record["status"])
        self.assertEqual(["before.png", "after.png"], record["captures"])
        self.assertEqual("PASS", review.call_args.args[4])

    def test_copy_success_keeps_paste_verification_pending(self):
        result, record, _, _, review = self.run_fixture(case="shell_metachar_files", exit_code=0, gets=1)
        self.assertEqual(0, result)
        self.assertEqual("NATIVE_PASS_VISUAL_PENDING", record["status"])
        self.assertEqual("PENDING_TARGET_VERIFICATION", record["native"]["paste_completed"])
        self.assertEqual("PENDING_REVIEW", review.call_args.kwargs["paste_verification"])


class OleDiagnosticAuditTests(unittest.TestCase):
    def test_failure_capture_real_guard_audit_does_not_record_injection(self):
        import gx_perf

        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            exe = work / "owned-app.exe"
            app_hash = "a" * 64
            log = work / "guards.jsonl"
            instance = ole.gui.Instance(pid=100, exe=str(exe), env_dir=work, creation=200, launched=0)
            backend = mock.Mock()
            backend.process_alive.return_value = True
            backend.process_image.return_value = str(exe)
            backend.process_creation.return_value = 200
            backend.foreground.return_value = 300
            backend.window_pid.return_value = 100
            identity = {"process": {"sha256": app_hash}}
            record = {"status": "FAIL", "reason": "original failure", "traceback": "original traceback", "captures": []}
            # Exercise the real Instance guards, input_guard decorator, audit
            # writer and guard_evidence reader; only native operations are mocked.
            with mock.patch.dict(os.environ, {"GX_PERF_BATCH_ID": "ole-diagnostic", "GX_PERF_GUARD_LOG": str(log)}), \
                    mock.patch.object(ole.gui, "win32", return_value=backend), \
                    mock.patch.object(ole, "native_snapshot", return_value=identity), \
                    mock.patch.object(instance, "require_window", return_value=SimpleNamespace(hwnd=300)), \
                    mock.patch.object(instance, "capture_window") as capture:
                ole.capture_failure_after(instance, app_hash, work, record)
                evidence = gx_perf.guard_evidence(log, "ole-diagnostic")
            capture.return_value.save_png.assert_called_once_with(work / "failure-after.png")
            self.assertEqual(["failure-after.png"], record["captures"])
            self.assertEqual(("FAIL", "original failure", "original traceback"),
                             (record["status"], record["reason"], record["traceback"]))
            self.assertFalse(evidence["injected"], evidence)
            self.assertEqual(0, evidence["passed_guards"])
            self.assertEqual([], instance.input_events)
            backend.send.assert_not_called()
            backend.activate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
