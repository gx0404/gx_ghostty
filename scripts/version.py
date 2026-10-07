#!/usr/bin/env python3
"""fork 版本真源：根 CHANGELOG.md 中数值最大的 `## X.Y.Z(YYYY-MM-DD|TBD)` 标题。

用法：
  python scripts/version.py            打印当前 fork 版本 X.Y.Z
  python scripts/version.py --check    校验全部二级标题合法、版本不重复且至少一个
  python scripts/version.py --release  在 --check 基础上要求最大版本已定版（带日期）
退出码：0 通过；1 校验失败或无法读取 CHANGELOG；2 用法错误。

二级标题（`## ` 开头）只能是版本标题，小节请用 `###`；围栏代码块内的内容不参与解析。
版本号按 SemVer 数值比较（不允许前导零），与标题书写顺序无关。fork tag 为 gx-vX.Y.Z；
产品版本仍以 build.zig.zon 为真源，本脚本不做同步。

其他脚本复用：parse_headings(text) -> list[Heading]、current(text) -> Heading、
read_changelog(root) -> str；Heading.date 为 None 表示 TBD。
"""

from __future__ import annotations

import argparse
import datetime
import re
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[1]
CHANGELOG_NAME = "CHANGELOG.md"
HEADING_FORMAT = "## X.Y.Z(YYYY-MM-DD|TBD)"
_NUMBER = r"(0|[1-9]\d*)"
HEADING_RE = re.compile(rf"^##\s+{_NUMBER}\.{_NUMBER}\.{_NUMBER}\s*\((TBD|\d{{4}}-\d{{2}}-\d{{2}})\)\s*$")
LEVEL2_RE = re.compile(r"^##(?!#)")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


class Heading(NamedTuple):
    version: tuple[int, int, int]
    date: str | None  # None 表示 TBD
    line: int  # 1 起算的行号

    @property
    def semver(self) -> str:
        return format_version(self.version)


def format_version(version: tuple[int, int, int]) -> str:
    return ".".join(str(part) for part in version)


def _closes_fence(line: str, fence: str) -> bool:
    marker = FENCE_RE.match(line)
    if not marker:
        return False
    run = marker.group(1)
    return run[0] == fence[0] and len(run) >= len(fence) and not line.strip().lstrip(fence[0])


def scan(text: str) -> tuple[list[Heading], list[str]]:
    """返回（合法版本标题, 问题列表）；问题包括非法二级标题、非法日期与重复版本。"""
    headings: list[Heading] = []
    problems: list[str] = []
    seen: dict[tuple[int, int, int], int] = {}
    fence: str | None = None
    for number, line in enumerate(text.splitlines(), start=1):
        if fence is not None:
            if _closes_fence(line, fence):
                fence = None
            continue
        marker = FENCE_RE.match(line)
        if marker:
            fence = marker.group(1)
            continue
        if not LEVEL2_RE.match(line):
            continue
        match = HEADING_RE.match(line)
        if not match:
            problems.append(f"第 {number} 行：二级标题必须是 {HEADING_FORMAT}：{line.strip()}")
            continue
        version = (int(match.group(1)), int(match.group(2)), int(match.group(3)))
        raw_date = match.group(4)
        date: str | None = None
        if raw_date != "TBD":
            try:
                datetime.date.fromisoformat(raw_date)
            except ValueError:
                problems.append(f"第 {number} 行：{raw_date} 不是有效日期")
                continue
            date = raw_date
        if version in seen:
            problems.append(f"第 {number} 行：版本 {format_version(version)} 重复（首次出现在第 {seen[version]} 行）")
            continue
        seen[version] = number
        headings.append(Heading(version, date, number))
    return headings, problems


def parse_headings(text: str) -> list[Heading]:
    """按出现顺序返回全部版本标题；存在非法二级标题、非法日期或重复版本时抛 ValueError。"""
    headings, problems = scan(text)
    if problems:
        raise ValueError("CHANGELOG 版本标题不合法：\n" + "\n".join(problems))
    return headings


def current(text: str) -> Heading:
    """数值最大的版本标题；没有版本标题或存在非法标题时抛 ValueError。"""
    headings = parse_headings(text)
    if not headings:
        raise ValueError(f"CHANGELOG 没有任何 {HEADING_FORMAT} 版本标题")
    return max(headings, key=lambda heading: heading.version)


def read_changelog(root: Path) -> str:
    return (Path(root) / CHANGELOG_NAME).read_text(encoding="utf-8-sig")


def _utf8_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            pass


def main(argv: list[str] | None = None) -> int:
    _utf8_stdio()
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog=__doc__.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--check", action="store_true", help="校验全部版本标题（退出 0/1）")
    parser.add_argument("--release", action="store_true", help="在 --check 基础上要求最大版本已定版")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="仓库根目录（默认取脚本所在仓库）")
    args = parser.parse_args(argv)
    path = Path(args.root) / CHANGELOG_NAME
    try:
        text = read_changelog(args.root)
    except (OSError, UnicodeDecodeError) as exc:
        print(f"FAIL: 无法读取 {path}：{exc}", file=sys.stderr)
        return 1
    if not (args.check or args.release):
        try:
            print(current(text).semver)
        except ValueError as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1
        return 0
    headings, problems = scan(text)
    if not headings and not problems:
        problems.append(f"没有任何 {HEADING_FORMAT} 版本标题")
    if problems:
        print(f"FAIL: {path} 版本标题校验失败：", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    top = max(headings, key=lambda heading: heading.version)
    if args.release:
        if top.date is None:
            print(
                f"FAIL: 最大版本 {top.semver} 仍是 TBD（第 {top.line} 行）；发版前先把它定版为当天日期",
                file=sys.stderr,
            )
            return 1
        print(f"PASS: fork 版本 {top.semver}（{top.date}）已定版，tag gx-v{top.semver}")
        return 0
    print(f"PASS: fork 版本 {top.semver}（{top.date or 'TBD'}），共 {len(headings)} 个版本标题")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
