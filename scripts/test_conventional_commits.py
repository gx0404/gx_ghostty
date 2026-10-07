#!/usr/bin/env python3
"""scripts/conventional_commits.py 与 .githooks/commit-msg 测试（中文描述、提交信息文件、首父链）。"""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import conventional_commits as cc  # noqa: E402

SCRIPT = SCRIPTS / "conventional_commits.py"
HOOK = ROOT / ".githooks" / "commit-msg"


def _env() -> dict[str, str]:
    return dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8")


class FakeGit:
    """记录命令并返回预设输出的 git 替身。"""

    def __init__(self, stdout: str = "", returncode: int = 0, stderr: str = "") -> None:
        self.stdout = stdout
        self.returncode = returncode
        self.stderr = stderr
        self.commands: list[list[str]] = []

    def __call__(self, command, **kwargs):
        self.commands.append(list(command))
        return subprocess.CompletedProcess(command, self.returncode, self.stdout, self.stderr)


def run_main(*args: str, runner=None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        if runner is None:
            code = cc.main(list(args))
        else:
            code = cc.main(list(args), runner=runner)
    return code, out.getvalue(), err.getvalue()


class SubjectTests(unittest.TestCase):
    def test_accepts_every_allowed_type_with_chinese_description(self) -> None:
        for kind in cc.ALLOWED_TYPES:
            with self.subTest(kind=kind):
                self.assertIsNone(cc.subject_problem(f"{kind}: 中文描述"))
                self.assertIsNone(cc.subject_problem(f"{kind}(scope): 中文描述"))

    def test_accepts_common_fork_subjects(self) -> None:
        for subject in [
            "fix(build): 非 v 前缀 tag 不再触发版本号 panic",
            "feat(terminal): 支持 OSC 133 语义提示",
            "refactor(renderer)!: 拆分帧快照逻辑",
            "chore(sync): 合并上游 main（c3203ea4b）",
            "ci(github): 归档上游 workflow 并新增 gx-ci 与 gx-release",
            "chore(release): 定版 0.1.0",
            "docs(kb): 生成图谱报告与知识库",
            "revert: 撤销 feat(font): 新增字体回退",
            "style(zig): 统一格式",
        ]:
            with self.subTest(subject=subject):
                self.assertTrue(cc.is_valid_subject(subject))

    def test_rejects_malformed_subjects(self) -> None:
        for subject in [
            "Update VOUCHED list (#14550)",
            "renderer: always release shaders  (#14542)",
            "Merge branch 'main' into gx_ghostty",
            'Revert "feat: 新增功能"',
            "feat：全角冒号",
            "feat:缺少空格",
            "feat:  两个空格",
            "Feat: 首字母大写",
            "feature: 非法类型",
            "fix(): 空 scope",
            "fix(a b): scope 含空格",
            "fix(build) : 冒号前有空格",
            " fix: 行首空格",
            "fix:",
            "",
        ]:
            with self.subTest(subject=subject):
                self.assertIsNotNone(cc.subject_problem(subject))

    def test_rejects_autosquash_prefixes_with_specific_reason(self) -> None:
        for subject in ["fixup! feat: 新增功能", "squash! fix(build): 修复", "amend! docs: 更新"]:
            with self.subTest(subject=subject):
                self.assertIn("autosquash", cc.subject_problem(subject) or "")


class MessageFileTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _file(self, content: str, *, bom: bool = False) -> Path:
        path = self.dir / "COMMIT_EDITMSG"
        data = content.encode("utf-8")
        path.write_bytes(b"\xef\xbb\xbf" + data if bom else data)
        return path

    def test_skips_comments_and_leading_blank_lines(self) -> None:
        text = "# 请输入提交信息\n\n\n   \nfeat(input): 支持 kitty 键盘协议\n\n正文第一行\n# 注释\n"
        self.assertEqual("feat(input): 支持 kitty 键盘协议", cc.message_subject(text))

    def test_stops_at_scissors_line(self) -> None:
        text = "# 注释\n# ------------------------ >8 ------------------------\ndiff --git a/x b/x\n"
        self.assertEqual("", cc.message_subject(text))

    def test_valid_message_file_with_crlf_and_bom(self) -> None:
        path = self._file("\r\n# 注释\r\nfix(build): 修复 Windows 构建\r\n\r\n正文\r\n", bom=True)
        code, out, err = run_main("--message-file", str(path))
        self.assertEqual(0, code, err)
        self.assertIn("通过", out)

    def test_invalid_message_file(self) -> None:
        path = self._file("更新文档\n")
        code, _, err = run_main("--message-file", str(path))
        self.assertEqual(1, code)
        self.assertIn("更新文档", err)

    def test_fixup_message_file_rejected(self) -> None:
        path = self._file("fixup! feat(input): 支持 kitty 键盘协议\n")
        code, _, err = run_main("--message-file", str(path))
        self.assertEqual(1, code)
        self.assertIn("autosquash", err)

    def test_empty_message_rejected(self) -> None:
        path = self._file("# 只有注释\n\n")
        code, _, err = run_main("--message-file", str(path))
        self.assertEqual(1, code)
        self.assertIn("标题为空", err)

    def test_missing_message_file_is_usage_error(self) -> None:
        code, _, _ = run_main("--message-file", str(self.dir / "absent"))
        self.assertEqual(2, code)


class RangeTests(unittest.TestCase):
    def test_uses_first_parent_subject_log(self) -> None:
        fake = FakeGit("feat(font): 新增字体回退\nchore(sync): 合并上游 main（abc1234）\n")
        code, out, err = run_main("--range", "origin/gx_ghostty..HEAD", runner=fake)
        self.assertEqual(0, code, err)
        self.assertIn("2 个", out)
        command = fake.commands[0]
        self.assertEqual(["git", "log"], command[:2])
        self.assertIn("--first-parent", command)
        self.assertIn("--format=%s", command)
        self.assertEqual("origin/gx_ghostty..HEAD", command[-1])

    def test_merge_commits_must_be_conventional(self) -> None:
        fake = FakeGit("feat(font): 新增字体回退\nMerge branch 'main' into gx_ghostty\n")
        code, _, err = run_main("--range", "a..b", runner=fake)
        self.assertEqual(1, code)
        self.assertIn("Merge branch", err)

    def test_empty_subject_in_range_is_a_violation(self) -> None:
        fake = FakeGit("feat: 正常\n\n")
        code, _, err = run_main("--range", "a..b", runner=fake)
        self.assertEqual(1, code)
        self.assertIn("标题为空", err)

    def test_empty_range_passes(self) -> None:
        code, _, _ = run_main("--range", "a..a", runner=FakeGit(""))
        self.assertEqual(0, code)

    def test_all_zero_base_checks_only_head(self) -> None:
        fake = FakeGit("ci(github): 新增 gx-ci\n")
        code, _, err = run_main("--range", "0" * 40 + "..deadbeef", runner=fake)
        self.assertEqual(0, code, err)
        command = fake.commands[0]
        self.assertIn("-1", command)
        self.assertNotIn("--first-parent", command)
        self.assertEqual("deadbeef", command[-1])

    def test_rejects_malformed_ranges_without_running_git(self) -> None:
        for rev_range in ["HEAD", "a...b", "--output=x..y", "a..-p"]:
            with self.subTest(rev_range=rev_range):
                fake = FakeGit("")
                code, _, _ = run_main(f"--range={rev_range}", runner=fake)
                self.assertEqual(2, code)
                self.assertEqual([], fake.commands)

    def test_git_failure_is_usage_error(self) -> None:
        fake = FakeGit("", returncode=128, stderr="fatal: bad revision")
        code, _, err = run_main("--range", "nope..HEAD", runner=fake)
        self.assertEqual(2, code)
        self.assertIn("bad revision", err)


class CliTests(unittest.TestCase):
    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=_env(),
            check=False,
        )

    def test_positional_subjects(self) -> None:
        self.assertEqual(0, self._run("feat(input): 支持鼠标 1005 编码", "docs: 更新开发文档").returncode)
        result = self._run("feat: 合规", "随手改改")
        self.assertEqual(1, result.returncode)
        self.assertIn("随手改改", result.stderr)

    def test_usage_errors_exit_2(self) -> None:
        self.assertEqual(2, self._run().returncode)
        self.assertEqual(2, self._run("--bogus").returncode)


