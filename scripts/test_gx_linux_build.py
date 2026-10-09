"""Tests for scripts/gx_linux_build.py: synthetic ELF files, archives and fake runners, no network."""

from __future__ import annotations

import io
import os
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_linux_build as linux  # noqa: E402
import gx_release as release  # noqa: E402
import gx_windows_package as pkg  # noqa: E402

ROOT = SCRIPTS.parent
VS = release.release_info(ROOT).version_string
COMMIT = "c" * 40
LAYER_SHELL = "libgtk4-layer-shell.so"


def make_elf(needed: tuple[str, ...] = (), *, runpath: str | None = None, rpath: str | None = None,
             soname: str | None = None, machine: int = 0x3E, version: str = VS, base: int = 0x200000,
             extra: tuple[tuple[int, int], ...] = (), strtab_shift: int = 0) -> bytes:
    """A 64-bit little-endian ELF image: one PT_LOAD over the whole file, a PT_DYNAMIC, then the version."""
    strings = bytearray(b"\0")

    def add(text: str) -> int:
        offset = len(strings)
        strings.extend(text.encode("utf-8") + b"\0")
        return offset

    entries = [(linux.DT_NEEDED, add(name)) for name in needed]
    for tag, value in ((linux.DT_SONAME, soname), (linux.DT_RPATH, rpath), (linux.DT_RUNPATH, runpath)):
        if value is not None:
            entries.append((tag, add(value)))
    strtab = 64 + 2 * 56
    padding = -len(strings) % 8
    dynamic = strtab + len(strings) + padding
    entries += [(linux.DT_STRTAB, base + strtab + strtab_shift), (linux.DT_STRSZ, len(strings)), *extra,
                (linux.DT_NULL, 0)]
    table = b"".join(struct.pack("<qQ", tag, value) for tag, value in entries)
    trailer = version.encode("ascii") + b"\0"
    size = dynamic + len(table) + len(trailer)
    header = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack(
        "<HHIQQQIHHHHHH", 3, machine, 1, 0, 64, 0, 0, 64, 56, 2, 64, 0, 0)
    load = struct.pack("<IIQQQQQQ", linux.PT_LOAD, 5, 0, base, base, size, size, 0x1000)
    dyn = struct.pack("<IIQQQQQQ", linux.PT_DYNAMIC, 6, dynamic, base + dynamic, base + dynamic, len(table),
                      len(table), 8)
    return header + load + dyn + bytes(strings) + bytes(padding) + table + trailer


