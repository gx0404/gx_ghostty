#!/usr/bin/env python3
"""Release pipeline for the gx0404/gx_ghostty fork (driven by .github/workflows/gx-release.yml).

Actions:
  prepare [--publish]
      Resolve the clean source commit, the fork version (largest CHANGELOG.md heading), the
      product version (build.zig.zon .version) and the Zig pin, then run the release gates
      (resolver --check, version.py --check, build_agent_kb.py, graphify.py check).
      --publish additionally requires a dated heading with a non-empty section body (the
      release notes start with it) and checks that neither the gx-vX.Y.Z tag
      (git ls-remote --tags origin) nor a release for it (gh release view) exists.
      Prints sha/version/tag/version_string/zig and appends them to $GITHUB_OUTPUT.
  verify --sha SHA --artifacts DIR [--macos] [--version-string VS]
      Check the artifact directory against the exact expected asset set, the archive layouts,
      the VERSION embedded in the source tarballs and the Windows installer header, then write
      manifest.json and SHA256SUMS (or require existing ones to match byte for byte).
  publish --sha SHA --artifacts DIR [--macos] [--version-string VS]
      Only inside the manual gx-release workflow of gx0404/gx_ghostty: re-verify, create a
      draft release (not a prerelease) targeting SHA whose notes are the CHANGELOG.md section
      of the version followed by the generated asset table and the fixed footer DISCLAIMER (an
      unofficial fork, not affiliated with or endorsed by the Ghostty project), upload every
      asset, compare remote sizes and digests, then publish it. Never overwrites a release,
      never reuses or moves a tag.

Exit codes: 0 success, 1 refused or failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import version as changelog_version  # noqa: E402  (scripts/version.py)

ROOT = SCRIPTS.parent
REPOSITORY = "gx0404/gx_ghostty"
WORKFLOW_PATH = ".github/workflows/gx-release.yml"
TAG_PREFIX = "gx-v"
MANIFEST = "manifest.json"
SUMS = "SHA256SUMS"
# Fixed footer of every release body: the Ghostty maintainers ask unofficial builds to say that
# they are not affiliated with or endorsed by the Ghostty project.
DISCLAIMER = (
    "---",
    "",
    "> Ghostty GX 是 Ghostty 的非官方分支，由 gx0404 维护，与 Ghostty 团队无关，未获其认可或背书。",
    ">",
    "> Ghostty GX is an unofficial fork of Ghostty maintained by gx0404. "
    "It is not affiliated with or endorsed by the Ghostty project.",
)
SOURCE_LIBVT_MAX_BYTES = 5 * 1024 * 1024
LINUX_LIBVT_TARGETS = ("x86_64-linux-gnu", "aarch64-linux-gnu", "x86_64-linux-musl")
WASM_LIBVT_TARGET = "wasm32-freestanding"
WINDOWS_LIBVT_TARGET = "x86_64-windows-msvc"
LINUX_APP_TARGET = "x86_64-linux-debian13"
WINDOWS_APP_TARGET = "x86_64-windows"
WINDOWS_FONTS = (
    "JetBrainsMonoNerdFont-Bold.ttf", "JetBrainsMonoNerdFont-BoldItalic.ttf", "JetBrainsMonoNerdFont-Italic.ttf",
    "JetBrainsMonoNerdFont-Regular.ttf", "JetBrainsMonoNerdFont-SemiBold.ttf",
    "JetBrainsMonoNerdFont-SemiBoldItalic.ttf", "NotoSansCJK-Bold.ttc", "NotoSansCJK-Regular.ttc",
)
INSTALLER_MIN_BYTES = 16 * 1024 * 1024
GATES = (
    ("rules", ("scripts/resolve_agent_rules.py", "--check")),
    ("version", ("scripts/version.py", "--check")),
    ("kb", ("scripts/build_agent_kb.py",)),
    ("graph", ("scripts/graphify.py", "check")),
)
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
CORE_VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
ZON_FIELD_RE = re.compile(
    r'^\s*\.(?P<key>version|minimum_zig_version)\s*=\s*"(?P<value>[^"\\]*)"\s*,?\s*(?://.*)?$'
)
ZIG_PIN_RE = re.compile(r"""^ZIG_VERSION\s*(?::[^=]+)?=\s*["']([^"']+)["']\s*$""")
REMOTE_URLS = {
    f"https://github.com/{REPOSITORY}".lower(),
    f"git@github.com:{REPOSITORY}".lower(),
    f"ssh://git@github.com/{REPOSITORY}".lower(),
}


class ReleaseError(Exception):
    """A release precondition failed; the message says what to fix."""


@dataclass(frozen=True)
class ReleaseInfo:
    fork_version: str
    date: str | None
    product_version: str
    zon_version: str
    zig_version: str

    @property
    def tag(self) -> str:
        return f"{TAG_PREFIX}{self.fork_version}"

    @property
    def title(self) -> str:
        return f"Ghostty GX {self.fork_version}"

    @property
    def version_string(self) -> str:
        return f"{self.product_version}-gx.{self.fork_version}"


@dataclass(frozen=True)
class Asset:
    name: str
    kind: str
    target: str
    root: str
    required: tuple[str, ...] = ()
    required_prefixes: tuple[str, ...] = ()
    required_basenames: tuple[str, ...] = ()
    version_file: bool = False
    max_bytes: int | None = None
    min_bytes: int | None = None


def is_hash(value: object, length: int = 64) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % length, value) is not None


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def unique_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ReleaseError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def run_command(args: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            list(args),
            cwd=str(cwd),
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError as error:
        raise ReleaseError(f"cannot run {args[0]}: {error}") from error


def git(root: Path, *args: str) -> str:
    result = run_command(["git", *args], cwd=root)
    if result.returncode != 0:
        raise ReleaseError(f"git {' '.join(args)} failed (exit {result.returncode}): {result.stderr.strip()}")
    return result.stdout


def gh(root: Path, *args: str) -> str:
    result = run_command(["gh", *args], cwd=root)
    if result.returncode != 0:
        raise ReleaseError(f"gh {' '.join(args[:2])} failed (exit {result.returncode}): {result.stderr.strip()}")
    return result.stdout


def gh_json(root: Path, *args: str) -> object:
    output = gh(root, *args)
    try:
        return json.loads(output, object_pairs_hook=unique_keys)
    except json.JSONDecodeError as error:
        raise ReleaseError(f"gh {' '.join(args[:2])} returned invalid JSON: {error}") from error


def summary(text: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8", newline="\n") as stream:
            stream.write(text.rstrip("\n") + "\n")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        raise ReleaseError(f"missing {path.name} ({path})") from None


def zon_fields(text: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for line in text.splitlines():
        match = ZON_FIELD_RE.match(line)
        if not match:
            continue
        key = match.group("key")
        if key in found:
            raise ReleaseError(f"build.zig.zon declares .{key} more than once")
        found[key] = match.group("value")
    for key in ("version", "minimum_zig_version"):
        if key not in found:
            raise ReleaseError(f'build.zig.zon has no top-level .{key} = "..." line')
    return found


def pinned_zig(text: str) -> str:
    pins = [match.group(1) for line in text.splitlines() if (match := ZIG_PIN_RE.match(line))]
    if len(pins) != 1:
        raise ReleaseError("scripts/setup_zig.py must define exactly one ZIG_VERSION")
    return pins[0]


def release_info(root: Path) -> ReleaseInfo:
    root = Path(root)
    try:
        heading = changelog_version.current(changelog_version.read_changelog(root))
    except FileNotFoundError:
        raise ReleaseError(f"missing CHANGELOG.md in {root}") from None
    except ValueError as error:
        raise ReleaseError(f"CHANGELOG.md: {error}") from error
    raw = heading.version
    fork = raw if isinstance(raw, str) else ".".join(str(part) for part in raw)
    if not CORE_VERSION_RE.match(fork):
        raise ReleaseError(f"fork version {fork!r} is not X.Y.Z")
    fields = zon_fields(read_text(root / "build.zig.zon"))
    product = SEMVER_RE.match(fields["version"])
    if not product:
        raise ReleaseError(f"build.zig.zon .version {fields['version']!r} is not a semantic version")
    zig = fields["minimum_zig_version"]
    pinned = pinned_zig(read_text(root / "scripts" / "setup_zig.py"))
    if pinned != zig:
        raise ReleaseError(
            f"scripts/setup_zig.py ZIG_VERSION {pinned} differs from build.zig.zon minimum_zig_version {zig}"
        )
    return ReleaseInfo(
        fork_version=fork,
        date=heading.date,
        product_version=".".join(product.group(i) for i in (1, 2, 3)),
        zon_version=fields["version"],
        zig_version=zig,
    )


def changelog_section(root: Path, fork_version: str) -> str:
    """Body of the `## X.Y.Z(...)` section of fork_version (up to the next version heading), stripped."""
    try:
        text = changelog_version.read_changelog(Path(root))
        headings = sorted(changelog_version.parse_headings(text), key=lambda heading: heading.line)
    except FileNotFoundError:
        raise ReleaseError(f"missing CHANGELOG.md in {root}") from None
    except ValueError as error:
        raise ReleaseError(f"CHANGELOG.md: {error}") from error
    lines = text.splitlines()
    for index, heading in enumerate(headings):
        if heading.semver != fork_version:
            continue
        end = headings[index + 1].line - 1 if index + 1 < len(headings) else len(lines)
        body = "\n".join(line.rstrip() for line in lines[heading.line:end]).strip("\n")
        if not body.strip():
            raise ReleaseError(
                f"CHANGELOG.md section ## {fork_version} is empty; the release notes start with it"
            )
        return body
    raise ReleaseError(f"CHANGELOG.md has no ## {fork_version} heading")


def head_sha(root: Path) -> str:
    sha = git(root, "rev-parse", "HEAD").strip()
    if not is_hash(sha, 40):
        raise ReleaseError(f"HEAD does not resolve to a full 40-character commit SHA: {sha!r}")
    return sha


def require_clean(root: Path) -> None:
    if git(root, "status", "--porcelain", "--untracked-files=all").strip():
        raise ReleaseError("release preparation requires a clean checkout (git status --porcelain is not empty)")


def require_origin(root: Path) -> None:
    url = git(root, "config", "--get", "remote.origin.url").strip()
    normalized = url.rstrip("/")
    if normalized.endswith(".git"):
        normalized = normalized[:-4]
    if normalized.lower() not in REMOTE_URLS:
        raise ReleaseError(f"origin is {url!r}, not {REPOSITORY}; refusing remote release checks")


def run_gates(root: Path) -> None:
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    for name, argv in GATES:
        result = run_command([sys.executable, *argv], cwd=root, env=env)
        command = "python " + " ".join(argv)
        if result.returncode != 0:
            detail = "\n".join(((result.stdout or "") + (result.stderr or "")).strip().splitlines()[-20:])
            raise ReleaseError(f"release gate '{name}' failed: {command} exited {result.returncode}\n{detail}")
        print(f"PASS gate {name}: {command}")


def remote_tag_commit(root: Path, tag: str) -> str | None:
    ref = f"refs/tags/{tag}"
    direct = peeled = None
    for line in git(root, "ls-remote", "--tags", "origin", ref, ref + "^{}").splitlines():
        if not line.strip():
            continue
        sha, _, name = line.partition("\t")
        if name == ref:
            direct = sha
        elif name == ref + "^{}":
            peeled = sha
        else:
            raise ReleaseError(f"unexpected ref from git ls-remote: {line!r}")
    commit = peeled or direct
    if commit is not None and not is_hash(commit, 40):
        raise ReleaseError(f"tag {tag} resolves to an invalid object name {commit!r}")
    return commit


def release_view(root: Path, tag: str) -> dict | None:
    result = run_command(["gh", "release", "view", tag, "--repo", REPOSITORY, "--json", "tagName,isDraft"], cwd=root)
    if result.returncode == 0:
        try:
            data = json.loads(result.stdout, object_pairs_hook=unique_keys)
        except json.JSONDecodeError as error:
            raise ReleaseError(f"gh release view returned invalid JSON: {error}") from error
        if not isinstance(data, dict) or data.get("tagName") != tag:
            raise ReleaseError(f"gh release view {tag} returned an unexpected release")
        return data
    if "release not found" in (result.stderr or "").lower():
        return None
    raise ReleaseError(f"gh release view {tag} failed (exit {result.returncode}): {(result.stderr or '').strip()}")


def write_outputs(outputs: dict[str, str]) -> None:
    record = "".join(f"{key}={value}\n" for key, value in outputs.items())
    print(record, end="")
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8", newline="\n") as stream:
            stream.write(record)


def prepare(root: Path, publish_requested: bool) -> dict[str, str]:
    root = Path(root)
    sha = head_sha(root)
    require_clean(root)
    info = release_info(root)
    if publish_requested and info.date is None:
        raise ReleaseError(
            f"publishing requires a dated heading: CHANGELOG.md still has ## {info.fork_version}(TBD); "
            "set it to the release date, run just graph, just kb and just generated-check, then commit"
        )
    if publish_requested:
        changelog_section(root, info.fork_version)
    run_gates(root)
    if publish_requested:
        require_origin(root)
        if remote_tag_commit(root, info.tag) is not None:
            raise ReleaseError(f"tag {info.tag} already exists on origin; add a new CHANGELOG version instead")
        if release_view(root, info.tag) is not None:
            raise ReleaseError(f"a release for {info.tag} already exists; refusing to overwrite it")
    outputs = {
        "sha": sha,
        "version": info.fork_version,
        "tag": info.tag,
        "version_string": info.version_string,
        "zig": info.zig_version,
    }
    write_outputs(outputs)
    mode = "publish after verify" if publish_requested else "build and verify only (no tag or release writes)"
    summary(
        f"## {info.title}\n\n- Source: `{sha}`\n- Version string: `{info.version_string}` "
        f"(build.zig.zon `{info.zon_version}`, CHANGELOG `{info.fork_version}` {info.date or 'TBD'})\n"
        f"- Zig: `{info.zig_version}`\n- Mode: {mode}\n"
    )
    return outputs


def expected_assets(version_string: str, macos: bool = False) -> dict[str, Asset]:
    vs = version_string
    assets = [
        Asset(
            f"libghostty-vt-{vs}.tar.gz", "source", "libghostty-vt", f"libghostty-vt-{vs}",
            required=("build.zig", "build.zig.zon", "CMakeLists.txt", "VERSION"),
            version_file=True, max_bytes=SOURCE_LIBVT_MAX_BYTES,
        ),
        Asset(
            f"ghostty-{vs}.tar.gz", "source", "ghostty", f"ghostty-{vs}",
            required=(
                "build.zig", "build.zig.zon", "VERSION",
                "src/apprt/gtk/ghostty_resources.c", "src/apprt/gtk/ghostty_resources.h",
                "src/build/framegen/framedata.compressed",
            ),
            version_file=True,
        ),
    ]
    for target in LINUX_LIBVT_TARGETS:
        assets.append(Asset(
            f"libghostty-vt-{vs}-{target}.tar.gz", "libvt", target, f"libghostty-vt-{vs}-{target}",
            required=("include/ghostty/vt.h", "lib/libghostty-vt.a"),
            required_prefixes=("lib/libghostty-vt.so",),
        ))
    assets.append(Asset(
        f"libghostty-vt-{vs}-{WASM_LIBVT_TARGET}.tar.gz", "libvt", WASM_LIBVT_TARGET,
        f"libghostty-vt-{vs}-{WASM_LIBVT_TARGET}", required=("bin/ghostty-vt.wasm",),
    ))
    assets.append(Asset(
        f"libghostty-vt-{vs}-{WINDOWS_LIBVT_TARGET}.zip", "libvt", WINDOWS_LIBVT_TARGET,
        f"libghostty-vt-{vs}-{WINDOWS_LIBVT_TARGET}",
        required=("include/ghostty/vt.h", "lib/ghostty-vt-static.lib"),
        required_basenames=("ghostty-vt.dll",),
    ))
    assets.append(Asset(
        f"ghostty-gx-{vs}-{LINUX_APP_TARGET}.tar.gz", "app", LINUX_APP_TARGET,
        f"ghostty-gx-{vs}-{LINUX_APP_TARGET}",
        required=("usr/bin/ghostty",), required_prefixes=("usr/share/ghostty/",),
    ))
    assets.append(Asset(
        f"ghostty-gx-{vs}-{WINDOWS_APP_TARGET}.zip", "app", WINDOWS_APP_TARGET,
        f"ghostty-gx-{vs}-{WINDOWS_APP_TARGET}",
        required=(
            "ghostty.exe", "conpty.dll", "OpenConsole.exe",
            "mesa/opengl32.dll", "mesa/libgallium_wgl.dll", "mesa/dxil.dll",
            "share/terminfo/ghostty.terminfo", "README.txt",
            "licenses/Ghostty-MIT.txt", "licenses/THIRD-PARTY.txt",
            *(f"fonts/{name}" for name in WINDOWS_FONTS),
        ),
        required_prefixes=("share/ghostty/",),
    ))
    assets.append(Asset(
        f"ghostty-gx-{vs}-{WINDOWS_APP_TARGET}-setup.exe", "installer", WINDOWS_APP_TARGET, "",
        min_bytes=INSTALLER_MIN_BYTES,
    ))
    if macos:
        assets.append(Asset(
            f"libghostty-vt-{vs}-xcframework.zip", "libvt", "xcframework", "ghostty-vt.xcframework",
            required=("Info.plist",),
        ))
        assets.append(Asset(
            f"ghostty-gx-{vs}-universal-macos-unsigned.zip", "app", "universal-macos", "Ghostty.app",
            required=("Contents/Info.plist", "Contents/MacOS/ghostty"),
        ))
    return {asset.name: asset for asset in assets}


def regular_file(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise ReleaseError(f"{path.name} is missing, a symlink or not a regular file")
    if path.stat().st_size == 0:
        raise ReleaseError(f"{path.name} is empty")


def relative_member(asset: Asset, name: str) -> str:
    normalized = name.replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    stripped = normalized.rstrip("/")
    parts = stripped.split("/")
    if (not stripped or stripped.startswith("/") or re.match(r"^[A-Za-z]:", stripped)
            or any(part in ("", ".", "..") for part in parts)):
        raise ReleaseError(f"{asset.name}: unsafe member path {name!r}")
    if parts[0] != asset.root:
        raise ReleaseError(f"{asset.name}: member {name!r} is outside the top-level directory {asset.root}/")
    return "/".join(parts[1:])


def check_link(asset: Asset, member: str, target: str) -> None:
    if not target or target.startswith("/") or "\\" in target or re.match(r"^[A-Za-z]:", target):
        raise ReleaseError(f"{asset.name}: link {member!r} has an unsafe target {target!r}")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(member), target))
    if resolved == ".." or resolved.startswith("../"):
        raise ReleaseError(f"{asset.name}: link {member!r} escapes the archive ({target!r})")


def tar_members(path: Path, asset: Asset) -> tuple[set[str], bytes | None]:
    present: set[str] = set()
    version: bytes | None = None
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            relative = relative_member(asset, member.name)
            if member.isdir():
                continue
            if member.issym():
                check_link(asset, relative, member.linkname)
            elif member.islnk():
                relative_member(asset, member.linkname)
            elif not member.isfile():
                raise ReleaseError(f"{asset.name}: special file {member.name!r} is not allowed")
            if not relative:
                raise ReleaseError(f"{asset.name}: the top-level entry {member.name!r} must be a directory")
            present.add(relative)
            if relative == "VERSION" and member.isfile():
                stream = archive.extractfile(member)
                version = stream.read() if stream else None
    return present, version


def zip_members(path: Path, asset: Asset) -> set[str]:
    present: set[str] = set()
    with zipfile.ZipFile(path) as archive:
        broken = archive.testzip()
        if broken is not None:
            raise ReleaseError(f"{asset.name}: corrupt member {broken!r}")
        for info in archive.infolist():
            relative = relative_member(asset, info.filename)
            if info.is_dir() or info.filename.replace("\\", "/").endswith("/"):
                continue
            if stat.S_ISLNK(info.external_attr >> 16):
                check_link(asset, relative, archive.read(info).decode("utf-8", "replace"))
            if not relative:
                raise ReleaseError(f"{asset.name}: the top-level entry {info.filename!r} must be a directory")
            present.add(relative)
    return present


def check_installer(path: Path, asset: Asset) -> None:
    size = path.stat().st_size
    if asset.min_bytes is not None and size < asset.min_bytes:
        raise ReleaseError(f"{asset.name} is {size} bytes, below the {asset.min_bytes} byte minimum of a complete installer")
    with path.open("rb") as stream:
        header = stream.read(64)
        if len(header) < 64 or header[:2] != b"MZ":
            raise ReleaseError(f"{asset.name} is not a Windows executable (no MZ header)")
        stream.seek(struct.unpack_from("<I", header, 60)[0])
        signature = stream.read(4)
    if signature != b"PE\0\0":
        raise ReleaseError(f"{asset.name} has an MZ header but no PE signature")


def check_asset(path: Path, asset: Asset, version_string: str) -> None:
    if asset.max_bytes is not None and path.stat().st_size > asset.max_bytes:
        raise ReleaseError(f"{asset.name} is {path.stat().st_size} bytes, above the {asset.max_bytes} byte limit")
    if asset.kind == "installer":
        check_installer(path, asset)
        return
    version: bytes | None = None
    try:
        if asset.name.endswith(".tar.gz"):
            present, version = tar_members(path, asset)
        else:
            present = zip_members(path, asset)
    except (tarfile.TarError, zipfile.BadZipFile, zlib.error, EOFError, OSError) as error:
        raise ReleaseError(f"{asset.name} is not a readable archive: {error}") from error
    missing = [item for item in asset.required if item not in present]
    missing += [f"{prefix}*" for prefix in asset.required_prefixes
                if not any(item.startswith(prefix) for item in present)]
    missing += [f"**/{base}" for base in asset.required_basenames
                if not any(posixpath.basename(item) == base for item in present)]
    if missing:
        raise ReleaseError(f"{asset.name} lacks {', '.join(missing)} under {asset.root}/")
    if asset.version_file:
        found = (version or b"").decode("utf-8", "replace").strip()
        if found != version_string:
            raise ReleaseError(f"{asset.name}: embedded VERSION is {found!r}, expected {version_string!r}")


def write_or_verify(path: Path, content: str) -> None:
    data = content.encode("utf-8")
    if path.exists() or path.is_symlink():
        regular_file(path)
        if path.read_bytes() != data:
            raise ReleaseError(f"existing {path.name} differs from the verified assets; refusing to overwrite it")
        return
    with path.open("xb") as stream:
        stream.write(data)


def render_manifest(info: ReleaseInfo, sha: str, macos: bool, entries: list[dict]) -> str:
    record = {
        "schema_version": 2,
        "repository": REPOSITORY,
        "name": info.title,
        "tag": info.tag,
        "fork_version": info.fork_version,
        "product_version": info.product_version,
        "version_string": info.version_string,
        "zig_version": info.zig_version,
        "source_commit": sha,
        "macos": macos,
        "assets": entries,
    }
    return json.dumps(record, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def verify_artifacts(
    root: Path, folder: Path, sha: str, macos: bool = False, version_string: str | None = None
) -> list[Path]:
    if not is_hash(sha, 40):
        raise ReleaseError("--sha must be a full 40-character lowercase commit SHA")
    root, folder = Path(root), Path(folder)
    actual = head_sha(root)
    if actual != sha:
        raise ReleaseError(f"checkout is at {actual}, not {sha}; verify must run on the prepared commit")
    info = release_info(root)
    if version_string is not None and version_string != info.version_string:
        raise ReleaseError(
            f"--version-string {version_string} differs from {info.version_string} derived from this checkout"
        )
    if folder.is_symlink() or not folder.is_dir():
        raise ReleaseError(f"artifact directory {folder} is missing or not a real directory")
    expected = expected_assets(info.version_string, macos)
    names = {path.name for path in folder.iterdir()}
    missing = sorted(set(expected) - names)
    unexpected = sorted(names - set(expected) - {MANIFEST, SUMS})
    if missing or unexpected:
        raise ReleaseError(
            f"artifact set mismatch: missing {missing or 'nothing'}, unexpected {unexpected or 'nothing'}"
        )
    entries = []
    for name in sorted(expected):
        path = folder / name
        regular_file(path)
        asset = expected[name]
        check_asset(path, asset, info.version_string)
        entries.append({
            "kind": asset.kind, "name": name, "sha256": digest(path),
            "size": path.stat().st_size, "target": asset.target,
        })
    write_or_verify(folder / MANIFEST, render_manifest(info, sha, macos, entries))
    files = [folder / name for name in sorted(expected)] + [folder / MANIFEST]
    sums = "".join(f"{digest(path)}  {path.name}\n" for path in sorted(files, key=lambda item: item.name))
    write_or_verify(folder / SUMS, sums)
    return [*files, folder / SUMS]


def require_publish_context() -> None:
    expected = {
        "GITHUB_ACTIONS": "true",
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REPOSITORY": REPOSITORY,
        "GX_PUBLISH": "true",
    }
    wrong = [key for key, value in expected.items() if os.environ.get(key) != value]
    if not os.environ.get("GITHUB_WORKFLOW_REF", "").startswith(f"{REPOSITORY}/{WORKFLOW_PATH}@"):
        wrong.append("GITHUB_WORKFLOW_REF")
    if not os.environ.get("GH_TOKEN"):
        wrong.append("GH_TOKEN")
    if wrong:
        raise ReleaseError(
            f"publish only runs in the manual {WORKFLOW_PATH} workflow of {REPOSITORY} with publish=true "
            f"(unexpected: {', '.join(wrong)})"
        )


def releases_for_tag(root: Path, tag: str) -> list[dict]:
    matches: list[dict] = []
    for page in range(1, 101):
        releases = gh_json(root, "api", f"repos/{REPOSITORY}/releases?per_page=100&page={page}")
        if not isinstance(releases, list) or any(not isinstance(item, dict) for item in releases):
            raise ReleaseError("unexpected release listing from the GitHub API")
        matches.extend(item for item in releases if item.get("tag_name") == tag)
        if len(releases) < 100:
            return matches
    raise ReleaseError("release listing exceeded 100 pages")


def check_draft(release: object, info: ReleaseInfo, sha: str) -> int:
    if not isinstance(release, dict):
        raise ReleaseError("unexpected release object from the GitHub API")
    release_id = release.get("id")
    if type(release_id) is not int or release_id <= 0:
        raise ReleaseError(f"invalid release id {release_id!r}")
    expected = {"draft": True, "prerelease": False, "tag_name": info.tag, "name": info.title, "target_commitish": sha}
    for key, value in expected.items():
        if type(release.get(key)) is not type(value) or release.get(key) != value:
            raise ReleaseError(
                f"draft {release_id} has {key}={release.get(key)!r}, expected {value!r}; it stays unpublished"
            )
    return release_id


def verify_remote_assets(assets: object, files: list[Path]) -> None:
    expected = {path.name: path for path in files}
    if not isinstance(assets, list) or any(not isinstance(asset, dict) for asset in assets):
        raise ReleaseError("unexpected asset listing from the GitHub API")
    names = [asset.get("name") for asset in assets]
    if len(set(names)) != len(names) or set(names) != set(expected):
        missing = sorted(set(expected) - set(names))
        unexpected = sorted({str(name) for name in names} - set(expected))
        raise ReleaseError(
            f"remote assets differ from the verified set (missing {missing}, unexpected {unexpected}, "
            f"{len(names)} listed); the draft stays unpublished"
        )
    for asset in assets:
        path = expected[asset["name"]]
        if asset.get("state") != "uploaded":
            raise ReleaseError(f"remote asset {path.name} is in state {asset.get('state')!r}")
        if type(asset.get("size")) is not int or asset["size"] != path.stat().st_size:
            raise ReleaseError(f"remote asset {path.name} has size {asset.get('size')!r}, expected {path.stat().st_size}")
        if asset.get("digest") != "sha256:" + digest(path):
            raise ReleaseError(f"remote asset {path.name} has digest {asset.get('digest')!r}, not the local SHA-256")


def asset_description(name: str, asset: Asset | None) -> str:
    if asset is None:
        return "资产清单（每个资产的大小与 SHA-256）" if name == MANIFEST else "全部资产与 manifest.json 的 SHA-256"
    if asset.kind == "source" and asset.target == "libghostty-vt":
        return "libghostty-vt 源码包（`zig build distcheck -Demit-lib-vt=true` 产出并自检）"
    if asset.kind == "source":
        return "完整源码包（`zig build dist`，含预生成的 GTK 资源与 framedata）"
    if asset.target == "xcframework":
        return "libghostty-vt XCFramework（Apple 平台静态库）"
    if asset.kind == "libvt":
        return f"libghostty-vt 预编译库（`{asset.target}`）"
    if asset.target == LINUX_APP_TARGET:
        return "Ghostty GX 的 Linux GTK 构建（实验性，debian:13 构建，解压后运行 `usr/bin/ghostty`）"
    if asset.kind == "installer":
        return ("Ghostty GX Windows 安装包（x64；默认按用户安装到 `%LOCALAPPDATA%\\Programs\\Ghostty GX`，"
                "可改为所有用户；可选桌面图标与资源管理器右键菜单，按同一范围安装随附字体，卸载保留用户配置）")
    if asset.target == WINDOWS_APP_TARGET:
        return ("Ghostty GX Windows 便携版（x64；解压后运行 `ghostty.exe`，附 ConPTY、Mesa 软件渲染后备、"
                "字体与许可证，见包内 `README.txt`）")
    return "由本 fork 源码构建的 macOS app `Ghostty.app`（非官方构建；universal，仅 ad-hoc 签名，未公证）"


def release_notes(info: ReleaseInfo, sha: str, macos: bool, files: list[Path], changelog: str) -> str:
    assets = expected_assets(info.version_string, macos)
    rows = [f"| `{path.name}` | {asset_description(path.name, assets.get(path.name))} |" for path in files]
    return "\n".join([
        changelog.strip("\n"),
        "",
        f"<!-- gx-release source={sha} version_string={info.version_string} -->",
        "### 构建与资产",
        "",
        f"- 构建版本串：`{info.version_string}`（Ghostty 产品版本 `{info.product_version}` + fork 版本 `{info.fork_version}`）",
        f"- 源码提交：`{sha}`",
        f"- Zig：`{info.zig_version}`",
        "",
        "| 资产 | 说明 |",
        "|---|---|",
        *rows,
        "",
        "全部资产未签名：Windows 的 exe 与安装包没有 Authenticode 签名（SmartScreen 可能提示），"
        "macOS 包只有 ad-hoc 签名、未经公证，Linux GTK 包是实验性构建。"
        "下载后用 `sha256sum -c SHA256SUMS` 校验（Windows 可用 PowerShell 的 `Get-FileHash`）。",
        f"fork 变更见 [CHANGELOG.md](https://github.com/{REPOSITORY}/blob/{info.tag}/CHANGELOG.md)。",
        "",
        *DISCLAIMER,
        "",
    ])


def wait_for_tag(root: Path, tag: str, attempts: int = 6, delay: float = 5.0) -> str | None:
    for attempt in range(attempts):
        commit = remote_tag_commit(root, tag)
        if commit is not None or attempt == attempts - 1:
            return commit
        time.sleep(delay)
    return None


def single_draft(root: Path, tag: str, attempts: int = 5, delay: float = 2.0) -> dict:
    drafts: list[dict] = []
    for attempt in range(attempts):
        drafts = releases_for_tag(root, tag)
        if drafts or attempt == attempts - 1:
            break
        time.sleep(delay)
    if len(drafts) != 1:
        raise ReleaseError(f"expected exactly one draft for {tag}, found {len(drafts)}")
    return drafts[0]


def settled_remote_assets(root: Path, release_id: int, files: list[Path], attempts: int = 4, delay: float = 5.0) -> None:
    for attempt in range(attempts):
        assets = gh_json(root, "api", f"repos/{REPOSITORY}/releases/{release_id}/assets?per_page=100")
        try:
            verify_remote_assets(assets, files)
            return
        except ReleaseError:
            if attempt == attempts - 1:
                raise
            time.sleep(delay)


def publish(
    root: Path, folder: Path, sha: str, macos: bool = False, version_string: str | None = None
) -> str:
    require_publish_context()
    root, folder = Path(root), Path(folder)
    files = verify_artifacts(root, folder, sha, macos, version_string)
    info = release_info(root)
    if info.date is None:
        raise ReleaseError(f"CHANGELOG.md still has ## {info.fork_version}(TBD); refusing to publish")
    changelog = changelog_section(root, info.fork_version)
    require_origin(root)
    tag = info.tag
    if remote_tag_commit(root, tag) is not None:
        raise ReleaseError(f"tag {tag} already exists on origin; it is never reused or moved")
    if release_view(root, tag) is not None or releases_for_tag(root, tag):
        raise ReleaseError(
            f"a release or draft for {tag} already exists; inspect it and delete a leftover draft by hand"
        )
    with tempfile.TemporaryDirectory(prefix="gx-release-") as temp:
        notes = Path(temp) / "notes.md"
        notes.write_bytes(release_notes(info, sha, macos, files, changelog).encode("utf-8"))
        gh(root, "release", "create", tag, "--repo", REPOSITORY, "--draft",
           "--target", sha, "--title", info.title, "--notes-file", str(notes))
    release_id = check_draft(single_draft(root, tag), info, sha)
    gh(root, "release", "upload", tag, *[str(path) for path in files], "--repo", REPOSITORY)
    settled_remote_assets(root, release_id, files)
    check_draft(gh_json(root, "api", f"repos/{REPOSITORY}/releases/{release_id}"), info, sha)
    if remote_tag_commit(root, tag) is not None:
        raise ReleaseError(f"tag {tag} appeared while uploading; the draft stays unpublished")
    result = gh_json(root, "api", "--method", "PATCH", f"repos/{REPOSITORY}/releases/{release_id}", "-F", "draft=false")
    if (not isinstance(result, dict) or result.get("id") != release_id or result.get("draft") is not False
            or result.get("prerelease") is not False or result.get("tag_name") != tag):
        raise ReleaseError(f"ambiguous publish response for release {release_id}; inspect it before retrying")
    commit = wait_for_tag(root, tag)
    if commit != sha:
        raise ReleaseError(f"published {tag}, but origin reports the tag at {commit!r} instead of {sha}; inspect it")
    url = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    print(url)
    summary(f"Published [{info.title}]({url}) from `{sha}` with {len(files)} verified assets.")
    return url


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
    actions = parser.add_subparsers(dest="action", required=True)
    prepare_parser = actions.add_parser("prepare", help="resolve versions and run the release gates")
    prepare_parser.add_argument("--publish", action="store_true", help="also require a dated heading and an unused tag")
    prepare_parser.add_argument("--root", type=Path, default=ROOT, help="repository root (default: this checkout)")
    for name in ("verify", "publish"):
        sub = actions.add_parser(name, help=f"{name} the release assets")
        sub.add_argument("--sha", required=True, help="full commit SHA from prepare")
        sub.add_argument("--artifacts", type=Path, required=True, help="directory holding the release assets")
        sub.add_argument("--macos", action="store_true", help="expect the optional macOS assets")
        sub.add_argument("--version-string", help="cross-check against the version string derived from the checkout")
        sub.add_argument("--root", type=Path, default=ROOT, help="repository root (default: this checkout)")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    try:
        if args.action == "prepare":
            prepare(root, args.publish)
        elif args.action == "verify":
            files = verify_artifacts(root, args.artifacts, args.sha, args.macos, args.version_string)
            print(f"PASS: verified {len(files)} release files in {args.artifacts}")
            summary(f"Verified {len(files)} release files for `{args.sha}` (also in build-only runs).")
        else:
            publish(root, args.artifacts, args.sha, args.macos, args.version_string)
        return 0
    except (ReleaseError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
