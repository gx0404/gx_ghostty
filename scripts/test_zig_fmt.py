#!/usr/bin/env python3
"""Exercise source discovery against a real temporary Git worktree."""
from __future__ import annotations

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zig_fmt


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def put(self, name, content="const x = 1;\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def test_sources_include_untracked_and_unicode_but_not_ignored_nested_caches(self):
        self.put(".gitignore", "ignored/\n")
        keep = [self.put("build.zig"), self.put("build.zig.zon", ".{}\n"), self.put("目录 with spaces/new.zig")]
        self.put("docs/note.md")
        self.put("ignored/source.zig")
        for cache in zig_fmt.EXCLUDED_DIRS:
            self.put(f"example/demo/{cache}/dependency.zig")
        self.assertEqual(set(map(str, keep)), set(zig_fmt.source_files(self.root)))

    def test_deleted_tracked_source_is_not_passed_to_zig(self):
        path = self.put("removed.zig")
        subprocess.run(["git", "-C", str(self.root), "add", "removed.zig"], check=True)
        path.unlink()
        self.assertEqual([], zig_fmt.source_files(self.root))

    def test_foreign_git_environment_cannot_change_source_scope(self):
        own = self.put("own.zig")
        self.put(".gitignore", "foreign.zig\nforeign-repo/\n")
        self.put("foreign.zig")
        foreign = self.root / "foreign-repo"
        foreign.mkdir()
        subprocess.run(["git", "init", "-q", str(foreign)], check=True)
        (foreign / "foreign.zig").write_text("const x = 1;\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(foreign), "add", "foreign.zig"], check=True)
        polluted = {
            "GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
            "GIT_INDEX_FILE": str(foreign / ".git/index"),
        }
        with mock.patch.dict(os.environ, polluted):
            self.assertEqual([str(own)], zig_fmt.source_files(self.root))

    def test_checker_keeps_files_and_propagates_tool_failure(self):
        path = self.put("目录 with spaces/main.zig", "not formatted\n")
        before = path.read_bytes()
        with mock.patch.object(zig_fmt.zigw, "require_zig", return_value=zig_fmt.zigw.ResolvedZig("pinned-zig", "pinned")), \
             mock.patch.object(zig_fmt.zigw, "run", return_value=7) as execute:
            self.assertEqual(7, zig_fmt.run(self.root, True))
        self.assertEqual(before, path.read_bytes())
        self.assertEqual(["fmt", "--check", str(path)], execute.call_args.args[1])
        self.assertEqual("pinned-zig", execute.call_args.args[0])

    def test_pinned_toolchain_failure_never_falls_back(self):
        self.put("main.zig")
        with mock.patch.object(zig_fmt.zigw, "require_zig", side_effect=zig_fmt.zigw.ZigwError("wrong version")), \
             mock.patch.object(zig_fmt.zigw, "run") as execute:
            with self.assertRaises(zig_fmt.zigw.ZigwError):
                zig_fmt.run(self.root, True)
            execute.assert_not_called()


class BatchingTests(unittest.TestCase):
    def test_bounded_batches_keep_every_path_and_do_not_split_arguments(self):
        paths = [f"C:/目录 with spaces/{i:04d}.zig" for i in range(1000)]
        prefix = ["C:/tool chain/zig.exe", "fmt", "--check"]
        groups = list(zig_fmt.batches(prefix, paths, budget=300))
        self.assertGreater(len(groups), 1)
        self.assertEqual(paths, [path for group in groups for path in group])
        for group in groups:
            self.assertLessEqual(zig_fmt.command_size([*prefix, *group]), 300)

    def test_single_oversized_argument_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "command budget"):
            list(zig_fmt.batches(["zig", "fmt"], ["x" * 500], budget=100))


if __name__ == "__main__":
    unittest.main()