def write(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def symlinks_supported() -> bool:
    with tempfile.TemporaryDirectory() as temp:
        try:
            os.symlink("target", os.path.join(temp, "link"))
        except (OSError, NotImplementedError):
            return False
    return True


def completed(command, code: int = 0, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(command, code, stdout, stderr)


def tag_archive(path: Path, top: str, files: dict[str, bytes], comment: str | None,
                extra: tuple[tarfile.TarInfo, ...] = ()) -> Path:
    """A gzipped tarball like `git archive`: a pax global header whose comment is the commit id."""
    headers = {"comment": comment} if comment is not None else {}
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT, pax_headers=headers) as bundle:
        directory = tarfile.TarInfo(top)
        directory.type = tarfile.DIRTYPE
        directory.mode = 0o755
        bundle.addfile(directory)
        for name, data in files.items():
            info = tarfile.TarInfo(f"{top}/{name}")
            info.size = len(data)
            info.mode = 0o644
            bundle.addfile(info, io.BytesIO(data))
        for info in extra:
            bundle.addfile(info, io.BytesIO(b"x" * info.size) if info.isfile() else None)
    return path


def source_tarball(path: Path, *, commit: str = COMMIT, version: str = VS, resources: bool = True,
                   extra: tuple[tarfile.TarInfo, ...] = ()) -> Path:
    files = {"build.zig": b"// build\n", "VERSION": version.encode("ascii")}
    if resources:
        files.update({resource: b"generated\n" for resource in linux.DIST_RESOURCES})
    return tag_archive(path, f"ghostty-{VS}", files, commit, extra)


class ElfTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)

    def test_dynamic_entries_are_read_through_the_load_segment(self):
        path = write(self.base / "a", make_elf((LAYER_SHELL, "libc.so.6"), runpath="$ORIGIN/../lib:/x",
                                               soname="liba.so.1", rpath="/old"))
        info = linux.elf_info(path)
        self.assertEqual(info, linux.ElfInfo(0x3E, (LAYER_SHELL, "libc.so.6"), "liba.so.1", ("/old",),
                                             ("$ORIGIN/../lib", "/x")))

    def test_files_without_dynamic_entries(self):
        static = write(self.base / "static", b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
                       + struct.pack("<HH", 2, 0x3E) + bytes(44))
        self.assertEqual(linux.elf_info(static), linux.ElfInfo(0x3E, (), None, (), ()))
        bare = write(self.base / "bare", make_elf())
        self.assertEqual(linux.elf_info(bare).needed, ())

    def test_malformed_files_are_refused(self):
        valid = make_elf((LAYER_SHELL,), runpath="$ORIGIN/../lib")
        cases = {
            "not elf": (b"MZ" + bytes(100), "not a 64-bit little-endian ELF"),
            "32-bit": (valid[:4] + b"\x01" + valid[5:], "not a 64-bit little-endian ELF"),
            "short": (valid[:40], "not a 64-bit little-endian ELF"),
            "truncated headers": (valid[:100], "truncated program header table"),
            "duplicate runpath": (make_elf(runpath="a", extra=((linux.DT_RUNPATH, 1),)), "2 dynamic entries"),
            "strtab outside": (make_elf((LAYER_SHELL,), strtab_shift=1 << 24), "outside every loaded segment"),
            "string outside": (make_elf(extra=((linux.DT_NEEDED, 4096),)), "outside its string table"),
        }
        for label, (data, message) in cases.items():
            with self.subTest(case=label), self.assertRaisesRegex(pkg.PackageError, message):
                linux.elf_info(write(self.base / label.replace(" ", "-"), data))
        with self.assertRaisesRegex(pkg.PackageError, "cannot read"):
            linux.elf_info(self.base / "missing")

    def test_check_binary_needs_x86_64_and_the_version_string(self):
        good = write(self.base / "ghostty", make_elf(runpath="$ORIGIN/../lib"))
        self.assertEqual(linux.check_binary(good, VS).runpath, ("$ORIGIN/../lib",))
        with self.assertRaisesRegex(pkg.PackageError, "not x86-64"):
            linux.check_binary(write(self.base / "arm", make_elf(machine=0xB7)), VS)
        with self.assertRaisesRegex(pkg.PackageError, "does not embed the version string"):
            linux.check_binary(write(self.base / "stale", make_elf(version="1.0.0-gx.0.0.1")), VS)
        with self.assertRaisesRegex(pkg.PackageError, "missing"):
            linux.check_binary(self.base / "none", VS)


class BundledLibraryTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.prefix = Path(temp.name) / "prefix"
        self.lib = self.prefix / "lib"

    def binary(self, needed=(LAYER_SHELL, "libgtk-4.so.1", "libc.so.6"), **kwargs) -> Path:
        kwargs.setdefault("runpath", linux.ORIGIN_RUNPATH)
        return write(self.prefix / "bin" / "ghostty", make_elf(needed, **kwargs))

    def library(self, name: str, needed=("libgtk-4.so.1", "libc.so.6"), **kwargs) -> Path:
        return write(self.lib / name, make_elf(needed, soname=name, **kwargs))

    def test_the_bundled_library_is_found_and_system_libraries_are_not(self):
        library = self.library(LAYER_SHELL)
        write(self.lib / "libghostty-vt.so.0.1.0", make_elf(soname="libghostty-vt.so.0"))
        self.assertEqual(linux.bundled_libraries(self.binary(), self.lib), [(LAYER_SHELL, library.resolve())])

    def test_libraries_are_followed_transitively(self):
        self.library(LAYER_SHELL, needed=("libhelper.so", "libc.so.6"))
        self.library("libhelper.so", needed=(LAYER_SHELL, "libc.so.6"), runpath="$ORIGIN")
        found = [name for name, _ in linux.bundled_libraries(self.binary(), self.lib)]
        self.assertEqual(found, [LAYER_SHELL, "libhelper.so"])

    def test_search_path_problems_are_refused(self):
        cache_path = "/src/ghostty/.zig-cache/o/0123456789abcdef"
        cases = (
            ("unbundled", lambda: self.binary(), "no runtime package provides"),
            ("rpath", lambda: (self.library(LAYER_SHELL), self.binary(rpath="$ORIGIN/../lib")), "DT_RPATH"),
            ("zig cache", lambda: (self.library(LAYER_SHELL), self.binary(runpath=f"{cache_path}:$ORIGIN/../lib")),
             "RUNPATH entries"),
            ("library runpath", lambda: (self.library(LAYER_SHELL, runpath=cache_path), self.binary()),
             "RUNPATH entries"),
            ("no runpath", lambda: (self.library(LAYER_SHELL), self.binary(runpath=None)), "RUNPATH is unset"),
            ("machine", lambda: (self.library(LAYER_SHELL, machine=0xB7), self.binary()), "targets ELF machine"),
            ("name", lambda: self.binary(needed=("../evil.so",)), "not a plain library file name"),
        )
        for label, setup, message in cases:
            with self.subTest(case=label):
                for path in (self.prefix / "bin" / "ghostty", self.lib / LAYER_SHELL):
                    path.unlink(missing_ok=True)
                setup()
                with self.assertRaisesRegex(pkg.PackageError, message):
                    linux.bundled_libraries(self.prefix / "bin" / "ghostty", self.lib)

    @unittest.skipUnless(symlinks_supported(), "creating symlinks needs Developer Mode on Windows")
    def test_libraries_must_resolve_inside_the_directory(self):
        outside = write(self.prefix / "elsewhere" / LAYER_SHELL, make_elf(soname=LAYER_SHELL))
        self.lib.mkdir(parents=True)
        os.symlink(outside, self.lib / LAYER_SHELL)
        with self.assertRaisesRegex(pkg.PackageError, "resolves outside"):
            linux.bundled_libraries(self.binary(), self.lib)

    def test_check_prefix_runs_version_without_ld_library_path(self):
        self.library(LAYER_SHELL)
        binary = self.binary()
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs))
            return completed(command, stdout=f"Ghostty {VS}\n\nVersion\n  - version: {VS}\n  - channel: tip\n")

        with mock.patch.dict(os.environ, {"LD_LIBRARY_PATH": "/somewhere"}), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            libraries = linux.check_prefix(self.prefix, VS, runner)
        self.assertEqual([name for name, _ in libraries], [LAYER_SHELL])
        command, kwargs = calls[0]
        self.assertEqual(command, [str(binary), "+version"])
        self.assertNotIn("LD_LIBRARY_PATH", kwargs["env"])
        self.assertIn(f"PASS prefix {self.prefix}", stdout.getvalue())
        with self.assertRaisesRegex(pkg.PackageError, "did not print"):
            linux.check_prefix(self.prefix, VS, lambda command, **kwargs: completed(command, stdout="Ghostty\n"))
        with self.assertRaisesRegex(pkg.PackageError, "did not print"):
            linux.check_prefix(self.prefix, VS, lambda command, **kwargs: completed(command, 127, "", "error"))

    def test_check_prefix_needs_the_origin_runpath(self):
        self.binary(needed=("libc.so.6",), runpath=None)
        with self.assertRaisesRegex(pkg.PackageError, "has RUNPATH unset"):
            linux.check_prefix(self.prefix, VS, lambda command, **kwargs: self.fail("must not run"))


