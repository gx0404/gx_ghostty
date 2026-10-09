#!/usr/bin/env python3
"""Windows portable zip and Inno Setup installer for Ghostty GX (gx0404/gx_ghostty).

Inputs
  --prefix PREFIX         install prefix of `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
                          -Doptimize=ReleaseFast -Dversion-string=VS --prefix PREFIX` (default zig-out):
                          bin/ghostty.exe (x64 PE that embeds VS) and share/ with share/ghostty/ and
                          share/terminfo/ghostty.terminfo. bin/ DLLs that ghostty.exe imports ship
                          next to it; other bin/ files (ghostty-vt.dll, *.pdb), share/pkgconfig/ and
                          the other top-level entries (include/, lib/) are skipped.
  --version-string VS     <build.zig.zon X.Y.Z>-gx.<fork X.Y.Z>; defaults to, and must equal,
                          scripts/gx_release.py::ReleaseInfo.version_string of this checkout.
  --output-dir DIR        default zig-out/dist; existing outputs with the same names are replaced.
  --build                 first run that ReleaseFast win32 build into PREFIX via scripts/zigw.py.

Pinned third-party inputs (DOWNLOADS, PAYLOAD) are fetched once into the cache directory (--cache-dir,
else $GX_GHOSTTY_PACKAGE_CACHE, else .local/cache/gx-package; --offline never downloads). Every
download and every extracted file must match its SHA-256, otherwise packaging fails (fail closed):
  - Microsoft.Windows.Console.ConPTY 1.24.261001001 (NuGet, MIT): x64 conpty.dll and OpenConsole.exe,
    the pair src/gx/conpty.zig loads from the directory of ghostty.exe;
  - Mesa 26.2.4 llvmpipe from pal1000/mesa-dist-win (release-msvc .7z, extracted with Windows'
    built-in bsdtar, System32\\tar.exe): mesa/opengl32.dll and mesa/libgallium_wgl.dll (static CRT,
    system imports only) plus mesa/dxil.dll for Mesa's D3D12 driver; the app loads
    mesa\\opengl32.dll only as an OpenGL fallback (or with GHOSTTY_GX_OPENGL=software);
  - fonts, the ones Oh My Zsh GX also ships (gx/fonts/JetBrainsMonoNerd/) byte-identical to its
    copies, because GX Shell merges component fonts only when their bytes match: JetBrainsMono Nerd Font
    Regular/Bold/Italic/BoldItalic/SemiBold/SemiBoldItalic from the Nerd Fonts v3.4.0 release asset
    JetBrainsMono.tar.xz, and Noto Sans CJK Regular/Bold .ttc 2.001 from notofonts/noto-cjk tag
    NotoSansV2.001 (the files Ubuntu's fonts-noto-cjk installs as NotoSansCJK-*.ttc);
  - licenses: the fonts' OFL texts from those sources, plus the ConPTY MIT, Mesa MIT and LLVM
    Apache-2.0 WITH LLVM-exception texts committed under dist/windows/gx/licenses/ (pinned too).

Outputs
  ghostty-gx-VS-x86_64-windows.zip        one top directory ghostty-gx-VS-x86_64-windows/ holding
                                          ghostty.exe, conpty.dll, OpenConsole.exe, mesa/, share/
                                          (the prefix share/ tree; fork themes from src/gx/themes/,
                                          e.g. GX Mocha, are added to share/ghostty/themes/ with LF
                                          line endings unless the prefix has them), fonts/,
                                          licenses/ (with Ghostty-MIT.txt and THIRD-PARTY.txt) and a
                                          Chinese/English README.txt
  ghostty-gx-VS-x86_64-windows-setup.exe  Inno Setup 7.1 installer built from dist/windows/gx/ghostty-gx.iss:
                                          the same tree without fonts/ goes to {app}, the fonts are
                                          installed per user (skipped when already present, never
                                          uninstalled); --skip-installer omits it
Both outputs are checked against scripts/gx_release.py::expected_assets before success is reported.
ISCC comes from --iscc, $ISCC, .local/tools/innosetup/ISCC.exe (just setup --innosetup) or PATH.
scripts/gx_package.py builds the GX Shell Windows stage from the same tree (build_tree).

Exit codes: 0 success, 1 refused or failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_release  # noqa: E402  (scripts/gx_release.py)

ROOT = SCRIPTS.parent
PRODUCT = "ghostty-gx"
TARGET = gx_release.WINDOWS_APP_TARGET
ISS = Path("dist/windows/gx/ghostty-gx.iss")
ICON = Path("dist/windows/ghostty.ico")
THEMES = Path("src/gx/themes")
SKIPPED_SHARE = ("pkgconfig",)
CACHE_ENV = "GX_GHOSTTY_PACKAGE_CACHE"
VERSION_STRING_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-gx\.(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
PE_MACHINE_AMD64 = 0x8664
ZIP_TIMESTAMP = (2026, 1, 1, 0, 0, 0)
REPARSE_POINT = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
BUILD_FLAGS = ("-Dapp-runtime=win32", f"-Dtarget={TARGET}-gnu", "-Doptimize=ReleaseFast")
README = "README.txt"
FONTS_DIR = "fonts"


class PackageError(Exception):
    """Packaging was refused; the message says what to fix."""


@dataclass(frozen=True)
class Download:
    name: str
    url: str
    sha256: str
    size: int
    kind: str  # zip | tar.xz | 7z | file
    component: str
    license: str


@dataclass(frozen=True)
class Payload:
    target: str
    source: str  # a Download.name, or "repo" for a file committed in this repository
    member: str  # archive member, repository path, or "" for a plain file download
    sha256: str


CONPTY = "microsoft.windows.console.conpty.1.24.261001001.nupkg"
MESA = "mesa3d-26.2.4-release-msvc.7z"
NERD_FONTS = "nerd-fonts-v3.4.0-JetBrainsMono.tar.xz"
NOTO_REGULAR = "noto-cjk-NotoSansV2.001-NotoSansCJK-Regular.ttc"
NOTO_BOLD = "noto-cjk-NotoSansV2.001-NotoSansCJK-Bold.ttc"
NOTO_LICENSE = "noto-cjk-NotoSansV2.001-LICENSE"
NOTO_RAW = "https://raw.githubusercontent.com/notofonts/noto-cjk/cf29231ab8029678af4bbc1a9480e2b296a5b2d3"
REPO = "repo"

DOWNLOADS = (
    Download(
        CONPTY,
        "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/1.24.261001001/"
        "microsoft.windows.console.conpty.1.24.261001001.nupkg",
        "4d6aaddc1d2385c9f5897df28f33879f699f8f2783315d5204cf3d8c3616ac5f", 1733607, "zip",
        "Microsoft.Windows.Console.ConPTY 1.24.261001001 (NuGet)", "MIT (licenses/ConPTY-MIT.txt)",
    ),
    Download(
        MESA,
        "https://github.com/pal1000/mesa-dist-win/releases/download/26.2.4/mesa3d-26.2.4-release-msvc.7z",
        "351fc8c8b695878ffb3eaa044b3ead08672a48b1a045e3c3e3975811df0f6695", 70257286, "7z",
        "Mesa 26.2.4 llvmpipe (pal1000/mesa-dist-win release-msvc build; dxil.dll is Microsoft's DXIL "
        "library as redistributed by that build, used only by Mesa's D3D12 driver)",
        "MIT (licenses/Mesa-MIT.txt); statically linked LLVM: Apache-2.0 WITH LLVM-exception "
        "(licenses/LLVM-Apache-2.0-WITH-LLVM-exception.txt)",
    ),
    Download(
        NERD_FONTS,
        "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.tar.xz",
        "ef552a3e638f25125c6ad4c51176a6adcdce295ab1d2ffacf0db060caf8c1582", 6217644, "tar.xz",
        "JetBrainsMono Nerd Font (Nerd Fonts v3.4.0, JetBrains Mono 2.304)", "OFL-1.1 (licenses/JetBrainsMono-OFL-1.1.txt)",
    ),
    Download(
        NOTO_REGULAR, f"{NOTO_RAW}/NotoSansCJK-Regular.ttc",
        "5dcd1c336cc9344cb77c03a0cd8982ca8a7dc97d620fd6c9c434e02dcb1ceeb3", 20332392, "file",
        "Noto Sans CJK Regular 2.001 (notofonts/noto-cjk tag NotoSansV2.001)", "OFL-1.1 (licenses/NotoSansCJK-OFL-1.1.txt)",
    ),
    Download(
        NOTO_BOLD, f"{NOTO_RAW}/NotoSansCJK-Bold.ttc",
        "0c066cc1f22541fd9e138190de26dc480a4b8221bef5321e27e7b7802b26ee5e", 20930832, "file",
        "Noto Sans CJK Bold 2.001 (notofonts/noto-cjk tag NotoSansV2.001)", "OFL-1.1 (licenses/NotoSansCJK-OFL-1.1.txt)",
    ),
    Download(
        NOTO_LICENSE, f"{NOTO_RAW}/LICENSE",
        "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2", 4301, "file",
        "Noto Sans CJK license (notofonts/noto-cjk tag NotoSansV2.001)", "OFL-1.1",
    ),
)

PAYLOAD = (
    Payload("conpty.dll", CONPTY, "runtimes/win-x64/native/conpty.dll",
            "5afea6c9480e2c7dfd195376dd10996b0ae25cdc6f014e6247fd8aedc8c34852"),
    Payload("OpenConsole.exe", CONPTY, "build/native/runtimes/x64/OpenConsole.exe",
            "6f8e68dec4e8e5e15a54ecc8afa127b0e62139edc004ffbb4892125ff01d5737"),
    Payload("mesa/opengl32.dll", MESA, "x64/opengl32.dll",
            "75b295fc80df0eaa8f1264c28663f6932c8b72d36513eb092556608858b7f5e0"),
    Payload("mesa/libgallium_wgl.dll", MESA, "x64/libgallium_wgl.dll",
            "53e49adf87590d5b0cab8553b1e98084812040cc1fca8c487695b17b7af3702e"),
    Payload("mesa/dxil.dll", MESA, "x64/dxil.dll",
            "64be2368211d257a038a7d4ea6bb3e24c878eb8d588c7b8414fccf759b69c2ac"),
    Payload("fonts/JetBrainsMonoNerdFont-Regular.ttf", NERD_FONTS, "JetBrainsMonoNerdFont-Regular.ttf",
            "0ec29a68b539ece7078fc714cebff0c0accb2f4948f8f7963d9f5e86633b12d9"),
    Payload("fonts/JetBrainsMonoNerdFont-Bold.ttf", NERD_FONTS, "JetBrainsMonoNerdFont-Bold.ttf",
            "e82e27a7f37c9a0a13cc4e417503a149c6a0280586930772d2ebed803159c864"),
    Payload("fonts/JetBrainsMonoNerdFont-Italic.ttf", NERD_FONTS, "JetBrainsMonoNerdFont-Italic.ttf",
            "981133a258ef4c62769a7a7214a4b455ac1c63923784a70f50c48977b67f7025"),
    Payload("fonts/JetBrainsMonoNerdFont-BoldItalic.ttf", NERD_FONTS, "JetBrainsMonoNerdFont-BoldItalic.ttf",
            "961222be7bce59f310b41a3e158368d5ea22a47a0ac31defd57caac9b9e82cb0"),
    Payload("fonts/JetBrainsMonoNerdFont-SemiBold.ttf", NERD_FONTS, "JetBrainsMonoNerdFont-SemiBold.ttf",
            "1d28a687259870de46378bf83e511d9c85136c597db678e6c4953b2731e55c72"),
    Payload("fonts/JetBrainsMonoNerdFont-SemiBoldItalic.ttf", NERD_FONTS, "JetBrainsMonoNerdFont-SemiBoldItalic.ttf",
            "0647c1d105ce061fae5cb772e8ee0fdec9b814725d7dc141545d9fb7b24fe0ba"),
    Payload("fonts/NotoSansCJK-Regular.ttc", NOTO_REGULAR, "",
            "5dcd1c336cc9344cb77c03a0cd8982ca8a7dc97d620fd6c9c434e02dcb1ceeb3"),
    Payload("fonts/NotoSansCJK-Bold.ttc", NOTO_BOLD, "",
            "0c066cc1f22541fd9e138190de26dc480a4b8221bef5321e27e7b7802b26ee5e"),
    Payload("licenses/JetBrainsMono-OFL-1.1.txt", NERD_FONTS, "OFL.txt",
            "30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad"),
    Payload("licenses/NotoSansCJK-OFL-1.1.txt", NOTO_LICENSE, "",
            "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"),
    Payload("licenses/ConPTY-MIT.txt", REPO, "dist/windows/gx/licenses/ConPTY-MIT.txt",
            "ad0cf28f3381ca9bb0bf101d127402d44c17bfa0991e1a00bff7ae6679e9dada"),
    Payload("licenses/Mesa-MIT.txt", REPO, "dist/windows/gx/licenses/Mesa-MIT.txt",
            "323c587d0ccf10e376f8bf9a7f31fb4ca6078105194b42e0b1e0ee2bc9bde71f"),
    Payload("licenses/LLVM-Apache-2.0-WITH-LLVM-exception.txt", REPO,
            "dist/windows/gx/licenses/LLVM-Apache-2.0-WITH-LLVM-exception.txt",
            "3340babe8ac7bc6ae294d93aa01c310a250d43d5b760e5c12954882d4e5c83c7"),
)

GENERATED = ("licenses/Ghostty-MIT.txt", "licenses/THIRD-PARTY.txt", README)

Fetcher = Callable[[Download, Path], Path]
SevenZip = Callable[[Path, dict[str, Path]], None]
Runner = Callable[..., "subprocess.CompletedProcess"]


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def zip_name(version_string: str) -> str:
    return f"{PRODUCT}-{version_string}-{TARGET}.zip"


def installer_base(version_string: str) -> str:
    return f"{PRODUCT}-{version_string}-{TARGET}-setup"


def top_name(version_string: str) -> str:
    return f"{PRODUCT}-{version_string}-{TARGET}"


def font_payload(payload: Iterable[Payload] = PAYLOAD) -> list[Payload]:
    return [item for item in payload if item.target.startswith(FONTS_DIR + "/")]


def check_version_string(version_string: str, root: Path = ROOT) -> str:
    if not VERSION_STRING_RE.match(version_string or ""):
        raise PackageError(f"version string {version_string!r} is not <X.Y.Z>-gx.<X.Y.Z>")
    try:
        expected = gx_release.release_info(root).version_string
    except gx_release.ReleaseError as error:
        raise PackageError(str(error)) from error
    if version_string != expected:
        raise PackageError(f"version string {version_string} differs from {expected} derived from this checkout")
    return version_string


def numeric_version(version_string: str) -> str:
    match = VERSION_STRING_RE.match(version_string)
    if not match:
        raise PackageError(f"version string {version_string!r} is not <X.Y.Z>-gx.<X.Y.Z>")
    return ".".join([*match.group(1, 2, 3), "0"])


def cache_dir(explicit: Path | None = None, root: Path = ROOT) -> Path:
    if explicit is not None:
        return Path(explicit)
    configured = os.environ.get(CACHE_ENV, "").strip()
    return Path(configured) if configured else Path(root) / ".local" / "cache" / "gx-package"


def fetch(
    download: Download,
    cache: Path,
    *,
    offline: bool = False,
    urlopen: Callable[..., object] = urllib.request.urlopen,
    attempts: int = 3,
    sleep: Callable[[float], None] = time.sleep,
) -> Path:
    """Return the cached download, fetching it when missing; a SHA-256 mismatch is never kept."""
    path = Path(cache) / download.name
    if path.is_file() and not path.is_symlink():
        if digest(path) == download.sha256:
            return path
        print(f"cache entry {path} does not match its pinned SHA-256; fetching it again")
        path.unlink()
    elif path.exists() or path.is_symlink():
        raise PackageError(f"cache entry {path} is not a regular file; remove it")
    if offline:
        raise PackageError(f"--offline: {download.name} is not in the cache {cache}")
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".part")
    request = urllib.request.Request(download.url, headers={"User-Agent": "gx_ghostty-packaging"})
    for attempt in range(1, attempts + 1):
        print(f"fetching {download.url} ({download.size} bytes, attempt {attempt}/{attempts})", flush=True)
        try:
            with urlopen(request, timeout=120) as response, partial.open("wb") as stream:
                shutil.copyfileobj(response, stream, 1 << 20)
            break
        except (OSError, ValueError) as error:
            partial.unlink(missing_ok=True)
            if attempt == attempts:
                raise PackageError(f"cannot download {download.url}: {error}") from error
            sleep(5.0 * attempt)
    size = partial.stat().st_size
    actual = digest(partial)
    if size != download.size or actual != download.sha256:
        partial.unlink(missing_ok=True)
        raise PackageError(
            f"{download.url} has {size} bytes and SHA-256 {actual}, pinned {download.size} bytes and "
            f"{download.sha256}; the download was discarded"
        )
    os.replace(partial, path)
    return path


def bsdtar() -> str:
    if os.name == "nt":
        system = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "tar.exe"
        if system.is_file():
            return str(system)
    found = shutil.which("bsdtar")
    if found:
        return found
    raise PackageError("extracting the Mesa .7z needs bsdtar: Windows' System32\\tar.exe or libarchive's bsdtar")


def extract_7z(archive: Path, members: dict[str, Path], runner: Runner = subprocess.run) -> None:
    with tempfile.TemporaryDirectory(prefix="gx-7z-") as temp:
        command = [bsdtar(), "-xf", str(archive), "-C", temp, *members]
        result = runner(command, capture_output=True, text=True, errors="replace", check=False)
        if result.returncode != 0:
            raise PackageError(f"bsdtar could not extract {archive.name} (exit {result.returncode}): "
                               f"{(result.stderr or '').strip()}")
        for member, destination in members.items():
            extracted = Path(temp, *member.split("/"))
            if extracted.is_symlink() or not extracted.is_file():
                raise PackageError(f"{archive.name} has no regular file {member}")
            shutil.move(str(extracted), str(destination))


def copy_member(archive: Path, kind: str, member: str, destination: Path) -> None:
    if kind == "file":
        shutil.copyfile(archive, destination)
    elif kind == "zip":
        with zipfile.ZipFile(archive) as bundle:
            try:
                info = bundle.getinfo(member)
            except KeyError:
                raise PackageError(f"{archive.name} has no member {member}") from None
            with bundle.open(info) as source, destination.open("xb") as target:
                shutil.copyfileobj(source, target, 1 << 20)
    elif kind == "tar.xz":
        with tarfile.open(archive, "r:xz") as bundle:
            try:
                info = bundle.getmember(member)
            except KeyError:
                raise PackageError(f"{archive.name} has no member {member}") from None
            source = bundle.extractfile(info) if info.isfile() else None
            if source is None:
                raise PackageError(f"{archive.name} member {member} is not a regular file")
            with source, destination.open("xb") as target:
                shutil.copyfileobj(source, target, 1 << 20)
    else:
        raise PackageError(f"unsupported archive kind {kind!r} for {archive.name}")


def materialize(
    tree: Path,
    cache: Path,
    *,
    downloads: Iterable[Download] = DOWNLOADS,
    payload: Iterable[Payload] = PAYLOAD,
    root: Path = ROOT,
    offline: bool = False,
    fetcher: Fetcher | None = None,
    seven_zip: SevenZip = extract_7z,
) -> None:
    """Write every pinned payload file below tree and check its SHA-256."""
    by_name = {item.name: item for item in downloads}
    items = list(payload)
    fetched: dict[str, Path] = {}
    for item in items:
        if item.source != REPO and item.source not in fetched:
            if item.source not in by_name:
                raise PackageError(f"payload {item.target} names an unknown download {item.source}")
            download = by_name[item.source]
            fetched[item.source] = (fetcher(download, cache) if fetcher is not None
                                    else fetch(download, cache, offline=offline))
    pending_7z: dict[str, dict[str, Path]] = {}
    for item in items:
        destination = tree / item.target
        if destination.exists() or destination.is_symlink():
            raise PackageError(f"payload target {item.target} already exists in the staged tree")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if item.source == REPO:
            source = Path(root) / item.member
            if source.is_symlink() or not source.is_file():
                raise PackageError(f"missing repository file {item.member}")
            shutil.copyfile(source, destination)
            continue
        kind = by_name[item.source].kind
        if kind == "7z":
            pending_7z.setdefault(item.source, {})[item.member] = destination
        else:
            copy_member(fetched[item.source], kind, item.member, destination)
    for source, members in pending_7z.items():
        seven_zip(fetched[source], members)
    for item in items:
        actual = digest(tree / item.target)
        if actual != item.sha256:
            (tree / item.target).unlink()
            raise PackageError(f"{item.target} has SHA-256 {actual}, pinned {item.sha256}")


def pe_machine(path: Path) -> int | None:
    with Path(path).open("rb") as stream:
        header = stream.read(64)
        if len(header) < 64 or header[:2] != b"MZ":
            return None
        stream.seek(struct.unpack_from("<I", header, 60)[0])
        signature = stream.read(6)
    if len(signature) < 6 or signature[:4] != b"PE\0\0":
        return None
    return struct.unpack_from("<H", signature, 4)[0]


def pe_imports(path: Path) -> list[str]:
    """DLL names from the import and delay-import tables of a PE image."""
    data = Path(path).read_bytes()
    try:
        header = struct.unpack_from("<I", data, 60)[0]
        if data[:2] != b"MZ" or data[header:header + 4] != b"PE\0\0":
            raise PackageError(f"{path} is not a PE image")
        sections, optional_size = struct.unpack_from("<H", data, header + 6)[0], struct.unpack_from("<H", data, header + 20)[0]
        optional = header + 24
        directories = optional + (112 if struct.unpack_from("<H", data, optional)[0] == 0x20B else 96)
        table = optional + optional_size
        spans = [struct.unpack_from("<IIII", data, table + index * 40 + 8) for index in range(sections)]

        def offset(rva: int) -> int:
            for virtual_size, address, raw_size, raw in spans:
                if address <= rva < address + max(virtual_size, raw_size):
                    return rva - address + raw
            raise PackageError(f"{path}: RVA {rva:#x} is outside every section")

        def name_at(rva: int) -> str:
            start = offset(rva)
            return data[start:data.index(b"\0", start)].decode("ascii")

        names = []
        for slot, stride, name_field in ((1, 20, 12), (13, 32, 4)):
            rva = struct.unpack_from("<I", data, directories + slot * 8)[0]
            position = offset(rva) if rva else None
            while position is not None:
                name_rva = struct.unpack_from("<I", data, position + name_field)[0]
                if name_rva == 0:
                    break
                names.append(name_at(name_rva))
                position += stride
        return names
    except (struct.error, ValueError, UnicodeDecodeError) as error:
        raise PackageError(f"{path} has an unreadable import table: {error}") from error


def contains(path: Path, needle: bytes) -> bool:
    tail = b""
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            if needle in tail + chunk:
                return True
            tail = chunk[-(len(needle) - 1):] if len(needle) > 1 else b""
    return False


def plain_file(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise PackageError(f"{label} is missing") from None
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & REPARSE_POINT:
        raise PackageError(f"{label} is a symlink or reparse point")
    if not stat.S_ISREG(info.st_mode):
        raise PackageError(f"{label} is not a regular file")


def plain_dir(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise PackageError(f"{label} is missing") from None
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & REPARSE_POINT:
        raise PackageError(f"{label} is a symlink or reparse point")
    if not stat.S_ISDIR(info.st_mode):
        raise PackageError(f"{label} is not a directory")


def walk_files(base: Path, label: str) -> list[tuple[str, Path]]:
    """Regular files below base as (posix relative path, path); links and special files are refused."""
    found: list[tuple[str, Path]] = []
    for current, directories, files in os.walk(base):
        current_path = Path(current)
        for name in sorted(directories):
            plain_dir(current_path / name, f"{label}/{(current_path / name).relative_to(base).as_posix()}")
        directories.sort()
        for name in sorted(files):
            path = current_path / name
            relative = path.relative_to(base).as_posix()
            plain_file(path, f"{label}/{relative}")
            found.append((relative, path))
    return found


def check_binary(path: Path, version_string: str) -> None:
    plain_file(path, "bin/ghostty.exe")
    machine = pe_machine(path)
    if machine is None:
        raise PackageError(f"{path} is not a Windows PE executable")
    if machine != PE_MACHINE_AMD64:
        raise PackageError(f"{path} targets PE machine {machine:#06x}, not x86_64 ({PE_MACHINE_AMD64:#06x})")
    if not contains(path, version_string.encode("ascii")):
        raise PackageError(f"{path} does not embed the version string {version_string}; "
                           "rebuild with -Dversion-string=" + version_string)


def prefix_files(prefix: Path, version_string: str) -> list[tuple[str, Path]]:
    """Map the install prefix to portable-tree paths: ghostty.exe and the bin/ DLLs it imports to
    the top level, share/ unchanged except the libghostty-vt pkg-config files."""
    prefix = Path(prefix)
    plain_dir(prefix, f"prefix {prefix}")
    exe = prefix / "bin" / "ghostty.exe"
    check_binary(exe, version_string)
    plain_dir(prefix / "share", "share/")
    terminfo = prefix / "share" / "terminfo" / "ghostty.terminfo"
    if not terminfo.is_file() or terminfo.stat().st_size == 0:
        raise PackageError("share/terminfo/ghostty.terminfo is missing or empty in the prefix")
    if not any(path.is_file() for path in (prefix / "share" / "ghostty").rglob("*")):
        raise PackageError("share/ghostty/ (themes, shell integration) is missing or empty in the prefix")
    imported = {name.casefold() for name in pe_imports(exe)}
    files: list[tuple[str, Path]] = [("ghostty.exe", exe)]
    for relative, path in walk_files(prefix / "bin", "bin"):
        if relative == "ghostty.exe":
            continue
        if "/" not in relative and relative.casefold() in imported:
            files.append((relative, path))
        else:
            print(f"skipped bin/{relative} (ghostty.exe does not import it)")
    for relative, path in walk_files(prefix / "share", "share"):
        if relative.split("/")[0] in SKIPPED_SHARE:
            continue
        files.append((f"share/{relative}", path))
    for entry in sorted(prefix.iterdir(), key=lambda item: item.name):
        if entry.name not in ("bin", "share"):
            print(f"skipped prefix entry {entry.name} (only bin/ and share/ are packaged)")
    return files


def source_themes(root: Path = ROOT) -> list[tuple[str, bytes]]:
    """Fork themes (src/gx/themes/*, e.g. GX Mocha) as share/ghostty/themes entries with LF line endings."""
    directory = Path(root) / THEMES
    if not directory.is_dir():
        return []
    themes = []
    for relative, path in walk_files(directory, THEMES.as_posix()):
        if "/" in relative:
            raise PackageError(f"{THEMES.as_posix()}/{relative}: theme subdirectories are not supported")
        themes.append((f"share/ghostty/themes/{relative}", path.read_bytes().replace(b"\r\n", b"\n")))
    return themes


def check_collisions(relatives: Iterable[str]) -> None:
    seen: dict[str, str] = {}
    for relative in relatives:
        folded = relative.casefold()
        if folded in seen:
            raise PackageError(f"{relative} collides with {seen[folded]} (paths are case-insensitive on Windows)")
        seen[folded] = relative


def third_party(downloads: Iterable[Download] = DOWNLOADS, payload: Iterable[Payload] = PAYLOAD) -> str:
    items = list(payload)
    lines = ["Third-party components / 第三方组件", ""]
    for download in downloads:
        shipped = [item for item in items if item.source == download.name]
        if not shipped:
            continue
        lines += [
            download.component,
            f"  license: {download.license}",
            f"  source:  {download.url}",
            f"  sha256:  {download.sha256}",
        ]
        lines += [f"  {item.target}  sha256 {item.sha256}" for item in shipped]
        lines.append("")
    return "\n".join(lines)


def readme(version_string: str) -> str:
    setup = installer_base(version_string) + ".exe"
    text = f"""Ghostty GX {version_string}（Windows x64）

Ghostty GX 是 gx0404 维护的 Ghostty 分支（https://github.com/gx0404/gx_ghostty），不是 Ghostty 官方发布。

使用
- 运行 ghostty.exe 启动终端。便携版整个目录可以放在任何位置，不写注册表。
- fonts\\：JetBrainsMono Nerd Font 与 Noto Sans CJK。便携版不安装字体，需要时双击字体文件安装；
  安装包 {setup} 会把它们按用户安装（已有同名字体时跳过）。
- conpty.dll、OpenConsole.exe：微软 Microsoft.Windows.Console.ConPTY 1.24.261001001，提供比系统自带
  更新的 ConPTY。
- mesa\\：Mesa llvmpipe 软件渲染，只在系统驱动建不出 OpenGL 4.3 上下文时作为后备加载；
  设置环境变量 GHOSTTY_GX_OPENGL=software 可强制使用。
- 日志：%LOCALAPPDATA%\\ghostty\\logs\\ghostty.log。
- share\\ghostty：主题、shell 集成等资源；share\\terminfo：terminfo 源文件。
- licenses\\：Ghostty 与随附第三方组件的许可证，来源与 SHA-256 见 licenses\\THIRD-PARTY.txt。
- 发布页的 SHA256SUMS 可用 PowerShell 校验：Get-FileHash <文件> -Algorithm SHA256。

Ghostty GX {version_string} (Windows x64)

Ghostty GX is the Ghostty fork maintained by gx0404 (https://github.com/gx0404/gx_ghostty); it is not an
official Ghostty release.

Usage
- Run ghostty.exe. The portable directory can live anywhere and writes nothing to the registry.
- fonts\\: JetBrainsMono Nerd Font and Noto Sans CJK. The portable build does not install fonts;
  double-click a font file to install it. The installer {setup} installs them per user
  (skipping fonts that already exist).
- conpty.dll, OpenConsole.exe: Microsoft.Windows.Console.ConPTY 1.24.261001001, a newer ConPTY than
  the one built into Windows.
- mesa\\: Mesa llvmpipe software rendering, loaded only as a fallback when the system driver cannot
  create an OpenGL 4.3 context; set GHOSTTY_GX_OPENGL=software to force it.
- Log file: %LOCALAPPDATA%\\ghostty\\logs\\ghostty.log.
- share\\ghostty: themes, shell integration and other resources; share\\terminfo: terminfo source.
- licenses\\: licenses of Ghostty and the bundled third-party components; licenses\\THIRD-PARTY.txt
  lists their sources and SHA-256 digests.
- Check downloads against SHA256SUMS from the release page: Get-FileHash <file> -Algorithm SHA256.
"""
    return text.replace("\n", "\r\n")


def build_tree(
    tree: Path,
    prefix: Path,
    version_string: str,
    cache: Path,
    *,
    root: Path = ROOT,
    downloads: Iterable[Download] = DOWNLOADS,
    payload: Iterable[Payload] = PAYLOAD,
    offline: bool = False,
    fetcher: Fetcher | None = None,
    seven_zip: SevenZip = extract_7z,
) -> None:
    """Stage the complete portable directory (the zip's top directory) into the new directory tree."""
    downloads, payload = list(downloads), list(payload)
    pinned = {item.target: item.sha256 for item in payload}
    files = []
    for relative, source in prefix_files(prefix, version_string):
        if relative in pinned and digest(source) == pinned[relative]:
            continue
        if relative in pinned or relative in GENERATED or relative.split("/")[0] in ("fonts", "licenses", "mesa"):
            raise PackageError(f"the prefix provides {relative}, which packaging adds from a pinned source itself")
        files.append((relative, source))
    provided = {relative for relative, _ in files}
    themes = [(relative, data) for relative, data in source_themes(root) if relative not in provided]
    check_collisions([*provided, *(relative for relative, _ in themes), *pinned, *GENERATED])
    tree.mkdir(parents=True)
    for relative, source in files:
        destination = tree / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    for relative, data in themes:
        (tree / relative).parent.mkdir(parents=True, exist_ok=True)
        (tree / relative).write_bytes(data)
    materialize(tree, cache, downloads=downloads, payload=payload, root=root, offline=offline,
                fetcher=fetcher, seven_zip=seven_zip)
    license_text = Path(root) / "LICENSE"
    if not license_text.is_file():
        raise PackageError(f"missing {license_text}")
    shutil.copyfile(license_text, tree / "licenses" / "Ghostty-MIT.txt")
    (tree / "licenses" / "THIRD-PARTY.txt").write_bytes(third_party(downloads, payload).encode("utf-8"))
    (tree / README).write_bytes(b"\xef\xbb\xbf" + readme(version_string).encode("utf-8"))


def write_zip(tree: Path, top: str, destination: Path) -> Path:
    entries = sorted(walk_files(tree, top), key=lambda entry: entry[0])
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for relative, path in entries:
            info = zipfile.ZipInfo(f"{top}/{relative}", date_time=ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            info.file_size = path.stat().st_size
            with path.open("rb") as source, archive.open(info, "w") as target:
                shutil.copyfileobj(source, target, 1 << 20)
    os.replace(partial, destination)
    return destination


def font_name(path: Path) -> str:
    """Full name (name ID 4) of the first face, preferring US English: the name Inno Setup's FontInstall
    registers the font under, as Explorer shows it for the file."""
    data = Path(path).read_bytes()
    try:
        base = struct.unpack_from(">I", data, 12)[0] if data[:4] == b"ttcf" else 0
        count = struct.unpack_from(">H", data, base + 4)[0]
        for index in range(count):
            position = base + 12 + index * 16
            if data[position:position + 4] != b"name":
                continue
            table = struct.unpack_from(">I", data, position + 8)[0]
            _, records, strings = struct.unpack_from(">HHH", data, table)
            candidates = []
            for record in range(records):
                platform, _, language, ident, length, offset = struct.unpack_from(
                    ">6H", data, table + 6 + record * 12)
                if ident == 4 and platform in (0, 3):
                    start = table + strings + offset
                    candidates.append((language == 0x409, data[start:start + length].decode("utf-16-be")))
            if candidates:
                return sorted(candidates, reverse=True)[0][1]
    except (struct.error, UnicodeDecodeError) as error:
        raise PackageError(f"{path.name} has an unreadable name table: {error}") from error
    raise PackageError(f"{path.name} has no full font name (name ID 4)")


def fonts_include(fonts: Path) -> str:
    lines = []
    for path in sorted(fonts.iterdir(), key=lambda item: item.name):
        name = font_name(path).replace('"', '""')
        lines.append(f'Source: "{path}"; DestDir: "{{autofonts}}"; FontInstall: "{name}"; '
                     "Flags: onlyifdoesntexist uninsneveruninstall")
    return "\n".join(lines) + "\n"


def find_iscc(explicit: str | None = None, root: Path = ROOT) -> Path:
    candidates = [explicit, os.environ.get("ISCC"), str(Path(root) / ".local" / "tools" / "innosetup" / "ISCC.exe")]
    for candidate in candidates[:2]:
        if candidate:
            if not Path(candidate).is_file():
                raise PackageError(f"ISCC {candidate} does not exist")
            return Path(candidate)
    if Path(candidates[2]).is_file():
        return Path(candidates[2])
    found = shutil.which("iscc")
    if found:
        return Path(found)
    raise PackageError("Inno Setup 7.1 is required for the installer: run `just setup --innosetup` "
                       "(installs into .local/tools/innosetup) or pass --skip-installer")


def build_installer(
    tree: Path,
    fonts: Path,
    work: Path,
    output: Path,
    version_string: str,
    iscc: Path,
    *,
    root: Path = ROOT,
    runner: Runner = subprocess.run,
) -> Path:
    include = work / "fonts.iss"
    include.write_bytes(fonts_include(fonts).encode("utf-8"))
    base = installer_base(version_string)
    destination = output / f"{base}.exe"
    command = [
        str(iscc), "/Qp",
        f"/DGxVersion={version_string}",
        f"/DGxNumericVersion={numeric_version(version_string)}",
        f"/DGxApp={tree}",
        f"/DGxFonts={include}",
        f"/DGxIcon={Path(root) / ICON}",
        f"/DGxOutput={output}",
        f"/DGxFilename={base}",
        str(Path(root) / ISS),
    ]
    print("$ " + subprocess.list2cmdline(command), flush=True)
    result = runner(command, check=False)
    if result.returncode != 0:
        raise PackageError(f"ISCC failed with exit code {result.returncode}")
    if not destination.is_file():
        raise PackageError(f"ISCC did not produce {destination}")
    return destination


def verify_outputs(paths: Iterable[Path], version_string: str) -> None:
    expected = gx_release.expected_assets(version_string)
    for path in paths:
        asset = expected.get(path.name)
        if asset is None:
            raise PackageError(f"{path.name} is not a gx-release asset name")
        try:
            gx_release.regular_file(path)
            gx_release.check_asset(path, asset, version_string)
        except gx_release.ReleaseError as error:
            raise PackageError(str(error)) from error


def run_build(prefix: Path, version_string: str, root: Path = ROOT, runner: Runner = subprocess.run) -> None:
    command = [sys.executable, str(Path(root) / "scripts" / "zigw.py"), "build", *BUILD_FLAGS,
               f"-Dversion-string={version_string}", "--prefix", str(prefix)]
    print("$ " + subprocess.list2cmdline(command), flush=True)
    result = runner(command, cwd=str(root), check=False)
    if result.returncode != 0:
        raise PackageError(f"zig build failed with exit code {result.returncode}")


def package(
    prefix: Path,
    version_string: str,
    output: Path,
    *,
    root: Path = ROOT,
    cache: Path | None = None,
    iscc: str | None = None,
    skip_installer: bool = False,
    offline: bool = False,
    build: bool = False,
    downloads: Iterable[Download] = DOWNLOADS,
    payload: Iterable[Payload] = PAYLOAD,
    fetcher: Fetcher | None = None,
    seven_zip: SevenZip = extract_7z,
    runner: Runner = subprocess.run,
) -> list[Path]:
    version_string = check_version_string(version_string, root)
    compiler = None if skip_installer else find_iscc(iscc, root)
    cache = cache_dir(cache, root)
    downloads, payload = list(downloads), list(payload)
    by_name = {item.name: item for item in downloads}
    for name in dict.fromkeys(item.source for item in payload if item.source != REPO):
        if name not in by_name:
            raise PackageError(f"payload names an unknown download {name}")
        if fetcher is not None:
            fetcher(by_name[name], cache)
        else:
            fetch(by_name[name], cache, offline=offline)
    if build:
        run_build(prefix, version_string, root, runner)
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    outputs = []
    with tempfile.TemporaryDirectory(prefix="gx-windows-package-") as temp:
        work = Path(temp)
        top = top_name(version_string)
        tree = work / top
        build_tree(tree, prefix, version_string, cache, root=root, downloads=downloads, payload=payload,
                   offline=True if fetcher is None else offline, fetcher=fetcher, seven_zip=seven_zip)
        outputs.append(write_zip(tree, top, output / zip_name(version_string)))
        if compiler is not None:
            fonts = work / FONTS_DIR
            shutil.move(str(tree / FONTS_DIR), str(fonts))
            outputs.append(build_installer(tree, fonts, work, output, version_string, compiler,
                                           root=root, runner=runner))
    verify_outputs(outputs, version_string)
    for path in outputs:
        print(f"PASS {path} ({path.stat().st_size} bytes, sha256 {digest(path)})")
    return outputs


def _utf8_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (OSError, ValueError):
                pass


def main(argv: list[str] | None = None) -> int:
    _utf8_stdio()
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog=__doc__.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--prefix", type=Path, default=ROOT / "zig-out", help="install prefix (default zig-out)")
    parser.add_argument("--version-string", help="VS; defaults to the one derived from this checkout")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "zig-out" / "dist", help="default zig-out/dist")
    parser.add_argument("--cache-dir", type=Path, help=f"download cache (default ${CACHE_ENV} or .local/cache/gx-package)")
    parser.add_argument("--iscc", help="Inno Setup 7.1 ISCC.exe (default $ISCC, .local/tools/innosetup, PATH)")
    parser.add_argument("--skip-installer", action="store_true", help="only build the portable zip")
    parser.add_argument("--offline", action="store_true", help="use only cached downloads")
    parser.add_argument("--build", action="store_true", help="run the ReleaseFast win32 build into --prefix first")
    args = parser.parse_args(argv)
    try:
        version_string = args.version_string or gx_release.release_info(ROOT).version_string
        package(args.prefix.resolve(), version_string, args.output_dir, cache=args.cache_dir, iscc=args.iscc,
                skip_installer=args.skip_installer, offline=args.offline, build=args.build)
        return 0
    except (PackageError, gx_release.ReleaseError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
