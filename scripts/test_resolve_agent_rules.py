#!/usr/bin/env python3
"""scripts/resolve_agent_rules.py 的行为测试。

覆盖 glob 语义、routes.toml v3 schema、解析（目录展开、尚未创建的路径、上游嵌套
AGENTS、任务、JSON）、--check 的逐项失败注入（临时 git 仓库），以及真实仓库的只读
冒烟。测试不修改真实仓库。
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
RESOLVER = SCRIPTS_DIR / "resolve_agent_rules.py"


def _load_resolver():
    spec = importlib.util.spec_from_file_location("gx_resolve_agent_rules", RESOLVER)
    if spec is None or spec.loader is None:
        raise ImportError(f"无法加载 {RESOLVER}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


resolver = _load_resolver()

CHILD_ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
CHILD_ENV["PYTHONDONTWRITEBYTECODE"] = "1"

ROUTES_REL = "docs/AGENT_RULES/routes.toml"
MARKER = "<!-- gx-fork: 测试 fork 段（同步时保留）-->"


def DOC(rule_id: str) -> str:
    return f"docs/AGENT_RULES/{rule_id}.md"


ROUTES = """\
version = 3
root_max_bytes = 16384

root_only = [
  "LICENSE",
  "README.md",
]

nested_agents = [
  "lib/core/AGENTS.md",
]

[[rules]]
id = "code-review"
doc = "docs/AGENT_RULES/code-review.md"
paths = []
tasks = ["review"]

[[rules]]
id = "core"
doc = "docs/AGENT_RULES/core.md"
paths = [
  "lib/core.zig",
  "lib/core/**",
]
tasks = []

[[rules]]
id = "development"
doc = "docs/AGENT_RULES/development.md"
paths = [
  "**/AGENTS.md",
  ".gitignore",
  "docs/**",
  "scripts/*.py",
]
tasks = ["sync"]

