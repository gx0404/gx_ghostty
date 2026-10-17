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

ROOT = Path(__file__).resolve().parents[1]


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
def acquire(root: Path, kind: str, timeout: float = 0):
    if kind not in ("heavy", "desktop", "quiet") or not math.isfinite(timeout) or timeout < 0:
        raise ValueError("invalid slot kind or timeout")
    root.mkdir(parents=True, exist_ok=True)
    names = [f"heavy-{n}.lock" for n in (1, 2, 3)] if kind in ("heavy", "quiet") else []
    if kind in ("desktop", "quiet"):
        names.append("desktop-1.lock")
    deadline = time.monotonic() + timeout
    held = []

    def release():
        while held:
            stream = held.pop()
            try:
                stream.seek(1)
                stream.truncate()
                stream.flush()
            finally:
                try:
                    unlock(stream)
                finally:
                    stream.close()

    try:
        while True:
            for name in names:
                path = root / name
                # No append mode: update metadata under the owned byte lock.
                candidate = os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT, 0o600), "r+b")
                if not lock(candidate):
                    candidate.close()
                    if kind == "quiet":
                        break
                    continue
                held.append(candidate)
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
        yield
    finally:
        release()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("heavy", "desktop", "quiet"), required=True)
    parser.add_argument("--root", type=Path, default=ROOT / ".local" / "kernel-slots")
    parser.add_argument("--timeout", type=float, default=0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not math.isfinite(args.timeout) or args.timeout < 0:
        parser.error("a command and a nonnegative timeout are required")
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
