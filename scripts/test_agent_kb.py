#!/usr/bin/env python3
"""知识库行为测试。

1. 单元测试（临时语料，任何时候都应通过）：Markdown 切块、分片上限、文档注释摘要、Zig 与
   C 头文件的结构抽取、语料闭集、schema 2 布局与逐文档来源哈希、check/--confirm 退出码与
   原子写入、确定性、BM25 检索器、chunk id 推导与 CLI。
2. 真实语料测试：docs/kb/chunks.json 与当前语料一致（缺失即失败，提示运行 just kb）、
   每份领域文档都在库、schema 与体积预算、≥12 条中英文与代码符号检索回归、乱码查询无命中。
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import agent_kb  # noqa: E402
import build_agent_kb  # noqa: E402

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:
        tomllib = None  # type: ignore[assignment]

KB_PATH = REPO_ROOT / "docs" / "kb" / "chunks.json"
SIZE_BUDGET_BYTES = int(2.5 * 1024 * 1024)
PAYLOAD_KEYS = ["schema_version", "doc_fields", "chunk_fields", "doc_count", "chunk_count", "docs"]

# (查询, 期望命中：任一文档出现在 top-8 即通过)
GOLDEN_QUERIES = [
    ("嵌套 AGENTS 登记", ["docs/AGENT_RULES/README.md"]),
    ("libghostty-vt C API export", ["docs/AGENT_RULES/libghostty-vt.md", "src/terminal/c/AGENTS.md"]),
    ("发版 tag gx-v", ["docs/RELEASE.md", "docs/AGENT_RULES/ci-release.md"]),
    ("renderer thread mailbox", ["docs/AGENT_RULES/renderer.md"]),
    ("Config doc comment Pandoc", ["docs/AGENT_RULES/config.md"]),
    ("update-translations", ["docs/AGENT_RULES/apprt-gtk.md"]),
    ("fork patch Config.zig tag", ["docs/FORK_PATCHES.md"]),
    ("OpenGL context 单线程 current", ["docs/AGENT_RULES/renderer.md"]),
    ("上游同步 merge main 冲突", ["docs/DEVELOPMENT.md", "docs/AGENT_RULES/development.md"]),
    (
        "提交规范 type(scope) 中文描述",
        ["AGENTS.md", "docs/DEVELOPMENT.md", "docs/AGENT_RULES/development.md", "docs/AGENT_RULES/ci-release.md"],
    ),
    (
        "图谱 指纹 graph-check",
        ["docs/AGENT_RULES/development.md", "docs/DEVELOPMENT.md", "docs/MAKE_COMMANDS.md", "docs/TESTING.md"],
    ),
    ("hook 危险命令 拒绝 dangerous_patterns", ["docs/AI_TOOLS.md", "docs/AGENT_RULES/development.md"]),
    ("processOutput 数据流 pty 读线程", ["docs/AGENT_RULES/termio-pty-os.md", "docs/ARCHITECTURE.md"]),
    ("macOS build.nu Xcode 构建", ["docs/AGENT_RULES/macos-app.md", "macos/AGENTS.md"]),
    ("审核 严重 中 轻 结论", ["docs/AGENT_RULES/code-review.md"]),
    ("_MAX_VALUE GHOSTTY_ENUM_MAX_VALUE 哨兵", ["docs/AGENT_RULES/libghostty-vt.md", "AGENTS.md"]),
    ("ghostty_terminal_new", ["include/ghostty/vt/terminal.h"]),
    ("blueprint i18n gettext po", ["docs/AGENT_RULES/apprt-gtk.md"]),
    ("scrollback compression", ["src/terminal/compress/AGENTS.md", "docs/AGENT_RULES/terminal-core.md"]),
    (
        "知识库 BM25 kb-query",
        ["docs/AGENT_RULES/development.md", "docs/MAKE_COMMANDS.md", "docs/README.md", "docs/DEVELOPMENT.md"],
    ),
    ("GTK 截图 gtk-smoke PENDING", ["docs/AGENT_RULES/testing.md", "docs/TESTING.md", "docs/AGENT_RULES/ci-release.md"]),
    (
        "Windows just test win32 windows-gnu ghostty-test",
        ["docs/AGENT_RULES/testing.md", "docs/AGENT_RULES/build-system.md", "AGENTS.md", "docs/TESTING.md"],
    ),
    ("Windows win32 apprt WGL Direct2D 消息循环", ["docs/AGENT_RULES/apprt-win32.md"]),
    ("GUI 截图 kimi-cu 隔离 LOCALAPPDATA", ["docs/AGENT_RULES/apprt-win32.md"]),
    ("gui-settings.ghostty 配置分层 GX 默认值", ["docs/AGENT_RULES/gx-core.md", "docs/FORK_PATCHES.md"]),
    ("gx.i18n.tr 翻译 gx.zh_CN.po just i18n", ["docs/AGENT_RULES/gx-core.md", "docs/AGENT_RULES/apprt-gtk.md"]),
    ("GX-0007 随包 ConPTY", ["docs/FORK_PATCHES.md"]),
    ("ghostty_key_encoder_encode", ["include/ghostty/vt/key/encoder.h"]),
    ("lockDemand unlockDemand", ["src/renderer/State.zig"]),
    ("updateFrame drawFrame", ["src/renderer/generic.zig"]),
    ("WM_DPICHANGED handleDpiChange", ["src/apprt/win32/Window.zig"]),
]
GARBAGE_QUERY = "zzqqxxw qqzzwwk"

ZIG_SAMPLE = """\
//! Terminal core module.
//! Second line.
//!
//!
//! +------+------+
//! | cols | rows |
//! \U0001cc00 \U0001cc01 \U0001cc02

