"""锁定 scripts/gx_icon.py 与已提交的 dist/windows/gx/ghostty-gx.ico：像素一致、尺寸齐全、格式兼容。"""

from __future__ import annotations

import io
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gx_icon  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


class CommittedIconTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = (ROOT / gx_icon.ICON).read_bytes()
        cls.images = gx_icon.decode_ico(cls.data)

    def test_committed_icon_matches_the_generator(self) -> None:
        with redirect_stdout(io.StringIO()):
            self.assertEqual(gx_icon.main(["--check"]), 0)

    def test_every_size_is_present_once(self) -> None:
        (count,) = struct.unpack("<H", self.data[4:6])
        self.assertEqual(count, len(gx_icon.SIZES))
        self.assertEqual(sorted(self.images), list(gx_icon.SIZES))

    def test_only_the_largest_size_is_png(self) -> None:
        for i in range(len(gx_icon.SIZES)):
            width, _, _, _, planes, bits, size, offset = struct.unpack("<BBBBHHII", self.data[6 + 16 * i:22 + 16 * i])
            dim = width or 256
            self.assertEqual((planes, bits), (1, 32))
            is_png = self.data[offset:offset + size].startswith(gx_icon.PNG_SIGNATURE)
            self.assertEqual(is_png, dim >= gx_icon.PNG_MIN_SIZE, dim)

    def test_corners_are_transparent_and_the_center_is_opaque(self) -> None:
        for size, rgba in self.images.items():
            with self.subTest(size=size):
                self.assertEqual(rgba[3], 0)
                center = ((size // 2) * size + size // 2) * 4
                self.assertEqual(rgba[center + 3], 255)

    def test_small_sizes_omit_the_mark(self) -> None:
        self.assertIsNone(gx_icon.Layout(gx_icon.SMALL_MAX_SIZE).mark)
        self.assertIsNotNone(gx_icon.Layout(48).mark)


class GeneratorTest(unittest.TestCase):
    def run_main(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = gx_icon.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_write_is_idempotent_and_check_detects_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertEqual(self.run_main("--root", str(root), "--check")[0], 1)
            self.assertEqual(self.run_main("--root", str(root))[0], 0)
            target = root / gx_icon.ICON
            first = target.read_bytes()
            code, out, _ = self.run_main("--root", str(root))
            self.assertEqual(code, 0)
            self.assertIn("unchanged", out)
            self.assertEqual(target.read_bytes(), first)
            self.assertEqual(self.run_main("--root", str(root), "--check")[0], 0)

            images = gx_icon.decode_ico(first)
            pixel = bytearray(images[32])
            pixel[(16 * 32 + 16) * 4] ^= 0xFF
            images[32] = bytes(pixel)
            target.write_bytes(gx_icon.encode_ico(images))
            code, _, err = self.run_main("--root", str(root), "--check")
            self.assertEqual(code, 1)
            self.assertIn("stale", err)

            target.write_bytes(b"not an icon")
            self.assertEqual(self.run_main("--root", str(root), "--check")[0], 1)

    def test_png_previews(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root, previews = Path(temp) / "repo", Path(temp) / "png"
            self.assertEqual(self.run_main("--root", str(root), "--png", str(previews))[0], 0)
            for size in gx_icon.SIZES:
                dim, rgba = gx_icon.decode_png((previews / f"ghostty-gx-{size}.png").read_bytes())
                self.assertEqual((dim, rgba), (size, gx_icon.render(size)))

    def test_bmp_round_trip_keeps_pixels_and_masks_transparency(self) -> None:
        rgba = gx_icon.render(16)
        blob = gx_icon.encode_bmp(16, rgba)
        self.assertEqual(gx_icon.decode_bmp(blob), (16, rgba))
        mask = blob[40 + 16 * 16 * 4:]
        self.assertEqual(len(mask), 16 * 4)
        # The bottom-left pixel is a transparent corner: first bit of the first (bottom) mask row.
        self.assertTrue(mask[0] & 0x80)


if __name__ == "__main__":
    unittest.main()
