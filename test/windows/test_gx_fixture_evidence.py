"""Offline contracts; all native APIs are mocked and files are temporary."""
import contextlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_fixture_evidence as evidence


class EvidenceTests(unittest.TestCase):
    def test_144_dpi_does_not_claim_fractional_pixel_exact_boundary(self):
        actual = evidence.drag_thresholds(144)
        self.assertEqual(22, actual["vertical"]["at_or_below_px"])
        self.assertEqual(23, actual["vertical"]["above_px"])
        self.assertFalse(actual["vertical"]["exact_representable"])
        self.assertEqual(15, actual["horizontal"]["at_or_below_px"])
        self.assertTrue(actual["horizontal"]["exact_representable"])
        for dpi in (96, 120, 144, 192):
            for row in evidence.drag_thresholds(dpi).values():
                self.assertLessEqual(row["at_or_below_px"] * 96 / dpi, row["threshold_dip"])
                self.assertGreater(row["above_px"] * 96 / dpi, row["threshold_dip"])

    def test_review_requires_reading_and_preserves_reviewer_verdict(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "capture.png").write_bytes(b"fixture-image")
            path = evidence.write_review(root, "MIG-01", "R5-01", "host", "PASS", ["capture.png"])
            record = json.loads((root / path).read_text(encoding="utf-8"))
            self.assertEqual("PENDING_REVIEW", record["status"])
            self.assertEqual(evidence.sha256(root / "capture.png"), record["screenshots"][0]["sha256"])
            (root / path).write_text("reviewer-owned", encoding="utf-8")
            evidence.write_review(root, "MIG-01", "R5-01", "host", "PASS", ["capture.png"])
            self.assertEqual("reviewer-owned", (root / path).read_text(encoding="utf-8"))

    def test_pid_reuse_during_hash_rejected(self):
        api = mock.Mock()
        api.process_creation.side_effect = [123, 124]
        api.process_image.return_value = "fixture.exe"
        with mock.patch.object(evidence, "sha256", return_value="a" * 64):
            with self.assertRaisesRegex(AssertionError, "PID reused"):
                evidence.process_identity(api, 42)


class SharedSlotTests(unittest.TestCase):
    """fixture_slots locks the repository-wide slots, also from a worktree."""

    def git(self, *args, cwd):
        subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, encoding="utf-8")

    def test_a_worktree_shares_the_main_checkouts_slot_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            main, worktree = Path(folder) / "main", Path(folder) / "wt"
            main.mkdir()
            self.git("init", "-q", cwd=main)
            self.git("-c", "user.name=fixture", "-c", "user.email=fixture@invalid", "commit", "-q", "--allow-empty", "-m", "seed", cwd=main)
            self.git("worktree", "add", "-q", "--detach", str(worktree), cwd=main)
            gx_slots = SimpleNamespace(acquire=None)  # No shared_root: the git fallback.
            with mock.patch.dict(sys.modules, {"gx_slots": gx_slots}):
                expected = main.resolve() / ".local" / "kernel-slots"
                self.assertEqual(expected, evidence.slot_root(worktree).resolve())
                self.assertEqual(expected, evidence.slot_root(main).resolve())

    def test_gx_slots_shared_root_is_the_source_when_present(self):
        shared = Path("C:/repo/.local/kernel-slots")
        taken = []

        @contextlib.contextmanager
        def acquire(root, kind, timeout):
            taken.append((root, kind, timeout))
            yield

        gx_slots = SimpleNamespace(shared_root=lambda: shared, acquire=acquire)
        with mock.patch.dict(sys.modules, {"gx_slots": gx_slots}):
            with evidence.fixture_slots(Path("D:/elsewhere/worktree")):
                pass
            with evidence.fixture_slots(Path("D:/elsewhere/worktree"), desktop_held=True):
                pass
        self.assertEqual([(shared, "heavy", 45), (shared, "desktop", 45)], taken)


if __name__ == "__main__":
    unittest.main()
