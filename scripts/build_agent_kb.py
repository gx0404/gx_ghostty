#!/usr/bin/env python3
"""构建 gx_ghostty agent 知识库（docs/kb/chunks.json）。

用法：python scripts/build_agent_kb.py [--confirm] [--output PATH] [--root PATH]

语料是 Git 可见文件的闭集（git ls-files --cached --others --exclude-standard）：
1. 文档：根与嵌套 AGENTS.md、CLAUDE.md、README.md、HACKING.md、CONTRIBUTING.md、
   PACKAGING.md、AI_POLICY.md、CHANGELOG.md（前 6000 字符，锚点 recent）、docs/*.md、
   docs/AGENT_RULES/*.md。按 Markdown 标题切块（围栏代码块内不切），锚点为标题路径。
2. Zig 结构：src/**/*.zig 的 //! 模块文档与 pub 声明签名（函数截到 `{`；常量与变量截到 `=`，
   右侧是类型定义、类型构造、@import 或别名时保留到 `{` 或 `;`），每条附最多 3 行 ///；
   跳过 test 块与测试专用文件，排除生成与第三方代码。
3. C 头文件：include/ghostty/**/*.h 的 GHOSTTY_API 原型与 static inline 签名、typedef
   （附枚举值与结构字段名）、宏名，以及 @file / @defgroup / @mainpage 简介，
   各附前导文档注释的前 3 行。
每片文档最多 1500 字符、代码 4000 字符。chunk = {id, doc, anchor, text, source_sha256}，
source_sha256 是所在小节（切片前）文本的哈希；函数体与常量值改动不会让知识库过期，
公开签名与文档改动才会。

输出确定：排序键、LF、无时间戳、无绝对路径，同一语料在任何平台都得到同样的字节。
默认 check 模式：内存重建后与产物逐字节比较（CRLF 检出视同 LF），缺失或过期退出 1
并列出变化来源；--confirm 原子写入；--output 指定产物路径（测试用）；语料或写入失败退出 2。
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = "docs/kb/chunks.json"
SCHEMA_VERSION = 1
MAX_DOC_CHARS = 1500
MAX_CODE_CHARS = 4000
CHANGELOG_HEAD_CHARS = 6000
MAX_ID_CHARS = 160
MAX_SIGNATURE_CHARS = 240
MAX_DOC_LINES = 3
ROOT_DOCS = (
    "AGENTS.md",
    "CLAUDE.md",
    "README.md",
    "HACKING.md",
    "CONTRIBUTING.md",
    "PACKAGING.md",
    "AI_POLICY.md",
)
CHANGELOG = "CHANGELOG.md"
# 生成或第三方的 Zig 代码不进结构层（fnmatch 语义，`*` 可跨 `/`）。
EXCLUDED_ZIG = (
    "src/font/nerd_font_*",
    "src/stb/*",
    "src/build/framegen/*",
)
_GIT_LOCATION_ENV = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
)

_HEADING = re.compile(r"^(#{1,4})\s+(.+?)\s*#*\s*$")
_FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
_SLUG_DROP = re.compile(r"[^a-z0-9\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+")
_ZIG_PUB = re.compile(
    r"^pub\s+(?:(?:inline|noinline|export|extern(?:\s+\"[^\"]*\")?|threadlocal|comptime)\s+)*"
    r"(fn|const|var|usingnamespace)\b"
)
_ZIG_TEST = re.compile(r'^test\s*(?:"(?:[^"\\]|\\.)*"\s*|@?[A-Za-z_][\w.]*\s*)?\{')
# 常量右侧属于“签名”的形态：类型定义、错误集、内建类型函数、函数类型、
# PascalCase 类型构造调用与标识符别名（true/false/null/undefined 是值，不算别名）。
_ZIG_TYPE_RHS = re.compile(
    r"^(?:"
    r"(?:extern\s+|packed\s+)?(?:struct|enum|union|opaque)\b"
    r"|error\s*$"
    r"|@(?:import|This|Type|TypeOf|cImport)\b"
    r"|[?*\[\]\s]*(?:const\s+)?fn\b"
    r"|(?:[A-Za-z_]\w*\.)*[A-Z]\w*\s*\("
    r"|(?!(?:true|false|null|undefined)\s*$)[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\s*$"
    r")"
)
_C_DEFINE = re.compile(r"^#\s*define\s+([A-Za-z_]\w*)(\([^)]*\))?")
_C_GUARD = re.compile(r"_H_?$")
_C_CPLUSPLUS = re.compile(r"^#\s*if(?:def)?\b.*__cplusplus")
_C_IF = re.compile(r"^#\s*if")
_C_ENDIF = re.compile(r"^#\s*endif\b")
_C_TAG_SKIP = re.compile(
    r"^@(?:(?:ingroup|snippet|addtogroup|code|endcode|file|defgroup|mainpage|example)\b|[{}])"
)


class KBError(RuntimeError):
    """语料无法读取或 git 不可用。"""


# ---------------------------------------------------------------- 语料选择


def git_visible_files(root: Path) -> list[str]:
    env = {key: value for key, value in os.environ.items() if key not in _GIT_LOCATION_ENV}
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            check=False,
            env=env,
        )
    except OSError as exc:
        raise KBError(f"无法运行 git：{exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise KBError(f"git ls-files 失败：{detail or result.returncode}")
    files = {
        raw.decode("utf-8", errors="surrogateescape")
        for raw in result.stdout.split(b"\0")
        if raw
    }
    return sorted(rel for rel in files if (root / rel).is_file())


def is_excluded_zig(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    if name == "test.zig" or name.endswith("_test.zig"):
        return True
    return any(fnmatch.fnmatchcase(rel, pattern) for pattern in EXCLUDED_ZIG)


def select_corpus(files: list[str]) -> tuple[list[str], list[str], list[str]]:
    """返回 (文档, Zig 源码, C 头文件)，均为排序后的相对路径。"""
    visible = set(files)
    docs: set[str] = {name for name in ROOT_DOCS + (CHANGELOG,) if name in visible}
    zig: list[str] = []
    headers: list[str] = []
    for rel in files:
        parts = rel.split("/")
        if parts[-1] == "AGENTS.md":
            docs.add(rel)
        elif parts[0] == "docs" and rel.endswith(".md") and (
            len(parts) == 2 or (len(parts) == 3 and parts[1] == "AGENT_RULES")
        ):
            docs.add(rel)
        elif parts[0] == "src" and rel.endswith(".zig") and not is_excluded_zig(rel):
            zig.append(rel)
        elif rel.startswith("include/ghostty/") and rel.endswith(".h"):
            headers.append(rel)
    return sorted(docs), zig, headers


def read_text(root: Path, rel: str) -> str:
    try:
        raw = (root / rel).read_bytes()
    except OSError as exc:
        raise KBError(f"无法读取 {rel}：{exc}") from exc
    text = raw.decode("utf-8-sig", errors="replace")
    return "\n".join(text.splitlines())


# ---------------------------------------------------------------- 切片


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def slugify(value: str) -> str:
    slug = _SLUG_DROP.sub("-", value.lower()).strip("-")
    return slug[:MAX_ID_CHARS].strip("-")


def _hard_wrap(line: str, max_chars: int) -> list[str]:
    pieces: list[str] = []
    while len(line) > max_chars:
        cut = line.rfind(" ", max_chars // 2, max_chars + 1)
        if cut <= 0:
            cut = max_chars
        pieces.append(line[:cut].rstrip())
        line = line[cut:].lstrip()
    if line:
        pieces.append(line)
    return pieces


def split_parts(text: str, max_chars: int) -> list[str]:
    """按行装箱，每片不超过 max_chars；超长单行在空格处硬折；只含空白的片丢弃。"""
    parts: list[str] = []
    current: list[str] = []
    size = 0

    def flush() -> None:
        lines = list(current)
        while lines and not lines[0].strip():
            lines.pop(0)
        while lines and not lines[-1].strip():
            lines.pop()
        if lines:
            parts.append("\n".join(lines))

    for raw_line in text.splitlines():
        for line in _hard_wrap(raw_line, max_chars) if len(raw_line) > max_chars else [raw_line]:
            needed = len(line) + (1 if current else 0)
            if current and size + needed > max_chars:
                flush()
                current, size = [], 0
                needed = len(line)
            current.append(line)
            size += needed
    if current:
        flush()
    return parts


def emit_chunks(chunks: list[dict], doc: str, anchor: str, text: str, max_chars: int) -> None:
    clean = text.strip("\n")
    if not clean.strip():
        return
    parts = split_parts(clean, max_chars)
    base_id = slugify(f"{doc}#{anchor}") or slugify(doc) or "chunk"
    digest = sha256_text(clean)
    for index, part in enumerate(parts, start=1):
        chunks.append(
            {
                "id": base_id if len(parts) == 1 else f"{base_id}-part{index}",
                "doc": doc,
                "anchor": anchor,
                "text": part,
                "source_sha256": digest,
            }
        )


def split_markdown(text: str) -> list[tuple[str, str]]:
    """按 1–4 级 ATX 标题切成 (标题路径, 小节正文)；只有标题没有正文的小节不单独成片。"""
    sections: list[tuple[str, str]] = []
    stack: list[str] = []
    anchor = "_top"
    buffer: list[str] = []
    has_body = False
    fence: str | None = None

    def flush() -> None:
        if has_body:
            body = "\n".join(buffer).strip("\n")
            if body.strip():
                sections.append((anchor, body))

    for line in text.splitlines():
        fence_match = _FENCE.match(line)
        if fence is not None:
            if fence_match and fence_match.group(1)[0] == fence[0] and len(fence_match.group(1)) >= len(fence):
                fence = None
            buffer.append(line)
            has_body = True
            continue
        if fence_match:
            fence = fence_match.group(1)
            buffer.append(line)
            has_body = True
            continue
        heading = _HEADING.match(line)
        if heading:
            flush()
            level = len(heading.group(1))
            title = heading.group(2).strip()
            while len(stack) >= level:
                stack.pop()
            stack.append(title)
            anchor = " > ".join(stack)
            buffer = [line]
            has_body = False
            continue
        buffer.append(line)
        if line.strip():
            has_body = True
    flush()
    return sections


def changelog_head(text: str) -> str:
    if len(text) <= CHANGELOG_HEAD_CHARS:
        return text
    head = text[:CHANGELOG_HEAD_CHARS]
    newline = head.rfind("\n")
    return head[:newline] if newline > 0 else head


def doc_chunks(rel: str, text: str, chunks: list[dict]) -> None:
    if rel == CHANGELOG:
        emit_chunks(chunks, rel, "recent", changelog_head(text), MAX_DOC_CHARS)
        return
    for anchor, body in split_markdown(text):
        emit_chunks(chunks, rel, anchor, body, MAX_DOC_CHARS)


# ---------------------------------------------------------------- Zig 结构


def _skip_quoted(line: str, start: int) -> int:
    quote = line[start]
    index = start + 1
    while index < len(line):
        char = line[index]
        if char == "\\":
            index += 2
            continue
        if char == quote:
            return index + 1
        index += 1
    return len(line)


def zig_code(line: str) -> str:
    """去掉 // 注释后的代码部分（字符串与字符字面量内的内容原样保留）。"""
    stripped = line.lstrip()
    if stripped.startswith("\\\\"):
        return ""
    index = 0
    while index < len(line):
        char = line[index]
        if char in "\"'":
            index = _skip_quoted(line, index)
            continue
        if line.startswith("//", index):
            return line[:index]
        index += 1
    return line


