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

GTK_CSS = "src/apprt/gtk/css/style.css"
CSS_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
CSS_GRADIENT_RE = re.compile(r"\b(?:repeating-)?(?:linear|radial|conic)-gradient\(")
CSS_RGB_HSL_RE = re.compile(r"\b(?:rgba?|hsla?)\(")
CSS_GTK416_RE = re.compile(r"\b(?:color-mix|color|hwb|lab|lch|oklab|oklch|var)\(")
CSS_DIMENSION_RE = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:%|[a-z]+)?")


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
    """Shape lock for GX-0023: CSS outside comments that GTK 4.14 cannot parse.

    GTK drops such a declaration and logs a theme parser error. Color
    transition hints in gradients parse from GTK 4.20 on; the space-separated
    rgb()/hsl() syntax, color-mix(), the newer color functions and var()
    from GTK 4.16 on.
    """
    css = CSS_COMMENT_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), source)
    problems: list[str] = []

    def line(offset: int) -> int:
        return css.count("\n", 0, offset) + 1

    for match in CSS_GTK416_RE.finditer(css):
        problems.append(f"line {line(match.start())}: {match.group()} needs GTK 4.16")
    for match in CSS_RGB_HSL_RE.finditer(css):
        if len(css_call_args(css, match.end() - 1)) == 1:
            problems.append(f"line {line(match.start())}: {match.group()} without commas needs GTK 4.16")
    for match in CSS_GRADIENT_RE.finditer(css):
        for arg in css_call_args(css, match.end() - 1)[1:]:
            if CSS_DIMENSION_RE.fullmatch(arg):
                problems.append(f"line {line(match.start())}: color hint {arg!r} needs GTK 4.20")
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


if __name__ == "__main__":
    unittest.main()
