#!/usr/bin/env python3
"""GX Shell component stage for Ghostty GX (schema 3): builder, verifier and test package.

Usage
  python scripts/gx_package.py windows --stage-dir DIR [--build] [--prefix PREFIX] [--version-string VS]
                                       [--cache-dir DIR] [--offline]
  python3 scripts/gx_package.py deb --stage-dir DIR [--build [--source-tarball FILE] [--install-deps]]
                                    [--prefix PREFIX] [--version-string VS] [--deb-depends DEPENDS]
                                    [--cache-dir DIR] [--offline]
  python scripts/gx_package.py verify-stage DIR
  python3 scripts/gx_package.py test-deb DIR --output FILE

Consumer contract (GX Shell release.yml)
  Check out gx0404/gx_ghostty at the release commit (actions/checkout with persist-credentials: false;
  depth 1 is enough) and run the commands from its root. VS is <build.zig.zon X.Y.Z>-gx.<fork X.Y.Z> of
  that commit, 1.3.2-gx.0.0.1 for gx-v0.0.1 (gx-release's prepare job prints it as version_string);
  without --version-string that VS is used, any other value is refused before building.
  windows-2025 runner, shell pwsh, every command followed by `if ($LASTEXITCODE -ne 0) { exit
  $LASTEXITCODE }`; `git config --global core.autocrlf false` before the checkout keeps the shipped shell
  scripts and themes LF:
    python scripts/gx_package.py windows --build --stage-dir "$env:RUNNER_TEMP\\ghostty-gx-stage" --version-string $env:VS
    python scripts/gx_package.py verify-stage "$env:RUNNER_TEMP\\ghostty-gx-stage"
  ubuntu:24.04 job container (root), shell bash; before the checkout `apt-get update && apt-get install -y
  --no-install-recommends ca-certificates git python3` (without git, actions/checkout downloads a plain
  tarball and there is no commit to record), after it `git config --global --add safe.directory
  "$GITHUB_WORKSPACE"` (the workspace belongs to the runner user):
    python3 scripts/gx_package.py deb --build --install-deps --stage-dir "$RUNNER_TEMP/ghostty-gx-stage" --version-string "$VS"
    python3 scripts/gx_package.py verify-stage "$RUNNER_TEMP/ghostty-gx-stage"
  gx-release's linux-gtk-noble job runs exactly these two deb commands. To build without downloading
  blueprint-compiler, start from the gx-release asset ghostty-$VS.tar.gz of the same commit instead:
    python3 scripts/gx_package.py deb --build --install-deps --source-tarball "ghostty-$VS.tar.gz" --stage-dir "$RUNNER_TEMP/ghostty-gx-stage" --version-string "$VS"
  Tools: Python 3.10+ and Git. Zig 0.16.0 is the zig on PATH when it reports that version (for example
  mlugg/setup-zig), else scripts/setup_zig.py --install puts the sha256-pinned one into
  .local/toolchains/zig. windows needs neither MSVC nor Inno Setup (only gx_windows_package.py's
  installer does); Windows' System32\\tar.exe extracts the Mesa .7z. deb --install-deps apt-installs the
  package list of scripts/gx_linux_build.py (as root, else through sudo); a checkout build also installs
  the sha256-pinned blueprint-compiler 0.16.0 into .local/tools/ with meson.
  Network: Zig and its packages (pkg.machengine.org, else ziglang.org; deps.files.ghostty.org,
  github.com, codeberg.org, gitlab.freedesktop.org; Zig's own fetcher ignores HTTP proxies), the pinned
  downloads (windows: api.nuget.org, github.com, raw.githubusercontent.com; deb: github.com,
  raw.githubusercontent.com, gitlab.gnome.org with github.com as fallback) and the Ubuntu archive.
  Optional environment: ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR (Zig caches, by default inside the
  checkout: .local/zig-cache/global, plus .zig-cache for windows or .local/zig-cache/gx-linux-build for
  deb), GX_GHOSTTY_PACKAGE_CACHE or --cache-dir (pinned downloads, default .local/cache/gx-package),
  ZIG or GX_GHOSTTY_ZIG (a Zig 0.16.0 to use instead).
  Output: DIR alone (besides those caches), and exit code 0 only after DIR passed verify-stage. What a
  build adds to the checkout is ignored by Git, so source_dirty only reports changes made by the caller.
  --build installs into a temporary prefix next to DIR and removes it afterwards; an explicit --prefix is
  kept and must not exist or be empty. The manifest below is the interface: for deb, root/ is the
  package's file tree and deb_depends its Depends; fonts/ is for GX Shell to install.

--build runs, for windows, gx_windows_package.run_build (zig build -Dapp-runtime=win32
-Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -Dversion-string=VS --prefix PREFIX) once Zig is
there; for deb, the Ubuntu 24.04 recipe scripts/gx_linux_build.py build (ReleaseFast, baseline CPU, PIE,
-fno-sys=gtk4-layer-shell with libgtk4-layer-shell.so bundled in PREFIX/lib, RUNPATH $ORIGIN/../lib
through -Dpatch-rpath and patchelf 0.18.0), whose check-prefix also runs `bin/ghostty +version` without
LD_LIBRARY_PATH. Without --build, PREFIX (default zig-out) must already hold such a build.

DIR must not exist yet. The stage is assembled in a sibling temporary directory, verified, and only
then renamed to DIR, so a failed run leaves nothing behind. VS defaults to, and must equal,
scripts/gx_release.py::ReleaseInfo.version_string. Pinned downloads come from
scripts/gx_windows_package.py and its cache.

Contract: DIR/stage-manifest.json is a JSON object with exactly these keys
  schema             3
  platform           "windows" | "deb"
  architecture       "amd64"
  source_repository  "gx0404/gx_ghostty"
  source_commit      full 40-hex HEAD of the packaging checkout
  source_dirty       bool, true when `git status --porcelain --untracked-files=normal` is not empty
  package_version    fork version X.Y.Z (largest CHANGELOG.md heading, scripts/version.py)
  product_version    VS, which ends in -gx.<package_version>
  zig_version        build.zig.zon minimum_zig_version
  binaries           {"ghostty.exe": sha256} (windows) | {"ghostty": sha256} (deb)
  files              every stage entry except stage-manifest.json, sorted by path:
                     {"path", "size", "sha256"} for regular files, {"path", "symlink"} for the only
                     allowed symlink root/usr/bin/ghostty-gx -> ../lib/ghostty-gx/bin/ghostty (deb)
  deb_depends        deb only: Depends from dpkg-shlibdeps over the binary and the bundled libraries
                     (in a package tree, so $ORIGIN resolves and a library it cannot find is an
                     error), or --deb-depends
Paths use "/" and are relative to DIR; no other symlinks, reparse points or special files exist.
The fonts/ directory is not part of root/: GX Shell installs component fonts itself.

Windows layout (top level exactly app/, fonts/, build-inputs/ and the manifest)
  app/                  the portable directory of gx_windows_package.build_tree without fonts/:
                        ghostty.exe, conpty.dll, OpenConsole.exe, mesa/, share/ (with
                        share/terminfo/ghostty.terminfo and fork themes), licenses/ (Ghostty-MIT.txt,
                        THIRD-PARTY.txt and the ConPTY, Mesa, LLVM and font license texts), README.txt
  fonts/                the 8 pinned fonts of gx_release.WINDOWS_FONTS; GX Shell merges component fonts
                        only when the bytes match, so the four Oh My Zsh GX also ships are identical
  build-inputs/ghostty.ico   dist/windows/ghostty.ico
Deb layout (top level exactly root/, fonts/ and the manifest)
  root/usr/lib/ghostty-gx/   bin/ghostty and share/ from the prefix (relocatable: the app finds
                             share/ghostty, share/terminfo and share/locale relative to its real path),
                             without the upstream desktop integration (share/applications, dbus-1,
                             icons, kio, metainfo, nautilus-python, systemd) and share/pkgconfig, plus
                             fork themes from src/gx/themes/; a symlink inside share/ that stays in it
                             (tic links terminfo/g/ghostty to ../x/xterm-ghostty) becomes a copy
  root/usr/lib/ghostty-gx/lib/   exactly the libraries bin/ghostty loads from the prefix's lib/
                             (transitively; today libgtk4-layer-shell.so, which Ubuntu 24.04 lacks),
                             found through its RUNPATH $ORIGIN/../lib; absent when it needs none
  root/usr/bin/ghostty-gx    symlink to ../lib/ghostty-gx/bin/ghostty
  root/usr/share/applications/com.gx0404.ghostty-gx.desktop   Name=Ghostty GX, Exec=ghostty-gx,
                             Icon=com.gx0404.ghostty-gx, StartupWMClass=com.mitchellh.ghostty
  root/usr/share/icons/hicolor/<N>x<N>/apps/com.gx0404.ghostty-gx.png   from images/gnome/<N>.png
  root/usr/share/doc/ghostty-gx/copyright   machine-readable copyright (Ghostty MIT, fonts OFL-1.1)
  fonts/                     the same 8 pinned fonts
The deb --prefix is a plain prefix (bin/ghostty, share/, lib/) or a DESTDIR tree whose usr/ is that
prefix; the binary must be an x86-64 ELF that embeds VS, without DT_RPATH and with no RUNPATH entry
other than $ORIGIN/../lib (a plain Zig build records its .zig-cache directory there, which the loader
would search relative to the current directory), and every unversioned DT_NEEDED (lib*.so) must be in
lib/ (gx_linux_build.bundled_libraries).

verify-stage DIR re-reads the manifest (unique keys, exact key set, field types), re-hashes the
inventory (nothing missing, extra or changed), checks the required entries and the binary hashes, and
for deb re-applies the RUNPATH rule and checks that root/usr/lib/ghostty-gx/lib/ holds exactly the
libraries the binary loads from it. It needs neither Git nor the network.

test-deb DIR --output FILE builds, with dpkg-deb, the throwaway binary package ghostty-gx-stage-test
(Version VS with "-" turned into "~", Depends = deb_depends) from root/ of a verified deb stage, to try
`apt-get install ./FILE` on a clean Ubuntu 24.04. It is evidence, not a release asset: GX Shell builds
the real package.

Exit codes: 0 success, 1 refused or failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_linux_build as linux  # noqa: E402  (scripts/gx_linux_build.py)
import gx_release  # noqa: E402  (scripts/gx_release.py)
import gx_windows_package as windows  # noqa: E402  (scripts/gx_windows_package.py)

ROOT = SCRIPTS.parent
SCHEMA = 3
MANIFEST = "stage-manifest.json"
SOURCE_REPOSITORY = gx_release.REPOSITORY
PLATFORMS = ("windows", "deb")
ARCHITECTURE = "amd64"
DEB_LIB = "root/usr/lib/ghostty-gx"
DEB_LIBRARIES = f"{DEB_LIB}/lib"
DEB_LINK = "root/usr/bin/ghostty-gx"
DEB_LINK_TARGET = "../lib/ghostty-gx/bin/ghostty"
APP_ID = "com.gx0404.ghostty-gx"
DESKTOP = f"root/usr/share/applications/{APP_ID}.desktop"
COPYRIGHT = "root/usr/share/doc/ghostty-gx/copyright"
ICON_SIZES = (16, 32, 64, 128, 256, 512, 1024)
SKIPPED_SHARE = ("applications", "dbus-1", "icons", "kio", "metainfo", "nautilus-python", "pkgconfig", "systemd")
LINUX_TERMINFO = ("share/terminfo/g/ghostty", "share/terminfo/x/xterm-ghostty")
FONT_LICENSES = ("licenses/JetBrainsMono-OFL-1.1.txt", "licenses/NotoSansCJK-OFL-1.1.txt")
BASE_KEYS = {
    "schema", "platform", "architecture", "source_repository", "source_commit", "source_dirty",
    "package_version", "product_version", "zig_version", "binaries", "files",
}
TOP_LEVEL = {"windows": {"app", "fonts", "build-inputs", MANIFEST}, "deb": {"root", "fonts", MANIFEST}}
BINARIES = {"windows": ("ghostty.exe", "app/ghostty.exe"), "deb": ("ghostty", f"{DEB_LIB}/bin/ghostty")}
REQUIRED = {
    "windows": (
        "app/ghostty.exe", "app/conpty.dll", "app/OpenConsole.exe", "app/mesa/opengl32.dll",
        "app/mesa/libgallium_wgl.dll", "app/share/terminfo/ghostty.terminfo", "app/licenses/Ghostty-MIT.txt",
        "app/licenses/THIRD-PARTY.txt", "app/README.txt", "build-inputs/ghostty.ico",
    ),
    "deb": (
        f"{DEB_LIB}/bin/ghostty", DESKTOP, COPYRIGHT,
        *(f"root/usr/share/icons/hicolor/{size}x{size}/apps/{APP_ID}.png" for size in ICON_SIZES),
    ),
}
TEST_PACKAGE = "ghostty-gx-stage-test"
REPARSE_POINT = windows.REPARSE_POINT
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SEMVER_CORE_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")

PackageError = windows.PackageError
SourceInfo = Callable[[Path], "tuple[str, bool]"]
Depends = Callable[[Path], str]


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise PackageError(f"duplicate manifest key: {key}")
        result[key] = value
    return result


def safe_path(value: object) -> str:
    if not isinstance(value, str) or not value or "\\" in value or value.startswith("/"):
        raise PackageError(f"unsafe stage path: {value!r}")
    parts = value.split("/")
    if any(part in ("", ".", "..") or any(ord(char) < 32 for char in part) for part in parts):
        raise PackageError(f"unsafe stage path: {value!r}")
    return value


def git_source_info(root: Path) -> tuple[str, bool]:
    def git(*args: str) -> str:
        result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True,
                                encoding="utf-8", errors="replace", check=False)
        if result.returncode != 0:
            raise PackageError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
        return result.stdout

    top = Path(git("rev-parse", "--show-toplevel").strip()).resolve()
    if top != Path(root).resolve():
        raise PackageError(f"{root} is not the top of its Git checkout ({top})")
    sha = git("rev-parse", "HEAD").strip()
    if not COMMIT_RE.match(sha):
        raise PackageError(f"HEAD is not a full commit SHA: {sha!r}")
    return sha, bool(git("status", "--porcelain", "--untracked-files=normal").strip())


def inventory(stage: Path, platform: str) -> list[dict]:
    windows.plain_dir(stage, f"stage {stage}")
    entries: list[dict] = []
    folded: dict[str, str] = {}

    def visit(directory: Path) -> None:
        for path in sorted(directory.iterdir(), key=lambda item: item.name):
            relative = safe_path(path.relative_to(stage).as_posix())
            if platform == "windows":
                key = relative.casefold()
                if key in folded:
                    raise PackageError(f"stage paths {folded[key]} and {relative} differ only in case")
                folded[key] = relative
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                if platform != "deb" or relative != DEB_LINK or target != DEB_LINK_TARGET:
                    raise PackageError(f"unexpected stage symlink {relative} -> {target}")
                entries.append({"path": relative, "symlink": target})
            elif getattr(info, "st_file_attributes", 0) & REPARSE_POINT:
                raise PackageError(f"stage reparse point {relative} is not allowed")
            elif stat.S_ISDIR(info.st_mode):
                visit(path)
            elif stat.S_ISREG(info.st_mode):
                if relative != MANIFEST:
                    entries.append({"path": relative, "size": info.st_size, "sha256": windows.digest(path)})
            else:
                raise PackageError(f"special file {relative} is not allowed in a stage")

    visit(stage)
    return sorted(entries, key=lambda entry: entry["path"])


def check_entry(entry: object, platform: str) -> dict:
    if not isinstance(entry, dict):
        raise PackageError("invalid manifest files entry")
    relative = safe_path(entry.get("path"))
    if relative == MANIFEST:
        raise PackageError(f"the manifest lists itself: {relative}")
    if "symlink" in entry:
        if set(entry) != {"path", "symlink"} or platform != "deb" or relative != DEB_LINK \
                or entry["symlink"] != DEB_LINK_TARGET:
            raise PackageError(f"unexpected manifest symlink {relative}")
    elif (set(entry) != {"path", "size", "sha256"} or type(entry["size"]) is not int or entry["size"] < 0
          or not isinstance(entry["sha256"], str) or not SHA_RE.match(entry["sha256"])):
        raise PackageError(f"invalid manifest file entry {relative}")
    return entry


def verify_stage(stage: Path) -> dict:
    stage = Path(stage)
    windows.plain_dir(stage, f"stage {stage}")
    windows.plain_file(stage / MANIFEST, MANIFEST)
    try:
        manifest = json.loads((stage / MANIFEST).read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PackageError(f"{MANIFEST} is not valid UTF-8 JSON: {error}") from error
    if not isinstance(manifest, dict):
        raise PackageError(f"{MANIFEST} must be a JSON object")
    platform = manifest.get("platform")
    if platform not in PLATFORMS:
        raise PackageError(f"unsupported stage platform {platform!r}")
    keys = BASE_KEYS | ({"deb_depends"} if platform == "deb" else set())
    if set(manifest) != keys:
        raise PackageError(f"manifest keys differ: missing {sorted(keys - set(manifest))}, "
                           f"unexpected {sorted(set(manifest) - keys)}")
    if type(manifest["schema"]) is not int or manifest["schema"] != SCHEMA:
        raise PackageError(f"stage schema must be {SCHEMA}")
    if manifest["architecture"] != ARCHITECTURE:
        raise PackageError(f"stage architecture must be {ARCHITECTURE}")
    if manifest["source_repository"] != SOURCE_REPOSITORY:
        raise PackageError(f"stage source_repository must be {SOURCE_REPOSITORY}")
    if not isinstance(manifest["source_commit"], str) or not COMMIT_RE.match(manifest["source_commit"]):
        raise PackageError("stage source_commit must be a full 40-hex commit")
    if type(manifest["source_dirty"]) is not bool:
        raise PackageError("stage source_dirty must be a boolean")
    for key in ("package_version", "zig_version"):
        if not isinstance(manifest[key], str) or not SEMVER_CORE_RE.match(manifest[key]):
            raise PackageError(f"stage {key} must be X.Y.Z")
    product = manifest["product_version"]
    if (not isinstance(product, str) or not windows.VERSION_STRING_RE.match(product)
            or not product.endswith(f"-gx.{manifest['package_version']}")):
        raise PackageError(f"stage product_version {product!r} is not <X.Y.Z>-gx.<package_version>")
    if platform == "deb":
        depends = manifest["deb_depends"]
        if not isinstance(depends, str) or not depends.strip() or "\n" in depends:
            raise PackageError("stage deb_depends must be a non-empty single-line string")
    files = manifest["files"]
    if not isinstance(files, list):
        raise PackageError("stage files must be a list")
    expected = [check_entry(entry, platform) for entry in files]
    paths = [entry["path"] for entry in expected]
    if paths != sorted(set(paths)):
        raise PackageError("stage files must be sorted by path without duplicates")
    actual = {entry["path"]: entry for entry in inventory(stage, platform)}
    listed = {entry["path"]: entry for entry in expected}
    missing, extra = sorted(listed.keys() - actual.keys()), sorted(actual.keys() - listed.keys())
    if missing or extra:
        raise PackageError(f"stage inventory differs from {MANIFEST}: missing {missing}, extra {extra}")
    changed = sorted(path for path, entry in listed.items() if actual[path] != entry)
    if changed:
        raise PackageError(f"stage files differ from {MANIFEST}: {changed}")
    top = {path.name for path in stage.iterdir()}
    if top != TOP_LEVEL[platform]:
        raise PackageError(f"stage top level must be {sorted(TOP_LEVEL[platform])}, found {sorted(top)}")
    required = [*REQUIRED[platform], *(f"fonts/{name}" for name in gx_release.WINDOWS_FONTS)]
    absent = [path for path in required if "sha256" not in actual.get(path, {})]
    if platform == "deb" and DEB_LINK not in actual:
        absent.append(DEB_LINK)
    if absent:
        raise PackageError(f"stage lacks required entries: {absent}")
    name, path = BINARIES[platform]
    binaries = manifest["binaries"]
    if not isinstance(binaries, dict) or set(binaries) != {name}:
        raise PackageError(f"stage binaries must be exactly {{{name!r}: sha256}}")
    if binaries[name] != actual[path]["sha256"]:
        raise PackageError(f"stage binary {name} differs from {path}")
    if platform == "deb":
        check_deb_libraries(stage, actual)
    return manifest


def check_deb_libraries(stage: Path, actual: dict[str, dict]) -> None:
    needed = [name for name, _ in linux.bundled_libraries(stage / BINARIES["deb"][1], stage / DEB_LIBRARIES)]
    prefix = DEB_LIBRARIES + "/"
    staged = sorted(path[len(prefix):] for path in actual if path.startswith(prefix))
    if staged != needed:
        raise PackageError(f"{DEB_LIBRARIES}/ must hold exactly the libraries ghostty loads from it, {needed}; "
                           f"found {staged}")


def deb_prefix(prefix: Path) -> Path:
    prefix = Path(prefix)
    for candidate in (prefix, prefix / "usr"):
        if (candidate / "bin" / "ghostty").exists() or (candidate / "bin" / "ghostty").is_symlink():
            return candidate
    raise PackageError(f"{prefix} holds neither bin/ghostty nor usr/bin/ghostty")


def shlibdeps(binary: Path, runner: windows.Runner = subprocess.run) -> str:
    """Depends of a staged bin/ghostty and the libraries in its ../lib, from a package tree (with DEBIAN/)
    laid out like the installed package, the only layout in which dpkg-shlibdeps resolves $ORIGIN."""
    tool = shutil.which("dpkg-shlibdeps")
    if tool is None:
        raise PackageError("dpkg-shlibdeps is not installed (apt install dpkg-dev), or pass --deb-depends")
    binary = Path(binary)
    libraries = binary.parent.parent / "lib"
    installed = DEB_LIB.split("/", 1)[1]
    with tempfile.TemporaryDirectory(prefix="gx-shlibdeps-") as temp:
        work = Path(temp)
        (work / "debian").mkdir()
        (work / "debian" / "control").write_text(
            "Source: ghostty-gx\n\nPackage: ghostty-gx\nArchitecture: amd64\n", encoding="utf-8")
        (work / "package" / "DEBIAN").mkdir(parents=True)
        targets = [f"package/{installed}/bin/ghostty"]
        copy_file(binary, work / targets[0], executable=True)
        for library in sorted(libraries.iterdir() if libraries.is_dir() else (), key=lambda item: item.name):
            targets.append(f"package/{installed}/lib/{library.name}")
            copy_file(library, work / targets[-1])
        result = runner([tool, "-O", *(f"-e{target}" for target in targets)], cwd=str(work), capture_output=True,
                        text=True, errors="replace", check=False)
    if result.returncode != 0:
        raise PackageError(f"dpkg-shlibdeps failed (exit {result.returncode}): {(result.stderr or '').strip()}")
    unresolved = [line.strip() for line in (result.stderr or "").splitlines() if "cannot find library" in line]
    if unresolved:
        raise PackageError("dpkg-shlibdeps cannot resolve every needed library: " + "; ".join(unresolved))
    for line in (result.stdout or "").splitlines():
        if line.startswith("shlibs:Depends="):
            depends = line.split("=", 1)[1].strip()
            if depends:
                return depends
    raise PackageError("dpkg-shlibdeps reported no shlibs:Depends")


def font_copyright(path: Path) -> str:
    """Copyright notice (name ID 0) of the first face, preferring US English."""
    data = path.read_bytes()
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
            platform, _, language, ident, length, offset = struct.unpack_from(">6H", data, table + 6 + record * 12)
            if ident == 0 and platform in (0, 3):
                start = table + strings + offset
                candidates.append((language == 0x409, data[start:start + length].decode("utf-16-be")))
        if candidates:
            return " ".join(sorted(candidates, reverse=True)[0][1].split())
    raise PackageError(f"{path.name} has no copyright notice (name ID 0)")


def dep5_text(text: str) -> list[str]:
    lines = text.replace("\r\n", "\n").strip("\n").split("\n")
    return [f" {line.rstrip()}" if line.strip() else " ." for line in lines]


def holder(notice: str) -> str:
    return re.sub(r"^(Copyright\s*)?(\(c\)|©)?\s*", "", notice.strip(), flags=re.IGNORECASE)


def copyright_file(root: Path, fonts: Path, ofl: str) -> str:
    license_text = (Path(root) / "LICENSE").read_text(encoding="utf-8")
    ghostty = next((line for line in license_text.splitlines() if line.startswith("Copyright")), None)
    if ghostty is None:
        raise PackageError("LICENSE has no Copyright line")
    ghostty = holder(ghostty)
    jetbrains = holder(font_copyright(fonts / "JetBrainsMonoNerdFont-Regular.ttf"))
    noto = holder(font_copyright(fonts / "NotoSansCJK-Regular.ttc"))
    lines = [
        "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/",
        "Upstream-Name: Ghostty GX",
        "Upstream-Contact: https://github.com/gx0404/gx_ghostty/issues",
        "Source: https://github.com/gx0404/gx_ghostty",
        "",
        "Files: *",
        f"Copyright: {ghostty}",
        " gx0404 and Ghostty GX contributors",
        "License: MIT",
        "",
        "Files: */JetBrainsMonoNerdFont-*.ttf",
        f"Copyright: {jetbrains}",
        " Nerd Fonts contributors (patched glyphs, https://github.com/ryanoasis/nerd-fonts)",
        "License: OFL-1.1",
        "",
        "Files: */NotoSansCJK-*.ttc",
        f"Copyright: {noto}",
        "License: OFL-1.1",
        "",
        "License: MIT",
        *dep5_text(license_text),
        "",
        "License: OFL-1.1",
        *dep5_text(ofl),
        "",
    ]
    return "\n".join(lines)


def desktop_entry() -> str:
    return "\n".join([
        "[Desktop Entry]",
        "Version=1.0",
        "Type=Application",
        "Name=Ghostty GX",
        "GenericName=Terminal",
        "GenericName[zh_CN]=终端",
        "Comment=A terminal emulator",
        "Comment[zh_CN]=终端模拟器",
        "TryExec=ghostty-gx",
        "Exec=ghostty-gx",
        f"Icon={APP_ID}",
        "Categories=System;TerminalEmulator;",
        "Keywords=terminal;tty;pty;",
        "StartupNotify=true",
        "StartupWMClass=com.mitchellh.ghostty",
        "Terminal=false",
        "X-TerminalArgExec=-e",
        "X-TerminalArgTitle=--title=",
        "X-TerminalArgDir=--working-directory=",
        "X-TerminalArgHold=--wait-after-command",
        "",
    ])


def copy_file(source: Path, destination: Path, executable: bool = False) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o755 if executable else 0o644)


def materialize_fonts(stage: Path, cache: Path, *, root: Path, offline: bool,
                      fetcher: windows.Fetcher | None, downloads, payload) -> dict[str, Path]:
    """Write the pinned fonts to stage/fonts and return the font license texts (in a temp directory)."""
    payload = list(payload)
    selected = [item for item in payload if item.target.startswith(windows.FONTS_DIR + "/")
                or item.target in FONT_LICENSES]
    work = Path(tempfile.mkdtemp(prefix="gx-stage-fonts-", dir=stage.parent))
    windows.materialize(work, cache, downloads=downloads, payload=selected, root=root, offline=offline,
                        fetcher=fetcher)
    shutil.move(str(work / windows.FONTS_DIR), str(stage / windows.FONTS_DIR))
    return {name: work / name for name in FONT_LICENSES} | {"": work}


def stage_windows(stage: Path, prefix: Path, version_string: str, cache: Path, *, root: Path, offline: bool,
                  fetcher: windows.Fetcher | None, downloads, payload, seven_zip: windows.SevenZip) -> dict[str, str]:
    app = stage / "app"
    windows.build_tree(app, prefix, version_string, cache, root=root, downloads=downloads, payload=payload,
                       offline=offline, fetcher=fetcher, seven_zip=seven_zip)
    shutil.move(str(app / windows.FONTS_DIR), str(stage / windows.FONTS_DIR))
    copy_file(Path(root) / windows.ICON, stage / "build-inputs" / "ghostty.ico")
    return {"ghostty.exe": windows.digest(app / "ghostty.exe")}


def share_files(share: Path) -> list[tuple[str, Path]]:
    """Files below a Linux prefix's share/ as (posix relative path, file to copy).

    A symlink that resolves to a regular file inside share/ is copied as that file (tic links
    terminfo/g/ghostty to ../x/xterm-ghostty), because DEB_LINK is the only symlink a stage holds;
    any other symlink, and every special file, is refused."""
    share = Path(share)
    windows.plain_dir(share, "share/")
    real_share = share.resolve()
    found: list[tuple[str, Path]] = []
    for current, directories, files in os.walk(share):
        current_path = Path(current)
        for name in sorted(directories):
            windows.plain_dir(current_path / name, f"share/{(current_path / name).relative_to(share).as_posix()}")
        directories.sort()
        for name in sorted(files):
            path = current_path / name
            relative = path.relative_to(share).as_posix()
            if path.is_symlink():
                target = path.resolve()
                if not target.is_relative_to(real_share) or not target.is_file():
                    raise PackageError(f"share/{relative} links to {os.readlink(path)}, outside share/ or not a file")
                print(f"copied share/{relative} as a file (symlink to {os.readlink(path)})")
                found.append((relative, target))
            else:
                windows.plain_file(path, f"share/{relative}")
                found.append((relative, path))
    return found


def stage_deb(stage: Path, prefix: Path, version_string: str, cache: Path, *, root: Path, offline: bool,
              fetcher: windows.Fetcher | None, downloads, payload, depends: Depends) -> tuple[dict[str, str], str]:
    base = deb_prefix(prefix)
    linux.check_binary(base / "bin" / "ghostty", version_string)
    libraries = linux.bundled_libraries(base / "bin" / "ghostty", base / "lib")
    shared = share_files(base / "share")
    if not any((base / sentinel).is_file() for sentinel in LINUX_TERMINFO):
        raise PackageError("the prefix lacks the compiled terminfo share/terminfo/g/ghostty that the app "
                           "uses to find its resources")
    if not any(path.is_file() for path in (base / "share" / "ghostty").rglob("*")):
        raise PackageError("share/ghostty/ (themes, shell integration) is missing or empty in the prefix")
    lib = stage / DEB_LIB
    copy_file(base / "bin" / "ghostty", lib / "bin" / "ghostty", executable=True)
    for entry in sorted(os.listdir(base / "bin")):
        if entry != "ghostty":
            print(f"skipped bin/{entry} (only the ghostty binary is staged)")
    for name, source in libraries:
        copy_file(source, lib / "lib" / name)
    bundled = {name for name, _ in libraries}
    if (base / "lib").is_dir():
        for entry in sorted(os.listdir(base / "lib")):
            if entry not in bundled:
                print(f"skipped lib/{entry} (ghostty does not load it)")
    copied = set()
    for relative, source in shared:
        if relative.split("/")[0] in SKIPPED_SHARE:
            continue
        copy_file(source, lib / "share" / relative)
        copied.add(f"share/{relative}")
    for relative, data in windows.source_themes(root):
        if relative not in copied:
            (lib / relative).parent.mkdir(parents=True, exist_ok=True)
            (lib / relative).write_bytes(data)
    link = stage / DEB_LINK
    link.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(DEB_LINK_TARGET, link)
    desktop = stage / DESKTOP
    desktop.parent.mkdir(parents=True, exist_ok=True)
    desktop.write_bytes(desktop_entry().encode("utf-8"))
    for size in ICON_SIZES:
        copy_file(Path(root) / "images" / "gnome" / f"{size}.png",
                  stage / f"root/usr/share/icons/hicolor/{size}x{size}/apps/{APP_ID}.png")
    licenses = materialize_fonts(stage, cache, root=root, offline=offline, fetcher=fetcher,
                                 downloads=downloads, payload=payload)
    try:
        ofl = licenses[FONT_LICENSES[1]].read_text(encoding="utf-8")
        text = copyright_file(root, stage / windows.FONTS_DIR, ofl)
    finally:
        shutil.rmtree(licenses[""], ignore_errors=True)
    (stage / COPYRIGHT).parent.mkdir(parents=True, exist_ok=True)
    (stage / COPYRIGHT).write_bytes(text.encode("utf-8"))
    binary = lib / "bin" / "ghostty"
    return {"ghostty": windows.digest(binary)}, depends(binary)


def build_stage(
    platform: str,
    stage: Path,
    prefix: Path,
    version_string: str | None = None,
    *,
    root: Path = ROOT,
    cache: Path | None = None,
    offline: bool = False,
    deb_depends: str | None = None,
    source_info: SourceInfo = git_source_info,
    depends: Depends | None = None,
    fetcher: windows.Fetcher | None = None,
    seven_zip: windows.SevenZip = windows.extract_7z,
    downloads=windows.DOWNLOADS,
    payload=windows.PAYLOAD,
) -> dict:
    if platform not in PLATFORMS:
        raise PackageError(f"unsupported platform {platform!r}")
    stage = Path(stage).absolute()
    if stage.exists() or stage.is_symlink():
        raise PackageError(f"--stage-dir {stage} must not exist yet")
    info = gx_release.release_info(root)
    version_string = windows.check_version_string(version_string or info.version_string, root)
    sha, dirty = source_info(root)
    cache = windows.cache_dir(cache, root)
    if platform == "deb" and deb_depends is None and depends is None:
        depends = shlibdeps
    if deb_depends is not None:
        if not deb_depends.strip() or "\n" in deb_depends:
            raise PackageError("--deb-depends must be a non-empty single line")
        depends = lambda binary: deb_depends.strip()  # noqa: E731
    stage.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=f".{stage.name}.", dir=stage.parent))
    try:
        common = dict(root=root, offline=offline, fetcher=fetcher, downloads=downloads, payload=payload)
        manifest: dict = {
            "schema": SCHEMA, "platform": platform, "architecture": ARCHITECTURE,
            "source_repository": SOURCE_REPOSITORY, "source_commit": sha, "source_dirty": dirty,
            "package_version": info.fork_version, "product_version": version_string,
            "zig_version": info.zig_version,
        }
        if platform == "windows":
            manifest["binaries"] = stage_windows(temp, Path(prefix), version_string, cache, seven_zip=seven_zip,
                                                 **common)
        else:
            manifest["binaries"], manifest["deb_depends"] = stage_deb(
                temp, Path(prefix), version_string, cache, depends=depends, **common)
        manifest["files"] = inventory(temp, platform)
        (temp / MANIFEST).write_bytes(
            (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8"))
        verify_stage(temp)
        if stage.exists() or stage.is_symlink():
            raise PackageError(f"--stage-dir {stage} appeared while staging")
        os.rename(temp, stage)
    except BaseException:
        shutil.rmtree(temp, ignore_errors=True)
        raise
    return manifest


def build_prefix(platform: str, prefix: Path, version_string: str, *, root: Path = ROOT,
                 source_tarball: Path | None = None, install_deps: bool = False, cache: Path | None = None,
                 offline: bool = False, runner: windows.Runner = subprocess.run) -> None:
    """Build what the platform's stage packages into the new or empty prefix."""
    if platform == "deb":
        linux.build(prefix, version_string, root=root, source_tarball=source_tarball, install_deps=install_deps,
                    cache=cache, offline=offline, runner=runner)
        return
    prefix = linux.prepare_prefix(prefix)
    linux.ensure_zig(root, runner)
    windows.run_build(prefix, version_string, root, runner)