def brace_delta(line: str) -> int:
    if "{" not in line and "}" not in line:
        return 0
    code = zig_code(line)
    delta = 0
    index = 0
    while index < len(code):
        char = code[index]
        if char in "\"'":
            index = _skip_quoted(code, index)
            continue
        if char == "{":
            delta += 1
        elif char == "}":
            delta -= 1
        index += 1
    return delta


def _cut_signature(lines: list[str], start: int, is_fn: bool) -> str:
    """从 pub 声明行起取签名，在括号外第一个 `{` 或 `;` 处截断。

    函数可跨多行（参数列表）。常量与变量只取首行，并在顶层 `=` 处截断，
    只有右侧是类型定义、类型构造、@import 或别名时才保留右侧（_ZIG_TYPE_RHS），
    这样改常量的值不会让知识库过期，改类型才会。
    """
    collected: list[str] = []
    depth = 0
    assign_at: int | None = None
    consumed = 0
    for line_index in range(start, min(len(lines), start + (16 if is_fn else 1))):
        code = zig_code(lines[line_index])
        out: list[str] = []
        index = 0
        done = False
        while index < len(code):
            char = code[index]
            if char in "\"'":
                end = _skip_quoted(code, index)
                out.append(code[index:end])
                index = end
                continue
            if char in "([":
                depth += 1
            elif char in ")]":
                depth -= 1
            elif depth <= 0 and char in "{;":
                done = True
                break
            elif (
                depth <= 0
                and char == "="
                and assign_at is None
                and code[index + 1 : index + 2] not in ("=", ">")
                and (index == 0 or code[index - 1] not in "=!<>")
            ):
                assign_at = consumed + len("".join(out))
            out.append(char)
            index += 1
        piece = "".join(out)
        collected.append(piece)
        consumed += len(piece) + 1
        if done:
            break
    raw = " ".join(collected)
    if not is_fn and assign_at is not None:
        rhs = raw[assign_at + 1 :].strip()
        if not _ZIG_TYPE_RHS.match(rhs):
            raw = raw[:assign_at]
    signature = re.sub(r"\s+", " ", raw).strip()
    signature = re.sub(r"\(\s+", "(", signature)
    signature = re.sub(r",?\s*\)", ")", signature)
    signature = re.sub(r"\s*=\s*\.?$", "", signature)
    signature = re.sub(r"\s*\($", "", signature)
    if len(signature) > MAX_SIGNATURE_CHARS:
        signature = signature[: MAX_SIGNATURE_CHARS - 1].rstrip() + "…"
    return signature


