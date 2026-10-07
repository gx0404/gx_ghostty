#!/usr/bin/env python3
"""scripts/setup_zig.py 测试：钉版表与版本锁、安装根、只读 check、幂等安装、换源与离线解压。"""

from __future__ import annotations

import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import setup_zig  # noqa: E402

SCRIPT = SCRIPTS / "setup_zig.py"
EXE_NAME = "zig.exe" if os.name == "nt" else "zig"


def _current_key(test: unittest.TestCase) -> str:
    try:
        return setup_zig.platform_key()
    except setup_zig.SetupZigError:
        test.skipTest("本平台没有钉版条目")
        raise


def _build_archive(directory: Path, key: str) -> tuple[Path, str]:
    """按真实钉版文件名造一个离线归档（zip 或 tar.xz），返回（路径, sha256）。"""
    tarball = setup_zig.PINS[key]["tarball"]
    stem = setup_zig.archive_stem(tarball)
    exe = "zig.exe" if key.endswith("-windows") else "zig"
    archive = directory / tarball
    if tarball.endswith(".zip"):
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr(f"{stem}/{exe}", b"fake zig")
            bundle.writestr(f"{stem}/lib/std/std.zig", b"// std")
    else:
        with tarfile.open(archive, "w:xz") as bundle:
            for name, data, mode in ((f"{stem}/{exe}", b"fake zig", 0o755), (f"{stem}/lib/std/std.zig", b"// std", 0o644)):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = mode
                bundle.addfile(info, io.BytesIO(data))
    return archive, hashlib.sha256(archive.read_bytes()).hexdigest()


class PinTests(unittest.TestCase):
    def test_zig_version_matches_build_zig_zon(self) -> None:
        zon = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
        match = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon)
        self.assertIsNotNone(match, "build.zig.zon 缺少 minimum_zig_version")
        self.assertEqual(match.group(1), setup_zig.ZIG_VERSION)

    def test_pins_cover_all_platforms_with_valid_sha256(self) -> None:
        self.assertEqual(
            {"x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos", "x86_64-windows"},
            set(setup_zig.PINS),
        )
        for key, pin in setup_zig.PINS.items():
            with self.subTest(key=key):
                self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
                suffix = ".zip" if key.endswith("-windows") else ".tar.xz"
                self.assertEqual(f"zig-{key}-{setup_zig.ZIG_VERSION}{suffix}", pin["tarball"])

    def test_download_bases_order(self) -> None:
        official = "https://ziglang.org/download/0.16.0/"
        self.assertEqual(official, setup_zig.DOWNLOAD_BASE)
        self.assertEqual(["https://pkg.machengine.org/zig/", official], setup_zig.download_bases({}))
        custom = setup_zig.download_bases({setup_zig.MIRROR_ENV: "https://example.cn/zig"})
        self.assertEqual(["https://example.cn/zig/", "https://pkg.machengine.org/zig/", official], custom)
        same = setup_zig.download_bases({setup_zig.MIRROR_ENV: "https://pkg.machengine.org/zig"})
        self.assertEqual(["https://pkg.machengine.org/zig/", official], same)

    def test_platform_key_maps_aliases(self) -> None:
        self.assertEqual("x86_64-windows", setup_zig.platform_key("Windows", "AMD64"))
        self.assertEqual("x86_64-linux", setup_zig.platform_key("Linux", "x86_64"))
        self.assertEqual("aarch64-linux", setup_zig.platform_key("Linux", "aarch64"))
        self.assertEqual("aarch64-macos", setup_zig.platform_key("Darwin", "arm64"))
        self.assertEqual("x86_64-macos", setup_zig.platform_key("Darwin", "x86_64"))
        for system, machine in (("Linux", "riscv64"), ("FreeBSD", "amd64"), ("Windows", "ARM64")):
            with self.subTest(system=system, machine=machine), self.assertRaises(setup_zig.SetupZigError):
                setup_zig.platform_key(system, machine)

    def test_speed_floor(self) -> None:
        mib = 1024 * 1024
        self.assertFalse(setup_zig.too_slow(0, setup_zig.SPEED_PROBE_SECONDS))
        self.assertTrue(setup_zig.too_slow(100 * 1024, 9))
        self.assertTrue(setup_zig.too_slow(1 * mib, 20))
        self.assertFalse(setup_zig.too_slow(10 * mib, 20))


