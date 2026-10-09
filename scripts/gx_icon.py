#!/usr/bin/env python3
"""Ghostty GX 应用图标 dist/windows/gx/ghostty-gx.ico 的生成器（只用 Python 标准库）。

用法：
  python scripts/gx_icon.py              渲染全部尺寸并写入 ico（字节不变时不改文件）
  python scripts/gx_icon.py --check      只读校验：已提交的 ico 与重新渲染的像素逐个比对，不一致退出 1
  python scripts/gx_icon.py --png DIR    另把每个尺寸写成 DIR/ghostty-gx-<尺寸>.png，供审阅
  可选 --root PATH（测试用，默认取脚本所在仓库）

图案：GX Mocha 配色（背景 #1f1f28 与 Catppuccin Mocha 色板）的深色圆角方块，蓝色提示符 `>`；
48 像素及以上在提示符旁画 `GX` 字样与光标，32 像素及以下只画 `>_`，保证 16×16 仍可辨认。
不使用 Ghostty 的幽灵图标。小尺寸按像素网格取整，大尺寸在 256 单位的设计坐标里画；
边缘抗锯齿按像素中心的有符号距离计算，只用 IEEE 精确的四则运算与开方，结果与平台无关。

ico 内含 16、20、24、32、40、48、64、96、128、256 像素：256 像素是 PNG（Windows Vista 起支持），
其余是 32 位 BMP（带 AND 掩码，兼容资源编译器与 Inno Setup）。PNG 的压缩字节可能随 zlib
版本变化，所以 --check 解码后比较像素，不比较文件字节。

退出码：0 成功（或 --check 时一致）；1 --check 时 ico 缺失、无法解析或与渲染不一致；2 用法错误。
"""

from __future__ import annotations

import argparse
import functools
import math
import struct
import sys
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ICON = Path("dist/windows/gx/ghostty-gx.ico")
SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
PNG_MIN_SIZE = 256
SMALL_MAX_SIZE = 32
DESIGN = 256.0

BACKGROUND_TOP = (0x2B, 0x2B, 0x3A)
BACKGROUND_BOTTOM = (0x1A, 0x1A, 0x23)
RIM = (0x3E, 0x40, 0x54)
PROMPT = (0x89, 0xB4, 0xFA)
CURSOR = (0xF5, 0xE0, 0xDC)
MARK = (0xCB, 0xA6, 0xF7)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return low if value < low else high if value > high else value


def length(x: float, y: float) -> float:
    return math.sqrt(x * x + y * y)


def rounded_rect(px: float, py: float, x0: float, y0: float, x1: float, y1: float, radius: float) -> float:
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    qx = abs(px - cx) - ((x1 - x0) / 2 - radius)
    qy = abs(py - cy) - ((y1 - y0) / 2 - radius)
    return length(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - radius


def capsule(px: float, py: float, ax: float, ay: float, bx: float, by: float, half_width: float) -> float:
    dx, dy = bx - ax, by - ay
    t = clamp(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy))
    return length(px - ax - t * dx, py - ay - t * dy) - half_width


def half_plane(px: float, py: float, ox: float, oy: float, nx: float, ny: float) -> float:
    """Signed distance to the half-plane through (ox, oy) whose outward unit normal is (nx, ny)."""
    return (px - ox) * nx + (py - oy) * ny


def letter_g(px: float, py: float, cx: float, cy: float, radius: float, stroke: float) -> float:
    ring = abs(length(px - cx, py - cy) - radius) - stroke / 2
    # The opening on the right: between the horizontal through the center and the ray at 45
    # degrees above it (screen y grows downwards).
    s = math.sqrt(0.5)
    gap = max(half_plane(px, py, cx, cy, 0.0, 1.0), half_plane(px, py, cx, cy, -s, -s))
    arc = max(ring, -gap)
    bar = max(
        half_plane(px, py, cx + radius + stroke / 2, cy, 1.0, 0.0),
        half_plane(px, py, cx + stroke * 0.15, cy, -1.0, 0.0),
        half_plane(px, py, cx, cy - stroke / 2, 0.0, -1.0),
        half_plane(px, py, cx, cy + stroke / 2, 0.0, 1.0),
    )
    return min(arc, bar)


def letter_x(px: float, py: float, x0: float, y0: float, x1: float, y1: float, stroke: float) -> float:
    # Long strokes clipped to the cap height give flat ends on the top and bottom lines.
    dx, dy = (x1 - x0) * 0.25, (y1 - y0) * 0.25
    a = capsule(px, py, x0 - dx, y0 - dy, x1 + dx, y1 + dy, stroke / 2)
    b = capsule(px, py, x1 + dx, y0 - dy, x0 - dx, y1 + dy, stroke / 2)
    band = max(half_plane(px, py, 0.0, y0, 0.0, -1.0), half_plane(px, py, 0.0, y1, 0.0, 1.0))
    return max(min(a, b), band)


