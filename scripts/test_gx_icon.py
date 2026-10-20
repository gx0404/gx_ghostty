"""锁定 scripts/gx_icon.py 与已提交的 dist/windows/gx/ghostty-gx.ico、dist/linux/gx/icons/*.png：
像素一致、尺寸齐全、格式兼容，加速渲染与逐像素定义逐字节相同，Linux 尺寸覆盖 GTK gresource。"""

from __future__ import annotations

import io
import re
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

    def test_linux_icons_are_square_rgba_pngs_of_their_size(self) -> None:
        for size in gx_icon.LINUX_SIZES:
            with self.subTest(size=size):
                dim, rgba = gx_icon.decode_png((ROOT / gx_icon.linux_icon(size)).read_bytes())
                self.assertEqual(dim, size)
                self.assertEqual(len(rgba), size * size * 4)
                self.assertEqual(rgba[3], 0)
                center = ((size // 2) * size + size // 2) * 4
                self.assertEqual(rgba[center + 3], 255)

    def test_linux_sizes_cover_the_gtk_resources(self) -> None:
        # GX-0058: the GTK gresource embeds icon_sizes at 1x and 2x from dist/linux/gx/icons/.
        text = (ROOT / "src/apprt/gtk/build/gresource.zig").read_text(encoding="utf-8")
        match = re.search(r"pub const icon_sizes: \[\]const comptime_int = &\.\{([^}]*)\};", text)
        self.assertIsNotNone(match)
        sizes = [int(value) for value in match.group(1).split(",") if value.strip()]
        self.assertTrue(sizes)
        for size in sizes:
            self.assertIn(size, gx_icon.LINUX_SIZES)
            self.assertIn(size * 2, gx_icon.LINUX_SIZES)
        source = f'"{gx_icon.LINUX_ICONS.as_posix()}/{{d}}.png"'
        self.assertEqual(text.count(source), 4, "file_inputs and genIcons read 1x and 2x from the GX icons")
        self.assertNotIn('"images/gnome/', text)


class RenderTest(unittest.TestCase):
    def test_traced_rendering_matches_the_per_pixel_definition(self) -> None:
        # 64 and 128 exercise the full design (mark, rim and cursor); the small layout differs.
        for size in (16, 32, 48, 64, 128):
            with self.subTest(size=size):
                self.assertEqual(gx_icon.render(size), gx_icon.render_reference(size))

    def test_trace_classifies_only_pixels_inside_a_band(self) -> None:
        # A distance that falls by one per pixel: 0.0 at column 3, outside before, inside after.
        runs = gx_icon.trace(lambda px, py: 3.5 - px, 0.5, 8, gx_icon.SHAPE_BANDS)
        self.assertEqual([run[0] for run in runs], sorted(run[0] for run in runs))
        self.assertEqual(runs[0][0], 0)
        self.assertEqual(runs[-1][1], 8)
        for (_, end, _), (start, _, _) in zip(runs, runs[1:]):
            self.assertEqual(end, start)
        expanded = {}
        for start, end, value in runs:
            for x in range(start, end):
                expanded[x] = value
        self.assertEqual(expanded[0], gx_icon.OUTSIDE)
        self.assertEqual(expanded[3], 0.0)
        self.assertEqual(expanded[7], gx_icon.INSIDE)
        # 0.0 is a distance, not a band label: classified and exact pixels must never collide.
        self.assertNotEqual(expanded[3], gx_icon.INSIDE)


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
            target.write_bytes(first)

            linux = root / gx_icon.linux_icon(64)
            dim, rgba = gx_icon.decode_png(linux.read_bytes())
            pixel = bytearray(rgba)
            pixel[(32 * 64 + 32) * 4 + 1] ^= 0xFF
            linux.write_bytes(gx_icon.encode_png(dim, bytes(pixel)))
            code, _, err = self.run_main("--root", str(root), "--check")
            self.assertEqual(code, 1)
            self.assertIn(f"{gx_icon.linux_icon(64).as_posix()} is stale", err)

            (root / gx_icon.linux_icon(2048)).unlink()
            code, _, err = self.run_main("--root", str(root), "--check")
            self.assertEqual(code, 1)
            self.assertIn(f"{gx_icon.linux_icon(2048).as_posix()}: cannot read the icon", err)

            code, out, _ = self.run_main("--root", str(root))
            self.assertEqual(code, 0)
            self.assertIn(f"wrote {gx_icon.linux_icon(64).as_posix()}", out)
            self.assertIn(f"wrote {gx_icon.linux_icon(2048).as_posix()}", out)
            self.assertIn(f"{gx_icon.ICON.as_posix()} unchanged", out)
            self.assertEqual(self.run_main("--root", str(root), "--check")[0], 0)

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
