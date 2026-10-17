"""Offline contracts; all native APIs are mocked and files are temporary."""
import json
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