class Layout:
    """The shapes of one icon size, in pixel coordinates of that size."""

    def __init__(self, size: int) -> None:
        self.size = size
        self.small = size <= SMALL_MAX_SIZE
        if self.small:
            s = float(size)
            self.margin = 0.0 if size < 32 else 1.0
            self.radius = round(s * 0.22)
            self.rim = 1.0
            stroke = float(max(2, int(s / 8 + 0.5)))
            self.prompt_half = stroke / 2
            # A right angle: 45-degree strokes stay crisp at 16 px.
            top, bottom = s * 0.25, s * 0.75
            apex = top + s / 4
            self.prompt = ((top, top), (apex, s / 2), (top, bottom))
            cursor_bottom = round(bottom + stroke / 2)
            self.cursor = (round(apex + stroke * 0.75 + 1), cursor_bottom - stroke, round(s * 0.85), cursor_bottom)
            self.mark = None
        else:
            k = size / DESIGN
            self.margin = 12.0 * k
            self.radius = 52.0 * k
            self.rim = max(1.0, 4.0 * k)
            self.prompt_half = 11.0 * k
            self.prompt = ((52 * k, 54 * k), (88 * k, 80 * k), (52 * k, 106 * k))
            self.cursor = (100 * k, 104 * k, 144 * k, 117 * k)
            # "GX": the G centered at (91, 172) with a 30-unit radius, the X from 153 to 201.
            self.mark = (91 * k, 172 * k, 30 * k, 18 * k, (153 * k, 133 * k, 201 * k, 211 * k))

    def background(self, px: float, py: float) -> float:
        lo, hi = self.margin, self.size - self.margin
        return rounded_rect(px, py, lo, lo, hi, hi, self.radius)

    def prompt_distance(self, px: float, py: float) -> float:
        (ax, ay), (bx, by), (cx, cy) = self.prompt
        return min(capsule(px, py, ax, ay, bx, by, self.prompt_half), capsule(px, py, bx, by, cx, cy, self.prompt_half))

    def cursor_distance(self, px: float, py: float) -> float:
        x0, y0, x1, y1 = self.cursor
        return rounded_rect(px, py, x0, y0, x1, y1, 0.0 if self.small else (y1 - y0) * 0.25)

    def mark_distance(self, px: float, py: float) -> float:
        assert self.mark is not None
        gx, gy, radius, stroke, (x0, y0, x1, y1) = self.mark
        return min(letter_g(px, py, gx, gy, radius, stroke), letter_x(px, py, x0, y0, x1, y1, stroke))


def coverage(distance: float) -> float:
    """Pixel coverage of a shape whose signed distance (in pixels) at the pixel center is given."""
    return clamp(0.5 - distance)


def over(dst: list[float], color: tuple[float, float, float], alpha: float) -> None:
    """Composite a straight-alpha color over a premultiplied RGBA pixel in place."""
    if alpha <= 0.0:
        return
    for i in range(3):
        dst[i] = color[i] / 255.0 * alpha + dst[i] * (1.0 - alpha)
    dst[3] = alpha + dst[3] * (1.0 - alpha)


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[float, float, float]:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


@functools.cache
def render(size: int) -> bytes:
    """Straight-alpha RGBA rows, top to bottom."""
    layout = Layout(size)
    out = bytearray()
    span = size - 2 * layout.margin
    for y in range(size):
        py = y + 0.5
        shade = lerp(BACKGROUND_TOP, BACKGROUND_BOTTOM, clamp((py - layout.margin) / span))
        for x in range(size):
            px = x + 0.5
            pixel = [0.0, 0.0, 0.0, 0.0]
            edge = layout.background(px, py)
            body = coverage(edge)
            if body > 0.0:
                over(pixel, shade, body)
                over(pixel, RIM, min(body, coverage(-(edge + layout.rim))))
                over(pixel, PROMPT, min(body, coverage(layout.prompt_distance(px, py))))
                over(pixel, CURSOR, min(body, coverage(layout.cursor_distance(px, py))))
                if layout.mark is not None:
                    over(pixel, MARK, min(body, coverage(layout.mark_distance(px, py))))
            alpha = pixel[3]
            if alpha <= 0.0:
                out += b"\x00\x00\x00\x00"
                continue
            out += bytes(int(clamp(pixel[i] / alpha) * 255.0 + 0.5) for i in range(3))
            out.append(int(alpha * 255.0 + 0.5))
    return bytes(out)


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def encode_png(size: int, rgba: bytes) -> bytes:
    stride = size * 4
    raw = b"".join(b"\x00" + rgba[row * stride:(row + 1) * stride] for row in range(size))
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (PNG_SIGNATURE + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", zlib.compress(raw, 9))
            + png_chunk(b"IEND", b""))


