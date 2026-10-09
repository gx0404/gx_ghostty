"""Contract tests for scripts/gx_release.py: temp repositories, fake gh/git, no network."""

from __future__ import annotations

import copy
import io
import json
import os
import re
import shutil
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

SHA = "a" * 40
OTHER_SHA = "b" * 40
FORK = "0.1.0"
VS = "1.3.2-gx.0.1.0"
TAG = "gx-v0.1.0"
TITLE = "Ghostty GX 0.1.0"
REPO_URL = "https://github.com/gx0404/gx_ghostty"
MANUAL_ENV = {
    "GITHUB_ACTIONS": "true",
    "GITHUB_EVENT_NAME": "workflow_dispatch",
    "GITHUB_REPOSITORY": "gx0404/gx_ghostty",
    "GITHUB_WORKFLOW_REF": "gx0404/gx_ghostty/.github/workflows/gx-release.yml@refs/heads/gx_ghostty",
    "GX_PUBLISH": "true",
    "GH_TOKEN": "test-token",
}
CI_KEYS = (
    "GITHUB_ACTIONS", "GITHUB_EVENT_NAME", "GITHUB_REPOSITORY", "GITHUB_WORKFLOW_REF",
    "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "GX_PUBLISH", "GH_TOKEN",
)
CONTRACT_ASSETS = {
    f"libghostty-vt-{VS}.tar.gz",
    f"ghostty-{VS}.tar.gz",
    f"libghostty-vt-{VS}-x86_64-linux-gnu.tar.gz",
    f"libghostty-vt-{VS}-aarch64-linux-gnu.tar.gz",
    f"libghostty-vt-{VS}-x86_64-linux-musl.tar.gz",
    f"libghostty-vt-{VS}-wasm32-freestanding.tar.gz",
    f"libghostty-vt-{VS}-x86_64-windows-msvc.zip",
    f"ghostty-gx-{VS}-x86_64-linux-debian13.tar.gz",
    f"ghostty-gx-{VS}-x86_64-windows.zip",
    f"ghostty-gx-{VS}-x86_64-windows-setup.exe",
}
WINDOWS_ZIP = f"ghostty-gx-{VS}-x86_64-windows.zip"
WINDOWS_SETUP = f"ghostty-gx-{VS}-x86_64-windows-setup.exe"
TEST_INSTALLER_MIN_BYTES = 4096
CHANGELOG_BODY = "### Added\n\n- 条目"
MACOS_ASSETS = {
    f"libghostty-vt-{VS}-xcframework.zip",
    f"ghostty-gx-{VS}-universal-macos-unsigned.zip",
}


def write_root(base: Path, *, date: str | None = "2026-10-07", zon_version: str = "1.3.2-dev",
               zig: str = "0.16.0", pin: str = "0.16.0", newline: str = "\n") -> Path:
    root = base / "repo"
    (root / "scripts").mkdir(parents=True, exist_ok=True)
    changelog = [
        "# Changelog", "", f"## {FORK}({date or 'TBD'})", "", "### Added", "", "- 条目", "",
        "## 0.0.9(2026-01-01)", "", "- 旧条目", "",
    ]
    zon = [
        ".{", "    .name = .ghostty,", f'    .version = "{zon_version}",', '    .paths = .{""},',
        "    .fingerprint = 0x64407a2a0b4147e5,", f'    .minimum_zig_version = "{zig}",',
        "    .dependencies = .{", '        .libxev = .{ .url = "https://example.invalid/x.tar.gz", .hash = "x" },',
        "    },", "}", "",
    ]
    (root / "CHANGELOG.md").write_bytes(newline.join(changelog).encode("utf-8"))
    (root / "build.zig.zon").write_bytes(newline.join(zon).encode("utf-8"))
    (root / "scripts" / "setup_zig.py").write_bytes(
        newline.join(["import os", "", f'ZIG_VERSION = "{pin}"', 'INSTALL_DIR_NAME = f"zig-{ZIG_VERSION}"', ""]).encode()
    )
    return root


def asset_members(asset: release.Asset, version_string: str) -> tuple[dict[str, bytes], dict[str, str]]:
    files = {path: b"payload " + path.encode() for path in asset.required}
    links: dict[str, str] = {}
    if asset.version_file:
        files["VERSION"] = version_string.encode()
    for prefix in asset.required_prefixes:
        if prefix == "lib/libghostty-vt.so":
            files["lib/libghostty-vt.so.0.1.0"] = b"\x7fELF shared object"
            links["lib/libghostty-vt.so.0"] = "libghostty-vt.so.0.1.0"
            links["lib/libghostty-vt.so"] = "libghostty-vt.so.0"
        else:
            files[prefix + "themes/Example"] = b"palette = 0=#000000"
    for base in asset.required_basenames:
        files[f"bin/{base}"] = b"MZ dll"
    return files, links


def write_tar(path: Path, root: str, files: dict[str, bytes], links: dict[str, str] | None = None,
              extra: list[tarfile.TarInfo] | None = None) -> None:
    with tarfile.open(path, "w:gz") as archive:
        directories = {root}
        for name in [*files, *(links or {})]:
            parts = name.split("/")[:-1]
            for index in range(1, len(parts) + 1):
                directories.add("/".join([root, *parts[:index]]))
        for directory in sorted(directories):
            info = tarfile.TarInfo(directory)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            archive.addfile(info)
        for name, data in sorted(files.items()):
            info = tarfile.TarInfo(f"{root}/{name}")
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
        for name, target in sorted((links or {}).items()):
            info = tarfile.TarInfo(f"{root}/{name}")
            info.type = tarfile.SYMTYPE
            info.linkname = target
            archive.addfile(info)
        for info in extra or []:
            archive.addfile(info, io.BytesIO(b"x" * info.size) if info.isfile() else None)


def write_zip(path: Path, root: str, files: dict[str, bytes], *, backslashes: bool = False) -> None:
    separator = "\\" if backslashes else "/"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            archive.writestr(separator.join([root, *name.split("/")]), data)


