#!/usr/bin/env python3
"""Ubuntu 24.04 build recipe for the Ghostty GX GTK app, the input of the GX Shell deb stage.

Usage
  python3 scripts/gx_linux_build.py deps [--mode checkout|tarball] [--install]
  python3 scripts/gx_linux_build.py build --prefix PREFIX [--version-string VS] [--source-tarball FILE]
                                          [--work-dir DIR] [--install-deps] [--cache-dir DIR] [--offline]
  python3 scripts/gx_linux_build.py check-prefix PREFIX [--version-string VS]

deps
  Checks the apt packages with dpkg-query and prints the apt-get command for the missing ones;
  --install runs apt-get update and install (as root, else through sudo). Every build needs
  BUILD_PACKAGES; a build from the Git checkout (--mode checkout, the default) compiles the GTK
  resources and also needs RESOURCE_PACKAGES. Package names are Ubuntu 24.04's (noble).
build
  1. the deps check for the chosen source (--install-deps installs what is missing first), patchelf
     PATCHELF_VERSION (noble's patchelf package), and the GTK 4 / libadwaita versions from pkg-config;
  2. Zig 0.16.0: the one scripts/zigw.py resolves when it reports the pinned version (for example
     mlugg/setup-zig on PATH), else scripts/setup_zig.py --install (sha256-pinned, .local/toolchains/zig);
  3. the source:
     - checkout (default): this Git checkout. Ubuntu 24.04 ships blueprint-compiler 0.12 and the
       build needs 0.16.0, so the BLUEPRINTS archive (GNOME GitLab's v0.16.0 tag archive, else
       GNOME's GitHub mirror; both sha256-pinned and checked to be git archives of the tag commit)
       is cached like the other pinned downloads (--cache-dir, else $GX_GHOSTTY_PACKAGE_CACHE,
       else .local/cache/gx-package; --offline never downloads), installed with meson into
       .local/tools/blueprint-compiler-0.16.0 and put first on PATH;
     - --source-tarball FILE: ghostty-VS.tar.gz from `zig build dist` (the gx-release asset),
       extracted below the work directory (--work-dir, kept; default a temporary directory next to
       PREFIX, removed afterwards). It must be the git archive of this checkout's HEAD (its pax
       comment) with VERSION = VS; it carries the generated GTK resources, so no blueprint-compiler;
  4. python3 scripts/zigw.py build --prefix PREFIX BUILD_FLAGS -Dversion-string=VS in the source,
     with ZIG_LOCAL_CACHE_DIR defaulting to .local/zig-cache/gx-linux-build: -Dpatch-rpath edits the
     cached binary in place, so these builds keep a cache of their own;
  5. check-prefix.
  PREFIX must not exist or be empty. VS defaults to, and must equal, the version string derived from
  this checkout (scripts/gx_release.py::ReleaseInfo.version_string). Zig downloads its packages
  (ZIG_GLOBAL_CACHE_DIR, default .local/zig-cache/global); Zig's own fetcher cannot go through an
  HTTP proxy, so behind one prefetch them first (scripts/gx_wsl.py setup does).
check-prefix
  bin/ghostty is an x86-64 ELF that embeds VS, has no DT_RPATH and a DT_RUNPATH of exactly
  $ORIGIN/../lib; the libraries it needs from PREFIX/lib (and theirs) carry no other search path
  than $ORIGIN; every unversioned DT_NEEDED (lib*.so, which no runtime package provides) is in
  PREFIX/lib; and `bin/ghostty +version` prints "  - version: VS" with LD_LIBRARY_PATH unset.

The bundled library: Ubuntu 24.04 has no libgtk4-layer-shell-dev, so -fno-sys=gtk4-layer-shell builds
pkg/gtk4-layer-shell as libgtk4-layer-shell.so (unversioned SONAME; it has to stay a shared library
linked before libwayland-client, see src/build/SharedDeps.zig) and installs it into PREFIX/lib. Zig
alone records the build tree's .zig-cache directory as the RUNPATH, which the dynamic loader resolves
against the current directory; -Dpatch-rpath=$ORIGIN/../lib (src/build/Config.zig) has patchelf
replace it, so PREFIX/{bin,lib}, and the stage's /usr/lib/ghostty-gx/{bin,lib}, work from any
location without LD_LIBRARY_PATH.

Exit codes: 0 success, 1 refused or failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Mapping

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_release  # noqa: E402  (scripts/gx_release.py)
import gx_windows_package as windows  # noqa: E402  (scripts/gx_windows_package.py)
import setup_zig  # noqa: E402  (scripts/setup_zig.py)
import zigw  # noqa: E402  (scripts/zigw.py)

ROOT = SCRIPTS.parent
PackageError = windows.PackageError
Runner = windows.Runner
Fetcher = windows.Fetcher

BUILD_PACKAGES = (
    "ca-certificates",  # HTTPS downloads: Zig, Zig packages, blueprint-compiler, fonts
    "dpkg-dev",  # dpkg-shlibdeps for the deb stage
    "gettext",  # msgfmt for the translations (src/build/GhosttyI18n.zig)
    "git",  # stage provenance; the source tarball check
    "libadwaita-1-dev",
    "libgtk-4-dev",  # also brings libwayland-dev, libx11-dev, libegl-dev, glib-compile-resources
    "ncurses-bin",  # tic compiles the terminfo (src/build/GhosttyResources.zig)
    "patchelf",  # -Dpatch-rpath
    "pkgconf",  # pkg-config (src/build/gtk.zig and every system library)
    "python3",
)
RESOURCE_PACKAGES = (
    "gir1.2-adw-1",  # typelibs that blueprint-compiler validates the blueprints against
    "gir1.2-girepository-2.0",
    "gir1.2-gtk-4.0",
    "libxml2-utils",  # xmllint for glib-compile-resources preprocess="xml-stripblanks"
    "meson",  # builds and installs the pinned blueprint-compiler
    "ninja-build",
    "python3-gi",
)
MODES = ("checkout", "tarball")

BLUEPRINT_VERSION = "0.16.0"
BLUEPRINT_COMMIT = "04ef0944db56ab01307a29aaa7303df6067cb3c0"  # refs/tags/v0.16.0^{}
BLUEPRINT_LICENSE = "LGPL-3.0-or-later (build tool only, not shipped)"
BLUEPRINTS = (
    windows.Download(
        f"blueprint-compiler-v{BLUEPRINT_VERSION}.tar.gz",
        "https://gitlab.gnome.org/GNOME/blueprint-compiler/-/archive/"
        f"v{BLUEPRINT_VERSION}/blueprint-compiler-v{BLUEPRINT_VERSION}.tar.gz",
        "01feb8263fe7a450b0a9fed0fd54cf88947aaf00f86cc7da345f8b39a0e7bd30", 129792, "file",
        f"blueprint-compiler {BLUEPRINT_VERSION} (GNOME GitLab tag archive)", BLUEPRINT_LICENSE,
    ),
    windows.Download(
        f"blueprint-compiler-{BLUEPRINT_VERSION}-github.tar.gz",
        f"https://github.com/GNOME/blueprint-compiler/archive/refs/tags/v{BLUEPRINT_VERSION}.tar.gz",
        "521c6149fef9c4f254ea67af2f71bb5255baddb7ac99dc335736d236b4e4f3d8", 129774, "file",
        f"blueprint-compiler {BLUEPRINT_VERSION} (GNOME GitHub mirror tag archive)", BLUEPRINT_LICENSE,
    ),
)
PATCHELF_VERSION = "0.18.0"
VERSION_MODULES = ("gtk4", "libadwaita-1")

ORIGIN_RUNPATH = "$ORIGIN/../lib"
BUILD_FLAGS = (
    "-Doptimize=ReleaseFast",
    "-Dcpu=baseline",
    "-Dpie=true",
    "-Dapp-runtime=gtk",
    "-Dgtk-wayland=true",
    "-Dgtk-x11=true",
    "-Di18n=true",
    "-Demit-docs=false",
    "-fno-sys=gtk4-layer-shell",
    f"-Dpatch-rpath={ORIGIN_RUNPATH}",
)
LOCAL_CACHE = Path(".local") / "zig-cache" / "gx-linux-build"
DIST_RESOURCES = (
    "src/apprt/gtk/ghostty_resources.c",
    "src/apprt/gtk/ghostty_resources.h",
    "src/build/framegen/framedata.compressed",
)

ELF_MACHINE_X86_64 = 0x3E
PT_LOAD, PT_DYNAMIC = 1, 2
DT_NULL, DT_NEEDED, DT_STRTAB, DT_STRSZ, DT_SONAME, DT_RPATH, DT_RUNPATH = 0, 1, 5, 10, 14, 15, 29
LIBRARY_NAME_RE = re.compile(r"^[A-Za-z0-9_.+-]+$")
UNVERSIONED_RE = re.compile(r"^lib[A-Za-z0-9_.+-]*\.so$")


@dataclass(frozen=True)
class ElfInfo:
    machine: int
    needed: tuple[str, ...]
    soname: str | None
    rpath: tuple[str, ...]
    runpath: tuple[str, ...]


def elf_info(path: Path) -> ElfInfo:
    """Machine, DT_NEEDED, DT_SONAME, DT_RPATH and DT_RUNPATH of a 64-bit little-endian ELF file."""
    path = Path(path)
    try:
        with path.open("rb") as stream:
            header = stream.read(64)
            if len(header) < 64 or header[:4] != b"\x7fELF" or header[4] != 2 or header[5] != 1:
                raise PackageError(f"{path} is not a 64-bit little-endian ELF file")
            machine = struct.unpack_from("<H", header, 18)[0]
            phoff = struct.unpack_from("<Q", header, 32)[0]
            phentsize, phnum = struct.unpack_from("<HH", header, 54)
            if phnum == 0:
                return ElfInfo(machine, (), None, (), ())
            if phentsize != 56 or phnum == 0xFFFF:
                raise PackageError(f"{path} has an unsupported program header table")
            stream.seek(phoff)
            table = stream.read(56 * phnum)
            if len(table) != 56 * phnum:
                raise PackageError(f"{path} has a truncated program header table")
            loads: list[tuple[int, int, int]] = []
            dynamic = None
            for index in range(phnum):
                kind, _, offset, address, _, size, _, _ = struct.unpack_from("<IIQQQQQQ", table, index * 56)
                if kind == PT_LOAD:
                    loads.append((address, offset, size))
                elif kind == PT_DYNAMIC:
                    dynamic = (offset, size)
            if dynamic is None:
                return ElfInfo(machine, (), None, (), ())
            stream.seek(dynamic[0])
            raw = stream.read(dynamic[1])
            entries: list[tuple[int, int]] = []
            for position in range(0, len(raw) - 15, 16):
                tag, value = struct.unpack_from("<qQ", raw, position)
                if tag == DT_NULL:
                    break
                entries.append((tag, value))

            def single(tag: int) -> int | None:
                values = [value for kind, value in entries if kind == tag]
                if len(values) > 1:
                    raise PackageError(f"{path} has {len(values)} dynamic entries of type {tag}")
                return values[0] if values else None

            strtab, strsz = single(DT_STRTAB), single(DT_STRSZ)
            if strtab is None or strsz is None:
                if any(kind in (DT_NEEDED, DT_SONAME, DT_RPATH, DT_RUNPATH) for kind, _ in entries):
                    raise PackageError(f"{path} names libraries without a dynamic string table")
                return ElfInfo(machine, (), None, (), ())
            location = next((strtab - address + offset for address, offset, size in loads
                             if address <= strtab < address + size), None)
            if location is None:
                raise PackageError(f"{path}: the dynamic string table is outside every loaded segment")
            stream.seek(location)
            strings = stream.read(strsz)
    except OSError as error:
        raise PackageError(f"cannot read {path}: {error}") from error
    except struct.error as error:
        raise PackageError(f"{path} is a truncated ELF file: {error}") from error

    def text(offset: int) -> str:
        end = strings.find(b"\0", offset)
        if offset >= len(strings) or end < 0:
            raise PackageError(f"{path} has a dynamic string outside its string table")
        try:
            return strings[offset:end].decode("utf-8")
        except UnicodeDecodeError as error:
            raise PackageError(f"{path} has a non UTF-8 dynamic string") from error

    def paths(tag: int) -> tuple[str, ...]:
        offset = single(tag)
        return tuple(text(offset).split(":")) if offset is not None else ()

    soname = single(DT_SONAME)
    return ElfInfo(
        machine,
        tuple(text(value) for kind, value in entries if kind == DT_NEEDED),
        text(soname) if soname is not None else None,
        paths(DT_RPATH),
        paths(DT_RUNPATH),
    )


def check_binary(path: Path, version_string: str) -> ElfInfo:
    windows.plain_file(Path(path), "bin/ghostty")
    info = elf_info(path)
    if info.machine != ELF_MACHINE_X86_64:
        raise PackageError(f"{path} targets ELF machine {info.machine:#x}, not x86-64")
    if not windows.contains(Path(path), version_string.encode("ascii")):
        raise PackageError(f"{path} does not embed the version string {version_string}; "
                           "rebuild with -Dversion-string=" + version_string)
    return info


def check_search_path(path: Path, info: ElfInfo, allowed: str) -> None:
    if info.rpath:
        raise PackageError(f"{path.name} has DT_RPATH {':'.join(info.rpath)}; only a DT_RUNPATH of {allowed} "
                           "is allowed")
    extra = [entry for entry in info.runpath if entry != allowed]
    if extra:
        raise PackageError(f"{path.name} has RUNPATH entries {extra} besides {allowed}, such as Zig's build-tree "
                           f".zig-cache path that the dynamic loader resolves against the current directory; "
                           f"rebuild with -Dpatch-rpath={ORIGIN_RUNPATH}")


def bundled_libraries(binary: Path, lib_dir: Path) -> list[tuple[str, Path]]:
    """(DT_NEEDED name, file) of every library that binary loads from lib_dir, transitively.

    The binary may only search $ORIGIN/../lib and the libraries only $ORIGIN; an unversioned
    DT_NEEDED (lib*.so) must be bundled, because only -dev packages provide such names."""
    binary, lib_dir = Path(binary), Path(lib_dir)
    info = elf_info(binary)
    check_search_path(binary, info, ORIGIN_RUNPATH)
    found: dict[str, Path] = {}
    pending = [(binary, name) for name in info.needed]
    while pending:
        user, name = pending.pop(0)
        if name in found:
            continue
        if not LIBRARY_NAME_RE.match(name):
            raise PackageError(f"{user.name} needs {name!r}, which is not a plain library file name")
        candidate = lib_dir / name
        if candidate.is_file():
            real = candidate.resolve()
            if real.parent != lib_dir.resolve():
                raise PackageError(f"{candidate} resolves outside {lib_dir}")
            library = elf_info(real)
            if library.machine != info.machine:
                raise PackageError(f"{candidate} targets ELF machine {library.machine:#x}, not {info.machine:#x}")
            check_search_path(real, library, "$ORIGIN")
            found[name] = real
            pending.extend((real, needed) for needed in library.needed)
        elif UNVERSIONED_RE.match(name):
            raise PackageError(f"{user.name} needs {name}, which no runtime package provides (unversioned "
                               f"SONAME), and {lib_dir} does not bundle it")
    if found and info.runpath != (ORIGIN_RUNPATH,):
        raise PackageError(f"{binary.name} needs the bundled {sorted(found)} but its RUNPATH is "
                           f"{':'.join(info.runpath) or 'unset'}, not {ORIGIN_RUNPATH}")
    return sorted(found.items())


def version_line(version_string: str) -> str:
    return f"  - version: {version_string}"


def check_prefix(prefix: Path, version_string: str, runner: Runner = subprocess.run) -> list[tuple[str, Path]]:
    prefix = Path(prefix)
    windows.plain_dir(prefix, f"prefix {prefix}")
    binary = prefix / "bin" / "ghostty"
    info = check_binary(binary, version_string)
    libraries = bundled_libraries(binary, prefix / "lib")
    if info.runpath != (ORIGIN_RUNPATH,):
        raise PackageError(f"{binary} has RUNPATH {':'.join(info.runpath) or 'unset'}, not {ORIGIN_RUNPATH}; "
                           f"build with -Dpatch-rpath={ORIGIN_RUNPATH}")
    env = {key: value for key, value in os.environ.items() if key != "LD_LIBRARY_PATH"}
    result = runner([str(binary), "+version"], capture_output=True, text=True, errors="replace", env=env,
                    stdin=subprocess.DEVNULL, timeout=120, check=False)
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0 or version_line(version_string) not in output.splitlines():
        raise PackageError(f"{binary} +version (exit {result.returncode}, LD_LIBRARY_PATH unset) did not print "
                           f"{version_line(version_string)!r}:\n{output.strip()}")
    print(f"PASS prefix {prefix}: ghostty {version_string}, RUNPATH {ORIGIN_RUNPATH}, bundled "
          f"{', '.join(name for name, _ in libraries) or 'nothing'}")
    return libraries


def required_packages(mode: str) -> tuple[str, ...]:
    if mode not in MODES:
        raise PackageError(f"unknown build mode {mode!r}")
    return tuple(sorted(BUILD_PACKAGES + (RESOURCE_PACKAGES if mode == "checkout" else ())))


def os_release(path: Path = Path("/etc/os-release")) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    values = {}
    for line in lines:
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip()] = value.strip().strip('"')
    return values


def missing_packages(packages: Iterable[str], runner: Runner = subprocess.run) -> list[str]:
    packages = list(packages)
    if shutil.which("dpkg-query") is None:
        raise PackageError("dpkg-query not found: this recipe targets Ubuntu 24.04 (apt and dpkg)")
    result = runner(["dpkg-query", "-W", "-f=${Package}\t${db:Status-Abbrev}\n", *packages],
                    capture_output=True, text=True, errors="replace", check=False)
    installed = set()
    for line in (result.stdout or "").splitlines():
        name, _, status = line.partition("\t")
        if status.startswith("ii"):
            installed.add(name.split(":", 1)[0])
    return [package for package in packages if package not in installed]


def apt_install_commands(packages: Iterable[str]) -> list[list[str]]:
    packages = list(packages)
    prefix = []
    if os.geteuid() != 0:
        sudo = shutil.which("sudo")
        if sudo is None:
            raise PackageError("installing apt packages needs root: run as root or install sudo")
        prefix = [sudo]
    apt = [*prefix, "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "-o", "DPkg::Lock::Timeout=600", "-o",
           "Acquire::Retries=5"]
    return [[*apt, "update"], [*apt, "install", "-y", "--no-install-recommends", *packages]]


def run(command: list[str], runner: Runner = subprocess.run, **kwargs) -> None:
    print("$ " + shlex.join(command), flush=True)
    result = runner(command, check=False, **kwargs)
    if result.returncode != 0:
        raise PackageError(f"{command[0]} failed with exit code {result.returncode}")


def ensure_deps(mode: str, *, install: bool = False, runner: Runner = subprocess.run) -> None:
    release = os_release()
    if (release.get("ID"), release.get("VERSION_ID")) != ("ubuntu", "24.04"):
        print(f"note: this recipe is tested on Ubuntu 24.04, not {release.get('PRETTY_NAME', 'this system')}")
    packages = required_packages(mode)
    missing = missing_packages(packages, runner)
    if missing and install:
        for command in apt_install_commands(missing):
            run(command, runner)
        missing = missing_packages(packages, runner)
    if missing:
        raise PackageError(f"missing apt packages for a {mode} build: {' '.join(missing)}; install them with "
                           f"`apt-get install --no-install-recommends {' '.join(missing)}` or rerun with "
                           "--install (deps) / --install-deps (build)")
    print(f"apt packages for a {mode} build: ok ({len(packages)})")


def tool_output(command: list[str], runner: Runner = subprocess.run) -> str | None:
    try:
        result = runner(command, capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL,
                        timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return (result.stdout or "").strip() if result.returncode == 0 else None


def check_patchelf(runner: Runner = subprocess.run) -> None:
    reported = tool_output(["patchelf", "--version"], runner)
    if reported != f"patchelf {PATCHELF_VERSION}":
        raise PackageError(f"-Dpatch-rpath needs patchelf {PATCHELF_VERSION} (Ubuntu 24.04's patchelf package), "
                           f"found {reported or 'none'}")
    print(f"patchelf {PATCHELF_VERSION}")


def system_versions(runner: Runner = subprocess.run) -> dict[str, str]:
    """pkg-config versions of the system GTK 4 and libadwaita that the app links against."""
    versions = {}
    for module in VERSION_MODULES:
        version = tool_output(["pkg-config", "--modversion", module], runner)
        if not version:
            raise PackageError(f"pkg-config cannot find {module}")
        versions[module] = version
    print("system libraries: " + ", ".join(f"{module} {version}" for module, version in versions.items()))
    return versions


def ensure_zig(root: Path = ROOT, runner: Runner = subprocess.run, env: Mapping[str, str] | None = None) -> None:
    env = zigw.child_env(os.environ if env is None else env, root)
    try:
        zig = zigw.require_zig(env, root)
    except zigw.ZigwError as error:
        if any(env.get(name, "").strip() for name in zigw.ENV_OVERRIDES):
            raise PackageError(str(error)) from error
        run([sys.executable, str(Path(root) / "scripts" / "setup_zig.py"), "--install"], runner, cwd=str(root))
        return
    print(f"zig {setup_zig.ZIG_VERSION}: {zig.path} ({zig.source})")


def blueprint_home(root: Path = ROOT) -> Path:
    return Path(root) / ".local" / "tools" / f"blueprint-compiler-{BLUEPRINT_VERSION}"


def reported_version(binary: Path, runner: Runner = subprocess.run) -> str | None:
    if not Path(binary).is_file():
        return None
    return tool_output([str(binary), "--version"], runner)


def safe_members(members: Iterable[tarfile.TarInfo], label: str) -> None:
    for member in members:
        parts = member.name.split("/")
        if member.name.startswith("/") or ".." in parts or not (member.isfile() or member.isdir() or member.issym()):
            raise PackageError(f"{label} has an unsafe member {member.name!r}")
        if member.issym() and (member.linkname.startswith("/") or ".." in member.linkname.split("/")):
            raise PackageError(f"{label} has a symlink {member.name!r} that leaves its directory")


def extract(bundle: tarfile.TarFile, destination: Path) -> None:
    if hasattr(tarfile, "data_filter"):
        bundle.extractall(destination, filter="data")
    else:
        bundle.extractall(destination)


def extract_tag_archive(archive: Path, destination: Path, commit: str) -> Path:
    """Extract a forge tag archive after checking its pax commit id; return its single top directory."""
    try:
        with tarfile.open(archive, "r:gz") as bundle:
            members = bundle.getmembers()
            if bundle.pax_headers.get("comment") != commit:
                raise PackageError(f"{Path(archive).name} is not the git archive of commit {commit}")
            tops = {member.name.split("/", 1)[0] for member in members}
            if len(tops) != 1:
                raise PackageError(f"{Path(archive).name} has {len(tops)} top-level entries")
            safe_members(members, Path(archive).name)
            extract(bundle, destination)
    except (tarfile.TarError, EOFError) as error:
        raise PackageError(f"cannot read {archive}: {error}") from error
    return Path(destination) / tops.pop()


def ensure_blueprint(root: Path = ROOT, *, cache: Path | None = None, offline: bool = False,
                     runner: Runner = subprocess.run, fetcher: Fetcher | None = None) -> Path:
    """Directory holding blueprint-compiler BLUEPRINT_VERSION, installed into blueprint_home() when missing."""
    home = blueprint_home(root)
    binary = home / "bin" / "blueprint-compiler"
    if reported_version(binary, runner) == BLUEPRINT_VERSION:
        print(f"blueprint-compiler {BLUEPRINT_VERSION}: {binary}")
        return binary.parent
    cache = windows.cache_dir(cache, root)
    errors = []
    archive = None
    for download in BLUEPRINTS:
        try:
            archive = (fetcher(download, cache) if fetcher is not None
                       else windows.fetch(download, cache, offline=offline))
            break
        except PackageError as error:
            errors.append(str(error))
    if archive is None:
        raise PackageError("cannot download blueprint-compiler: " + "; ".join(errors))
    with tempfile.TemporaryDirectory(prefix="gx-blueprint-") as temp:
        work = Path(temp)
        source = extract_tag_archive(archive, work, BLUEPRINT_COMMIT)
        shutil.rmtree(home, ignore_errors=True)
        run(["meson", "setup", str(work / "build"), str(source), f"--prefix={home}"], runner)
        run(["meson", "install", "-C", str(work / "build")], runner)
    version = reported_version(binary, runner)
    if version != BLUEPRINT_VERSION:
        raise PackageError(f"{binary} reports {version or 'nothing'}, not {BLUEPRINT_VERSION}")
    print(f"installed blueprint-compiler {BLUEPRINT_VERSION} into {home}")
    return binary.parent


def head_commit(root: Path) -> str:
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True,
                            errors="replace", check=False)
    sha = result.stdout.strip()
    if result.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise PackageError(f"cannot read HEAD of {root}: {result.stderr.strip() or sha}")
    return sha


def extract_source(tarball: Path, work: Path, version_string: str, commit: str) -> Path:
    """The source directory of a `zig build dist` tarball made from commit with version VS."""
    tarball = Path(tarball)
    windows.plain_file(tarball, f"source tarball {tarball}")
    top = f"ghostty-{version_string}"
    try:
        with tarfile.open(tarball, "r:gz") as bundle:
            members = bundle.getmembers()
            found = bundle.pax_headers.get("comment")
            if found != commit:
                raise PackageError(f"{tarball.name} is the git archive of {found or 'an unknown commit'}, not of this "
                                   f"checkout's HEAD {commit}")
            outside = [member.name for member in members if member.name.split("/", 1)[0] != top]
            if outside:
                raise PackageError(f"{tarball.name} has entries outside {top}/: {outside[:3]}")
            safe_members(members, tarball.name)
            extract(bundle, work)
    except (tarfile.TarError, EOFError, OSError) as error:
        raise PackageError(f"cannot read {tarball}: {error}") from error
    source = work / top
    version = (source / "VERSION").read_text(encoding="utf-8").strip() if (source / "VERSION").is_file() else None
    if version != version_string:
        raise PackageError(f"{tarball.name} has VERSION {version!r}, not {version_string}")
    absent = [path for path in DIST_RESOURCES if not (source / path).is_file()]
    if absent:
        raise PackageError(f"{tarball.name} lacks the generated resources {absent}; make it with `zig build dist`")
    return source


def prepare_prefix(prefix: Path) -> Path:
    prefix = Path(prefix).absolute()
    if prefix.is_symlink() or (prefix.exists() and (not prefix.is_dir() or any(prefix.iterdir()))):
        raise PackageError(f"--prefix {prefix} must not exist or be an empty directory")
    prefix.mkdir(parents=True, exist_ok=True)
    return prefix


def build(
    prefix: Path,
    version_string: str | None = None,
    *,
    root: Path = ROOT,
    source_tarball: Path | None = None,
    work_dir: Path | None = None,
    install_deps: bool = False,
    cache: Path | None = None,
    offline: bool = False,
    runner: Runner = subprocess.run,
    fetcher: Fetcher | None = None,
) -> list[tuple[str, Path]]:
    """Build the GTK app into prefix and check it; returns the bundled libraries."""
    root = Path(root)
    version_string = windows.check_version_string(version_string or gx_release.release_info(root).version_string,
                                                  root)
    commit = head_commit(root) if source_tarball is not None else None
    prefix = prepare_prefix(prefix)
    ensure_deps("tarball" if source_tarball is not None else "checkout", install=install_deps, runner=runner)
    check_patchelf(runner)
    system_versions(runner)
    ensure_zig(root, runner)
    env = dict(os.environ)
    if not env.get("ZIG_LOCAL_CACHE_DIR", "").strip():
        env["ZIG_LOCAL_CACHE_DIR"] = str(root / LOCAL_CACHE)
    temporary = None
    try:
        if source_tarball is None:
            tools = ensure_blueprint(root, cache=cache, offline=offline, runner=runner, fetcher=fetcher)
            env["PATH"] = str(tools) + os.pathsep + env.get("PATH", "")
            source = root
        else:
            if work_dir is None:
                temporary = Path(tempfile.mkdtemp(prefix=".gx-source-", dir=prefix.parent))
                work = temporary
            else:
                work = Path(work_dir).absolute()
                work.mkdir(parents=True, exist_ok=True)
            source = extract_source(Path(source_tarball), work, version_string, commit)
        run([sys.executable, str(root / "scripts" / "zigw.py"), "build", "--prefix", str(prefix), *BUILD_FLAGS,
             f"-Dversion-string={version_string}"], runner, cwd=str(source), env=env)
    finally:
        if temporary is not None:
            shutil.rmtree(temporary, ignore_errors=True)
    return check_prefix(prefix, version_string, runner)


def main(argv: list[str] | None = None) -> int:
    windows._utf8_stdio()
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog=__doc__.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    deps = commands.add_parser("deps", help="check (or install) the apt build dependencies")
    deps.add_argument("--mode", choices=MODES, default="checkout", help="source of the build (default checkout)")
    deps.add_argument("--install", action="store_true", help="apt-get install the missing packages")
    build_parser = commands.add_parser("build", help="build the GTK app into a new install prefix")
    build_parser.add_argument("--prefix", type=Path, required=True, help="new or empty install prefix")
    build_parser.add_argument("--version-string", help="VS; defaults to the one derived from this checkout")
    build_parser.add_argument("--source-tarball", type=Path, help="build from this ghostty-VS.tar.gz")
    build_parser.add_argument("--work-dir", type=Path, help="where the source tarball is extracted (kept)")
    build_parser.add_argument("--install-deps", action="store_true", help="apt-get install missing packages first")
    build_parser.add_argument("--cache-dir", type=Path, help="download cache for blueprint-compiler")
    build_parser.add_argument("--offline", action="store_true", help="use only cached downloads")
    check = commands.add_parser("check-prefix", help="check an install prefix of this recipe")
    check.add_argument("prefix", type=Path)
    check.add_argument("--version-string", help="VS; defaults to the one derived from this checkout")
    args = parser.parse_args(argv)
    if args.command == "build" and args.work_dir is not None and args.source_tarball is None:
        parser.error("--work-dir only applies to --source-tarball builds")
    try:
        if args.command == "deps":
            ensure_deps(args.mode, install=args.install)
        elif args.command == "build":
            build(args.prefix, args.version_string, source_tarball=args.source_tarball, work_dir=args.work_dir,
                  install_deps=args.install_deps, cache=args.cache_dir, offline=args.offline)
        else:
            version_string = windows.check_version_string(
                args.version_string or gx_release.release_info(ROOT).version_string, ROOT)
            check_prefix(args.prefix.absolute(), version_string)
    except (PackageError, gx_release.ReleaseError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
