import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_slots


class SlotTests(unittest.TestCase):
    def owner(self, path):
        with path.open("rb") as stream:
            stream.seek(1)
            return stream.read()

    def attempt(self, root, kind):
        return subprocess.run([sys.executable, str(Path(gx_slots.__file__)), "--root", str(root),
                               "--kind", kind, "--", sys.executable, "-c", "pass"],
                              capture_output=True, timeout=10)

    def test_desktop_exclusion_and_release_never_deletes_another_owner(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with gx_slots.acquire(root, "desktop"):
                owner = self.owner(root / "desktop-1.lock")
                self.assertEqual(self.attempt(root, "desktop").returncode, 1)
                self.assertEqual(self.owner(root / "desktop-1.lock"), owner)
                self.assertEqual(self.attempt(root, "heavy").returncode, 0)
            self.assertEqual(self.attempt(root, "desktop").returncode, 0)

    def test_exactly_three_heavy_slots_and_exception_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with gx_slots.acquire(root, "heavy"), gx_slots.acquire(root, "heavy"), gx_slots.acquire(root, "heavy"):
                self.assertEqual(self.attempt(root, "heavy").returncode, 1)
            self.assertEqual(self.attempt(root, "heavy").returncode, 0)
            with self.assertRaises(RuntimeError):
                with gx_slots.acquire(root, "desktop"):
                    raise RuntimeError("work failed")
            self.assertEqual(self.attempt(root, "desktop").returncode, 0)


if __name__ == "__main__":
    unittest.main()