def zig_structure(text: str) -> str:
    lines = text.splitlines()
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("//!"):
            out.append("//! " + stripped[3:].strip() if stripped[3:].strip() else "//!")
        elif not stripped or (stripped.startswith("//") and not stripped.startswith("///")):
            continue
        else:
            break
    while out and out[-1] == "//!":
        out.pop()

    depth = 0
    test_floor: int | None = None
    pending_doc: list[str] = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        delta = brace_delta(line)
        if test_floor is not None:
            depth += delta
            if depth <= test_floor:
                test_floor = None
            continue
        if stripped.startswith("///"):
            pending_doc.append(stripped[3:].strip())
            continue
        if _ZIG_TEST.match(stripped):
            if delta > 0:
                test_floor = depth
            depth += delta
            pending_doc = []
            continue
        match = _ZIG_PUB.match(stripped)
        if match:
            signature = _cut_signature(lines, index, is_fn=match.group(1) == "fn")
            docs = [doc for doc in pending_doc if doc][:MAX_DOC_LINES]
            entry = "  " * min(max(depth, 0), 4) + signature
            if docs:
                entry += " — " + " ".join(docs)
            out.append(entry)
        if stripped:
            pending_doc = []
        depth += delta
    return "\n".join(out)


# ---------------------------------------------------------------- C 头文件


