"""Tests for scripts/gx_i18n.py (the Ghostty GX zh-CN translation table generator).

Run from the repo root:

    python -m unittest scripts.test_gx_i18n -v
"""
from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gx_i18n  # noqa: E402

UPSTREAM = """\
# Upstream header comment
msgid ""
msgstr ""
"Language: zh_CN\\n"
"Plural-Forms: nplurals=1; plural=0;\\n"

#: src/a.zig:1
msgid "New Tab"
msgstr "新建标签页"

msgid "Close"
msgstr "关闭"

#, fuzzy
msgid "Fuzzy Entry"
msgstr "模糊"

msgid "Untranslated"
msgstr ""

msgctxt "menu"
msgid "Close"
msgstr "关闭菜单"

msgid ""
"Multi "
"line"
msgstr ""
"多"
"行"

msgid "{n} tab"
msgid_plural "{n} tabs"
msgstr[0] "{n} 个标签页"

#~ msgid "Obsolete"
#~ msgstr "废弃"
"""

FORK = """\
msgid ""
msgstr ""
"Language: zh_CN\\n"

msgid "New Tab"
msgstr "新标签"

msgid "Settings…"
msgstr "设置…"

msgid "WSL: {name}"
msgstr "WSL：{name}"

msgid "Untranslated"
msgstr ""
"""


def write_repo(root: Path, upstream: str = UPSTREAM, fork: str = FORK, newline: str = "\n") -> None:
    for rel, text in ((gx_i18n.UPSTREAM_PO, upstream), (gx_i18n.FORK_PO, fork)):
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.replace("\n", newline).encode("utf-8"))


