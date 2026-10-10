#!/usr/bin/env python3
"""The fork's Zig test roots list every file below them that declares a test.

Zig only runs the tests of files whose namespace the compiler happens to analyze. A file
that no `test` block imports drops out of `ghostty-test` silently as soon as the code that
analyzed it by accident changes. Each fork test root therefore imports, from its own
`test {}` block, every Zig file in its directory tree with a top-level test:

- `src/apprt/win32.zig` for `src/apprt/win32/**` (reached from `src/apprt.zig`'s test
  block through `runtime`, which is `win32` in Windows app builds);
- `src/gx/main.zig` for `src/gx/**` (reached from the GX-0010 test block of
  `src/config/Config.zig`);
- `src/apprt/gtk/gx/main.zig` for `src/apprt/gtk/gx/**`. Upstream GTK has no test
  block that imports it; it is reached through the analysis of `class/application.zig`, and
  the `gtk-smoke` job's `--filter apprt.gtk.gx` run (zero matches exit 2) guards that.

Run from the repo root: python scripts/run_unittests.py test_gx_test_roots
"""

from __future__ import annotations

import re
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class ZigTestRoot:
    root: str  # the Zig file whose `test {}` block lists the files
    scope: str  # the directory whose files it must list


ROOTS = (
    ZigTestRoot("src/apprt/win32.zig", "src/apprt/win32"),
    ZigTestRoot("src/gx/main.zig", "src/gx"),
    ZigTestRoot("src/apprt/gtk/gx/main.zig", "src/apprt/gtk/gx"),
)

# A top-level test declaration: `test "name" {`, `test name {` (decltest), `test @"x" {` or `test {`.
TEST_DECL_RE = re.compile(r'^test(?:\s+(?:"(?:[^"\\\n]|\\.)*"|@"(?:[^"\\\n]|\\.)*"|[A-Za-z_]\w*))?\s*\{', re.M)
TEST_BLOCK_RE = re.compile(r"^test\b[^\n]*\{[ \t]*$", re.M)
IMPORT_REF_RE = re.compile(r'_\s*=\s*@import\("([^"]+)"\)\s*;')
NAME_REF_RE = re.compile(r"_\s*=\s*([A-Za-z_]\w*)\s*;")
REF_ALL_DECLS_RE = re.compile(r"refAllDecls\(\s*@This\(\)\s*\)")
IMPORT_DECL_RE = re.compile(r'^(?:pub\s+)?const\s+([A-Za-z_]\w*)\s*=\s*@import\("([^"]+\.zig)"\)\s*;', re.M)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def has_tests(source: str) -> bool:
    """Whether a Zig file declares a test at the top level (zig fmt puts those in column 0)."""
    return TEST_DECL_RE.search(source.replace("\r\n", "\n")) is not None


def test_blocks(source: str) -> list[str]:
    """Bodies of the top-level test blocks: from `test ... {` to the next `}` in column 0."""
    source = source.replace("\r\n", "\n")
    bodies = []
    for match in TEST_BLOCK_RE.finditer(source):
        end = source.find("\n}", match.end())
        bodies.append(source[match.end():len(source) if end < 0 else end])
    return bodies


def top_level_imports(source: str) -> dict[str, str]:
    """`const name = @import("x.zig");` declarations at the top level: name -> path."""
    return {name: path for name, path in IMPORT_DECL_RE.findall(source.replace("\r\n", "\n"))}


def referenced_files(path: Path) -> tuple[set[Path], list[str]]:
    """Files the test blocks of `path` import, resolved against its directory, plus problems."""
    source = read(path)
    imports = top_level_imports(source)
    resolved: set[Path] = set()
    problems: list[str] = []
    for body in test_blocks(source):
        targets = list(IMPORT_REF_RE.findall(body))
        for name in NAME_REF_RE.findall(body):
            if name in imports:
                targets.append(imports[name])
        if REF_ALL_DECLS_RE.search(body):
            targets.extend(imports.values())
        for target in targets:
            if not target.endswith(".zig"):
                continue
            file = (path.parent / target).resolve()
            if not file.is_file():
                problems.append(f"{path.name}: the test block imports {target}, which does not exist")
            resolved.add(file)
    return resolved, problems


def files_with_tests(scope: Path) -> list[Path]:
    return sorted(file.resolve() for file in scope.rglob("*.zig") if has_tests(read(file)))


def root_problems(repo: Path, test_root: ZigTestRoot) -> list[str]:
    root = repo / test_root.root
    scope = repo / test_root.scope
    if not root.is_file():
        return [f"{test_root.root} is missing"]
    if not scope.is_dir():
        return [f"{test_root.scope} is missing"]
    referenced, problems = referenced_files(root)
    for file in files_with_tests(scope):
        if file == root.resolve() or file in referenced:
            continue
        relative = Path(file).relative_to(root.parent.resolve()).as_posix()
        problems.append(
            f"{Path(file).relative_to(repo.resolve()).as_posix()} has tests that no test block imports: "
            f'add `_ = @import("{relative}");` to the test block of {test_root.root}'
        )
    return problems


