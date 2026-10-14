#!/usr/bin/env python3
"""Offline, pinned Fluent SVG to Zig M/L/C/Z generator; --check never writes."""
from __future__ import annotations

import argparse
import hashlib
import math
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
REVISION = "a347af95478f989038cccbf085978865264c048a"
BASE = "src/gx/fluent"
LICENSE_HASH = "69bc45dc42b9acb96a69823adbc6ae538374e3c0bde169b855b32c48eaaef52f"
# Semantic id, exact upstream asset folder, filename stem, canonical LF SHA256.
SOURCES = (
    ("language", "Globe", "globe", "f84351d057756bf271c64dcd11a96ca25c3599eb671f0a4cbd8ad317e3341448"),
    ("appearance", "Color", "color", "6b41870bbba9cf258df1c655dcbc3f6e2847f0c906179c08bb8d2a3a3f4e37df"),
    ("font", "Text Font", "text_font", "be5c89700a59593f6c52a7679837ec123ed08053af957ba74e61bf7f8eec14e4"),
    ("interaction", "Cursor", "cursor", "b78a430f026a705492a29cad05e0ccb2e2aae2f669555c8ec5711625f3b6cf38"),
    ("shell", "Window Console", "window_console", "7ebcf2d63f4f857df354eb5a78b59ef8c8a95edee0432c0219936be18be27543"),
    ("about", "Info", "info", "5e5abcb6d027aeb248afd5166c0eef7716b9ac3cfe48552373b79a396229857b"),
)
TOKEN = re.compile(r"[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
ARITY = dict(M=2, L=2, H=1, V=1, C=6, S=4, Q=4, T=2, A=7)


class InvalidSvg(ValueError):
    pass


def number(value: float) -> str:
    if not math.isfinite(value) or abs(value) > 1e6:
        raise InvalidSvg("non-finite or out-of-bounds coordinate")
    value = round(value, 6)
    return "0" if value == 0 else f"{value:.6f}".rstrip("0").rstrip(".")


def tokens(data: str) -> list[str]:
    result, end = [], 0
    if len(data) > 1_000_000:
        raise InvalidSvg("path exceeds input limit")
    for match in TOKEN.finditer(data):
        gap = data[end:match.start()]
        if gap.strip(" \t\r\n,") or gap.count(",") > 1:
            raise InvalidSvg("invalid path token")
        if "," in gap and (not result or result[-1].isalpha() or match.group().isalpha()):
            raise InvalidSvg("invalid comma placement")
        result.append(match.group())
        end = match.end()
    if data[end:].strip(" \t\r\n"):
        raise InvalidSvg("invalid path suffix")
    return result


def arc(start, values):
    """SVG endpoint arc converted to cubic Beziers of at most 90 degrees."""
    rx, ry, rotation, large, sweep, x2, y2 = values
    if large not in (0, 1) or sweep not in (0, 1):
        raise InvalidSvg("arc flags must be 0 or 1")
    x1, y1 = start
    if (x1, y1) == (x2, y2):
        return []
    rx, ry = abs(rx), abs(ry)
    if not rx or not ry:
        return [("L", x2, y2)]
    if min(rx, ry) < 1e-12:
        raise InvalidSvg("arc below supported precision")
    phi = math.radians(rotation % 360)
    cp, sp = math.cos(phi), math.sin(phi)
    xp = cp * (x1 - x2) / 2 + sp * (y1 - y2) / 2
    yp = -sp * (x1 - x2) / 2 + cp * (y1 - y2) / 2
    scale = xp * xp / (rx * rx) + yp * yp / (ry * ry)
    if scale > 1:
        rx *= math.sqrt(scale)
        ry *= math.sqrt(scale)
    denom = rx * rx * yp * yp + ry * ry * xp * xp
    if denom == 0:
        raise InvalidSvg("arc below supported precision")
    factor = math.sqrt(max(0, (rx * rx * ry * ry - denom) / denom))
    if large == sweep:
        factor = -factor
    cxp, cyp = factor * rx * yp / ry, -factor * ry * xp / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2
    a = math.atan2((yp - cyp) / ry, (xp - cxp) / rx)
    b = math.atan2((-yp - cyp) / ry, (-xp - cxp) / rx)
    delta = (b - a) % (2 * math.pi)
    if not sweep:
        delta -= 2 * math.pi
    count = max(1, math.ceil(abs(delta) / (math.pi / 2)))
    step = delta / count

    def point(angle):
        return (cx + rx * cp * math.cos(angle) - ry * sp * math.sin(angle),
                cy + rx * sp * math.cos(angle) + ry * cp * math.sin(angle))

    def tangent(angle):
        return (-rx * cp * math.sin(angle) - ry * sp * math.cos(angle),
                -rx * sp * math.sin(angle) + ry * cp * math.cos(angle))

    result = []
    for index in range(count):
        left, right = a + index * step, a + (index + 1) * step
        p, q, u, v = point(left), point(right), tangent(left), tangent(right)
        alpha = 4 / 3 * math.tan(step / 4)
        result.append(("C", p[0] + alpha * u[0], p[1] + alpha * u[1],
                       q[0] - alpha * v[0], q[1] - alpha * v[1], *q))
    result[-1] = (*result[-1][:-2], x2, y2)
    return result


def normalize(data: str):
    source = tokens(data)
    result, index, command = [], 0, None
    current = origin = (0.0, 0.0)
    previous, cubic_control, quad_control = "", None, None
    while index < len(source):
        if source[index].isalpha():
            command = source[index]
            index += 1
        if command is None:
            raise InvalidSvg("path needs a command")
        op, relative = command.upper(), command.islower()
        if op == "Z":
            if not result or previous == "Z":
                raise InvalidSvg("close before move")
            result.append(("Z",))
            current, previous, command = origin, "Z", None
            cubic_control = quad_control = None
            continue
        if op == "A":
            # SVG permits adjacent one-character flags, including a coordinate
            # immediately after the sweep flag (e.g. A10 10 0 0110 20).
            for offset in (3, 4):
                pos = index + offset
                if pos >= len(source) or source[pos][0] not in "01":
                    raise InvalidSvg("arc flags must be 0 or 1")
                if len(source[pos]) > 1:
                    source[pos:pos + 1] = [source[pos][0], source[pos][1:]]
        if op not in ARITY or index + ARITY[op] > len(source):
            raise InvalidSvg("unsupported or incomplete path command")
        try:
            values = list(map(float, source[index:index + ARITY[op]]))
        except ValueError as exc:
            raise InvalidSvg("incomplete path command") from exc
        for value in values:
            number(value)
        index += ARITY[op]
        if not result and op != "M":
            raise InvalidSvg("path must begin with move")
        if previous == "Z" and op != "M":
            result.append(("M", *current))

        def point(x, y):
            return (x + current[0], y + current[1]) if relative else (x, y)

        end = current
        new_cubic = new_quad = None
        if op in ("M", "L", "T"):
            end = point(*values)
            if op == "T":
                control = tuple(2 * current[i] - quad_control[i] for i in range(2)) if previous in ("Q", "T") else current
                new_quad = control
                result.append(("C", *(current[i] + 2 / 3 * (control[i] - current[i]) for i in range(2)),
                               *(end[i] + 2 / 3 * (control[i] - end[i]) for i in range(2)), *end))
            else:
                result.append((op, *end))
                if op == "M":
                    origin = end
                    command = "l" if relative else "L"
        elif op == "H":
            end = (current[0] + values[0] if relative else values[0], current[1])
            result.append(("L", *end))
        elif op == "V":
            end = (current[0], current[1] + values[0] if relative else values[0])
            result.append(("L", *end))
        elif op in ("C", "S"):
            if op == "C":
                first, second, end = point(*values[:2]), point(*values[2:4]), point(*values[4:])
            else:
                first = tuple(2 * current[i] - cubic_control[i] for i in range(2)) if previous in ("C", "S") else current
                second, end = point(*values[:2]), point(*values[2:])
            result.append(("C", *first, *second, *end))
            new_cubic = second
        elif op == "Q":
            control, end = point(*values[:2]), point(*values[2:])
            result.append(("C", *(current[i] + 2 / 3 * (control[i] - current[i]) for i in range(2)),
                           *(end[i] + 2 / 3 * (control[i] - end[i]) for i in range(2)), *end))
            new_quad = control
        elif op == "A":
            end = point(*values[-2:])
            result.extend(arc(current, [*values[:5], *end]))
        current, previous = end, op
        cubic_control, quad_control = new_cubic, new_quad
        if len(result) > 10000:
            raise InvalidSvg("path exceeds command limit")
    if not result:
        raise InvalidSvg("empty path")
    for row in result:
        for value in row[1:]:
            number(value)
    return result


def parse_svg(data: bytes):
    if len(data) > 1_000_000 or b"<!" in data:
        raise InvalidSvg("oversized or declared XML is unsupported")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as exc:
        raise InvalidSvg("invalid SVG XML") from exc
    if root.tag != "{http://www.w3.org/2000/svg}svg":
        raise InvalidSvg("expected SVG namespace")
    try:
        view = list(map(float, root.attrib["viewBox"].replace(",", " ").split()))
    except (KeyError, ValueError) as exc:
        raise InvalidSvg("expected numeric viewBox") from exc
    if len(view) != 4 or view[:2] != [0, 0] or not all(0 < x <= 4096 for x in view[2:]):
        raise InvalidSvg("unsupported viewBox")
    paths = []

    def visit(node, fill="black", rule="nonzero"):
        if not node.tag.startswith("{http://www.w3.org/2000/svg}"):
            raise InvalidSvg("unexpected element namespace")
        tag = node.tag.removeprefix("{http://www.w3.org/2000/svg}")
        allowed = {"fill", "fill-rule", "id"}
        if tag == "svg":
            allowed |= {"width", "height", "viewBox"}
        elif tag == "path":
            allowed |= {"d", "clip-rule"}
        elif tag not in ("g", "title", "desc"):
            raise InvalidSvg(f"unsupported element: {tag}")
        if set(node.attrib) - allowed:
            raise InvalidSvg("unsupported SVG attributes: " + str(set(node.attrib) - allowed))
        fill, rule = node.get("fill", fill), node.get("fill-rule", rule)
        if rule not in ("nonzero", "evenodd"):
            raise InvalidSvg("unsupported fill rule")
        if tag == "path":
            if fill not in ("#212121", "black", "#000", "#000000", "currentColor"):
                raise InvalidSvg("expected monochrome filled path")
            paths.append((rule, normalize(node.get("d", ""))))
        for child in node:
            visit(child, fill, rule)

    visit(root)
    if not paths or len(paths) > 64:
        raise InvalidSvg("invalid path count")
    return view[2], view[3], paths


def pinned(path: Path, digest: str) -> bytes:
    data = path.read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(data).hexdigest() != digest:
        raise InvalidSvg(f"input hash mismatch: {path.name}")
    return data


def generate(root: Path) -> bytes:
    inputs = root / BASE / "inputs"
    pinned(inputs / "LICENSE", LICENSE_HASH)
    lines = ["// Generated by scripts/gx_fluent_icons.py; do not edit.",
             f"// Microsoft Fluent UI System Icons {REVISION}; MIT (inputs/LICENSE).",
             'const model = @import("model.zig");',
             "pub const Id = enum { " + ", ".join(x[0] for x in SOURCES) + " };",
             "pub const icons = [_]model.Icon{"]
    for semantic, folder, stem, digest in SOURCES:
        filename = f"ic_fluent_{stem}_20_filled.svg"
        width, height, paths = parse_svg(pinned(inputs / filename, digest))
        lines.append(f"    // {semantic}: assets/{folder}/SVG/{filename}; sha256 {digest}")
        lines.append(f"    .{{ .width = {number(width)}, .height = {number(height)}, .paths = &.{{")
        for rule, commands in paths:
            lines.append(f"        .{{ .fill_rule = .{rule}, .commands = &.{{")
            for command in commands:
                op, *coords = command
                point = lambda x, y: f".{{ .x = {number(x)}, .y = {number(y)} }}"
                if op == "Z":
                    lines.append("            .close,")
                elif op == "C":
                    lines.append("            .{ .cubic = .{ .c1 = " + point(*coords[:2]) + ", .c2 = " + point(*coords[2:4]) + ", .end = " + point(*coords[4:]) + " } },")
                else:
                    name = "move" if op == "M" else "line"
                    lines.append(f"            .{{ .{name} = {point(*coords)} }},")
            lines.append("        } },")
        lines.append("    } },")
    lines += ["};", ""]
    return "\n".join(lines).encode()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        data = generate(args.root)
        path = args.root / BASE / "paths.zig"
        previous = path.read_bytes().replace(b"\r\n", b"\n") if path.exists() else None
        if args.check and previous != data:
            parser.exit(1, "Fluent paths are missing or stale; run scripts/gx_fluent_icons.py\n")
        if not args.check and previous != data:
            path.write_bytes(data)
        print("PASS: Fluent inputs and generated paths" if args.check else "Generated Fluent paths")
    except (OSError, ValueError) as exc:
        parser.exit(2, f"ERROR: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
