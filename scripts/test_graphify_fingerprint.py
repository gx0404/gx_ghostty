#!/usr/bin/env python3
"""graphify 指纹与固定入口的行为测试。

在临时 Git 仓库里验证：被索引文件改动 → 过期；排除文件改动 → 不过期；管线改动 → 过期；
graph.json 缺失可容忍；CRLF 检出与 LF 指纹一致；排除表语义与真实 .graphifyignore；
scripts/graphify.py 的子命令守门、CLI 查找、钉版校验，以及用假 graphify 跑通 rebuild。
不需要安装 graphify，不触碰真实仓库的 graphify-out/。
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import graphify_fingerprint as fp  # noqa: E402


def _load_wrapper():
    spec = importlib.util.spec_from_file_location("gx_graphify_wrapper", SCRIPTS_DIR / "graphify.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


wrapper = _load_wrapper()

TEST_IGNORE = """\
# 测试用排除表（镜像真实 .graphifyignore 的几类写法）
/test/
/vendor/
pkg/*/vendor/
src/font/nerd_font_*.zig
*.json
/docs/
/scripts/
"""

INCLUDED = {
    "src/main.zig": "pub fn main() void {}\n",
    "src/terminal/Terminal.zig": "pub const Terminal = struct {};\n",
    "include/ghostty/vt.h": "int ghostty_vt(void);\n",
    "macos/Sources/App.swift": "struct App {}\n",
    "src/shell-integration/bash/ghostty.bash": "echo ghostty\n",
    "src/renderer/shaders/shaders.metal": "kernel void k() {}\n",
}

EXCLUDED = {
    "test/fixture.zig": "const x = 1;\n",
    "vendor/glad/gl.c": "int gl;\n",
    "pkg/simdutf/vendor/simdutf.cpp": "int simd;\n",
    "src/font/nerd_font_tables.zig": "pub const table = 1;\n",
    "docs/guide.md": "# guide\n",
    "src/build/Config.zig": "pub const version = 1;\n",
    "src/apprt/gtk/build/blueprint.zig": "pub const x = 1;\n",
    "macos/Assets/Contents.json": "{}\n",
    "README.md": "# readme\n",
    "src/config/config-template": "font-size = 12\n",
}

FAKE_GRAPHIFY = r'''
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
log = os.environ.get("FAKE_GRAPHIFY_LOG")
if log:
    with open(log, "a", encoding="utf-8") as handle:
        keys = ("GRAPHIFY_OUT", "PYTHONHASHSEED", "GRAPHIFY_NO_AUTO_REFRESH")
        record = {"args": args, "cwd": os.getcwd(), "env": {key: os.environ.get(key) for key in keys}}
        handle.write(json.dumps(record) + "\n")
if args[:1] == ["--version"]:
    print("graphify " + os.environ.get("FAKE_GRAPHIFY_VERSION", "0.9.73"))
    sys.exit(0)
if args and args[0] == os.environ.get("FAKE_GRAPHIFY_FAIL"):
    sys.exit(3)
out = Path.cwd() / "graphify-out"
if args[:1] == ["extract"]:
    out.mkdir(exist_ok=True)
    (out / "graph.json").write_text('{"nodes": []}\n', encoding="utf-8")
elif args[:1] == ["cluster-only"]:
    (out / "GRAPH_REPORT.md").write_bytes(b"# Graph Report\r\n\r\n- nodes: 0\r\n")
sys.exit(0)
'''


def _git_env() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def git_init(root: Path) -> None:
    subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True, env=_git_env())


def write(root: Path, rel: str, content: str | bytes) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
    return path


def make_fake_cli(directory: Path, name: str = "graphify") -> Path:
    script = directory / "fake_graphify.py"
    script.write_text(FAKE_GRAPHIFY, encoding="utf-8")
    if os.name == "nt":
        launcher = directory / f"{name}.cmd"
        launcher.write_text(f'@"{sys.executable}" "{script}" %*\r\n', encoding="utf-8")
    else:
        launcher = directory / name
        launcher.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n', encoding="utf-8")
        launcher.chmod(0o755)
    return launcher


def quiet(func, *args, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return func(*args, **kwargs)


class TempRepoCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "repo"
        self.root.mkdir()
        git_init(self.root)
        write(self.root, ".graphifyignore", TEST_IGNORE)
        write(self.root, "scripts/graphify.py", "# pipeline wrapper\n")
        write(self.root, "scripts/graphify_fingerprint.py", "# pipeline fingerprint\n")
        for rel, content in {**INCLUDED, **EXCLUDED}.items():
            write(self.root, rel, content)
        write(self.root, "graphify-out/GRAPH_REPORT.md", "# Graph Report\n\n- nodes: 3\n")
        write(self.root, "graphify-out/graph.json", '{"nodes": [1, 2, 3]}\n')

    def write_fingerprint(self) -> None:
        quiet(fp.write_fingerprint, self.root)

    def assert_stale(self, pattern: str) -> None:
        with self.assertRaisesRegex(fp.FingerprintError, pattern):
            fp.check_fingerprint(self.root)

    def assert_fresh(self) -> list[str]:
        return fp.check_fingerprint(self.root)


class FingerprintTests(TempRepoCase):
    def test_source_set_mirrors_graphify_selection(self) -> None:
        self.assertEqual(fp.graph_sources(self.root), sorted(INCLUDED))

    def test_write_then_check_is_clean_and_deterministic(self) -> None:
        self.write_fingerprint()
        self.assertEqual(self.assert_fresh(), [])
        target = self.root / "graphify-out" / "source-fingerprint.json"
        raw = target.read_bytes()
        self.assertNotIn(b"\r", raw)
        self.assertTrue(raw.endswith(b"\n"))
        payload = json.loads(raw.decode("utf-8"))
        self.assertEqual(raw.decode("utf-8"), fp.render(payload))
        self.assertEqual(payload["schema_version"], fp.SCHEMA_VERSION)
        self.assertEqual(payload["source"]["file_count"], len(INCLUDED))
        self.assertEqual(sorted(payload["pipeline"]), sorted(fp.PIPELINE_INPUTS))
        self.assertEqual(sorted(payload["artifacts"]), ["GRAPH_REPORT.md", "graph.json"])
        self.write_fingerprint()
        self.assertEqual(target.read_bytes(), raw)

    def test_included_source_change_marks_stale(self) -> None:
        self.write_fingerprint()
        write(self.root, "src/terminal/Terminal.zig", "pub const Terminal = struct { rows: u16 };\n")
        self.assert_stale("源码指纹已变化")

    def test_added_and_deleted_sources_mark_stale(self) -> None:
        self.write_fingerprint()
        write(self.root, "src/termio/Exec.zig", "pub fn exec() void {}\n")
        self.assert_stale(f"{len(INCLUDED)} → {len(INCLUDED) + 1}")
        (self.root / "src/termio/Exec.zig").unlink()
        self.assertEqual(self.assert_fresh(), [])
        (self.root / "src/main.zig").unlink()
        self.assert_stale("源码指纹已变化")

    def test_excluded_and_unindexed_changes_keep_graph_fresh(self) -> None:
        self.write_fingerprint()
        for rel, content in EXCLUDED.items():
            write(self.root, rel, content + "// changed\n")
        for rel in (
            "test/new_case.zig",
            "vendor/glad/new.c",
            "pkg/freetype/vendor/ft.c",
            "src/font/nerd_font_attributes.zig",
            "docs/AGENT_RULES/new.md",
            "src/build/framegen/main.c",
            "dist/linux/helper.py",
            "macos/Assets/Other/Contents.json",
            "src/config/notes.txt",
        ):
            write(self.root, rel, "new\n")
        self.assertEqual(self.assert_fresh(), [])

    def test_gitignored_untracked_file_is_not_a_source(self) -> None:
        write(self.root, ".gitignore", "zig-out/\n")
        self.write_fingerprint()
        write(self.root, "zig-out/generated.zig", "pub const generated = 1;\n")
        self.assertEqual(self.assert_fresh(), [])

    def test_crlf_checkout_matches_lf_fingerprint(self) -> None:
        self.write_fingerprint()
        for rel in [*INCLUDED, ".graphifyignore", "scripts/graphify.py"]:
            path = self.root / rel
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(self.assert_fresh(), [])

    def test_pipeline_change_marks_stale(self) -> None:
        self.write_fingerprint()
        ignore = self.root / ".graphifyignore"
        original = ignore.read_bytes()
        ignore.write_bytes(original + b"# comment only\n")
        self.assert_stale(r"管线输入已变化：\.graphifyignore")
        ignore.write_bytes(original)
        self.assertEqual(self.assert_fresh(), [])
        write(self.root, "scripts/graphify.py", "# pipeline wrapper v2\n")
        self.assert_stale(r"管线输入已变化：scripts/graphify\.py")

    def test_missing_graph_json_is_tolerated(self) -> None:
        self.write_fingerprint()
        (self.root / "graphify-out" / "graph.json").unlink()
        notes = self.assert_fresh()
        self.assertEqual(len(notes), 1)
        self.assertIn("graph.json", notes[0])
        self.assertEqual(quiet(fp.main, ["check", "--root", str(self.root)]), 0)

    def test_local_graph_json_drift_marks_stale(self) -> None:
        self.write_fingerprint()
        write(self.root, "graphify-out/graph.json", '{"nodes": []}\n')
        self.assert_stale("graph.json 与指纹不一致")

    def test_report_is_normalized_and_check_never_rewrites(self) -> None:
        report = self.root / "graphify-out" / "GRAPH_REPORT.md"
        report.write_bytes(b"# Graph Report\r\n\r\nbody\r\n")
        self.write_fingerprint()
        self.assertEqual(report.read_bytes(), b"# Graph Report\n\nbody\n")
        fingerprint = self.root / "graphify-out" / "source-fingerprint.json"
        before = fingerprint.read_bytes()
        report.write_bytes(b"# Graph Report\n\nedited by hand\n")
        self.assert_stale("GRAPH_REPORT.md 与指纹不一致")
        self.assertEqual(report.read_bytes(), b"# Graph Report\n\nedited by hand\n")
        self.assertEqual(fingerprint.read_bytes(), before)

    def test_report_with_crlf_checkout_still_matches(self) -> None:
        self.write_fingerprint()
        report = self.root / "graphify-out" / "GRAPH_REPORT.md"
        report.write_bytes(report.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(self.assert_fresh(), [])

    def test_missing_fingerprint_report_or_ignore_file(self) -> None:
        self.assert_stale("缺少 graphify-out/source-fingerprint.json")
        (self.root / "graphify-out" / "GRAPH_REPORT.md").unlink()
        with self.assertRaisesRegex(fp.FingerprintError, "GRAPH_REPORT.md"):
            fp.write_fingerprint(self.root)
        (self.root / ".graphifyignore").unlink()
        with self.assertRaisesRegex(fp.FingerprintError, r"\.graphifyignore"):
            fp.graph_sources(self.root)

    def test_cli_exit_codes(self) -> None:
        self.assertEqual(quiet(fp.main, ["check", "--root", str(self.root)]), 2)
        self.assertEqual(quiet(fp.main, ["write", "--root", str(self.root)]), 0)
        self.assertEqual(quiet(fp.main, ["check", "--root", str(self.root)]), 0)
        write(self.root, "src/main.zig", "pub fn main() !void {}\n")
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = fp.main(["check", "--root", str(self.root)])
        self.assertEqual(code, 2)
        self.assertIn("just graph", stderr.getvalue())

    def test_extensionless_files_follow_shebang(self) -> None:
        write(self.root, "tools/run-sh", "#!/usr/bin/env -S bash -e\necho hi\n")
        write(self.root, "tools/run-py", "#!/usr/bin/python3\nprint(1)\n")
        write(self.root, "tools/run-nu", "#!/usr/bin/env nu\nprint 1\n")
        write(self.root, "tools/plain", "no shebang\n")
        sources = fp.graph_sources(self.root)
        self.assertIn("tools/run-sh", sources)
        self.assertIn("tools/run-py", sources)
        self.assertNotIn("tools/run-nu", sources)
        self.assertNotIn("tools/plain", sources)


class IgnoreRuleTests(unittest.TestCase):
    def rules(self, text: str) -> list:
        return fp.parse_ignore_rules(text)

    def test_anchored_patterns_basename_patterns_and_globs(self) -> None:
        rules = self.rules("/test/\nvendor/\n*.json\nsrc/font/nerd_font_*.zig\npkg/*/vendor/\n")
        ignored = [
            "test/a.zig",
            "x/vendor/a.c",
            "vendor/a.c",
            "a/b/c.json",
            "src/font/nerd_font_tables.zig",
            "pkg/simdutf/vendor/simdutf.cpp",
        ]
        kept = [
            "src/test/a.zig",
            "test.zig",
            "src/font/sub/nerd_font_x.zig",
            "src/font/nerd_font_codegen.py",
            "pkg/simdutf/src/x.cpp",
            "pkgs/a/vendor.c",
        ]
        for rel in ignored:
            self.assertTrue(fp.is_ignored(rel, rules), rel)
        for rel in kept:
            self.assertFalse(fp.is_ignored(rel, rules), rel)

    def test_directory_only_pattern_does_not_match_files(self) -> None:
        rules = self.rules("build/\n")
        self.assertFalse(fp.is_ignored("src/build", rules))
        self.assertTrue(fp.is_ignored("src/build/Config.zig", rules))

    def test_double_star(self) -> None:
        rules = self.rules("**/gen/*.zig\ndocs/**\na/**/b.zig\n")
        for rel in ("gen/a.zig", "x/y/gen/c.zig", "docs/x/y.md", "a/b.zig", "a/x/y/b.zig"):
            self.assertTrue(fp.is_ignored(rel, rules), rel)
        for rel in ("gen/sub/a.zig", "docs.md", "a/b.zig.txt", "b/a/c.zig"):
            self.assertFalse(fp.is_ignored(rel, rules), rel)

    def test_negation_and_parent_exclusion(self) -> None:
        rules = self.rules("src/*\n!src/keep.zig\n/vendor/\n!vendor/keep.c\n")
        self.assertFalse(fp.is_ignored("src/keep.zig", rules))
        self.assertTrue(fp.is_ignored("src/other.zig", rules))
        self.assertTrue(fp.is_ignored("vendor/keep.c", rules))

    def test_crlf_comments_blank_lines_and_escapes(self) -> None:
        rules = self.rules("# comment\r\n\r\n/test/\r\n  \r\n\\#literal\r\n")
        self.assertEqual([rule.pattern for rule in rules], ["test", "#literal"])
        self.assertTrue(fp.is_ignored("test/a.zig", rules))

    def test_graphify_noise_dirs(self) -> None:
        for rel in ("src/build/Config.zig", "dist/x.c", "a/node_modules/x.js", "a/x_venv/b.py",
                    ".claude/worktrees/x/y.py", "a/b.egg-info/c.py"):
            self.assertTrue(fp.in_noise_dir(rel), rel)
        for rel in ("src/builder/x.zig", "build.zig", "src/worktrees/x.zig", "src/out/x.zig"):
            self.assertFalse(fp.in_noise_dir(rel), rel)

    def test_contract_extensions_are_indexed(self) -> None:
        self.assertLessEqual(set(fp.CONTRACT_EXTENSIONS), fp.INDEXED_EXTENSIONS)


