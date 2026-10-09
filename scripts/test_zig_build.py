#!/usr/bin/env python3
"""scripts/zig_build.py 测试：Windows 默认目标的补全条件、参数顺序与退出码透传。

不运行真实 zig，zigw.main 被替换为记录参数的桩。
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import zig_build  # noqa: E402

TARGET = zig_build.WINDOWS_TARGET


class BuildArgsTests(unittest.TestCase):
    def test_windows_adds_the_gnu_target_first(self):
        self.assertEqual(["build", TARGET], zig_build.build_args([], windows=True))
        self.assertEqual(
            ["build", TARGET, "-Doptimize=ReleaseFast", "run", "--", "-e", "cmd"],
            zig_build.build_args(["-Doptimize=ReleaseFast", "run", "--", "-e", "cmd"], windows=True),
        )

    def test_explicit_target_is_kept(self):
        for target in ("-Dtarget=x86_64-windows-msvc", "-Dtarget=x86_64-linux-gnu", "-Dtarget=native"):
            with self.subTest(target):
                self.assertEqual(["build", target], zig_build.build_args([target], windows=True))

    def test_lib_vt_builds_are_unchanged(self):
        for flag in ("-Demit-lib-vt", "-Demit-lib-vt=true"):
            with self.subTest(flag):
                self.assertEqual(["build", flag], zig_build.build_args([flag], windows=True))
        self.assertEqual(
            ["build", TARGET, "-Demit-lib-vt=false"],
            zig_build.build_args(["-Demit-lib-vt=false"], windows=True),
        )

    def test_other_hosts_are_unchanged(self):
        self.assertEqual(["build"], zig_build.build_args([], windows=False))
        self.assertEqual(["build", "-Doptimize=Debug"], zig_build.build_args(["-Doptimize=Debug"], windows=False))

    def test_target_lookalikes_do_not_count(self):
        self.assertEqual(
            ["build", TARGET, "-Dtarget-cpu=x", "--target=y"],
            zig_build.build_args(["-Dtarget-cpu=x", "--target=y"], windows=True),
        )


class MainTests(unittest.TestCase):
    def test_delegates_to_zigw_and_returns_its_exit_code(self):
        with mock.patch.object(zig_build.zigw, "main", return_value=3) as zigw_main, \
                mock.patch.object(zig_build.sys, "platform", "win32"):
            self.assertEqual(3, zig_build.main(["-Doptimize=ReleaseFast"]))
        zigw_main.assert_called_once_with(["build", TARGET, "-Doptimize=ReleaseFast"])

    def test_non_windows_passes_arguments_through(self):
        with mock.patch.object(zig_build.zigw, "main", return_value=0) as zigw_main, \
                mock.patch.object(zig_build.sys, "platform", "linux"):
            self.assertEqual(0, zig_build.main(["-Dapp-runtime=gtk"]))
        zigw_main.assert_called_once_with(["build", "-Dapp-runtime=gtk"])


if __name__ == "__main__":
    unittest.main()
