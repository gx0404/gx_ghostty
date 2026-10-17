import subprocess
import sys
import tempfile
from pathlib import Path
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_slots


class SlotTests(unittest.TestCase):
    def test_quiet_excludes_all_slots_and_releases_after_error(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(RuntimeError):
                with gx_slots.acquire(root, 'quiet'):
                    for kind in ('heavy', 'desktop', 'quiet'):
                        self.assertEqual(1, self.attempt(root, kind).returncode)
                    raise RuntimeError('stop')
            for kind in ('heavy', 'desktop', 'quiet'):
                self.assertEqual(0, self.attempt(root, kind).returncode)
            self.assertEqual(4, len(list(root.glob('*.lock'))))

    def test_quiet_rolls_back_partial_acquisition_without_changing_owner(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with gx_slots.acquire(root, 'desktop'):
                owner = self.owner(root / 'desktop-1.lock')
                self.assertEqual(1, self.attempt(root, 'quiet').returncode)
                self.assertEqual(owner, self.owner(root / 'desktop-1.lock'))
                with gx_slots.acquire(root, 'heavy'), gx_slots.acquire(root, 'heavy'), gx_slots.acquire(root, 'heavy'):
                    pass

    def test_quiet_retry_holds_nothing_during_sleep(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            real_lock = gx_slots.lock
            busy = [True]
            def lock(stream):
                # Fail the fourth lock on the first attempt only.
                lock.calls += 1
                return False if busy[0] and lock.calls == 4 else real_lock(stream)
            lock.calls = 0
            def sleep(_):
                busy[0] = False
                with gx_slots.acquire(root, 'quiet'):
                    pass
            with mock.patch.object(gx_slots, 'lock', side_effect=lock), mock.patch.object(gx_slots.time, 'sleep', side_effect=sleep):
                with gx_slots.acquire(root, 'quiet', 10):
                    self.assertFalse(busy[0])

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