def decode_png(data: bytes) -> tuple[int, bytes]:
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("not a PNG")
    pos, width, idat = len(PNG_SIGNATURE), 0, b""
    while pos < len(data):
        (length_,) = struct.unpack(">I", data[pos:pos + 4])
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length_]
        pos += 12 + length_
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if width != height or (depth, color, interlace) != (8, 6, 0):
                raise ValueError("expected a square 8-bit RGBA PNG without interlacing")
        elif kind == b"IDAT":
            idat += body
    raw = zlib.decompress(idat)
    stride = width * 4
    rows = []
    for row in range(width):
        start = row * (stride + 1)
        if raw[start] != 0:
            raise ValueError("only PNG filter type 0 is supported")
        rows.append(raw[start + 1:start + 1 + stride])
    return width, b"".join(rows)


def encode_bmp(size: int, rgba: bytes) -> bytes:
    stride = size * 4
    pixels = bytearray()
    for row in reversed(range(size)):
        line = rgba[row * stride:(row + 1) * stride]
        for i in range(0, stride, 4):
            pixels += bytes((line[i + 2], line[i + 1], line[i], line[i + 3]))
    mask_stride = ((size + 31) // 32) * 4
    mask = bytearray()
    for row in reversed(range(size)):
        line = bytearray(mask_stride)
        for x in range(size):
            if rgba[(row * size + x) * 4 + 3] == 0:
                line[x // 8] |= 0x80 >> (x % 8)
        mask += line
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, len(pixels) + len(mask), 0, 0, 0, 0)
    return header + bytes(pixels) + bytes(mask)


def decode_bmp(data: bytes) -> tuple[int, bytes]:
    header_size, width, height, planes, bits, compression = struct.unpack("<IiiHHI", data[:20])
    if header_size != 40 or height != width * 2 or planes != 1 or bits != 32 or compression != 0:
        raise ValueError("expected a 32-bit BMP icon image")
    stride = width * 4
    pixels = data[40:40 + stride * width]
    rows = []
    for row in reversed(range(width)):
        line = pixels[row * stride:(row + 1) * stride]
        rows.append(b"".join(bytes((line[i + 2], line[i + 1], line[i], line[i + 3])) for i in range(0, stride, 4)))
    return width, b"".join(rows)


def encode_ico(images: dict[int, bytes]) -> bytes:
    blobs = [(size, encode_png(size, rgba) if size >= PNG_MIN_SIZE else encode_bmp(size, rgba))
             for size, rgba in sorted(images.items())]
    offset = 6 + 16 * len(blobs)
    directory, payload = b"", b""
    for size, blob in blobs:
        dim = 0 if size >= 256 else size
        directory += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(blob), offset + len(payload))
        payload += blob
    return struct.pack("<HHH", 0, 1, len(blobs)) + directory + payload


def decode_ico(data: bytes) -> dict[int, bytes]:
    reserved, kind, count = struct.unpack("<HHH", data[:6])
    if reserved != 0 or kind != 1:
        raise ValueError("not an icon file")
    images: dict[int, bytes] = {}
    for i in range(count):
        width, height, _, _, _, _, size, offset = struct.unpack("<BBBBHHII", data[6 + 16 * i:22 + 16 * i])
        blob = data[offset:offset + size]
        dim, rgba = decode_png(blob) if blob.startswith(PNG_SIGNATURE) else decode_bmp(blob)
        if dim != (width or 256) or dim != (height or 256):
            raise ValueError(f"icon entry {i} declares {width}x{height} but holds {dim}x{dim}")
        images[dim] = rgba
    return images


def render_all() -> dict[int, bytes]:
    return {size: render(size) for size in SIZES}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate dist/windows/gx/ghostty-gx.ico")
    parser.add_argument("--check", action="store_true", help="compare the committed icon with a fresh rendering")
    parser.add_argument("--png", type=Path, help="also write every size as a PNG into this directory")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_args(argv)
    if args.check and args.png:
        parser.error("--check does not write files")
    target = args.root / ICON
    images = render_all()
    if args.check:
        try:
            committed = decode_ico(target.read_bytes())
        except (OSError, ValueError, zlib.error, struct.error) as err:
            print(f"{ICON.as_posix()}: cannot read the icon: {err}", file=sys.stderr)
            return 1
        if committed != images:
            print(f"{ICON.as_posix()} is stale: run python scripts/gx_icon.py", file=sys.stderr)
            return 1
        print(f"{ICON.as_posix()} is up to date ({', '.join(map(str, SIZES))} px)")
        return 0
    data = encode_ico(images)
    if not target.is_file() or target.read_bytes() != data:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(f"wrote {ICON.as_posix()} ({len(data)} bytes)")
    else:
        print(f"{ICON.as_posix()} unchanged")
    if args.png:
        args.png.mkdir(parents=True, exist_ok=True)
        for size, rgba in images.items():
            (args.png / f"ghostty-gx-{size}.png").write_bytes(encode_png(size, rgba))
        print(f"wrote {len(images)} PNG files to {args.png}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
