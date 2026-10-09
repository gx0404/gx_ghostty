"""Tests for scripts/gx_windows_package.py: fake prefixes and pins, no network."""

from __future__ import annotations

import dataclasses
import hashlib
import io
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_release as release  # noqa: E402
import gx_windows_package as pkg  # noqa: E402

ROOT = SCRIPTS.parent
VS = release.release_info(ROOT).version_string
SHA = "a" * 40
ROOT_FILES = (
    "LICENSE", "CHANGELOG.md", "build.zig.zon", "scripts/setup_zig.py", "dist/windows/ghostty.ico",
    "dist/windows/gx/ghostty-gx.iss", *(item.member for item in pkg.PAYLOAD if item.source == pkg.REPO),
)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def symlinks_supported() -> bool:
    with tempfile.TemporaryDirectory() as temp:
        try:
            os.symlink("target", os.path.join(temp, "link"))
        except (OSError, NotImplementedError):
            return False
    return True


def sfnt(full_name: str, notice: str = "Copyright 2020 Test Font Authors", ttc: bool = False) -> bytes:
    """A minimal OpenType file (or one-font collection) whose name table has IDs 0 and 4."""
    records = [(0, notice.encode("utf-16-be")), (4, full_name.encode("utf-16-be")),
               (4, "Mac Name".encode("utf-16-be"))]
    strings = b"".join(data for _, data in records)
    table = struct.pack(">HHH", 0, len(records), 6 + 12 * len(records))
    offset = 0
    for index, (ident, data) in enumerate(records):
        platform, encoding, language = (3, 1, 0x409) if index < 2 else (1, 0, 0)
        table += struct.pack(">6H", platform, encoding, language, ident, len(data), offset)
        offset += len(data)
    table += strings
    base = 16 if ttc else 0
    font = struct.pack(">IHHHH", 0x00010000, 1, 16, 0, 0)
    font += struct.pack(">4sIII", b"name", 0, base + 12 + 16, len(table)) + table
    return (b"ttcf" + struct.pack(">III", 0x00010000, 1, base) + font) if ttc else font


def fake_pe(imports: tuple[str, ...] = (), machine: int = 0x8664, version: str = VS) -> bytes:
    """A PE image with one .idata section listing imports, followed by the version string."""
    data = bytearray(0x400)
    data[0:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x40)
    data[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, 0x44, machine, 1, 0, 0, 0, 0xF0, 0x22)
    optional = 0x58
    struct.pack_into("<H", data, optional, 0x20B)
    names_rva = 0x1000 + 20 * (len(imports) + 1)
    struct.pack_into("<II", data, optional + 112 + 8, 0x1000, 20 * (len(imports) + 1))
    struct.pack_into("<8sIIII", data, optional + 0xF0, b".idata", 0x200, 0x1000, 0x200, 0x200)
    cursor = names_rva
    for index, name in enumerate(imports):
        struct.pack_into("<IIIII", data, 0x200 + index * 20, 0, 0, 0, cursor, 0)
        raw = name.encode("ascii") + b"\0"
        data[0x200 + cursor - 0x1000:0x200 + cursor - 0x1000 + len(raw)] = raw
        cursor += len(raw)
    return bytes(data) + version.encode("ascii") + b"\0"


