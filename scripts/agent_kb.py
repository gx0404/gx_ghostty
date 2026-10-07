#!/usr/bin/env python3
"""BM25 检索 gx_ghostty agent 知识库（docs/kb/chunks.json）。

用法：python scripts/agent_kb.py <查询词...> [--top 8] [--json] [--kb PATH]

分词：拉丁词 [a-z0-9_./:-]{2,}（小写；`path::symbol`、`snake_case` 这类复合词另拆出各段）
加 CJK 二元组（单字词保留单字）。索引覆盖正文、标题路径（权重 2）与文档路径；
查询按 GLOSSARY 做中英术语互扩（扩展词权重 0.5），让英文标识符也能命中中文领域文档。
同一文档最多返回 2 片，结果覆盖更多来源。每条命中带 doc 与 anchor，便于回源阅读。
没有命中时输出“(无命中)”，退出码仍为 0；知识库缺失或损坏退出 2。
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_KB = REPO_ROOT / "docs" / "kb" / "chunks.json"
K1 = 1.2
B = 0.75
ANCHOR_WEIGHT = 2
EXPANSION_WEIGHT = 0.5
MAX_PER_DOC = 2
EXCERPT_CHARS = 200

# 中英术语对照（英文词组, 中文词组）：只用于查询扩展，不影响知识库产物。
GLOSSARY = (
    ("thread threads", "线程"),
    ("render renderer rendering", "渲染"),
    ("config configuration", "配置"),
    ("release releases", "发版 发布"),
    ("test tests testing", "测试"),
    ("build builds", "构建"),
    ("font fonts", "字体"),
    ("translation translations i18n", "翻译"),
    ("graph", "图谱"),
    ("fingerprint", "指纹"),
    ("upstream", "上游"),
    ("sync", "同步"),
    ("commit commits", "提交"),
    ("review", "审核"),
    ("patch patches", "补丁"),
    ("screenshot screenshots", "截图"),
    ("version versions", "版本"),
    ("invariant invariants", "不变"),
    ("verify verification", "验证"),
    ("input", "输入"),
    ("keyboard", "键盘"),
    ("mouse", "鼠标"),
    ("clipboard", "剪贴板"),
    ("terminal", "终端"),
    ("window windows", "窗口"),
    ("compress compression", "压缩"),
    ("search", "搜索"),
    ("generated", "生成"),
    ("dangerous", "危险"),
    ("deny denied", "拒绝"),
    ("platform platforms", "平台"),
    ("package packaging", "打包"),
    ("memory", "内存"),
    ("performance", "性能"),
    ("export exports", "导出"),
    ("route routes routing", "路由"),
    ("rule rules", "规则"),
    ("domain domains", "领域"),
    ("nested", "嵌套"),
)

_LATIN_TOKEN = re.compile(r"[a-z0-9_./:-]{2,}")
_LATIN_SPLIT = re.compile(r"[_./:-]+")
_LATIN_EDGE = "_./:-"
_CJK_RUN = re.compile("[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+")


def tokenize(text: str) -> list[str]:
    lowered = text.lower()
    tokens: list[str] = []
    for raw in _LATIN_TOKEN.findall(lowered):
        token = raw.strip(_LATIN_EDGE)
        if len(token) < 2:
            continue
        tokens.append(token)
        if any(sep in token for sep in _LATIN_EDGE):
            tokens.extend(part for part in _LATIN_SPLIT.split(token) if len(part) >= 2 and part != token)
    for run in _CJK_RUN.findall(lowered):
        if len(run) == 1:
            tokens.append(run)
        else:
            tokens.extend(run[index : index + 2] for index in range(len(run) - 1))
    return tokens


def expand_query(query: str) -> dict[str, float]:
    """查询词 → 权重：原词 1.0；GLOSSARY 中对应的另一种语言的词按 EXPANSION_WEIGHT 计。"""
    weights = {token: 1.0 for token in tokenize(query)}
    lowered = query.lower()
    for english, chinese in GLOSSARY:
        english_words = english.split()
        chinese_words = chinese.split()
        extra: list[str] = []
        if any(word in weights for word in english_words):
            extra.extend(token for word in chinese_words for token in tokenize(word))
        if any(word in lowered for word in chinese_words):
            extra.extend(english_words)
        for token in extra:
            weights.setdefault(token, EXPANSION_WEIGHT)
    return weights


def chunk_tokens(chunk: dict) -> list[str]:
    return (
        tokenize(str(chunk.get("text", "")))
        + tokenize(str(chunk.get("anchor", ""))) * ANCHOR_WEIGHT
        + tokenize(str(chunk.get("doc", "")))
    )


class KBIndex:
    def __init__(self, chunks: list[dict]) -> None:
        self.chunks = chunks
        tokenized = [chunk_tokens(chunk) for chunk in chunks]
        self.term_freqs = [Counter(tokens) for tokens in tokenized]
        self.lengths = [len(tokens) for tokens in tokenized]
        total = len(chunks)
        self.avg_length = (sum(self.lengths) / total) if total else 1.0
        doc_freq: Counter = Counter()
        for freqs in self.term_freqs:
            doc_freq.update(freqs.keys())
        self.idf = {
            term: math.log(1 + (total - df + 0.5) / (df + 0.5)) for term, df in doc_freq.items()
        }

    def search(self, query: str, top: int = 8, per_doc: int = MAX_PER_DOC) -> list[dict]:
        weights = {term: weight for term, weight in expand_query(query).items() if term in self.idf}
        if not weights or top < 1:
            return []
        scored: list[tuple[float, str, str, int]] = []
        for index, freqs in enumerate(self.term_freqs):
            norm = K1 * (1 - B + B * max(self.lengths[index], 1) / self.avg_length)
            score = 0.0
            for term, weight in weights.items():
                tf = freqs.get(term, 0)
                if tf:
                    score += weight * self.idf[term] * tf * (K1 + 1) / (tf + norm)
            if score > 0:
                chunk = self.chunks[index]
                scored.append((-score, str(chunk.get("doc", "")), str(chunk.get("id", "")), index))
        scored.sort()
        results: list[dict] = []
        per_doc_count: Counter = Counter()
        for negative, doc, _id, index in scored:
            if per_doc > 0 and per_doc_count[doc] >= per_doc:
                continue
            per_doc_count[doc] += 1
            chunk = self.chunks[index]
            results.append(
                {
                    "doc": chunk.get("doc", ""),
                    "anchor": chunk.get("anchor", ""),
                    "id": chunk.get("id", ""),
                    "score": round(-negative, 4),
                    "excerpt": " ".join(str(chunk.get("text", "")).split())[:EXCERPT_CHARS],
                }
            )
            if len(results) == top:
                break
        return results


class KBLoadError(RuntimeError):
    pass


def load_chunks(path: Path) -> list[dict]:
    if not path.is_file():
        raise KBLoadError(f"缺少知识库 {path}；运行 just kb 生成")
    try:
        payload = json.loads(path.read_bytes().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise KBLoadError(f"知识库不可读：{path}：{exc}；运行 just kb 重建") from exc
    chunks = payload.get("chunks") if isinstance(payload, dict) else None
    if not isinstance(chunks, list):
        raise KBLoadError(f"知识库格式错误（缺少 chunks 列表）：{path}；运行 just kb 重建")
    return [chunk for chunk in chunks if isinstance(chunk, dict)]


def load_index(path: Path = DEFAULT_KB) -> KBIndex:
    return KBIndex(load_chunks(path))


def _configure_output() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(errors="replace")
            except (OSError, ValueError):
                pass


def _positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("必须是正整数")
    return number


def main(argv: list[str] | None = None) -> int:
    _configure_output()
    parser = argparse.ArgumentParser(description="BM25 检索 agent 知识库（docs/kb/chunks.json）")
    parser.add_argument("query", nargs="+", help="查询词，可写多个（中英文均可）")
    parser.add_argument("--top", type=_positive_int, default=8, help="返回条数（默认 8）")
    parser.add_argument("--json", action="store_true", dest="as_json", help="输出 JSON")
    parser.add_argument("--kb", type=Path, default=DEFAULT_KB, help="知识库路径（默认 docs/kb/chunks.json）")
    args = parser.parse_intermixed_args(argv)
    try:
        index = load_index(args.kb)
    except KBLoadError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    results = index.search(" ".join(args.query), args.top)
    if args.as_json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return 0
    if not results:
        print("(无命中)")
        return 0
    for item in results:
        print(f"{item['score']:>8.4f}  {item['doc']}  [{item['anchor']}]")
        print(f"          {item['excerpt']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
