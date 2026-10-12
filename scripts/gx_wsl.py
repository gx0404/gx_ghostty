#!/usr/bin/env python3
"""Drive a WSL clone of gx_ghostty from Windows: Linux GTK builds, full Zig tests and Xvfb screenshots.

Usage: python scripts/gx_wsl.py [--distro NAME] [--clone PATH] [--dry-run] COMMAND [ARGS...]

Commands (all run inside `wsl.exe -d <distro>` against the clone, default ~/src/gx_ghostty):
  setup [--check] [--apt]
        Idempotent: clone the Windows repository if the clone is missing, install the pinned
        Zig with scripts/setup_zig.py, install the pinned blueprint-compiler under
        ~/.local/opt/blueprint-compiler-<version> with a shim at ~/.local/bin/blueprint-compiler,
        then prefetch the Zig packages. --check only reports and changes nothing; --apt first
        installs missing apt packages and locales as root (never upgrades installed ones).
  sync [REF | WORKTREE] [--dirty]
        Fetch a commit of the Windows repository into the clone and check it out detached.
        A directory argument is a worktree (its HEAD is synced; --dirty also snapshots its
        uncommitted and untracked files into a temporary commit object); anything else is a
        ref of this repository. Without an argument, the worktree containing this script.
        Refuses (exit 3) when the clone has local changes or commits that would be orphaned.
  build [--gtk] [ZIG BUILD ARGS...]
        python3 scripts/zigw.py build ...; --gtk adds -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
        (Ubuntu 24.04 has no gtk4-layer-shell development package, so it is built from pkg/).
        Only normal installs certify an image. Query/help/list/custom-step or unknown arguments
        write an ineligible attempt, with Zig output and exit status unchanged. Known valued options
        such as --summary all and inline -j4 are supported; pinned Zig rejects separated -j 4.
  test [--suite main|vt] [--gtk] [--filter TEXT]... [ZIG_TEST ARGS...]
        python3 scripts/zig_test.py; the main suite (default) gets -Dapp-runtime=none like the
        gx-ci linux-main job, or the GTK runtime flags with --gtk.
  smoke --out DIR [--lang zh_CN|en] [--xdotool FILE] [--config FILE] [--wait SECONDS]
        [--settle SECONDS] [--name PREFIX] [--env NAME=VALUE]... [--perf] [-- GHOSTTY ARGS...]
        Start zig-out/bin/ghostty under xvfb-run like the gx-ci gtk-smoke job (GDK_BACKEND=x11,
        LIBGL_ALWAYS_SOFTWARE=1, NO_AT_BRIDGE=1, 1280x800x24, --gtk-single-instance=false) with
        the --env variables, wait up to --wait seconds (default 20) for its window (an
        `xdotool search` every 50 ms; it stops early if Ghostty exits), screenshot it with
        scrot --settle seconds later (default 3),
        optionally run an xdotool script (the Ghostty PID is its $1) and screenshot again, then
        copy PNGs, log, version and metadata to the Windows directory DIR. --perf sets
        GHOSTTY_GX_PERF=1, runs `seq 1 3000000` in the terminal (`-e sh workload.sh`) after the
        first screenshot and writes PREFIX-perf.txt: the time to the window and of the workload,
        CPU time and page faults per Ghostty thread (from /proc/<pid>/task/*/stat) and the DMABUF
        warnings in the log, as `metric NAME VALUE [UNIT]` lines that scripts/gx_perf.py reads.
        --perf requires actual ReleaseFast; ordinary GUI smoke still accepts Debug. PID/starttime/exe
        and TID/starttime are guarded; process signals use an owned pidfd and unreaped Popen child.
        Invalid/incomplete windows retain raw evidence but no accepted metrics. PREFIX-meta.json
        records identity, source tree/dirty state, effective display environment and artifact hashes.
        Existing evidence prefixes are refused, never overwritten.
  scenario --out DIR [SCENARIO...]
        Run the GTK scenarios test/gui/gtk/G*.toml (ids such as G01 or file paths; default
        all): each writes its config and xdotool script to DIR/<id>/, runs one smoke named
        <id> there and fails when the log has a line matching its `forbid` patterns (default
        `Theme parser error` and `css parsing failed`). DIR/<id>/notes.txt lists what the
        screenshots must show; DIR/SUMMARY.txt has one line per scenario.
  run [--lang zh_CN|en] [--config FILE] [--x11] [-- GHOSTTY ARGS...]
        Start zig-out/bin/ghostty on the WSLg desktop (Wayland, or XWayland with --x11) in the
        background and print its PID.
  shell
        Print how to enter the clone and build or run by hand.

Ghostty started by smoke or run never reads or writes the WSL user's Ghostty configuration: it
gets a private XDG_CONFIG_HOME whose ghostty/config.ghostty is the --config file (or empty), plus
an `env` entry that hands the original XDG_CONFIG_HOME back to the shell inside the terminal.
LD_LIBRARY_PATH points at zig-out/lib, where the vendored libgtk4-layer-shell.so is installed;
the RUNPATH Zig writes into the binary is relative to the cache and only works from the clone root.

Inside WSL every command drops /mnt/* entries from PATH, puts ~/.local/bin first and unsets ZIG
and GX_GHOSTTY_ZIG, so the clone's pinned Zig (.local/toolchains) is used. Zig packages are
downloaded with curl and registered with `zig fetch <file>`, because Zig's own HTTP client
cannot reach HTTPS servers through an HTTP proxy, which may be a WSL distro's only way out.

Options --distro and --clone default to $GX_WSL_DISTRO / $GX_WSL_CLONE, else Ubuntu-24.04 and
~/src/gx_ghostty. --clone must be a Linux path; in Git Bash quote it ('~/src/x') because MSYS
rewrites arguments that start with /. --dry-run prints the wsl.exe command lines and scripts.

Exit codes: the WSL command's own exit code (0 success, 1 failure); 2 for usage errors, a missing
wsl.exe, a missing clone or build, or a wsl.exe failure; 3 when sync refuses to touch the clone.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
TAG = "[gx-wsl]"
WSL_EXE = "wsl.exe"
SCRIPT_NAME = "gx-wsl"
DEFAULT_DISTRO = "Ubuntu-24.04"
DEFAULT_CLONE = "~/src/gx_ghostty"
DISTRO_ENV = "GX_WSL_DISTRO"
CLONE_ENV = "GX_WSL_CLONE"

# blueprint-compiler >= 0.16.0 is required (src/apprt/gtk/build/blueprint.zig); Ubuntu 24.04
# ships 0.12.0. 0.16.0 is also what the gx-ci gtk-smoke job gets from Debian 13. GNOME publishes
# no 0.16 tarball on download.gnome.org, so the GitLab tag archive is pinned by its sha256.
BLUEPRINT_VERSION = "0.16.0"
BLUEPRINT_URL = (
    "https://gitlab.gnome.org/GNOME/blueprint-compiler/-/archive/"
    f"v{BLUEPRINT_VERSION}/blueprint-compiler-v{BLUEPRINT_VERSION}.tar.gz"
)
BLUEPRINT_SHA256 = "01feb8263fe7a450b0a9fed0fd54cf88947aaf00f86cc7da345f8b39a0e7bd30"

APT_PACKAGES = (
    "curl",
    "fonts-noto-cjk",
    "gettext",
    "gir1.2-adw-1",
    "gir1.2-girepository-2.0",
    "gir1.2-gtk-4.0",
    "git",
    "libadwaita-1-dev",
    "libbz2-dev",
    "libgl1-mesa-dri",
    "libgtk-4-dev",
    "libonig-dev",
    "libwayland-dev",
    "libxml2-utils",
    "meson",
    "ninja-build",
    "python3-gi",
    "scrot",
    "wayland-protocols",
    "xauth",
    "xdotool",
    "xvfb",
)
LOCALES = ("en_US.UTF-8", "zh_CN.UTF-8")
GTK_BUILD_ARGS = ("-Dapp-runtime=gtk", "-fno-sys=gtk4-layer-shell")
MAIN_SUITE_ARGS = ("-Dapp-runtime=none",)
SMOKE_SCREEN = "1280x800x24"
SMOKE_WAIT_SECONDS = 20.0
SMOKE_SETTLE_SECONDS = 3.0
ENV_NAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
GTK_SCENARIO_DIR = REPO_ROOT / "test" / "gui" / "gtk"
GTK_SCENARIO_ID = re.compile(r"^G\d{2}$")
GTK_SCENARIO_KEYS = frozenset(("id", "title", "lang", "config", "xdotool", "wait", "settle", "env", "args", "expect",
                               "forbid"))
# GTK and the GX layer log these when a stylesheet does not parse.
SCENARIO_FORBID = ("Theme parser error", "css parsing failed")
# --lang value -> (LANG and LC_ALL, LANGUAGE)
LANGS = {"en": ("en_US.UTF-8", "en"), "zh_CN": ("zh_CN.UTF-8", "zh_CN:zh")}
NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
WINDOWS_PATH = re.compile(r"^(?:[A-Za-z]:[\\/]|\\\\)")
SNAPSHOT_IDENTITY = {
    "GIT_AUTHOR_NAME": "gx-wsl",
    "GIT_AUTHOR_EMAIL": "gx-wsl@localhost",
    "GIT_COMMITTER_NAME": "gx-wsl",
    "GIT_COMMITTER_EMAIL": "gx-wsl@localhost",
}

PREFETCH_DELIMITER = "GX_WSL_PREFETCH"
# Runs inside WSL as `python3 - <clone> [--check]`. Every package of build.zig.zon.json and of the
# build.zig.zon files (root, pkg/*, then each extracted zig-pkg/<hash>; `//` comments ignored) that
# is in neither zig-pkg/ nor the global cache is downloaded with curl and registered with `zig fetch <file>`,
# which must print exactly the expected hash. git+ URLs of GitHub and Codeberg are fetched as the
# forge's archive of the pinned commit; the hash check proves the contents are identical.
PREFETCH_PROGRAM = r'''
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

FORGE_GIT = re.compile(
    r"^git\+https://(github\.com|codeberg\.org)/([^/]+)/([^/?#]+?)(?:\.git)?/?(?:\?[^#]*)?#([0-9a-f]{40})$"
)
DEPENDENCY = re.compile(
    r'\.url\s*=\s*"([^"]+)"[^{}]*?\.hash\s*=\s*"([^"]+)"'
    r'|\.hash\s*=\s*"([^"]+)"[^{}]*?\.url\s*=\s*"([^"]+)"'
)


def archive_url(url):
    if not url.startswith("git+"):
        return url
    match = FORGE_GIT.match(url)
    if match is None:
        return None
    host, owner, repo, commit = match.groups()
    return f"https://{host}/{owner}/{repo}/archive/{commit}.tar.gz"


def strip_comments(text):
    lines = []
    for line in text.splitlines():
        cut = len(line)
        in_string = escaped = False
        for index, char in enumerate(line):
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
            elif char == '"':
                in_string = True
            elif line.startswith("//", index):
                cut = index
                break
        lines.append(line[:cut])
    return "\n".join(lines)


def zon_dependencies(text):
    pairs = []
    for match in DEPENDENCY.finditer(strip_comments(text)):
        url, digest, digest_first, url_second = match.groups()
        pairs.append((digest or digest_first, url or url_second))
    return pairs


def archive_name(package, url):
    base = url.split("?", 1)[0].split("#", 1)[0].rstrip("/").rsplit("/", 1)[-1]
    return f"{package}-{base}"


def declared(root):
    found = {}
    manifest = os.path.join(root, "build.zig.zon.json")
    if os.path.isfile(manifest):
        with open(manifest, encoding="utf-8") as handle:
            for package, info in json.load(handle).items():
                found.setdefault(package, info["url"])
    zons = [os.path.join(root, "build.zig.zon")]
    zons += sorted(glob.glob(os.path.join(root, "pkg", "*", "build.zig.zon")))
    for path in zons:
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as handle:
                for package, url in zon_dependencies(handle.read()):
                    found.setdefault(package, url)
    return found


def present(root, cache, package):
    return os.path.isdir(os.path.join(root, "zig-pkg", package)) or os.path.isfile(
        os.path.join(cache, "p", package + ".tar.gz")
    )


def fetch(root, workdir, package, url):
    source = archive_url(url)
    if source is None:
        return f"no tarball mapping for {url}"
    target = os.path.join(workdir, archive_name(package, source))
    print(f"[gx-wsl] fetching {package} from {source}", flush=True)
    download = subprocess.run(
        ["curl", "-fsSL", "--retry", "3", "--connect-timeout", "30", "-o", target, source],
        stdin=subprocess.DEVNULL,
    )
    if download.returncode != 0:
        return f"curl exited {download.returncode} for {source}"
    result = subprocess.run(
        [sys.executable, os.path.join(root, "scripts", "zigw.py"), "fetch", target],
        cwd=root,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    words = result.stdout.split()
    got = words[-1] if words else ""
    if result.returncode != 0 or got != package:
        return f"zig fetch printed {got or result.stderr.strip()!r}, expected {package}"
    return None


def main(argv):
    root = os.path.abspath(argv[1])
    check = "--check" in argv[2:]
    cache = os.environ.get("ZIG_GLOBAL_CACHE_DIR", "").strip() or os.path.join(root, ".local", "zig-cache", "global")
    queue = sorted(declared(root).items())
    seen = set()
    missing = []
    failures = []
    fetched = 0
    with tempfile.TemporaryDirectory(prefix="gx-wsl-prefetch-") as workdir:
        while queue:
            package, url = queue.pop(0)
            if package in seen:
                continue
            seen.add(package)
            if not present(root, cache, package):
                if check:
                    missing.append(package)
                    continue
                error = fetch(root, workdir, package, url)
                if error is not None:
                    failures.append(f"{package}: {error}")
                    continue
                fetched += 1
            nested = os.path.join(root, "zig-pkg", package, "build.zig.zon")
            if os.path.isfile(nested):
                with open(nested, encoding="utf-8") as handle:
                    queue.extend(zon_dependencies(handle.read()))
    available = len(seen) - len(missing) - len(failures)
    print(f"[gx-wsl] zig packages: {available}/{len(seen)} available, {fetched} fetched now", flush=True)
    for package in missing:
        print(f"[gx-wsl] missing zig package: {package}", flush=True)
    for failure in failures:
        print(f"[gx-wsl] failed to prefetch {failure}", file=sys.stderr, flush=True)
    return 1 if missing or failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
'''

# Shared by every user-level script. $1 is the clone path; the command's own arguments follow.
PRELUDE = r"""set -euo pipefail
log() { printf '[gx-wsl] %s\n' "$*"; }
warn() { printf '[gx-wsl] warning: %s\n' "$*" >&2; }
die() { printf '[gx-wsl] error: %s\n' "$1" >&2; exit "${2:-1}"; }
clone=$1
shift
case $clone in
  "~") clone=$HOME ;;
  "~/"*) clone=$HOME/${clone#"~/"} ;;
esac
PATH=$HOME/.local/bin:$(printf '%s' "$PATH" | tr ':' '\n' | { grep -v '^/mnt/' || true; } | paste -sd: -)
export PATH
unset ZIG GX_GHOSTTY_ZIG
enter_clone() {
  [ -d "$clone/.git" ] || die "no clone at $clone; run: python scripts/gx_wsl.py setup" 2
  cd "$clone"
}
"""

PREREQUISITES = r"""check_prerequisites() {
  local pkg wanted have
  local -a missing=() missing_locales=()
  for pkg in "${apt_packages[@]}"; do
    dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii' || missing+=("$pkg")
  done
  have=$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/utf-8$/utf8/')
  for wanted in "${locales[@]}"; do
    printf '%s\n' "$have" | grep -qx "$(printf '%s' "$wanted" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8$/utf8/')" \
      || missing_locales+=("$wanted")
  done
  if [ ${#missing[@]} -eq 0 ] && [ ${#missing_locales[@]} -eq 0 ]; then
    log "apt packages and locales: ok"
    return 0
  fi
  [ ${#missing[@]} -eq 0 ] || warn "missing apt packages: ${missing[*]}"
  [ ${#missing_locales[@]} -eq 0 ] || warn "missing locales: ${missing_locales[*]}"
  warn "install them with: python scripts/gx_wsl.py setup --apt"
  return 1
}
"""

BLUEPRINT = r"""install_blueprint() {
  local version=$1 url=$2 sha256=$3
  local prefix=$HOME/.local/opt/blueprint-compiler-$version
  local shim=$HOME/.local/bin/blueprint-compiler
  local marker="# gx-wsl blueprint-compiler shim"
  local work desired
  if [ "$("$prefix/bin/blueprint-compiler" --version 2>/dev/null || true)" = "$version" ]; then
    log "blueprint-compiler $version already installed in $prefix"
  else
    work=$(mktemp -d)
    log "downloading $url"
    curl -fsSL --retry 3 --connect-timeout 30 -o "$work/source.tar.gz" "$url"
    printf '%s  %s\n' "$sha256" "$work/source.tar.gz" | sha256sum -c --quiet - \
      || die "sha256 of $url is not $sha256"
    tar -xzf "$work/source.tar.gz" -C "$work"
    rm -rf "$prefix"
    if ! { meson setup "$work/build" "$work/blueprint-compiler-v$version" --prefix="$prefix" \
      && meson install -C "$work/build"; } >"$work/meson.log" 2>&1; then
      cat "$work/meson.log" >&2
      die "meson could not install blueprint-compiler $version"
    fi
    rm -rf "$work"
    [ "$("$prefix/bin/blueprint-compiler" --version)" = "$version" ] \
      || die "$prefix/bin/blueprint-compiler does not report version $version"
    log "installed blueprint-compiler $version in $prefix"
  fi
  desired=$(printf '#!/bin/sh\n%s %s\nexec "%s" "$@"' "$marker" "$version" "$prefix/bin/blueprint-compiler")
  if [ -e "$shim" ] && ! grep -q "^$marker" "$shim"; then
    die "$shim exists and was not written by gx-wsl; move it aside and rerun setup" 2
  fi
  if [ "$(cat "$shim" 2>/dev/null || true)" != "$desired" ]; then
    mkdir -p "${shim%/*}"
    printf '%s\n' "$desired" >"$shim"
    chmod 755 "$shim"
    log "wrote $shim"
  fi
  [ "$(blueprint-compiler --version)" = "$version" ] || die "blueprint-compiler on PATH is not $version"
}
"""

SETUP_BODY = r"""source_win=$1
blueprint_version=$2
blueprint_url=$3
blueprint_sha256=$4
read -r -a apt_packages <<<"$5"
read -r -a locales <<<"$6"
status=0
check_prerequisites || status=1
if [ ! -d "$clone/.git" ]; then
  repo=$(wslpath -u "$source_win")
  mkdir -p "$(dirname "$clone")"
  log "cloning $repo into $clone"
  git clone --quiet "$repo" "$clone"
fi
enter_clone
log "clone $clone at $(git log -1 --format='%h %s')"
python3 scripts/setup_zig.py --install
log "zig $(python3 scripts/zigw.py version)"
install_blueprint "$blueprint_version" "$blueprint_url" "$blueprint_sha256"
prefetch || status=1
if [ "$status" -eq 0 ]; then log "setup complete"; else warn "setup finished with problems (see above)"; fi
exit "$status"
"""

CHECK_BODY = r"""blueprint_version=$2
read -r -a apt_packages <<<"$5"
read -r -a locales <<<"$6"
status=0
check_prerequisites || status=1
version=$(blueprint-compiler --version 2>/dev/null || true)
if [ "$version" = "$blueprint_version" ]; then
  log "blueprint-compiler $version ($(command -v blueprint-compiler))"
else
  warn "blueprint-compiler ${version:-not found}, want $blueprint_version"
  status=1
fi
log "https proxy: ${https_proxy:-${HTTPS_PROXY:-none}}"
if [ -d "$clone/.git" ]; then
  cd "$clone"
  log "clone $clone at $(git log -1 --format='%h %s')"
  python3 scripts/setup_zig.py --check || status=1
  prefetch --check || status=1
else
  warn "no clone at $clone"
  status=1
fi
exit "$status"
"""

APT_SCRIPT = r"""set -euo pipefail
read -r -a apt_packages <<<"$1"
read -r -a locales <<<"$2"
missing=()
for pkg in "${apt_packages[@]}"; do
  dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii' || missing+=("$pkg")
done
if [ ${#missing[@]} -gt 0 ]; then
  printf '[gx-wsl] apt-get install %s\n' "${missing[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
else
  printf '[gx-wsl] apt packages already installed\n'
fi
have=$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/utf-8$/utf8/')
missing_locales=()
for wanted in "${locales[@]}"; do
  printf '%s\n' "$have" | grep -qx "$(printf '%s' "$wanted" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8$/utf8/')" \
    || missing_locales+=("$wanted")
done
if [ ${#missing_locales[@]} -gt 0 ]; then
  locale-gen "${missing_locales[@]}"
else
  printf '[gx-wsl] locales already generated\n'
fi
"""

SYNC_BODY = r"""source_win=$1
sha=$2
label=$3
enter_clone
changes=$(git status --porcelain)
if [ -n "$changes" ]; then
  printf '%s\n' "$changes" >&2
  die "the clone $clone has local changes; commit or stash them there, then sync again" 3
fi
head=$(git rev-parse HEAD)
if [ "$head" != "$sha" ] && [ -z "$(git for-each-ref --contains "$head" --count=1)" ]; then
  die "HEAD $head of $clone is on no branch, tag or synced ref; checking out $sha would orphan it" 3
fi
repo=$(wslpath -u "$source_win")
git fetch --quiet --no-tags "$repo" "$sha"
git update-ref -m "gx-wsl sync $label" refs/gx-wsl/synced "$sha"
git checkout --quiet --detach "$sha"
log "synced $clone to $(git log -1 --format='%h %s') from $label"
"""

RECEIPT_PROGRAM = r'''
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

BUILD_RECEIPT = Path(".local/gx-wsl/gtk-build-receipt.json")


def image_info(path, digest=False):
    with open(path, "rb") as handle:
        stat = os.fstat(handle.fileno())
        info = {"device": stat.st_dev, "inode": stat.st_ino, "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}
        if digest:
            sha = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                sha.update(chunk)
            end = os.fstat(handle.fileno())
            if (end.st_dev, end.st_ino, end.st_size, end.st_mtime_ns) != (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns):
                raise ValueError("executable changed while hashing")
            info["sha256"] = sha.hexdigest()
        return info


def source_identity():
    def git(*args):
        return subprocess.check_output(["git", *args], text=True).strip()
    dirty = git("status", "--porcelain", "--untracked-files=normal")
    return {"commit": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}"),
            "dirty": bool(dirty), "dirty_paths": dirty}


def build_option(argv, key):
    values = [arg.split("=", 1)[1] for arg in argv if arg.startswith("-D" + key + "=")]
    return values[-1] if values else None


def version_mode(version):
    match = re.search(r"build mode\s*:\s*(?:\w+\.)?\.?(Debug|ReleaseFast|ReleaseSafe|ReleaseSmall)\b", version)
    return match.group(1) if match else "unknown"


def build_kind(args):
    if any(arg in ("-h", "--help", "-l", "--list-steps") for arg in args):
        return "query"
    values = {"--summary", "--color", "--seed", "--maxrss", "--sysroot", "--search-prefix", "--libc",
              "--error-style", "--multiline-errors", "--debug-log", "--libc-runtimes", "--glibc-runtimes"}
    flags = {"--verbose", "--verbose-link", "--verbose-cc", "--verbose-cimport", "--debug-pkg-config",
             "--debug-compile-errors", "-fincremental", "-fno-incremental"}
    steps = []
    index = 0
    while index < len(args):
        arg = args[index]
        index += 1
        if arg in values:
            if index == len(args) or not args[index]:
                return "unsupported"
            value = args[index]
            index += 1
            if (arg == "--summary" and value not in ("all", "new", "failures", "line", "none")) or \
                    (arg == "--color" and value not in ("auto", "on", "off")):
                return "unsupported"
        elif arg.startswith(("-Demit-", "-Dtarget=")):
            return "custom"
        elif arg.startswith("-D") and len(arg) > 2:
            continue
        elif arg.startswith(("-fsys=", "-fno-sys=")) and arg.rsplit("=", 1)[1]:
            continue
        elif re.fullmatch(r"-j\d+", arg) and 0 < int(arg[2:]) <= 0xffffffff:
            continue
        elif arg in flags:
            continue
        elif arg.startswith("-"):
            return "unsupported"
        else:
            steps.append(arg)
    return "install" if not steps or steps == ["install"] else "non-install"


def validate_receipt(receipt, source, executable, version, version_exit):
    if source.get("dirty") is not False or source.get("dirty_paths") != "" or \
            any(not re.fullmatch(r"[0-9a-f]{40}", source.get(key, "")) for key in ("commit", "tree")):
        raise ValueError("perf requires a clean committed source tree")
    argv = receipt.get("build_argv", [])
    if receipt.get("schema") != "gx-gtk-build-v1" or receipt.get("producer") != "gx_wsl.py build" or \
            receipt.get("build_exit") != 0 or not isinstance(argv, list) or argv[:3] != ["python3", "scripts/zigw.py", "build"] or \
            not all(isinstance(arg, str) for arg in argv) or build_option(argv, "optimize") != "ReleaseFast" or \
            build_option(argv, "app-runtime") != "gtk":
        raise ValueError("missing successful normal ReleaseFast GTK build receipt")
    if build_kind(argv[3:]) != "install":
        raise ValueError("build receipt does not describe the normal GTK install")
    if receipt.get("source_before") != source or receipt.get("source_after") != source:
        raise ValueError("source identity differs from build receipt")
    if receipt.get("executable") != executable or receipt.get("version") != version or \
            receipt.get("version_exit") != version_exit or version_exit != 0 or version_mode(version) != "ReleaseFast":
        raise ValueError("actual executable/version differs from build receipt")
    match = re.match(r"Ghostty (\S+)", version)
    built_version = match.group(1) if match else ""
    if not built_version.endswith("+" + source["commit"][:9]):
        raise ValueError("binary version does not bind the source commit (unsafe version override)")
    override = build_option(argv, "version-string")
    if override is not None and override != built_version:
        raise ValueError("version override differs from actual binary")
    return receipt


def build_main(argv):
    args = argv[1:]
    kind = build_kind(args)
    standard_gtk = kind == "install" and build_option(args, "app-runtime") == "gtk"
    receipt = {"schema": "gx-gtk-build-v1", "producer": "gx_wsl.py build", "build_kind": kind,
               "build_argv": ["python3", "scripts/zigw.py", "build", *args], "build_exit": None,
               "started_realtime": time.time(), "perf_eligible": False}
    lock = BUILD_RECEIPT.parent / "build.lock"
    BUILD_RECEIPT.parent.mkdir(parents=True, exist_ok=True)
    try:
        lock.mkdir()
    except FileExistsError:
        print("[gx-wsl] error: own clone build is already in progress", file=sys.stderr)
        return 1
    try:
        receipt["source_before"] = source_identity()
        BUILD_RECEIPT.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        if standard_gtk and build_option(args, "optimize") == "ReleaseFast" and receipt["source_before"]["dirty"]:
            raise ValueError("perf build requires a clean committed source tree")
        code = subprocess.run([sys.executable, "scripts/zigw.py", "build", *args], check=False).returncode
        receipt["build_exit"] = code
        if code != 0 or not standard_gtk:
            return code
        receipt["source_after"] = source_identity()
        exe = str(Path("zig-out/bin/ghostty").resolve())
        fd = os.open(exe, os.O_RDONLY)
        try:
            held = f"/proc/self/fd/{fd}"
            receipt["executable"] = {"path": exe, **image_info(held, True)}
            env = dict(os.environ, LD_LIBRARY_PATH=str(Path("zig-out/lib").resolve()))
            env.pop("DISPLAY", None)
            env.pop("WAYLAND_DISPLAY", None)
            version = subprocess.run([held, "+version"], pass_fds=(fd,), env=env, capture_output=True, text=True, timeout=30)
            receipt["version"], receipt["version_exit"] = version.stdout, version.returncode
            if image_info(held, True) != {key: value for key, value in receipt["executable"].items() if key != "path"}:
                raise ValueError("build image changed during version query")
        finally:
            os.close(fd)
        if build_option(args, "optimize") == "ReleaseFast":
            validate_receipt(receipt, receipt["source_after"], receipt["executable"], receipt["version"], receipt["version_exit"])
            receipt["perf_eligible"] = True
        print("[gx-wsl] build receipt: " + str(BUILD_RECEIPT), flush=True)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        receipt["error"] = str(exc)
        print("[gx-wsl] build receipt rejected: " + str(exc), file=sys.stderr)
        return 1
    finally:
        receipt["finished_realtime"] = time.time()
        BUILD_RECEIPT.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        lock.rmdir()
'''

BUILD_BODY = r"""enter_clone
prefetch || warn "some Zig packages could not be prefetched; zig build will try to fetch them itself"
log "python3 scripts/zigw.py build $*"
normal_build "$@"
"""

TEST_BODY = r"""enter_clone
prefetch || warn "some Zig packages could not be prefetched; zig build will try to fetch them itself"
log "python3 scripts/zig_test.py $*"
exec python3 scripts/zig_test.py "$@"
"""

# Used by smoke and run: a private Ghostty config home and the --lang environment.
GHOSTTY_HELPERS = r"""prepare_config() {
  local home=$1/xdg-config config_win=$2
  mkdir -p "$home/ghostty"
  {
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
      printf 'env = XDG_CONFIG_HOME=%s\n' "$XDG_CONFIG_HOME"
    else
      printf 'env = XDG_CONFIG_HOME=\n'
    fi
    if [ -n "$config_win" ]; then
      sed 's/\r$//' "$(wslpath -u "$config_win")"
      printf '\n'
    fi
  } >"$home/ghostty/config.ghostty"
  export XDG_CONFIG_HOME=$home
}
apply_lang() {
  [ -n "$1" ] || return 0
  export LANG=$1 LC_ALL=$1 LANGUAGE=$2
}
alive() {
  local state
  state=$(awk '/^State:/ {print $2}' "/proc/$1/status" 2>/dev/null || true)
  [ -n "$state" ] && [ "$state" != Z ]
}
require_ghostty() {
  [ -x zig-out/bin/ghostty ] || die "$clone/zig-out/bin/ghostty is missing; run: python scripts/gx_wsl.py build --gtk" 2
}
"""

PERF_DELIMITER = "GX_WSL_PERF"
PERF_PROGRAM = r"""
import math
import os
import re
import sys

FIRST = ("main", "renderer", "io", "io-reader", "io-gather")
COUNTERS = ("utime", "stime", "minflt", "majflt")
DMABUF_WARNINGS = ("failed to export DMABUF", "failed to build dmabuf")


def group_name(comm):
    return re.sub(r"[^A-Za-z0-9_.:-]", "_", re.sub(r"-\d+$", "", comm)) or "unnamed"


def parse_tasks(text):
    tasks = {}
    for line in text.splitlines():
        tid, sep, stat = line.partition("\t")
        tid = tid.strip()
        if not sep or not tid.isdigit() or int(tid) <= 0 or tid in tasks or "(" not in stat or ")" not in stat:
            raise ValueError("malformed or duplicate task stat: " + line)
        if stat.split("(", 1)[0].strip() != tid:
            raise ValueError("task stat TID mismatch: " + line)
        fields = stat[stat.rindex(")") + 1 :].split()
        if len(fields) < 50 or fields[0] in ("Z", "X", "x"):
            raise ValueError("partial or exited task stat: " + line)
        task = {"comm": stat[stat.index("(") + 1 : stat.rindex(")")], "starttime": int(fields[19])}
        task.update({key: int(fields[index]) for key, index in zip(COUNTERS, (11, 12, 7, 9))})
        if task["starttime"] <= 0 or any(task[key] < 0 for key in COUNTERS):
            raise ValueError("negative counters or missing task birth: " + tid)
        tasks[tid] = task
    if not tasks:
        raise ValueError("no thread statistics")
    return tasks


def parse_times(text):
    values = {}
    for line in text.splitlines():
        key, _, value = line.strip().partition(" ")
        if key:
            values[key] = value.strip()
    return values


def deltas(before, after, pid):
    if pid not in before or pid not in after:
        raise ValueError("missing main thread")
    if set(before) != set(after):
        raise ValueError(f"thread population changed: gone={sorted(set(before) - set(after))}, added={sorted(set(after) - set(before))}")
    groups = {}
    names = {"main": "<main>", "total": "<process total>", "endpoint_threads": "<endpoint total>"}
    for tid, now in after.items():
        then = before[tid]
        if (now["starttime"], now["comm"]) != (then["starttime"], then["comm"]):
            raise ValueError("task identity changed: " + tid)
        token = "main" if tid == pid else group_name(now["comm"])
        base = "<main>" if tid == pid else re.sub(r"-\d+$", "", now["comm"])
        if token in names and names[token] != base:
            raise ValueError("thread metric token collision: " + token)
        names[token] = base
        group = groups.setdefault(token, dict.fromkeys(("threads",) + COUNTERS, 0))
        group["threads"] += 1
        for key in COUNTERS:
            change = now[key] - then[key]
            if change < 0:
                raise ValueError(f"negative {key} delta: {tid}")
            group[key] += change
    return groups, []


def measurement(before_text, after_text, times_text):
    times = parse_times(times_text)
    groups, _ = deltas(parse_tasks(before_text), parse_tasks(after_text), times.get("pid", ""))
    if "renderer" not in groups:
        raise ValueError("missing renderer thread")
    if times.get("workload_finished") != "1":
        raise ValueError("incomplete workload")
    if times.get("run_exit", "0") != "0":
        raise ValueError("nonzero run exit")
    for key in ("window_seconds", "workload_seconds"):
        value = float(times.get(key, "nan"))
        if not math.isfinite(value) or value < 0:
            raise ValueError("missing or invalid " + key)
    return groups


def cpu_accounting(before_text, after_text, process_before, process_after, pid, clk_tck):
    before, after = parse_tasks(before_text), parse_tasks(after_text)
    deltas(before, after, pid)
    if type(clk_tck) is not int or clk_tck <= 0:
        raise ValueError("invalid CLK_TCK")
    brackets = []
    for sample in (process_before, process_after):
        begin, end = sample["begin_ns"], sample["end_ns"]
        if type(begin) is not int or type(end) is not int or begin < 0 or end < begin:
            raise ValueError("invalid process/task snapshot read order")
        low = parse_tasks(pid + "\t" + sample["pre_stat"])[pid]
        high = parse_tasks(pid + "\t" + sample["post_stat"])[pid]
        if any(task["starttime"] != before[pid]["starttime"] for task in (low, high)):
            raise ValueError("process accounting identity changed")
        if any(high[key] < low[key] for key in COUNTERS):
            raise ValueError("process counter decreased within snapshot")
        brackets.append((low, high))
    if process_after["begin_ns"] < process_before["end_ns"]:
        raise ValueError("overlapping process measurement endpoints")
    total = {key: brackets[1][1][key] - brackets[0][1][key] for key in COUNTERS}
    if any(value < 0 for value in total.values()):
        raise ValueError("negative process counter delta")
    endpoint = {key: sum(after[tid][key] - before[tid][key] for tid in before) for key in COUNTERS}
    residual = {key: total[key] - endpoint[key] for key in ("utime", "stime")}
    rounding = len(before) + len(after) + 2
    skew = {key: sum(high[key] - low[key] for low, high in brackets) for key in residual}
    bound = {key: rounding + skew[key] for key in residual}
    return {"total_source": "process stat post-to-post (includes exited threads)",
            "thread_population": "endpoint identities only; no full-lifetime population proof",
            "comparison_contract": "quantized process/endpoint ticks; no full-population or rounding-bound guarantee",
            "diagnostic_only": True, "bound_proof": "unproved for Linux adjusted CPU counters; not a sample-validity or benefit gate",
            "clk_tck": clk_tck, "process_counters": total, "endpoint_counters": endpoint,
            "residual_ticks": residual, "diagnostic_rounding_ticks_per_counter": rounding, "read_skew_ticks": skew,
            "diagnostic_bound_ticks": bound, "diagnostic_within_bound": all(abs(residual[key]) <= bound[key] for key in residual),
            "snapshot_durations_ns": [sample["end_ns"] - sample["begin_ns"] for sample in (process_before, process_after)],
            "process_window_begin_ns": process_before["end_ns"], "process_window_end_ns": process_after["end_ns"]}


def report(before_text, after_text, times_text, log_text, clk_tck, process_before=None, process_after=None):
    times = parse_times(times_text)
    lines = ["# gx-wsl smoke --perf",
             "workload: seq 1 3000000 run by `ghostty -e sh workload.sh` once the first screenshot is taken",
             "finished: " + ("yes" if times.get("workload_finished") == "1" else "no")]
    try:
        groups = measurement(before_text, after_text, times_text)
        if clk_tck <= 0:
            raise ValueError("invalid CLK_TCK")
        accounting = cpu_accounting(before_text, after_text, process_before, process_after, times["pid"], clk_tck) if process_before is not None else None
    except (ValueError, KeyError, TypeError) as exc:
        return "\n".join([*lines, "valid: no", "rejected: " + str(exc)]) + "\n"
    lines += ["valid: yes (identity/build receipt must be checked in meta.json)",
              "clock: realtime elapsed; window/done polling 50 ms; CPU includes the 1 s drain tail",
              "population: endpoint identities only; transient population not proven",
              "cpu.total: " + ("process aggregate including exited threads" if accounting else "unverified endpoint sum; no process reconciliation")]
    order = [name for name in FIRST if name in groups]
    order += sorted((name for name in groups if name not in FIRST), key=lambda name: -(groups[name]["utime"] + groups[name]["stime"]))
    total = {key: sum(group[key] for group in groups.values()) for key in ("threads",) + COUNTERS}
    if accounting:
        endpoint_cpu = (total["utime"] + total["stime"]) / clk_tck
        lines.append(f"metric cpu.endpoint_threads {endpoint_cpu:.3f} s")
        total.update(accounting["process_counters"])
        lines.append(f"diagnostic only: residual_ticks={accounting['residual_ticks']} candidate_bound_ticks={accounting['diagnostic_bound_ticks']} (Linux rounding proof missing; not a validity/benefit gate)")
    for key in ("window_seconds", "workload_seconds"):
        lines.append(f"metric {key} {float(times[key]):.3f} s")
    for name in order + ["total"]:
        group = total if name == "total" else groups[name]
        lines.append(f"metric cpu.{name} {(group['utime'] + group['stime']) / clk_tck:.3f} s")
    lines.append(f"metric minflt.total {total['minflt']}")
    lines.append(f"metric majflt.total {total['majflt']}")
    lines.append(f"metric dmabuf_warnings {sum(any(needle in line for needle in DMABUF_WARNINGS) for line in log_text.splitlines())}")
    lines.append(f"metric gx_perf_lines {sum('(gx_perf):' in line for line in log_text.splitlines())}")
    lines += ["", f"{'thread':<24} {'threads':>7} {'cpu_s':>8} {'user_s':>8} {'sys_s':>8} {'minflt':>9} {'majflt':>7}"]
    for name in order + ["total"]:
        group = total if name == "total" else groups[name]
        lines.append(f"{name:<24} {group['threads']:>7} {(group['utime'] + group['stime']) / clk_tck:>8.3f} "
                     f"{group['utime'] / clk_tck:>8.3f} {group['stime'] / clk_tck:>8.3f} {group['minflt']:>9} {group['majflt']:>7}")
    return "\n".join(lines) + "\n"


def main(argv):
    try:
        texts = []
        for path in argv[1:5]:
            with open(path, encoding="utf-8", errors="strict") as handle:
                texts.append(handle.read())
        result = report(*texts, os.sysconf("SC_CLK_TCK"))
    except (OSError, ValueError) as exc:
        result = "valid: no\nrejected: " + str(exc) + "\n"
    sys.stdout.write(result)
    return 1 if "valid: no" in result else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
"""

# smoke --perf runs this as `ghostty -e sh workload.sh`: it waits for the file `go` next to it,
# writes the load to the terminal, then marks `done` and keeps the terminal open.
PERF_WORKLOAD = r"""dir=${0%/*}
while [ ! -e "$dir/go" ]; do sleep 0.05; done
seq 1 3000000
result=$?
printf '%s\n' "$result" >"$dir/workload-exit"
[ "$result" -eq 0 ] && touch "$dir/done"
exec sleep 3600
"""

SMOKE_PROGRAM = RECEIPT_PROGRAM.split("\ndef build_main(", 1)[0] + r"""
import select
import signal
import uuid

ENV_KEYS = ("DISPLAY", "WAYLAND_DISPLAY", "GDK_BACKEND", "GSK_RENDERER", "LIBGL_ALWAYS_SOFTWARE", "GALLIUM_DRIVER",
            "MESA_LOADER_DRIVER_OVERRIDE", "MESA_GL_VERSION_OVERRIDE", "EGL_PLATFORM", "NO_AT_BRIDGE", "GHOSTTY_GX_PERF",
            "LANG", "LC_ALL", "LANGUAGE", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "LD_LIBRARY_PATH")


def copy_evidence(source, target):
    for path in sorted(Path(source).iterdir()):
        with open(Path(target) / path.name, "xb") as handle:
            handle.write(path.read_bytes())


def process_identity(pid, digest=False):
    root = Path("/proc") / str(pid)
    task = parse_tasks(f"{pid}\t" + (root / "stat").read_text())[str(pid)]
    return {"pid": pid, "starttime": task["starttime"], "exe": os.readlink(root / "exe"),
            **image_info(root / "exe", digest)}


def require_identity(pid, expected, pidfd, digest=False):
    if select.select([pidfd], [], [], 0)[0]:
        raise ValueError("controlled child exited")
    identity = process_identity(pid, digest)
    if any(identity.get(key) != value for key, value in expected.items() if key != "sha256" or digest):
        raise ValueError("process identity changed")
    return identity


def stop_child(child, pidfd, meta):
    if child is None:
        return
    if pidfd is None:
        # Popen has never polled/waited: our unreaped direct child still owns this PID.
        child.terminate()
        meta["cleanup"] = "unreaped direct Popen child (pidfd_open failed)"
    else:
        try:
            if "identity" not in meta:
                raise ValueError("no launch identity")
            current = require_identity(child.pid, meta["identity"], pidfd, True)
            meta["identity_checks"].append({"stage": "cleanup", "realtime": time.time(), **current})
            meta["cleanup_identity"] = "verified"
        except (OSError, ValueError) as exc:
            meta["errors"].append("cleanup: " + str(exc))
            meta["cleanup_identity"] = "failed; owned pidfd only"
        try:
            signal.pidfd_send_signal(pidfd, signal.SIGTERM)
        except ProcessLookupError:
            pass
        meta["cleanup"] = "owned pidfd SIGTERM"
    try:
        meta["child_exit"] = child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if pidfd is None:
            child.kill()
        else:
            signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        meta["cleanup"] += ", SIGKILL"
        meta["errors"].append("child required forced cleanup")
        meta["child_exit"] = child.wait(timeout=5)
    if meta["child_exit"] not in (0, -signal.SIGTERM):
        meta["errors"].append("unexpected child exit: " + str(meta["child_exit"]))
    if pidfd is not None:
        os.close(pidfd)


def smoke_main(argv):
    evidence, name, wait_seconds, xdo, settle, perf, work, screen, *extra = argv[1:]
    evidence, work = Path(evidence), Path(work)
    perf = perf == "1"
    prefix = evidence / name
    meta = {"schema": "gx-gtk-perf-v1", "perf": perf, "valid": False, "exit": 1, "errors": [],
            "started_realtime": time.time(), "identity_checks": [], "workload_finished": False,
            "effective_env": {key: os.environ.get(key) for key in ENV_KEYS}, "screen": screen,
            "clock": "realtime elapsed; 50 ms polling; CPU includes 1 s drain tail", "warmup": "none",
            "clk_tck": os.sysconf("SC_CLK_TCK"),
            "renderer_evidence": {"egl": "unknown", "cpu_fallback": "unknown", "hardware": "unknown"}}
    meta["capture_id"] = uuid.uuid4().hex
    times = {}
    child = pidfd = exe_fd = None
    before = after = ""
    process_before = process_after = None

    def save(suffix, text):
        (evidence / (name + suffix)).write_text(text, encoding="utf-8", newline="\n")

    def guard(stage, digest=False):
        current = require_identity(child.pid, meta["identity"], pidfd, digest)
        if digest:
            meta["identity_checks"].append({"stage": stage, "realtime": time.time(), **current})
        return current

    def checked(command, stage, check=True):
        guard(stage + " before", stage == "xdotool script")
        result = subprocess.run(command, capture_output=True, text=True, check=check, timeout=30)
        guard(stage + " after", stage == "xdotool script")
        return result

    def capture(suffix):
        checked(["scrot", str(prefix) + suffix], "screenshot " + suffix)
        if (evidence / (name + suffix)).stat().st_size == 0:
            raise ValueError("empty screenshot")

    def snapshot(stage):
        guard(stage + " before", True)
        root = Path("/proc") / str(child.pid)
        process = {"begin_ns": time.monotonic_ns(), "pre_stat": (root / "stat").read_text().strip()}
        tids = sorted((root / "task").iterdir(), key=lambda p: int(p.name))
        rows = []
        for task in tids:
            try:
                stat = (task / "stat").read_text().strip()
            except OSError:
                stat = ""
            rows.append(task.name + "\t" + stat)
        process.update(post_stat=(root / "stat").read_text().strip(), end_ns=time.monotonic_ns())
        text = "\n".join(rows) + "\n"
        save("-tasks-" + stage + ".txt", text)
        save("-process-" + stage + ".json", json.dumps(process, indent=2) + "\n")
        save("-status-" + stage + ".txt", (root / "status").read_text())
        if {p.name for p in (root / "task").iterdir()} != {p.name for p in tids}:
            raise ValueError("thread population changed during snapshot")
        guard(stage + " after", True)
        parse_tasks(text)
        return text, process

    try:
        if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
            raise ValueError("pidfd unavailable; refusing to launch")
        probe = os.pidfd_open(os.getpid())
        try:
            signal.pidfd_send_signal(probe, 0)
        finally:
            os.close(probe)
        meta.update(source_identity())
        if perf and meta["dirty"]:
            raise ValueError("perf requires a clean committed source tree")
        exe = str(Path("zig-out/bin/ghostty").resolve())
        exe_fd = os.open(exe, os.O_RDONLY)
        held = f"/proc/self/fd/{exe_fd}"
        meta["executable"] = {"path": exe, **image_info(held, True)}
        version = subprocess.run([held, "+version"], pass_fds=(exe_fd,), capture_output=True, text=True, timeout=30)
        save("-version.txt", version.stdout + version.stderr)
        meta["version"] = version.stdout
        meta["version_exit"] = version.returncode
        mode = re.search(r"build mode\s*:\s*(?:\w+\.)?\.?(Debug|ReleaseFast|ReleaseSafe|ReleaseSmall)\b", version.stdout)
        meta["build_mode"] = mode.group(1) if mode else "unknown"
        if version.returncode != 0 or (perf and meta["build_mode"] != "ReleaseFast"):
            raise ValueError("perf requires verified ReleaseFast" if perf else "version failed")
        if perf and os.environ.get("GHOSTTY_GX_PERF", "").strip().lower() not in ("1", "true", "on", "yes"):
            raise ValueError("GHOSTTY_GX_PERF not enabled")
        if perf:
            if (BUILD_RECEIPT.parent / "build.lock").exists():
                raise ValueError("normal build is still in progress")
            receipt_text = BUILD_RECEIPT.read_text(encoding="utf-8")
            receipt = json.loads(receipt_text)
            source = {key: meta[key] for key in ("commit", "tree", "dirty", "dirty_paths")}
            validate_receipt(receipt, source, meta["executable"], meta["version"], meta["version_exit"])
            meta["build_receipt_sha256"] = hashlib.sha256(receipt_text.encode()).hexdigest()
            save("-build-receipt.json", receipt_text)
        command = [exe, "--gtk-single-instance=false", *extra]
        if perf:
            command += ["-e", "sh", str(work / "workload.sh")]
        meta["command"] = command
        times["launch_realtime"] = time.time()
        with open(str(prefix) + ".log", "w") as log:
            child = subprocess.Popen(command, executable=held, pass_fds=(exe_fd,), stdout=log, stderr=log)
        pidfd = os.pidfd_open(child.pid)
        identity = process_identity(child.pid, True)
        meta["identity"] = identity
        if any(identity[key] != value for key, value in meta["executable"].items() if key != "path"):
            raise ValueError("launch executable mismatch")
        times["pid"] = child.pid
        guard("launch", True)
        deadline = time.monotonic() + float(wait_seconds)
        window = ""
        while time.monotonic() < deadline:
            found = checked(["xdotool", "search", "--onlyvisible", "--pid", str(child.pid)], "window search", False)
            if found.returncode == 0 and found.stdout.strip():
                window = found.stdout.splitlines()[0]
                owner = checked(["xdotool", "getwindowpid", window], "window owner")
                if owner.stdout.strip() != str(child.pid):
                    raise ValueError("window PID mismatch")
                break
            time.sleep(0.05)
        if not window:
            raise ValueError("no visible window within " + wait_seconds + " s")
        meta["window"] = window
        times["window_seconds"] = time.time() - times["launch_realtime"]
        time.sleep(float(settle))
        capture(".png")
        if perf:
            before, process_before = snapshot("before")
            times["workload_begin_realtime"] = time.time()
            (work / "go").touch()
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                guard("workload")
                if (work / "done").exists():
                    meta["workload_finished"] = True
                    break
                time.sleep(0.05)
            times["workload_end_realtime"] = time.time()
            times["workload_seconds"] = times["workload_end_realtime"] - times["workload_begin_realtime"]
            times["workload_finished"] = int(meta["workload_finished"])
            meta["workload_exit"] = (work / "workload-exit").read_text().strip() if (work / "workload-exit").exists() else None
            if meta["workload_exit"] != "0":
                raise ValueError("workload failed or exit unavailable")
            time.sleep(1)
            after, process_after = snapshot("after")
            times["cpu_end_realtime"] = time.time()
            capture("-perf.png")
            measurement(before, after, "\n".join(f"{key} {value}" for key, value in times.items()))
            meta["cpu_accounting"] = cpu_accounting(before, after, process_before, process_after, str(child.pid), meta["clk_tck"])
        if xdo:
            checked(["xdotool", xdo, str(child.pid)], "xdotool script")
            time.sleep(1)
            capture("-after.png")
        guard("finished", True)
        if perf:
            meta["source_end"] = source_identity()
            if BUILD_RECEIPT.read_text(encoding="utf-8") != receipt_text:
                raise ValueError("normal build receipt changed during smoke")
            validate_receipt(receipt, meta["source_end"], meta["executable"], meta["version"], meta["version_exit"])
        meta["exit"] = 0
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        meta["errors"].append(str(exc))
    except KeyboardInterrupt:
        meta["errors"].append("interrupted")
    finally:
        try:
            stop_child(child, pidfd, meta)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            meta["errors"].append("cleanup failed: " + str(exc))
        if exe_fd is not None:
            os.close(exe_fd)
        if meta["errors"]:
            meta["exit"] = 1
        meta["valid"] = meta["exit"] == 0
        meta["finished_realtime"] = time.time()
        times["run_exit"] = meta["exit"]
        times_text = "\n".join(f"{key} {value}" for key, value in times.items()) + "\n"
        save("-times.txt", times_text)
        log_path = evidence / (name + ".log")
        log_text = log_path.read_text(errors="replace") if log_path.exists() else ""
        meta["renderer_evidence"]["runtime_log_lines"] = [line for line in log_text.splitlines()
            if any(token in line.lower() for token in ("opengl", "egl", "dmabuf", "llvmpipe", "cpu presentation"))]
        if perf:
            save("-perf.txt", report(before, after, times_text, log_text, os.sysconf("SC_CLK_TCK"), process_before, process_after))
        meta["files"] = sorted(p.name for p in evidence.iterdir())
        meta["artifact_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in evidence.iterdir()}
        save("-meta.txt", "\n".join(f"{key}: {value}" for key, value in meta.items() if key not in ("renderer_evidence", "files")) + "\n")
        save("-meta.json", json.dumps(meta, indent=2) + "\n")
    print("[gx-wsl] " + ("smoke passed" if meta["valid"] else "smoke rejected: " + "; ".join(meta["errors"])), flush=True)
    return meta["exit"]


if __name__ == "__main__":
    if sys.argv[1:2] == ["--copy"]:
        copy_evidence(sys.argv[2], sys.argv[3])
    else:
        sys.exit(smoke_main(sys.argv))
"""

SMOKE_BODY = r"""out_win=$1
lang=$2
language=$3
xdotool_win=$4
config_win=$5
wait_seconds=$6
name=$7
screen=$8
settle=$9
perf=${10}
env_spec=${11}
workload=${12}
shift 12
enter_clone
require_ghostty
for tool in xvfb-run xauth scrot xdotool; do
  command -v "$tool" >/dev/null || die "$tool is not installed; run: python scripts/gx_wsl.py setup --apt" 2
done
out=$(wslpath -u "$out_win")
mkdir -p "$out"
if compgen -G "$out/$name*" >/dev/null; then die "evidence prefix already exists in $out; use a new directory" 2; fi
lock=$out/.gx-wsl-$name
mkdir "$lock" || die "evidence prefix is already in use: $out/$name" 2
work=$(mktemp -d "${TMPDIR:-/tmp}/gx-wsl-smoke.XXXXXX")
keep_work=0
trap '[ "$keep_work" = 1 ] || rm -rf "$work"; rmdir "$lock"' EXIT
if compgen -G "$out/$name*" >/dev/null; then die "evidence prefix appeared while acquiring lock: $out/$name" 2; fi
evidence=$work/evidence
mkdir -p "$evidence"
xdo=
if [ -n "$xdotool_win" ]; then
  xdo=$work/script.xdo
  sed 's/\r$//' "$(wslpath -u "$xdotool_win")" >"$xdo"
fi
prepare_config "$work" "$config_win"
export XDG_STATE_HOME=$work/xdg-state
apply_lang "$lang" "$language"
export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1
export LD_LIBRARY_PATH=$clone/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
unset WAYLAND_DISPLAY
if [ "$perf" = 1 ]; then
  export GHOSTTY_GX_PERF=1
  printf '%s' "$workload" >"$work/workload.sh"
fi
while IFS= read -r assignment; do
  if [ -n "$assignment" ]; then export "$assignment"; fi
done <<<"$env_spec"
write_smoke_program >"$work/session.py"
status=0
xvfb-run --auto-servernum --server-args="-screen 0 $screen" python3 "$work/session.py" \
  "$evidence" "$name" "$wait_seconds" "$xdo" "$settle" "$perf" "$work" "$screen" "$@" || status=$?
if ! python3 "$work/session.py" --copy "$evidence" "$out"; then
  keep_work=1
  warn "evidence copy failed; original raw retained in $evidence"
  exit 1
fi
for file in "$evidence"/*; do log "evidence: $(wslpath -w "$out/${file##*/}")"; done
exit "$status"
"""

RUN_BODY = r"""lang=$1
language=$2
config_win=$3
x11=$4
shift 4
enter_clone
require_ghostty
runs=$HOME/.cache/gx-wsl/run
mkdir -p "$runs"
find "$runs" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | tail -n +10 | cut -d' ' -f2- \
  | while IFS= read -r old; do rm -rf "$old"; done
state=$runs/$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$state"
prepare_config "$state" "$config_win"
apply_lang "$lang" "$language"
export LD_LIBRARY_PATH=$clone/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
if [ "$x11" = 1 ]; then
  export GDK_BACKEND=x11
fi
setsid ./zig-out/bin/ghostty --gtk-single-instance=false "$@" >"$state/ghostty.log" 2>&1 </dev/null &
pid=$!
sleep 3
if ! alive "$pid"; then
  tail -n 20 "$state/ghostty.log" >&2 || true
  die "ghostty exited during startup; log: $state/ghostty.log"
fi
log "ghostty is running on WSLg as pid $pid (log: $state/ghostty.log)"
log "stop it with: wsl.exe -d ${WSL_DISTRO_NAME:-<distro>} -e kill $pid"
"""

SHELL_QUERY = r"""cd "$clone" 2>/dev/null && pwd || printf '%s\n' "$clone"
"""


class GxWslError(RuntimeError):
    """A usage, environment or Windows-side git problem; reported with exit code 2."""


@dataclass(frozen=True)
class Invocation:
    """One bash script run through wsl.exe with positional arguments; user None means the default user."""

    script: str
    args: tuple[str, ...]
    user: str | None = None


@dataclass(frozen=True)
class SyncTarget:
    sha: str
    source: str
    label: str
    worktree: str | None = None
    uncommitted: bool = False


def utf8_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            pass


def prefetch_function() -> str:
    """Bash function `prefetch [--check]` that pipes PREFETCH_PROGRAM into python3 via a quoted heredoc."""
    if PREFETCH_DELIMITER in PREFETCH_PROGRAM.splitlines():
        raise AssertionError("PREFETCH_PROGRAM contains its heredoc delimiter")
    return (
        "prefetch() {\n"
        f"  python3 - \"$clone\" \"$@\" <<'{PREFETCH_DELIMITER}'\n"
        f"{PREFETCH_PROGRAM.strip()}\n"
        f"{PREFETCH_DELIMITER}\n"
        "}\n"
    )


def perf_function() -> str:
    """Bash function `perf_report BEFORE AFTER TIMES LOG` that pipes PERF_PROGRAM into python3."""
    if PERF_DELIMITER in PERF_PROGRAM.splitlines():
        raise AssertionError("PERF_PROGRAM contains its heredoc delimiter")
    return (
        "perf_report() {\n"
        f"  python3 - \"$@\" <<'{PERF_DELIMITER}'\n"
        f"{PERF_PROGRAM.strip()}\n"
        f"{PERF_DELIMITER}\n"
        "}\n"
    )


def build_function() -> str:
    return "normal_build() {\npython3 - \"$@\" <<'GX_WSL_BUILD'\n" + RECEIPT_PROGRAM.strip() + "\nsys.exit(build_main(sys.argv))\nGX_WSL_BUILD\n}\n"


def smoke_function() -> str:
    program = PERF_PROGRAM.rsplit('\nif __name__ == "__main__":', 1)[0] + SMOKE_PROGRAM
    program = "\n".join(re.sub(r"^(?:    )+", lambda m: "  " * (len(m[0]) // 4), line) for line in program.splitlines())
    return "write_smoke_program() {\ncat <<'GX_WSL_SESSION'\n" + program.strip() + "\nGX_WSL_SESSION\n}\n"


def compose(*parts: str) -> str:
    return "\n".join(part.rstrip("\n") for part in parts) + "\n"


def wsl_command(distro: str, invocation: Invocation) -> list[str]:
    """wsl.exe argv. `-e` execs bash directly: the default login shell (zsh here) never re-parses
    the script, and every value reaches bash as its own positional argument."""
    command = [WSL_EXE, "-d", distro]
    if invocation.user:
        command += ["-u", invocation.user]
    return [*command, "--cd", "~", "-e", "bash", "-c", invocation.script, SCRIPT_NAME, *invocation.args]


def check_clone_path(clone: str) -> str:
    if WINDOWS_PATH.match(clone) or not (clone == "~" or clone.startswith("~/") or clone.startswith("/")):
        raise GxWslError(
            f"--clone must be a Linux path such as ~/src/gx_ghostty or /home/<user>/src/gx_ghostty, got {clone!r} "
            "(Git Bash rewrites arguments that start with /: quote '~/...' or set MSYS_NO_PATHCONV=1)"
        )
    return clone


def windows_path(path: str) -> str:
    """Absolute Windows path for wslpath -u inside WSL; relative paths are taken from the current directory."""
    return os.path.abspath(path)


def setup_invocations(clone: str, source: str, *, check: bool, apt: bool) -> list[Invocation]:
    packages = " ".join(APT_PACKAGES)
    locales = " ".join(LOCALES)
    invocations = []
    if apt:
        invocations.append(Invocation(APT_SCRIPT, (packages, locales), user="root"))
    body = CHECK_BODY if check else SETUP_BODY
    script = compose(PRELUDE, PREREQUISITES, BLUEPRINT, prefetch_function(), body)
    args = (clone, source, BLUEPRINT_VERSION, BLUEPRINT_URL, BLUEPRINT_SHA256, packages, locales)
    invocations.append(Invocation(script, args))
    return invocations


def sync_invocation(clone: str, target: SyncTarget) -> Invocation:
    return Invocation(compose(PRELUDE, SYNC_BODY), (clone, target.source, target.sha, target.label))


def build_args(gtk: bool, extra: Sequence[str]) -> list[str]:
    return [*(GTK_BUILD_ARGS if gtk else ()), *extra]


def build_invocation(clone: str, gtk: bool, extra: Sequence[str]) -> Invocation:
    return Invocation(compose(PRELUDE, prefetch_function(), build_function(), BUILD_BODY), (clone, *build_args(gtk, extra)))


def zig_test_args(suite: str, gtk: bool, filters: Sequence[str], extra: Sequence[str]) -> list[str]:
    """zig_test.py arguments. -fno-sys is not a -D option, so it reaches zig build through --zig-arg."""
    args = ["--suite", suite]
    if gtk:
        args += [arg if arg.startswith("-D") else f"--zig-arg={arg}" for arg in GTK_BUILD_ARGS]
    elif suite == "main":
        args += MAIN_SUITE_ARGS
    for text in filters:
        args += ["--filter", text]
    return [*args, *extra]


def zig_test_invocation(clone: str, suite: str, gtk: bool, filters: Sequence[str], extra: Sequence[str]) -> Invocation:
    return Invocation(compose(PRELUDE, prefetch_function(), TEST_BODY), (clone, *zig_test_args(suite, gtk, filters, extra)))


def lang_values(lang: str | None) -> tuple[str, str]:
    return LANGS[lang] if lang else ("", "")


def smoke_name(name: str | None, lang: str | None) -> str:
    result = name or ("ghostty-xvfb" + (f"-{lang}" if lang else ""))
    if not NAME_PATTERN.match(result):
        raise GxWslError(f"--name may only contain letters, digits, '.', '_' and '-', got {result!r}")
    return result


def env_assignments(values: Sequence[str]) -> str:
    """The --env NAME=VALUE assignments, one per line; names are shell variable names, values one line."""
    lines = []
    for value in values:
        name, sep, rest = value.partition("=")
        if not sep or not ENV_NAME_PATTERN.match(name):
            raise GxWslError(f"--env takes NAME=VALUE with a shell variable name, got {value!r}")
        if "\n" in rest or "\r" in rest or "\0" in rest:
            raise GxWslError(f"--env values must be a single line, got {value!r}")
        if name in ("DISPLAY", "WAYLAND_DISPLAY", "XDG_CONFIG_HOME", "XDG_STATE_HOME") or (name == "GDK_BACKEND" and rest != "x11"):
            raise GxWslError(f"--env cannot override smoke isolation: {name}")
        lines.append(value)
    return "\n".join(lines)


def smoke_invocation(
    clone: str,
    *,
    out: str,
    lang: str | None,
    xdotool: str | None,
    config: str | None,
    wait: float,
    name: str | None,
    ghostty_args: Sequence[str],
    settle: float = SMOKE_SETTLE_SECONDS,
    perf: bool = False,
    env: Sequence[str] = (),
) -> Invocation:
    lang_value, language = lang_values(lang)
    args = (
        clone,
        windows_path(out),
        lang_value,
        language,
        windows_path(xdotool) if xdotool else "",
        windows_path(config) if config else "",
        f"{wait:g}",
        smoke_name(name, lang),
        SMOKE_SCREEN,
        f"{settle:g}",
        "1" if perf else "0",
        env_assignments(env),
        PERF_WORKLOAD,
        *ghostty_args,
    )
    return Invocation(compose(PRELUDE, GHOSTTY_HELPERS, smoke_function(), SMOKE_BODY), args)


def run_invocation(clone: str, *, lang: str | None, config: str | None, x11: bool, ghostty_args: Sequence[str]) -> Invocation:
    lang_value, language = lang_values(lang)
    args = (clone, lang_value, language, windows_path(config) if config else "", "1" if x11 else "0", *ghostty_args)
    return Invocation(compose(PRELUDE, GHOSTTY_HELPERS, RUN_BODY), args)


def git(cwd: Path | str, *args: str, env: Mapping[str, str] | None = None, check: bool = True) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(cwd), *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdin=subprocess.DEVNULL,
            env=None if env is None else dict(env),
            check=False,
        )
    except OSError as exc:
        raise GxWslError(f"cannot run git: {exc}") from exc
    if check and result.returncode != 0:
        raise GxWslError(f"git {' '.join(args)} failed in {cwd}: {result.stderr.strip() or result.returncode}")
    return result.stdout.strip() if result.returncode == 0 else ""


def same_path(left: str | Path, right: str | Path) -> bool:
    return os.path.normcase(os.path.realpath(left)) == os.path.normcase(os.path.realpath(right))


def common_dir(path: Path | str) -> str:
    return git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")


def fetch_source(common: str) -> str:
    """Directory to fetch from: the main worktree for a `.git` common dir, else the (bare) repository."""
    path = Path(common)
    return str(path.parent) if path.name == ".git" else str(path)


def snapshot_commit(worktree: Path | str) -> str:
    """Commit object holding the worktree's tracked and untracked (not ignored) files on top of HEAD.

    A temporary index keeps the worktree's own index, refs and files untouched; the object only
    lives in the object database until git gc prunes it.
    """
    with tempfile.TemporaryDirectory(prefix="gx-wsl-snapshot-") as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(tmp) / "index")}
        git(worktree, "read-tree", "HEAD", env=env)
        git(worktree, "add", "--all", env=env)
        tree = git(worktree, "write-tree", env=env)
    return git(
        worktree,
        "commit-tree",
        tree,
        "-p",
        "HEAD",
        "-m",
        "gx-wsl snapshot of uncommitted changes",
        env={**os.environ, **SNAPSHOT_IDENTITY},
    )


def resolve_sync_target(
    target: str | None, *, repo_root: Path = REPO_ROOT, dirty: bool = False, dry_run: bool = False
) -> SyncTarget:
    """A worktree directory (default: the one containing this script) or a ref of this repository.

    A dry run never writes the snapshot object; its sha is the placeholder `<snapshot>`.
    """
    if target is not None and target.startswith("-"):
        raise GxWslError(f"not a ref or worktree path: {target}")
    if target is None or os.path.isdir(target):
        path = Path(target) if target is not None else repo_root
        top = git(path, "rev-parse", "--show-toplevel")
        if not same_path(top, path):
            raise GxWslError(f"{path} is not the top of a git worktree (that is {top})")
        head = git(path, "rev-parse", "HEAD")
        branch = git(path, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
        where = f"worktree {top} ({branch or 'detached'})"
        changed = bool(git(path, "status", "--porcelain"))
        source = fetch_source(common_dir(path))
        if dirty and changed:
            sha = "<snapshot>" if dry_run else snapshot_commit(path)
            return SyncTarget(sha, source, f"{where} with uncommitted changes", top, True)
        if changed:
            print(f"{TAG} note: {top} has uncommitted changes that are not synced (add --dirty to include them)", file=sys.stderr)
        return SyncTarget(head, source, where, top)
    if dirty:
        raise GxWslError("--dirty only applies to a worktree path")
    sha = git(repo_root, "rev-parse", "--verify", "--quiet", f"{target}^{{commit}}", check=False)
    if not sha:
        raise GxWslError(f"{target} is neither a directory nor a commit-ish of {repo_root}")
    return SyncTarget(sha, fetch_source(common_dir(repo_root)), f"ref {target}")


def default_source(repo_root: Path = REPO_ROOT) -> str:
    return fetch_source(common_dir(repo_root))


def describe(command: Sequence[str]) -> str:
    script_at = command.index("-c") + 1
    shown = [*command[:script_at], "<script>", *command[script_at + 1 :]]
    return subprocess.list2cmdline(shown)


def execute(distro: str, invocation: Invocation, *, dry_run: bool) -> int:
    command = wsl_command(distro, invocation)
    if dry_run:
        print(f"{TAG} {describe(command)}")
        print(f"{TAG} <script>:")
        print(invocation.script, end="")
        return 0
    wsl = shutil.which(WSL_EXE)
    if wsl is None:
        raise GxWslError("wsl.exe not found: this command drives WSL from a Windows host")
    try:
        code = subprocess.run([wsl, *command[1:]], check=False).returncode
    except KeyboardInterrupt:
        return 130
    except OSError as exc:
        raise GxWslError(f"cannot run wsl.exe: {exc}") from exc
    if code < 0 or code > 255:
        print(f"{TAG} error: wsl.exe failed with exit code {code & 0xFFFFFFFF:#010x} (is distro {distro!r} installed?)", file=sys.stderr)
        return 2
    return code


def shell_instructions(distro: str, clone: str, resolved: str | None) -> list[str]:
    where = resolved or clone
    return [
        f"{TAG} enter the clone:",
        f"  wsl.exe -d {distro} --cd {where}" if where.startswith("/") else f"  wsl.exe -d {distro}, then: cd {where}",
        f"{TAG} inside WSL, put the blueprint-compiler shim first and use the pinned Zig:",
        '  export PATH="$HOME/.local/bin:$PATH"',
        "  python3 scripts/zigw.py build " + " ".join(GTK_BUILD_ARGS),
        '  LD_LIBRARY_PATH="$PWD/zig-out/lib" ./zig-out/bin/ghostty',
        "  python3 scripts/zig_test.py --suite main " + " ".join(MAIN_SUITE_ARGS),
    ]


def shell(distro: str, clone: str, *, dry_run: bool) -> int:
    invocation = Invocation(compose(PRELUDE, SHELL_QUERY), (clone,))
    if dry_run:
        return execute(distro, invocation, dry_run=True)
    resolved = None
    wsl = shutil.which(WSL_EXE)
    if wsl is not None:
        try:
            result = subprocess.run(
                [wsl, *wsl_command(distro, invocation)[1:]],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                stdin=subprocess.DEVNULL,
                timeout=60,
                check=False,
            )
            if result.returncode == 0 and result.stdout.strip().startswith("/"):
                resolved = result.stdout.strip().splitlines()[-1]
        except (OSError, subprocess.SubprocessError):
            pass
    for line in shell_instructions(distro, clone, resolved):
        print(line)
    return 0


def positive_seconds(text: str) -> float:
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {text}") from None
    if not value > 0:
        raise argparse.ArgumentTypeError(f"must be greater than 0: {text}")
    return value


def non_negative_seconds(text: str) -> float:
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {text}") from None
    if not value >= 0:
        raise argparse.ArgumentTypeError(f"must not be negative: {text}")
    return value


def build_parser() -> argparse.ArgumentParser:
    doc = __doc__ or ""
    common = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    common.add_argument("--distro", default=argparse.SUPPRESS, help=f"WSL distribution (default ${DISTRO_ENV} or {DEFAULT_DISTRO})")
    common.add_argument("--clone", default=argparse.SUPPRESS, help=f"Linux path of the clone (default ${CLONE_ENV} or {DEFAULT_CLONE})")
    common.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS, help="print the wsl.exe commands and scripts only")
    parser = argparse.ArgumentParser(
        prog="gx_wsl.py",
        description=doc.splitlines()[0],
        epilog=doc.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        parents=[common],
        allow_abbrev=False,
    )
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    setup = commands.add_parser("setup", parents=[common], allow_abbrev=False, help="clone, pinned Zig, blueprint-compiler, Zig packages")
    setup.add_argument("--check", action="store_true", help="only report what is missing")
    setup.add_argument("--apt", action="store_true", help="first install missing apt packages and locales as root")

    sync = commands.add_parser("sync", parents=[common], allow_abbrev=False, help="check out a Windows ref or worktree in the clone")
    sync.add_argument("target", nargs="?", help="worktree directory or ref (default: this worktree)")
    sync.add_argument("--dirty", action="store_true", help="include the worktree's uncommitted and untracked files")

    build = commands.add_parser("build", parents=[common], allow_abbrev=False, help="zig build in the clone (other arguments pass through)")
    build.add_argument("--gtk", action="store_true", help="add " + " ".join(GTK_BUILD_ARGS))

    test = commands.add_parser("test", parents=[common], allow_abbrev=False, help="scripts/zig_test.py in the clone (other arguments pass through)")
    test.add_argument("--suite", choices=("main", "vt"), default="main", help="test suite (default main)")
    test.add_argument("--gtk", action="store_true", help="main suite with the GTK runtime instead of -Dapp-runtime=none")
    test.add_argument("--filter", action="append", default=[], metavar="TEXT", help="test name substring, repeatable")

    smoke = commands.add_parser("smoke", parents=[common], allow_abbrev=False, help="Xvfb screenshot of zig-out/bin/ghostty")
    smoke.add_argument("--out", required=True, metavar="DIR", help="Windows directory that receives the evidence")
    smoke.add_argument("--lang", choices=sorted(LANGS), help="LANG/LC_ALL/LANGUAGE for Ghostty")
    smoke.add_argument("--xdotool", metavar="FILE", help="xdotool script run after the first screenshot ($1 is the Ghostty PID)")
    smoke.add_argument("--config", metavar="FILE", help="Ghostty config file to use instead of an empty one")
    smoke.add_argument("--wait", type=positive_seconds, default=SMOKE_WAIT_SECONDS, metavar="SECONDS", help="how long to wait for the window to appear (default 20)")
    smoke.add_argument("--settle", type=non_negative_seconds, default=SMOKE_SETTLE_SECONDS, metavar="SECONDS", help="delay between the window appearing and the screenshot (default 3)")
    smoke.add_argument("--name", metavar="PREFIX", help="evidence file prefix (default ghostty-xvfb[-LANG])")
    smoke.add_argument("--env", action="append", default=[], metavar="NAME=VALUE", help="environment variable for Ghostty, repeatable")
    smoke.add_argument("--perf", action="store_true", help="time a seq 1 3000000 workload and report per-thread CPU time")
    smoke.add_argument("ghostty_args", nargs="*", metavar="GHOSTTY_ARG", help="extra Ghostty arguments, after --")

    scenario = commands.add_parser("scenario", parents=[common], allow_abbrev=False,
                                   help="run test/gui/gtk scenarios, one smoke each")
    scenario.add_argument("--out", required=True, metavar="DIR", help="Windows directory; scenario <id> writes DIR/<id>/")
    scenario.add_argument("scenarios", nargs="*", metavar="SCENARIO", help="ids such as G01 or .toml files (default all)")

    run = commands.add_parser("run", parents=[common], allow_abbrev=False, help="start zig-out/bin/ghostty on the WSLg desktop")
    run.add_argument("--lang", choices=sorted(LANGS), help="LANG/LC_ALL/LANGUAGE for Ghostty")
    run.add_argument("--config", metavar="FILE", help="Ghostty config file to use instead of an empty one")
    run.add_argument("--x11", action="store_true", help="GDK_BACKEND=x11 (XWayland) instead of Wayland")
    run.add_argument("ghostty_args", nargs="*", metavar="GHOSTTY_ARG", help="extra Ghostty arguments, after --")

    commands.add_parser("shell", parents=[common], allow_abbrev=False, help="print how to enter the clone")
    return parser


PASSTHROUGH_COMMANDS = ("build", "test")


def parse_args(argv: Sequence[str] | None, environ: Mapping[str, str] | None = None) -> argparse.Namespace:
    environ = os.environ if environ is None else environ
    parser = build_parser()
    args, extra = parser.parse_known_args(argv)
    if extra and args.command not in PASSTHROUGH_COMMANDS:
        parser.error(f"unrecognized arguments: {' '.join(extra)}")
    args.extra = extra
    args.distro = getattr(args, "distro", None) or environ.get(DISTRO_ENV, "").strip() or DEFAULT_DISTRO
    args.clone = getattr(args, "clone", None) or environ.get(CLONE_ENV, "").strip() or DEFAULT_CLONE
    args.dry_run = getattr(args, "dry_run", False)
    return args


def plan(args: argparse.Namespace) -> list[Invocation]:
    clone = check_clone_path(args.clone)
    if args.command == "setup":
        return setup_invocations(clone, default_source(), check=args.check, apt=args.apt)
    if args.command == "sync":
        return [sync_invocation(clone, resolve_sync_target(args.target, dirty=args.dirty, dry_run=args.dry_run))]
    if args.command == "build":
        return [build_invocation(clone, args.gtk, args.extra)]
    if args.command == "test":
        if args.gtk and args.suite != "main":
            raise GxWslError("--gtk only applies to --suite main")
        return [zig_test_invocation(clone, args.suite, args.gtk, args.filter, args.extra)]
    if args.command == "smoke":
        return [
            smoke_invocation(
                clone,
                out=args.out,
                lang=args.lang,
                xdotool=args.xdotool,
                config=args.config,
                wait=args.wait,
                name=args.name,
                ghostty_args=args.ghostty_args,
                settle=args.settle,
                perf=args.perf,
                env=args.env,
            )
        ]
    if args.command == "run":
        return [run_invocation(clone, lang=args.lang, config=args.config, x11=args.x11, ghostty_args=args.ghostty_args)]
    raise GxWslError(f"unknown command {args.command}")


@dataclass(frozen=True)
class GtkScenario:
    """A test/gui/gtk/G*.toml scenario: one `smoke` run plus the log lines it must not have."""

    path: Path
    id: str
    title: str
    config: str
    lang: str | None = None
    xdotool: str = ""
    wait: float = SMOKE_WAIT_SECONDS
    settle: float = SMOKE_SETTLE_SECONDS
    env: tuple[str, ...] = ()
    args: tuple[str, ...] = ()
    expect: tuple[str, ...] = ()
    forbid: tuple[str, ...] = SCENARIO_FORBID


def load_toml(path: Path) -> dict:
    try:
        import tomllib  # type: ignore[import-not-found]
    except ModuleNotFoundError:  # Python 3.10
        try:
            import tomli as tomllib  # type: ignore[import-not-found,no-redef]
        except ModuleNotFoundError:
            raise GxWslError("reading scenarios needs Python 3.11+ (tomllib) or the tomli package") from None
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise GxWslError(f"{path}: {exc}") from None


def load_gtk_scenario(path: Path) -> GtkScenario:
    data = load_toml(path)
    unknown = sorted(data.keys() - GTK_SCENARIO_KEYS)
    if unknown:
        raise GxWslError(f"{path}: unknown keys {', '.join(unknown)}")
    for key in ("id", "title", "config"):
        if not isinstance(data.get(key), str):
            raise GxWslError(f"{path}: {key} must be a string")
    if not GTK_SCENARIO_ID.match(data["id"]) or not path.name.startswith(data["id"] + "-"):
        raise GxWslError(f"{path}: id must look like G01 and start the file name")
    lang = data.get("lang")
    if lang is not None and lang not in LANGS:
        raise GxWslError(f"{path}: lang must be one of {', '.join(sorted(LANGS))}")
    env = data.get("env", {})
    if not isinstance(env, dict) or not all(isinstance(value, str) for value in env.values()):
        raise GxWslError(f"{path}: env must map variable names to strings")
    assignments = tuple(f"{name}={value}" for name, value in env.items())
    env_assignments(assignments)
    forbid = tuple(data.get("forbid", SCENARIO_FORBID))
    for pattern in forbid:
        try:
            re.compile(pattern)
        except re.error as exc:
            raise GxWslError(f"{path}: bad forbid pattern {pattern!r}: {exc}") from None
    return GtkScenario(path, data["id"], data["title"], data["config"], lang, data.get("xdotool", ""),
                       float(data.get("wait", SMOKE_WAIT_SECONDS)), float(data.get("settle", SMOKE_SETTLE_SECONDS)),
                       assignments, tuple(data.get("args", ())), tuple(data.get("expect", ())), forbid)


def gtk_scenario_paths(selectors: Sequence[str], directory: Path = GTK_SCENARIO_DIR) -> list[Path]:
    available = sorted(directory.glob("G*.toml"))
    if not selectors:
        return available
    paths = []
    for selector in selectors:
        if selector.endswith(".toml") and os.path.isfile(selector):
            paths.append(Path(selector))
            continue
        matches = [path for path in available if path.name.startswith(selector + "-")]
        if len(matches) != 1:
            raise GxWslError(f"no single scenario {selector!r} in {directory}")
        paths.extend(matches)
    return paths


def forbidden_lines(log_text: str, patterns: Sequence[str]) -> list[str]:
    regexes = [re.compile(pattern) for pattern in patterns]
    return [line for line in log_text.splitlines() if any(regex.search(line) for regex in regexes)]


def run_gtk_scenarios(args: argparse.Namespace) -> int:
    """`scenario`: each scenario's config and xdotool script go to OUT/<id>/, then one smoke run named <id>."""
    clone = check_clone_path(args.clone)
    scenarios = [load_gtk_scenario(path) for path in gtk_scenario_paths(args.scenarios)]
    out = Path(args.out)
    summary = []
    failed = 0
    for scenario in scenarios:
        target = out / scenario.id
        target.mkdir(parents=True, exist_ok=True)
        config = target / "config.ghostty"
        config.write_text(scenario.config.lstrip("\n"), encoding="utf-8", newline="\n")
        script = None
        if scenario.xdotool.strip():
            script = target / "script.xdo"
            script.write_text(scenario.xdotool.lstrip("\n"), encoding="utf-8", newline="\n")
        invocation = smoke_invocation(
            clone,
            out=str(target),
            lang=scenario.lang,
            xdotool=str(script) if script else None,
            config=str(config),
            wait=scenario.wait,
            name=scenario.id,
            ghostty_args=scenario.args,
            settle=scenario.settle,
            env=scenario.env,
        )
        code = execute(args.distro, invocation, dry_run=args.dry_run)
        if args.dry_run:
            continue
        log = target / f"{scenario.id}.log"
        status = "OK" if code == 0 else f"FAILED (smoke exit {code})"
        if code == 0 and not log.is_file():
            status = "FAILED (no log was copied back)"
        bad = forbidden_lines(log.read_text(encoding="utf-8", errors="replace"), scenario.forbid) if log.is_file() else []
        if bad:
            status = f"FAILED ({len(bad)} forbidden log lines, first: {bad[0].strip()})"
        failed += not status.startswith("OK")
        notes = [f"{scenario.id} {scenario.title}", f"status: {status}", "",
                 "Read every screenshot before recording PASS. Expected:"]
        notes += [f"- {item}" for item in scenario.expect] or ["- (no expectations listed)"]
        (target / "notes.txt").write_text("\n".join(notes) + "\n", encoding="utf-8")
        summary.append(f"{scenario.id} {status} {scenario.title}")
        print(f"{TAG} {summary[-1]}", flush=True)
    if not args.dry_run:
        out.mkdir(parents=True, exist_ok=True)
        text = "\n".join(summary) + "\n\nScreenshots prove nothing until they are read; see <id>/notes.txt.\n"
        (out / "SUMMARY.txt").write_text(text, encoding="utf-8")
    return 1 if failed else 0


def main(argv: Sequence[str] | None = None) -> int:
    utf8_stdio()
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    try:
        if args.command == "shell":
            return shell(args.distro, check_clone_path(args.clone), dry_run=args.dry_run)
        if args.command == "scenario":
            return run_gtk_scenarios(args)
        for invocation in plan(args):
            code = execute(args.distro, invocation, dry_run=args.dry_run)
            if code != 0:
                return code
    except GxWslError as exc:
        print(f"{TAG} error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