const std = @import("std");

/// Doc line one.
/// Doc line two.
/// Doc line three.
/// Doc line four.
pub fn init(
    alloc: std.mem.Allocator,
    opts: Options,
) !Terminal {
    const s = "{ not a brace";
    _ = s;
    return undefined;
}

fn private() void {}

pub const Options = struct {
    cols: u16 = 80,

    /// Nested doc.
    pub fn validate(self: Options) bool {
        return self.cols > 0;
    }
};

test { std.testing.refAllDecls(@This()); }

pub const max_cols: u16 = 500;

const text =
    \\\\{ multiline brace
;

test "helper" {
    const Helper = struct {
        pub fn hidden() void {}
    };
    _ = Helper;
}

/// Global flag summary sentence. This second sentence is long enough that appending it would push
/// the summary past the budget.
pub var global_flag: bool = false;

pub const Mailbox = BlockingQueue(Message, 64);
pub const Screen = @import("Screen.zig");
pub const Alias = terminal.Terminal;
pub const log = std.log.scoped(.terminal);
pub const enabled = true;
pub const Kind = enum(u8) { a, b };
pub const Error = error{ OutOfMemory, Invalid };
pub const Callback = *const fn (u8) void;
pub const default: Options = .{};
pub extern "c" fn ghostty_ext(x: c_int) c_int;
"""

ZIG_EXPECTED = """\
Terminal core module.
Second line.

| cols | rows |

fn init(alloc: std.mem.Allocator, opts: Options) !Terminal — Doc line one. Doc line two. Doc line three.
const Options = struct
  fn validate(self: Options) bool — Nested doc.
const max_cols: u16
var global_flag: bool — Global flag summary sentence.
const Mailbox = BlockingQueue(Message, 64)
const Screen = @import("Screen.zig")
const Alias = terminal.Terminal
const log
const enabled
const Kind = enum(u8)
const Error = error
const Callback = *const fn (u8) void
const default: Options
extern "c" fn ghostty_ext(x: c_int) c_int"""

HEADER_SAMPLE = """\
/**
 * @file demo.h
 *
 * Demo header brief.
 */
#ifndef GHOSTTY_VT_DEMO_H
#define GHOSTTY_VT_DEMO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup demo Demo
 *
 * Demo group brief.
 *
 * @{
 */

/** Size helper. */
#define GHOSTTY_DEMO_SIZE(type) \\
  (sizeof(type))

/**
 * Demo modes.
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** First mode. */
  GHOSTTY_DEMO_ONE = 1,
  GHOSTTY_DEMO_TWO = 2,
  GHOSTTY_DEMO_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDemoMode;

/** Demo options. */
typedef struct {
  size_t size;
  uint16_t cols;
  union { int a; float b; } value;
  char name[16];
} GhosttyDemoOptions;

/** Opaque demo handle. */
typedef struct GhosttyDemoImpl* GhosttyDemo;

/**
 * Create a demo.
 *
 * @param out Where to store the handle
 * @return GHOSTTY_SUCCESS on success
 *
 * @ingroup demo
 */
GHOSTTY_API GhosttyResult ghostty_demo_new(const GhosttyDemoOptions* options,
                                           GhosttyDemo* out);

/** Pack a mode. */
static inline uint16_t ghostty_demo_pack(uint16_t value) {
  return value & 0x7FFF;
}

/** Free a demo. */
GHOSTTY_API void ghostty_demo_free(GhosttyDemo demo);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_DEMO_H */
"""

HEADER_EXPECTED = """\
@file Demo header brief.
@defgroup demo Demo — Demo group brief.
#define GHOSTTY_DEMO_SIZE(type) — Size helper.
typedef enum GhosttyDemoMode { GHOSTTY_DEMO_ONE, GHOSTTY_DEMO_TWO, GHOSTTY_DEMO_MAX_VALUE } — Demo modes.
typedef struct GhosttyDemoOptions { size, cols, value, name } — Demo options.
typedef struct GhosttyDemoImpl* GhosttyDemo — Opaque demo handle.
GHOSTTY_API GhosttyResult ghostty_demo_new(const GhosttyDemoOptions* options, GhosttyDemo* out) — \
Create a demo. @param out Where to store the handle @return GHOSTTY_SUCCESS on success
static inline uint16_t ghostty_demo_pack(uint16_t value) — Pack a mode.
GHOSTTY_API void ghostty_demo_free(GhosttyDemo demo) — Free a demo."""

TEMP_CORPUS = {
    "AGENTS.md": "# Root\n\n## Rules\nroot rules about renderer\n",
    "src/terminal/c/AGENTS.md": "# C API\n\nexport functions\n",
    "README.md": "# Readme\n\nintro text\n",
    "CHANGELOG.md": "# Changelog\n\n## 0.1.0(TBD)\n\n- first\n",
    "docs/guide.md": "# 指南\n\n## 范围\n渲染线程 mailbox\n",
    "docs/AGENT_RULES/renderer.md": "# renderer\n\n## 不变量\nOpenGL context 单线程\n",
    "docs/deep/nested.md": "# nested\n\nnot in corpus\n",
    "notes.md": "# notes\n\nnot in corpus\n",
    "src/terminal/Terminal.zig": "//! Terminal.\npub fn init() void {\n    var x: u8 = 0;\n    _ = &x;\n}\n",
    "src/font/nerd_font_tables.zig": "pub const table = 1;\n",
    "src/stb/main.zig": "pub fn stb() void {}\n",
    "src/build/framegen/gen.zig": "pub fn gen() void {}\n",
    "src/build/Config.zig": "pub const Config = struct {};\n",
    "src/terminal/kitty/dnd_test.zig": "pub fn helper() void {}\n",
    "include/ghostty/vt/demo.h": HEADER_SAMPLE,
    "include/other.h": "int other(void);\n",
}


def _git_env() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def make_repo(base: Path, files: dict[str, str | bytes]) -> Path:
    root = base / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True, env=_git_env())
    for rel, content in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
    return root


def run_cli(main, argv: list[str]) -> tuple[int, str, str]:
    stdout, stderr = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        code = main(argv)
    return code, stdout.getvalue(), stderr.getvalue()


def assert_payload_shape(case: unittest.TestCase, payload: dict) -> None:
    case.assertEqual(list(payload), PAYLOAD_KEYS)
    case.assertEqual(payload["schema_version"], build_agent_kb.SCHEMA_VERSION)
    case.assertEqual(payload["schema_version"], agent_kb.SCHEMA_VERSION)
    case.assertEqual(payload["doc_fields"], ["path", "source_sha256", "chunks"])
    case.assertEqual(payload["chunk_fields"], ["anchor", "text"])
    docs = payload["docs"]
    paths = [entry[0] for entry in docs]
    case.assertEqual(paths, sorted(set(paths)), "docs 必须按路径排序且不重复")
    case.assertEqual(payload["doc_count"], len(docs))
    case.assertEqual(payload["chunk_count"], sum(len(entry[2]) for entry in docs))
    for entry in docs:
        case.assertEqual(len(entry), 3, entry[0])
        path, digest, chunks = entry
        case.assertFalse(Path(path).is_absolute(), path)
        case.assertNotIn("\\", path)
        case.assertRegex(digest, r"^[0-9a-f]{64}$")
        case.assertTrue(chunks, path)
        cap = build_agent_kb.MAX_DOC_CHARS if path.endswith(".md") else build_agent_kb.MAX_CODE_CHARS
        for chunk in chunks:
            case.assertEqual(len(chunk), 2, path)
            anchor, text = chunk
            case.assertTrue(anchor and text.strip(), path)
            case.assertNotIn("\r", text, path)
            case.assertLessEqual(len(text), cap, f"{path}#{anchor}")
    case.assertEqual(json.loads(build_agent_kb.render(payload)), payload, "render 必须无损")
    ids = [chunk["id"] for chunk in agent_kb.expand_docs(docs)]
    case.assertEqual(len(ids), len(set(ids)), "推导的 chunk id 必须唯一")


class ChunkingTests(unittest.TestCase):
    def test_markdown_sections_use_heading_paths(self) -> None:
        text = "preamble\n# T\n\n## A\nalpha\n### A1\nbeta\n## B\ngamma\n##### deep\nstill gamma\n"
        sections = build_agent_kb.split_markdown(text)
        self.assertEqual([anchor for anchor, _ in sections], ["_top", "T > A", "T > A > A1", "T > B"])
        self.assertTrue(sections[1][1].startswith("## A\nalpha"))
        self.assertIn("##### deep\nstill gamma", sections[3][1])

    def test_fenced_code_blocks_are_not_split(self) -> None:
        text = "# T\n## S\n```bash\n# comment\n## not a heading\n```\nafter\n~~~\n# also code\n~~~\n"
        sections = build_agent_kb.split_markdown(text)
        self.assertEqual([anchor for anchor, _ in sections], ["T > S"])
        self.assertIn("# comment", sections[0][1])
        self.assertIn("# also code", sections[0][1])

    def test_parts_respect_cap_and_never_blank(self) -> None:
        self.assertEqual(build_agent_kb.split_parts("a" * 9 + "\n\n" + "x" * 20, 10), ["a" * 9, "x" * 10, "x" * 10])
        parts = build_agent_kb.split_parts("x" * 12 + "\n  \n\t\n" + "y" * 12 + "\n   ", 10)
        self.assertTrue(all(part.strip() for part in parts), parts)
        self.assertTrue(all(len(part) <= 10 for part in parts), parts)
        long_line = "word " * 400
        wrapped = build_agent_kb.split_parts(long_line, 1500)
        self.assertTrue(all(len(part) <= 1500 for part in wrapped))
        self.assertEqual(" ".join(" ".join(wrapped).split()), long_line.strip())

    def test_section_chunks_and_derived_ids(self) -> None:
        self.assertEqual(
            build_agent_kb.section_chunks("范围 > 不变量", "\nalpha\n\nbeta\n", 100),
            [["范围 > 不变量", "alpha\n\nbeta"]],
        )
        self.assertEqual(
            build_agent_kb.section_chunks("anchor", "a" * 8 + "\n" + "b" * 8, 10),
            [["anchor", "a" * 8], ["anchor", "b" * 8]],
        )
        self.assertEqual(build_agent_kb.section_chunks("anchor", "\n  \n", 10), [])
        docs = [["docs/说明.md", "0" * 64, [["范围 > 不变量", "x"], ["范围 > 不变量", "y"], ["其他", "z"]]]]
        chunks = agent_kb.expand_docs(docs)
        self.assertEqual(
            [chunk["id"] for chunk in chunks],
            ["docs/说明.md#范围 > 不变量", "docs/说明.md#范围 > 不变量~2", "docs/说明.md#其他"],
        )
        self.assertEqual(chunks[1], {"id": "docs/说明.md#范围 > 不变量~2", "doc": "docs/说明.md",
                                     "anchor": "范围 > 不变量", "text": "y"})
        for bad in ([["a.md", "0" * 64]], [["a.md", "0" * 64, [["anchor"]]]], [{"path": "a.md"}]):
            with self.assertRaises(ValueError):
                agent_kb.expand_docs(bad)

    def test_changelog_keeps_recent_head_only(self) -> None:
        lines = [f"- entry {index:04d} " + "x" * 40 for index in range(200)]
        source = build_agent_kb.doc_source("CHANGELOG.md", "# Changelog\n" + "\n".join(lines))
        self.assertLessEqual(len(source), build_agent_kb.CHANGELOG_HEAD_CHARS)
        chunks = build_agent_kb.doc_chunks("CHANGELOG.md", source)
        self.assertEqual({anchor for anchor, _ in chunks}, {"recent"})
        joined = "\n".join(text for _, text in chunks)
        self.assertLessEqual(len(joined), build_agent_kb.CHANGELOG_HEAD_CHARS)
        self.assertIn("entry 0000", joined)
        self.assertNotIn("entry 0199", joined)
        self.assertTrue(all(line.endswith("x") for line in joined.splitlines()[1:]))
        self.assertEqual(build_agent_kb.doc_source("docs/guide.md", "x" * 7000), "x" * 7000)

    def test_doc_brief_keeps_whole_sentences_within_budget(self) -> None:
        brief = build_agent_kb.doc_brief
        self.assertEqual(brief(["A one.", "B two.", "C three.", "D four."]), "A one. B two. C three.")
        long_tail = "Second sentence " + "y" * build_agent_kb.MAX_SUMMARY_CHARS + "."
        self.assertEqual(brief(["First sentence.", long_tail]), "First sentence.")
        first = "Long first sentence " + "z" * build_agent_kb.MAX_SUMMARY_CHARS + "."
        self.assertEqual(brief([first, "Short."]), first)
        self.assertEqual(brief(["Use e.g. lowercase continuations.", "Then `ticks`."]),
                         "Use e.g. lowercase continuations. Then `ticks`.")
        self.assertEqual(brief(["Create a demo.", "@param out Where to store"]), "Create a demo. @param out Where to store")


class CodeStructureTests(unittest.TestCase):
    def test_zig_structure(self) -> None:
        self.assertEqual(build_agent_kb.zig_structure(ZIG_SAMPLE), ZIG_EXPECTED)

    def test_zig_structure_ignores_crlf(self) -> None:
        self.assertEqual(build_agent_kb.zig_structure(ZIG_SAMPLE.replace("\n", "\r\n")), ZIG_EXPECTED)

    def test_zig_module_doc_is_capped_at_a_line_boundary(self) -> None:
        cap = build_agent_kb.MAX_MODULE_DOC_CHARS
        lines = [f"//! Paragraph line {index:05d} " + "w" * 50 for index in range(cap // 40)]
        doc = build_agent_kb.zig_module_doc(lines + ["", "pub fn after() void {}"])
        self.assertEqual(doc[-1], "…")
        self.assertLessEqual(sum(len(line) + 1 for line in doc[:-1]), cap)
        self.assertEqual(doc[:-1], [line[4:] for line in lines[: len(doc) - 1]])
        self.assertEqual(build_agent_kb.zig_module_doc(["//! Short.", "//!", "pub fn x() void {}"]), ["Short."])
        self.assertEqual(build_agent_kb.zig_structure("pub fn x() void {}\n"), "fn x() void")

    def test_zig_exclusions(self) -> None:
        for rel in ("src/font/nerd_font_tables.zig", "src/font/nerd_font_attributes.zig", "src/stb/main.zig",
                    "src/build/framegen/x/y.zig", "src/terminal/kitty/dnd_test.zig", "src/lib/tinyio/test.zig"):
            self.assertTrue(build_agent_kb.is_excluded_zig(rel), rel)
        for rel in ("src/build/Config.zig", "src/terminal/Terminal.zig", "src/lib/compat/testing.zig"):
            self.assertFalse(build_agent_kb.is_excluded_zig(rel), rel)

    def test_header_structure(self) -> None:
        self.assertEqual(build_agent_kb.header_structure(HEADER_SAMPLE), HEADER_EXPECTED)


class BuildTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = Path(self._tmp.name)

    def test_corpus_is_the_git_visible_closed_set(self) -> None:
        files = dict(TEMP_CORPUS, **{".gitignore": "docs/ignored.md\n", "docs/ignored.md": "# ignored\n\nx\n"})
        root = make_repo(self.base, files)
        payload = build_agent_kb.build_payload(root)
        assert_payload_shape(self, payload)
        by_doc = {path: (digest, chunks) for path, digest, chunks in payload["docs"]}
        self.assertEqual(
            sorted(by_doc),
            [
                "AGENTS.md",
                "CHANGELOG.md",
                "README.md",
                "docs/AGENT_RULES/renderer.md",
                "docs/guide.md",
                "include/ghostty/vt/demo.h",
                "src/build/Config.zig",
                "src/terminal/Terminal.zig",
                "src/terminal/c/AGENTS.md",
            ],
        )
        self.assertEqual(by_doc["src/terminal/Terminal.zig"][1], [["structure", "Terminal.\n\nfn init() void"]])
        self.assertEqual({anchor for anchor, _ in by_doc["include/ghostty/vt/demo.h"][1]}, {"declarations"})
        self.assertEqual(by_doc["CHANGELOG.md"][1], [["recent", "# Changelog\n\n## 0.1.0(TBD)\n\n- first"]])
        self.assertEqual(by_doc["docs/guide.md"][1], [["指南 > 范围", "## 范围\n渲染线程 mailbox"]])
        guide = TEMP_CORPUS["docs/guide.md"].rstrip("\n")
        self.assertEqual(by_doc["docs/guide.md"][0], hashlib.sha256(guide.encode("utf-8")).hexdigest())
        structure = "Terminal.\n\nfn init() void"
        self.assertEqual(by_doc["src/terminal/Terminal.zig"][0], hashlib.sha256(structure.encode("utf-8")).hexdigest())

    def test_output_is_deterministic_and_platform_neutral(self) -> None:
        root = make_repo(self.base, TEMP_CORPUS)
        payload = build_agent_kb.build_payload(root)
        first = build_agent_kb.render(payload)
        self.assertEqual(first, build_agent_kb.render(build_agent_kb.build_payload(root)))
        self.assertTrue(first.endswith("\n"))
        self.assertNotIn("\r", first)
        self.assertNotIn(root.as_posix(), first)
        self.assertNotIn(json.dumps(str(root))[1:-1], first)
        self.assertEqual(json.loads(first), payload)
        lines = first.splitlines()
        self.assertTrue(lines[0].startswith('{"schema_version":2,'), lines[0])
        self.assertTrue(lines[0].endswith('"docs":['), lines[0])
        self.assertEqual(lines[-1], "]}")
        doc_lines = [line for line in lines[1:-1] if not line.startswith(" ")]
        chunk_lines = [line for line in lines[1:-1] if line.startswith(" ")]
        self.assertEqual(len(doc_lines), payload["doc_count"])
        self.assertEqual(len(chunk_lines), payload["chunk_count"])
        self.assertEqual(doc_lines[0], f'["AGENTS.md","{payload["docs"][0][1]}",[')
        for rel in TEMP_CORPUS:
            path = root / rel
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(build_agent_kb.render(build_agent_kb.build_payload(root)), first)

    def test_body_edits_keep_kb_fresh_but_signature_edits_do_not(self) -> None:
        root = make_repo(self.base, TEMP_CORPUS)
        before = build_agent_kb.build_payload(root)
        zig = root / "src/terminal/Terminal.zig"
        zig.write_text("//! Terminal.\npub fn init() void {\n    var y: u16 = 1;\n    _ = &y;\n}\n", encoding="utf-8")
        self.assertEqual(build_agent_kb.build_payload(root), before)
        config = root / "src/build/Config.zig"
        config.write_text("pub const Config = struct { a: u8 };\npub const limit: u32 = 1;\n", encoding="utf-8")
        with_value = build_agent_kb.build_payload(root)
        config.write_text("pub const Config = struct { a: u16 };\npub const limit: u32 = 2;\n", encoding="utf-8")
        self.assertEqual(build_agent_kb.build_payload(root), with_value, "常量值与容器体改动不应让 KB 过期")
        zig.write_text("//! Terminal.\npub fn init(rows: u16) void {\n    _ = rows;\n}\n", encoding="utf-8")
        after = build_agent_kb.build_payload(root)
        self.assertEqual(build_agent_kb.changed_sources(with_value, after), ["src/terminal/Terminal.zig"])

    def test_cli_check_confirm_and_stale_listing(self) -> None:
        root = make_repo(self.base, TEMP_CORPUS)
        output = self.base / "out" / "chunks.json"
        argv = ["--root", str(root), "--output", str(output)]
        code, _, err = run_cli(build_agent_kb.main, argv)
        self.assertEqual(code, 1)
        self.assertIn("just kb", err)
        code, out, _ = run_cli(build_agent_kb.main, [*argv, "--confirm"])
        self.assertEqual(code, 0)
        self.assertIn("9 docs", out)
        self.assertIn("chunks", out)
        raw = output.read_bytes()
        self.assertNotIn(b"\r", raw)
        self.assertEqual(sorted(path.name for path in output.parent.iterdir()), ["chunks.json"])
        self.assertEqual(run_cli(build_agent_kb.main, argv)[0], 0)
        self.assertEqual(run_cli(build_agent_kb.main, [*argv, "--check"])[0], 0)
        output.write_bytes(raw.replace(b"\n", b"\r\n"))
        self.assertEqual(run_cli(build_agent_kb.main, argv)[0], 0, "CRLF 检出应视同 LF")
        output.write_bytes(raw)
        (root / "docs/guide.md").write_text("# 指南\n\n## 范围\n改过的内容\n", encoding="utf-8")
        (root / "docs/AGENT_RULES/new-domain.md").write_text("# new\n\nbody\n", encoding="utf-8")
        code, _, err = run_cli(build_agent_kb.main, argv)
        self.assertEqual(code, 1)
        self.assertIn("docs/guide.md", err)
        self.assertIn("docs/AGENT_RULES/new-domain.md", err)
        self.assertNotIn("README.md", err.replace("docs/AGENT_RULES/new-domain.md", ""))
        self.assertEqual(output.read_bytes(), raw, "check 模式不得写盘")
        output.write_text("{not json", encoding="utf-8")
        code, _, err = run_cli(build_agent_kb.main, argv)
        self.assertEqual(code, 1)
        self.assertIn("JSON", err)
        output.write_text(json.dumps({"schema_version": 1, "chunk_count": 0, "chunks": []}), encoding="utf-8")
        code, _, err = run_cli(build_agent_kb.main, argv)
        self.assertEqual(code, 1)
        self.assertIn("schema", err)
        self.assertIn("just kb", err)

    def test_default_output_path(self) -> None:
        self.assertEqual(build_agent_kb.DEFAULT_OUTPUT, "docs/kb/chunks.json")
        self.assertEqual(agent_kb.DEFAULT_KB, REPO_ROOT / "docs" / "kb" / "chunks.json")


TOY_CHUNKS = [
    {"id": "a", "doc": "docs/AGENT_RULES/renderer.md", "anchor": "renderer > 线程", "text": "渲染线程 mailbox 唤醒"},
    {"id": "b", "doc": "docs/AGENT_RULES/terminal-core.md", "anchor": "terminal", "text": "terminal parser state machine"},
    {"id": "c", "doc": "src/renderer/Thread.zig", "anchor": "structure",
     "text": "fn threadMain(self: *Thread) void — The main entrypoint for the thread."},
    {"id": "d", "doc": "docs/RELEASE.md", "anchor": "发版", "text": "发版 tag 为 gx-vX.Y.Z，经 gx-release 发布"},
]


def toy_kb_text() -> str:
    """TOY_CHUNKS 按 schema 2 写出的知识库文本。"""
    docs = sorted([chunk["doc"], "0" * 64, [[chunk["anchor"], chunk["text"]]]] for chunk in TOY_CHUNKS)
    return build_agent_kb.render({
        "schema_version": build_agent_kb.SCHEMA_VERSION,
        "doc_fields": list(build_agent_kb.DOC_FIELDS),
        "chunk_fields": list(build_agent_kb.CHUNK_FIELDS),
        "doc_count": len(docs),
        "chunk_count": len(docs),
        "docs": docs,
    })


class RetrieverTests(unittest.TestCase):
    def test_tokenizer(self) -> None:
        tokens = agent_kb.tokenize("PROTOCOL_VERSION 与 协议版本")
        for expected in ("protocol_version", "protocol", "version", "协议", "议版", "版本", "与"):
            self.assertIn(expected, tokens)
        tokens = agent_kb.tokenize("见 `src/renderer/Thread.zig::threadMain`。")
        for expected in ("src/renderer/thread.zig::threadmain", "renderer", "thread", "threadmain"):
            self.assertIn(expected, tokens)
        tokens = agent_kb.tokenize("图谱，指纹")
        self.assertIn("图谱", tokens)
        self.assertIn("指纹", tokens)
        self.assertNotIn("谱指", tokens)
        self.assertEqual(agent_kb.tokenize("a b"), [])

    def test_bm25_ranks_relevant_chunk_first(self) -> None:
        index = agent_kb.KBIndex(TOY_CHUNKS)
        self.assertEqual(index.search("renderer thread mailbox", 1)[0]["doc"], "docs/AGENT_RULES/renderer.md")
        self.assertEqual(index.search("threadMain", 1)[0]["doc"], "src/renderer/Thread.zig")
        self.assertEqual(index.search("发版 tag gx-v", 1)[0]["doc"], "docs/RELEASE.md")
        self.assertEqual(index.search("parser", 3)[0]["doc"], "docs/AGENT_RULES/terminal-core.md")
        results = index.search("renderer", 8)
        self.assertEqual({item["doc"] for item in results},
                         {"docs/AGENT_RULES/renderer.md", "src/renderer/Thread.zig"})
        self.assertTrue(all(set(item) == {"doc", "anchor", "id", "score", "excerpt"} for item in results))
        self.assertEqual([item["score"] for item in results], sorted((item["score"] for item in results), reverse=True))

    def test_query_expansion_bridges_english_and_chinese(self) -> None:
        weights = agent_kb.expand_query("renderer thread")
        self.assertEqual(weights["renderer"], 1.0)
        self.assertEqual(weights["thread"], 1.0)
        self.assertEqual(weights["渲染"], agent_kb.EXPANSION_WEIGHT)
        self.assertEqual(weights["线程"], agent_kb.EXPANSION_WEIGHT)
        weights = agent_kb.expand_query("渲染线程")
        self.assertEqual(weights["线程"], 1.0)
        for word in ("render", "renderer", "thread", "threads"):
            self.assertEqual(weights[word], agent_kb.EXPANSION_WEIGHT, word)
        self.assertEqual(agent_kb.expand_query("invariant"), {"invariant": 1.0, "不变": agent_kb.EXPANSION_WEIGHT})
        self.assertIn("invariant", agent_kb.expand_query("不变量"))
        self.assertEqual(agent_kb.expand_query(GARBAGE_QUERY), {"zzqqxxw": 1.0, "qqzzwwk": 1.0})

    def test_results_are_capped_per_doc(self) -> None:
        same = [{"id": f"s{index}", "doc": "docs/same.md", "anchor": "s", "text": "renderer mailbox"}
                for index in range(3)]
        index = agent_kb.KBIndex(same + TOY_CHUNKS)
        docs = [item["doc"] for item in index.search("renderer mailbox", 8)]
        self.assertEqual(docs.count("docs/same.md"), agent_kb.MAX_PER_DOC)
        docs = [item["doc"] for item in index.search("renderer mailbox", 8, per_doc=0)]
        self.assertEqual(docs.count("docs/same.md"), 3)

    def test_garbage_and_empty_queries_return_nothing(self) -> None:
        index = agent_kb.KBIndex(TOY_CHUNKS)
        self.assertEqual(index.search(GARBAGE_QUERY, 8), [])
        self.assertEqual(index.search("", 8), [])
        self.assertEqual(agent_kb.KBIndex([]).search("renderer", 8), [])

    def test_ranking_is_deterministic_and_top_is_respected(self) -> None:
        twin = {"anchor": "same", "text": "terminal parser"}
        twins = [dict(twin, id="t2", doc="x/two.md"), dict(twin, id="t1", doc="x/one.md")]
        index = agent_kb.KBIndex(twins + TOY_CHUNKS)
        first = index.search("terminal parser", 8)
        self.assertEqual(first, index.search("parser terminal parser", 8))
        tied = [item for item in first if item["doc"].startswith("x/")]
        self.assertEqual([item["doc"] for item in tied], ["x/one.md", "x/two.md"])
        self.assertEqual(tied[0]["score"], tied[1]["score"])
        self.assertEqual(len(index.search("terminal parser", 1)), 1)

    def test_cli(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            kb = Path(tmp) / "chunks.json"
            kb.write_text(toy_kb_text(), encoding="utf-8")
            code, out, _ = run_cli(agent_kb.main, ["renderer", "--top", "1", "mailbox", "--json", "--kb", str(kb)])
            self.assertEqual(code, 0)
            results = json.loads(out)
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0]["doc"], "docs/AGENT_RULES/renderer.md")
            self.assertEqual(results[0]["anchor"], "renderer > 线程")
            self.assertEqual(results[0]["id"], "docs/AGENT_RULES/renderer.md#renderer > 线程")
            code, out, _ = run_cli(agent_kb.main, ["渲染线程", "--kb", str(kb)])
            self.assertEqual(code, 0)
            self.assertIn("docs/AGENT_RULES/renderer.md", out)
            code, out, _ = run_cli(agent_kb.main, [GARBAGE_QUERY, "--kb", str(kb)])
            self.assertEqual((code, out.strip()), (0, "(无命中)"))
            code, _, err = run_cli(agent_kb.main, ["renderer", "--kb", str(Path(tmp) / "missing.json")])
            self.assertEqual(code, 2)
            self.assertIn("just kb", err)
            kb.write_text("[]", encoding="utf-8")
            self.assertEqual(run_cli(agent_kb.main, ["renderer", "--kb", str(kb)])[0], 2)
            kb.write_text(json.dumps({"schema_version": 1, "chunk_count": len(TOY_CHUNKS), "chunks": TOY_CHUNKS}),
                          encoding="utf-8")
            code, _, err = run_cli(agent_kb.main, ["renderer", "--kb", str(kb)])
            self.assertEqual(code, 2)
            self.assertIn("schema", err)
            self.assertIn("just kb", err)
            bad = json.loads(toy_kb_text())
            bad["docs"][0][2].append(["anchor only"])
            kb.write_text(json.dumps(bad), encoding="utf-8")
            code, _, err = run_cli(agent_kb.main, ["renderer", "--kb", str(kb)])
            self.assertEqual(code, 2)
            self.assertIn("格式错误", err)


class RealCorpusTests(unittest.TestCase):
    """真实仓库语料：只读，内存构建；文档定稿并运行 just kb 后应全部通过。"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.payload = build_agent_kb.build_payload(REPO_ROOT)
        cls.rendered = build_agent_kb.render(cls.payload)
        cls.index = agent_kb.KBIndex(agent_kb.expand_docs(cls.payload["docs"]))
        cls.docs = {entry[0] for entry in cls.payload["docs"]}

    def test_checked_in_kb_is_fresh(self) -> None:
        if not KB_PATH.is_file():
            self.fail("docs/kb/chunks.json 缺失：run just kb（python scripts/build_agent_kb.py --confirm）后提交")
        self.assertTrue(
            KB_PATH.read_bytes().replace(b"\r\n", b"\n") == self.rendered.encode("utf-8"),
            "docs/kb/chunks.json 与当前语料不一致：run just kb 重建并审 diff",
        )
        self.assertEqual(len(agent_kb.load_chunks(KB_PATH)), self.payload["chunk_count"])

    def test_build_is_deterministic(self) -> None:
        self.assertEqual(build_agent_kb.render(build_agent_kb.build_payload(REPO_ROOT)), self.rendered)

    def test_schema_layers_and_budget(self) -> None:
        assert_payload_shape(self, self.payload)
        size = len(self.rendered.encode("utf-8"))
        self.assertLessEqual(size, SIZE_BUDGET_BYTES, f"知识库 {size} 字节超出 2.5 MiB 预算")
        for expected in ("AGENTS.md", "README.md", "HACKING.md", "src/terminal/Terminal.zig",
                         "src/renderer/Thread.zig", "include/ghostty/vt/terminal.h", "src/terminal/c/AGENTS.md"):
            self.assertIn(expected, self.docs)
        for doc in self.docs:
            self.assertFalse(doc.startswith(("graphify-out/", "docs/kb/", "src/stb/", "src/build/framegen/")), doc)
            self.assertFalse(doc.startswith("src/font/nerd_font_"), doc)

    def test_every_agent_rules_doc_is_indexed(self) -> None:
        visible = build_agent_kb.git_visible_files(REPO_ROOT)
        rule_docs = [rel for rel in visible if rel.startswith("docs/AGENT_RULES/") and rel.endswith(".md")
                     and rel.count("/") == 2]
        self.assertIn("docs/AGENT_RULES/README.md", rule_docs)
        for rel in rule_docs:
            self.assertIn(rel, self.docs, rel)
        routes = REPO_ROOT / "docs" / "AGENT_RULES" / "routes.toml"
        self.assertTrue(routes.is_file(), "缺少 docs/AGENT_RULES/routes.toml")
        if tomllib is None:
            self.skipTest("需要 tomllib（Python 3.11+）或 tomli 才能解析 routes.toml")
        table = tomllib.loads(routes.read_bytes().decode("utf-8"))
        routed = sorted({rule["doc"] for rule in table.get("rules", [])})
        self.assertTrue(routed, "routes.toml 没有 [[rules]]")
        missing = [doc for doc in routed if doc not in self.docs]
        self.assertEqual(missing, [], "routes.toml 登记的领域文档不在知识库中")

    def test_golden_queries_hit_expected_docs(self) -> None:
        self.assertGreaterEqual(len(GOLDEN_QUERIES), 12)
        for query, expected in GOLDEN_QUERIES:
            with self.subTest(query=query):
                docs = [item["doc"] for item in self.index.search(query, top=8)]
                self.assertTrue(any(doc in docs for doc in expected), f"{query} -> top8={docs}，期望之一 {expected}")

    def test_garbage_query_returns_nothing(self) -> None:
        self.assertEqual(self.index.search(GARBAGE_QUERY, top=8), [])


if __name__ == "__main__":
    unittest.main()
