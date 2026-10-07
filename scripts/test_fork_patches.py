"""Lock tests for the fork patch registry in docs/FORK_PATCHES.md.

The registry table is the closed set of ``fork(gx)`` markers in upstream
source (src/, include/, pkg/, macos/ and build.zig). Run from the repo root:

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


class RealRepoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry_text = (ROOT / REGISTRY).read_text(encoding="utf-8")
        cls.patches = parse_registry(cls.registry_text)

    def test_registry_lists_gx0001_as_active(self):
        self.assertIn(Patch("GX-0001", CONFIG_ZIG, GX0001_MARKER, "active"), self.patches)

    def test_registry_documents_the_scanned_scope(self):
        rules = self.registry_text.split("## 规则", 1)[1].split("\n## ", 1)[0]
        for scope in ("`src/`", "`include/`", "`pkg/`", "`macos/`", "`build.zig`"):
            self.assertIn(scope, rules)

    def test_scan_lists_only_git_visible_files_in_scope(self):
        files = git_visible_files(ROOT, SCAN_PATHSPECS)
        self.assertIn(CONFIG_ZIG, files)
        self.assertIn("build.zig", files)
        for path in files:
            self.assertTrue(path == "build.zig" or path.split("/", 1)[0] in SCAN_PATHSPECS, path)

    def test_markers_registered_and_closed(self):
        self.assertEqual(check(ROOT), [])

    def test_config_zig_keeps_the_gx0001_guard(self):
        source = (ROOT / CONFIG_ZIG).read_text(encoding="utf-8")
        self.assertEqual(gx0001_problems(source), [])


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
        for ref in ("main", "origin/main", "upstream/main"):
            base = subprocess.run(["git", "-C", str(ROOT), "merge-base", "HEAD", ref],
                                  capture_output=True)
            if base.returncode == 0:
                break
        else:
            self.skipTest("no upstream mirror branch (main) available to compare against")
        commit = base.stdout.decode("ascii").strip()
        shown = subprocess.run(["git", "-C", str(ROOT), "show", f"{commit}:{CONFIG_ZIG}"],
                               capture_output=True)
        if shown.returncode != 0:
            self.skipTest(f"{CONFIG_ZIG} is not readable at merge base {commit}")
        upstream = shown.stdout.decode("utf-8").replace("\r\n", "\n")
        if "fork(gx)" in upstream:
            self.skipTest("merge base already contains fork patches")
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
