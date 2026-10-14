import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import sys
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_windows_vm as vm


class WindowsVmTests(unittest.TestCase):
    def test_stage_validation_binds_guest_and_exact_fixture_hash(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(vm, "protect_directory"):
            root = Path(directory)
            vm.prepare(root)
            guest_uuid = "17874e2a-890a-4dd9-8f10-9d9b030ab9d3"
            destination = vm.stage_validation(root, "win11", guest_uuid, "GX-WIN11")
            data = json.loads((destination / "validation-manifest.json").read_text())
            self.assertEqual(data["guest_uuid"], guest_uuid)
            self.assertEqual(data["image"], vm.IMAGE)
            self.assertEqual(data["fixture_sha256"], hashlib.sha256(vm.VALIDATION_SCRIPT.read_bytes()).hexdigest())
            self.assertEqual((destination / vm.VALIDATION_SCRIPT.name).read_bytes(), vm.VALIDATION_SCRIPT.read_bytes())
            original = (destination / "validation-manifest.json").read_bytes()
            with self.assertRaisesRegex(ValueError, "another owner or VM"):
                vm.stage_validation(root, "win11", "64a9cf19-6e00-44df-8579-58620db1ab2e", "GX-WIN11")
            self.assertEqual((destination / "validation-manifest.json").read_bytes(), original)

    def test_media_rejects_corruption_and_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "iso"
            path.write_bytes(b"good")
            spec = {"size": 4, "sha256": hashlib.sha256(b"good").hexdigest()}
            self.assertEqual(vm.verify_media(path, spec), spec["sha256"])
            path.write_bytes(b"evil")
            with self.assertRaisesRegex(ValueError, "SHA256"):
                vm.verify_media(path, spec)
            path.write_bytes(b"bad")
            with self.assertRaisesRegex(ValueError, "size"):
                vm.verify_media(path, spec)

    def test_isolation_and_idempotent_credentials(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(vm, "protect_directory") as protect:
            root = Path(directory)
            vm.prepare(root)
            protect.assert_called_with(root)
            first = (root / "win11" / "credentials.json").read_bytes()
            vm.prepare(root)
            self.assertEqual(first, (root / "win11" / "credentials.json").read_bytes())
            account = json.loads(first)
            for version, web in [("win11", 18006), ("win10", 18007)]:
                compose = (root / version / "compose.yaml").read_text()
                self.assertIn(vm.IMAGE, compose)
                self.assertIn(f"127.0.0.1:{web}:8006", compose)
                self.assertIn("KVM: 'Y'", compose)
                self.assertIn("restart: 'no'", compose)
                self.assertIn("/custom.iso:ro", compose)
                self.assertNotIn(account["admin_password"], compose)
                self.assertNotIn(str(Path.home()), compose)
                setup = (root / version / "oem" / "setup-guest.ps1").read_text()
                self.assertIn("fDisableClip -Value 1", setup)
                self.assertIn("fDisableCdm -Value 1", setup)


if __name__ == "__main__":
    unittest.main()