class LayoutTests(unittest.TestCase):
    def test_default_install_root_is_repo_local(self) -> None:
        self.assertEqual(ROOT / ".local" / "toolchains" / "zig", setup_zig.install_root({}))
        self.assertEqual(setup_zig.REPO_ROOT, ROOT)
        other = Path("/tmp/other-repo")
        self.assertEqual(
            other / ".local" / "toolchains" / "zig" / "zig-0.16.0" / EXE_NAME,
            setup_zig.zig_binary({}, other),
        )

    def test_home_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {setup_zig.HOME_ENV: tmp}
            self.assertEqual(Path(tmp), setup_zig.install_root(env))
            self.assertEqual(Path(tmp) / "zig-0.16.0" / EXE_NAME, setup_zig.zig_binary(env))

    def test_which_on_path_searches_only_listed_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            tool = bin_dir / ("tool.exe" if os.name == "nt" else "tool")
            tool.write_bytes(b"")
            tool.chmod(0o755)
            found = setup_zig.which_on_path("tool", os.pathsep.join([str(Path(tmp) / "absent"), str(bin_dir)]))
            self.assertIsNotNone(found)
            self.assertEqual(os.path.normcase(str(tool)), os.path.normcase(found or ""))
            self.assertIsNone(setup_zig.which_on_path("tool", ""))


class CheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name) / "zig-home"
        self.env = {setup_zig.HOME_ENV: str(self.home), "PATH": ""}

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _check(self, version: str | None) -> tuple[int, str]:
        out = io.StringIO()
        with mock.patch.object(setup_zig, "run_zig_version", return_value=version), redirect_stdout(out):
            code = setup_zig.check(self.env)
        return code, out.getvalue()

    def _fake_binary(self) -> Path:
        binary = self.home / setup_zig.INSTALL_DIR_NAME / EXE_NAME
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"")
        return binary

    def test_check_missing_is_readonly(self) -> None:
        _current_key(self)
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8")
        env[setup_zig.HOME_ENV] = str(self.home)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--check"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            check=False,
        )
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn("MISSING", result.stdout)
        self.assertFalse(self.home.exists(), "check 不得创建目录")

    def test_check_reports_installed(self) -> None:
        _current_key(self)
        self._fake_binary()
        code, out = self._check(setup_zig.ZIG_VERSION)
        self.assertEqual(0, code)
        self.assertIn("INSTALLED", out)

    def test_check_flags_wrong_version(self) -> None:
        _current_key(self)
        self._fake_binary()
        code, out = self._check("0.15.1")
        self.assertEqual(1, code)
        self.assertIn("BROKEN", out)
        self.assertIn("--force", out)