def test_control(manifest: dict) -> str:
    return "\n".join([
        f"Package: {TEST_PACKAGE}",
        f"Version: {manifest['product_version'].replace('-', '~')}",
        f"Architecture: {ARCHITECTURE}",
        "Maintainer: gx0404 <gx0404@users.noreply.github.com>",
        f"Depends: {manifest['deb_depends']}",
        "Section: x11",
        "Priority: optional",
        "Homepage: https://github.com/gx0404/gx_ghostty",
        "Description: Ghostty GX deb stage test package (not for distribution)",
        " Throwaway package of root/ from a scripts/gx_package.py deb stage of",
        f" {SOURCE_REPOSITORY} {manifest['source_commit']}. GX Shell ships the real package.",
        "",
    ])


def test_deb(stage: Path, output: Path, runner: windows.Runner = subprocess.run) -> Path:
    stage = Path(stage)
    manifest = verify_stage(stage)
    if manifest["platform"] != "deb":
        raise PackageError(f"{stage} is a {manifest['platform']} stage, not a deb stage")
    tool = shutil.which("dpkg-deb")
    if tool is None:
        raise PackageError("dpkg-deb is not installed (it comes with dpkg)")
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise PackageError(f"--output {output} must not exist yet")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gx-test-deb-") as temp:
        tree = Path(temp) / TEST_PACKAGE
        shutil.copytree(stage / "root", tree, symlinks=True)
        (tree / "DEBIAN").mkdir()
        (tree / "DEBIAN" / "control").write_bytes(test_control(manifest).encode("utf-8"))
        for directory, _, _ in os.walk(tree):
            os.chmod(directory, 0o755)
        command = [tool, "--root-owner-group", "-Zxz", "--build", str(tree), str(output)]
        print("$ " + subprocess.list2cmdline(command), flush=True)
        result = runner(command, check=False)
    if result.returncode != 0:
        raise PackageError(f"dpkg-deb failed with exit code {result.returncode}")
    return output


