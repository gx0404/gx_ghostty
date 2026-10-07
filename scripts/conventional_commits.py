#!/usr/bin/env python3
"""校验提交标题符合 fork 规范 `type(scope): 中文描述`。

type 取 feat fix perf docs ci test refactor chore build revert style release 之一；
scope 可省略；`!` 标记破坏性变更；冒号为半角，后接一个空格再写描述。
merge 提交同样要合规，例如 `chore(sync): 合并上游 main（<sha>）`。

输入（可组合）：
  标题...             直接校验给定标题
  --message-file F    commit-msg 钩子用：跳过 # 注释行与开头空行取第一行；拒绝 fixup!/squash!/amend!
  --range A..B        git log --first-parent --format=%s A..B；A 为全零 SHA（新分支推送）时只校验 B
退出码：0 全部合规；1 存在违规；2 用法错误或无法读取输入。
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence

ALLOWED_TYPES = (
    "feat",
    "fix",
    "perf",
    "docs",
    "ci",
    "test",
    "refactor",
    "chore",
    "build",
    "revert",
    "style",
    "release",
)
SUBJECT_RE = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^()\s]+)\))?(?P<breaking>!)?: \S")
AUTOSQUASH_RE = re.compile(r"^(?:fixup|squash|amend)! ")
SCISSORS_RE = re.compile(r"^#\s*-+\s*>8\s*-+\s*$")
ZERO_SHA_RE = re.compile(r"^(?:0{40}|0{64})$")
EXAMPLE = "fix(build): 非 v 前缀 tag 不再触发版本号 panic"

Runner = Callable[..., "subprocess.CompletedProcess[str]"]


class UsageError(Exception):
    """参数不合法或无法读取输入（退出码 2）。"""


def subject_problem(subject: str) -> str | None:
    """合规返回 None，否则返回中文原因。"""
    if not subject.strip():
        return "标题为空"
    if AUTOSQUASH_RE.match(subject):
        return "fixup!/squash!/amend! 提交不能进入历史，先用 git rebase -i --autosquash 合并"
    match = SUBJECT_RE.match(subject)
    if not match:
        return "格式应为 type(scope): 描述（scope 可省略；半角冒号后接一个空格）"
    if match.group("type") not in ALLOWED_TYPES:
        return f"type「{match.group('type')}」不在允许列表"
    return None


def is_valid_subject(subject: str) -> bool:
    return subject_problem(subject) is None


def message_subject(text: str) -> str:
    """提交信息的标题行：跳过 # 注释行与开头空行，遇到 scissors 行（其后是 diff）即停止。"""
    for line in text.splitlines():
        if SCISSORS_RE.match(line):
            break
        if line.startswith("#") or not line.strip():
            continue
        return line.rstrip()
    return ""


def read_message_subject(path: Path) -> str:
    return message_subject(Path(path).read_text(encoding="utf-8-sig"))


def range_command(rev_range: str) -> list[str]:
    if rev_range.startswith("-") or "..." in rev_range or ".." not in rev_range:
        raise UsageError(f"--range 需要 A..B 形式：{rev_range!r}")
    base, _, head = rev_range.partition("..")
    if head.startswith("-"):
        raise UsageError(f"--range 需要 A..B 形式：{rev_range!r}")
    if ZERO_SHA_RE.match(base):
        return ["git", "log", "-1", "--no-show-signature", "--format=%s", head or "HEAD"]
    return ["git", "log", "--first-parent", "--no-show-signature", "--format=%s", rev_range]


def range_subjects(rev_range: str, runner: Runner = subprocess.run) -> list[str]:
    """首父链上每个提交一行标题（%s 不含换行），空标题也保留以便判为违规。"""
    command = range_command(rev_range)
    try:
        result = runner(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError as exc:
        raise UsageError(f"无法运行 git：{exc}") from exc
    if result.returncode != 0:
        raise UsageError(f"git log 失败（退出码 {result.returncode}）：{(result.stderr or '').strip()}")
    return result.stdout.splitlines()


def _utf8_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            pass


def main(argv: Sequence[str] | None = None, runner: Runner = subprocess.run) -> int:
    _utf8_stdio()
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog=__doc__.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("subjects", nargs="*", help="直接校验的提交标题")
    parser.add_argument("--message-file", type=Path, help="提交信息文件（commit-msg 钩子的 $1）")
    parser.add_argument("--range", dest="rev_range", help="A..B，按首父链校验其中每个提交")
    args = parser.parse_args(argv)
    if not (args.subjects or args.message_file is not None or args.rev_range):
        parser.print_usage(sys.stderr)
        print("error: 至少提供一个标题、--message-file 或 --range", file=sys.stderr)
        return 2

    subjects: list[str] = list(args.subjects)
    try:
        if args.message_file is not None:
            subjects.append(read_message_subject(args.message_file))
        if args.rev_range:
            subjects.extend(range_subjects(args.rev_range, runner))
    except UsageError as exc:
        print(f"[commit-check] error: {exc}", file=sys.stderr)
        return 2
    except (OSError, UnicodeDecodeError) as exc:
        print(f"[commit-check] error: 无法读取提交信息：{exc}", file=sys.stderr)
        return 2

    violations = [(subject, problem) for subject in subjects if (problem := subject_problem(subject))]
    if violations:
        print("[commit-check] 提交标题不合规：", file=sys.stderr)
        for subject, problem in violations:
            print(f"  - {subject.strip() or '（空）'}：{problem}", file=sys.stderr)
        print(f"规范：type(scope): 中文描述，例如 {EXAMPLE}", file=sys.stderr)
        print("允许的 type：" + " ".join(ALLOWED_TYPES), file=sys.stderr)
        return 1
    print(f"[commit-check] 通过：{len(subjects)} 个提交标题合规")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