def write(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def make_root(base: Path, themes: dict[str, bytes] | None = None) -> Path:
    root = base / "root"
    for relative in ROOT_FILES:
        write(root / relative, (ROOT / relative).read_bytes())
    for name, data in (themes or {}).items():
        write(root / "src/gx/themes" / name, data)
    return root


def windows_prefix(base: Path, *, imports: tuple[str, ...] = ("KERNEL32.dll", "helper.dll"), **extra: bytes) -> Path:
    prefix = base / "prefix"
    write(prefix / "bin/ghostty.exe", fake_pe(imports))
    write(prefix / "bin/helper.dll", b"MZ helper")
    write(prefix / "bin/ghostty-vt.dll", b"MZ vt")
    write(prefix / "bin/ghostty-vt.pdb", b"pdb")
    write(prefix / "share/ghostty/themes/Builtin Dark", b"background = #000000\n")
    write(prefix / "share/ghostty/shell-integration/zsh/ghostty-integration", b"# zsh\n")
    write(prefix / "share/terminfo/ghostty.terminfo", b"xterm-ghostty|ghostty,\n")
    write(prefix / "share/pkgconfig/libghostty-vt.pc", b"Name: libghostty-vt\n")
    write(prefix / "include/ghostty/vt.h", b"/* vt */\n")
    for relative, data in extra.items():
        write(prefix / relative, data)
    return prefix


class Fixtures:
    """Fake third-party downloads mirroring the real pin table, served by a fake urlopen."""

    def __init__(self, base: Path) -> None:
        self.base = base
        self.blobs: dict[str, bytes] = {}
        self.requests: list[str] = []
        self.members: dict[str, bytes] = {}
        downloads, payload = [], []
        by_source: dict[str, list[pkg.Payload]] = {}
        for item in pkg.PAYLOAD:
            by_source.setdefault(item.source, []).append(item)
        for download in pkg.DOWNLOADS:
            items = by_source[download.name]
            contents = {item.member: self.member_bytes(item) for item in items}
            blob = self.archive(download.kind, contents)
            url = f"https://example.invalid/{download.name}"
            self.blobs[url] = blob
            downloads.append(dataclasses.replace(download, url=url, sha256=sha(blob), size=len(blob)))
            payload.extend(dataclasses.replace(item, sha256=sha(contents[item.member])) for item in items)
        payload.extend(by_source[pkg.REPO])
        self.downloads, self.payload = downloads, payload

    def member_bytes(self, item: pkg.Payload) -> bytes:
        name = item.target.rsplit("/", 1)[-1]
        if item.target.startswith("fonts/"):
            data = sfnt(name.rsplit(".", 1)[0].replace("-", " "), ttc=name.endswith(".ttc"))
        elif item.target.startswith("licenses/"):
            data = f"SIL Open Font License 1.1 for {name}\n\nPermission is hereby granted.\n".encode()
        else:
            data = b"MZ fake " + item.target.encode()
        self.members[item.target] = data
        return data

    @staticmethod
    def archive(kind: str, contents: dict[str, bytes]) -> bytes:
        buffer = io.BytesIO()
        if kind == "file":
            return next(iter(contents.values()))
        if kind in ("zip", "7z"):
            with zipfile.ZipFile(buffer, "w") as bundle:
                for member, data in contents.items():
                    bundle.writestr(member, data)
                bundle.writestr("unrelated/readme.txt", b"extra")
        elif kind == "tar.xz":
            with tarfile.open(fileobj=buffer, mode="w:xz") as bundle:
                for member, data in contents.items():
                    info = tarfile.TarInfo(member)
                    info.size = len(data)
                    bundle.addfile(info, io.BytesIO(data))
        return buffer.getvalue()

    def urlopen(self, request, timeout=None):
        url = request.full_url
        self.requests.append(url)
        return io.BytesIO(self.blobs[url])

    def fetcher(self, download: pkg.Download, cache: Path) -> Path:
        return pkg.fetch(download, cache, urlopen=self.urlopen, sleep=lambda seconds: None)

    @staticmethod
    def seven_zip(archive: Path, members: dict[str, Path]) -> None:
        with zipfile.ZipFile(archive) as bundle:
            for member, destination in members.items():
                destination.write_bytes(bundle.read(member))


class Case(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.fixtures = Fixtures(self.base)
        self.cache = self.base / "cache"
        self.root = make_root(self.base)
        stdout = mock.patch("sys.stdout", new_callable=io.StringIO)
        self.stdout = stdout.start()
        self.addCleanup(stdout.stop)
        patcher = mock.patch.object(release, "INSTALLER_MIN_BYTES", 4096)
        patcher.start()
        self.addCleanup(patcher.stop)

    def common(self) -> dict:
        return {"downloads": self.fixtures.downloads, "payload": self.fixtures.payload,
                "fetcher": self.fixtures.fetcher}

    def tree(self, prefix: Path, root: Path | None = None) -> Path:
        tree = self.base / "tree"
        pkg.build_tree(tree, prefix, VS, self.cache, root=root or self.root, seven_zip=self.fixtures.seven_zip,
                       **self.common())
        return tree


class PinTests(unittest.TestCase):
    def test_pins_are_well_formed_and_every_download_is_used(self):
        names = [download.name for download in pkg.DOWNLOADS]
        self.assertEqual(len(names), len(set(names)))
        for download in pkg.DOWNLOADS:
            with self.subTest(download=download.name):
                self.assertRegex(download.sha256, r"^[0-9a-f]{64}$")
                self.assertTrue(download.url.startswith("https://"))
                self.assertIn(download.kind, ("zip", "tar.xz", "7z", "file"))
                self.assertGreater(download.size, 0)
                self.assertTrue(any(item.source == download.name for item in pkg.PAYLOAD))
        targets = [item.target for item in pkg.PAYLOAD]
        self.assertEqual(len(targets), len(set(targets)))
        for item in pkg.PAYLOAD:
            with self.subTest(target=item.target):
                self.assertRegex(item.sha256, r"^[0-9a-f]{64}$")
                self.assertIn(item.source, {*names, pkg.REPO})

    def test_committed_license_texts_match_their_pins(self):
        for item in pkg.PAYLOAD:
            if item.source == pkg.REPO:
                with self.subTest(path=item.member):
                    data = (ROOT / item.member).read_bytes()
                    self.assertNotIn(b"\r", data)
                    self.assertEqual(sha(data), item.sha256)

    def test_fonts_and_runtime_match_the_release_contract(self):
        fonts = sorted(item.target.split("/", 1)[1] for item in pkg.font_payload())
        self.assertEqual(fonts, sorted(release.WINDOWS_FONTS))
        asset = release.expected_assets(VS)[pkg.zip_name(VS)]
        targets = {item.target for item in pkg.PAYLOAD} | set(pkg.GENERATED) | {"ghostty.exe",
                                                                                   "share/terminfo/ghostty.terminfo"}
        self.assertLessEqual(set(asset.required), targets)
        self.assertEqual(asset.root, pkg.top_name(VS))
        self.assertIn(pkg.installer_base(VS) + ".exe", release.expected_assets(VS))

    def test_fonts_are_the_wezterm_gx_snapshot(self):
        expected = {
            "JetBrainsMonoNerdFont-Bold.ttf": "e82e27a7f37c9a0a13cc4e417503a149c6a0280586930772d2ebed803159c864",
            "JetBrainsMonoNerdFont-BoldItalic.ttf": "961222be7bce59f310b41a3e158368d5ea22a47a0ac31defd57caac9b9e82cb0",
            "JetBrainsMonoNerdFont-Italic.ttf": "981133a258ef4c62769a7a7214a4b455ac1c63923784a70f50c48977b67f7025",
            "JetBrainsMonoNerdFont-Regular.ttf": "0ec29a68b539ece7078fc714cebff0c0accb2f4948f8f7963d9f5e86633b12d9",
            "JetBrainsMonoNerdFont-SemiBold.ttf": "1d28a687259870de46378bf83e511d9c85136c597db678e6c4953b2731e55c72",
            "JetBrainsMonoNerdFont-SemiBoldItalic.ttf": "0647c1d105ce061fae5cb772e8ee0fdec9b814725d7dc141545d9fb7b24fe0ba",
            "NotoSansCJK-Bold.ttc": "0c066cc1f22541fd9e138190de26dc480a4b8221bef5321e27e7b7802b26ee5e",
            "NotoSansCJK-Regular.ttc": "5dcd1c336cc9344cb77c03a0cd8982ca8a7dc97d620fd6c9c434e02dcb1ceeb3",
        }
        self.assertEqual({item.target.split("/", 1)[1]: item.sha256 for item in pkg.font_payload()}, expected)

    def test_version_strings(self):
        self.assertEqual(pkg.numeric_version("1.3.2-gx.0.1.0"), "1.3.2.0")
        self.assertEqual(pkg.check_version_string(VS, ROOT), VS)
        for bad in ("1.3.2", "1.3.2-gx.0.1", "v1.3.2-gx.0.1.0", "01.3.2-gx.0.1.0", ""):
            with self.subTest(bad=bad), self.assertRaisesRegex(pkg.PackageError, "not <X.Y.Z>-gx"):
                pkg.check_version_string(bad, ROOT)
        major = VS.split(".", 1)
        other = f"{int(major[0]) + 1}.{major[1]}"
        with self.assertRaisesRegex(pkg.PackageError, "differs from"):
            pkg.check_version_string(other, ROOT)


class FetchTests(Case):
    def download(self) -> pkg.Download:
        return next(item for item in self.fixtures.downloads if item.kind == "file")

    def test_downloads_once_then_reuses_the_verified_cache(self):
        download = self.download()
        path = self.fixtures.fetcher(download, self.cache)
        self.assertEqual(sha(path.read_bytes()), download.sha256)
        self.assertEqual(self.fixtures.fetcher(download, self.cache), path)
        self.assertEqual(self.fixtures.requests, [download.url])
        path.write_bytes(b"corrupted")
        self.fixtures.fetcher(download, self.cache)
        self.assertEqual(len(self.fixtures.requests), 2)
        self.assertEqual(sha(path.read_bytes()), download.sha256)

    def test_mismatched_downloads_are_discarded(self):
        download = dataclasses.replace(self.download(), sha256="0" * 64)
        with self.assertRaisesRegex(pkg.PackageError, "discarded"):
            self.fixtures.fetcher(download, self.cache)
        self.assertEqual(list(self.cache.iterdir()), [])
        download = dataclasses.replace(self.download(), size=1)
        with self.assertRaisesRegex(pkg.PackageError, "discarded"):
            self.fixtures.fetcher(download, self.cache)

    def test_offline_mode_and_retries(self):
        download = self.download()
        with self.assertRaisesRegex(pkg.PackageError, "--offline"):
            pkg.fetch(download, self.cache, offline=True)
        attempts = []

        def flaky(request, timeout=None):
            attempts.append(request.full_url)
            if len(attempts) < 3:
                raise OSError("connection reset")
            return io.BytesIO(self.fixtures.blobs[request.full_url])

        sleeps = []
        pkg.fetch(download, self.cache, urlopen=flaky, sleep=sleeps.append)
        self.assertEqual((len(attempts), sleeps), (3, [5.0, 10.0]))
        self.assertTrue(pkg.fetch(download, self.cache, offline=True).is_file())
        with self.assertRaisesRegex(pkg.PackageError, "cannot download"):
            pkg.fetch(dataclasses.replace(download, name="other"), self.cache,
                      urlopen=mock.Mock(side_effect=OSError("down")), sleep=lambda seconds: None)


class PortableTreeTests(Case):
    def test_tree_layout_contents_and_skips(self):
        prefix = windows_prefix(self.base)
        tree = self.tree(prefix)
        files = {path.relative_to(tree).as_posix() for path in tree.rglob("*") if path.is_file()}
        for relative in ("ghostty.exe", "helper.dll", "conpty.dll", "OpenConsole.exe", "mesa/opengl32.dll",
                         "mesa/libgallium_wgl.dll", "mesa/dxil.dll", "share/terminfo/ghostty.terminfo",
                         "share/ghostty/themes/Builtin Dark", "README.txt", "licenses/Ghostty-MIT.txt",
                         "licenses/THIRD-PARTY.txt", "licenses/ConPTY-MIT.txt", "licenses/Mesa-MIT.txt",
                         "licenses/LLVM-Apache-2.0-WITH-LLVM-exception.txt", "licenses/JetBrainsMono-OFL-1.1.txt",
                         "licenses/NotoSansCJK-OFL-1.1.txt", *(f"fonts/{name}" for name in release.WINDOWS_FONTS)):
            self.assertIn(relative, files)
        for skipped in ("ghostty-vt.dll", "ghostty-vt.pdb", "share/pkgconfig/libghostty-vt.pc", "include/ghostty/vt.h"):
            self.assertNotIn(skipped, files)
        self.assertIn("skipped bin/ghostty-vt.dll", self.stdout.getvalue())
        for target, data in self.fixtures.members.items():
            self.assertEqual((tree / target).read_bytes(), data)
        self.assertEqual((tree / "licenses/Ghostty-MIT.txt").read_bytes(), (ROOT / "LICENSE").read_bytes())
        readme = (tree / "README.txt").read_bytes()
        self.assertTrue(readme.startswith(b"\xef\xbb\xbf"))
        text = readme[3:].decode("utf-8")
        self.assertNotIn("\n", text.replace("\r\n", ""))
        for needle in (VS, "不是 Ghostty 官方发布", "not an\r\nofficial Ghostty release", pkg.installer_base(VS),
                       "GHOSTTY_GX_OPENGL=software", "Get-FileHash"):
            self.assertIn(needle, text)
        third_party = (tree / "licenses/THIRD-PARTY.txt").read_text(encoding="utf-8")
        for download in self.fixtures.downloads:
            self.assertIn(download.url, third_party)
            self.assertIn(download.sha256, third_party)

    def test_fork_themes_are_added_with_lf_unless_the_prefix_has_them(self):
        root = make_root(self.base / "themed", themes={"GX Mocha": b"# GX theme\r\nbackground = #1f1f28\r\n",
                                                       "Builtin Dark": b"from source\n"})
        tree = self.tree(windows_prefix(self.base), root=root)
        self.assertEqual((tree / "share/ghostty/themes/GX Mocha").read_bytes(), b"# GX theme\nbackground = #1f1f28\n")
        self.assertEqual((tree / "share/ghostty/themes/Builtin Dark").read_bytes(), b"background = #000000\n")
        self.assertEqual(pkg.source_themes(self.root), [])

    def test_prefix_problems_are_refused(self):
        cases = (
            ("missing exe", lambda prefix: (prefix / "bin/ghostty.exe").unlink(), "bin/ghostty.exe is missing"),
            ("not pe", lambda prefix: write(prefix / "bin/ghostty.exe", b"ELF?" + VS.encode()), "not a Windows PE"),
            ("arm64", lambda prefix: write(prefix / "bin/ghostty.exe", fake_pe(machine=0xAA64)), "not x86_64"),
            ("stale", lambda prefix: write(prefix / "bin/ghostty.exe", fake_pe(version="1.0.0-gx.0.0.1")),
             "does not embed the version string"),
            ("terminfo", lambda prefix: (prefix / "share/terminfo/ghostty.terminfo").unlink(), "ghostty.terminfo"),
            ("resources", lambda prefix: shutil.rmtree(prefix / "share/ghostty"), "share/ghostty/"),
            ("conflict", lambda prefix: write(prefix / "bin/conpty.dll", b"MZ other"), None),
            ("readme", lambda prefix: write(prefix / "bin/README.txt", b"readme"), None),
        )
        for index, (label, mutate, message) in enumerate(cases):
            with self.subTest(case=label):
                prefix = windows_prefix(self.base / f"case-{index}",
                                        imports=("conpty.dll", "README.txt") if label in ("conflict", "readme")
                                        else ("KERNEL32.dll", "helper.dll"))
                mutate(prefix)
                tree = self.base / f"tree-{index}"
                with self.assertRaisesRegex(pkg.PackageError, message or "packaging adds from a pinned source"):
                    pkg.build_tree(tree, prefix, VS, self.cache, root=self.root, seven_zip=self.fixtures.seven_zip,
                                   **self.common())
                self.assertFalse(tree.exists())

    def test_identical_pinned_file_in_the_prefix_is_accepted(self):
        prefix = windows_prefix(self.base, imports=("conpty.dll",))
        write(prefix / "bin/conpty.dll", self.fixtures.members["conpty.dll"])
        tree = self.tree(prefix)
        self.assertEqual((tree / "conpty.dll").read_bytes(), self.fixtures.members["conpty.dll"])

    @unittest.skipUnless(symlinks_supported(), "creating symlinks needs Developer Mode on Windows")
    def test_symlinks_in_the_prefix_are_refused(self):
        prefix = windows_prefix(self.base)
        os.symlink(prefix / "share/terminfo/ghostty.terminfo", prefix / "share/ghostty/link")
        with self.assertRaisesRegex(pkg.PackageError, "symlink"):
            self.tree(prefix)

    def test_tampered_archive_member_fails_closed(self):
        payload = [dataclasses.replace(item, sha256="1" * 64) if item.target == "mesa/dxil.dll" else item
                   for item in self.fixtures.payload]
        with self.assertRaisesRegex(pkg.PackageError, "mesa/dxil.dll has SHA-256"):
            pkg.build_tree(self.base / "tree", windows_prefix(self.base), VS, self.cache, root=self.root,
                           downloads=self.fixtures.downloads, payload=payload, fetcher=self.fixtures.fetcher,
                           seven_zip=self.fixtures.seven_zip)

    def test_case_collisions_are_refused(self):
        with self.assertRaisesRegex(pkg.PackageError, "case-insensitive"):
            pkg.check_collisions(["share/ghostty/themes/A", "share/ghostty/themes/a"])


class PackageTests(Case):
    def runner(self, calls: list, size: int = 8192, code: int = 0):
        def run(command, **kwargs):
            calls.append(command)
            defines = dict(arg[2:].split("=", 1) for arg in command if arg.startswith("/D"))
            if code == 0:
                write(Path(defines["GxOutput"]) / (defines["GxFilename"] + ".exe"), fake_pe()[:0x400].ljust(size, b"\0"))
                self.include = Path(defines["GxFonts"]).read_text(encoding="utf-8")
                self.app_files = sorted(path.relative_to(defines["GxApp"]).as_posix()
                                        for path in Path(defines["GxApp"]).rglob("*") if path.is_file())
            return subprocess.CompletedProcess(command, code)
        return run

    def package(self, **kwargs):
        options = dict(root=self.root, cache=self.cache, seven_zip=self.fixtures.seven_zip, **self.common())
        options.update(kwargs)
        return pkg.package(windows_prefix(self.base), VS, self.base / "out", **options)

    def test_zip_and_installer_satisfy_the_release_contract(self):
        calls: list = []
        iscc = write(self.base / "inno/ISCC.exe", b"MZ")
        outputs = self.package(iscc=str(iscc), runner=self.runner(calls))
        self.assertEqual([path.name for path in outputs], [pkg.zip_name(VS), pkg.installer_base(VS) + ".exe"])
        self.assertEqual(sorted(path.name for path in (self.base / "out").iterdir()), sorted(path.name for path in outputs))
        command = calls[0]
        self.assertEqual(command[0], str(iscc))
        self.assertEqual(command[-1], str(self.root / pkg.ISS))
        for define in (f"/DGxVersion={VS}", f"/DGxNumericVersion={pkg.numeric_version(VS)}",
                       f"/DGxFilename={pkg.installer_base(VS)}", f"/DGxIcon={self.root / pkg.ICON}",
                       f"/DGxOutput={(self.base / 'out').resolve()}"):
            self.assertIn(define, command)
        self.assertFalse(any(path.startswith("fonts/") for path in self.app_files))
        self.assertIn("ghostty.exe", self.app_files)
        lines = self.include.splitlines()
        self.assertEqual(len(lines), len(release.WINDOWS_FONTS))
        for line in lines:
            self.assertRegex(line, r'^Source: "[^"]+[\\/]fonts[\\/][^"]+"; DestDir: "\{autofonts\}"; '
                                   r'FontInstall: "[^"]+"; Flags: onlyifdoesntexist uninsneveruninstall$')
        self.assertIn('FontInstall: "JetBrainsMonoNerdFont Regular"', self.include)
        with zipfile.ZipFile(outputs[0]) as archive:
            names = archive.namelist()
            self.assertTrue(all(name.startswith(pkg.top_name(VS) + "/") for name in names))
            self.assertEqual(names, sorted(names))
            self.assertEqual({info.date_time for info in archive.infolist()}, {pkg.ZIP_TIMESTAMP})

    def test_zip_only_and_failures(self):
        outputs = self.package(skip_installer=True)
        self.assertEqual([path.name for path in outputs], [pkg.zip_name(VS)])
        release.check_asset(outputs[0], release.expected_assets(VS)[pkg.zip_name(VS)], VS)
        calls: list = []
        iscc = write(self.base / "inno/ISCC.exe", b"MZ")
        with self.assertRaisesRegex(pkg.PackageError, "ISCC failed"):
            self.package(iscc=str(iscc), runner=self.runner(calls, code=2))
        with self.assertRaisesRegex(pkg.PackageError, "below the 4096 byte minimum"):
            self.package(iscc=str(iscc), runner=self.runner(calls, size=1024))

    def test_missing_compiler_or_wrong_version_refuses_before_downloading(self):
        with mock.patch.dict(os.environ, {"ISCC": ""}), mock.patch.object(pkg.shutil, "which", return_value=None):
            with self.assertRaisesRegex(pkg.PackageError, "just setup --innosetup"):
                self.package()
            with self.assertRaisesRegex(pkg.PackageError, "differs from"):
                pkg.package(windows_prefix(self.base), "9.9.9-gx.9.9.9", self.base / "out", root=self.root,
                            skip_installer=True, **self.common())
        self.assertEqual(self.fixtures.requests, [])

    def test_iscc_lookup_order(self):
        local = write(self.root / ".local/tools/innosetup/ISCC.exe", b"MZ")
        explicit = write(self.base / "explicit/ISCC.exe", b"MZ")
        env = write(self.base / "env/ISCC.exe", b"MZ")
        with mock.patch.dict(os.environ, {"ISCC": str(env)}):
            self.assertEqual(pkg.find_iscc(str(explicit), self.root), explicit)
            self.assertEqual(pkg.find_iscc(None, self.root), env)
        with mock.patch.dict(os.environ, {"ISCC": ""}):
            self.assertEqual(pkg.find_iscc(None, self.root), local)
            with self.assertRaisesRegex(pkg.PackageError, "does not exist"):
                pkg.find_iscc(str(self.base / "missing.exe"), self.root)

    def test_build_flag_runs_the_release_build_first(self):
        calls: list = []

        def runner(command, **kwargs):
            calls.append((command, kwargs.get("cwd")))
            return subprocess.CompletedProcess(command, 0)

        self.package(skip_installer=True, build=True, runner=runner)
        command, cwd = calls[0]
        self.assertEqual(command[1:3], [str(self.root / "scripts" / "zigw.py"), "build"])
        for flag in ("-Dapp-runtime=win32", "-Dtarget=x86_64-windows-gnu", "-Doptimize=ReleaseFast",
                     f"-Dversion-string={VS}", "--prefix"):
            self.assertIn(flag, command)
        self.assertEqual(cwd, str(self.root))


class BinaryFormatTests(unittest.TestCase):
    def test_pe_imports_and_machine(self):
        with tempfile.TemporaryDirectory() as temp:
            path = write(Path(temp) / "a.exe", fake_pe(("KERNEL32.dll", "helper.dll")))
            self.assertEqual(pkg.pe_imports(path), ["KERNEL32.dll", "helper.dll"])
            self.assertEqual(pkg.pe_machine(path), 0x8664)
            self.assertTrue(pkg.contains(path, VS.encode()))
            write(path, b"MZ" + bytes(100))
            with self.assertRaises(pkg.PackageError):
                pkg.pe_imports(path)
            self.assertIsNone(pkg.pe_machine(path))

    def test_contains_finds_needles_across_chunk_boundaries(self):
        with tempfile.TemporaryDirectory() as temp:
            path = write(Path(temp) / "big.bin", b"x" * ((1 << 20) - 3) + b"needle" + b"y" * 10)
            self.assertTrue(pkg.contains(path, b"needle"))
            self.assertFalse(pkg.contains(path, b"missing"))

    def test_font_names_follow_wezterm_gx(self):
        with tempfile.TemporaryDirectory() as temp:
            ttf = write(Path(temp) / "a.ttf", sfnt("JetBrainsMono NF Regular"))
            ttc = write(Path(temp) / "b.ttc", sfnt("Noto Sans CJK JP", ttc=True))
            self.assertEqual(pkg.font_name(ttf), "JetBrainsMono NF Regular")
            self.assertEqual(pkg.font_name(ttc), "Noto Sans CJK JP")
            write(ttf, b"\0\1\0\0" + bytes(8))
            with self.assertRaises(pkg.PackageError):
                pkg.font_name(ttf)


class InstallerScriptTests(unittest.TestCase):
    text = (ROOT / pkg.ISS).read_text(encoding="utf-8")
    lines = [line.strip() for line in text.splitlines()]

    def setting(self, key: str) -> str:
        values = [line.split("=", 1)[1] for line in self.lines if line.startswith(key + "=")]
        self.assertEqual(len(values), 1, key)
        return values[0]

    def test_identity_scope_and_version(self):
        self.assertEqual(self.setting("AppId"), "{{49341A18-5070-425E-83B9-79E184242ACF}")
        self.assertEqual(self.setting("AppName"), "Ghostty GX")
        self.assertEqual(self.setting("DefaultDirName"), r"{autopf}\Ghostty GX")
        self.assertEqual(self.setting("PrivilegesRequired"), "lowest")
        self.assertEqual(self.setting("PrivilegesRequiredOverridesAllowed"), "dialog")
        self.assertEqual(self.setting("AppVersion"), "{#GxVersion}")
        self.assertEqual(self.setting("VersionInfoVersion"), "{#GxNumericVersion}")
        self.assertEqual(self.setting("OutputBaseFilename"), "{#GxFilename}")
        for define in ("GxVersion", "GxNumericVersion", "GxApp", "GxFonts", "GxIcon", "GxOutput", "GxFilename"):
            self.assertIn(f"#ifndef {define}", self.lines)
        self.assertIn("#if VER < EncodeVer(7, 1, 0) || VER >= EncodeVer(8, 0, 0)", self.lines)
        self.assertFalse(self.text.startswith("\ufeff"))

    def test_languages_tasks_files_and_shortcuts(self):
        self.assertIn('Name: "chinesesimplified"; MessagesFile: "compiler:Languages\\ChineseSimplified.isl"', self.lines)
        self.assertIn('Name: "english"; MessagesFile: "compiler:Default.isl"', self.lines)
        self.assertIn("chinesesimplified.OpenHere=在此处打开 Ghostty GX", self.lines)
        self.assertIn("english.OpenHere=Open Ghostty GX here", self.lines)
        self.assertIn('Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; '
                      'GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked', self.lines)
        self.assertTrue(any(line.startswith('Name: "contextmenu";') for line in self.lines))
        self.assertIn('Source: "{#GxApp}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs',
                      self.lines)
        self.assertIn("#include GxFonts", self.lines)
        self.assertTrue(any(line.startswith('Name: "{autoprograms}\\Ghostty GX"; Filename: "{app}\\ghostty.exe"')
                            for line in self.lines))
        self.assertTrue(any(line.startswith('Name: "{autodesktop}\\Ghostty GX"') and line.endswith("Tasks: desktopicon")
                            for line in self.lines))
        self.assertNotIn("[UninstallDelete]", self.text)

    def test_registry_app_paths_and_context_menu(self):
        registry = [line for line in self.lines if line.startswith("Root: ")]
        self.assertTrue(all(line.startswith("Root: HKA;") for line in registry))
        self.assertIn('Root: HKA; Subkey: "Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\ghostty.exe"; '
                      'ValueType: string; ValueData: "{app}\\ghostty.exe"; Flags: uninsdeletekey', registry)
        for key in ("Directory\\Background\\shell\\GhosttyGX", "Directory\\shell\\GhosttyGX"):
            with self.subTest(key=key):
                self.assertIn(f'Root: HKA; Subkey: "Software\\Classes\\{key}"; ValueType: string; '
                              'ValueData: "{cm:OpenHere}"; Flags: uninsdeletekey; Tasks: contextmenu', registry)
                self.assertIn(f'Root: HKA; Subkey: "Software\\Classes\\{key}\\command"; ValueType: string; '
                              'ValueData: """{app}\\ghostty.exe"" --working-directory=""%V"""; Tasks: contextmenu',
                              registry)


if __name__ == "__main__":
    unittest.main()
