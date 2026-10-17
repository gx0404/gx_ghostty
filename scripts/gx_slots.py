"""Coordinate Windows-dispatched builds (including WSL/Docker) and desktop use.

Locks are kernel-owned and released on process exit. Persistent lock files are
never deleted or reclaimed by age. Run all jobs through the same host Python;
do not mix Windows locking and Linux flock against a shared mounted directory.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import subprocess
import time
from dataclasses import dataclass

ROOT = Path(__file__).resolve().parents[1]
QUIET_NAMES = tuple(f'heavy-{number}.lock' for number in (1, 2, 3)) + ('desktop-1.lock',)


def shared_root() -> Path:
    result = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True, encoding='utf-8', timeout=10, check=True)
    return Path(result.stdout.strip()).parent / '.local' / 'kernel-slots'


@dataclass
class Lease:
    root: Path
    kind: str
    streams: list
    pid: int

    def verify(self) -> bool:
        if self.pid != os.getpid() or self.kind != 'quiet' or len(self.streams) != 4:
            return False
        for stream in self.streams:
            if stream.closed:
                return False
            stream.seek(1)
            meta = json.loads(stream.read().decode('ascii'))
            if meta.get('pid') != self.pid or meta.get('kind') != 'quiet':
                return False
        return True


def holders(root: Path) -> list[dict]:
    """Owner records of the four shared locks, read without taking any lock.

    An owner writes its record after byte 0 under its own byte-0 lock and
    truncates it on release, so a record names a current owner (or one that
    crashed). Reading past byte 0 never touches the locked byte."""
    found = []
    for name in QUIET_NAMES:
        try:
            with (root / name).open('rb') as stream:
                stream.seek(1)
                raw = stream.read()
        except FileNotFoundError:
            continue
        try:
            meta = json.loads(raw.decode('ascii')) if raw.strip() else None
        except (UnicodeDecodeError, ValueError):
            meta = None  # an owner may be mid-write; not evidence of anything
        if isinstance(meta, dict) and isinstance(meta.get('pid'), int):
            found.append({'lock': name, 'pid': meta['pid'], 'kind': meta.get('kind'), 'started_ns': meta.get('started_ns')})
    return found


def lock(stream) -> bool:
    stream.seek(0)
    try:
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, PermissionError):
        return False
    except OSError as exc:
        if exc.errno in (11, 13, 35):
            return False
        raise
    return True


def unlock(stream) -> None:
    stream.seek(0)
    if os.name == "nt":
        import msvcrt
        msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


@contextmanager
def acquire(root: Path, kind: str, timeout: float = 0, *, probe: bool = False):
    if kind not in ("heavy", "desktop", "quiet") or not math.isfinite(timeout) or timeout < 0:
        raise ValueError("invalid slot kind or timeout")
    if probe:
        if not root.is_dir() or any(not (root / name).is_file() for name in QUIET_NAMES):
            raise FileNotFoundError(f'{root}: existing shared slot directory and all four locks are required')
    else:
        root.mkdir(parents=True, exist_ok=True)
    names = [f"heavy-{n}.lock" for n in (1, 2, 3)] if kind in ("heavy", "quiet") else []
    if kind in ("desktop", "quiet"):
        names.append("desktop-1.lock")
    deadline = time.monotonic() + timeout
    held = []

    def release():
        error = None
        while held:
            stream = held.pop()
            try:
                try:
                    if not probe:
                        stream.seek(1)
                        stream.truncate()
                        stream.flush()
                finally:
                    try:
                        unlock(stream)
                    finally:
                        stream.close()
            except BaseException as exc:
                error = error or exc
        if error is not None:
            raise error

    try:
        while True:
            for name in names:
                path = root / name
                # No append mode: update metadata under the owned byte lock.
                candidate = os.fdopen(os.open(path, os.O_RDWR | (0 if probe else os.O_CREAT), 0o600), "r+b")
                try:
                    acquired = lock(candidate)
                except BaseException:
                    candidate.close()
                    raise
                if not acquired:
                    candidate.close()
                    if kind == "quiet":
                        break
                    continue
                held.append(candidate)
                if not probe:
                    candidate.seek(0)
                    candidate.write(b"\0" + json.dumps({"pid": os.getpid(), "host": os.name, "kind": kind,
                                               "started_ns": time.time_ns()}).encode("ascii"))
                    candidate.truncate()
                    candidate.flush()
                if kind != "quiet":
                    break
            if held and (kind != "quiet" or len(held) == len(names)):
                break
            # All-or-nothing acquisition: never wait while holding a subset.
            release()
            if timeout == 0 or time.monotonic() >= deadline:
                raise TimeoutError(f"No free {kind} slot; existing owners were not changed")
            time.sleep(min(0.2, max(0, deadline - time.monotonic())))
        yield Lease(root.resolve(), kind, held, os.getpid())
    finally:
        release()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("heavy", "desktop", "quiet"), required=True)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--timeout", type=float, default=0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not math.isfinite(args.timeout) or args.timeout < 0:
        parser.error("a command and a nonnegative timeout are required")
    try:
        args.root = args.root or shared_root()
    except (OSError, subprocess.SubprocessError) as exc:
        parser.exit(2, f'gx-slots: cannot resolve the shared slot root from git; pass --root: {exc}\n')
    if not args.root.is_dir():
        parser.error(f'{args.root}: slot directory does not exist')
    try:
        with acquire(args.root, args.kind, args.timeout):
            child = subprocess.Popen(command)
            try:
                return child.wait()
            except KeyboardInterrupt:
                # Keep ownership until this command actually ends; interrupting
                # the caller must not advertise a free slot prematurely.
                child.wait()
                return 130
    except (OSError, TimeoutError) as exc:
        parser.exit(1, f"gx-slots: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
