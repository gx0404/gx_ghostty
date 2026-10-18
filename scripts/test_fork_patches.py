"""Lock tests for the fork patch registry in docs/FORK_PATCHES.md.

The registry table is the closed set of ``fork(gx)`` markers in upstream
source (src/, include/, pkg/, macos/ and build.zig), whatever the comment
syntax (``//`` or ``/* */``, e.g. in GTK CSS). Pure additions are
wrapped in ``fork(gx): GX-NNNN begin`` / ``fork(gx): GX-NNNN end`` comment
lines, so dropping those hunks must give back the merged upstream file.
Run from the repo root:

    python -m unittest scripts.test_fork_patches -v
"""
from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = "docs/FORK_PATCHES.md"
SCAN_PATHSPECS = ("src", "include", "pkg", "macos", "build.zig")
TABLE_BEGIN = "<!-- fork-patches:begin -->"
TABLE_END = "<!-- fork-patches:end -->"
HEADER = ("ID", "文件", "标记", "状态")
STATUSES = ("active", "removed")
ID_RE = re.compile(r"GX-\d{4}")
MARKER_RE = re.compile(rb"fork\(gx\)(?::[ \t]*(GX-\d{4})(?![0-9]))?")
SECTION_RE = re.compile(r"^##[ \t]+(GX-\d{4})(?![0-9])", re.M)
HUNK_BEGIN_RE = re.compile(r"^[ \t]*// fork\(gx\): (GX-\d{4}) begin(?::.*)?$")
HUNK_END_RE = re.compile(r"^[ \t]*// fork\(gx\): (GX-\d{4}) end$")
UPSTREAM_REFS = ("main", "origin/main", "upstream/main")

# The marked notice block at the top of the upstream README.md (not a source patch).
README_NOTICE_BEGIN = "<!-- gx-fork:"
README_NOTICE_END = "<!-- /gx-fork -->"
README_NOTICES = (
    "Ghostty GX is an unofficial fork of Ghostty maintained by [gx0404](https://github.com/gx0404). "
    "It is not affiliated with or endorsed by the Ghostty project.",
    "Ghostty GX 是 Ghostty 的非官方分支，由 gx0404 维护，与 Ghostty 团队无关，未获其认可或背书。",
)

GHOSTTY_EXE_ZIG = "src/build/GhosttyExe.zig"
GX0026_RC = 'b.path("dist/windows/gx/ghostty-gx.rc")'

CONFIG_ZIG = "src/build/Config.zig"
GX0001_MARKER = "fork(gx): GX-0001"
GX0001_GUARD_CALL = 'std.mem.startsWith(u8, tag, "v")'
GX0001_GUARD_RE = re.compile(
    r'^[ ]*if \(!std\.mem\.eql\(u8, tag, "tip"\) and '
    r'std\.mem\.startsWith\(u8, tag, "v"\)\) \{$'
)
UPSTREAM_TAG_BRANCH = "if (vsn.tag) |tag| {"
UPSTREAM_TIP_GUARD = 'if (!std.mem.eql(u8, tag, "tip")) {'
UPSTREAM_EXPECTED = 'const expected = b.fmt("v{d}.{d}.{d}", .{'
UPSTREAM_PANIC = '@panic("tagged releases must be in vX.Y.Z format matching build.zig");'
UPSTREAM_FALLBACK = ".pre = vsn.branch,"

BUILD_ZIG = "build.zig"
GX0002 = "GX-0002"
GX0002_MARKER = f"fork(gx): {GX0002}"
# (hunk, line prefix it must follow, line prefix it must precede, statements).
# Statements are compared with squash(), so formatting does not matter.
GX0002_HUNKS = (
    ("step declarations",
     "const test_lib_vt_build_step = b.step(",
     "const resources = try buildpkg.GhosttyResources.init(", (
         'const test_bin_step = b.step("test-bin",',
         'const test_lib_vt_bin_step = b.step("test-lib-vt-bin",',
         "if (config.emit_lib_vt) test_bin_step.dependOn(&b.addFail(",
     )),
    ("libghostty-vt installs",
     "const mod_vt_c_test = b.addTest(.{",
     "// Tests (skip when building libghostty-vt)", (
         "test_lib_vt_bin_step.dependOn(&b.addInstallArtifact(mod_vt_test, .{"
         ' .dest_dir = .{ .override = .{ .custom = "test/vt" } } }).step);',
         "test_lib_vt_bin_step.dependOn(&b.addInstallArtifact(mod_vt_c_test, .{"
         ' .dest_dir = .{ .override = .{ .custom = "test/vt_c" } } }).step);',
     )),
    ("ghostty-test install",
     "const test_exe = b.addTest(.{",
     "test_valgrind_step.dependOn(&valgrind_run.step);", (
         "const test_exe_bin_install = b.addInstallArtifact(test_exe, .{"
         ' .dest_dir = .{ .override = .{ .custom = "test" } } });',
         "config.addPatchElf(test_exe, &test_exe_bin_install.step);",
         "test_bin_step.dependOn(&test_exe_bin_install.step);",
     )),
)

CLOSE_DIALOG_ZIG = "src/apprt/gtk/class/close_confirmation_dialog.zig"
GX0027 = "GX-0027"
GX0027_CALL = '@import("../gx/confirm.zig").listProcesses(self, priv.target, parent);'
GX0027_AFTER = "self.as(Dialog.Parent).setBody(priv.target.body());"
GX0027_BEFORE = "self.as(Dialog).present(parent);"

APPLICATION_ZIG = "src/apprt/gtk/class/application.zig"
GX0028 = "GX-0028"

OPENGL_ZIG = "src/renderer/OpenGL.zig"
GX0029 = "GX-0029"
GX0029_FIELD = 'gx_dmabuf: @import("../gx/dmabuf_export.zig").Export(gl) = .{},'
GX0029_CONDITION = "if (presentation_health == .healthy and self.gx_dmabuf.enabled(self.device.display)) {"
GX0029_EXPORT = "if (self.gx_dmabuf.track(target.exportDmabuf(self.device.display, self.egl_context))) |dmabuf| {"
UPSTREAM_DMABUF_WARNING = "failed to export DMABUF, falling back to CPU presentation"

GTK_CSS = "src/apprt/gtk/css/style.css"
CSS_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
CSS_GRADIENT_RE = re.compile(r"\b(?:repeating-)?(?:linear|radial|conic)-gradient\(")
CSS_RGB_HSL_RE = re.compile(r"\b(?:rgba?|hsla?)\(")
CSS_GTK416_RE = re.compile(r"\b(?:color-mix|color|hwb|lab|lch|oklab|oklch|var)\(")
CSS_CUSTOM_PROPERTY_RE = re.compile(r"(?<![\w-])--[A-Za-z_][\w-]*\s*:")
CSS_ROOT_RE = re.compile(r":root\b")
CSS_DIMENSION_RE = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:%|[a-z]+)?")

# The Ghostty GX stylesheets of the GTK app (not upstream patches, held to the same GTK 4.14
# floor): every static *.css below GX_CSS_DIR, and the CSS that GX_CSS_GENERATORS write at
# runtime. Only Zig functions whose name ends in `416` (like upstream's
# `Application.loadRuntimeCss416`) may write CSS that needs GTK 4.16; their callers check the
# runtime GTK version.
GX_CSS_DIR = "src/apprt/gtk/gx"
GX_CSS_GENERATORS = ("src/gx/gtk_css.zig", "src/apprt/gtk/gx/style.zig")
ZIG_FN_RE = re.compile(r"^(?:pub\s+)?(?:inline\s+)?fn\s+([A-Za-z_]\w*)\s*\(", re.M)
ZIG_TEST_RE = re.compile(r"^test\b", re.M)
ZIG_STRING_RE = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
ZIG_CHAR_RE = re.compile(r"'(?:[^'\\\n]|\\.)*'")
ZIG_FORMAT_ESCAPE_RE = re.compile(r"\{\{|\}\}")
ZIG_PLACEHOLDER_RE = re.compile(r"\{[^{}\s]*\}")


@dataclass(frozen=True)
class Patch:
    id: str
    path: str
    marker: str
    status: str


def _row_cells(line: str) -> list[str]:
    stripped = line.strip()
    if len(stripped) < 2 or not (stripped.startswith("|") and stripped.endswith("|")):
        raise ValueError(f"not a table row: {line!r}")
    return [cell.strip() for cell in stripped[1:-1].split("|")]


def _unquote(cell: str) -> str:
    if len(cell) >= 2 and cell.startswith("`") and cell.endswith("`"):
        return cell[1:-1]
    return cell


def parse_registry(text: str) -> list[Patch]:
    """Parse the table between the fork-patches begin/end comments."""
    lines = text.splitlines()
    begins = [i for i, line in enumerate(lines) if line.strip() == TABLE_BEGIN]
    ends = [i for i, line in enumerate(lines) if line.strip() == TABLE_END]
    if len(begins) != 1 or len(ends) != 1 or begins[0] > ends[0]:
        raise ValueError("registry needs exactly one begin/end comment pair, in order")
    rows = [line for line in lines[begins[0] + 1 : ends[0]] if line.strip()]
    if len(rows) < 2:
        raise ValueError("registry table needs a header row and a separator row")
    if tuple(_row_cells(rows[0])) != HEADER:
        raise ValueError(f"registry header must be: {' | '.join(HEADER)}")
    separator = _row_cells(rows[1])
    if len(separator) != len(HEADER) or not all(re.fullmatch(r":?-{3,}:?", c) for c in separator):
        raise ValueError("registry separator row is malformed")

    patches: list[Patch] = []
    seen: set[tuple[str, str]] = set()
    for row in rows[2:]:
        cells = _row_cells(row)
        if len(cells) != len(HEADER):
            raise ValueError(f"registry row needs {len(HEADER)} cells: {row!r}")
        patch = Patch(*(_unquote(cell) for cell in cells))
        if not ID_RE.fullmatch(patch.id):
            raise ValueError(f"bad patch id {patch.id!r}")
        parts = patch.path.split("/")
        if (not patch.path or patch.path.startswith("/") or "\\" in patch.path
                or ":" in patch.path or any(p in ("", ".", "..") for p in parts)):
            raise ValueError(f"{patch.id}: file must be a repo-relative POSIX path, got {patch.path!r}")
        if patch.marker != f"fork(gx): {patch.id}":
            raise ValueError(f"{patch.id}: marker must be 'fork(gx): {patch.id}', got {patch.marker!r}")
        if patch.status not in STATUSES:
            raise ValueError(f"{patch.id}: status must be one of {', '.join(STATUSES)}, got {patch.status!r}")
        key = (patch.id, patch.path)
        if key in seen:
            raise ValueError(f"duplicate registry row: {patch.id} {patch.path}")
        seen.add(key)
        patches.append(patch)
    return patches