def main(argv: list[str] | None = None) -> int:
    windows._utf8_stdio()
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["verify-stage"]:
        parser = argparse.ArgumentParser(prog="gx_package.py verify-stage",
                                         description="verify a schema 3 Ghostty GX stage")
        parser.add_argument("stage", type=Path)
        args = parser.parse_args(argv[1:])
        try:
            manifest = verify_stage(args.stage)
        except (PackageError, OSError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
        print(f"PASS stage {args.stage}: {manifest['platform']}, {manifest['product_version']}, "
              f"{manifest['source_commit']}, {len(manifest['files'])} entries")
        return 0
    if argv[:1] == ["test-deb"]:
        parser = argparse.ArgumentParser(prog="gx_package.py test-deb",
                                         description=f"build the throwaway {TEST_PACKAGE} package of a deb stage")
        parser.add_argument("stage", type=Path)
        parser.add_argument("--output", type=Path, required=True, help="new .deb file")
        args = parser.parse_args(argv[1:])
        try:
            output = test_deb(args.stage, args.output)
        except (PackageError, OSError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
        print(f"BUILT {output}: {TEST_PACKAGE}, {output.stat().st_size} bytes, sha256 {windows.digest(output)}")
        return 0
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog=__doc__.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("platform", choices=PLATFORMS)
    parser.add_argument("--stage-dir", type=Path, required=True, help="new directory for the stage")
    parser.add_argument("--build", action="store_true",
                        help="first build the app into the prefix (windows: win32 ReleaseFast; deb: gx_linux_build.py)")
    parser.add_argument("--prefix", type=Path,
                        help="install prefix (default zig-out; with --build a temporary directory removed afterwards)")
    parser.add_argument("--source-tarball", type=Path, help="deb --build only: build from this ghostty-VS.tar.gz")
    parser.add_argument("--install-deps", action="store_true",
                        help="deb --build only: apt-get install the missing build dependencies first")
    parser.add_argument("--version-string", help="VS; defaults to the one derived from this checkout")
    parser.add_argument("--deb-depends", help="deb only: Depends to record instead of running dpkg-shlibdeps")
    parser.add_argument("--cache-dir", type=Path, help="download cache (see gx_windows_package.py)")
    parser.add_argument("--offline", action="store_true", help="use only cached downloads")
    args = parser.parse_args(argv)
    if args.deb_depends is not None and args.platform != "deb":
        parser.error("--deb-depends only applies to deb stages")
    if (args.source_tarball is not None or args.install_deps) and not (args.build and args.platform == "deb"):
        parser.error("--source-tarball and --install-deps only apply to deb --build")
    temporary = None
    try:
        version_string = windows.check_version_string(
            args.version_string or gx_release.release_info(ROOT).version_string, ROOT)
        stage = args.stage_dir.absolute()
        if stage.exists() or stage.is_symlink():
            raise PackageError(f"--stage-dir {stage} must not exist yet")
        prefix = args.prefix
        if args.build:
            if prefix is None:
                stage.parent.mkdir(parents=True, exist_ok=True)
                temporary = Path(tempfile.mkdtemp(prefix=f".{stage.name}.prefix-", dir=stage.parent))
                prefix = temporary
            build_prefix(args.platform, prefix, version_string, source_tarball=args.source_tarball,
                         install_deps=args.install_deps, cache=args.cache_dir, offline=args.offline)
        manifest = build_stage(args.platform, stage, (prefix or ROOT / "zig-out").resolve(), version_string,
                               cache=args.cache_dir, offline=args.offline, deb_depends=args.deb_depends)
    except (PackageError, gx_release.ReleaseError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    finally:
        if temporary is not None:
            shutil.rmtree(temporary, ignore_errors=True)
    print(f"STAGED {args.stage_dir}: {manifest['platform']}, {manifest['product_version']}, "
          f"source {manifest['source_commit']} dirty={manifest['source_dirty']}, {len(manifest['files'])} entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
