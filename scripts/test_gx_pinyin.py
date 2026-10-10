"""Tests for scripts/gx_pinyin.py (the pinyin initials table generator).

Run from the repo root:

    python -m unittest scripts.test_gx_pinyin -v
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gx_pinyin  # noqa: E402

PINYIN = """\
# version: 0.15.0
# source: https://github.com/mozillazg/pinyin-data
U+3007: líng,yuán,xīng  # 〇
U+4E00: yī  # 一
U+4E50: lè,yuè  # 乐
U+884C: xíng,háng,héng,xìng,hàng  # 行
U+91CD: zhòng,chóng,tóng  # 重
U+5463: ḿ,m̀,móu  # 呣
U+55EF: ǹg,ńg,ňg  # 嗯
U+9FFF: shì  # 鿿
U+20000: hē  # 𠀀
"""

TGHZ = """\
U+4E50: lè yuè  # 乐
U+884C: háng,héng,xíng  # 行
U+91CD: chóng,zhòng  # 重
"""

XHC = """\
U+884C: háng,hàng,héng,xíng  # 行
"""


def sources(pinyin: str = PINYIN, tghz: str = TGHZ, xhc: str = XHC) -> dict[str, str]:
    return {"pinyin.txt": pinyin, "kTGHZ2013.txt": tghz, "kXHC1983.txt": xhc}


def pins_of(files: dict[str, str]) -> dict[str, str]:
    return {name: hashlib.sha256(text.encode("utf-8")).hexdigest() for name, text in files.items()}


def write_source_dir(root: Path, files: dict[str, str], newline: str = "\n") -> Path:
    root.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (root / name).write_bytes(text.replace("\n", newline).encode("utf-8"))
    return root


def write_tarball(path: Path, files: dict[str, str], top: str = "pinyin-data-0.15.0") -> Path:
    with tarfile.open(path, "w:gz") as archive:
        for name, text in {**files, "README.md": "readme\n"}.items():
            data = text.encode("utf-8")
            info = tarfile.TarInfo(f"{top}/{name}")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return path


def run(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = gx_pinyin.main(argv)
    return code, out.getvalue(), err.getvalue()


class InitialTest(unittest.TestCase):
    def test_tone_marks_and_umlauts_are_dropped(self) -> None:
        self.assertEqual(gx_pinyin.initial_of("zhōng"), "z")
        self.assertEqual(gx_pinyin.initial_of("Lǜ"), "l")
        self.assertEqual(gx_pinyin.initial_of("ḿ"), "m")
        self.assertEqual(gx_pinyin.initial_of("ňg"), "n")
        self.assertEqual(gx_pinyin.initial_of("ê̄"), "e")

    def test_readings_must_start_with_a_letter(self) -> None:
        with self.assertRaises(gx_pinyin.SourceError):
            gx_pinyin.initial_of("1a", "U+4E00")
        with self.assertRaises(gx_pinyin.SourceError):
            gx_pinyin.initial_of("")


class ParseTest(unittest.TestCase):
    def test_comments_separators_and_crlf(self) -> None:
        readings = gx_pinyin.parse_readings("# c\r\nU+4E50: lè, yuè  # 乐\r\n\r\nU+884C: xíng háng\r\n", "t")
        self.assertEqual(readings, {0x4E50: ["lè", "yuè"], 0x884C: ["xíng", "háng"]})

    def test_bad_lines_are_rejected(self) -> None:
        for text in ("4E00: yī\n", "U+4E00:\n", "U+4E00: yī\nU+4E00: yī\n"):
            with self.subTest(text=text), self.assertRaises(gx_pinyin.SourceError):
                gx_pinyin.parse_readings(text, "t")


class TableTest(unittest.TestCase):
    def build(self) -> gx_pinyin.Table:
        files = sources()
        return gx_pinyin.build_table(
            gx_pinyin.parse_readings(files["pinyin.txt"], "pinyin.txt"),
            [gx_pinyin.parse_readings(files[name], name) for name in gx_pinyin.EXTRA_FILES],
        )

    def letter(self, table: gx_pinyin.Table, code_point: int) -> str:
        return table.primary[code_point - gx_pinyin.FIRST]

    def test_primary_is_the_first_reading(self) -> None:
        table = self.build()
        self.assertEqual(len(table.primary), gx_pinyin.LAST - gx_pinyin.FIRST + 1)
        self.assertEqual(self.letter(table, 0x4E00), "y")
        self.assertEqual(self.letter(table, 0x4E50), "l")
        self.assertEqual(self.letter(table, 0x884C), "x")
        self.assertEqual(self.letter(table, 0x91CD), "z")
        self.assertEqual(self.letter(table, 0x9FFF), "s")
        self.assertEqual(self.letter(table, 0x4E01), ".")

    def test_extra_letters_come_from_modern_readings_only(self) -> None:
        table = self.build()
        self.assertEqual(table.extra[0x4E50], "y")
        self.assertEqual(table.extra[0x884C], "h")
        # 重 tóng is only in the full list, not in the modern dictionaries.
        self.assertEqual(table.extra[0x91CD], "c")
        # Other readings of 呣 and 嗯 are not in the modern dictionaries.
        self.assertNotIn(0x5463, table.extra)
        self.assertNotIn(0x55EF, table.extra)
        self.assertNotIn(0x4E00, table.extra)

    def test_code_points_outside_the_block_are_left_out(self) -> None:
        table = self.build()
        self.assertNotIn(0x3007, table.extra)
        self.assertNotIn(0x20000, table.extra)
        self.assertEqual(table.primary.count("."), len(table.primary) - 7)


class RenderTest(unittest.TestCase):
    def test_render_is_deterministic_and_verifies(self) -> None:
        files = sources()
        pins = pins_of(files)
        first = gx_pinyin.generate(files, pins)
        self.assertEqual(first, gx_pinyin.generate(files, pins))
        self.assertTrue(first.startswith("//! Pinyin initials"))
        self.assertTrue(first.endswith("};\n"))
        self.assertNotIn("\r", first)
        self.assertIn('    .{ 0x4E50, "y" }, // 乐\n', first)
        self.assertIn('    .{ 0x91CD, "c" }, // 重\n', first)
        self.assertIn("pub const first = 0x4E00;\n", first)
        lines = [line for line in first.splitlines() if line.startswith('    "')]
        self.assertEqual(len(lines), (gx_pinyin.LAST - gx_pinyin.FIRST + 1) // gx_pinyin.LINE_WIDTH)
        self.assertTrue(lines[0].endswith('" ++ // U+4E00'))
        self.assertTrue(lines[-1].endswith('"; // U+9FC0'))
        self.assertEqual(gx_pinyin.verify(first, pins), [])
        self.assertEqual(gx_pinyin.verify(first.replace("\n", "\r\n"), pins), [])

    def test_verify_finds_edits_and_stale_tables(self) -> None:
        files = sources()
        pins = pins_of(files)
        text = gx_pinyin.generate(files, pins)
        edited = text.replace('.{ 0x4E50, "y" }', '.{ 0x4E50, "x" }')
        self.assertTrue(any("改动" in p for p in gx_pinyin.verify(edited, pins)))
        other_pins = {**pins, "pinyin.txt": "0" * 64}
        self.assertTrue(any("摘要" in p for p in gx_pinyin.verify(text, other_pins)))
        with mock.patch.object(gx_pinyin, "FORMAT", gx_pinyin.FORMAT + 1):
            self.assertTrue(any("格式" in p for p in gx_pinyin.verify(text, pins)))
        no_meta = "\n".join(line for line in text.split("\n") if not line.startswith(gx_pinyin.META_PREFIX))
        self.assertEqual(len(gx_pinyin.verify(no_meta, pins)), 1)


class SourcesTest(unittest.TestCase):
    def test_directory_and_tarball_give_the_same_text(self) -> None:
        files = sources()
        pins = pins_of(files)
        with tempfile.TemporaryDirectory() as tmp:
            directory = write_source_dir(Path(tmp) / "dir", files, newline="\r\n")
            crlf_pins = pins_of({name: text.replace("\n", "\r\n") for name, text in files.items()})
            from_dir = gx_pinyin.read_sources(directory, crlf_pins)
            tarball = write_tarball(Path(tmp) / "data.tar.gz", files)
            from_tar = gx_pinyin.read_sources(tarball, pins)
        self.assertEqual(from_dir, from_tar)
        self.assertEqual(from_tar["pinyin.txt"], PINYIN)

    def test_pins_missing_files_and_bad_archives_are_errors(self) -> None:
        files = sources()
        pins = pins_of(files)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = write_source_dir(root / "dir", files)
            with self.assertRaisesRegex(gx_pinyin.SourceError, "sha256"):
                gx_pinyin.read_sources(directory, {**pins, "kXHC1983.txt": "0" * 64})
            (directory / "kTGHZ2013.txt").unlink()
            with self.assertRaisesRegex(gx_pinyin.SourceError, "kTGHZ2013"):
                gx_pinyin.read_sources(directory, pins)
            partial = write_tarball(root / "partial.tar.gz", {"pinyin.txt": PINYIN})
            with self.assertRaisesRegex(gx_pinyin.SourceError, "kTGHZ2013"):
                gx_pinyin.read_sources(partial, pins)
            nested = write_tarball(root / "nested.tar.gz", files, top="a/b")
            with self.assertRaises(gx_pinyin.SourceError):
                gx_pinyin.read_sources(nested, pins)
            junk = root / "junk.tar.gz"
            junk.write_bytes(b"not a tarball")
            with self.assertRaises(gx_pinyin.SourceError):
                gx_pinyin.read_sources(junk, pins)
            with self.assertRaisesRegex(gx_pinyin.SourceError, "--download"):
                gx_pinyin.read_sources(root / "missing", pins)

    def test_download_keeps_the_pinned_files(self) -> None:
        files = sources()
        pins = pins_of(files)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tarball = write_tarball(root / "data.tar.gz", files)
            cache = root / "cache"
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                gx_pinyin.download(cache, pins, url=tarball.as_uri())
            self.assertTrue(gx_pinyin.has_sources(cache, pins))
            self.assertFalse((cache / "README.md").exists())
            self.assertEqual(gx_pinyin.read_sources(cache, pins)["kXHC1983.txt"], XHC)
            with self.assertRaisesRegex(gx_pinyin.SourceError, "sha256"):
                with contextlib.redirect_stdout(io.StringIO()):
                    gx_pinyin.download(root / "other", {**pins, "pinyin.txt": "0" * 64}, url=tarball.as_uri())
            with self.assertRaises(gx_pinyin.SourceError):
                with contextlib.redirect_stdout(io.StringIO()):
                    gx_pinyin.download(root / "other", pins, url=(root / "missing.tar.gz").as_uri())


class MainTest(unittest.TestCase):
    def setUp(self) -> None:
        self.files = sources()
        patcher = mock.patch.object(gx_pinyin, "SOURCE_FILES", pins_of(self.files))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / gx_pinyin.OUTPUT

    def test_generate_check_and_unchanged(self) -> None:
        source = write_source_dir(self.root / "src-data", self.files)
        code, out, _ = run(["--root", str(self.root), "--source", str(source)])
        self.assertEqual(code, 0)
        self.assertIn("已写入", out)
        self.assertEqual(self.output.read_bytes().count(b"\r"), 0)
        code, out, _ = run(["--root", str(self.root), "--source", str(source)])
        self.assertEqual((code, "无变化" in out), (0, True))
        # Without sources only the digests are checked.
        code, out, _ = run(["--root", str(self.root), "--check"])
        self.assertEqual(code, 0)
        self.assertIn("未重新生成", out)
        code, out, _ = run(["--root", str(self.root), "--check", "--source", str(source)])
        self.assertEqual((code, "是最新的" in out), (0, True))

    def test_check_fails_for_missing_edited_or_stale_tables(self) -> None:
        source = write_source_dir(self.root / "src-data", self.files)
        code, _, err = run(["--root", str(self.root), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("缺失", err)
        run(["--root", str(self.root), "--source", str(source)])
        text = self.output.read_text(encoding="utf-8")
        self.output.write_text(text.replace('"y" }, // 乐', '"x" }, // 乐'), encoding="utf-8", newline="\n")
        code, _, err = run(["--root", str(self.root), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("改动", err)
        # Regenerated from changed sources, the table no longer matches them.
        changed = {**self.files, "kXHC1983.txt": XHC + "U+4E00: yī,qī  # 一\n"}
        changed_source = write_source_dir(self.root / "changed", changed)
        with mock.patch.object(gx_pinyin, "SOURCE_FILES", pins_of(changed)):
            run(["--root", str(self.root), "--source", str(changed_source)])
        code, _, err = run(["--root", str(self.root), "--check", "--source", str(source)])
        self.assertEqual(code, 1)

    def test_check_compares_with_the_cache(self) -> None:
        write_source_dir(self.root / gx_pinyin.CACHE_DIR, self.files)
        self.assertEqual(run(["--root", str(self.root)])[0], 0)
        code, out, _ = run(["--root", str(self.root), "--check"])
        self.assertEqual((code, "是最新的" in out), (0, True))

    def test_source_errors_exit_2(self) -> None:
        code, _, err = run(["--root", str(self.root)])
        self.assertEqual(code, 2)
        self.assertIn("--download", err)
        bad = write_source_dir(self.root / "bad", {**self.files, "pinyin.txt": "garbage\n"})
        with mock.patch.object(gx_pinyin, "SOURCE_FILES", pins_of({**self.files, "pinyin.txt": "garbage\n"})):
            code, _, err = run(["--root", str(self.root), "--source", str(bad)])
        self.assertEqual(code, 2)
        self.assertIn("cannot parse", err)

    def test_download_and_check_do_not_mix(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            gx_pinyin.main(["--root", str(self.root), "--check", "--download"])
        self.assertEqual(raised.exception.code, 2)

    def test_download_only_when_the_cache_is_incomplete(self) -> None:
        cache = self.root / gx_pinyin.CACHE_DIR
        with mock.patch.object(gx_pinyin, "download", side_effect=lambda target: write_source_dir(target, self.files)) as fetch:
            self.assertEqual(run(["--root", str(self.root), "--download"])[0], 0)
            self.assertEqual(fetch.call_count, 1)
            self.assertEqual(fetch.call_args.args[0], cache)
            self.assertEqual(run(["--root", str(self.root), "--download"])[0], 0)
            self.assertEqual(fetch.call_count, 1)


class RealTableTest(unittest.TestCase):
    """The committed table is what this script generates."""

    def test_committed_table_verifies(self) -> None:
        text = (gx_pinyin.REPO_ROOT / gx_pinyin.OUTPUT).read_text(encoding="utf-8")
        self.assertEqual(gx_pinyin.verify(text), [])
        self.assertIn(f"pinyin-data\n//! {gx_pinyin.SOURCE_VERSION}", text)


if __name__ == "__main__":
    unittest.main()