def fake_installer(size: int = 2 * TEST_INSTALLER_MIN_BYTES, signature: bytes = b"PE\0\0") -> bytes:
    data = bytearray(size)
    data[0:2] = b"MZ"
    data[0x3C:0x40] = (0x80).to_bytes(4, "little")
    data[0x80:0x84] = signature
    return bytes(data)


def write_artifacts(folder: Path, *, macos: bool = False, version_string: str = VS,
                    skip: tuple[str, ...] = ()) -> dict[str, release.Asset]:
    folder.mkdir(parents=True, exist_ok=True)
    assets = release.expected_assets(version_string, macos)
    for name, asset in assets.items():
        if name in skip:
            continue
        if asset.kind == "installer":
            (folder / name).write_bytes(fake_installer())
            continue
        files, links = asset_members(asset, version_string)
        if name.endswith(".tar.gz"):
            write_tar(folder / name, asset.root, files, links)
        else:
            write_zip(folder / name, asset.root, files)
    return assets


def completed(args, returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(list(args), returncode, stdout, stderr)


class FakeRunner:
    """Stands in for git, gh and the release gates; records every command."""

    def __init__(self) -> None:
        self.sha = SHA
        self.status = ""
        self.origin = REPO_URL
        self.tag_commit: str | None = None
        self.annotated = False
        self.gate_codes: dict[str, int] = {}
        self.view_error: str | None = None
        self.releases: list[dict] = []
        self.assets: dict[int, list[dict]] = {}
        self.calls: list[list[str]] = []
        self.fail_upload = False
        self.tamper = None
        self.tag_during_upload: str | None = None
        self.tag_on_publish: str | None = None
        self.target_override: str | None = None
        self.prerelease_override: bool | None = None
        self.notes: str | None = None
        self.stale_listings = 0
        self.stale_assets = 0

    def __call__(self, args, *, cwd, env=None):
        args = [str(arg) for arg in args]
        self.calls.append(args)
        if args[0] == "git":
            return self.git(args)
        if args[0] == "gh":
            return self.gh(args)
        if args[0] == sys.executable:
            names = {argv[0]: name for name, argv in release.GATES}
            code = self.gate_codes.get(names[args[1]], 0)
            return completed(args, code, "gate output\n", "" if code == 0 else "gate failed\n")
        raise AssertionError(f"unexpected command {args}")

    def commands(self, program: str) -> list[list[str]]:
        return [call for call in self.calls if call[0] == program]

    def mutations(self) -> list[str]:
        result = []
        for call in self.commands("gh"):
            if call[1:3] in (["release", "create"], ["release", "upload"]):
                result.append(" ".join(call[1:3]))
            elif call[1] == "api" and "--method" in call:
                result.append("api " + call[call.index("--method") + 1])
        return result

    def git(self, args):
        rest = args[1:]
        if rest == ["rev-parse", "HEAD"]:
            return completed(args, stdout=self.sha + "\n")
        if rest == ["status", "--porcelain", "--untracked-files=all"]:
            return completed(args, stdout=self.status)
        if rest == ["config", "--get", "remote.origin.url"]:
            return completed(args, stdout=self.origin + "\n")
        if rest[:3] == ["ls-remote", "--tags", "origin"]:
            ref = rest[3]
            assert rest[4:] == [ref + "^{}"], rest
            if self.tag_commit is None:
                return completed(args)
            if self.annotated:
                return completed(args, stdout=f"{'c' * 40}\t{ref}\n{self.tag_commit}\t{ref}^{{}}\n")
            return completed(args, stdout=f"{self.tag_commit}\t{ref}\n")
        raise AssertionError(f"unexpected git command {args}")

    def release_by_id(self, release_id: int) -> dict:
        return next(item for item in self.releases if item["id"] == release_id)

    def gh(self, args):
        rest = args[1:]
        if rest[:2] == ["release", "view"]:
            if self.view_error is not None:
                return completed(args, 1, stderr=self.view_error)
            if any(item["tag_name"] == rest[2] for item in self.releases):
                return completed(args, stdout=json.dumps({"tagName": rest[2], "isDraft": True}))
            return completed(args, 1, stderr="release not found\n")
        if rest[:2] == ["release", "create"]:
            flags = rest[3:]
            values = {flags[i]: flags[i + 1] for i in range(len(flags) - 1) if flags[i].startswith("--")}
            self.notes = Path(values["--notes-file"]).read_text(encoding="utf-8")
            record = {
                "id": 42 + len(self.releases), "tag_name": rest[2], "name": values["--title"],
                "draft": "--draft" in flags,
                "prerelease": "--prerelease" in flags if self.prerelease_override is None else self.prerelease_override,
                "target_commitish": self.target_override or values["--target"], "body": self.notes,
            }
            self.releases.append(record)
            self.assets[record["id"]] = []
            return completed(args, stdout=f"https://github.com/gx0404/gx_ghostty/releases/tag/untagged-{record['id']}\n")
        if rest[:2] == ["release", "upload"]:
            if self.fail_upload:
                return completed(args, 1, stderr="HTTP 502: upload failed\n")
            record = next(item for item in self.releases if item["tag_name"] == rest[2])
            files = rest[3:rest.index("--repo")]
            for name in files:
                path = Path(name)
                if any(asset["name"] == path.name for asset in self.assets[record["id"]]):
                    return completed(args, 1, stderr=f"asset under the same name already exists: {path.name}\n")
                self.assets[record["id"]].append({
                    "name": path.name, "size": path.stat().st_size, "state": "uploaded",
                    "digest": "sha256:" + release.digest(path),
                })
            if self.tag_during_upload:
                self.tag_commit = self.tag_during_upload
            return completed(args)
        if rest[0] == "api":
            method = "GET"
            endpoint_args = rest[1:]
            if endpoint_args[0] == "--method":
                method, endpoint_args = endpoint_args[1], endpoint_args[2:]
            endpoint = endpoint_args[0]
            prefix = "repos/gx0404/gx_ghostty/releases"
            assert endpoint.startswith(prefix), endpoint
            tail = endpoint[len(prefix):]
            if method == "GET" and tail.startswith("?per_page=100&page="):
                page = int(tail.rsplit("=", 1)[1])
                listed = copy.deepcopy(self.releases) if page == 1 else []
                if self.stale_listings and any(item["draft"] for item in listed):
                    self.stale_listings -= 1
                    listed = [item for item in listed if not item["draft"]]
                return completed(args, stdout=json.dumps(listed))
            match = re.fullmatch(r"/(\d+)(/assets\?per_page=100)?", tail)
            assert match, endpoint
            record = self.release_by_id(int(match.group(1)))
            if match.group(2):
                assets = copy.deepcopy(self.assets[record["id"]])
                if self.tamper:
                    self.tamper(assets)
                if self.stale_assets:
                    self.stale_assets -= 1
                    for asset in assets:
                        asset["digest"] = None
                return completed(args, stdout=json.dumps(assets))
            if method == "PATCH":
                assert endpoint_args[1:] == ["-F", "draft=false"], endpoint_args
                record["draft"] = False
                if self.tag_commit is None:
                    self.tag_commit = self.tag_on_publish or record["target_commitish"]
            return completed(args, stdout=json.dumps(record))
        raise AssertionError(f"unexpected gh command {args}")


class EnvironmentCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        for key in CI_KEYS:
            os.environ.pop(key, None)
        self.root = write_root(self.base)
        self.runner = FakeRunner()
        run_patch = mock.patch.object(release, "run_command", self.runner)
        run_patch.start()
        self.addCleanup(run_patch.stop)
        sleep_patch = mock.patch.object(release.time, "sleep")
        sleep_patch.start()
        self.addCleanup(sleep_patch.stop)
        minimum_patch = mock.patch.object(release, "INSTALLER_MIN_BYTES", TEST_INSTALLER_MIN_BYTES)
        minimum_patch.start()
        self.addCleanup(minimum_patch.stop)


class ReleaseInfoTests(EnvironmentCase):
    def test_versions_tag_and_title_come_from_changelog_and_zon(self):
        info = release.release_info(self.root)
        self.assertEqual(info.fork_version, FORK)
        self.assertEqual(info.date, "2026-10-07")
        self.assertEqual(info.product_version, "1.3.2")
        self.assertEqual(info.zon_version, "1.3.2-dev")
        self.assertEqual(info.zig_version, "0.16.0")
        self.assertEqual((info.tag, info.title, info.version_string), (TAG, TITLE, VS))

    def test_crlf_files_and_plain_product_versions_are_accepted(self):
        for zon_version in ("1.3.2", "1.3.2-dev", "2.0.0-rc.1+build.5"):
            with self.subTest(zon_version=zon_version):
                root = write_root(self.base / zon_version, zon_version=zon_version, newline="\r\n")
                info = release.release_info(root)
                self.assertEqual(info.version_string, f"{zon_version.split('-')[0].split('+')[0]}-gx.{FORK}")
                self.assertEqual(info.zig_version, "0.16.0")

    def test_tbd_heading_has_no_date(self):
        root = write_root(self.base / "tbd", date=None)
        self.assertIsNone(release.release_info(root).date)

    def test_rejects_invalid_product_version_and_zig_drift(self):
        cases = (
            ({"zon_version": "1.3"}, "not a semantic version"),
            ({"zon_version": "v1.3.2"}, "not a semantic version"),
            ({"zon_version": "01.3.2"}, "not a semantic version"),
            ({"pin": "0.15.1"}, "differs from build.zig.zon"),
        )
        for index, (kwargs, message) in enumerate(cases):
            with self.subTest(kwargs=kwargs):
                root = write_root(self.base / f"case-{index}", **kwargs)
                with self.assertRaisesRegex(release.ReleaseError, message):
                    release.release_info(root)

    def test_rejects_missing_or_duplicate_zon_fields_and_missing_pin(self):
        zon = self.root / "build.zig.zon"
        original = zon.read_text(encoding="utf-8")
        zon.write_text(original.replace('    .minimum_zig_version = "0.16.0",\n', ""), encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "minimum_zig_version"):
            release.release_info(self.root)
        zon.write_text(original.replace('.paths = .{""},', '.version = "9.9.9",'), encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "more than once"):
            release.release_info(self.root)
        zon.write_text(original, encoding="utf-8")
        (self.root / "scripts" / "setup_zig.py").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "setup_zig.py"):
            release.release_info(self.root)

    def test_rejects_changelog_without_valid_version_heading(self):
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "CHANGELOG.md"):
            release.release_info(self.root)
        (self.root / "CHANGELOG.md").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "CHANGELOG.md"):
            release.release_info(self.root)

    def test_changelog_section_is_the_body_under_the_version_heading(self):
        self.assertEqual(release.changelog_section(self.root, FORK), CHANGELOG_BODY)
        self.assertEqual(release.changelog_section(self.root, "0.0.9"), "- 旧条目")
        crlf = write_root(self.base / "crlf", newline="\r\n")
        self.assertEqual(release.changelog_section(crlf, FORK), CHANGELOG_BODY)
        text = "\n".join([
            "# Changelog", "", "## 0.2.0(2026-10-09)", "", "### Fixed", "", "```text", "## not a heading", "```",
            "", "- 修复  ", "", "## 0.1.0(2026-10-01)", "", "- 旧", "",
        ])
        (self.root / "CHANGELOG.md").write_text(text, encoding="utf-8")
        self.assertEqual(release.changelog_section(self.root, "0.2.0"),
                         "### Fixed\n\n```text\n## not a heading\n```\n\n- 修复")
        self.assertEqual(release.changelog_section(self.root, "0.1.0"), "- 旧")
        with self.assertRaisesRegex(release.ReleaseError, "no ## 0.3.0 heading"):
            release.changelog_section(self.root, "0.3.0")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.2.0(TBD)\n\n\n## 0.1.0(2026-10-01)\n\n- 旧\n",
                                                encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "section ## 0.2.0 is empty"):
            release.changelog_section(self.root, "0.2.0")


