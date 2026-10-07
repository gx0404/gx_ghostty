#!/usr/bin/env python3
"""scripts/version.py 测试：标题解析、数值取最大、非法标题、TBD 与 --check/--release 退出码。"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import version  # noqa: E402

SCRIPT = SCRIPTS / "version.py"


class ParseHeadingsTests(unittest.TestCase):
    def test_parses_dated_and_tbd_headings_with_line_numbers(self) -> None:
        text = "# CHANGELOG\n\n## 0.2.0(TBD)\n\n### 新增\n- 某项\n\n## 0.1.0 (2026-10-07)\n"
        self.assertEqual(
            [
                version.Heading((0, 2, 0), None, 3),
                version.Heading((0, 1, 0), "2026-10-07", 8),
            ],
            version.parse_headings(text),
        )

    def test_tolerates_crlf_and_trailing_spaces(self) -> None:
        text = "# CHANGELOG\r\n\r\n## 1.2.3(2026-01-31)  \r\n- 修复\r\n"
        self.assertEqual([version.Heading((1, 2, 3), "2026-01-31", 3)], version.parse_headings(text))

    def test_semver_property(self) -> None:
        self.assertEqual("10.0.3", version.Heading((10, 0, 3), None, 1).semver)

    def test_ignores_level1_level3_and_fenced_code(self) -> None:
        text = "\n".join(
            [
                "# CHANGELOG",
                "## 0.1.0(TBD)",
                "### 说明",
                "```markdown",
                "## 9.9.9(TBD)",
                "## 这不是标题",
                "```",
                "~~~",
                "## also ignored",
                "~~~",
            ]
        )
        self.assertEqual([version.Heading((0, 1, 0), None, 2)], version.parse_headings(text))

    def test_rejects_invalid_level2_headings(self) -> None:
        invalid = [
            "## v0.1.0(TBD)",
            "## 0.1(TBD)",
            "## 0.1.0",
            "## 0.1.0(tbd)",
            "## 0.1.0(2026/10/07)",
            "## 0.1.0(2026-13-01)",
            "## 0.1.0(2026-02-30)",
            "## 01.2.3(TBD)",
            "## 0.1.0(TBD) 首个版本",
            "##0.2.0(TBD)",
            "## 未发布",
        ]
        for line in invalid:
            with self.subTest(line=line):
                text = f"# CHANGELOG\n\n## 0.0.1(2026-01-01)\n\n{line}\n"
                with self.assertRaises(ValueError) as caught:
                    version.parse_headings(text)
                self.assertIn("第 5 行", str(caught.exception))
                with self.assertRaises(ValueError):
                    version.current(text)

    def test_rejects_duplicate_versions(self) -> None:
        text = "## 0.1.0(TBD)\n## 0.1.0(2026-10-07)\n"
        with self.assertRaises(ValueError) as caught:
            version.parse_headings(text)
        self.assertIn("重复", str(caught.exception))

    def test_reports_every_problem(self) -> None:
        headings, problems = version.scan("## x\n## 0.1.0(TBD)\n## y\n")
        self.assertEqual([version.Heading((0, 1, 0), None, 2)], headings)
        self.assertEqual(2, len(problems))


class CurrentTests(unittest.TestCase):
    def test_unordered_headings_pick_numeric_max(self) -> None:
        text = "## 0.1.0(2026-01-01)\n## 0.3.0(TBD)\n## 0.2.5(2026-03-01)\n"
        self.assertEqual(version.Heading((0, 3, 0), None, 2), version.current(text))

    def test_multi_digit_components_compare_numerically(self) -> None:
        cases = [
            (["0.9.0", "0.10.0"], "0.10.0"),
            (["1.2.9", "1.2.10"], "1.2.10"),
            (["9.99.99", "10.0.0"], "10.0.0"),
            (["2.0.0", "11.0.0", "3.0.0"], "11.0.0"),
        ]
        for versions, expected in cases:
            with self.subTest(versions=versions):
                text = "".join(f"## {item}(2026-10-07)\n" for item in versions)
                self.assertEqual(expected, version.current(text).semver)

    def test_no_headings_raises(self) -> None:
        for text in ("", "# CHANGELOG\n\n### 新增\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                version.current(text)

    def test_read_changelog_strips_bom(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "CHANGELOG.md").write_bytes("\ufeff## 0.1.0(TBD)\r\n".encode("utf-8"))
            text = version.read_changelog(Path(tmp))
        self.assertEqual("0.1.0", version.current(text).semver)


class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write(self, text: str) -> None:
        (self.root / "CHANGELOG.md").write_text(text, encoding="utf-8", newline="")

    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8")
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            check=False,
        )

    def test_prints_current_version(self) -> None:
        self._write("# CHANGELOG\n\n## 0.1.0(2026-01-01)\n\n## 0.2.0(TBD)\n")
        result = self._run()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("0.2.0\n", result.stdout)

    def test_check_passes_with_tbd(self) -> None:
        self._write("# CHANGELOG\r\n\r\n## 0.1.0(TBD)\r\n")
        result = self._run("--check")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("PASS", result.stdout)

    def test_check_fails_on_invalid_heading(self) -> None:
        self._write("## 0.1.0(TBD)\n## Unreleased\n")
        result = self._run("--check")
        self.assertEqual(1, result.returncode)
        self.assertIn("Unreleased", result.stderr)

    def test_check_fails_without_headings(self) -> None:
        self._write("# CHANGELOG\n")
        self.assertEqual(1, self._run("--check").returncode)
        self.assertEqual(1, self._run().returncode)

    def test_release_fails_while_max_version_is_tbd(self) -> None:
        self._write("## 0.1.0(2026-01-01)\n## 0.2.0(TBD)\n")
        result = self._run("--release")
        self.assertEqual(1, result.returncode)
        self.assertIn("TBD", result.stderr)

    def test_release_passes_when_max_version_is_dated(self) -> None:
        self._write("## 0.2.0(2026-10-07)\n## 0.1.0(TBD)\n")
        result = self._run("--release")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("gx-v0.2.0", result.stdout)

    def test_missing_changelog_exits_1(self) -> None:
        self.assertEqual(1, self._run("--check").returncode)

    def test_usage_error_exits_2(self) -> None:
        self._write("## 0.1.0(TBD)\n")
        self.assertEqual(2, self._run("--bogus").returncode)


if __name__ == "__main__":
    unittest.main()