[[rules]]
id = "ui"
doc = "docs/AGENT_RULES/ui.md"
paths = [
  "lib/core/ui.zig",
  "ui/**",
]
tasks = ["test"]
"""

FILES = {
    ".gitignore": "/out/\n",
    "AGENTS.md": f"# Upstream guide\n\nUpstream body.\n\n{MARKER}\n\n## 规则加载协议\n\nfork 段正文。\n",
    "LICENSE": "license\n",
    "README.md": "readme\n",
    "docs/AGENT_RULES/README.md": "# AGENT_RULES\n\n索引。\n",
    "docs/AGENT_RULES/code-review.md": "# code-review\n\n## 范围\n\n审核输出格式。\n",
    "docs/AGENT_RULES/core.md": "# core\n\n## 范围\n\ncore 领域规则。\n",
    "docs/AGENT_RULES/development.md": "# development\n\n## 范围\n\n框架规则。\n",
    ROUTES_REL: ROUTES,
    "docs/AGENT_RULES/ui.md": "# ui\n\n## 范围\n\nui 领域规则。\n",
    "lib/core.zig": "// core\n",
    "lib/core/AGENTS.md": "# Core upstream guide\n",
    "lib/core/deep/nested.zig": "// nested\n",
    "lib/core/page.zig": "// page\n",
    "lib/core/ui.zig": "// shared with ui\n",
    "scripts/tool.py": "print('tool')\n",
    "ui/window.zig": "// window\n",
}

LONG_PROSE = (
    "这一段用于验证重复段落检测：规范化空白后的长度必须超过一百六十个字符，"
    "当它同时出现在两份不同的领域规则文档里时，闭集校验必须拒绝，"
    "因为复制粘贴的规则迟早会各自漂移，真源只能有一个，"
    "其余位置应当引用而不是复制正文；重复是维护事故的起点，"
    "所以检查会把每个段落与列表项归一化后逐一比较，第二次出现即判定失败，"
    "防止两份领域规则各说各话、互相矛盾。"
)


def _wrap(text: str, width: int) -> str:
    return "\n".join(text[index:index + width] for index in range(0, len(text), width))


class TempRepoCase(unittest.TestCase):
    """每个用例一个全新的临时 git 仓库（未提交；--others 让未跟踪文件同样 Git 可见）。

    全局与系统 git 配置被隔离，开发机上的 core.excludesFile 不会改变「Git 可见」集合。
    每个类只在 setUpClass 里 git init 一次，用例复制这份全新的 .git，不再各起一个 git 进程。
    """

    @classmethod
    def setUpClass(cls) -> None:
        tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.addClassCleanup(tmp.cleanup)
        base = Path(tmp.name).resolve()
        gitconfig = base / "gitconfig"
        gitconfig.write_bytes(b"")
        env = {**CHILD_ENV, "GIT_CONFIG_GLOBAL": str(gitconfig), "GIT_CONFIG_NOSYSTEM": "1"}
        cls.fresh_git_dir = base / "template" / ".git"
        subprocess.run(["git", "init", "-q", str(cls.fresh_git_dir.parent)], check=True, env=env, capture_output=True)

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name).resolve()
        gitconfig = base / "gitconfig"
        gitconfig.write_bytes(b"")
        isolation = {"GIT_CONFIG_GLOBAL": str(gitconfig), "GIT_CONFIG_NOSYSTEM": "1"}
        self.env = {**CHILD_ENV, **isolation}
        patcher = mock.patch.dict(os.environ, isolation)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.root = base / "repo"
        self.root.mkdir()
        for relative, content in FILES.items():
            self.write(relative, content)
        shutil.copytree(self.fresh_git_dir, self.root / ".git")

    def write(self, relative: str, content: str | bytes, *, crlf: bool = False) -> None:
        path = self.root.joinpath(*relative.split("/"))
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, str):
            content = (content.replace("\n", "\r\n") if crlf else content).encode("utf-8")
        path.write_bytes(content)

    def remove(self, relative: str) -> None:
        self.root.joinpath(*relative.split("/")).unlink()

    def edit_routes(self, old: str, new: str) -> None:
        self.assertIn(old, ROUTES)
        self.write(ROUTES_REL, ROUTES.replace(old, new, 1))

    def resolve(self, *paths: str, tasks: tuple[str, ...] = ()) -> list[str]:
        return resolver.resolve_rules(self.root, list(paths), list(tasks)).lines()

    def resolve_error(self, *paths: str, tasks: tuple[str, ...] = ()) -> str:
        with self.assertRaises(resolver.RuleManifestError) as ctx:
            resolver.resolve_rules(self.root, list(paths), list(tasks))
        return str(ctx.exception)

    def check_error(self, *fragments: str) -> str:
        with self.assertRaises(resolver.RuleManifestError) as ctx:
            resolver.validate_repository(self.root)
        message = str(ctx.exception)
        for fragment in fragments:
            self.assertIn(fragment, message)
        return message

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RESOLVER), "--root", str(self.root), *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=self.env,
            timeout=120,
            check=False,
        )


class GlobSemanticsTest(unittest.TestCase):
    def test_single_star_does_not_cross_slash(self) -> None:
        match = resolver.route_matches
        self.assertTrue(match("src/apprt/*.zig", "src/apprt/gtk.zig"))
        self.assertFalse(match("src/apprt/*.zig", "src/apprt/gtk/App.zig"))
        self.assertTrue(match("test/fuzz-libghostty/*", "test/fuzz-libghostty/AGENTS.md"))
        self.assertFalse(match("test/fuzz-libghostty/*", "test/fuzz-libghostty/src/main.zig"))

    def test_leading_globstar_matches_zero_or_more_directories(self) -> None:
        for path in ("AGENTS.md", "macos/AGENTS.md", "src/terminal/c/AGENTS.md"):
            with self.subTest(path=path):
                self.assertTrue(resolver.route_matches("**/AGENTS.md", path))
        for path in ("XAGENTS.md", "src/xAGENTS.md", "src/AGENTS.md.bak"):
            with self.subTest(path=path):
                self.assertFalse(resolver.route_matches("**/AGENTS.md", path))

    def test_trailing_globstar_matches_directory_itself_and_descendants(self) -> None:
        for path in ("src/terminal", "src/terminal/Screen.zig", "src/terminal/c/terminal.zig"):
            with self.subTest(path=path):
                self.assertTrue(resolver.route_matches("src/terminal/**", path))
        for path in ("src", "src/terminalx", "src/terminal_x/a.zig"):
            with self.subTest(path=path):
                self.assertFalse(resolver.route_matches("src/terminal/**", path))

    def test_middle_globstar(self) -> None:
        for path in ("a/b.zig", "a/x/b.zig", "a/x/y/b.zig"):
            with self.subTest(path=path):
                self.assertTrue(resolver.route_matches("a/**/b.zig", path))
        self.assertFalse(resolver.route_matches("a/**/b.zig", "a/xb.zig"))

    def test_question_mark_and_literal_characters(self) -> None:
        self.assertTrue(resolver.route_matches("po/??.po", "po/de.po"))
        self.assertFalse(resolver.route_matches("po/??.po", "po/es_AR.po"))
        self.assertTrue(resolver.route_matches("pkg/afl++/**", "pkg/afl++/build.zig"))
        self.assertFalse(resolver.route_matches("pkg/afl++/**", "pkg/afl/build.zig"))
        self.assertFalse(resolver.route_matches("build.zig.zon", "buildxzigxzon"))


class ProseUnitsTest(unittest.TestCase):
    def test_paragraphs_and_list_items_are_units(self) -> None:
        text = (
            "# 标题\n\n第一段\n第二行\n\n- 项一\n  续行\n- 项二\n\n"
            "| 列 a | 列 b |\n|---|---|\n\n```bash\ncode line\n```\n"
        )
        units = resolver.prose_units(text)
        for expected in ("第一段 第二行", "项一 续行", "项二", "项一 续行 项二"):
            with self.subTest(unit=expected):
                self.assertIn(expected, units)
        self.assertFalse(any("code line" in unit or "标题" in unit or "列 a" in unit for unit in units))

    def test_crlf_input(self) -> None:
        self.assertEqual(resolver.prose_units("甲\r\n乙\r\n\r\n丙\r\n"), {"甲 乙", "丙"})


class SchemaTest(TempRepoCase):
    def assert_schema_error(self, old: str, new: str, fragment: str) -> None:
        self.edit_routes(old, new)
        with self.assertRaises(resolver.RuleManifestError) as ctx:
            resolver.load_rule_routes(self.root)
        self.assertIn(fragment, str(ctx.exception))

    def test_fixture_loads(self) -> None:
        routes = resolver.load_rule_routes(self.root)
        self.assertEqual(routes.version, 3)
        self.assertEqual([rule.id for rule in routes.rules], ["code-review", "core", "development", "ui"])
        self.assertEqual(routes.allowed_tasks, ("review", "sync", "test"))
        self.assertEqual(routes.nested_agents, ("lib/core/AGENTS.md",))

    def test_version_must_be_3(self) -> None:
        self.assert_schema_error("version = 3", "version = 2", "schema 版本")

    def test_top_level_keys_must_match_exactly(self) -> None:
        cases = {
            "missing": ('nested_agents = [\n  "lib/core/AGENTS.md",\n]\n', ""),
            "extra": ("root_max_bytes = 16384\n", 'root_max_bytes = 16384\nextra = "x"\n'),
        }
        for name, (old, new) in cases.items():
            with self.subTest(case=name):
                self.assert_schema_error(old, new, "顶层键")

    def test_root_max_bytes_is_fixed(self) -> None:
        self.assert_schema_error("root_max_bytes = 16384", "root_max_bytes = 32768", "固定为 16384")

    def test_rule_keys_must_match_exactly(self) -> None:
        self.assert_schema_error('tasks = ["review"]', 'tasks = ["review"]\nnote = "x"', "恰好包含 id/doc/paths/tasks")

    def test_doc_must_follow_id(self) -> None:
        self.assert_schema_error('doc = "docs/AGENT_RULES/ui.md"', 'doc = "docs/AGENT_RULES/frontend.md"', "doc 必须是")

    def test_id_must_be_kebab_case(self) -> None:
        for bad in ("UI", "ui_x", "ui-", "ui--x"):
            with self.subTest(id=bad):
                self.assert_schema_error('id = "ui"', f'id = "{bad}"', "kebab-case")

    def test_duplicate_id_rejected(self) -> None:
        self.assert_schema_error('id = "ui"', 'id = "core"', "id 重复")

    def test_nested_agents_entries_are_subdirectory_agents_files(self) -> None:
        for bad in ("AGENTS.md", "lib/core/README.md", "lib/*/AGENTS.md", "lib/../AGENTS.md"):
            with self.subTest(entry=bad):
                self.assert_schema_error('"lib/core/AGENTS.md"', f'"{bad}"', "nested_agents")

    def test_catch_all_and_malformed_patterns_rejected(self) -> None:
        cases = {
            "**": "万能兜底",
            "**/*": "万能兜底",
            "ui**": "独占",
            "ui/**/**": "连续",
            "ui\\\\x.zig": "无效",
            "/ui/**": "相对 POSIX",
            "ui/../x": "相对 POSIX",
            "ui/": "相对 POSIX",
        }
        for pattern, fragment in cases.items():
            with self.subTest(pattern=pattern):
                self.assert_schema_error('"ui/**"', f'"{pattern}"', fragment)

    def test_rule_needs_paths_or_tasks(self) -> None:
        self.assert_schema_error('tasks = ["review"]', "tasks = []", "至少声明")

    def test_duplicate_entries_rejected(self) -> None:
        self.assert_schema_error('  "lib/core.zig",\n', '  "lib/core.zig",\n  "lib/core.zig",\n', "重复项")

    def test_task_names_must_be_kebab_case(self) -> None:
        self.assert_schema_error('tasks = ["test"]', 'tasks = ["Test"]', "kebab-case")

    def test_rules_must_be_non_empty(self) -> None:
        header = ROUTES.split("[[rules]]", 1)[0]
        self.write(ROUTES_REL, header + "rules = []\n")
        with self.assertRaises(resolver.RuleManifestError) as ctx:
            resolver.load_rule_routes(self.root)
        self.assertIn("非空", str(ctx.exception))

    def test_invalid_toml_reported(self) -> None:
        self.write(ROUTES_REL, "version = \n")
        with self.assertRaises(resolver.RuleManifestError) as ctx:
            resolver.load_rule_routes(self.root)
        self.assertIn("TOML", str(ctx.exception))

    def test_crlf_routes_parse(self) -> None:
        self.write(ROUTES_REL, ROUTES, crlf=True)
        routes = resolver.load_rule_routes(self.root)
        self.assertEqual([rule.id for rule in routes.rules], ["code-review", "core", "development", "ui"])


class ResolveTest(TempRepoCase):
    def test_file_resolves_domain_and_upstream_agents(self) -> None:
        self.assertEqual(self.resolve("lib/core/page.zig"), [DOC("core"), "lib/core/AGENTS.md"])
        self.assertEqual(self.resolve("lib/core/deep/nested.zig"), [DOC("core"), "lib/core/AGENTS.md"])

    def test_sibling_prefix_does_not_inherit_upstream_agents(self) -> None:
        self.assertEqual(self.resolve("lib/core.zig"), [DOC("core")])
        self.assertEqual(self.resolve("ui/window.zig"), [DOC("ui")])

    def test_directory_expands_to_union(self) -> None:
        expected = [DOC("core"), DOC("development"), DOC("ui"), "lib/core/AGENTS.md"]
        self.assertEqual(self.resolve("lib"), expected)
        self.assertEqual(self.resolve("."), expected)

    def test_multiple_paths_union(self) -> None:
        self.assertEqual(self.resolve("ui/window.zig", "scripts/tool.py"), [DOC("development"), DOC("ui")])

    def test_not_yet_created_routed_paths_accepted(self) -> None:
        self.assertEqual(self.resolve("ui/future/panel.zig"), [DOC("ui")])
        self.assertEqual(self.resolve("lib/core/new/thing.zig"), [DOC("core"), "lib/core/AGENTS.md"])
        self.assertFalse((self.root / "ui" / "future").exists())

    def test_root_only_paths_produce_no_docs(self) -> None:
        self.assertEqual(self.resolve("README.md", "LICENSE"), [])

    def test_root_agents_is_never_listed(self) -> None:
        lines = self.resolve("AGENTS.md")
        self.assertEqual(lines, [DOC("development")])
        self.assertNotIn("AGENTS.md", lines)

    def test_tasks_add_task_docs(self) -> None:
        self.assertEqual(self.resolve("lib/core.zig", tasks=("test",)), [DOC("core"), DOC("ui")])
        self.assertEqual(self.resolve(tasks=("review", "sync")), [DOC("code-review"), DOC("development")])

    def test_scope_paths_are_normalized(self) -> None:
        absolute = str(self.root / "lib" / "core" / "page.zig")
        for raw in (absolute, "lib\\core\\page.zig", "./lib//core/page.zig", "lib/core/./page.zig"):
            with self.subTest(raw=raw):
                resolution = resolver.resolve_rules(self.root, [raw])
                self.assertEqual(resolution.scope, ("lib/core/page.zig",))
                self.assertEqual(resolution.lines(), [DOC("core"), "lib/core/AGENTS.md"])

    def test_dot_dot_and_outside_paths_rejected(self) -> None:
        cases = {
            "lib/../lib/core.zig": "'..'",
            "lib\\..\\lib\\core.zig": "'..'",
            str(self.root.parent / "elsewhere.zig"): "越出仓库",
        }
        for raw, fragment in cases.items():
            with self.subTest(raw=raw):
                self.assertIn(fragment, self.resolve_error(raw))

    def test_unknown_path_rejected(self) -> None:
        message = self.resolve_error("zzz/unknown.txt")
        self.assertIn("未登记领域路由", message)
        self.assertIn("zzz/unknown.txt（不存在）", message)
        self.write("orphan.txt", "x\n")
        message = self.resolve_error("orphan.txt")
        self.assertIn("orphan.txt", message)
        self.assertNotIn("orphan.txt（不存在）", message)

    def test_unknown_task_lists_allowed_tasks(self) -> None:
        message = self.resolve_error("lib/core.zig", tasks=("deploy",))
        self.assertIn("deploy", message)
        self.assertIn("允许的任务：review, sync, test", message)

    def test_requires_path_or_task(self) -> None:
        self.assertIn("至少提供", self.resolve_error())

    def test_directory_without_visible_files_rejected(self) -> None:
        self.write("out/artifact.bin", b"\x00")
        self.assertIn("不含 Git 可见文件", self.resolve_error("out"))
        self.assertIn("未登记领域路由", self.resolve_error("out/artifact.bin"))

    def test_scope_overlapping_root_only_rejected(self) -> None:
        self.edit_routes('  "README.md",\n]', '  "README.md",\n  "lib/core.zig",\n]')
        self.assertIn("同时命中", self.resolve_error("lib/core.zig"))

    def test_missing_matched_doc_rejected(self) -> None:
        self.remove("docs/AGENT_RULES/ui.md")
        message = self.resolve_error("ui/window.zig")
        self.assertIn(DOC("ui"), message)
        self.assertIn("不存在", message)
        self.assertEqual(self.resolve("lib/core.zig"), [DOC("core")])

    def test_missing_upstream_agents_rejected(self) -> None:
        self.remove("lib/core/AGENTS.md")
        self.assertIn("lib/core/AGENTS.md", self.resolve_error("lib/core/page.zig"))


class CliTest(TempRepoCase):
    def test_text_output_lists_docs_then_upstream_agents(self) -> None:
        result = self.run_cli("lib/core/page.zig", "ui/window.zig")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [DOC("core"), DOC("ui"), "lib/core/AGENTS.md"])
        self.assertEqual(result.stderr, "")

    def test_json_shape(self) -> None:
        result = self.run_cli("--json", "--task", "review", "lib\\core\\page.zig", "ui")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(set(payload), {"version", "scope", "tasks", "rules", "upstream_agents"})
        self.assertEqual(payload["version"], 3)
        self.assertEqual(payload["scope"], ["lib/core/page.zig", "ui"])
        self.assertEqual(payload["tasks"], ["review"])
        self.assertEqual(
            payload["rules"],
            [
                {"id": "code-review", "doc": DOC("code-review")},
                {"id": "core", "doc": DOC("core")},
                {"id": "ui", "doc": DOC("ui")},
            ],
        )
        self.assertEqual(payload["upstream_agents"], ["lib/core/AGENTS.md"])

    def test_json_for_root_only_scope(self) -> None:
        result = self.run_cli("--json", "README.md")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual((payload["rules"], payload["upstream_agents"]), ([], []))

    def test_options_may_be_interleaved_with_paths(self) -> None:
        result = self.run_cli("lib/core.zig", "--task", "review", "ui/window.zig")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [DOC("code-review"), DOC("core"), DOC("ui")])

    def test_errors_exit_2(self) -> None:
        cases = {
            ("zzz/unknown.txt",): "未登记领域路由",
            ("lib/core.zig", "--task", "deploy"): "允许的任务",
            ("--check", "lib/core.zig"): "--check",
            ("--check", "--json"): "--check",
            (): "至少提供",
        }
        for args, fragment in cases.items():
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn(fragment, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_check_success_summary(self) -> None:
        result = self.run_cli("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("OK:"), result.stdout)
        self.assertIn("4 份领域规则", result.stdout)
        self.assertIn("1 份上游嵌套 AGENTS.md", result.stdout)

    def test_check_failure_reports_every_problem(self) -> None:
        self.write("orphan.txt", "x\n")
        self.write("AGENTS.md", "# guide without marker\n")
        result = self.run_cli("--check")
        self.assertEqual(result.returncode, 2)
        lines = result.stderr.splitlines()
        self.assertGreaterEqual(len(lines), 2)
        self.assertTrue(all(line.startswith("error: ") for line in lines), lines)
        self.assertIn("fork 段标记", result.stderr)
        self.assertIn("orphan.txt", result.stderr)


class CheckTest(TempRepoCase):
    def test_valid_repository_passes(self) -> None:
        summary = resolver.validate_repository(self.root)
        self.assertEqual(summary.file_count, len(FILES))
        self.assertEqual(len(summary.routes.rules), 4)

    def test_ignored_files_are_outside_the_closure(self) -> None:
        self.write("out/artifact.bin", b"\x00")
        resolver.validate_repository(self.root)

    def test_root_agents_size_limit(self) -> None:
        head = f"# guide\n\n{MARKER}\n\n"
        at_limit = head + "x" * (16384 - len(head.encode("utf-8")) - 1) + "\n"
        self.assertEqual(len(at_limit.encode("utf-8")), 16384)
        self.write("AGENTS.md", at_limit)
        resolver.validate_repository(self.root)
        self.write("AGENTS.md", at_limit + "x\n")
        self.check_error("16386 bytes", "超过 root_max_bytes=16384")

    def test_fork_marker_required_once_at_line_start(self) -> None:
        cases = {
            "missing": ("# guide\n\nbody\n", "缺少 fork 段标记"),
            "inline": (f"# guide\n\nsee {MARKER}\n", "缺少 fork 段标记"),
            "twice": (f"# guide\n\n{MARKER}\n\nbody\n\n{MARKER}\n", "恰好 1 次"),
        }
        for name, (content, fragment) in cases.items():
            with self.subTest(case=name):
                self.write("AGENTS.md", content)
                self.check_error(fragment)

    def test_root_agents_must_be_utf8_regular_file(self) -> None:
        self.write("AGENTS.md", b"# guide\n\xff\xfe\n" + MARKER.encode("utf-8") + b"\n")
        self.check_error("UTF-8")
        self.remove("AGENTS.md")
        self.check_error("根 AGENTS.md 必须是普通文件")

    def test_root_only_domain_overlap(self) -> None:
        self.edit_routes('  "README.md",\n]', '  "README.md",\n  "lib/core.zig",\n]')
        self.check_error("重叠", "lib/core.zig")

    def test_unregistered_nested_agents(self) -> None:
        self.write("ui/AGENTS.md", "# new upstream guide\n")
        self.check_error("未登记的嵌套 AGENTS.md", "ui/AGENTS.md")

    def test_registered_nested_agents_missing(self) -> None:
        self.remove("lib/core/AGENTS.md")
        self.check_error("过期条目", "lib/core/AGENTS.md")

    def test_unsorted_rules(self) -> None:
        header, review, core, development, ui = ROUTES.split("[[rules]]")
        self.write(ROUTES_REL, "[[rules]]".join([header, review, development, core, ui]))
        self.check_error("rules 必须按 id 排序")

    def test_unsorted_lists(self) -> None:
        cases = {
            "paths": (
                '  "lib/core.zig",\n  "lib/core/**",\n',
                '  "lib/core/**",\n  "lib/core.zig",\n',
                "规则 core 的 paths 必须排序",
            ),
            "tasks": ('tasks = ["sync"]', 'tasks = ["sync", "release"]', "规则 development 的 tasks 必须排序"),
            "root_only": ('  "LICENSE",\n  "README.md",\n', '  "README.md",\n  "LICENSE",\n', "root_only 必须排序"),
            "nested_agents": (
                '  "lib/core/AGENTS.md",\n',
                '  "ui/AGENTS.md",\n  "lib/core/AGENTS.md",\n',
                "nested_agents 必须排序",
            ),
        }
        self.write("ui/AGENTS.md", "# ui upstream guide\n")
        for name, (old, new, fragment) in cases.items():
            with self.subTest(field=name):
                self.edit_routes(old, new)
                self.check_error(fragment)

    def test_unregistered_doc(self) -> None:
        self.write("docs/AGENT_RULES/extra.md", "# extra\n")
        self.check_error("未登记的领域文档", "docs/AGENT_RULES/extra.md")

    def test_missing_doc(self) -> None:
        self.remove("docs/AGENT_RULES/ui.md")
        self.check_error("登记的领域文档不存在", DOC("ui"))

    def test_empty_or_oversized_doc(self) -> None:
        cases = {"empty": ("", "领域文档为空"), "blank": ("\n\n", "领域文档为空"), "large": ("x" * 16385, "超过 16384")}
        for name, (content, fragment) in cases.items():
            with self.subTest(case=name):
                self.write("docs/AGENT_RULES/ui.md", content)
                self.check_error(fragment, DOC("ui"))

    def test_zero_match_patterns(self) -> None:
        cases = {
            "glob": ('  "lib/core/**",\n', '  "lib/core/**",\n  "lib/missing/**",\n', "core 的 pattern 未命中任何 Git 可见文件：lib/missing/**"),
            "literal": ('  "docs/**",\n', '  "docs/**",\n  "justfile",\n', "development 的 pattern 未命中任何 Git 可见文件：justfile"),
            "root_only": ('  "LICENSE",\n', '  "LICENSE",\n  "NOTICE",\n', "root_only 的 pattern 未命中任何 Git 可见文件：NOTICE"),
        }
        for name, (old, new, fragment) in cases.items():
            with self.subTest(case=name):
                self.edit_routes(old, new)
                self.check_error(fragment)

    def test_ignored_files_do_not_satisfy_patterns(self) -> None:
        self.write("out/artifact.bin", b"\x00")
        self.edit_routes('  "docs/**",\n', '  "docs/**",\n  "out/**",\n')
        self.check_error("pattern 未命中任何 Git 可见文件：out/**")

    def test_uncovered_file(self) -> None:
        self.write("orphan.txt", "x\n")
        self.write("misc/notes/todo.md", "x\n")
        self.check_error("未登记路由", "orphan.txt", "misc/notes/todo.md")

    def test_duplicate_paragraph_across_docs(self) -> None:
        self.assertGreaterEqual(len(LONG_PROSE), resolver.DUPLICATE_PARAGRAPH_MIN_CHARS)
        self.write("docs/AGENT_RULES/core.md", f"# core\n\n## 范围\n\n{LONG_PROSE}\n")
        self.write("docs/AGENT_RULES/ui.md", f"# ui\n\n## 不变量\n\n{_wrap(LONG_PROSE, 37)}\n")
        self.check_error("重复段落", DOC("core"), DOC("ui"))

    def test_duplicate_list_item_inside_different_lists(self) -> None:
        self.write("docs/AGENT_RULES/core.md", f"# core\n\n- 第一项\n- {LONG_PROSE}\n")
        self.write("docs/AGENT_RULES/ui.md", f"# ui\n\n1. 别的项\n2. {_wrap(LONG_PROSE, 50)}\n3. 再一项\n", crlf=True)
        self.check_error("重复段落", DOC("core"), DOC("ui"))

    def test_allowed_repetition(self) -> None:
        short = "这是一段很短的重复文字，长度远低于阈值。"
        core = (
            f"# core\n\n{short}\n\n```text\n{LONG_PROSE}\n```\n\n| 列 | {LONG_PROSE} |\n\n"
            f"{LONG_PROSE}\n\n{LONG_PROSE}\n"
        )
        ui = f"# ui\n\n{short}\n\n```text\n{LONG_PROSE}\n```\n\n| 列 | {LONG_PROSE} |\n"
        self.write("docs/AGENT_RULES/core.md", core)
        self.write("docs/AGENT_RULES/ui.md", ui)
        self.write("docs/AGENT_RULES/README.md", f"# AGENT_RULES\n\n{LONG_PROSE}\n")
        resolver.validate_repository(self.root)

    def test_crlf_checkout_passes(self) -> None:
        for relative, content in FILES.items():
            if relative.endswith((".md", ".toml")):
                self.write(relative, content, crlf=True)
        resolver.validate_repository(self.root)
        self.assertEqual(self.resolve("lib/core/page.zig"), [DOC("core"), "lib/core/AGENTS.md"])

    def test_all_problems_reported_together(self) -> None:
        self.write("AGENTS.md", "# guide\n")
        self.write("orphan.txt", "x\n")
        self.write("docs/AGENT_RULES/extra.md", "# extra\n")
        message = self.check_error("fork 段标记", "orphan.txt", "extra.md")
        self.assertGreaterEqual(len(message.splitlines()), 3)

    def test_schema_error_reported_with_root_problems(self) -> None:
        self.write("AGENTS.md", "# guide\n")
        self.edit_routes("version = 3", "version = 2")
        self.check_error("fork 段标记", "schema 版本")

    def test_git_failure_reported_with_collected_problems(self) -> None:
        shutil.rmtree(self.root / ".git")
        self.write("AGENTS.md", "# guide\n")
        with mock.patch.dict(os.environ, {"GIT_CEILING_DIRECTORIES": str(self.root.parent)}):
            self.check_error("git ls-files 失败", "fork 段标记")


TERMINAL_C = "src/terminal/c/terminal.zig"
PO_FILE = "po/de.po"
SWIFT_FILE = "macos/Sources/App/AppDelegate.swift"


class RealRepoRoutesTest(unittest.TestCase):
    """真实 routes.toml 的 schema、排序、任务表与嵌套登记表；不依赖领域文档是否已写完。"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.routes = resolver.load_rule_routes(REPO_ROOT)
        cls.files = resolver.repository_files(REPO_ROOT)

    def test_schema_sorting_and_root_only(self) -> None:
        self.assertEqual(self.routes.version, 3)
        self.assertEqual(resolver.sort_problems(self.routes), [])
        self.assertEqual(self.routes.root_only, (".gitmodules", ".mailmap", "LICENSE"))

    def test_task_routes(self) -> None:
        by_task = {
            task: [rule.id for rule in self.routes.rules if task in rule.tasks] for task in self.routes.allowed_tasks
        }
        self.assertEqual(
            by_task,
            {
                "release": ["ci-release"],
                "review": ["code-review"],
                "sync": ["ci-release", "development"],
                "test": ["testing"],
            },
        )
        review = next(rule for rule in self.routes.rules if rule.id == "code-review")
        self.assertEqual(review.paths, ())

    def test_nested_agents_registry_matches_repository(self) -> None:
        self.assertEqual(len(self.routes.nested_agents), 9)
        self.assertEqual(resolver.nested_agents_problems(self.routes, self.files), [])

    def test_routing_union(self) -> None:
        matcher = resolver.RouteMatcher(self.routes)
        cases = {
            TERMINAL_C: ["libghostty-vt", "terminal-core"],
            PO_FILE: ["apprt-gtk"],
            SWIFT_FILE: ["macos-app"],
            "src/apprt/embedded.zig": ["app-core", "libghostty-embedding", "macos-app"],
            "README.md": ["development"],
            "LICENSE": [],
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(matcher.rule_ids(path), expected)
        self.assertTrue(matcher.in_root_only("LICENSE"))
        self.assertFalse(matcher.in_root_only("README.md"))


class RealRepoSmokeTest(unittest.TestCase):
    """真实仓库 CLI 冒烟（只读）：从仓库外的 cwd 调用，验证默认根取自脚本位置。"""

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RESOLVER), *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=CHILD_ENV,
            cwd=tempfile.gettempdir(),
            timeout=120,
            check=False,
        )

    def assert_lines(self, args: tuple[str, ...], expected: list[str]) -> None:
        result = self.run_cli(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), expected)

    def test_terminal_c_api_file(self) -> None:
        self.assert_lines(
            (TERMINAL_C,),
            [DOC("libghostty-vt"), DOC("terminal-core"), "src/terminal/c/AGENTS.md"],
        )

    def test_translation_file(self) -> None:
        self.assert_lines((PO_FILE,), [DOC("apprt-gtk")])

    def test_macos_swift_file(self) -> None:
        self.assert_lines((SWIFT_FILE,), [DOC("macos-app"), "macos/AGENTS.md"])

    def test_review_task(self) -> None:
        self.assert_lines(("--task", "review"), [DOC("code-review")])

    def test_json_upstream_agents(self) -> None:
        result = self.run_cli("--json", TERMINAL_C)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["version"], 3)
        self.assertEqual(payload["scope"], [TERMINAL_C])
        self.assertEqual([rule["id"] for rule in payload["rules"]], ["libghostty-vt", "terminal-core"])
        self.assertEqual(payload["upstream_agents"], ["src/terminal/c/AGENTS.md"])


if __name__ == "__main__":
    unittest.main()
