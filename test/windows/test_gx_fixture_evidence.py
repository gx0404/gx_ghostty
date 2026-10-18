"""Offline contracts; all native APIs are mocked and files are temporary."""
import contextlib
import json
import os
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
        with tempfile.TemporaryDirectory() as folder, self.environment():
            worktree = Path(folder) / "worktree"
            worktree.mkdir()
            (worktree / ".git").write_text("gitdir: elsewhere\n", encoding="utf-8")  # A worktree's link file.
            with mock.patch.dict(sys.modules, {"gx_slots": gx_slots}):
                with evidence.fixture_slots(worktree):
                    pass
                with evidence.fixture_slots(worktree, desktop_held=True):
                    pass
        self.assertEqual([(shared, "heavy", 45), (shared, "desktop", 45)], taken)

    @contextlib.contextmanager
    def environment(self, **values):
        """os.environ without GX_FIXTURE_SLOT_ROOT, plus `values`."""
        with mock.patch.dict(os.environ, values):
            if "GX_FIXTURE_SLOT_ROOT" not in values:
                os.environ.pop("GX_FIXTURE_SLOT_ROOT", None)
            yield

    @staticmethod
    def no_git():
        """A gx_slots whose shared_root, like git itself, must not be asked."""
        def refuse(*args, **kwargs):
            raise AssertionError(f"git must not run: {args}")
        return SimpleNamespace(shared_root=refuse, acquire=None), refuse

    def test_a_staged_copy_outside_any_checkout_keeps_its_own_slots(self):
        # Review round 4: a VM stage of the Python fixtures has no git checkout;
        # the default lock entry must work there as it did before shared slots.
        gx_slots, refuse = self.no_git()
        with tempfile.TemporaryDirectory() as folder, self.environment():
            stage = Path(folder) / "stage"
            stage.mkdir()
            with mock.patch.dict(sys.modules, {"gx_slots": gx_slots}), mock.patch.object(evidence.subprocess, "run", side_effect=refuse):
                self.assertEqual(stage / ".local" / "kernel-slots", evidence.slot_root(stage))

    def test_an_explicit_absolute_slot_root_needs_no_git(self):
        gx_slots, refuse = self.no_git()
        with tempfile.TemporaryDirectory() as folder:
            explicit = Path(folder) / "vm-slots"
            with self.environment(GX_FIXTURE_SLOT_ROOT=str(explicit)), mock.patch.dict(sys.modules, {"gx_slots": gx_slots}), \
                    mock.patch.object(evidence.subprocess, "run", side_effect=refuse):
                self.assertEqual(explicit, evidence.slot_root(Path(__file__).resolve().parents[2]))
        with self.environment(GX_FIXTURE_SLOT_ROOT="relative/slots"), self.assertRaisesRegex(ValueError, "absolute"):
            evidence.slot_root(Path("D:/stage"))

    def test_a_checkout_whose_git_fails_does_not_fall_back_to_private_slots(self):
        # A worktree's own slots would not exclude the other worktrees.
        def fail():
            raise subprocess.CalledProcessError(128, ["git"])
        gx_slots = SimpleNamespace(shared_root=fail, acquire=None)
        with tempfile.TemporaryDirectory() as folder, self.environment():
            worktree = Path(folder) / "worktree"
            worktree.mkdir()
            (worktree / ".git").write_text("gitdir: elsewhere\n", encoding="utf-8")
            with mock.patch.dict(sys.modules, {"gx_slots": gx_slots}), self.assertRaises(subprocess.CalledProcessError):
                evidence.slot_root(worktree)

    def test_the_coordinator_held_entry_takes_no_lock_and_needs_no_slot_root(self):
        with mock.patch.object(evidence, "slot_root", side_effect=AssertionError("no slot root when held")):
            with evidence.fixture_slots(Path("D:/stage"), desktop_held=True):
                pass


if __name__ == "__main__":
    unittest.main()
