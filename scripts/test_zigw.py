#!/usr/bin/env python3
"""scripts/zigw.py 测试：解析顺序、版本校验、缓存目录默认值、参数与退出码透传。

伪 zig 是一个 Python 脚本，外面套平台启动器（Windows 用 zig.cmd，其他平台用 sh 脚本），
所以 Windows 上同样能跑；不会运行真实 zig，也不写真实仓库。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import setup_zig  # noqa: E402
import zigw  # noqa: E402

SCRIPT = SCRIPTS / "zigw.py"
EXE_NAME = "zig.exe" if os.name == "nt" else "zig"
OVERRIDE_VARS = ("GX_GHOSTTY_ZIG", "ZIG", setup_zig.HOME_ENV, zigw.CACHE_ENV)
FAKE_ZIG_SOURCE = """\
import json, os, sys
args = sys.argv[1:]
if args == ["version"]:
    print(os.environ.get("FAKE_ZIG_VERSION", "0.16.0"))
    sys.exit(0)
record = os.environ.get("FAKE_ZIG_RECORD")
if record:
    with open(record, "w", encoding="utf-8") as handle:
        json.dump({"args": args, "cache": os.environ.get("ZIG_GLOBAL_CACHE_DIR")}, handle, ensure_ascii=False)
sys.exit(int(os.environ.get("FAKE_ZIG_EXIT", "0")))
"""


def make_fake_zig(directory: Path) -> Path:
    """可执行的伪 zig：`zig version` 打印 $FAKE_ZIG_VERSION（默认 0.16.0），其余调用记录参数与缓存目录。"""
    directory.mkdir(parents=True, exist_ok=True)
    script = directory / "fake_zig.py"
    script.write_text(FAKE_ZIG_SOURCE, encoding="utf-8")
    if os.name == "nt":
        launcher = directory / "zig.cmd"
        launcher.write_text(f'@"{sys.executable}" "{script}" %*\r\n@exit /b %ERRORLEVEL%\r\n', encoding="utf-8", newline="")
    else:
        launcher = directory / "zig"
        launcher.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n', encoding="utf-8")
        launcher.chmod(0o755)
    return launcher


def make_dummy(path: Path) -> Path:
    """只用于解析顺序断言、不会被执行的占位文件。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"")
    path.chmod(0o755)
    return path


def same(left: str | Path, right: str | Path) -> bool:
    return os.path.normcase(os.path.abspath(left)) == os.path.normcase(os.path.abspath(right))


class ResolveTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "repo"
        self.root.mkdir()
        self.pinned = make_dummy(self.root / ".local" / "toolchains" / "zig" / "zig-0.16.0" / EXE_NAME)
        self.path_zig = make_dummy(self.tmp / "path-bin" / EXE_NAME)
        self.gx_zig = make_dummy(self.tmp / "gx" / EXE_NAME)
        self.env_zig = make_dummy(self.tmp / "env" / EXE_NAME)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def env(self, **values: str) -> dict[str, str]:
        return {"PATH": str(self.path_zig.parent), **values}

    def test_gx_ghostty_zig_has_highest_priority(self) -> None:
        resolved = zigw.resolve_zig(self.env(GX_GHOSTTY_ZIG=str(self.gx_zig), ZIG=str(self.env_zig)), self.root)
        self.assertEqual("GX_GHOSTTY_ZIG", resolved.source)
        self.assertTrue(same(self.gx_zig, resolved.path))

    def test_zig_env_beats_pinned_and_path(self) -> None:
        resolved = zigw.resolve_zig(self.env(ZIG=str(self.env_zig)), self.root)
        self.assertEqual("ZIG", resolved.source)
        self.assertTrue(same(self.env_zig, resolved.path))

    def test_pinned_beats_path(self) -> None:
        resolved = zigw.resolve_zig(self.env(), self.root)
        self.assertEqual("pinned", resolved.source)
        self.assertTrue(same(self.pinned, resolved.path))

    def test_path_is_last_resort(self) -> None:
        self.pinned.unlink()
        resolved = zigw.resolve_zig(self.env(), self.root)
        self.assertEqual("PATH", resolved.source)
        self.assertTrue(same(self.path_zig, resolved.path))

    def test_missing_everywhere_mentions_just_setup(self) -> None:
        self.pinned.unlink()
        with self.assertRaises(zigw.ZigwError) as caught:
            zigw.resolve_zig({"PATH": str(self.tmp / "empty")}, self.root)
        self.assertIn("just setup", str(caught.exception))

    def test_broken_override_fails_instead_of_falling_back(self) -> None:
        with self.assertRaises(zigw.ZigwError) as caught:
            zigw.resolve_zig(self.env(GX_GHOSTTY_ZIG=str(self.tmp / "nope" / EXE_NAME)), self.root)
        self.assertIn("GX_GHOSTTY_ZIG", str(caught.exception))

    def test_bare_command_override_is_looked_up_on_path(self) -> None:
        resolved = zigw.resolve_zig(self.env(ZIG="zig"), self.root)
        self.assertEqual("ZIG", resolved.source)
        self.assertTrue(same(self.path_zig, resolved.path))

    def test_blank_overrides_are_ignored(self) -> None:
        resolved = zigw.resolve_zig(self.env(GX_GHOSTTY_ZIG="", ZIG="  "), self.root)
        self.assertEqual("pinned", resolved.source)

    def test_zig_home_moves_pinned_dir(self) -> None:
        home_zig = make_dummy(self.tmp / "shared" / "zig-0.16.0" / EXE_NAME)
        resolved = zigw.resolve_zig(self.env(GX_GHOSTTY_ZIG_HOME=str(self.tmp / "shared")), self.root)
        self.assertEqual("pinned", resolved.source)
        self.assertTrue(same(home_zig, resolved.path))


class VersionAndEnvTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.fake = make_fake_zig(self.tmp / "fake")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def env(self, **values: str) -> dict[str, str]:
        env = {key: value for key, value in os.environ.items() if key not in OVERRIDE_VARS}
        env.update(GX_GHOSTTY_ZIG=str(self.fake), PYTHONDONTWRITEBYTECODE="1", **values)
        return env

    def test_require_zig_accepts_pinned_version(self) -> None:
        resolved = zigw.require_zig(self.env(), self.tmp)
        self.assertEqual("GX_GHOSTTY_ZIG", resolved.source)

    def test_require_zig_rejects_other_version(self) -> None:
        with self.assertRaises(zigw.ZigwError) as caught:
            zigw.require_zig(self.env(FAKE_ZIG_VERSION="0.15.1"), self.tmp)
        message = str(caught.exception)
        self.assertIn("0.15.1", message)
        self.assertIn(setup_zig.ZIG_VERSION, message)

    def test_cache_dir_defaults_to_repo_local(self) -> None:
        env = zigw.child_env({"PATH": ""}, self.tmp)
        self.assertEqual(str(self.tmp / ".local" / "zig-cache" / "global"), env[zigw.CACHE_ENV])
        self.assertEqual(ROOT / ".local" / "zig-cache" / "global", zigw.default_cache_dir())

    def test_cache_dir_respects_existing_value(self) -> None:
        self.assertEqual("/custom/cache", zigw.child_env({zigw.CACHE_ENV: "/custom/cache"}, self.tmp)[zigw.CACHE_ENV])
        blank = zigw.child_env({zigw.CACHE_ENV: ""}, self.tmp)[zigw.CACHE_ENV]
        self.assertEqual(str(self.tmp / ".local" / "zig-cache" / "global"), blank)


class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.fake = make_fake_zig(self.tmp / "fake")
        self.record = self.tmp / "record.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, *args: str, **env_values: str) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if key not in OVERRIDE_VARS}
        env.update(
            {
                setup_zig.HOME_ENV: str(self.tmp / "no-pinned"),
                "FAKE_ZIG_RECORD": str(self.record),
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONIOENCODING": "utf-8",
            }
        )
        env.update(env_values)
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            cwd=self.tmp,
            env=env,
            check=False,
        )

    def _recorded(self) -> dict:
        return json.loads(self.record.read_text(encoding="utf-8"))

    def test_passes_args_exit_code_and_default_cache_dir(self) -> None:
        cache = ROOT / ".local" / "zig-cache" / "global"
        existed = cache.exists()
        result = self._run("build", "test", "-Dtest-filter=terminal", GX_GHOSTTY_ZIG=str(self.fake), FAKE_ZIG_EXIT="7")
        self.assertEqual(7, result.returncode, result.stderr)
        recorded = self._recorded()
        self.assertEqual(["build", "test", "-Dtest-filter=terminal"], recorded["args"])
        self.assertTrue(same(cache, recorded["cache"]))
        if not existed:
            self.assertFalse(cache.exists(), "zigw 不应自行创建缓存目录")

    def test_zero_exit_and_existing_cache_dir_preserved(self) -> None:
        custom = str(self.tmp / "custom-cache")
        result = self._run("fmt", "--check", ".", ZIG=str(self.fake), ZIG_GLOBAL_CACHE_DIR=custom)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({"args": ["fmt", "--check", "."], "cache": custom}, self._recorded())

    def test_path_zig_used_when_no_override(self) -> None:
        path = os.pathsep.join([str(self.fake.parent), os.environ.get("PATH", "")])
        result = self._run("build", PATH=path, FAKE_ZIG_EXIT="3")
        self.assertEqual(3, result.returncode, result.stderr)
        self.assertEqual(["build"], self._recorded()["args"])

    def test_missing_zig_exits_2_with_setup_hint(self) -> None:
        empty = self.tmp / "empty-bin"
        empty.mkdir()
        result = self._run("build", PATH=str(empty))
        self.assertEqual(2, result.returncode)
        self.assertIn("just setup", result.stderr)
        self.assertFalse(self.record.exists())

    def test_wrong_version_exits_2_without_running_command(self) -> None:
        result = self._run("build", GX_GHOSTTY_ZIG=str(self.fake), FAKE_ZIG_VERSION="0.15.1")
        self.assertEqual(2, result.returncode)
        self.assertIn("0.15.1", result.stderr)
        self.assertIn(setup_zig.ZIG_VERSION, result.stderr)
        self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