def run_main(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = gx_i18n.main(list(argv))
    return code, out.getvalue(), err.getvalue()


def entries_of(rendered: str) -> list[str]:
    return [line for line in rendered.splitlines() if line.startswith("    .{ .key = ")]


class ParseTests(unittest.TestCase):
    def test_entries_flags_and_continuations(self):
        entries = gx_i18n.parse_po(UPSTREAM, "upstream.po")
        by_key = {(e.msgctxt, e.msgid): e for e in entries}
        self.assertEqual(by_key[(None, "New Tab")].msgstr, {0: "新建标签页"})
        self.assertIn("fuzzy", by_key[(None, "Fuzzy Entry")].flags)
        self.assertEqual(by_key[("menu", "Close")].msgstr, {0: "关闭菜单"})
        self.assertEqual(by_key[(None, "Multi line")].msgstr, {0: "多行"})
        plural = by_key[(None, "{n} tab")]
        self.assertEqual(plural.msgid_plural, "{n} tabs")
        self.assertEqual(plural.msgstr, {0: "{n} 个标签页"})
        self.assertTrue(by_key[(None, "Obsolete")].obsolete)
        self.assertFalse(by_key[(None, "New Tab")].obsolete)

    def test_crlf_and_entries_without_blank_lines(self):
        text = 'msgid "A"\r\nmsgstr "甲"\r\nmsgid "B"\r\nmsgstr "乙"\r\n'
        entries = gx_i18n.parse_po(text, "x.po")
        self.assertEqual([(e.msgid, e.msgstr[0]) for e in entries], [("A", "甲"), ("B", "乙")])

    def test_escapes(self):
        text = 'msgid "a\\tb\\n\\"q\\" \\\\ \\101 \\x42"\nmsgstr "ok"\n'
        (entry,) = gx_i18n.parse_po(text, "x.po")
        self.assertEqual(entry.msgid, 'a\tb\n"q" \\ A B')

    def test_syntax_errors(self):
        cases = {
            "unknown escape": 'msgid "a\\q"\nmsgstr "b"\n',
            "unquoted": "msgid a\nmsgstr b\n",
            "continuation": '"orphan"\n',
            "no msgstr": 'msgid "a"\n',
            "msgstr first": 'msgstr "b"\n',
            "plural mismatch": 'msgid "a"\nmsgstr[0] "b"\n',
            "unescaped quote": 'msgid "a"b"\nmsgstr "c"\n',
        }
        for name, text in cases.items():
            with self.subTest(name):
                with self.assertRaises(gx_i18n.PoError):
                    gx_i18n.parse_po(text, "bad.po")


class TableTests(unittest.TestCase):
    def test_table_skips_header_fuzzy_empty_and_obsolete(self):
        table = gx_i18n.table_from(gx_i18n.parse_po(UPSTREAM, "u.po"), "u.po")
        self.assertEqual(table["New Tab"], "新建标签页")
        self.assertEqual(table["Close"], "关闭")
        self.assertEqual(table["menu\x04Close"], "关闭菜单")
        self.assertEqual(table["{n} tab"], "{n} 个标签页")
        self.assertEqual(table["{n} tabs"], "{n} 个标签页")
        for missing in ("", "Fuzzy Entry", "Untranslated", "Obsolete"):
            self.assertNotIn(missing, table)

    def test_plural_alias_does_not_override_singular(self):
        text = ('msgid "tab"\nmsgid_plural "tabs"\nmsgstr[0] "标签页（复数）"\n\n'
                'msgid "tabs"\nmsgstr "标签页们"\n')
        table = gx_i18n.table_from(gx_i18n.parse_po(text, "x.po"), "x.po")
        self.assertEqual(table["tabs"], "标签页们")

    def test_duplicate_msgid_is_rejected(self):
        text = 'msgid "a"\nmsgstr "1"\n\nmsgid "a"\nmsgstr "2"\n'
        with self.assertRaisesRegex(gx_i18n.PoError, "duplicate msgid"):
            gx_i18n.table_from(gx_i18n.parse_po(text, "x.po"), "x.po")

    def test_fork_entries_override_upstream(self):
        upstream = gx_i18n.table_from(gx_i18n.parse_po(UPSTREAM, "u.po"), "u.po")
        fork = gx_i18n.table_from(gx_i18n.parse_po(FORK, "f.po"), "f.po")
        merged = gx_i18n.merge(upstream, fork)
        self.assertEqual(merged["New Tab"], "新标签")
        self.assertEqual(merged["Close"], "关闭")
        self.assertEqual(merged["Settings…"], "设置…")
        self.assertNotIn("Untranslated", merged)

    def test_placeholder_mismatch_is_reported(self):
        problems = gx_i18n.placeholder_problems({"WSL: {name}": "WSL：{distro}", "{a}/{b}": "{b}/{a}"}, "f.po")
        self.assertEqual(len(problems), 1)
        self.assertIn("WSL: {name}", problems[0])


class RenderTests(unittest.TestCase):
    def test_sorted_by_utf8_bytes_and_unique(self):
        table = {"b": "乙", "a": "甲", "Z": "大", "é": "e", "a\x04ctx": "上下文"}
        keys = [line.split('"')[1] for line in entries_of(gx_i18n.render(table))]
        self.assertEqual(keys, sorted(keys, key=lambda k: k.encode("utf-8")))
        self.assertEqual(len(keys), len(set(keys)))
        self.assertEqual(len(keys), len(table))

    def test_zig_string_escapes(self):
        self.assertEqual(gx_i18n.zig_string('a"b\\c\nd\te\r'), '"a\\"b\\\\c\\nd\\te\\r"')
        self.assertEqual(gx_i18n.zig_string("\x04\x7f"), '"\\x04\\x7f"')
        self.assertEqual(gx_i18n.zig_string("\u2028\u0085\ufeff"), '"\\u{2028}\\u{85}\\u{feff}"')
        self.assertEqual(gx_i18n.zig_string("中文…"), '"中文…"')

    def test_render_is_deterministic_and_order_independent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_repo(root)
            first = gx_i18n.build(root)
            self.assertEqual(first, gx_i18n.build(root))
            blocks = UPSTREAM.split("\n\n")
            write_repo(root, upstream="\n\n".join([blocks[0], *reversed(blocks[1:])]) + "\n")
            self.assertEqual(first, gx_i18n.build(root))
            write_repo(root, newline="\r\n")
            self.assertEqual(first, gx_i18n.build(root))
        self.assertTrue(first.endswith("};\n"))
        self.assertNotIn("\r", first)


class MainTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        write_repo(self.root)
        self.output = self.root / gx_i18n.OUTPUT

    def test_check_reports_missing_then_stale_then_fresh(self):
        self.assertEqual(run_main("--check", "--root", str(self.root))[0], 1)
        self.assertEqual(run_main("--root", str(self.root))[0], 0)
        self.assertTrue(self.output.read_bytes().endswith(b"};\n"))
        self.assertNotIn(b"\r\n", self.output.read_bytes())
        self.assertEqual(run_main("--check", "--root", str(self.root))[0], 0)

        write_repo(self.root, fork=FORK + '\nmsgid "Quit"\nmsgstr "退出"\n')
        code, _, err = run_main("--check", "--root", str(self.root))
        self.assertEqual(code, 1)
        self.assertIn(gx_i18n.OUTPUT, err)
        self.assertEqual(run_main("--root", str(self.root))[0], 0)
        self.assertEqual(run_main("--check", "--root", str(self.root))[0], 0)

    def test_write_is_idempotent(self):
        self.assertEqual(run_main("--root", str(self.root))[0], 0)
        before = self.output.stat().st_mtime_ns
        code, out, _ = run_main("--root", str(self.root))
        self.assertEqual(code, 0)
        self.assertEqual(before, self.output.stat().st_mtime_ns)
        self.assertIn("无变化", out)

    def test_crlf_checkout_of_the_table_is_fresh(self):
        self.assertEqual(run_main("--root", str(self.root))[0], 0)
        self.output.write_bytes(self.output.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(run_main("--check", "--root", str(self.root))[0], 0)

    def test_invalid_sources_exit_2(self):
        write_repo(self.root, fork='msgid "WSL: {name}"\nmsgstr "WSL"\n')
        code, _, err = run_main("--check", "--root", str(self.root))
        self.assertEqual(code, 2)
        self.assertIn("placeholders", err)

        write_repo(self.root, fork='msgid "broken\n')
        self.assertEqual(run_main("--root", str(self.root))[0], 2)

        (self.root / gx_i18n.FORK_PO).unlink()
        code, _, err = run_main("--check", "--root", str(self.root))
        self.assertEqual(code, 2)
        self.assertIn("missing", err)
        self.assertFalse(self.output.exists())


class RealRepoTests(unittest.TestCase):
    def test_committed_table_is_fresh(self):
        code, _, err = run_main("--check")
        self.assertEqual(code, 0, err)

    def test_fork_po_has_no_placeholder_problems(self):
        fork = gx_i18n.table_from(gx_i18n.read_po(gx_i18n.REPO_ROOT, gx_i18n.FORK_PO), gx_i18n.FORK_PO)
        self.assertEqual(gx_i18n.placeholder_problems(fork, gx_i18n.FORK_PO), [])
        for msgid in ("Settings", "Language", "New Tab", "WSL: {name}", "{current}/{total}", "OK"):
            self.assertIn(msgid, fork)


if __name__ == "__main__":
    unittest.main()