def git_visible_files(root: Path, pathspecs) -> list[str]:
    """Tracked plus untracked-but-not-ignored files under the pathspecs."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others",
         "--exclude-standard", "--", *pathspecs],
        capture_output=True, check=True,
    )
    return sorted({path for path in result.stdout.decode("utf-8").split("\0") if path})


def find_markers(root: Path, files) -> list[tuple[str, int, str | None]]:
    """Return (path, line, id-or-None) for every fork(gx) occurrence."""
    found: list[tuple[str, int, str | None]] = []
    for rel in files:
        path = root / rel
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"fork(gx)" not in data:
            continue
        for lineno, line in enumerate(data.splitlines(), 1):
            for match in MARKER_RE.finditer(line):
                pid = match.group(1)
                found.append((rel, lineno, pid.decode("ascii") if pid else None))
    return found


def hunk_problems(rel: str, text: str) -> list[str]:
    """Report nested, unclosed or stray begin/end hunk delimiters in one file."""
    problems: list[str] = []
    open_hunk: tuple[str, int] | None = None
    for lineno, line in enumerate(text.splitlines(), 1):
        opened, closed = HUNK_BEGIN_RE.match(line), HUNK_END_RE.match(line)
        if opened:
            if open_hunk is not None:
                problems.append(f"{rel}:{lineno}: {opened.group(1)} begin inside the "
                                f"{open_hunk[0]} hunk opened on line {open_hunk[1]}")
            open_hunk = (opened.group(1), lineno)
        elif closed:
            if open_hunk is None or open_hunk[0] != closed.group(1):
                problems.append(f"{rel}:{lineno}: {closed.group(1)} end without a matching begin")
            else:
                open_hunk = None
    if open_hunk is not None:
        problems.append(f"{rel}:{open_hunk[1]}: {open_hunk[0]} begin is never closed")
    return problems


def marked_hunks(source: str, pid: str) -> tuple[str, list[tuple[int, int]]]:
    """Strip the begin/end-delimited hunks of patch ``pid`` from ``source``.

    Returns the remaining text (original line endings kept) and the 0-based
    line indexes of each hunk's begin and end delimiter. Raises ValueError
    for nested, unclosed or stray delimiters and for a ``pid`` marker that
    sits outside a hunk.
    """
    marker = re.compile(rf"fork\(gx\):[ \t]*{re.escape(pid)}(?![0-9])")
    kept: list[str] = []
    hunks: list[tuple[int, int]] = []
    begin: int | None = None
    for index, line in enumerate(source.splitlines(keepends=True)):
        text = line.rstrip("\r\n")
        opened, closed = HUNK_BEGIN_RE.match(text), HUNK_END_RE.match(text)
        if opened and opened.group(1) == pid:
            if begin is not None:
                raise ValueError(f"line {index + 1}: {pid} begin inside the hunk opened on line {begin + 1}")
            begin = index
        elif closed and closed.group(1) == pid:
            if begin is None:
                raise ValueError(f"line {index + 1}: {pid} end without a begin")
            hunks.append((begin, index))
            begin = None
        elif begin is None:
            if marker.search(text):
                raise ValueError(f"line {index + 1}: {pid} marker outside a begin/end hunk")
            kept.append(line)
    if begin is not None:
        raise ValueError(f"line {begin + 1}: {pid} begin is never closed")
    return "".join(kept), hunks


def squash(code: str) -> str:
    """Drop comment lines, whitespace and trailing commas so formatting is irrelevant."""
    body = "".join(line for line in code.splitlines() if not line.lstrip().startswith("//"))
    return re.sub(r",(?=[)}\]])", "", re.sub(r"\s+", "", body))


def merged_upstream_text(root: Path, rel: str) -> tuple[str | None, str]:
    """Return ``rel`` at the merge base of HEAD and the upstream mirror.

    The text is LF-normalised; on failure the first item is None and the
    second explains why (used as a skip reason).
    """
    for ref in UPSTREAM_REFS:
        base = subprocess.run(["git", "-C", str(root), "merge-base", "HEAD", ref],
                              capture_output=True)
        if base.returncode == 0:
            break
    else:
        return None, "no upstream mirror branch (main) available to compare against"
    commit = base.stdout.decode("ascii").strip()
    shown = subprocess.run(["git", "-C", str(root), "show", f"{commit}:{rel}"],
                           capture_output=True)
    if shown.returncode != 0:
        return None, f"{rel} is not readable at merge base {commit}"
    upstream = shown.stdout.decode("utf-8").replace("\r\n", "\n")
    if "fork(gx)" in upstream:
        return None, "merge base already contains fork patches"
    return upstream, ""


def check(root: Path, files: list[str] | None = None) -> list[str]:
    """Return every registry/marker violation; an empty list means clean.

    ``files`` defaults to the Git-visible files in the scan scope plus the
    registered files; tests pass an explicit list for temp-dir fixtures.
    """
    registry_path = root / REGISTRY
    if not registry_path.is_file():
        return [f"{REGISTRY} is missing"]
    text = registry_path.read_text(encoding="utf-8")
    try:
        patches = parse_registry(text)
    except ValueError as err:
        return [f"{REGISTRY}: {err}"]

    problems: list[str] = []
    sections = set(SECTION_RE.findall(text))
    for pid in sorted({patch.id for patch in patches} - sections):
        problems.append(f"{REGISTRY}: {pid} has no '## {pid}' section")

    registered = [patch.path for patch in patches]
    if files is None:
        files = git_visible_files(root, list(dict.fromkeys([*SCAN_PATHSPECS, *registered])))
    found = find_markers(root, sorted(set(files) | set(registered)))
    present = {(pid, rel) for rel, _, pid in found if pid}
    active = {(patch.id, patch.path) for patch in patches if patch.status == "active"}

    for patch in patches:
        if patch.status == "active":
            if not (root / patch.path).is_file():
                problems.append(f"{patch.id}: registered file {patch.path} does not exist")
            elif (patch.id, patch.path) not in present:
                problems.append(f"{patch.id}: marker '{patch.marker}' is missing from {patch.path}")
        elif (patch.id, patch.path) in present:
            problems.append(f"{patch.id}: removed patch still has its marker in {patch.path}")
    for rel, lineno, pid in found:
        if pid is None:
            problems.append(f"{rel}:{lineno}: malformed marker, expected 'fork(gx): GX-NNNN'")
        elif (pid, rel) not in active:
            problems.append(f"{rel}:{lineno}: {pid} is not registered as active for this file in {REGISTRY}")
    for rel in sorted({rel for rel, _, _ in found}):
        problems.extend(hunk_problems(rel, (root / rel).read_bytes().decode("utf-8", "replace")))
    return problems


def gx0001_problems(source: str) -> list[str]:
    """Shape lock for GX-0001 in src/build/Config.zig."""
    lines = source.splitlines()
    guards = [i for i, line in enumerate(lines) if GX0001_GUARD_CALL in line]
    if len(guards) != 1:
        return [f"expected exactly one line with {GX0001_GUARD_CALL}, found {len(guards)}"]
    guard = guards[0]
    problems: list[str] = []
    if not GX0001_GUARD_RE.match(lines[guard]):
        problems.append(f"guard must combine the tip check and the 'v' prefix check: {lines[guard].strip()!r}")
    if not any(GX0001_MARKER in line for line in lines[max(0, guard - 3):guard]):
        problems.append(f"'{GX0001_MARKER}' comment must sit within 3 lines above the guard")
    if any(line.strip() == UPSTREAM_TIP_GUARD for line in lines):
        problems.append("the unpatched upstream tip-only guard is still present")

    def single(needle: str) -> int | None:
        hits = [i for i, line in enumerate(lines) if line.strip() == needle]
        if len(hits) != 1:
            problems.append(f"expected exactly one line {needle!r}, found {len(hits)}")
            return None
        return hits[0]

    branch = single(UPSTREAM_TAG_BRANCH)
    expected = single(UPSTREAM_EXPECTED)
    panic = single(UPSTREAM_PANIC)
    fallback = single(UPSTREAM_FALLBACK)
    if branch is not None and not branch < guard:
        problems.append("guard must sit inside `if (vsn.tag) |tag|`")
    if expected is not None and panic is not None and not guard < expected < panic:
        problems.append("upstream vX.Y.Z comparison and panic must stay behind the guard")
    if panic is not None and fallback is not None and not panic < fallback:
        problems.append("branch pre-release fallback must follow the tagged-release block")
    return problems


def gx0002_problems(source: str) -> list[str]:
    """Shape lock for GX-0002 in build.zig: three pure-addition hunks."""
    try:
        upstream, hunks = marked_hunks(source, GX0002)
    except ValueError as err:
        return [str(err)]
    problems: list[str] = []
    if "fork(gx)" in upstream:
        problems.append("build.zig carries fork(gx) markers outside the GX-0002 hunks")
    if len(hunks) != len(GX0002_HUNKS):
        problems.append(f"expected {len(GX0002_HUNKS)} {GX0002} hunks, found {len(hunks)}")
    lines = source.splitlines()
    bodies = [squash("\n".join(lines[begin + 1:end])) for begin, end in hunks]
    outside = squash(upstream)

    def anchor(prefix: str) -> int | None:
        hits = [i for i, line in enumerate(lines) if line.strip().startswith(prefix)]
        if len(hits) != 1:
            problems.append(f"expected exactly one line starting with {prefix!r}, found {len(hits)}")
            return None
        return hits[0]

    for name, after, before, statements in GX0002_HUNKS:
        low, high = anchor(after), anchor(before)
        for statement in statements:
            owners = [i for i, body in enumerate(bodies) if squash(statement) in body]
            if len(owners) != 1 or squash(statement) in outside:
                problems.append(f"{name}: {statement!r} must appear in exactly one {GX0002} hunk "
                                f"and nowhere else (found in {len(owners)} hunks)")
                continue
            begin, end = hunks[owners[0]]
            if low is not None and high is not None and not low < begin < end < high:
                problems.append(f"{name}: the hunk on lines {begin + 1}-{end + 1} must sit "
                                f"between {after!r} and {before!r}")
    return problems


def zig_fn_lines(lines: list[str], header: str) -> tuple[int, int] | None:
    """0-based [start, end) lines of the one function whose first line starts with ``header``
    (after indentation), up to its closing brace at the same indentation; None otherwise."""
    starts = [i for i, line in enumerate(lines) if line.strip().startswith(header)]
    if len(starts) != 1:
        return None
    start = starts[0]
    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
    end = next((i for i in range(start + 1, len(lines)) if lines[i] == f"{indent}}}"), None)
    return None if end is None else (start, end + 1)


def gx0027_problems(source: str) -> list[str]:
    """Shape lock for GX-0027: one pure-addition hunk in CloseConfirmationDialog.present."""
    try:
        upstream, hunks = marked_hunks(source, GX0027)
    except ValueError as err:
        return [str(err)]
    problems: list[str] = []
    if "fork(gx)" in upstream:
        problems.append(f"{CLOSE_DIALOG_ZIG} carries fork(gx) markers outside the {GX0027} hunk")
    if len(hunks) != 1:
        return [*problems, f"expected one {GX0027} hunk, found {len(hunks)}"]
    lines = source.splitlines()
    begin, end = hunks[0]
    if squash(GX0027_CALL) not in squash("\n".join(lines[begin + 1:end])):
        problems.append(f"the {GX0027} hunk must call {GX0027_CALL!r}")
    after = [i for i, line in enumerate(lines) if line.strip() == GX0027_AFTER]
    before = [i for i, line in enumerate(lines) if line.strip() == GX0027_BEFORE]
    if len(after) != 1 or len(before) != 1 or not after[0] < begin < end < before[0]:
        problems.append(f"the {GX0027} hunk must sit between {GX0027_AFTER!r} and {GX0027_BEFORE!r}")
    return problems


def gx0028_problems(source: str) -> list[str]:
    """Shape lock for GX-0028 in class/application.zig: the configuration errors dialog shows
    each set of diagnostics once, and only its own reload button shows remaining errors again."""
    lines = source.replace("\r\n", "\n").split("\n")
    show = zig_fn_lines(lines, "fn showConfigErrorsDialog(")
    reload = zig_fn_lines(lines, "fn handleReloadConfig(")
    if show is None or reload is None:
        return ["showConfigErrorsDialog and handleReloadConfig must each be defined once"]
    problems: list[str] = []
    show_body = [line.strip() for line in lines[show[0]:show[1]]]
    reload_body = [line.strip() for line in lines[reload[0]:reload[1]]]

    def single(body: list[str], name: str, needle: str) -> int | None:
        hits = [i for i, line in enumerate(body) if line == needle]
        if len(hits) != 1:
            problems.append(f"{name}: expected exactly one line {needle!r}, found {len(hits)}")
            return None
        return hits[0]

    name = "showConfigErrorsDialog"
    update = single(show_body, name, "const gx_new_errors = priv.gx_config_errors.update(priv.config.get());")
    existing = single(show_body, name, "if (priv.config_errors_dialog.get()) |diag| {")
    present = single(show_body, name, "if (gx_new_errors) diag.present(null);")
    no_diagnostics = single(show_body, name, "if (!priv.config.hasDiagnostics()) return;")
    reported = single(show_body, name, "if (!gx_new_errors) return;")
    create = single(show_body, name, "const dialog: *ConfigErrorsDialog = .new(priv.config);")
    if "diag.present(null);" in show_body:
        problems.append(f"{name}: the open dialog is presented without checking gx_new_errors")
    if None not in (update, existing) and not update < existing:
        problems.append(f"{name}: gx_config_errors.update must run before the open dialog is handled")
    if present is not None and GX0028 not in show_body[present - 1]:
        problems.append(f"{name}: the changed present line needs a fork(gx): {GX0028} comment above it")
    if None not in (no_diagnostics, reported, create) and not no_diagnostics < reported < create:
        problems.append(f"{name}: diagnostics reported before must return before a new dialog is created")

    forget = single(reload_body, "handleReloadConfig", "priv.gx_config_errors.forget();")
    call = next((i for i, line in enumerate(reload_body) if line.startswith("Action.reloadConfig(")), None)
    if forget is not None and (call is None or not forget < call):
        problems.append("handleReloadConfig: forget() must run before Action.reloadConfig")
    if sum("gx_config_errors.forget()" in line for line in lines) != 1:
        problems.append("only the reload button of the configuration errors dialog may forget reported diagnostics")

    window = zig_fn_lines(lines, "fn initAndShowWindow(")
    shown_in = zig_fn_lines(lines, "fn gxShowConfigErrorsIn(")
    if window is None or shown_in is None:
        return [*problems, "initAndShowWindow and gxShowConfigErrorsIn must each be defined once"]
    window_body = [line.strip() for line in lines[window[0]:window[1]]]
    name = "initAndShowWindow"
    shown = single(window_body, name, "gtk.Window.present(win.as(gtk.Window));")
    hook = single(window_body, name, "if (self.private().gx_config_errors.windowShown()) self.gxShowConfigErrorsIn(win);")
    if None not in (shown, hook) and not shown < hook:
        problems.append(f"{name}: the errors of the startup must be shown after the window is")
    if "dialog.present(win.as(gtk.Widget));" not in (line.strip() for line in lines[shown_in[0]:shown_in[1]]):
        problems.append("gxShowConfigErrorsIn: the dialog must be presented in the window")
    return problems


def gx0029_problems(source: str) -> list[str]:
    """Shape lock for GX-0029 in src/renderer/OpenGL.zig: present() stops exporting DMABUFs
    once that cannot work, after the Windows (GX-0004) branch has returned."""
    lines = source.replace("\r\n", "\n").split("\n")
    problems: list[str] = []

    def marked(needle: str) -> int | None:
        hits = [i for i, line in enumerate(lines) if line.strip() == needle]
        if len(hits) != 1:
            problems.append(f"expected exactly one line {needle!r}, found {len(hits)}")
            return None
        if GX0029 not in lines[hits[0] - 1]:
            problems.append(f"{needle!r} needs a fork(gx): {GX0029} comment on the line above")
        return hits[0]

    marked(GX0029_FIELD)
    condition = marked(GX0029_CONDITION)
    export = marked(GX0029_EXPORT)
    if UPSTREAM_DMABUF_WARNING in source:
        problems.append("present() must not warn for every frame whose export fails")
    present = zig_fn_lines(lines, "pub fn present(")
    if present is None:
        return [*problems, "expected one top-level `pub fn present(`"]
    start, end = present
    if any(at is not None and not start < at < end for at in (condition, export)):
        problems.append("the DMABUF export must stay in present()")
    if None not in (condition, export) and not condition < export:
        problems.append("the DMABUF export must be inside the GX-0029 condition")
    windows = next((i for i in range(start, end) if "builtin.os.tag == .windows" in lines[i]), None)
    if windows is None or (condition is not None and not windows < condition):
        problems.append("the Windows (GX-0004) branch of present() must return before the DMABUF export")
    return problems


CORE_SURFACE_ZIG = "src/Surface.zig"
GX0044 = "GX-0044"
GX0044_MARKER_RE = re.compile(r"fork\(gx\):[ \t]*GX-0044(?![0-9])")
# Every identifier that the GX-0044 hook adds to the core Surface.
GX0044_NAMES = ("gx_binding_route", "gx_binding_bypass", "gx_table_generation", "gx_generation",
                "gx_once", "GxOnceTable", "gxPopOnceTable", "gxCompleteBinding", "gxBeginBinding",
                "gxCancelBinding", "gxCompleteClipboard")
GX0044_ROUTE_FIELD = "gx_binding_route: ?struct {"
GX0044_ROUTE_GATE = "if (self.gx_binding_route) |route|"
# Upstream behavior kept when no route is installed: the immediate one-shot table pop
# and clearing the selection right after a copy.
GX0044_LOCAL_PATHS = 2


def gx0044_problems(source: str) -> list[str]:
    """Shape lock for GX-0044 in src/Surface.zig: the remote binding route is optional
    (null by default), its callbacks run only behind that gate, the upstream paths stay
    when it is absent, and every code line using GX-0044 state is inside a GX-0044 hunk
    or directly below a GX-0044 marker line."""
    lines = source.replace("\r\n", "\n").split("\n")
    problems: list[str] = []
    inside = False
    for index, line in enumerate(lines):
        opened, closed = HUNK_BEGIN_RE.match(line), HUNK_END_RE.match(line)
        if opened and opened.group(1) == GX0044:
            inside = True
            continue
        if closed and closed.group(1) == GX0044:
            inside = False
            continue
        if inside or line.lstrip().startswith("//"):
            continue
        if any(name in line for name in GX0044_NAMES) and not (
                index and GX0044_MARKER_RE.search(lines[index - 1])):
            problems.append(f"line {index + 1}: GX-0044 state outside a hunk needs a "
                            f"fork(gx): {GX0044} line above")
    fields = [i for i, line in enumerate(lines) if line.strip() == GX0044_ROUTE_FIELD]
    if len(fields) != 1:
        problems.append(f"expected one {GX0044_ROUTE_FIELD!r} field, found {len(fields)}")
    else:
        close = next((i for i in range(fields[0] + 1, min(fields[0] + 8, len(lines)))
                      if lines[i].startswith("}")), None)
        if close is None or lines[close].strip() != "} = null,":
            problems.append("gx_binding_route must default to null")
    for call in ("route.callback(", "route.config_changed("):
        hits = [i for i, line in enumerate(lines) if call in line]
        if len(hits) != 1:
            problems.append(f"expected one {call!r}, found {len(hits)}")
        elif not any(GX0044_ROUTE_GATE in lines[i] for i in range(max(0, hits[0] - 1), hits[0] + 1)):
            problems.append(f"{call!r} must run only inside `{GX0044_ROUTE_GATE}`")
    local = sum("self.gx_binding_route == null" in line for line in lines)
    if local != GX0044_LOCAL_PATHS:
        problems.append(f"expected {GX0044_LOCAL_PATHS} upstream paths gated on a missing route, "
                        f"found {local}")
    return problems


GX0043 = "GX-0043"
WIN32_SURFACE_ZIG = "src/apprt/win32/Surface.zig"


def gx0043_readback_problems(wgl: str, surface: str) -> list[str]:
    """The GX-0043 readback timing: one end stamp after the successful error check of the
    remote ReadPixels and before success, and the remote frame logs only after unlocking."""
    lines = wgl.splitlines()
    try:
        _, hunks = marked_hunks(wgl, GX0043)
    except ValueError as err:
        return [str(err)]
    inside = [i for begin, end in hunks for i in range(begin, end)]
    stamps = [i for i in inside if lines[i].strip() == "remote.frame.readbackComplete();"]
    if len(wgl.split("readbackComplete(")) != 2 or len(stamps) != 1:
        return ["expected exactly one remote.frame.readbackComplete() inside the GX-0043 hunk"]
    stamp = stamps[0]
    problems: list[str] = []
    if not (lines[stamp - 1].strip() == "try gl.errors.getError();"
            and "remote.frame.pixels().ptr" in lines[stamp - 2]
            and lines[stamp + 1].strip() == "success = true;"):
        problems.append("readbackComplete must follow the remote ReadPixels error check and precede success")
    finish = surface[surface.index("pub const RemoteFrame = struct"):]
    finish = finish[finish.index("pub fn finish("):finish.index("\n    }\n")]
    order = ["self.frame.finish(success);", "RtlReleaseSRWLockExclusive(&self.surface.remote_mutex);",
             "self.frame.logPerfSamples();"]
    places = [finish.find(step) for step in order]
    if -1 in places or places != sorted(places):
        problems.append("RemoteFrame.finish must finish, unlock and only then log the perf samples")
    return problems


GX0046 = "GX-0046"
GX0046_HOOK = ("if (effective_req == .osc_52_read) return gxStartClipboardReadOSC52(self, loc, "
               "effective_req.osc_52_read);")
GX0046_EMPTY = ("if (data.len == 0 and !confirmed) return self.completeClipboardReadOSC52("
                "data, clipboard_type, true);")


def gx0046_problems(source: str) -> list[str]:
    """Shape lock for GX-0046 in src/Surface.zig: the OSC 52 read hook after the deny check
    of startClipboardRequest, the helper hunk, and the empty-read bypass after the deny
    assertion of completeClipboardReadOSC52."""
    try:
        _, hunks = marked_hunks(source, GX0046)
    except ValueError as err:
        return [str(err)]
    if len(hunks) != 3:
        return [f"expected 3 {GX0046} hunks, found {len(hunks)}"]
    lines = source.splitlines()
    bodies = [[line.strip() for line in lines[b + 1:e] if line.strip()] for b, e in hunks]
    problems: list[str] = []
    if bodies[0] != [GX0046_HOOK]:
        problems.append("the first GX-0046 hunk must hold only the OSC 52 read hook")
    if bodies[2] != [GX0046_EMPTY]:
        problems.append("the last GX-0046 hunk must hold only the empty-read bypass")
    helper = "\n".join(bodies[1])
    if "fn gxStartClipboardReadOSC52(" not in helper or "if (result == .unavailable) {" not in helper \
            or 'try self.completeClipboardReadOSC52("", clipboard, true);' not in helper \
            or "return .started;" not in helper:
        problems.append("the helper must answer only an unavailable read, once, as started")
    def exact_fn(name: str) -> tuple[int, int] | None:
        # The upstream signatures break after "(", unlike same-named test doubles.
        starts = [i for i, line in enumerate(lines) if line.strip() == f"fn {name}("]
        if len(starts) != 1:
            return None
        end = next((i for i in range(starts[0] + 1, len(lines)) if lines[i] == "}"), None)
        return None if end is None else (starts[0], end + 1)

    start = exact_fn("startClipboardRequest")
    complete = exact_fn("completeClipboardReadOSC52")
    if start is None or complete is None:
        return problems + ["startClipboardRequest or completeClipboardReadOSC52 is missing"]
    deny = [i for i in range(*start) if lines[i].strip() == ".osc_52_read => if (self.config.clipboard_read == .deny) {"]
    if not (start[0] <= hunks[0][0] < start[1]) or not deny or hunks[0][0] < deny[0]:
        problems.append("the hook must sit in startClipboardRequest after its deny check")
    elif lines[hunks[0][1] + 1].strip() != "return try self.rt_surface.clipboardRequest(loc, effective_req);":
        problems.append("the hook must sit right above the upstream clipboardRequest return")
    asserted = [i for i in range(*complete) if lines[i].strip() == "assert(self.config.clipboard_read != .deny);"]
    if not (complete[0] <= hunks[2][0] < complete[1]) or not asserted or hunks[2][0] < asserted[0]:
        problems.append("the empty-read bypass must follow the deny assertion")
    return problems


TARGET_ZIG = "src/renderer/opengl/Target.zig"
WGL_ZIG = "src/renderer/opengl/wgl.zig"
GX0045 = "GX-0045"
GX0045_CALLS = (
    'if (comptime builtin.os.tag == .windows) @import("wgl.zig").targetLifetime(true);',
    'if (comptime builtin.os.tag == .windows) @import("wgl.zig").targetLifetime(false);',
)


def gx0045_problems(source: str) -> list[str]:
    """Shape lock for GX-0045 in src/renderer/opengl/Target.zig: two one-line hunks, the
    create count after the render framebuffer is complete and before the GX-0004 Windows
    return, the release count after the four destroys in deinit."""
    try:
        _, hunks = marked_hunks(source, GX0045)
    except ValueError as err:
        return [str(err)]
    lines = source.splitlines()
    if len(hunks) != 2:
        return [f"expected 2 {GX0045} hunks, found {len(hunks)}"]
    problems: list[str] = []
    for (begin, end), call in zip(hunks, GX0045_CALLS):
        body = [line.strip() for line in lines[begin + 1:end]]
        if body != [call]:
            problems.append(f"line {begin + 1}: the {GX0045} hunk must hold only `{call}`")
    init = zig_fn_lines(lines, "pub fn init(")
    deinit = zig_fn_lines(lines, "pub fn deinit(")
    if init is None or deinit is None:
        return problems + ["Target.init or Target.deinit is missing"]
    create, release = hunks[0][0], hunks[1][0]
    complete = [i for i in range(*init) if lines[i].strip() == ".complete => {},"]
    windows_return = [i for i in range(*init) if "GX-0004 begin: Windows blits" in lines[i]]
    if not (init[0] <= create < init[1]):
        problems.append("the create count must sit inside Target.init")
    elif not complete or not windows_return or not (complete[0] < create < windows_return[0]):
        problems.append("the create count must follow the complete render framebuffer and "
                        "precede the GX-0004 Windows return")
    destroys = [i for i in range(*deinit) if lines[i].strip().endswith(".destroy();")]
    if not (deinit[0] <= release < deinit[1]):
        problems.append("the release count must sit inside Target.deinit")
    elif len(destroys) != 4 or release < max(destroys):
        problems.append("the release count must follow the four destroys of Target.deinit")
    return problems


def _expand_ids(spec: str) -> set[str]:
    ids: set[str] = set()
    for first, last in re.findall(r"GX-(\d{4})(?:～GX-(\d{4}))?", spec):
        ids.update(f"GX-{n:04d}" for n in range(int(first), int(last or first) + 1))
    return ids


def registry_rule_problems(text: str, patches: list[Patch]) -> list[str]:
    """The 规则 section states the skipped IDs, the highest ID and the registered IDs;
    these sentences must agree with the registry table."""
    rules = text.split("## 规则", 1)[1].split("\n## ", 1)[0] if "## 规则" in text else ""
    ids = {patch.id for patch in patches}
    if not ids:
        return ["the registry table is empty"]
    highest = max(ids)
    problems: list[str] = []
    stated = re.search(r"当前最大编号（(GX-\d{4})）", rules)
    if stated is None or stated.group(1) != highest:
        problems.append(f"the rules must name {highest} as the current highest ID")
    listed = re.search(r"在册的 (\d+) 个 ID 是 ([^，]+)，", rules)
    if listed is None:
        problems.append("the rules must list the registered IDs")
    else:
        if int(listed.group(1)) != len(ids):
            problems.append(f"the rules count {listed.group(1)} IDs, the table has {len(ids)}")
        if _expand_ids(listed.group(2)) != ids:
            problems.append("the registered ID ranges in the rules differ from the table")
    skipped_match = re.search(r"。(GX-[^：。]+?) 没有对应补丁", rules)
    skipped = _expand_ids(skipped_match.group(1)) if skipped_match else set()
    if skipped & ids:
        problems.append(f"skipped IDs are registered: {', '.join(sorted(skipped & ids))}")
    every = {f"GX-{n:04d}" for n in range(1, int(highest[3:]) + 1)}
    if skipped | ids != every:
        problems.append("every ID up to the highest must be registered or listed as skipped")
    return problems


def css_call_args(css: str, paren: int) -> list[str]:
    """Top-level, comma-separated arguments of the call whose '(' is at ``paren``."""
    args: list[str] = []
    depth, start = 0, paren + 1
    for index in range(paren, len(css)):
        if css[index] == "(":
            depth += 1
        elif css[index] == ")":
            depth -= 1
            if depth == 0:
                return [*args, css[start:index].strip()]
        elif css[index] == "," and depth == 1:
            args.append(css[start:index].strip())
            start = index + 1
    raise ValueError(f"unclosed call at offset {paren}")


def gtk414_css_problems(source: str) -> list[str]:
    """Shape lock for GX-0023 and the GX stylesheets: CSS outside comments that GTK 4.14 cannot parse.

    GTK drops such a declaration and logs a theme parser error. Color
    transition hints in gradients parse from GTK 4.20 on; the space-separated
    rgb()/hsl() syntax, color-mix(), the newer color functions, var(),
    custom properties (`--name: value`) and :root from GTK 4.16 on.
    """
    css = CSS_COMMENT_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), source)
    problems: list[str] = []

    def line(offset: int) -> int:
        return css.count("\n", 0, offset) + 1

    for match in CSS_GTK416_RE.finditer(css):
        problems.append(f"line {line(match.start())}: {match.group()} needs GTK 4.16")
    for match in CSS_CUSTOM_PROPERTY_RE.finditer(css):
        problems.append(f"line {line(match.start())}: custom property {match.group().rstrip(': ')} needs GTK 4.16")
    for match in CSS_ROOT_RE.finditer(css):
        problems.append(f"line {line(match.start())}: :root needs GTK 4.16")
    for match in CSS_RGB_HSL_RE.finditer(css):
        if len(css_call_args(css, match.end() - 1)) == 1:
            problems.append(f"line {line(match.start())}: {match.group()} without commas needs GTK 4.16")
    for match in CSS_GRADIENT_RE.finditer(css):
        for arg in css_call_args(css, match.end() - 1)[1:]:
            if CSS_DIMENSION_RE.fullmatch(arg):
                problems.append(f"line {line(match.start())}: color hint {arg!r} needs GTK 4.20")
    return problems


def zig_css_text(source: str) -> str:
    """The string literals of a Zig CSS generator that GTK 4.14 may receive, as one CSS text.

    Multiline (`\\\\`) and quoted literals outside `test` declarations and outside functions
    named `*416` are kept one per line; format escapes `{{`/`}}` become braces and
    placeholders such as `{[bar_bg]f}` become `0`, so a color written by a `format` method
    stays a valid value.
    """
    lines = source.replace("\r\n", "\n").split("\n")
    fragments: list[str] = []
    skipping = False
    for line in lines:
        if line.startswith("}"):
            skipping = False
            continue
        fn = ZIG_FN_RE.match(line)
        if fn or ZIG_TEST_RE.match(line):
            gated = fn is None or fn.group(1).endswith("416")
            skipping = gated and not line.rstrip().endswith("}")
            if gated:
                continue
        if skipping:
            continue
        stripped = line.lstrip()
        if stripped.startswith("\\\\"):
            fragments.append(stripped[2:])
            continue
        code = ZIG_CHAR_RE.sub("' '", line)
        comment = None
        for match in re.finditer(r'"(?:[^"\\\n]|\\.)*"|//', code):
            if match.group() == "//":
                comment = match.start()
                break
        code = code if comment is None else code[:comment]
        fragments.extend(match.group(1) for match in ZIG_STRING_RE.finditer(code))
    text = "\n".join(fragments)
    text = ZIG_FORMAT_ESCAPE_RE.sub(lambda m: m.group()[0], text)
    return ZIG_PLACEHOLDER_RE.sub("0", text)


def gx_css_problems(root: Path) -> list[str]:
    """GTK 4.14 problems in the Ghostty GX static stylesheets and in the CSS its Zig code writes."""
    problems: list[str] = []
    sheets = sorted((root / GX_CSS_DIR).rglob("*.css"))
    if not sheets:
        problems.append(f"no stylesheet under {GX_CSS_DIR}")
    sources = [(path.relative_to(root).as_posix(), path.read_text(encoding="utf-8")) for path in sheets]
    for rel in GX_CSS_GENERATORS:
        path = root / rel
        if not path.is_file():
            problems.append(f"{rel} is missing")
            continue
        sources.append((rel, zig_css_text(path.read_text(encoding="utf-8"))))
    for rel, css in sources:
        try:
            problems.extend(f"{rel}: {problem}" for problem in gtk414_css_problems(css))
        except ValueError as exc:
            problems.append(f"{rel}: {exc}")
    return problems


class RealRepoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry_text = (ROOT / REGISTRY).read_text(encoding="utf-8")
        cls.patches = parse_registry(cls.registry_text)

    def test_registry_lists_gx0001_as_active(self):
        self.assertIn(Patch("GX-0001", CONFIG_ZIG, GX0001_MARKER, "active"), self.patches)

    def test_registry_lists_gx0002_as_active(self):
        self.assertIn(Patch(GX0002, BUILD_ZIG, GX0002_MARKER, "active"), self.patches)

    def test_registry_documents_the_scanned_scope(self):
        rules = self.registry_text.split("## 规则", 1)[1].split("\n## ", 1)[0]
        for scope in ("`src/`", "`include/`", "`pkg/`", "`macos/`", "`build.zig`"):
            self.assertIn(scope, rules)

    def test_scan_lists_only_git_visible_files_in_scope(self):
        files = git_visible_files(ROOT, SCAN_PATHSPECS)
        self.assertIn(CONFIG_ZIG, files)
        self.assertIn("build.zig", files)
        self.assertIn(GTK_CSS, files)
        for path in files:
            self.assertTrue(path == "build.zig" or path.split("/", 1)[0] in SCAN_PATHSPECS, path)

    def test_markers_registered_and_closed(self):
        self.assertEqual(check(ROOT), [])

    def test_readme_starts_with_the_unofficial_fork_notice(self):
        lines = (ROOT / "README.md").read_text(encoding="utf-8").splitlines()
        self.assertTrue(lines[0].startswith(README_NOTICE_BEGIN), lines[0])
        self.assertEqual(sum(line.startswith(README_NOTICE_BEGIN) for line in lines), 1)
        self.assertEqual(lines.count(README_NOTICE_END), 1)
        block = "\n".join(lines[:lines.index(README_NOTICE_END)])
        for notice in README_NOTICES:
            self.assertIn(notice, block)

    def test_ghostty_exe_embeds_the_fork_resources(self):
        lines = (ROOT / GHOSTTY_EXE_ZIG).read_text(encoding="utf-8").splitlines()
        selected = [i for i, line in enumerate(lines) if GX0026_RC in line]
        self.assertEqual(len(selected), 1)
        self.assertIn("fork(gx): GX-0026", lines[selected[0] - 1])
        self.assertFalse(any('"dist/windows/ghostty.rc"' in line for line in lines))

    def test_config_zig_keeps_the_gx0001_guard(self):
        source = (ROOT / CONFIG_ZIG).read_text(encoding="utf-8")
        self.assertEqual(gx0001_problems(source), [])

    def test_build_zig_keeps_the_gx0002_hunks(self):
        source = (ROOT / BUILD_ZIG).read_text(encoding="utf-8")
        self.assertEqual(gx0002_problems(source), [])

    def test_gtk_stylesheet_parses_on_gtk_4_14(self):
        source = (ROOT / GTK_CSS).read_text(encoding="utf-8")
        self.assertEqual(gtk414_css_problems(source), [])

    def test_gx_stylesheets_parse_on_gtk_4_14(self):
        self.assertEqual(gx_css_problems(ROOT), [])

    def test_gx_css_generator_text_is_extracted(self):
        css = zig_css_text((ROOT / GX_CSS_GENERATORS[0]).read_text(encoding="utf-8"))
        self.assertIn("background-color: 0;", css)
        self.assertIn("toolbarview.gx-chrome tabbar tabbox:not(.single-tab) tab:selected {", css)
        self.assertIn("rgb(0,0,0)", css)


class Gx0001ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / CONFIG_ZIG).read_text(encoding="utf-8")
        lines = cls.source.splitlines(keepends=True)
        guard = next(i for i, line in enumerate(lines) if GX0001_GUARD_CALL in line)
        indent = lines[guard][: len(lines[guard]) - len(lines[guard].lstrip())]
        # Reconstruct the upstream text: drop the two marker comment lines
        # and restore the tip-only guard.
        cls.upstream = "".join(
            lines[: guard - 2] + [f"{indent}{UPSTREAM_TIP_GUARD}\n"] + lines[guard + 1 :]
        )

    def test_reconstructed_upstream_is_rejected(self):
        self.assertNotIn("fork(gx)", self.upstream)
        problems = gx0001_problems(self.upstream)
        self.assertTrue(any("found 0" in problem for problem in problems), problems)

    def test_patch_is_the_only_change_against_merged_upstream(self):
        if set(re.findall(r"fork\(gx\): (GX-\d{4})", self.source)) != {"GX-0001"}:
            self.skipTest("Config.zig carries other fork patches")
        upstream, reason = merged_upstream_text(ROOT, CONFIG_ZIG)
        if upstream is None:
            self.skipTest(reason)
        self.assertEqual(self.upstream, upstream)

    def test_guard_without_tip_check_is_rejected(self):
        broken = self.source.replace('!std.mem.eql(u8, tag, "tip") and ', "", 1)
        self.assertTrue(any("tip check" in p for p in gx0001_problems(broken)))

    def test_missing_marker_comment_is_rejected(self):
        broken = self.source.replace(GX0001_MARKER, "fork note", 1)
        self.assertTrue(any("comment must sit" in p for p in gx0001_problems(broken)))

    def test_removed_upstream_panic_is_rejected(self):
        broken = self.source.replace(UPSTREAM_PANIC, "{}", 1)
        self.assertTrue(any(UPSTREAM_PANIC in p for p in gx0001_problems(broken)))

    def test_crlf_source_is_accepted(self):
        self.assertEqual(gx0001_problems(self.source.replace("\n", "\r\n")), [])


class Gx0002ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / BUILD_ZIG).read_text(encoding="utf-8")
        cls.lines = cls.source.splitlines(keepends=True)
        cls.upstream, cls.hunks = marked_hunks(cls.source, GX0002)

    def without_hunk(self, index: int) -> str:
        begin, end = self.hunks[index]
        return "".join(self.lines[:begin] + self.lines[end + 1:])

    def test_stripping_the_hunks_removes_every_marker(self):
        self.assertEqual(len(self.hunks), len(GX0002_HUNKS))
        self.assertNotIn("fork(gx)", self.upstream)

    def test_hunks_are_the_only_change_against_merged_upstream(self):
        if set(re.findall(r"fork\(gx\): (GX-\d{4})", self.source)) != {GX0002}:
            self.skipTest("build.zig carries other fork patches")
        upstream, reason = merged_upstream_text(ROOT, BUILD_ZIG)
        if upstream is None:
            self.skipTest(reason)
        self.assertEqual(self.upstream, upstream)

    def test_stripped_upstream_is_rejected(self):
        problems = gx0002_problems(self.upstream)
        self.assertTrue(any("found 0" in problem for problem in problems), problems)

    def test_each_missing_hunk_is_rejected(self):
        for index, (name, *_) in enumerate(GX0002_HUNKS):
            with self.subTest(name):
                problems = gx0002_problems(self.without_hunk(index))
                self.assertTrue(any(p.startswith(f"{name}:") for p in problems), problems)

    def test_install_directories_are_locked(self):
        for old, new, name in (('"test/vt_c"', '"test/vt"', "libghostty-vt installs"),
                               ('.custom = "test" }', '.custom = "bin" }', "ghostty-test install")):
            with self.subTest(new):
                problems = gx0002_problems(self.source.replace(old, new, 1))
                self.assertTrue(any(p.startswith(f"{name}:") for p in problems), problems)

    def test_step_must_depend_on_the_install(self):
        broken = self.source.replace("test_bin_step.dependOn(&test_exe_bin_install.step);", "", 1)
        problems = gx0002_problems(broken)
        self.assertTrue(any(p.startswith("ghostty-test install:") for p in problems), problems)

    def test_hunk_outside_its_block_is_rejected(self):
        begin, end = self.hunks[1]
        rest = self.lines[:begin] + self.lines[end + 1:]
        at = next(i for i, line in enumerate(rest) if line.strip() == "// Zig module tests")
        moved = "".join(rest[:at] + self.lines[begin:end + 1] + rest[at:])
        problems = gx0002_problems(moved)
        self.assertTrue(any("must sit between" in p for p in problems), problems)

    def test_marker_outside_a_hunk_is_rejected(self):
        problems = gx0002_problems(f"// {GX0002_MARKER} stray note\n" + self.source)
        self.assertTrue(any("outside a begin/end hunk" in p for p in problems), problems)

    def test_unclosed_hunk_is_rejected(self):
        _, end = self.hunks[2]
        problems = gx0002_problems("".join(self.lines[:end] + self.lines[end + 1:]))
        self.assertTrue(any("never closed" in p for p in problems), problems)

    def test_crlf_source_is_accepted(self):
        crlf = self.source.replace("\n", "\r\n")
        self.assertEqual(gx0002_problems(crlf), [])
        self.assertEqual(marked_hunks(crlf, GX0002)[0].replace("\r\n", "\n"), self.upstream)


class Gx0027ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / CLOSE_DIALOG_ZIG).read_text(encoding="utf-8")
        cls.lines = cls.source.splitlines(keepends=True)
        cls.upstream, cls.hunks = marked_hunks(cls.source, GX0027)

    def test_close_dialog_keeps_the_hunk(self):
        self.assertEqual(gx0027_problems(self.source), [])
        self.assertEqual(gx0027_problems(self.source.replace("\n", "\r\n")), [])

    def test_hunk_is_the_only_change_against_merged_upstream(self):
        upstream, reason = merged_upstream_text(ROOT, CLOSE_DIALOG_ZIG)
        if upstream is None:
            self.skipTest(reason)
        self.assertEqual(self.upstream.replace("\r\n", "\n"), upstream)

    def test_missing_or_moved_hunk_is_rejected(self):
        self.assertIn(f"expected one {GX0027} hunk, found 0", gx0027_problems(self.upstream))
        begin, end = self.hunks[0]
        rest = self.lines[:begin] + self.lines[end + 1:]
        at = next(i for i, line in enumerate(rest) if line.strip() == GX0027_BEFORE) + 1
        moved = "".join(rest[:at] + self.lines[begin:end + 1] + rest[at:])
        self.assertTrue(any("must sit between" in p for p in gx0027_problems(moved)))


class Gx0028ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / APPLICATION_ZIG).read_text(encoding="utf-8")

    def problems_after(self, old: str, new: str) -> list[str]:
        self.assertIn(old, self.source)
        return gx0028_problems(self.source.replace(old, new, 1))

    def test_application_keeps_the_hooks(self):
        self.assertEqual(gx0028_problems(self.source), [])
        self.assertEqual(gx0028_problems(self.source.replace("\n", "\r\n")), [])

    def test_open_dialog_is_not_raised_for_reported_diagnostics(self):
        problems = self.problems_after("if (gx_new_errors) diag.present(null);", "diag.present(null);")
        self.assertTrue(any("without checking gx_new_errors" in p for p in problems), problems)

    def test_reported_diagnostics_stay_dismissed(self):
        problems = self.problems_after("        if (!gx_new_errors) return;\n", "")
        self.assertTrue(any("'if (!gx_new_errors) return;'" in p for p in problems), problems)

    def test_only_the_dialog_reload_forgets(self):
        problems = self.problems_after("        priv.gx_config_errors.forget();\n", "")
        self.assertTrue(any(p.startswith("handleReloadConfig:") for p in problems), problems)
        problems = self.problems_after("        defer config.unref();\n",
                                       "        defer config.unref();\n        self.private().gx_config_errors.forget();\n")
        self.assertTrue(any("only the reload button" in p for p in problems), problems)

    def test_startup_errors_are_shown_in_the_first_window(self):
        hook = "        if (self.private().gx_config_errors.windowShown()) self.gxShowConfigErrorsIn(win);\n"
        problems = self.problems_after(hook, "")
        self.assertTrue(any(p.startswith("initAndShowWindow:") for p in problems), problems)
        problems = self.problems_after("dialog.present(win.as(gtk.Widget));", "dialog.present(null);")
        self.assertTrue(any(p.startswith("gxShowConfigErrorsIn:") for p in problems), problems)


class Gx0029ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / OPENGL_ZIG).read_text(encoding="utf-8")

    def test_present_keeps_the_hooks(self):
        self.assertEqual(gx0029_problems(self.source), [])
        self.assertEqual(gx0029_problems(self.source.replace("\n", "\r\n")), [])

    def test_unchecked_or_untracked_export_is_rejected(self):
        for old, new in ((" and self.gx_dmabuf.enabled(self.device.display)", ""),
                         ("self.gx_dmabuf.track(target.exportDmabuf(self.device.display, self.egl_context))",
                          "target.exportDmabuf(self.device.display, self.egl_context)")):
            with self.subTest(old):
                self.assertIn(old, self.source)
                problems = gx0029_problems(self.source.replace(old, new, 1))
                self.assertTrue(any("found 0" in p for p in problems), problems)

    def test_per_frame_warning_is_rejected(self):
        problems = gx0029_problems(self.source + f'\n// log.warn("{UPSTREAM_DMABUF_WARNING}", .{{}});\n')
        self.assertIn("present() must not warn for every frame whose export fails", problems)


class HunkTests(unittest.TestCase):
    TEXT = ("a\n// fork(gx): GX-0002 begin: add b\nb\n// fork(gx): GX-0002 end\nc\n"
            "// fork(gx): GX-0003 begin\nd\n// fork(gx): GX-0003 end\n")

    def test_strips_only_the_requested_patch(self):
        stripped, hunks = marked_hunks(self.TEXT, "GX-0002")
        self.assertEqual(stripped, "a\nc\n// fork(gx): GX-0003 begin\nd\n// fork(gx): GX-0003 end\n")
        self.assertEqual(hunks, [(1, 3)])
        self.assertEqual(marked_hunks(self.TEXT, "GX-0003"), ("a\n// fork(gx): GX-0002 begin: add b\n"
                                                             "b\n// fork(gx): GX-0002 end\nc\n", [(5, 7)]))

    def test_crlf_line_endings_are_kept(self):
        stripped, hunks = marked_hunks(self.TEXT.replace("\n", "\r\n"), "GX-0002")
        self.assertEqual(stripped, marked_hunks(self.TEXT, "GX-0002")[0].replace("\n", "\r\n"))
        self.assertEqual(hunks, [(1, 3)])

    def test_malformed_hunks_are_rejected(self):
        begin, end = "// fork(gx): GX-0002 begin\n", "// fork(gx): GX-0002 end\n"
        cases = {
            "never closed": begin,
            "without a begin": end,
            "inside the hunk": begin + begin + end + end,
            "outside a begin/end hunk": "// fork(gx): GX-0002 one-line note\n",
        }
        for expected, text in cases.items():
            with self.subTest(expected):
                with self.assertRaisesRegex(ValueError, re.escape(expected)):
                    marked_hunks(text, "GX-0002")

    def test_squash_ignores_formatting_and_comments(self):
        self.assertEqual(squash("f(.{\n    // note\n    .a = 1,\n});"), squash("f(.{ .a = 1 });"))


class Gtk414CssTests(unittest.TestCase):
    def test_gtk_4_14_syntax_passes(self):
        css = (".a { color: hsl(25, 50%, 75%); border-color: rgba(53, 132, 228, 0.5); }\n"
               ".b {\n  background: linear-gradient(\n    to left,\n    transparent 50%,\n"
               "    rgba(53, 132, 228, 0.2) 50%\n  );\n}\n"
               ".c { background: radial-gradient(10px, red, blue); background-image: image(rgb(1,2,3)); }\n"
               "/* background: linear-gradient(to left, transparent, 50%, color-mix(in srgb,"
               " var(--accent-color), transparent 50%) 50%); */\n")
        self.assertEqual(gtk414_css_problems(css), [])
        self.assertEqual(gtk414_css_problems(css.replace("\n", "\r\n")), [])

    def test_newer_syntax_is_rejected(self):
        cases = {
            "line 3: color hint '50%' needs GTK 4.20":
                "/* x */\n.a {\n  background: linear-gradient(\n    to left,\n    transparent,\n"
                "    50%,\n    rgba(53, 132, 228, 0.2) 50%\n  );\n}\n",
            "line 1: hsl( without commas needs GTK 4.16": ".a { color: hsl(25 50 75); }\n",
            "line 1: rgb( without commas needs GTK 4.16": ".a { color: rgb(1 2 3 / 50%); }\n",
            "line 1: color-mix( needs GTK 4.16": ".a { color: color-mix(in srgb, red, blue); }\n",
            "line 1: var( needs GTK 4.16": ".a { color: var(--accent-color); }\n",
            "line 1: oklab( needs GTK 4.16": ".a { color: oklab(from red calc(l * 0.9) a b); }\n",
        }
        for expected, css in cases.items():
            with self.subTest(expected):
                self.assertIn(expected, gtk414_css_problems(css))

    def test_custom_properties_and_root_are_rejected(self):
        problems = gtk414_css_problems(":root { --accent-bg-color: #3584e4; }\n"
                                       "window.window {\n  --headerbar-bg-color : rgb(1,2,3);\n}\n")
        self.assertIn("line 1: :root needs GTK 4.16", problems)
        self.assertIn("line 1: custom property --accent-bg-color needs GTK 4.16", problems)
        self.assertIn("line 3: custom property --headerbar-bg-color needs GTK 4.16", problems)
        self.assertEqual(gtk414_css_problems("@define-color window_bg_color rgb(1,2,3);\n"
                                             ".a { margin: -1px; transition: --x; }\n"), [])


class GxCssGeneratorTests(unittest.TestCase):
    ZIG = "\n".join((
        "const std = @import(\"std\");",
        "pub const Rgb = struct {",
        "    pub fn format(self: Rgb, w: *W) !void {",
        "        try w.print(\"rgb({d},{d},{d})\", .{ self.r, self.g, self.b }); // not var(--x)",
        "    }",
        "};",
        "pub fn write(w: *W, c: Colors) !void {",
        "    try w.print(",
        "        \\\\.window headerbar {{",
        "        \\\\  background-color: {[bg]f};",
        "        \\\\}}",
        "    , .{ .bg = c.bg });",
        "    const quote = '\"';",
        "}",
        "pub fn writeVariables416(w: *W) !void {",
        "    try w.writeAll(",
        "        \\\\window.window { --accent-bg-color: var(--blue); }",
        "    );",
        "}",
        "test \"write\" {",
        "    try std.testing.expect(std.mem.indexOf(u8, css, \"color-mix(\") == null);",
        "}",
        "test \"one line\" {}",
        "const tail = \"--late: 1;\";",
        "",
    ))

    def test_text_skips_tests_comments_and_gtk_4_16_functions(self):
        css = zig_css_text(self.ZIG.replace("\n", "\r\n"))
        self.assertEqual(css.splitlines(), [
            "std",
            "rgb(0,0,0)",
            ".window headerbar {",
            "  background-color: 0;",
            "}",
            "--late: 1;",
        ])

    def test_generators_and_sheets_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertIn(f"no stylesheet under {GX_CSS_DIR}", gx_css_problems(root))
            sheet = root / GX_CSS_DIR / "style.css"
            sheet.parent.mkdir(parents=True)
            sheet.write_text(".a { color: hsl(25 50 75); }\n", encoding="utf-8")
            for rel in GX_CSS_GENERATORS:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text(self.ZIG, encoding="utf-8")
            problems = gx_css_problems(root)
            self.assertIn(f"{GX_CSS_DIR}/style.css: line 1: hsl( without commas needs GTK 4.16", problems)
            self.assertIn(f"{GX_CSS_GENERATORS[0]}: line 6: custom property --late needs GTK 4.16", problems)
            self.assertEqual(len(problems), 1 + len(GX_CSS_GENERATORS), problems)
            sheet.write_text(".a { color: rgb(1 2 3; }\n", encoding="utf-8")
            self.assertTrue(any("unclosed call" in problem for problem in gx_css_problems(root)))


class Gx0030ShapeTests(unittest.TestCase):
    def test_optional_hooks_bracket_only_user_mutations(self):
        expected = {
            "src/Surface.zig": 5,
            "src/termio/Termio.zig": 2,
        }
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        for rel, count in expected.items():
            with self.subTest(rel):
                self.assertIn(Patch("GX-0030", rel, "fork(gx): GX-0030", "active"), patches)
                source = (ROOT / rel).read_text(encoding="utf-8")
                stripped, hunks = marked_hunks(source, "GX-0030")
                self.assertEqual(len(hunks), count * 2 + (2 if rel == "src/Surface.zig" else 0))
                self.assertNotIn("gxUserScrolled", stripped)
                self.assertNotIn("gx_before", stripped)
                self.assertEqual(source.count("const gx_before = if (comptime @hasDecl(apprt.Surface,"), count)
                self.assertEqual(source.count(".gxUserScrolled(gx_before,"), count)
                for forbidden in ("ShowWindow", "PostMessage"):
                    for begin, end in hunks:
                        self.assertNotIn(forbidden, "\n".join(source.splitlines()[begin:end + 1]))
                lines = source.splitlines()
                mutations = [(begin, end) for begin, end in hunks
                             if "gx_before" in "\n".join(lines[begin + 1:end])]
                self.assertEqual(len(mutations), count * 2)
                for before, after in zip(mutations[::2], mutations[1::2]):
                    mutation = "\n".join(lines[before[1] + 1:after[0]])
                    self.assertTrue(any(call in mutation for call in
                                        ("autoscrollTick(", ".scrollViewport(", ".scroll(")), mutation)
                    self.assertNotIn("queueIo(", mutation)
                    self.assertNotIn(".unlock(", mutation)
        termio = (ROOT / "src/termio/Termio.zig").read_text(encoding="utf-8")
        self.assertEqual(termio.count("self.surface_mailbox.surface.rt_surface.gxUserScrolled("), 2)

    def test_search_selection_source_stays_inside_the_mutex(self):
        rel = "src/terminal/search/Thread.zig"
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        self.assertIn(Patch("GX-0030", rel, "fork(gx): GX-0030", "active"), patches)
        source = (ROOT / rel).read_text(encoding="utf-8")
        stripped, hunks = marked_hunks(source, "GX-0030")
        self.assertEqual(len(hunks), 5)
        self.assertNotIn("gx_user_scroll", stripped)
        lines = source.splitlines()
        bounds = zig_fn_lines(lines, "fn select(")
        self.assertIsNotNone(bounds)
        body = "\n".join(lines[bounds[0]:bounds[1]])
        lock = body.index("self.opts.mutex.lockUncancelable(")
        before = body.index("const gx_before =")
        mutation = body.index("try s.select(")
        after = body.index("const gx_after =")
        notify = body.index("cb(.{ .gx_user_scroll")
        self.assertTrue(lock < before < mutation < after < notify)
        self.assertIn("defer self.opts.mutex.unlock(", body)
        self.assertIn("if (gx_before.offset != gx_after.offset)", body)
        self.assertNotIn(".push(", body)
        self.assertEqual(body.count("screens.active.pages.scrollbar()"), 2)
        self.assertIn("gx_user_scroll_enabled: bool = false", source)
        core = (ROOT / "src/Surface.zig").read_text(encoding="utf-8")
        self.assertIn('.gx_user_scroll_enabled = @hasDecl(apprt.Surface, "gxUserScrolled"),', core)
        self.assertIn("self.rt_surface.gxUserScrolled(scroll.before, scroll.after);", core)


class Gx0031ShapeTests(unittest.TestCase):
    def test_cursor_gate_only_changes_the_timer_notify(self):
        source = (ROOT / "src/renderer/Thread.zig").read_text(encoding="utf-8")
        lines = source.splitlines()
        start, end = zig_fn_lines(lines, "fn cursorTimerCallback(")
        body = "\n".join(lines[start:end])
        self.assertIn('fork(gx): GX-0031', body)
        self.assertIn('@import("../gx/cursor_blink.zig").notify(t, global.io());', body)
        self.assertIn('t.flags.cursor_blink_visible = !t.flags.cursor_blink_visible;', body)
        self.assertIn('t.cursor_h.run(', body)
        self.assertIn('const CURSOR_BLINK_INTERVAL = 600;', source)
        self.assertNotIn('t.state', body)
        self.assertNotIn('t.wakeup.notify()', body)
        focus = source[source.index('.focus =>'):source.index('.reset_cursor_blink =>')]
        self.assertIn('self.cursor_h.cancel(', focus)
        animation = source[source.index('fn animationTimerCallback('):source.index('fn cursorTimerCallback(')]
        self.assertNotIn('cursor_blink.zig', animation)

    def test_blink_cache_uses_the_successful_frame_snapshot(self):
        source = (ROOT / "src/renderer/generic.zig").read_text(encoding="utf-8")
        self.assertIn('gx_cursor_blink_affects: bool = true', source)
        self.assertIn('errdefer @import("../gx/cursor_blink.zig").invalidate(self, global.io());', source)
        cache = source.index('self.gx_cursor_blink_affects = !gx_rebuilt')
        self.assertLess(source.index('self.terminal_state.endUpdate();'), cache)
        self.assertLess(source.index('self.rebuildCells('), cache)
        self.assertIn('.preedit = critical.preedit != null,', source[cache:cache + 280])
        self.assertIn('.focused = self.focused,', source[cache:cache + 280])
        outside = source[source.index('self.terminal_state.endUpdate();'):source.index('pub fn drawFrame(')]
        self.assertNotIn('state.preedit', outside)
        self.assertNotIn('state.mouse', outside)
        callback = (ROOT / 'src/renderer/Thread.zig').read_text(encoding='utf-8')
        self.assertLess(callback.index('if (!t.renderer.display_realized)'), callback.index('if (!t.flags.visible) return .disarm;'))


class Gx0032ShapeTests(unittest.TestCase):
    def test_background_is_prepared_under_draw_mutex_before_realization(self):
        source = (ROOT / 'src/renderer/generic.zig').read_text(encoding='utf-8')
        lines = source.splitlines()
        start, end = zig_fn_lines(lines, 'pub fn displayRealized(')
        body = '\n'.join(lines[start:end])
        self.assertIn('fork(gx): GX-0032', body)
        self.assertLess(body.index('draw_mutex.lockUncancelable'), body.index('prepareBackground('))
        self.assertLess(body.index('prepareBackground('), body.index('self.display_realized = true;'))
        self.assertNotIn('uploadBackgroundImage(', body)
        helper = (ROOT / 'src/gx/renderer_recovery.zig').read_text(encoding='utf-8')
        self.assertIn('renderer.config.bg_image != null and renderer.bg_image == null', helper)
        self.assertIn('try prepare(renderer);', helper)


class Gx0033ShapeTests(unittest.TestCase):
    def test_vsync_documentation_describes_a_request_not_a_driver_guarantee(self):
        source = (ROOT / 'src/config/Config.zig').read_text(encoding='utf-8')
        doc = source[source.index('/// Synchronize rendering with the screen refresh rate.'):source.index('@"window-vsync": bool = true,')]
        for text in ('fork(gx): GX-0033', 'WGL', 'interval 1', 'when false', 'Driver settings', 'original request', 'gl.finish()', 'only affect new terminals'):
            self.assertIn(text, doc)
        self.assertNotIn('only supported currently on macOS', doc)


class GtkInputShapeTests(unittest.TestCase):
    def test_zoom_hooks_stay_thin_and_before_scroll_conversion(self):
        rel = "src/apprt/gtk/class/surface.zig"
        source = (ROOT / rel).read_text(encoding="utf-8")
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        self.assertIn(Patch("GX-0035", rel, "fork(gx): GX-0035", "active"), patches)
        self.assertEqual(source.count("gx_font_zoom.sync("), 1)
        self.assertEqual(source.count("gx_font_zoom.scroll("), 1)
        self.assertEqual(source.count("gx_font_zoom.dispose("), 1)
        self.assertLess(source.index("gx_font_zoom.dispose("), source.index("gtk.Widget.disposeTemplate("))
        self.assertLess(source.index("gx_font_zoom.scroll("), source.index("const multiplier: f64 = if (priv.precision_scroll)"))
        zoom = (ROOT / "src/apprt/gtk/gx/font_zoom.zig").read_text(encoding="utf-8")
        self.assertIn(".set_font_size = points", zoom)
        self.assertNotIn(".setFontSize(", zoom)
        self.assertNotIn("gui_settings", zoom)
        self.assertNotIn(".getZoom(", zoom)

    def test_environment_only_replaces_the_two_flag_writers(self):
        source = (ROOT / APPLICATION_ZIG).read_text(encoding="utf-8")
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        self.assertIn(Patch("GX-0036", APPLICATION_ZIG, "fork(gx): GX-0036", "active"), patches)
        lines = source.splitlines()
        start, end = zig_fn_lines(lines, "fn setGtkEnv(")
        body = "\n".join(lines[start:end])
        self.assertEqual(body.count('@import("../gx/environment.zig").append('), 2)
        self.assertIn("assert(gtk.isInitialized() == 0);", body)
        self.assertIn("global.syncEnviron();", body)
        self.assertNotIn('setenv("GDK_', body)
        adapter = (ROOT / "src/apprt/gtk/gx/environment.zig").read_text(encoding="utf-8")
        self.assertIn("gtk_version.runtimeAtLeast(4, 16, 0)", adapter)
        self.assertNotIn('setenv("GSK_RENDERER"', adapter)
        surface = (ROOT / "src/apprt/gtk/class/surface.zig").read_text(encoding="utf-8")
        for variable in ("GDK_DEBUG", "GDK_DISABLE", "GSK_RENDERER"):
            self.assertIn(f'"{variable}"', surface)


class Gx0037ShapeTests(unittest.TestCase):
    GENERATORS = (
        ("src/build/webgen/main_config.zig", "try genConfig(stdout);"),
        ("src/build/webgen/main_actions.zig",
         "try helpgen_actions.generate(stdout, .markdown, true, std.heap.page_allocator);"),
        ("src/build/webgen/main_commands.zig", "try genActions(stdout);"),
    )

    def test_buffered_stdout_is_flushed_after_generation(self):
        for rel, generate in self.GENERATORS:
            with self.subTest(rel):
                lines = (ROOT / rel).read_text(encoding="utf-8").splitlines()
                bounds = zig_fn_lines(lines, "pub fn main(")
                self.assertIsNotNone(bounds)
                body = [line.strip() for line in lines[bounds[0]:bounds[1]]]
                self.assertEqual(body.count(generate), 1)
                self.assertEqual(body.count("try stdout.flush();"), 1)
                self.assertLess(body.index(generate), body.index("try stdout.flush();"))

    def test_flush_hunks_are_registered_pure_additions(self):
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        for rel, generate in self.GENERATORS:
            with self.subTest(rel):
                source = (ROOT / rel).read_text(encoding="utf-8")
                stripped, hunks = marked_hunks(source, "GX-0037")
                self.assertEqual(len(hunks), 1)
                begin, end = hunks[0]
                lines = source.splitlines()
                self.assertEqual(lines[begin - 1].strip(), generate)
                self.assertEqual(squash("\n".join(lines[begin + 1:end])), squash("try stdout.flush();"))
                self.assertIn(Patch("GX-0037", rel, "fork(gx): GX-0037", "active"), patches)
                self.assertEqual(marked_hunks(source.replace("\n", "\r\n"), "GX-0037")[0]
                                 .replace("\r\n", "\n"), stripped)
                upstream, reason = merged_upstream_text(ROOT, rel)
                if upstream is None:
                    self.skipTest(reason)
                self.assertEqual(stripped, upstream)


class Gx0038ShapeTests(unittest.TestCase):
    def test_mapping_style_and_cache_are_thin_hooks(self):
        source = (ROOT / "src/font/CodepointResolver.zig").read_text(encoding="utf-8")
        self.assertIn("self.getIndexCodepointOverride(alloc, cp, style)", source)
        self.assertIn('const DescriptorCache = @import("../gx/font_codepoint_map.zig").State;', source)
        self.assertIn("self.descriptor_cache.resolve(alloc, &self.collection, discover, map, cp, style)", source)
        self.assertEqual(source.count("self.descriptor_cache.getOrdinaryIndex(&self.collection,"), 2)
        resolver_body = source.split("pub fn getIndex(", 1)[1].split("\n}\n", 1)[0]
        self.assertNotIn("self.collection.getIndex(", resolver_body)
        mapping = (ROOT / "src/gx/font_codepoint_map.zig").read_text(encoding="utf-8")
        self.assertIn("private_indices.contains(index.int())", mapping)
        self.assertIn("private_indices.putAssumeCapacityNoClobber(idx.int(), {})", mapping)
        self.assertLess(mapping.index("state.private_indices.ensureUnusedCapacity(alloc, 1)"), mapping.index("const idx = try collection.add(alloc, face,"))
        self.assertNotIn("return ctx.hash(a) == ctx.hash(b);", source)
        self.assertNotIn(".style = .regular,", source.split("fn getIndexCodepointOverride(", 1)[1].split("\n}", 1)[0])
        for line in ("if (self.getIndexCodepointOverride(alloc, cp, style))", "fn getIndexCodepointOverride(", "const DescriptorCache ="):
            lines = source.splitlines()
            pos = next(i for i, text in enumerate(lines) if line in text)
            self.assertIn("fork(gx): GX-0038", lines[pos - 1])

    def test_fontconfig_and_grid_additions_have_closed_hunks(self):
        expected = {"src/font/discovery.zig": 1, "src/font/SharedGridSet.zig": 4}
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        for path, count in expected.items():
            with self.subTest(path=path):
                self.assertIn(Patch("GX-0038", path, "fork(gx): GX-0038", "active"), patches)
                source = (ROOT / path).read_text(encoding="utf-8")
                stripped, hunks = marked_hunks(source, "GX-0038")
                self.assertEqual(len(hunks), count)
                self.assertNotIn("font_policy", stripped)
                self.assertNotIn("discoverMappedFamily", stripped)
        grid = (ROOT / "src/font/SharedGridSet.zig").read_text(encoding="utf-8")
        self.assertIn(".descriptor_cache = .{ .policy = key.font_policy }", grid)
        self.assertIn('Policy.fromConfig(config)', grid)
        self.assertIn("autoHash(hasher, @as(u8, @bitCast(self.font_policy)));", grid)


class Gx0044ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / CORE_SURFACE_ZIG).read_text(encoding="utf-8")

    def test_registered_route_stays_optional_and_marked(self):
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        self.assertIn(Patch(GX0044, CORE_SURFACE_ZIG, f"fork(gx): {GX0044}", "active"), patches)
        self.assertEqual(gx0044_problems(self.source), [])
        self.assertEqual(gx0044_problems(self.source.replace("\n", "\r\n")), [])

    def test_broken_shapes_are_rejected(self):
        cases = {
            "default to null": ("\n} = null,\ngx_binding_bypass", "\n} = undefined,\ngx_binding_bypass"),
            "inside `if (self.gx_binding_route) |route|`": (
                "if (self.gx_binding_route) |route| {", "if (true) { const route = self.gx_binding_route.?;"),
            "needs a fork(gx): GX-0044 line above": (
                "// fork(gx): GX-0044 remote writes clear only after an actual receipt\n", ""),
            "upstream paths gated on a missing route": (
                "self.config.selection_clear_on_copy and self.gx_binding_route == null",
                "self.config.selection_clear_on_copy"),
        }
        for expected, (old, new) in cases.items():
            with self.subTest(expected):
                self.assertEqual(self.source.count(old), 1, old)
                problems = gx0044_problems(self.source.replace(old, new))
                self.assertTrue(any(expected in problem for problem in problems), problems)


class Gx0043ReadbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.wgl = (ROOT / WGL_ZIG).read_text(encoding="utf-8")
        cls.surface = (ROOT / WIN32_SURFACE_ZIG).read_text(encoding="utf-8")

    def test_readback_stamp_and_unlocked_logging(self):
        self.assertEqual(gx0043_readback_problems(self.wgl, self.surface), [])

    def test_broken_shapes_are_rejected(self):
        stamp = "                    remote.frame.readbackComplete();\n"
        self.assertEqual(self.wgl.count(stamp), 1)
        dropped = gx0043_readback_problems(self.wgl.replace(stamp, ""), self.surface)
        self.assertTrue(any("exactly one" in p for p in dropped), dropped)
        early = self.wgl.replace(stamp, "").replace(
            "                    try gl.errors.getError();\n                    success = true;\n",
            stamp + "                    try gl.errors.getError();\n                    success = true;\n", 1)
        problems = gx0043_readback_problems(early, self.surface)
        self.assertTrue(any("must follow" in p for p in problems), problems)
        unlock = "        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.surface.remote_mutex);\n"
        log = "        self.frame.logPerfSamples();\n"
        self.assertEqual(self.surface.count(unlock + log), 1)
        locked = self.surface.replace(unlock + log, log + unlock, 1)
        problems = gx0043_readback_problems(self.wgl, locked)
        self.assertTrue(any("only then log" in p for p in problems), problems)


GX0050 = "GX-0050"
GX0050_DISCARD = "    // fork(gx): GX-0050 replaces the now-invalid unused self discard."
GX0050_BODIES = (
    ("surfaceSize", """if (comptime builtin.os.tag == .windows) {
        if (!self.wgl_context.drawable()) return error.ContextLost;
    }"""),
    ("setViewport", """if (comptime builtin.os.tag == .windows) {
        if (!self.wgl_context.drawable()) return;
    }"""),
    ("drawFrameEnd", """if (comptime builtin.os.tag == .windows) {
        self.wgl_context.finishRecovery(self.device) catch |err| {
            log.err("cannot recreate the OpenGL context err={}", .{err});
        };
        return;
    }"""),
)


def gx0050_problems(source: str) -> list[str]:
    """Three Windows-only hooks; GL/resource work stays in fork code.

    Each hook necessarily replaces the upstream unused-self discard (Zig
    rejects it once self is used). Restore those explicitly marked lines
    before stripping pure-addition blocks.
    """
    problems = []
    if source.count(GX0050_DISCARD) != 3:
        problems.append("expected three explicitly marked unused-self replacements")
    restored = source.replace(GX0050_DISCARD, "    _ = self;")
    try:
        _, hunks = marked_hunks(restored, GX0050)
    except ValueError as err:
        return problems + [str(err)]
    if len(hunks) != 3:
        return problems + [f"expected 3 {GX0050} hunks, found {len(hunks)}"]
    lines = source.splitlines()
    for (begin, end), (name, expected) in zip(hunks, GX0050_BODIES):
        bounds = zig_fn_lines(lines, f"pub fn {name}(")
        if bounds is None or not (bounds[0] < begin < end < bounds[1]):
            problems.append(f"the {name} hook must stay in that function")
        if squash("\n".join(lines[begin + 1:end])) != squash(expected):
            problems.append(f"the {name} hook must remain the exact Windows forwarding/guard")
        if end + 1 >= len(lines) or lines[end + 1] != GX0050_DISCARD:
            problems.append(f"the {name} unused-self replacement must follow its hook")
    return problems


class Gx0050ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / OPENGL_ZIG).read_text(encoding="utf-8")

    def test_registration(self):
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        self.assertIn(Patch(GX0050, OPENGL_ZIG, f"fork(gx): {GX0050}", "active"), patches)

    def test_real_source_and_crlf(self):
        self.assertEqual(gx0050_problems(self.source), [])
        self.assertEqual(gx0050_problems(self.source.replace("\n", "\r\n")), [])

    def test_affected_functions_restore_upstream(self):
        upstream, reason = merged_upstream_text(ROOT, OPENGL_ZIG)
        if upstream is None:
            self.skipTest(reason)
        restored = self.source.replace(GX0050_DISCARD, "    _ = self;")
        restored, _ = marked_hunks(restored, GX0050)
        for name, _ in GX0050_BODIES:
            with self.subTest(name=name):
                current_lines = restored.splitlines()
                original_lines = upstream.splitlines()
                current = zig_fn_lines(current_lines, f"pub fn {name}(")
                original = zig_fn_lines(original_lines, f"pub fn {name}(")
                self.assertIsNotNone(current)
                self.assertIsNotNone(original)
                self.assertEqual(squash("\n".join(current_lines[slice(*current)])),
                                 squash("\n".join(original_lines[slice(*original)])))

    def test_wrong_platform_or_early_hook_is_rejected(self):
        for name, body in GX0050_BODIES:
            with self.subTest(name=name):
                self.assertIn(body, self.source)
                self.assertTrue(gx0050_problems(self.source.replace(body, body.replace(".windows", ".linux"))))
        moved = self.source.replace("pub fn drawFrameEnd(", "pub fn gxWrongFrameEnd(")
        self.assertTrue(gx0050_problems(moved))

    def test_inline_cleanup_and_silent_failure_are_rejected(self):
        call = "self.wgl_context.finishRecovery(self.device)"
        self.assertTrue(gx0050_problems(self.source.replace(call, "self.releaseGpuResources()")))
        logged = 'log.err("cannot recreate the OpenGL context err={}", .{err});'
        self.assertTrue(gx0050_problems(self.source.replace(logged, "_ = err;")))

    def test_missing_guard_discard_marker_or_delimiter_is_rejected(self):
        self.assertTrue(gx0050_problems(self.source.replace("if (!self.wgl_context.drawable()) return;", "", 1)))
        self.assertTrue(gx0050_problems(self.source.replace(GX0050_DISCARD, "", 1)))
        self.assertTrue(gx0050_problems(self.source.replace("// fork(gx): GX-0050 end", "", 1)))


class Gx0049ShapeTests(unittest.TestCase):
    def test_validate_config_flushes_stdout_without_truncating(self):
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        self.assertIn(Patch("GX-0049", "src/cli/validate_config.zig", "fork(gx): GX-0049", "active"), patches)
        source = (ROOT / "src/cli/validate_config.zig").read_text(encoding="utf-8")
        lines = source.splitlines()
        marker = [i for i, line in enumerate(lines) if "fork(gx): GX-0049" in line]
        self.assertEqual(len(marker), 1)
        self.assertEqual(lines[marker[0] + 1].strip(), "try stdout_writer.flush();")
        # end() truncates stdout, which a Windows pipe or NUL rejects.
        self.assertNotIn("stdout_writer.end()", source)


class Gx0048ShapeTests(unittest.TestCase):
    def test_windows_click_interval_stays_a_default_only(self):
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        for rel in ("src/os/mouse.zig", "src/config/Config.zig"):
            self.assertIn(Patch("GX-0048", rel, "fork(gx): GX-0048", "active"), patches)
        mouse = (ROOT / "src/os/mouse.zig").read_text(encoding="utf-8")
        stripped, hunks = marked_hunks(mouse, "GX-0048")
        self.assertEqual(len(hunks), 1)
        self.assertIn('.windows => @import("../gx/os_mouse.zig").doubleClickTime(),', mouse)
        self.assertNotIn("GetDoubleClickTime", mouse)
        upstream, reason = merged_upstream_text(ROOT, "src/os/mouse.zig")
        if upstream is not None:
            self.assertEqual(stripped.replace("\r\n", "\n"), upstream)
        helper = (ROOT / "src/gx/os_mouse.zig").read_text(encoding="utf-8")
        # The OS value is clamped so the core's u32 nanoseconds cannot overflow.
        self.assertIn("pub const max_ms: u32 = std.math.maxInt(u32) / std.time.ns_per_ms;", helper)
        self.assertIn("return @min(ms, max_ms);", helper)
        config = (ROOT / "src/config/Config.zig").read_text(encoding="utf-8")
        # Only the zero default consults the OS; an explicit value still wins.
        self.assertIn('if (self.@"click-repeat-interval" == 0 and', config)
        self.assertIn("internal_os.clickInterval() orelse 500;", config)


class Gx0046ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / CORE_SURFACE_ZIG).read_text(encoding="utf-8")

    def test_osc52_read_completion_stays_registered_and_in_place(self):
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        self.assertIn(Patch(GX0046, CORE_SURFACE_ZIG, f"fork(gx): {GX0046}", "active"), patches)
        self.assertEqual(gx0046_problems(self.source), [])
        self.assertEqual(gx0046_problems(self.source.replace("\n", "\r\n")), [])

    def test_broken_shapes_are_rejected(self):
        cases = {
            "only the OSC 52 read hook": (GX0046_HOOK, GX0046_HOOK + "\n    _ = 0;"),
            "only the empty-read bypass": (GX0046_EMPTY, "if (data.len == 0) return;"),
            "answer only an unavailable read": ("if (result == .unavailable) {", "if (result != .started) {"),
        }
        for expected, (old, new) in cases.items():
            with self.subTest(expected):
                self.assertEqual(self.source.count(old), 1, old)
                problems = gx0046_problems(self.source.replace(old, new))
                self.assertTrue(any(expected in problem for problem in problems), problems)


class Gx0045ShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / TARGET_ZIG).read_text(encoding="utf-8")

    def test_target_counts_stay_registered_and_in_place(self):
        patches = parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8"))
        self.assertIn(Patch(GX0045, TARGET_ZIG, f"fork(gx): {GX0045}", "active"), patches)
        self.assertEqual(gx0045_problems(self.source), [])
        self.assertEqual(gx0045_problems(self.source.replace("\n", "\r\n")), [])

    def test_dropping_the_hunks_gives_back_upstream(self):
        upstream, reason = merged_upstream_text(ROOT, TARGET_ZIG)
        if upstream is None:
            self.skipTest(reason)
        stripped, _ = marked_hunks(self.source, GX0045)
        stripped, _ = marked_hunks(stripped, "GX-0004")
        self.assertEqual(squash(stripped), squash(upstream))

    def test_gauge_switch_comes_before_the_lock(self):
        lines = (ROOT / WGL_ZIG).read_text(encoding="utf-8").splitlines()
        start, end = zig_fn_lines(lines, "pub fn targetLifetime(")
        body = [line.strip() for line in lines[start + 1:end] if line.strip()]
        self.assertEqual(body[0], "if (!perf.enabled()) return;")
        lock = next(i for i, line in enumerate(body) if "target_lock.lockUncancelable(" in line)
        report = next(i for i, line in enumerate(body) if "target_counts.report()" in line)
        self.assertLess(0, lock)
        self.assertLess(lock, report)

    def test_broken_shapes_are_rejected(self):
        create, release = GX0045_CALLS
        cases = {
            "must hold only": (create, create + "\n    _ = 0;"),
            "expected 2": (
                "    // fork(gx): GX-0045 begin: account for released Windows target resources\n"
                f"    {release}\n    // fork(gx): GX-0045 end\n",
                ""),
        }
        for expected, (old, new) in cases.items():
            with self.subTest(expected):
                self.assertEqual(self.source.count(old), 1, old)
                problems = gx0045_problems(self.source.replace(old, new))
                self.assertTrue(any(expected in problem for problem in problems), problems)
        swapped = self.source.replace(create, "@@CREATE@@").replace(release, create).replace("@@CREATE@@", release)
        self.assertTrue(gx0045_problems(swapped))
        hunk = ("    // fork(gx): GX-0045 begin: count fully initialized Windows target resources\n"
                f"    {create}\n    // fork(gx): GX-0045 end\n")
        fbo = "    const fbo = try gl.Framebuffer.create();\n"
        self.assertEqual(self.source.count(hunk), 1)
        early = self.source.replace(hunk, "", 1).replace(fbo, hunk + fbo, 1)
        problems = gx0045_problems(early)
        self.assertTrue(any("precede the GX-0004 Windows return" in p for p in problems), problems)
        moved = self.source.replace(
            "    self.framebuffer.destroy();\n",
            "    // fork(gx): GX-0045 begin: account for released Windows target resources\n"
            f"    {release}\n    // fork(gx): GX-0045 end\n    self.framebuffer.destroy();\n", 1)
        moved = moved.replace(
            "    self.export_texture.destroy();\n    // fork(gx): GX-0045 begin: account for released Windows target resources\n"
            f"    {release}\n    // fork(gx): GX-0045 end\n",
            "    self.export_texture.destroy();\n", 1)
        self.assertTrue(any("four destroys" in p for p in gx0045_problems(moved)), gx0045_problems(moved))


class RegistryRuleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (ROOT / REGISTRY).read_text(encoding="utf-8")
        cls.patches = parse_registry(cls.text)

    def test_rules_match_the_registry(self):
        self.assertEqual(registry_rule_problems(self.text, self.patches), [])

    def test_stale_rules_are_rejected(self):
        highest = max(patch.id for patch in self.patches)
        count = len({patch.id for patch in self.patches})
        stale = self.text.replace(f"当前最大编号（{highest}）", "当前最大编号（GX-0001）", 1)
        self.assertTrue(any("highest ID" in p for p in registry_rule_problems(stale, self.patches)))
        stale = self.text.replace(f"在册的 {count} 个 ID", f"在册的 {count - 1} 个 ID", 1)
        self.assertTrue(any("the table has" in p for p in registry_rule_problems(stale, self.patches)))
        extra = [*self.patches, Patch("GX-0013", "src/a.zig", "fork(gx): GX-0013", "active")]
        problems = registry_rule_problems(self.text, extra)
        self.assertTrue(any("skipped IDs are registered" in p for p in problems), problems)


REGISTRY_TEMPLATE = """# fork 补丁登记