def _clean_doc(lines: list[str]) -> list[str]:
    cleaned: list[str] = []
    for raw in lines:
        line = raw.strip()
        if line.startswith("*"):
            line = line[1:].strip()
        if line:
            cleaned.append(line)
    return cleaned


def _doc_summary(lines: list[str]) -> list[str]:
    summary: list[str] = []
    for line in lines:
        if _C_TAG_SKIP.match(line):
            continue
        line = re.sub(r"\s*@[{}]\s*", " ", line).strip()
        if line:
            summary.append(line)
        if len(summary) == MAX_DOC_LINES:
            break
    return summary


def _c_statements(text: str) -> list[tuple[str, str, list[str]]]:
    """顶层声明扫描：返回 (kind, 文本, 文档行)。

    kind：stmt（以 `;` 结束的声明）、func（static inline 定义，只留签名）、define、
    file（@file 简介）、group（@defgroup / @mainpage 标题与简介）。
    C++ 专用的 __cplusplus 条件块整体跳过，宏的续行不当作代码解析。
    """
    items: list[tuple[str, str, list[str]]] = []
    lines: list[str] = []
    skip = 0
    for line in text.splitlines():
        stripped = line.strip()
        if skip:
            if _C_IF.match(stripped):
                skip += 1
            elif _C_ENDIF.match(stripped):
                skip -= 1
            continue
        if _C_CPLUSPLUS.match(stripped):
            skip = 1
            continue
        lines.append(line)

    depth = 0
    in_comment = False
    comment_doc = False
    comment_buf: list[str] = []
    last_doc: list[str] = []
    statement: list[str] = []
    statement_doc: list[str] = []
    started = False
    continuation = False

    def close_comment() -> None:
        nonlocal last_doc
        if not comment_doc or depth != 0 or started:
            return
        cleaned = _clean_doc(comment_buf)
        first_tag = next((line.split()[0] for line in cleaned if line.startswith("@")), "")
        if first_tag == "@file":
            items.append(("file", "", _doc_summary(cleaned)))
        elif first_tag in ("@defgroup", "@mainpage"):
            title = next(line for line in cleaned if line.startswith(first_tag))
            items.append(("group", title, _doc_summary(cleaned)))
        elif first_tag != "@example":
            last_doc = cleaned

    for line in lines:
        stripped = line.strip()
        if continuation:
            continuation = stripped.endswith("\\")
            continue
        if not in_comment and stripped.startswith("#"):
            continuation = stripped.endswith("\\")
            define = _C_DEFINE.match(stripped)
            if define and depth == 0 and not started and not _C_GUARD.search(define.group(1)):
                items.append(("define", f"#define {define.group(1)}{define.group(2) or ''}", last_doc))
                last_doc = []
            continue
        code: list[str] = []
        index = 0
        while index < len(line):
            if in_comment:
                end = line.find("*/", index)
                if end == -1:
                    comment_buf.append(line[index:])
                    index = len(line)
                    break
                comment_buf.append(line[index:end])
                in_comment = False
                index = end + 2
                close_comment()
                continue
            if line.startswith("/*", index):
                in_comment = True
                comment_doc = line.startswith(("/**", "/*!"), index) and not line.startswith("/**/", index)
                comment_buf = []
                index += 3 if comment_doc else 2
                continue
            if line.startswith("//", index):
                break
            char = line[index]
            if char in "\"'":
                end = _skip_quoted(line, index)
                code.append(line[index:end])
                index = end
                continue
            if not started and not char.isspace():
                started = True
                statement_doc = last_doc
                last_doc = []
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            code.append(char)
            index += 1
            if depth != 0 or char not in ";}":
                continue
            text_so_far = re.sub(r"\s+", " ", " ".join([*statement, "".join(code)])).strip()
            if char == ";":
                items.append(("stmt", text_so_far, statement_doc))
            else:
                head = text_so_far.split("{", 1)[0].strip()
                if not head.endswith(")") or re.match(r"^(typedef|struct|enum|union)\b", head):
                    continue
                items.append(("func", head, statement_doc))
            statement, code, statement_doc, started = [], [], [], False
        if code:
            statement.append("".join(code))
    return items


