#!/usr/bin/env python3
"""Format Git-visible Zig/ZON sources, excluding nested build caches.

No arguments formats sources; --check is read-only. Uses the pinned zigw
toolchain and bounded argument batches on Windows and POSIX.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys

import zigw

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_DIRS = frozenset({".local", "zig-pkg", "zig-out", ".zig-cache", "zig-cache"})
ARGUMENT_BUDGET = 24000
GIT_LOCATION_ENV = frozenset({
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
})


def source_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        capture_output=True, check=True,
        env={key: value for key, value in os.environ.items() if key not in GIT_LOCATION_ENV},
    )
    files = []
    for raw in sorted(set(result.stdout.split(b"\0")) - {b""}):
        relative = raw.decode("utf-8")
        path = root / relative
        if path.suffix not in {".zig", ".zon"} or EXCLUDED_DIRS.intersection(Path(relative).parts[:-1]):
            continue
        if not path.exists():
            continue  # A tracked source may have been deleted in the worktree.
        cursor = root
        for part in Path(relative).parts:
            cursor /= part
            if cursor.is_symlink() or (hasattr(cursor, "is_junction") and cursor.is_junction()):
                raise ValueError(f"Refusing linked source path: {relative}")
        path.resolve().relative_to(root.resolve())
        if path.is_file():
            files.append(str(path.resolve()))
    return files


def command_size(command: list[str]) -> int:
    # This bound is conservative for both CreateProcess's UTF-16 command line
    # and POSIX argv bytes, including quotes and non-ASCII paths.
    text = subprocess.list2cmdline(command)
    return max(len(text.encode("utf-16-le")) // 2, len(text.encode("utf-8"))) + 1


def batches(prefix: list[str], files: list[str], budget: int = ARGUMENT_BUDGET):
    batch: list[str] = []
    for path in files:
        if command_size([*prefix, path]) > budget:
            raise ValueError(f"Source path exceeds command budget: {path}")
        if batch and command_size([*prefix, *batch, path]) > budget:
            yield batch
            batch = []
        batch.append(path)
    if batch:
        yield batch


def run(root: Path, check: bool) -> int:
    files = source_files(root)
    if not files:
        raise ValueError("No Git-visible Zig/ZON sources")
    env = zigw.child_env(os.environ, root)
    zig = zigw.require_zig(env, root)
    args = ["fmt", *(["--check"] if check else [])]
    for group in batches([zig.path, *args], files):
        code = zigw.run(zig.path, [*args, *group], env)
        if code:
            return code
    print(f"[zig-fmt] {'checked' if check else 'formatted'} {len(files)} Git-visible Zig/ZON files")
    return 0


def main(argv: list[str] | None = None) -> int:
    zigw.setup_zig.utf8_stdio()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    try:
        return run(ROOT, args.check)
    except (OSError, ValueError, subprocess.CalledProcessError, zigw.ZigwError) as exc:
        print(f"[zig-fmt] error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