## 规则

范围：`src/`、`include/`、`pkg/`、`macos/` 与 `build.zig`。

## 登记表

<!-- fork-patches:begin -->
| ID | 文件 | 标记 | 状态 |
|---|---|---|---|
{rows}
<!-- fork-patches:end -->

{sections}
"""


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def write(self, rel: str, text: str, newline: str = "\n") -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.replace("\n", newline).encode("utf-8"))

    def registry(self, rows, sections=None, newline: str = "\n") -> None:
        body = "\n".join(f"| {pid} | `{path}` | `fork(gx): {pid}` | {status} |"
                         for pid, path, status in rows)
        ids = sections if sections is not None else sorted({row[0] for row in rows})
        text = REGISTRY_TEMPLATE.format(
            rows=body, sections="\n\n".join(f"## {pid} 说明\n\n正文。" for pid in ids))
        self.write(REGISTRY, text, newline)

    def test_clean_fixture_passes(self):
        self.registry([("GX-0001", "src/a.zig", "active")])
        self.write("src/a.zig", "// fork(gx): GX-0001 keep\nconst a = 1;\n")
        self.write("src/b.zig", "const b = 2;\n")
        self.assertEqual(check(self.root, ["src/a.zig", "src/b.zig"]), [])

    def test_missing_marker_is_reported(self):
        self.registry([("GX-0001", "src/a.zig", "active")])
        self.write("src/a.zig", "const a = 1;\n")
        problems = check(self.root, ["src/a.zig"])
        self.assertTrue(any("GX-0001" in p and "missing" in p for p in problems), problems)

    def test_missing_registered_file_is_reported(self):
        self.registry([("GX-0001", "src/gone.zig", "active")])
        problems = check(self.root, [])
        self.assertTrue(any("does not exist" in p for p in problems), problems)

    def test_unregistered_marker_is_reported(self):
        self.registry([("GX-0001", "src/a.zig", "active")])
        self.write("src/a.zig", "// fork(gx): GX-0001\n")
        self.write("pkg/x/b.c", "/* fork(gx): GX-0002 new */\n")
        problems = check(self.root, ["src/a.zig", "pkg/x/b.c"])
        self.assertTrue(any(p.startswith("pkg/x/b.c:1:") and "GX-0002" in p for p in problems), problems)

    def test_marker_in_wrong_file_is_reported(self):
        self.registry([("GX-0001", "src/a.zig", "active")])
        self.write("src/a.zig", "const a = 1;\n")
        self.write("macos/B.swift", "// fork(gx): GX-0001\n")
        problems = check(self.root, ["src/a.zig", "macos/B.swift"])
        self.assertTrue(any("missing from src/a.zig" in p for p in problems), problems)
        self.assertTrue(any(p.startswith("macos/B.swift:1:") for p in problems), problems)

    def test_malformed_markers_are_reported(self):
        self.registry([])
        self.write("src/a.zig", "// fork(gx) no id\n// fork(gx): GX-00012 five digits\n")
        problems = check(self.root, ["src/a.zig"])
        self.assertEqual(sum("malformed marker" in p for p in problems), 2, problems)

    def test_removed_patch_must_drop_its_marker(self):
        self.registry([("GX-0001", "src/a.zig", "removed")])
        self.write("src/a.zig", "// fork(gx): GX-0001\n")
        problems = check(self.root, ["src/a.zig"])
        self.assertTrue(any("removed patch still has its marker" in p for p in problems), problems)
        self.write("src/a.zig", "const a = 1;\n")
        self.assertEqual(check(self.root, ["src/a.zig"]), [])

    def test_registered_id_needs_a_section(self):
        self.registry([("GX-0001", "src/a.zig", "active")], sections=[])
        self.write("src/a.zig", "// fork(gx): GX-0001\n")
        problems = check(self.root, ["src/a.zig"])
        self.assertTrue(any("no '## GX-0001' section" in p for p in problems), problems)

    def test_multi_file_patch_uses_one_row_per_file(self):
        self.registry([("GX-0001", "src/a.zig", "active"), ("GX-0001", "include/a.h", "active")])
        self.write("src/a.zig", "// fork(gx): GX-0001\n")
        self.write("include/a.h", "// fork(gx): GX-0001\n")
        self.assertEqual(check(self.root, ["src/a.zig", "include/a.h"]), [])

    def test_crlf_registry_and_sources_are_accepted(self):
        self.registry([("GX-0001", "src/a.zig", "active")], newline="\r\n")
        self.write("src/a.zig", "const a = 1;\n// fork(gx): GX-0001\n", newline="\r\n")
        self.assertEqual(check(self.root, ["src/a.zig"]), [])
        self.assertEqual(find_markers(self.root, ["src/a.zig"]), [("src/a.zig", 2, "GX-0001")])

    def test_css_block_comment_markers(self):
        css = "src/x/style.css"
        self.registry([("GX-0001", css, "active")])
        self.write(css, ".a {\n  /* fork(gx): GX-0001 legacy hsl() syntax */\n  color: hsl(25, 50%, 75%);\n}\n",
                   newline="\r\n")
        self.assertEqual(check(self.root, [css]), [])
        self.assertEqual(find_markers(self.root, [css]), [(css, 2, "GX-0001")])
        self.write(css, "/* fork(gx) legacy syntax */\n/* fork(gx): GX-0002 legacy syntax */\n")
        problems = check(self.root, [css])
        self.assertIn(f"{css}:1: malformed marker, expected 'fork(gx): GX-NNNN'", problems)
        self.assertTrue(any(p.startswith(f"{css}:2: GX-0002 is not registered") for p in problems), problems)
        self.assertTrue(any("GX-0001" in p and "missing" in p for p in problems), problems)

    def test_balanced_hunks_pass(self):
        self.registry([("GX-0001", "build.zig", "active")])
        self.write("build.zig", "const a = 1;\n// fork(gx): GX-0001 begin: add b\nconst b = 2;\n"
                                "// fork(gx): GX-0001 end\n", newline="\r\n")
        self.assertEqual(check(self.root, ["build.zig"]), [])

    def test_unbalanced_hunks_are_reported(self):
        self.registry([("GX-0001", "build.zig", "active")])
        begin, end = "// fork(gx): GX-0001 begin\n", "// fork(gx): GX-0001 end\n"
        cases = {
            "build.zig:1: GX-0001 begin is never closed": begin + "const b = 2;\n",
            "build.zig:2: GX-0001 end without a matching begin": "const b = 2;\n" + end,
            "build.zig:2: GX-0001 begin inside the GX-0001 hunk opened on line 1": begin + begin + end,
        }
        for expected, text in cases.items():
            with self.subTest(expected):
                self.write("build.zig", text)
                self.assertIn(expected, check(self.root, ["build.zig"]))

    def test_missing_registry_is_reported(self):
        self.assertEqual(check(self.root, []), [f"{REGISTRY} is missing"])

    def test_bad_registries_are_rejected(self):
        good = "| GX-0001 | `src/a.zig` | `fork(gx): GX-0001` | active |"
        cases = {
            "no table": "# empty\n",
            "bad header": f"{TABLE_BEGIN}\n| ID | file | marker | status |\n|---|---|---|---|\n{TABLE_END}\n",
            "bad separator": f"{TABLE_BEGIN}\n| ID | 文件 | 标记 | 状态 |\n| x | x | x | x |\n{TABLE_END}\n",
            "bad id": good.replace("GX-0001 |", "GX-1 |", 1),
            "bad marker": good.replace("`fork(gx): GX-0001`", "`fork(gx): GX-0002`"),
            "bad status": good.replace("active", "pending"),
            "absolute path": good.replace("`src/a.zig`", "`/src/a.zig`"),
            "parent path": good.replace("`src/a.zig`", "`src/../a.zig`"),
            "windows path": good.replace("`src/a.zig`", "`src\\a.zig`"),
            "duplicate row": f"{good}\n{good}",
            "missing cell": "| GX-0001 | `src/a.zig` | active |",
        }
        for name, body in cases.items():
            with self.subTest(name):
                text = body if name in ("no table", "bad header", "bad separator") else (
                    f"{TABLE_BEGIN}\n| ID | 文件 | 标记 | 状态 |\n|---|---|---|---|\n{body}\n{TABLE_END}\n")
                with self.assertRaises(ValueError):
                    parse_registry(text)


class Gx0034ShapeTests(unittest.TestCase):
    def test_startup_retains_layers_and_samples_after_adw_init(self):
        source = (ROOT / APPLICATION_ZIG).read_text(encoding="utf-8")
        self.assertIn(Patch("GX-0034", APPLICATION_ZIG, "fork(gx): GX-0034", "active"),
                      parse_registry((ROOT / REGISTRY).read_text(encoding="utf-8")))
        self.assertEqual(source.count("var gx_defaults: gx_gtk.defaults.Startup = .{};"), 1)
        self.assertEqual(source.count("defer gx_defaults.deinit();"), 1)
        self.assertEqual(source.count("gx_defaults.load(alloc)"), 1)
        self.assertEqual(source.count("gx_defaults.initialized(alloc, &config);"), 1)
        self.assertLess(source.index("gx_defaults.load(alloc)"), source.index("adw.init();"))
        self.assertLess(source.index("adw.init();"), source.index("gx_defaults.initialized(alloc, &config);"))
        reload = source.split("// Hard reload, load a new config completely.", 1)[1]
        self.assertLess(reload.index("gx_gtk.defaults.sampleSystemCursorBlink();"),
                        reload.index("CoreConfig.load(alloc)"))
        replacement = ("        // fork(gx): GX-0034 load before GTK without reading GtkSettings\n"
                       "        var config = gx_defaults.load(alloc)")
        self.assertEqual(source.count(replacement), 1)
        restored = source.replace(replacement, "        var config = CoreConfig.load(alloc)")
        stripped, hunks = marked_hunks(restored, "GX-0034")
        self.assertEqual(len(hunks), 3)
        self.assertNotIn("sampleSystemCursorBlink()", stripped)


if __name__ == "__main__":
    unittest.main()