class RealRepoTests(unittest.TestCase):
    def test_every_file_with_tests_is_imported_by_its_root(self):
        for test_root in ROOTS:
            with self.subTest(root=test_root.root):
                self.assertEqual(root_problems(ROOT, test_root), [])

    def test_each_scope_has_tested_files(self):
        for test_root in ROOTS:
            with self.subTest(root=test_root.root):
                self.assertGreater(len(files_with_tests(ROOT / test_root.scope)), 2)

    def test_win32_root_is_reached_through_the_runtime(self):
        source = read(ROOT / "src/apprt.zig")
        self.assertIn('pub const win32 = @import("apprt/win32.zig");', source)
        self.assertRegex(source, r"\.win32\s*=>\s*win32,")
        self.assertTrue(any("_ = runtime;" in body for body in test_blocks(source)))

    def test_gx_root_is_imported_by_the_config_test_block(self):
        referenced, problems = referenced_files(ROOT / "src/config/Config.zig")
        self.assertEqual(problems, [])
        self.assertIn((ROOT / "src/gx/main.zig").resolve(), referenced)


class ParserTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, rel: str, text: str, newline: str = "\n") -> None:
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.replace("\n", newline).encode("utf-8"))

    def test_test_declarations(self):
        for text in ('test "a b" {\n}\n', "test {\n}\n", "test premultiplied {\n}\n", 'test @"x y" {\n}\n',
                     'const a = 1;\ntest "x" {}\n'):
            with self.subTest(text=text):
                self.assertTrue(has_tests(text))
                self.assertTrue(has_tests(text.replace("\n", "\r\n")))
        for text in ('    test "nested" {\n    }\n', '// test "x" {\n', '    \\\\test "x" {\n',
                     "const testing = @import(\"std\").testing;\n", "fn test_x() void {}\n"):
            with self.subTest(text=text):
                self.assertFalse(has_tests(text))

    def test_imports_names_and_ref_all_decls(self):
        self.write("root.zig", "\n".join((
            'pub const a = @import("dir/a.zig");',
            'const b = @import("dir/b.zig");',
            'const std = @import("std");',
            "",
            "test {",
            '    _ = @import("dir/c.zig");',
            "    _ = b;",
            "    _ = std;",
            "}",
            "",
        )), newline="\r\n")
        for name in ("a", "b", "c"):
            self.write(f"dir/{name}.zig", 'test "t" {}\n')
        referenced, problems = referenced_files(self.repo / "root.zig")
        self.assertEqual(problems, [])
        self.assertEqual(referenced, {(self.repo / f"dir/{name}.zig").resolve() for name in ("b", "c")})
        self.write("root.zig", 'pub const a = @import("dir/a.zig");\n\ntest {\n    std.testing.refAllDecls(@This());\n}\n')
        self.assertEqual(referenced_files(self.repo / "root.zig")[0], {(self.repo / "dir/a.zig").resolve()})

    def test_missing_and_stale_files_are_reported(self):
        self.write("root.zig", 'test {\n    _ = @import("dir/a.zig");\n    _ = @import("dir/gone.zig");\n}\n')
        self.write("dir/a.zig", 'test "a" {}\n')
        self.write("dir/sub/b.zig", "test decl {}\n")
        self.write("dir/c.zig", "pub fn f() void {}\n")
        problems = root_problems(self.repo, ZigTestRoot("root.zig", "dir"))
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("root.zig: the test block imports dir/gone.zig, which does not exist", problems)
        self.assertTrue(problems[1].startswith("dir/sub/b.zig has tests"), problems)
        self.assertIn('`_ = @import("dir/sub/b.zig");`', problems[1])

    def test_root_inside_its_scope_is_not_required_to_import_itself(self):
        self.write("gx/main.zig", 'pub const a = @import("a.zig");\n\ntest {\n    _ = a;\n}\n\ntest "own" {}\n')
        self.write("gx/a.zig", 'test "a" {}\n')
        self.assertEqual(root_problems(self.repo, ZigTestRoot("gx/main.zig", "gx")), [])
        self.write("gx/b.zig", 'test "b" {}\n')
        self.assertEqual(len(root_problems(self.repo, ZigTestRoot("gx/main.zig", "gx"))), 1)

    def test_a_test_block_outside_column_zero_is_not_a_root_block(self):
        self.write("root.zig", 'const S = struct {\n    test {\n        _ = @import("dir/a.zig");\n    }\n};\n')
        self.write("dir/a.zig", 'test "a" {}\n')
        self.assertEqual(len(root_problems(self.repo, ZigTestRoot("root.zig", "dir"))), 1)


if __name__ == "__main__":
    unittest.main()