class InstallTests(unittest.TestCase):
    def setUp(self) -> None:
        self.key = _current_key(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "zig-home"
        self.env = {setup_zig.HOME_ENV: str(self.home)}
        self.archive, self.digest = _build_archive(self.tmp, self.key)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _pin(self, digest: str | None = None):
        pin = dict(setup_zig.PINS[self.key], sha256=digest or self.digest)
        return mock.patch.dict(setup_zig.PINS, {self.key: pin})

    def _serve(self, *payloads: bytes | None):
        """依次为每个下载源返回给定字节；None 表示该源网络失败。"""
        urls: list[str] = []
        queue = list(payloads)

        def fake_download(url: str, destination: Path) -> None:
            urls.append(url)
            payload = queue.pop(0) if queue else None
            if payload is None:
                raise setup_zig.SetupZigError("网络失败：模拟")
            destination.write_bytes(payload)

        return mock.patch.object(setup_zig, "_download_one", side_effect=fake_download), urls

    def _install(self, force: bool = False) -> str:
        out = io.StringIO()
        with mock.patch.object(setup_zig, "run_zig_version", return_value=setup_zig.ZIG_VERSION), redirect_stdout(out):
            self.assertEqual(0, setup_zig.install(force=force, env=self.env))
        return out.getvalue()

    def test_refuses_broken_dir_without_force(self) -> None:
        (self.home / setup_zig.INSTALL_DIR_NAME).mkdir(parents=True)
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8")
        env[setup_zig.HOME_ENV] = str(self.home)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--install"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            check=False,
        )
        self.assertEqual(2, result.returncode)
        self.assertIn("--force", result.stderr)

    def test_idempotent_when_valid(self) -> None:
        binary = self.home / setup_zig.INSTALL_DIR_NAME / EXE_NAME
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"")
        patcher, urls = self._serve()
        with patcher:
            out = self._install()
        self.assertIn("跳过", out)
        self.assertEqual([], urls)

    def test_downloads_verifies_and_extracts_offline(self) -> None:
        patcher, urls = self._serve(self.archive.read_bytes())
        with self._pin(), patcher:
            self._install()
        self.assertEqual(["https://pkg.machengine.org/zig/" + self.archive.name], urls)
        target = self.home / setup_zig.INSTALL_DIR_NAME
        exe = "zig.exe" if self.key.endswith("-windows") else "zig"
        self.assertTrue((target / exe).is_file())
        self.assertTrue((target / "lib" / "std" / "std.zig").is_file())
        self.assertEqual([setup_zig.INSTALL_DIR_NAME], sorted(p.name for p in self.home.iterdir()))

    def test_falls_through_to_next_source_on_bad_sha256(self) -> None:
        patcher, urls = self._serve(b"tampered", self.archive.read_bytes())
        with self._pin(), patcher:
            self._install()
        self.assertEqual(
            ["https://pkg.machengine.org/zig/", setup_zig.DOWNLOAD_BASE],
            [url[: -len(self.archive.name)] for url in urls],
        )

    def test_custom_mirror_is_tried_first(self) -> None:
        self.env[setup_zig.MIRROR_ENV] = "https://mirror.example/zig"
        patcher, urls = self._serve(None, self.archive.read_bytes())
        with self._pin(), patcher:
            self._install()
        self.assertTrue(urls[0].startswith("https://mirror.example/zig/"))
        self.assertTrue(urls[1].startswith("https://pkg.machengine.org/zig/"))

    def test_all_sources_failing_leaves_no_install(self) -> None:
        patcher, urls = self._serve(None, None, None)
        with self._pin(), patcher, redirect_stdout(io.StringIO()):
            with self.assertRaises(setup_zig.SetupZigError) as caught:
                setup_zig.install(env=self.env)
        self.assertIn("所有下载源", str(caught.exception))
        self.assertEqual(2, len(urls))
        self.assertFalse((self.home / setup_zig.INSTALL_DIR_NAME).exists())
        self.assertEqual([], list(self.home.iterdir()))

    def test_force_replaces_broken_install(self) -> None:
        broken = self.home / setup_zig.INSTALL_DIR_NAME
        broken.mkdir(parents=True)
        (broken / "stale.txt").write_text("stale", encoding="utf-8")
        patcher, _ = self._serve(self.archive.read_bytes())
        with self._pin(), patcher:
            self._install(force=True)
        self.assertFalse((broken / "stale.txt").exists())
        self.assertTrue((broken / "lib" / "std" / "std.zig").is_file())


class ExtractTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_zip_uses_zipfile_even_when_tar_exists(self) -> None:
        archive, _ = _build_archive(self.tmp, "x86_64-windows")
        out = self.tmp / "out"
        out.mkdir()
        with mock.patch.object(setup_zig.shutil, "which", return_value="/usr/bin/tar"), mock.patch.object(
            setup_zig.subprocess, "run", side_effect=AssertionError("zip 不应交给系统 tar")
        ):
            setup_zig.extract_archive(archive, out)
        self.assertTrue((out / "zig-x86_64-windows-0.16.0" / "zig.exe").is_file())

    def test_tar_xz_extracts_with_tarfile(self) -> None:
        try:
            import lzma  # noqa: F401
        except ImportError:
            self.skipTest("Python 缺少 lzma")
        archive, _ = _build_archive(self.tmp, "x86_64-linux")
        out = self.tmp / "out"
        out.mkdir()
        setup_zig.extract_archive(archive, out)
        self.assertTrue((out / "zig-x86_64-linux-0.16.0" / "zig").is_file())

    def test_unknown_archive_rejected(self) -> None:
        bogus = self.tmp / "zig.tar.gz"
        bogus.write_bytes(b"")
        with self.assertRaises(setup_zig.SetupZigError):
            setup_zig.extract_archive(bogus, self.tmp)


if __name__ == "__main__":
    unittest.main()