def _member_names(body: str, enum: bool) -> list[str]:
    while re.search(r"\{[^{}]*\}", body):
        body = re.sub(r"\{[^{}]*\}", " ", body)
    names: list[str] = []
    if enum:
        for member in body.split(","):
            found = re.match(r"\s*([A-Za-z_]\w*)", member)
            if found:
                names.append(found.group(1))
        return names
    for member in body.split(";"):
        member = re.sub(r"\[[^\]]*\]|:\s*\d+\s*$", "", member).strip()
        found = re.search(r"([A-Za-z_]\w*)$", member)
        if found:
            names.append(found.group(1))
    return names


def _compound_summary(statement: str) -> str | None:
    match = re.match(r"^(typedef\s+)?(enum|struct|union)\b([^{]*)\{(.*)\}\s*([A-Za-z_]\w*)?\s*;$", statement)
    if not match:
        return None
    kind = match.group(2)
    tag = match.group(3).replace("GHOSTTY_ENUM_TYPED", "").strip()
    name = match.group(5) or tag
    if not name:
        return None
    members = _member_names(match.group(4), enum=kind == "enum")
    summary = f"{'typedef ' if match.group(1) else ''}{kind} {name}"
    if members:
        listed = ", ".join(members)
        if len(listed) > 600:
            listed = listed[:599].rsplit(",", 1)[0] + ", …"
        summary += " { " + listed + " }"
    return summary


def header_structure(text: str) -> str:
    out: list[str] = []
    seen: set[str] = set()
    for kind, statement, doc in _c_statements(text):
        summary: str | None
        if kind == "file":
            if doc:
                out.append("@file " + " ".join(doc))
            continue
        if kind in ("group", "define", "func"):
            summary = statement
        elif statement.startswith("GHOSTTY_API") or (
            statement.startswith("typedef") and "{" not in statement
        ):
            summary = statement.rstrip(";").strip()
        else:
            summary = _compound_summary(statement)
        if not summary or summary in seen:
            continue
        seen.add(summary)
        if len(summary) > MAX_SIGNATURE_CHARS * 4:
            summary = summary[: MAX_SIGNATURE_CHARS * 4 - 1].rstrip() + "…"
        brief = _doc_summary(doc)
        out.append(summary + (" — " + " ".join(brief) if brief else ""))
    return "\n".join(out)


# ---------------------------------------------------------------- 组装与输出