class DependencyTests(unittest.TestCase):
    def test_package_lists(self):
        checkout, tarball = linux.required_packages("checkout"), linux.required_packages("tarball")
        self.assertEqual(list(checkout), sorted(checkout))
        self.assertEqual(len(set(checkout)), len(checkout))
        self.assertLess(set(tarball), set(checkout))
        for package in ("dpkg-dev", "git", "libadwaita-1-dev", "libgtk-4-dev", "ncurses-bin", "patchelf",
                        "pkgconf", "python3"):
            self.assertIn(package, tarball)
        for package in ("meson", "ninja-build", "python3-gi", "gir1.2-gtk-4.0", "gir1.2-adw-1"):
            self.assertIn(package, checkout)
            self.assertNotIn(package, tarball)
        with self.assertRaisesRegex(pkg.PackageError, "unknown build mode"):
            linux.required_packages("nix")

    def test_os_release(self):
        with tempfile.TemporaryDirectory() as temp:
            path = write(Path(temp) / "os-release", b'NAME="Ubuntu"\r\nVERSION_ID="24.04"\nID=ubuntu\n# note\n')
            self.assertEqual(linux.os_release(path), {"NAME": "Ubuntu", "VERSION_ID": "24.04", "ID": "ubuntu"})
            self.assertEqual(linux.os_release(Path(temp) / "missing"), {})

    def test_missing_packages_reads_dpkg_query(self):
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            return completed(command, 1, "libgtk-4-dev:amd64\tii \npatchelf\tun \ngit\trc \n",
                             "dpkg-query: no packages found matching meson\n")

        with mock.patch.object(linux.shutil, "which", return_value="/usr/bin/dpkg-query"):
            missing = linux.missing_packages(["libgtk-4-dev", "patchelf", "git", "meson"], runner)
        self.assertEqual(missing, ["patchelf", "git", "meson"])
        self.assertEqual(calls[0][:3], ["dpkg-query", "-W", "-f=${Package}\t${db:Status-Abbrev}\n"])
        with mock.patch.object(linux.shutil, "which", return_value=None), \
                self.assertRaisesRegex(pkg.PackageError, "dpkg-query not found"):
            linux.missing_packages(["git"], runner)

    def test_apt_commands_use_root_or_sudo(self):
        with mock.patch.object(linux.os, "geteuid", return_value=0, create=True):
            update, install = linux.apt_install_commands(["git", "meson"])
        self.assertEqual(update, ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "-o", "DPkg::Lock::Timeout=600",
                                  "-o", "Acquire::Retries=5", "update"])
        self.assertEqual(install[-5:], ["install", "-y", "--no-install-recommends", "git", "meson"])
        with mock.patch.object(linux.os, "geteuid", return_value=1000, create=True), \
                mock.patch.object(linux.shutil, "which", return_value="/usr/bin/sudo"):
            self.assertEqual(linux.apt_install_commands(["git"])[0][0], "/usr/bin/sudo")
        with mock.patch.object(linux.os, "geteuid", return_value=1000, create=True), \
                mock.patch.object(linux.shutil, "which", return_value=None), \
                self.assertRaisesRegex(pkg.PackageError, "needs root"):
            linux.apt_install_commands(["git"])

    def test_ensure_deps_installs_then_checks_again(self):
        state = {"installed": False}
        commands = []

        def runner(command, **kwargs):
            commands.append(command)
            if command[0] == "dpkg-query":
                listed = command[3:] if state["installed"] else ["git"]
                return completed(command, stdout="".join(f"{name}\tii \n" for name in listed))
            if "install" in command:
                state["installed"] = True
            return completed(command)

        with mock.patch.object(linux.shutil, "which", return_value="/usr/bin/dpkg-query"), \
                mock.patch.object(linux.os, "geteuid", return_value=0, create=True), \
                mock.patch.object(linux, "os_release", return_value={"ID": "ubuntu", "VERSION_ID": "24.04"}), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            with self.assertRaisesRegex(pkg.PackageError, r"missing apt packages for a tarball build: .*--install-deps"):
                linux.ensure_deps("tarball", runner=runner)
            linux.ensure_deps("tarball", install=True, runner=runner)
        apt = [command for command in commands if "apt-get" in command]
        self.assertEqual([command[command.index("apt-get") + 5] for command in apt], ["update", "install"])
        self.assertNotIn("git", apt[1])
        self.assertIn("apt packages for a tarball build: ok", stdout.getvalue())
        self.assertNotIn("note:", stdout.getvalue())


class ToolTests(unittest.TestCase):
    def test_patchelf_is_pinned(self):
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            linux.check_patchelf(lambda command, **kwargs: completed(command, stdout="patchelf 0.18.0\n"))
        for runner in (lambda command, **kwargs: completed(command, stdout="patchelf 0.17.2\n"),
                       mock.Mock(side_effect=FileNotFoundError("patchelf"))):
            with self.assertRaisesRegex(pkg.PackageError, "needs patchelf 0.18.0"):
                linux.check_patchelf(runner)

    def test_system_versions(self):
        answers = {"gtk4": "4.14.5", "libadwaita-1": "1.5.0"}

        def runner(command, **kwargs):
            module = command[-1]
            return completed(command, 0 if module in answers else 1, answers.get(module, "") + "\n")

        with mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(linux.system_versions(runner), answers)
        self.assertIn("gtk4 4.14.5, libadwaita-1 1.5.0", stdout.getvalue())
        with self.assertRaisesRegex(pkg.PackageError, "pkg-config cannot find libadwaita-1"):
            linux.system_versions(lambda command, **kwargs: completed(command, 0 if command[-1] == "gtk4" else 1,
                                                                      "4.14.5"))

    def test_ensure_zig_installs_the_pin_only_when_needed(self):
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs.get("cwd")))
            return completed(command)

        found = linux.zigw.ResolvedZig("/opt/zig/zig", "PATH")
        with mock.patch.object(linux.zigw, "require_zig", return_value=found), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            linux.ensure_zig(ROOT, runner, env={})
        self.assertEqual(calls, [])
        self.assertIn("/opt/zig/zig (PATH)", stdout.getvalue())
        with mock.patch.object(linux.zigw, "require_zig", side_effect=linux.zigw.ZigwError("no zig")), \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            linux.ensure_zig(ROOT, runner, env={})
            self.assertEqual(calls, [([sys.executable, str(ROOT / "scripts" / "setup_zig.py"), "--install"],
                                      str(ROOT))])
            with self.assertRaisesRegex(pkg.PackageError, "no zig"):
                linux.ensure_zig(ROOT, runner, env={"ZIG": "/elsewhere/zig"})


class BlueprintTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.root = self.base / "root"
        self.binary = linux.blueprint_home(self.root) / "bin" / "blueprint-compiler"
        self.calls: list = []
        stdout = mock.patch("sys.stdout", new_callable=io.StringIO)
        stdout.start()
        self.addCleanup(stdout.stop)

    def archive(self, commit: str = linux.BLUEPRINT_COMMIT) -> Path:
        return tag_archive(self.base / "downloads" / f"{commit}.tar.gz", "blueprint-compiler-v0.16.0",
                           {"meson.build": b"project('blueprint-compiler')\n"}, commit)

    def runner(self, command, **kwargs):
        self.calls.append(command)
        if command[:2] == ["meson", "install"]:
            write(self.binary, b"#!/usr/bin/env python3\n")
        if command[-1] == "--version":
            return completed(command, stdout=linux.BLUEPRINT_VERSION + "\n")
        return completed(command)

    def test_pins(self):
        self.assertRegex(linux.BLUEPRINT_COMMIT, r"^[0-9a-f]{40}$")
        self.assertEqual(linux.BLUEPRINTS[0].sha256, "01feb8263fe7a450b0a9fed0fd54cf88947aaf00f86cc7da345f8b39a0e7bd30")
        self.assertTrue(linux.BLUEPRINTS[0].url.startswith("https://gitlab.gnome.org/GNOME/blueprint-compiler/"))
        self.assertEqual(len({download.name for download in linux.BLUEPRINTS}), len(linux.BLUEPRINTS))
        for download in linux.BLUEPRINTS:
            with self.subTest(download=download.name):
                self.assertRegex(download.sha256, r"^[0-9a-f]{64}$")
                self.assertTrue(download.url.startswith("https://"))
                self.assertIn(f"v{linux.BLUEPRINT_VERSION}", download.url)
                self.assertEqual(download.kind, "file")
                self.assertGreater(download.size, 0)

    def test_an_installed_pin_is_reused(self):
        write(self.binary, b"#!/usr/bin/env python3\n")
        fetcher = mock.Mock(side_effect=AssertionError("must not download"))
        self.assertEqual(linux.ensure_blueprint(self.root, runner=self.runner, fetcher=fetcher), self.binary.parent)
        self.assertEqual(self.calls, [[str(self.binary), "--version"]])

    def test_install_from_the_mirror_when_the_first_download_fails(self):
        archive = self.archive()
        fetched = []

        def fetcher(download, cache):
            fetched.append((download.name, cache))
            if download is linux.BLUEPRINTS[0]:
                raise pkg.PackageError("gitlab.gnome.org is down")
            return archive

        cache = self.base / "cache"
        self.assertEqual(linux.ensure_blueprint(self.root, cache=cache, runner=self.runner, fetcher=fetcher),
                         self.binary.parent)
        self.assertEqual(fetched, [(linux.BLUEPRINTS[0].name, cache), (linux.BLUEPRINTS[1].name, cache)])
        setup = next(command for command in self.calls if command[:2] == ["meson", "setup"])
        self.assertEqual(setup[-1], f"--prefix={linux.blueprint_home(self.root)}")
        self.assertTrue(setup[3].endswith("blueprint-compiler-v0.16.0"))
        self.assertIn(["meson", "install", "-C", setup[2]], self.calls)

    def test_wrong_archives_and_failed_downloads_are_refused(self):
        wrong = self.archive("d" * 40)
        with self.assertRaisesRegex(pkg.PackageError, "is not the git archive of commit"):
            linux.ensure_blueprint(self.root, runner=self.runner, fetcher=lambda download, cache: wrong)
        failing = mock.Mock(side_effect=pkg.PackageError("offline"))
        with self.assertRaisesRegex(pkg.PackageError, "cannot download blueprint-compiler: offline; offline"):
            linux.ensure_blueprint(self.root, runner=self.runner, fetcher=failing)
        self.assertFalse(any(command[0] == "meson" for command in self.calls))

    def test_offline_uses_only_the_cache(self):
        with self.assertRaisesRegex(pkg.PackageError, "--offline"):
            linux.ensure_blueprint(self.root, cache=self.base / "empty", offline=True, runner=self.runner)


class SourceTarballTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)

    def test_extracts_a_matching_dist_tarball(self):
        tarball = source_tarball(self.base / f"ghostty-{VS}.tar.gz")
        source = linux.extract_source(tarball, self.base / "work", VS, COMMIT)
        self.assertEqual(source, self.base / "work" / f"ghostty-{VS}")
        for resource in linux.DIST_RESOURCES:
            self.assertTrue((source / resource).is_file())

    def test_mismatches_are_refused(self):
        link = tarfile.TarInfo(f"ghostty-{VS}/escape")
        link.type, link.linkname = tarfile.SYMTYPE, "../../etc/passwd"
        dotdot = tarfile.TarInfo(f"ghostty-{VS}/../outside")
        dotdot.size = 1
        outside = tarfile.TarInfo("other/file")
        outside.size = 1
        cases = (
            ("commit", dict(commit="d" * 40), "not of this checkout's HEAD"),
            ("no commit", dict(commit=None), "an unknown commit"),
            ("version", dict(version="9.9.9-gx.9.9.9"), "has VERSION"),
            ("resources", dict(resources=False), "lacks the generated resources"),
            ("symlink", dict(extra=(link,)), "leaves its directory"),
            ("dotdot", dict(extra=(dotdot,)), "unsafe member"),
            ("outside", dict(extra=(outside,)), "entries outside"),
        )
        for index, (label, options, message) in enumerate(cases):
            with self.subTest(case=label):
                tarball = source_tarball(self.base / f"{index}.tar.gz", **options)
                with self.assertRaisesRegex(pkg.PackageError, message):
                    linux.extract_source(tarball, self.base / f"work-{index}", VS, COMMIT)
        with self.assertRaisesRegex(pkg.PackageError, "cannot read"):
            linux.extract_source(write(self.base / "bad.tar.gz", b"not gzip"), self.base / "w", VS, COMMIT)


class BuildTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.prefix = self.base / "prefix"
        self.calls: list = []
        self.steps: list = []
        patches = {
            "ensure_deps": lambda mode, install=False, runner=None: self.steps.append(("deps", mode, install)),
            "check_patchelf": lambda runner: self.steps.append(("patchelf",)),
            "system_versions": lambda runner: self.steps.append(("versions",)),
            "ensure_zig": lambda root, runner: self.steps.append(("zig",)),
            "ensure_blueprint": self.blueprint,
            "check_prefix": lambda prefix, version_string, runner: self.steps.append(("check", prefix)) or [],
            "head_commit": lambda root: COMMIT,
        }
        for name, replacement in patches.items():
            patcher = mock.patch.object(linux, name, side_effect=replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        stdout = mock.patch("sys.stdout", new_callable=io.StringIO)
        stdout.start()
        self.addCleanup(stdout.stop)

    def blueprint(self, root, *, cache=None, offline=False, runner=None, fetcher=None):
        self.steps.append(("blueprint", cache, offline))
        return self.base / "tools" / "bin"

    def runner(self, command, **kwargs):
        self.calls.append((command, kwargs))
        cwd = Path(kwargs["cwd"])
        self.assertTrue(cwd.is_dir())
        return completed(command)

    def test_checkout_build(self):
        env = {key: value for key, value in os.environ.items() if key != "ZIG_LOCAL_CACHE_DIR"}
        with mock.patch.dict(os.environ, env, clear=True):
            linux.build(self.prefix, VS, root=ROOT, cache=self.base / "cache", offline=True, runner=self.runner)
        self.assertEqual(self.steps, [("deps", "checkout", False), ("patchelf",), ("versions",), ("zig",),
                                      ("blueprint", self.base / "cache", True), ("check", self.prefix.absolute())])
        command, kwargs = self.calls[0]
        self.assertEqual(command, [sys.executable, str(ROOT / "scripts" / "zigw.py"), "build", "--prefix",
                                   str(self.prefix.absolute()), *linux.BUILD_FLAGS, f"-Dversion-string={VS}"])
        self.assertEqual(kwargs["cwd"], str(ROOT))
        self.assertEqual(kwargs["env"]["ZIG_LOCAL_CACHE_DIR"], str(ROOT / ".local" / "zig-cache" / "gx-linux-build"))
        self.assertTrue(kwargs["env"]["PATH"].startswith(str(self.base / "tools" / "bin") + os.pathsep))
        for flag in ("-Doptimize=ReleaseFast", "-fno-sys=gtk4-layer-shell", "-Dpatch-rpath=$ORIGIN/../lib",
                     "-Dapp-runtime=gtk", "-Dcpu=baseline"):
            self.assertIn(flag, linux.BUILD_FLAGS)

    def test_tarball_build_extracts_next_to_the_prefix_and_cleans_up(self):
        tarball = source_tarball(self.base / f"ghostty-{VS}.tar.gz")
        with mock.patch.dict(os.environ, {"ZIG_LOCAL_CACHE_DIR": str(self.base / "zig-local")}):
            linux.build(self.prefix, VS, root=ROOT, source_tarball=tarball, install_deps=True, runner=self.runner)
        self.assertEqual(self.steps[0], ("deps", "tarball", True))
        self.assertNotIn("blueprint", [step[0] for step in self.steps])
        command, kwargs = self.calls[0]
        source = Path(kwargs["cwd"])
        self.assertEqual(source.name, f"ghostty-{VS}")
        self.assertEqual(source.parent.parent, self.base)
        self.assertFalse(source.exists())
        self.assertEqual(kwargs["env"]["ZIG_LOCAL_CACHE_DIR"], str(self.base / "zig-local"))
        work = self.base / "work"
        linux.build(self.base / "prefix-2", VS, root=ROOT, source_tarball=tarball, work_dir=work, runner=self.runner)
        self.assertTrue((work / f"ghostty-{VS}" / "VERSION").is_file())

    def test_refusals_happen_before_building(self):
        write(self.prefix / "leftover", b"x")
        with self.assertRaisesRegex(pkg.PackageError, "must not exist or be an empty directory"):
            linux.build(self.prefix, VS, root=ROOT, runner=self.runner)
        with self.assertRaisesRegex(pkg.PackageError, "differs from"):
            linux.build(self.base / "new", "9.9.9-gx.9.9.9", root=ROOT, runner=self.runner)
        self.assertEqual((self.calls, self.steps), ([], []))

    def test_a_failed_build_is_reported(self):
        failing = lambda command, **kwargs: completed(command, 1)  # noqa: E731
        with self.assertRaisesRegex(pkg.PackageError, "failed with exit code 1"):
            linux.build(self.prefix, VS, root=ROOT, runner=failing)
        self.assertNotIn("check", [step[0] for step in self.steps])


class MainTests(unittest.TestCase):
    def test_usage_errors_and_failures(self):
        for argv in (["build", "--prefix", "p", "--work-dir", "w"], ["deps", "--mode", "nix"], ["build"], []):
            with self.subTest(argv=argv), mock.patch("sys.stderr", new_callable=io.StringIO), \
                    self.assertRaises(SystemExit) as raised:
                linux.main(argv)
            self.assertEqual(raised.exception.code, 2)
        with mock.patch.object(linux, "build", side_effect=pkg.PackageError("boom")) as build, \
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(linux.main(["build", "--prefix", "p", "--source-tarball", "t.tar.gz", "--work-dir", "w",
                                         "--install-deps", "--cache-dir", "c", "--offline"]), 1)
        self.assertIn("ERROR: boom", stderr.getvalue())
        _, kwargs = build.call_args
        self.assertEqual((kwargs["source_tarball"], kwargs["work_dir"], kwargs["install_deps"], kwargs["cache"],
                          kwargs["offline"]), (Path("t.tar.gz"), Path("w"), True, Path("c"), True))


if __name__ == "__main__":
    unittest.main()