class PrepareTests(EnvironmentCase):
    def setUp(self) -> None:
        super().setUp()
        self.output = self.base / "github_output"
        os.environ["GITHUB_OUTPUT"] = str(self.output)

    def gate_scripts(self) -> list[str]:
        return [call[1] for call in self.runner.commands(sys.executable)]

    def test_build_only_runs_all_gates_and_writes_exact_outputs(self):
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            outputs = release.prepare(self.root, False)
        expected = {"sha": SHA, "version": FORK, "tag": TAG, "version_string": VS, "zig": "0.16.0"}
        self.assertEqual(outputs, expected)
        self.assertEqual(self.output.read_bytes().decode("utf-8"),
                         "".join(f"{key}={value}\n" for key, value in expected.items()))
        self.assertEqual(self.gate_scripts(), [argv[0] for _, argv in release.GATES])
        gate_args = [call[1:] for call in self.runner.commands(sys.executable)]
        self.assertEqual(gate_args, [list(argv) for _, argv in release.GATES])
        self.assertEqual(self.runner.commands("gh"), [])
        self.assertFalse(any(call[1] == "ls-remote" for call in self.runner.commands("git")))

    def test_build_only_accepts_a_tbd_heading(self):
        root = write_root(self.base / "tbd", date=None)
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(release.prepare(root, False)["version"], FORK)

    def test_dirty_checkout_is_refused_before_any_gate(self):
        self.runner.status = "?? stray.txt\n"
        with self.assertRaisesRegex(release.ReleaseError, "clean checkout"):
            release.prepare(self.root, False)
        self.assertEqual(self.gate_scripts(), [])
        self.assertFalse(self.output.exists())

    def test_each_failing_gate_stops_preparation(self):
        for name, argv in release.GATES:
            with self.subTest(gate=name):
                self.runner.calls.clear()
                self.runner.gate_codes = {name: 1}
                with mock.patch("sys.stdout", new_callable=io.StringIO), \
                        self.assertRaisesRegex(release.ReleaseError, f"gate '{name}' failed"):
                    release.prepare(self.root, False)
                self.assertEqual(self.gate_scripts()[-1], argv[0])
                self.assertFalse(self.output.exists())

    def test_publish_requires_a_dated_heading_before_running_gates(self):
        root = write_root(self.base / "tbd", date=None)
        with self.assertRaisesRegex(release.ReleaseError, r"dated heading.*0\.1\.0\(TBD\)"):
            release.prepare(root, True)
        self.assertEqual(self.gate_scripts(), [])

    def test_publish_requires_release_notes_but_build_only_does_not(self):
        root = write_root(self.base / "empty")
        changelog = root / "CHANGELOG.md"
        changelog.write_text(changelog.read_text(encoding="utf-8").replace("### Added\n\n- 条目\n", ""),
                             encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "is empty"):
            release.prepare(root, True)
        self.assertEqual(self.gate_scripts(), [])
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(release.prepare(root, False)["version"], FORK)

    def test_publish_checks_tag_and_release_absence(self):
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            outputs = release.prepare(self.root, True)
        self.assertEqual(outputs["tag"], TAG)
        self.assertIn(["git", "ls-remote", "--tags", "origin", f"refs/tags/{TAG}", f"refs/tags/{TAG}^{{}}"],
                      self.runner.calls)
        self.assertIn(["gh", "release", "view", TAG, "--repo", "gx0404/gx_ghostty", "--json", "tagName,isDraft"],
                      self.runner.calls)
        self.assertEqual(self.runner.mutations(), [])

    def test_publish_refuses_existing_tags_releases_foreign_origin_and_gh_errors(self):
        cases = (
            ("lightweight tag", {"tag_commit": SHA}, "already exists on origin"),
            ("annotated tag", {"tag_commit": OTHER_SHA, "annotated": True}, "already exists on origin"),
            ("release", {"releases": [{"id": 7, "tag_name": TAG, "draft": False}]}, "already exists"),
            ("gh failure", {"view_error": "HTTP 401: Bad credentials\n"}, "gh release view"),
            ("foreign origin", {"origin": "https://github.com/ghostty-org/ghostty.git"}, "not gx0404/gx_ghostty"),
        )
        for label, state, message in cases:
            with self.subTest(case=label):
                self.runner = FakeRunner()
                for key, value in state.items():
                    setattr(self.runner, key, value)
                with mock.patch.object(release, "run_command", self.runner), \
                        mock.patch("sys.stdout", new_callable=io.StringIO), \
                        self.assertRaisesRegex(release.ReleaseError, message):
                    release.prepare(self.root, True)
                self.assertFalse(self.output.exists())
                self.assertEqual(self.runner.mutations(), [])

    def test_origin_url_forms_for_the_fork_are_accepted(self):
        for url in (REPO_URL, REPO_URL + ".git", REPO_URL + "/", "git@github.com:gx0404/gx_ghostty.git",
                    "ssh://git@github.com/gx0404/gx_ghostty", "https://github.com/GX0404/GX_GHOSTTY"):
            with self.subTest(url=url):
                self.runner.origin = url
                release.require_origin(self.root)

    def test_summary_is_written_when_requested(self):
        summary_file = self.base / "summary.md"
        os.environ["GITHUB_STEP_SUMMARY"] = str(summary_file)
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            release.prepare(self.root, False)
        text = summary_file.read_text(encoding="utf-8")
        self.assertIn(VS, text)
        self.assertIn("build and verify only", text)


