import contextlib
import io
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_slots


class SlotTests(unittest.TestCase):
    def test_probe_requires_existing_files_and_preserves_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'missing'
            with self.assertRaises(FileNotFoundError):
                with gx_slots.acquire(root, 'quiet', probe=True):
                    pass
            self.assertFalse(root.exists())
            with gx_slots.acquire(root, 'quiet') as lease:
                self.assertTrue(lease.verify())
            self.assertFalse(lease.verify())
            before = {p.name: p.read_bytes() for p in root.iterdir()}
            with gx_slots.acquire(root, 'quiet', probe=True):
                pass
            self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})

    def test_holders_read_owner_records_without_locking(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertEqual([], gx_slots.holders(root))
            with gx_slots.acquire(root, 'heavy'):
                held = gx_slots.holders(root)
                self.assertEqual([('heavy-1.lock', gx_slots.os.getpid(), 'heavy')],
                                 [(row['lock'], row['pid'], row['kind']) for row in held])
                self.assertEqual(0, self.attempt(root, 'heavy').returncode)
            self.assertEqual([], gx_slots.holders(root))
            (root / 'desktop-1.lock').write_bytes(b'\0{"pid": 7, "kind": "desk')
            self.assertEqual([], gx_slots.holders(root))

    def test_default_root_uses_git_common_dir(self):
        with tempfile.TemporaryDirectory() as temp:
            common = Path(temp) / 'main' / '.git'
            with mock.patch.object(gx_slots.subprocess, 'run', return_value=mock.Mock(stdout=str(common))):
                self.assertEqual(common.parent / '.local/kernel-slots', gx_slots.shared_root())

    def test_unresolvable_default_root_is_a_usage_error_without_traceback(self):
        argv = ['gx_slots.py', '--kind', 'heavy', '--', sys.executable, '-c', 'pass']
        for failure in (subprocess.CalledProcessError(128, ['git']), subprocess.TimeoutExpired(['git'], 10),
                        FileNotFoundError('git')):
            stderr = io.StringIO()
            with self.subTest(failure=type(failure).__name__), mock.patch.object(sys, 'argv', argv), \
                    mock.patch.object(gx_slots, 'shared_root', side_effect=failure), \
                    mock.patch.object(gx_slots, 'acquire', side_effect=AssertionError('no lock without a root')), \
                    contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as exit_:
                gx_slots.main()
            self.assertEqual(2, exit_.exception.code)
            self.assertIn('cannot resolve the shared slot root', stderr.getvalue())
            self.assertNotIn('Traceback', stderr.getvalue())

    def test_unlock_failure_still_closes_every_owned_handle(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original = gx_slots.unlock
            calls = []
            def unlock(stream):
                original(stream)
                calls.append(stream)
                if len(calls) == 1:
                    raise OSError('simulated cleanup error')
            with mock.patch.object(gx_slots, 'unlock', side_effect=unlock), self.assertRaises(OSError):
                with gx_slots.acquire(root, 'quiet'):
                    pass
            self.assertEqual(4, len(calls))
            self.assertTrue(all(stream.closed for stream in calls))
            self.assertEqual(0, self.attempt(root, 'quiet').returncode)

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