def build_payload(root: Path = REPO_ROOT) -> dict:
    docs, zig, headers = select_corpus(git_visible_files(root))
    chunks: list[dict] = []
    for rel in docs:
        doc_chunks(rel, read_text(root, rel), chunks)
    for rel in zig:
        emit_chunks(chunks, rel, "structure", zig_structure(read_text(root, rel)), MAX_CODE_CHARS)
    for rel in headers:
        emit_chunks(chunks, rel, "declarations", header_structure(read_text(root, rel)), MAX_CODE_CHARS)
    chunks.sort(key=lambda chunk: (chunk["id"], chunk["doc"], chunk["anchor"], chunk["text"]))
    seen: dict[str, int] = {}
    used = {chunk["id"] for chunk in chunks}
    for chunk in chunks:
        base = chunk["id"]
        if base not in seen:
            seen[base] = 0
            continue
        while True:
            seen[base] += 1
            candidate = f"{base}-x{seen[base]}"
            if candidate not in used:
                break
        chunk["id"] = candidate
        used.add(candidate)
    chunks.sort(key=lambda chunk: chunk["id"])
    return {"schema_version": SCHEMA_VERSION, "chunk_count": len(chunks), "chunks": chunks}


def render(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=1, sort_keys=True) + "\n"


def changed_sources(old: object, new: dict) -> list[str]:
    def by_doc(payload: object) -> dict[str, list[tuple]]:
        groups: dict[str, list[tuple]] = defaultdict(list)
        chunks = payload.get("chunks", []) if isinstance(payload, dict) else []
        for chunk in chunks if isinstance(chunks, list) else []:
            if isinstance(chunk, dict):
                groups[str(chunk.get("doc"))].append(
                    tuple(str(chunk.get(key)) for key in ("id", "anchor", "text", "source_sha256"))
                )
        return {doc: sorted(items) for doc, items in groups.items()}

    before, after = by_doc(old), by_doc(new)
    return sorted(doc for doc in set(before) | set(after) if before.get(doc) != after.get(doc))


def write_atomic(target: Path, content: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(target.parent), prefix=f".{target.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content.encode("utf-8"))
        os.replace(tmp_name, target)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def _display(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def _configure_output() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(errors="replace")
            except (OSError, ValueError):
                pass


def main(argv: list[str] | None = None) -> int:
    _configure_output()
    parser = argparse.ArgumentParser(
        description="构建 agent 知识库：默认只读校验（缺失或过期退出 1），--confirm 写入",
    )
    parser.add_argument("--confirm", action="store_true", help="原子写入产物（默认只检查）")
    parser.add_argument("--check", action="store_true", help="只读校验（与默认行为相同）")
    parser.add_argument("--output", type=Path, help=f"产物路径（默认 {DEFAULT_OUTPUT}）")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="仓库根目录（默认为脚本所在仓库）")
    args = parser.parse_args(argv)
    if args.confirm and args.check:
        parser.error("--confirm 与 --check 不能同时使用")
    root = args.root.resolve()
    target = (args.output if args.output else root / DEFAULT_OUTPUT).resolve()
    shown = _display(target, root)
    try:
        payload = build_payload(root)
    except KBError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    content = render(payload)
    size_kib = len(content.encode("utf-8")) / 1024
    if args.confirm:
        try:
            write_atomic(target, content)
        except OSError as exc:
            print(f"error: 无法写入 {shown}：{exc}", file=sys.stderr)
            return 2
        print(f"written: {shown}（{payload['chunk_count']} chunks，{size_kib:.0f} KiB）")
        return 0
    if not target.is_file():
        print(f"error: 缺少 {shown}；运行 just kb 生成后提交", file=sys.stderr)
        return 1
    on_disk = target.read_bytes().replace(b"\r\n", b"\n")
    if on_disk == content.encode("utf-8"):
        print(f"OK: {shown} 与语料一致（{payload['chunk_count']} chunks，{size_kib:.0f} KiB）")
        return 0
    try:
        old = json.loads(on_disk.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        print(f"error: {shown} 不是有效的 JSON；运行 just kb 重建", file=sys.stderr)
        return 1
    changed = changed_sources(old, payload)
    if changed:
        listed = "\n".join(f"  - {doc}" for doc in changed[:40])
        more = f"\n  …另有 {len(changed) - 40} 个" if len(changed) > 40 else ""
        print(f"error: {shown} 已过期；变化来源（{len(changed)}）：\n{listed}{more}", file=sys.stderr)
    else:
        print(f"error: {shown} 与当前构建不一致（格式或 schema 变化）", file=sys.stderr)
    print("运行 just kb 重建并审 diff", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