class VerifyTests(EnvironmentCase):
    def setUp(self) -> None:
        super().setUp()
        self.folder = self.base / "artifacts"
        self.assets = write_artifacts(self.folder)

    def verify(self, **kwargs):
        return release.verify_artifacts(self.root, self.folder, SHA, **kwargs)

    def test_expected_asset_names_match_the_release_contract(self):
        self.assertEqual(set(release.expected_assets(VS)), CONTRACT_ASSETS)
        self.assertEqual(set(release.expected_assets(VS, macos=True)), CONTRACT_ASSETS | MACOS_ASSETS)

    def test_writes_deterministic_manifest_and_checksums(self):
        files = self.verify()
        names = [path.name for path in files]
        self.assertEqual(names[-2:], [release.MANIFEST, release.SUMS])
        self.assertEqual(set(names[:-2]), CONTRACT_ASSETS)
        manifest_bytes = (self.folder / release.MANIFEST).read_bytes()
        self.assertNotIn(b"\r", manifest_bytes)
        manifest = json.loads(manifest_bytes)
        self.assertEqual(manifest["schema_version"], 2)
        self.assertEqual(manifest["repository"], "gx0404/gx_ghostty")
        self.assertEqual((manifest["tag"], manifest["name"], manifest["version_string"]), (TAG, TITLE, VS))
        self.assertEqual((manifest["fork_version"], manifest["product_version"]), (FORK, "1.3.2"))
        self.assertEqual(manifest["source_commit"], SHA)
        self.assertNotIn("prerelease", manifest)
        self.assertIs(manifest["macos"], False)
        self.assertEqual([entry["name"] for entry in manifest["assets"]], sorted(CONTRACT_ASSETS))
        for entry in manifest["assets"]:
            path = self.folder / entry["name"]
            self.assertEqual(entry["sha256"], release.digest(path))
            self.assertEqual(entry["size"], path.stat().st_size)
            self.assertEqual(entry["kind"], self.assets[entry["name"]].kind)
        sums = (self.folder / release.SUMS).read_bytes().decode("ascii")
        lines = sums.splitlines()
        self.assertEqual(len(lines), len(CONTRACT_ASSETS) + 1)
        self.assertEqual([line.split("  ", 1)[1] for line in lines], sorted([*CONTRACT_ASSETS, release.MANIFEST]))
        for line in lines:
            checksum, name = line.split("  ", 1)
            self.assertRegex(line, r"^[0-9a-f]{64}  \S+$")
            self.assertEqual(checksum, release.digest(self.folder / name))
        self.assertTrue(sums.endswith("\n"))
        self.assertEqual(self.verify(), files)
        self.assertEqual((self.folder / release.MANIFEST).read_bytes(), manifest_bytes)

    def test_manifest_records_macos_assets_when_requested(self):
        folder = self.base / "macos"
        write_artifacts(folder, macos=True)
        release.verify_artifacts(self.root, folder, SHA, macos=True)
        manifest = json.loads((folder / release.MANIFEST).read_text(encoding="utf-8"))
        self.assertIs(manifest["macos"], True)
        self.assertEqual({entry["name"] for entry in manifest["assets"]}, CONTRACT_ASSETS | MACOS_ASSETS)

    def test_macos_flag_controls_the_expected_set(self):
        with self.assertRaisesRegex(release.ReleaseError, "missing"):
            self.verify(macos=True)
        folder = self.base / "macos"
        write_artifacts(folder, macos=True)
        with self.assertRaisesRegex(release.ReleaseError, "unexpected"):
            release.verify_artifacts(self.root, folder, SHA, macos=False)

    def test_refuses_missing_extra_empty_and_symlinked_files(self):
        name = f"libghostty-vt-{VS}-x86_64-linux-gnu.tar.gz"
        path = self.folder / name
        moved = self.base / "moved"
        path.rename(moved)
        with self.assertRaisesRegex(release.ReleaseError, "missing"):
            self.verify()
        moved.rename(path)
        (self.folder / "notes.txt").write_text("stray", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "unexpected.*notes.txt"):
            self.verify()
        (self.folder / "notes.txt").unlink()
        data = path.read_bytes()
        path.write_bytes(b"")
        with self.assertRaisesRegex(release.ReleaseError, "empty"):
            self.verify()
        path.write_bytes(data)
        with mock.patch.object(Path, "is_symlink", lambda self: self.name == name):
            with self.assertRaisesRegex(release.ReleaseError, "symlink"):
                self.verify()

    def test_refuses_wrong_embedded_version(self):
        for name in (f"libghostty-vt-{VS}.tar.gz", f"ghostty-{VS}.tar.gz"):
            with self.subTest(name=name):
                asset = self.assets[name]
                files, links = asset_members(asset, VS)
                files["VERSION"] = b"1.3.2-dev"
                write_tar(self.folder / name, asset.root, files, links)
                with self.assertRaisesRegex(release.ReleaseError, "embedded VERSION"):
                    self.verify()
                files["VERSION"] = (VS + "\n").encode()
                write_tar(self.folder / name, asset.root, files, links)
                self.verify()
                for generated in (release.MANIFEST, release.SUMS):
                    (self.folder / generated).unlink()

    def test_refuses_oversized_libghostty_vt_source(self):
        with mock.patch.object(release, "SOURCE_LIBVT_MAX_BYTES", 64):
            with self.assertRaisesRegex(release.ReleaseError, "byte limit"):
                self.verify()

    def test_refuses_archives_missing_required_layout(self):
        cases = (
            (f"libghostty-vt-{VS}-x86_64-linux-gnu.tar.gz", "lib/libghostty-vt.a"),
            (f"libghostty-vt-{VS}-aarch64-linux-gnu.tar.gz", "lib/libghostty-vt.so.0.1.0"),
            (f"libghostty-vt-{VS}-wasm32-freestanding.tar.gz", "bin/ghostty-vt.wasm"),
            (f"libghostty-vt-{VS}-x86_64-windows-msvc.zip", "bin/ghostty-vt.dll"),
            (f"ghostty-gx-{VS}-x86_64-linux-debian13.tar.gz", "usr/bin/ghostty"),
            (f"ghostty-{VS}.tar.gz", "src/apprt/gtk/ghostty_resources.c"),
            (f"libghostty-vt-{VS}.tar.gz", "CMakeLists.txt"),
            (WINDOWS_ZIP, "conpty.dll"),
            (WINDOWS_ZIP, "mesa/libgallium_wgl.dll"),
            (WINDOWS_ZIP, "fonts/NotoSansCJK-Regular.ttc"),
            (WINDOWS_ZIP, "README.txt"),
        )
        for name, removed in cases:
            with self.subTest(name=name, removed=removed):
                asset = self.assets[name]
                files, links = asset_members(asset, VS)
                files.pop(removed)
                if removed.startswith("lib/libghostty-vt.so"):
                    links = {}
                if name.endswith(".zip"):
                    write_zip(self.folder / name, asset.root, files)
                else:
                    write_tar(self.folder / name, asset.root, files, links)
                with self.assertRaisesRegex(release.ReleaseError, "lacks"):
                    self.verify()
                write_artifacts(self.folder)

    def test_windows_app_assets_follow_the_contract(self):
        assets = release.expected_assets(VS)
        portable = assets[WINDOWS_ZIP]
        self.assertEqual((portable.kind, portable.target, portable.root), ("app", "x86_64-windows", WINDOWS_ZIP[:-4]))
        for required in ("ghostty.exe", "conpty.dll", "OpenConsole.exe", "mesa/opengl32.dll", "mesa/libgallium_wgl.dll",
                         "share/terminfo/ghostty.terminfo", "README.txt", *(f"fonts/{name}" for name in release.WINDOWS_FONTS)):
            self.assertIn(required, portable.required)
        self.assertIn("share/ghostty/", portable.required_prefixes)
        setup = assets[WINDOWS_SETUP]
        self.assertEqual((setup.kind, setup.target, setup.min_bytes), ("installer", "x86_64-windows", TEST_INSTALLER_MIN_BYTES))
        with mock.patch.object(release, "INSTALLER_MIN_BYTES", 16 * 1024 * 1024):
            self.assertEqual(release.expected_assets(VS)[WINDOWS_SETUP].min_bytes, 16 * 1024 * 1024)

    def test_refuses_installers_without_pe_headers_or_payload(self):
        path = self.folder / WINDOWS_SETUP
        cases = (
            ("text", b"#!/bin/sh\n" + b"x" * (2 * TEST_INSTALLER_MIN_BYTES), "no MZ header"),
            ("no pe", fake_installer(signature=b"NE\0\0"), "no PE signature"),
            ("truncated", fake_installer(size=TEST_INSTALLER_MIN_BYTES - 1), "below the 4096 byte minimum"),
        )
        for label, data, message in cases:
            with self.subTest(case=label):
                path.write_bytes(data)
                with self.assertRaisesRegex(release.ReleaseError, message):
                    self.verify()
        path.write_bytes(fake_installer())
        self.verify()

    def test_accepts_windows_zip_with_backslash_separators(self):
        name = f"libghostty-vt-{VS}-x86_64-windows-msvc.zip"
        asset = self.assets[name]
        files, _ = asset_members(asset, VS)
        write_zip(self.folder / name, asset.root, files, backslashes=True)
        self.verify()

    def test_refuses_unsafe_or_misplaced_members(self):
        name = f"libghostty-vt-{VS}-x86_64-linux-gnu.tar.gz"
        asset = self.assets[name]
        files, links = asset_members(asset, VS)
        variants = []
        for member in ("../escape", "/etc/passwd", "other-root/file", f"{asset.root}/../x"):
            info = tarfile.TarInfo(member)
            info.size = 1
            variants.append(("member", [info], {}))
        variants.append(("absolute link", [], {"lib/evil": "/etc/passwd"}))
        variants.append(("escaping link", [], {"lib/evil": "../../../outside"}))
        device = tarfile.TarInfo(f"{asset.root}/dev/null")
        device.type = tarfile.CHRTYPE
        variants.append(("device", [device], {}))
        for label, extra, extra_links in variants:
            with self.subTest(case=label, extra=[info.name for info in extra]):
                write_tar(self.folder / name, asset.root, files, {**links, **extra_links}, extra)
                with self.assertRaises(release.ReleaseError):
                    self.verify()
        zip_name = f"libghostty-vt-{VS}-x86_64-windows-msvc.zip"
        with zipfile.ZipFile(self.folder / zip_name, "a") as archive:
            archive.writestr("../escape.dll", b"x")
        write_artifacts(self.folder, skip=(zip_name,))
        with self.assertRaisesRegex(release.ReleaseError, "unsafe member"):
            self.verify()

    def test_refuses_corrupt_archives(self):
        for name in (f"libghostty-vt-{VS}-x86_64-linux-musl.tar.gz", f"libghostty-vt-{VS}-x86_64-windows-msvc.zip"):
            with self.subTest(name=name):
                (self.folder / name).write_bytes(b"not an archive at all")
                with self.assertRaisesRegex(release.ReleaseError, "readable archive"):
                    self.verify()
                write_artifacts(self.folder)
        name = f"ghostty-{VS}.tar.gz"
        data = (self.folder / name).read_bytes()
        (self.folder / name).write_bytes(data[: len(data) // 2])
        with self.assertRaisesRegex(release.ReleaseError, "readable archive"):
            self.verify()

    def test_refuses_to_overwrite_a_different_manifest_or_checksum_file(self):
        self.verify()
        for generated in (release.MANIFEST, release.SUMS):
            with self.subTest(file=generated):
                path = self.folder / generated
                original = path.read_bytes()
                path.write_bytes(original.replace(b"\n", b"\r\n"))
                with self.assertRaisesRegex(release.ReleaseError, "refusing to overwrite"):
                    self.verify()
                path.write_bytes(original)
        asset = self.folder / f"libghostty-vt-{VS}-wasm32-freestanding.tar.gz"
        files, links = asset_members(self.assets[asset.name], VS)
        files["bin/extra.txt"] = b"changed after verify"
        write_tar(asset, self.assets[asset.name].root, files, links)
        with self.assertRaisesRegex(release.ReleaseError, "manifest.json differs"):
            self.verify()

    def test_requires_the_prepared_checkout_and_version_string(self):
        with self.assertRaisesRegex(release.ReleaseError, "full 40-character"):
            release.verify_artifacts(self.root, self.folder, SHA[:12])
        with self.assertRaisesRegex(release.ReleaseError, "full 40-character"):
            release.verify_artifacts(self.root, self.folder, SHA.upper())
        self.runner.sha = OTHER_SHA
        with self.assertRaisesRegex(release.ReleaseError, "not " + SHA):
            self.verify()
        self.runner.sha = SHA
        with self.assertRaisesRegex(release.ReleaseError, "differs from"):
            self.verify(version_string="1.3.2-gx.0.2.0")
        self.verify(version_string=VS)

    def test_refuses_a_missing_artifact_directory(self):
        with self.assertRaisesRegex(release.ReleaseError, "not a real directory"):
            release.verify_artifacts(self.root, self.base / "absent", SHA)


class PublishTests(EnvironmentCase):
    def setUp(self) -> None:
        super().setUp()
        os.environ.update(MANUAL_ENV)
        self.folder = self.base / "artifacts"
        write_artifacts(self.folder)
        stdout = mock.patch("sys.stdout", new_callable=io.StringIO)
        stdout.start()
        self.addCleanup(stdout.stop)

    def publish(self):
        return release.publish(self.root, self.folder, SHA)

    def uploaded(self) -> set[str]:
        return {asset["name"] for assets in self.runner.assets.values() for asset in assets}

    def test_drafts_uploads_checks_digests_then_publishes_a_formal_release(self):
        url = self.publish()
        self.assertEqual(url, f"https://github.com/gx0404/gx_ghostty/releases/tag/{TAG}")
        self.assertEqual(self.runner.mutations(), ["release create", "release upload", "api PATCH"])
        create = next(call for call in self.runner.commands("gh") if call[1:3] == ["release", "create"])
        self.assertEqual(create[3], TAG)
        self.assertIn("--draft", create)
        self.assertNotIn("--prerelease", create)
        self.assertEqual(create[create.index("--target") + 1], SHA)
        self.assertEqual(create[create.index("--title") + 1], TITLE)
        self.assertEqual(create[create.index("--repo") + 1], "gx0404/gx_ghostty")
        self.assertEqual(self.uploaded(), CONTRACT_ASSETS | {release.MANIFEST, release.SUMS})
        record = self.runner.releases[0]
        self.assertIs(record["draft"], False)
        self.assertIs(record["prerelease"], False)
        self.assertEqual(self.runner.tag_commit, SHA)
        self.assertFalse(any("--clobber" in call for call in self.runner.calls))
        notes = self.runner.notes
        self.assertTrue(notes.startswith(CHANGELOG_BODY + "\n\n<!-- gx-release source="), notes[:200])
        self.assertNotIn("旧条目", notes)
        self.assertNotIn("预发布", notes)
        self.assertIn(SHA, notes)
        self.assertIn(VS, notes)
        self.assertIn("sha256sum -c SHA256SUMS", notes)
        for name in (WINDOWS_ZIP, WINDOWS_SETUP):
            self.assertRegex(notes, rf"\| `{name}` \| Ghostty GX Windows ")
        self.assertLess(notes.index(CHANGELOG_BODY), notes.index("| 资产 | 说明 |"))
        self.assertTrue(notes.endswith("\n".join(release.DISCLAIMER) + "\n"), notes[-400:])
        self.assertIn("> Ghostty GX 是 Ghostty 的非官方分支，由 gx0404 维护，与 Ghostty 团队无关，未获其认可或背书。", notes)
        self.assertIn("> Ghostty GX is an unofficial fork of Ghostty maintained by gx0404. "
                      "It is not affiliated with or endorsed by the Ghostty project.", notes)
        self.assertNotIn("Ghostty GTK app", notes)

    def test_a_draft_marked_as_prerelease_is_not_published(self):
        self.runner.prerelease_override = True
        with self.assertRaisesRegex(release.ReleaseError, "prerelease=True"):
            self.publish()
        self.assertEqual(self.runner.mutations(), ["release create"])

    def test_guard_rejects_runs_outside_the_manual_fork_workflow(self):
        variants = [
            ("GITHUB_ACTIONS", None), ("GITHUB_EVENT_NAME", "push"),
            ("GITHUB_REPOSITORY", "ghostty-org/ghostty"), ("GX_PUBLISH", "false"),
            ("GITHUB_WORKFLOW_REF", "gx0404/gx_ghostty/.github/workflows/gx-ci.yml@refs/heads/gx_ghostty"),
            ("GH_TOKEN", ""),
        ]
        for key, value in variants:
            with self.subTest(key=key, value=value), mock.patch.dict(os.environ):
                if value is None:
                    os.environ.pop(key)
                else:
                    os.environ[key] = value
                with self.assertRaisesRegex(release.ReleaseError, "manual"):
                    self.publish()
        self.assertEqual(self.runner.calls, [])

    def test_never_reuses_a_tag_or_overwrites_a_release_or_draft(self):
        cases = (
            ("tag", {"tag_commit": SHA}, "never reused"),
            ("published", {"releases": [{"id": 9, "tag_name": TAG, "draft": False}]}, "already exists"),
            ("draft", {"releases": [{"id": 9, "tag_name": TAG, "draft": True}]}, "already exists"),
        )
        for label, state, message in cases:
            with self.subTest(case=label):
                self.runner = FakeRunner()
                for key, value in state.items():
                    setattr(self.runner, key, value)
                with mock.patch.object(release, "run_command", self.runner), \
                        self.assertRaisesRegex(release.ReleaseError, message):
                    self.publish()
                self.assertEqual(self.runner.mutations(), [])

    def test_refuses_a_tbd_heading(self):
        self.root = write_root(self.base / "tbd", date=None)
        with self.assertRaisesRegex(release.ReleaseError, "TBD"):
            self.publish()
        self.assertEqual(self.runner.mutations(), [])

    def test_draft_stays_unpublished_when_remote_assets_differ(self):
        def bad_digest(assets):
            assets[0]["digest"] = "sha256:" + "0" * 64

        def bad_size(assets):
            assets[0]["size"] += 1

        def bad_state(assets):
            assets[0]["state"] = "starter"

        def missing_asset(assets):
            assets.pop()

        def missing_digest(assets):
            assets[0]["digest"] = None

        for tamper in (bad_digest, bad_size, bad_state, missing_asset, missing_digest):
            with self.subTest(tamper=tamper.__name__):
                self.runner = FakeRunner()
                self.runner.tamper = tamper
                with mock.patch.object(release, "run_command", self.runner), \
                        self.assertRaisesRegex(release.ReleaseError, "remote asset"):
                    self.publish()
                self.assertEqual(self.runner.mutations(), ["release create", "release upload"])
                self.assertIs(self.runner.releases[0]["draft"], True)

    def test_waits_briefly_for_eventually_consistent_listings(self):
        self.runner.stale_listings = 2
        self.runner.stale_assets = 2
        self.publish()
        self.assertEqual(self.runner.mutations(), ["release create", "release upload", "api PATCH"])
        self.assertIs(self.runner.releases[0]["draft"], False)

    def test_failed_upload_leaves_the_draft_unpublished(self):
        self.runner.fail_upload = True
        with self.assertRaisesRegex(release.ReleaseError, "gh release upload failed"):
            self.publish()
        self.assertEqual(self.runner.mutations(), ["release create", "release upload"])
        self.assertIs(self.runner.releases[0]["draft"], True)

    def test_tag_created_concurrently_blocks_publication(self):
        self.runner.tag_during_upload = OTHER_SHA
        with self.assertRaisesRegex(release.ReleaseError, "appeared while uploading"):
            self.publish()
        self.assertNotIn("api PATCH", self.runner.mutations())

    def test_draft_bound_to_another_commit_is_not_uploaded(self):
        self.runner.target_override = OTHER_SHA
        with self.assertRaisesRegex(release.ReleaseError, "target_commitish"):
            self.publish()
        self.assertEqual(self.runner.mutations(), ["release create"])

    def test_tag_mismatch_after_publication_is_reported(self):
        self.runner.tag_on_publish = OTHER_SHA
        with self.assertRaisesRegex(release.ReleaseError, "instead of " + SHA):
            self.publish()

    def test_publish_reverifies_local_assets_first(self):
        (self.folder / f"ghostty-{VS}.tar.gz").write_bytes(b"corrupted")
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.runner.mutations(), [])


class CommandLineTests(EnvironmentCase):
    def run_main(self, *argv: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            code = release.main(list(argv))
        return code, stdout.getvalue(), stderr.getvalue()

    def test_verify_and_prepare_exit_codes(self):
        folder = self.base / "artifacts"
        write_artifacts(folder)
        code, out, _ = self.run_main("verify", "--sha", SHA, "--artifacts", str(folder), "--root", str(self.root),
                                     "--version-string", VS)
        self.assertEqual(code, 0)
        self.assertIn(f"PASS: verified {len(CONTRACT_ASSETS) + 2} release files", out)
        self.assertEqual(len(CONTRACT_ASSETS) + 2, 12)
        code, _, err = self.run_main("verify", "--sha", SHA, "--artifacts", str(folder), "--root", str(self.root),
                                     "--macos")
        self.assertEqual(code, 1)
        self.assertIn("ERROR:", err)
        code, out, _ = self.run_main("prepare", "--root", str(self.root))
        self.assertEqual(code, 0)
        self.assertIn(f"version_string={VS}\n", out)
        code, _, err = self.run_main("publish", "--sha", SHA, "--artifacts", str(folder), "--root", str(self.root))
        self.assertEqual(code, 1)
        self.assertIn("manual", err)

    def test_usage_errors_exit_2(self):
        for argv in ([], ["verify"], ["verify", "--sha", SHA], ["unknown"]):
            with self.subTest(argv=argv), mock.patch("sys.stderr", io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    release.main(argv)
                self.assertEqual(raised.exception.code, 2)


@unittest.skipIf(shutil.which("git") is None, "git is not installed")
class RealGitTests(unittest.TestCase):
    """prepare --publish against a real local repository whose origin points at a bare clone."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        global_config = self.base / "gitconfig"
        global_config.write_text("", encoding="utf-8")
        patcher = mock.patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": str(global_config), "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "gx test", "GIT_AUTHOR_EMAIL": "gx@example.invalid",
            "GIT_COMMITTER_NAME": "gx test", "GIT_COMMITTER_EMAIL": "gx@example.invalid",
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        for key in CI_KEYS:
            os.environ.pop(key, None)
        self.root = write_root(self.base)
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "chore: fixture")
        self.bare = self.base / "origin.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(self.root), str(self.bare)], check=True,
                       capture_output=True)
        self.git("remote", "add", "origin", REPO_URL + ".git")
        self.git("config", f"url.{self.bare.as_uri()}.insteadOf", REPO_URL + ".git")
        self.real_run = release.run_command

    def git(self, *args: str, cwd: Path | None = None) -> str:
        result = subprocess.run(["git", *args], cwd=str(cwd or self.root), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def hybrid(self, args, *, cwd, env=None):
        if args[0] == "gh":
            return completed(args, 1, stderr="release not found\n")
        return self.real_run(args, cwd=cwd, env=env)

    def prepare(self):
        with mock.patch.object(release, "run_command", self.hybrid), \
                mock.patch.object(release, "run_gates"), \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            return release.prepare(self.root, True)

    def test_publish_preparation_sees_remote_tags_through_git_ls_remote(self):
        head = self.git("rev-parse", "HEAD").strip()
        outputs = self.prepare()
        self.assertEqual(outputs["sha"], head)
        self.assertEqual(outputs["version_string"], VS)
        self.git("tag", TAG, head, cwd=self.bare)
        with self.assertRaisesRegex(release.ReleaseError, "already exists on origin"):
            self.prepare()
        self.git("tag", "-d", TAG, cwd=self.bare)
        self.git("tag", "-a", "-m", "annotated", TAG, head, cwd=self.bare)
        self.assertEqual(release.remote_tag_commit(self.root, TAG), head)
        with self.assertRaisesRegex(release.ReleaseError, "already exists on origin"):
            self.prepare()

    def test_untracked_files_make_the_checkout_dirty(self):
        (self.root / "stray.txt").write_text("x", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "clean checkout"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