class RealIgnoreTableTests(unittest.TestCase):
    """只读解析真实 .graphifyignore，锁定附录 C 的排除项与框架目录。"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.rules = fp.load_ignore_rules(REPO_ROOT)

    def excluded(self, rel: str) -> bool:
        return fp.is_ignored(rel, self.rules) or fp.in_noise_dir(rel)

    def test_contract_exclusions(self) -> None:
        for rel in (
            "test/ucs-detect.sh",
            "vendor/glad/src/gl.c",
            "po/de.po",
            "images/icons/x.png",
            "dist/linux/ghostty_nautilus.py",
            "flatpak/zig-packages.json",
            "snap/local/launcher",
            "nix/build-support/check-zig-cache.sh",
            ".github/scripts/check-translations.sh",
            "example/c-vt/src/main.c",
            "src/font/res/x.c",
            "src/build/framegen/main.c",
            "src/stb/main.zig",
            "src/font/nerd_font_attributes.zig",
            "src/font/nerd_font_tables.zig",
            "src/font/nerd_font_codepoint_tables.py",
            "pkg/simdutf/vendor/simdutf.cpp",
            "pkg/fontconfig/override/config.h",
            "src/shell-integration/bash/bash-preexec.sh",
            "build.zig.zon.json",
        ):
            self.assertTrue(self.excluded(rel), rel)

    def test_framework_and_tool_dirs_are_excluded(self) -> None:
        for directory in ("docs", "scripts", ".claude", ".codex", ".zcode", ".agents", ".githooks",
                          "graphify-out", ".local", ".github"):
            self.assertTrue(self.excluded(f"{directory}/x.py"), directory)

    def test_product_sources_stay_indexed(self) -> None:
        for rel in (
            "build.zig",
            "src/terminal/Terminal.zig",
            "src/renderer/shaders/shaders.metal",
            "src/shell-integration/bash/ghostty.bash",
            "src/font/nerd_font_codegen.py",
            "include/ghostty/vt/terminal.h",
            "include/ghostty.h",
            "macos/Sources/App/macOS/AppDelegate.swift",
            "pkg/freetype/main.zig",
            "pkg/highway/src/cpp/abort.cc",
            "pkg/wuffs/src/png.zig",
        ):
            self.assertFalse(self.excluded(rel), rel)

    def test_pipeline_inputs_exist(self) -> None:
        for rel in fp.PIPELINE_INPUTS:
            self.assertTrue((REPO_ROOT / rel).is_file(), rel)


class WrapperGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

    def run_guarded(self, argv: list[str]) -> int:
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = wrapper.main(["--root", str(self.root), *argv])
        self.last_stderr = stderr.getvalue()
        return code

    def test_graph_override_is_rejected_before_running_graphify(self) -> None:
        for argv in (["query", "renderer", "--graph", "other.json"], ["path", "A", "B", "--graph=x.json"],
                     ["explain", "Terminal", "--graph", "x"]):
            self.assertEqual(self.run_guarded(argv), 2, argv)
            self.assertIn("禁止覆盖", self.last_stderr)

    def test_other_subcommands_are_refused(self) -> None:
        for command in ("extract", "update", "cluster-only", "label", "install", "uninstall", "hook",
                        "watch", "export", "tree", "merge-graphs", "global", "clone", "add",
                        "save-result", "reflect", "affected"):
            self.assertEqual(self.run_guarded([command]), 2, command)
            self.assertIn("不支持的子命令", self.last_stderr)

    def test_rebuild_and_check_take_no_arguments(self) -> None:
        self.assertEqual(self.run_guarded(["rebuild", "--force"]), 2)
        self.assertEqual(self.run_guarded(["check", "extra"]), 2)

    def test_usage(self) -> None:
        self.assertEqual(self.run_guarded([]), 2)
        self.assertEqual(self.run_guarded(["--help"]), 0)

    def test_passthrough_args(self) -> None:
        graph = ["--graph", "graphify-out/graph.json"]
        self.assertEqual(
            wrapper.passthrough_args("query", ["renderer", "thread", "--budget", "500"]),
            ["query", "renderer thread", "--budget", "500", *graph],
        )
        self.assertEqual(wrapper.passthrough_args("explain", ["Terminal"]), ["explain", "Terminal", *graph])
        self.assertEqual(
            wrapper.passthrough_args("path", ["Terminal", "Screen", "--undirected"]),
            ["path", "Terminal", "Screen", "--undirected", *graph],
        )
        for command, args in (("path", ["Terminal"]), ("query", []), ("query", ["--dfs"])):
            with self.assertRaises(wrapper.GraphifyError):
                wrapper.passthrough_args(command, args)

    def test_query_requires_local_graph(self) -> None:
        self.assertEqual(self.run_guarded(["query", "renderer"]), 1)
        self.assertIn("just graph", self.last_stderr)


class WrapperCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        base = Path(self._tmp.name)
        self.root = base / "repo"
        self.root.mkdir()
        self.bin = base / "bin"
        self.bin.mkdir()
        self.log = base / "graphify.log"
        self.cli = make_fake_cli(self.bin)
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GX_GHOSTTY_", "GRAPHIFY_", "FAKE_GRAPHIFY_", "GIT_"))
            and key != "PYTHONHASHSEED"
        }
        self.env["FAKE_GRAPHIFY_LOG"] = str(self.log)

    def calls(self) -> list[dict]:
        if not self.log.is_file():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def test_cli_lookup_precedence(self) -> None:
        env = {"PATH": str(self.bin), wrapper.CLI_ENV: str(self.cli)}
        self.assertEqual(wrapper.resolve_cli(self.root, env), [str(self.cli)])
        venv = wrapper.venv_cli(self.root)
        python = wrapper.venv_python(self.root)
        for path in (venv, python):
            write(self.root, path.relative_to(self.root).as_posix(), "fake")
            if os.name != "nt":
                path.chmod(0o755)
        # venv 内的 graphify 一律经 venv python -m graphify 运行，从不直接执行生成的启动器。
        self.assertEqual(wrapper.resolve_cli(self.root, {"PATH": str(self.bin)}), [str(python), "-m", "graphify"])
        venv.unlink()
        found = wrapper.resolve_cli(self.root, {"PATH": str(self.bin)})
        self.assertEqual(len(found), 1)
        self.assertEqual(Path(found[0]).parent, self.bin)
        self.assertEqual(Path(found[0]).stem.lower(), "graphify")
        empty = self.root / "empty"
        empty.mkdir()
        with self.assertRaisesRegex(wrapper.GraphifyError, "just setup"):
            wrapper.resolve_cli(self.root, {"PATH": str(empty)})
        with self.assertRaisesRegex(wrapper.GraphifyError, wrapper.CLI_ENV):
            wrapper.resolve_cli(self.root, {"PATH": str(empty), wrapper.CLI_ENV: str(self.root / "nope.exe")})

    def test_version_must_match_pin_unless_explicitly_allowed(self) -> None:
        env = dict(self.env, FAKE_GRAPHIFY_VERSION="0.9.20")
        with self.assertRaisesRegex(wrapper.GraphifyError, "0.9.20 != 钉版 0.9.73"):
            wrapper.ensure_version([str(self.cli)], env)
        wrapper.ensure_version([str(self.cli)], dict(env, **{wrapper.ALLOW_ANY_VERSION_ENV: "1"}))
        wrapper.ensure_version([str(self.cli)], self.env)
        self.assertEqual(wrapper.PINNED_VERSION, "0.9.73")

    def test_pin_and_venv_path_match_setup_env(self) -> None:
        path = SCRIPTS_DIR / "setup_env.py"
        if not path.is_file():
            self.skipTest("scripts/setup_env.py 不存在")
        spec = importlib.util.spec_from_file_location("gx_setup_env_for_graphify_test", path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        sys.modules[spec.name] = module
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(module)
        self.assertEqual(module.GRAPHIFY_VERSION, wrapper.PINNED_VERSION)
        self.assertEqual(
            module.venv_executable(module.venv_dir(self.root), "graphify"),
            wrapper.venv_cli(self.root),
        )

    def _seed_repo(self) -> None:
        git_init(self.root)
        for rel in fp.PIPELINE_INPUTS:
            shutil.copyfile(REPO_ROOT / rel, write(self.root, rel, b""))
        write(self.root, "src/main.zig", "pub fn main() void {}\n")

    def test_rebuild_runs_pinned_pipeline_and_writes_fingerprint(self) -> None:
        self._seed_repo()
        env = dict(self.env, **{wrapper.CLI_ENV: str(self.cli)})
        self.assertEqual(quiet(wrapper.run_command, ["rebuild"], self.root, env), 0)
        calls = self.calls()
        self.assertEqual([call["args"] for call in calls],
                         [["--version"], list(wrapper.EXTRACT_ARGS), list(wrapper.CLUSTER_ARGS)])
        self.assertEqual(
            wrapper.EXTRACT_ARGS,
            ("extract", ".", "--out", ".", "--force", "--code-only", "--no-cluster", "--max-workers", "4"),
        )
        self.assertEqual(
            wrapper.CLUSTER_ARGS,
            ("cluster-only", ".", "--graph", "graphify-out/graph.json", "--no-viz", "--no-label"),
        )
        for call in calls[1:]:
            self.assertEqual(Path(call["cwd"]).resolve(), self.root.resolve())
            self.assertEqual(call["env"],
                             {"GRAPHIFY_OUT": "graphify-out", "PYTHONHASHSEED": "0", "GRAPHIFY_NO_AUTO_REFRESH": "1"})
        report = self.root / "graphify-out" / "GRAPH_REPORT.md"
        self.assertNotIn(b"\r", report.read_bytes())
        self.assertEqual(fp.check_fingerprint(self.root), [])
        self.assertEqual(quiet(wrapper.run_command, ["check"], self.root, env), 0)
        write(self.root, "src/main.zig", "pub fn main() !void {}\n")
        self.assertEqual(quiet(wrapper.main, ["--root", str(self.root), "check"]), 2)

    def test_rebuild_stops_on_graphify_failure(self) -> None:
        self._seed_repo()
        env = dict(self.env, **{wrapper.CLI_ENV: str(self.cli), "FAKE_GRAPHIFY_FAIL": "extract"})
        with self.assertRaises(wrapper.GraphifyError) as caught:
            quiet(wrapper.run_command, ["rebuild"], self.root, env)
        self.assertEqual(caught.exception.code, 3)
        self.assertFalse((self.root / "graphify-out" / "source-fingerprint.json").exists())

    def test_rebuild_refuses_wrong_version_before_extracting(self) -> None:
        self._seed_repo()
        env = dict(self.env, **{wrapper.CLI_ENV: str(self.cli), "FAKE_GRAPHIFY_VERSION": "1.0.0"})
        with self.assertRaises(wrapper.GraphifyError):
            quiet(wrapper.run_command, ["rebuild"], self.root, env)
        self.assertEqual([call["args"] for call in self.calls()], [["--version"]])

    def test_query_passthrough_pins_graph(self) -> None:
        write(self.root, "graphify-out/graph.json", "{}\n")
        env = dict(self.env, **{wrapper.CLI_ENV: str(self.cli)})
        self.assertEqual(quiet(wrapper.run_command, ["query", "renderer", "thread"], self.root, env), 0)
        last = self.calls()[-1]
        self.assertEqual(last["args"], ["query", "renderer thread", "--graph", "graphify-out/graph.json"])
        self.assertEqual(last["env"]["GRAPHIFY_OUT"], "graphify-out")
        self.assertEqual(last["env"]["GRAPHIFY_NO_AUTO_REFRESH"], "1")
        self.assertIsNone(last["env"]["PYTHONHASHSEED"])


if __name__ == "__main__":
    unittest.main()