class HookTests(unittest.TestCase):
    def test_hook_is_posix_sh_with_lf_and_fallback(self) -> None:
        data = HOOK.read_bytes()
        self.assertTrue(data.startswith(b"#!/bin/sh\n"))
        self.assertNotIn(b"\r", data)
        text = data.decode("utf-8")
        self.assertIn('scripts/conventional_commits.py --message-file "$1"', text)
        self.assertIn("for py in python3 python; do", text)
        attributes = (ROOT / ".githooks" / ".gitattributes").read_bytes()
        self.assertEqual(b"* text eol=lf\n", attributes)

    def test_tracked_hook_is_committed_executable(self) -> None:
        listed = subprocess.run(
            ["git", "ls-files", "-s", "--", ".githooks/commit-msg"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=_env(),
            check=False,
        )
        self.assertEqual(0, listed.returncode, listed.stderr)
        entries = listed.stdout.splitlines()
        if not entries:
            self.skipTest(".githooks/commit-msg 尚未入库；首次提交用 git add --chmod=+x .githooks/commit-msg")
        for entry in entries:
            with self.subTest(entry=entry):
                self.assertTrue(
                    entry.startswith("100755 "),
                    f"{entry}：钩子必须以 100755 入库，否则 Linux/macOS 上的 git 会忽略它；"
                    "core.filemode=false 时普通 git add 记成 100644，改用 git add --chmod=+x .githooks/commit-msg",
                )

    @unittest.skipUnless(shutil.which("sh"), "需要 POSIX sh（Linux 或 Git for Windows）")
    def test_hook_accepts_and_rejects(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            message = Path(tmp) / "COMMIT_EDITMSG"
            message.write_text("# 注释\nfix(build): 修复 commit-msg 钩子\n", encoding="utf-8")
            ok = subprocess.run(
                [shutil.which("sh") or "sh", str(HOOK), str(message)],
                cwd=ROOT,
                capture_output=True,
                env=_env(),
                check=False,
            )
            self.assertEqual(0, ok.returncode, ok.stderr.decode("utf-8", "replace"))
            message.write_text("wip\n", encoding="utf-8")
            bad = subprocess.run(
                [shutil.which("sh") or "sh", str(HOOK), str(message)],
                cwd=ROOT,
                capture_output=True,
                env=_env(),
                check=False,
            )
            self.assertEqual(1, bad.returncode)


if __name__ == "__main__":
    unittest.main()
