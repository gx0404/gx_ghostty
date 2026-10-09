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
  test [--suite main|vt] [--gtk] [--filter TEXT]... [ZIG_TEST ARGS...]
        python3 scripts/zig_test.py; the main suite (default) gets -Dapp-runtime=none like the
        gx-ci linux-main job, or the GTK runtime flags with --gtk.
  smoke --out DIR [--lang zh_CN|en] [--xdotool FILE] [--config FILE] [--wait SECONDS]
        [--name PREFIX] [-- GHOSTTY ARGS...]
        Start zig-out/bin/ghostty under xvfb-run exactly like the gx-ci gtk-smoke job
        (GDK_BACKEND=x11, LIBGL_ALWAYS_SOFTWARE=1, NO_AT_BRIDGE=1, 1280x800x24,
        --gtk-single-instance=false), screenshot it with scrot after --wait seconds (default
        20), optionally run an xdotool script (the Ghostty PID is its $1) and screenshot again,
        then copy PNGs, log, version and metadata to the Windows directory DIR.
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

BUILD_BODY = r"""enter_clone
prefetch || warn "some Zig packages could not be prefetched; zig build will try to fetch them itself"
log "python3 scripts/zigw.py build $*"
exec python3 scripts/zigw.py build "$@"
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

SMOKE_BODY = r"""out_win=$1
lang=$2
language=$3
xdotool_win=$4
config_win=$5
wait_seconds=$6
name=$7
screen=$8
shift 8
enter_clone
require_ghostty
for tool in xvfb-run xauth scrot; do
  command -v "$tool" >/dev/null || die "$tool is not installed; run: python scripts/gx_wsl.py setup --apt" 2
done
if [ -n "$xdotool_win" ]; then
  command -v xdotool >/dev/null || die "xdotool is not installed; run: python scripts/gx_wsl.py setup --apt" 2
fi
out=$(wslpath -u "$out_win")
work=$(mktemp -d "${TMPDIR:-/tmp}/gx-wsl-smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT
evidence=$work/evidence
mkdir -p "$evidence"
xdo=
if [ -n "$xdotool_win" ]; then
  xdo=$work/script.xdo
  sed 's/\r$//' "$(wslpath -u "$xdotool_win")" >"$xdo"
fi
prepare_config "$work" "$config_win"
apply_lang "$lang" "$language"
export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1
export LD_LIBRARY_PATH=$clone/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
unset WAYLAND_DISPLAY
env -u DISPLAY ./zig-out/bin/ghostty +version >"$evidence/$name-version.txt" 2>&1
session=$(cat <<'GX_WSL_SESSION'
evidence=$1
name=$2
wait_seconds=$3
xdo=$4
shift 4
alive() {
  local state
  state=$(awk '/^State:/ {print $2}' "/proc/$1/status" 2>/dev/null || true)
  [ -n "$state" ] && [ "$state" != Z ]
}
./zig-out/bin/ghostty --gtk-single-instance=false "$@" >"$evidence/$name.log" 2>&1 &
pid=$!
sleep "$wait_seconds"
if ! alive "$pid"; then
  wait "$pid" || true
  printf '[gx-wsl] error: ghostty exited before the screenshot; see %s.log\n' "$name" >&2
  exit 1
fi
scrot "$evidence/$name.png"
status=0
if [ -n "$xdo" ]; then
  xdotool "$xdo" "$pid" || status=$?
  sleep 1
  scrot "$evidence/$name-after.png"
fi
kill "$pid" 2>/dev/null || true
wait "$pid" || true
if [ "$status" -ne 0 ]; then
  printf '[gx-wsl] error: the xdotool script exited with %s\n' "$status" >&2
  exit 1
fi
test -s "$evidence/$name.png"
GX_WSL_SESSION
)
started=$(date +%s)
status=0
xvfb-run --auto-servernum --server-args="-screen 0 $screen" bash -euo pipefail -c "$session" smoke \
  "$evidence" "$name" "$wait_seconds" "$xdo" "$@" || status=$?
extra_args=
if [ $# -gt 0 ]; then
  extra_args=$(printf ' %q' "$@")
fi
{
  printf 'commit: %s\n' "$(git log -1 --format='%H %s')"
  printf 'started: %s\n' "$(date -u -d "@$started" +%Y-%m-%dT%H:%M:%SZ)"
  printf 'seconds: %s\n' "$(($(date +%s) - started))"
  printf 'exit: %s\n' "$status"
  printf 'display: xvfb-run -screen 0 %s, GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1\n' "$screen"
  printf 'wait: %ss\n' "$wait_seconds"
  printf 'lang: %s\n' "${lang:-inherited (${LANG:-unset})}"
  printf 'config: %s\n' "${config_win:-none}"
  printf 'xdotool: %s\n' "${xdotool_win:-none}"
  printf 'ghostty args: --gtk-single-instance=false%s\n' "$extra_args"
} >"$evidence/$name-meta.txt"
mkdir -p "$out"
cp -f "$evidence"/* "$out"/
for file in "$evidence"/*; do
  log "evidence: $(wslpath -w "$out/${file##*/}")"
done
if [ "$status" -eq 0 ]; then log "smoke passed"; else warn "smoke failed with exit $status"; fi
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
    return Invocation(compose(PRELUDE, prefetch_function(), BUILD_BODY), (clone, *build_args(gtk, extra)))


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
        *ghostty_args,
    )
    return Invocation(compose(PRELUDE, GHOSTTY_HELPERS, SMOKE_BODY), args)


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
    smoke.add_argument("--wait", type=positive_seconds, default=SMOKE_WAIT_SECONDS, metavar="SECONDS", help="delay before the screenshot (default 20)")
    smoke.add_argument("--name", metavar="PREFIX", help="evidence file prefix (default ghostty-xvfb[-LANG])")
    smoke.add_argument("ghostty_args", nargs="*", metavar="GHOSTTY_ARG", help="extra Ghostty arguments, after --")

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
            )
        ]
    if args.command == "run":
        return [run_invocation(clone, lang=args.lang, config=args.config, x11=args.x11, ghostty_args=args.ghostty_args)]
    raise GxWslError(f"unknown command {args.command}")


def main(argv: Sequence[str] | None = None) -> int:
    utf8_stdio()
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    try:
        if args.command == "shell":
            return shell(args.distro, check_clone_path(args.clone), dry_run=args.dry_run)
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
