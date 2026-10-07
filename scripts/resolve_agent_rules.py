#!/usr/bin/env python3
"""按 scope 路径与任务类型解析本轮必读的 AI 领域规则（routes.toml schema v3）。

唯一机器真源是 docs/AGENT_RULES/routes.toml。解析结果先列领域文档（按 id 排序），
再列适用的上游嵌套 AGENTS.md（登记在 nested_agents、且所在目录是某个 scope 路径
的祖先）。根 AGENTS.md 每轮常驻加载，从不输出。

用法：
  resolve_agent_rules.py <path>... [--task T]... [--json]
  resolve_agent_rules.py --task T...            （只按任务追加文档）
  resolve_agent_rules.py --check

--check 校验根 AGENTS.md（体积、UTF-8、fork 段标记）、schema 与排序、领域文档
闭集、嵌套 AGENTS 登记表、零命中 pattern、全仓覆盖与 root_only 重叠、领域文档间
的重复段落。成功退出 0，任何违规退出 2。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path, PurePosixPath

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10：复用已安装的 tomli，不在运行时安装。
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:
        sys.stderr.write("error: 需要 Python 3.11+，或在 Python 3.10 环境中已安装 tomli\n")
        raise SystemExit(2) from None

REPO_ROOT = Path(__file__).resolve().parents[1]
RULES_DIR = PurePosixPath("docs/AGENT_RULES")
ROUTES_PATH = RULES_DIR / "routes.toml"
RULES_README = "README.md"
ROUTES_VERSION = 3
ROOT_AGENTS = "AGENTS.md"
ROOT_AGENTS_MAX_BYTES = 16 * 1024
DOMAIN_RULE_MAX_BYTES = 16 * 1024
FORK_MARKER = "<!-- gx-fork:"
NESTED_AGENTS_SUFFIX = "/AGENTS.md"
DUPLICATE_PARAGRAPH_MIN_CHARS = 160
TOP_LEVEL_KEYS = frozenset({"version", "root_max_bytes", "root_only", "nested_agents", "rules"})
RULE_KEYS = frozenset({"id", "doc", "paths", "tasks"})

_KEBAB = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*")
_LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
_GIT_LOCATION_ENV = frozenset(
    {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_OBJECT_DIRECTORY"}
)


class RuleManifestError(ValueError):
    """路由真源、scope 或仓库状态违反契约；CLI 以退出码 2 报告。"""


@dataclass(frozen=True)
class RuleRoute:
    id: str
    doc: str
    paths: tuple[str, ...]
    tasks: tuple[str, ...]


@dataclass(frozen=True)
class RuleRoutes:
    version: int
    root_max_bytes: int
    root_only: tuple[str, ...]
    nested_agents: tuple[str, ...]
    rules: tuple[RuleRoute, ...]

    @property
    def allowed_tasks(self) -> tuple[str, ...]:
        return tuple(sorted({task for rule in self.rules for task in rule.tasks}))


@dataclass(frozen=True)
class Resolution:
    scope: tuple[str, ...]
    tasks: tuple[str, ...]
    rules: tuple[RuleRoute, ...]
    upstream_agents: tuple[str, ...]

    def lines(self) -> list[str]:
        return [rule.doc for rule in self.rules] + list(self.upstream_agents)

    def payload(self) -> dict[str, object]:
        return {
            "version": ROUTES_VERSION,
            "scope": list(self.scope),
            "tasks": list(self.tasks),
            "rules": [{"id": rule.id, "doc": rule.doc} for rule in self.rules],
            "upstream_agents": list(self.upstream_agents),
        }


@dataclass(frozen=True)
class CheckSummary:
    routes: RuleRoutes
    file_count: int
    root_agents_bytes: int

    def describe(self) -> str:
        path_rules = sum(1 for rule in self.routes.rules if rule.paths)
        return (
            f"OK: routes.toml v{self.routes.version}，{len(self.routes.rules)} 份领域规则"
            f"（{path_rules} 份按路径），{len(self.routes.nested_agents)} 份上游嵌套 AGENTS.md 已登记，"
            f"{self.file_count} 个 Git 可见文件闭集完整；"
            f"根 AGENTS.md {self.root_agents_bytes}/{self.routes.root_max_bytes} bytes"
        )


# ---- routes.toml ----


def _string_list(value: object, label: str, normalizer: Callable[[str, str], str]) -> tuple[str, ...]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise RuleManifestError(f"{label} 必须是字符串数组")
    items = tuple(normalizer(item, label) for item in value)
    duplicates = sorted({item for item in items if items.count(item) > 1})
    if duplicates:
        raise RuleManifestError(f"{label} 含重复项：{duplicates}")
    return items


def _normalize_pattern(value: str, label: str) -> str:
    if not value or "\\" in value or any(char in value for char in "\0\r\n"):
        raise RuleManifestError(f"{label} 含无效 pattern：{value!r}")
    segments = value.split("/")
    if any(segment in {"", ".", ".."} for segment in segments):
        raise RuleManifestError(f"{label} 的 pattern 必须是仓库内相对 POSIX 路径：{value!r}")
    for index, segment in enumerate(segments):
        if "**" in segment and segment != "**":
            raise RuleManifestError(f"{label} 的 pattern 中 ** 必须独占一个路径段：{value!r}")
        if segment == "**" and index and segments[index - 1] == "**":
            raise RuleManifestError(f"{label} 的 pattern 不得连续使用 **：{value!r}")
    if set(value) <= {"*", "?", "/"}:
        raise RuleManifestError(f"{label} 禁止万能兜底 pattern：{value!r}")
    return value


def _normalize_nested_agent(value: str, label: str) -> str:
    segments = value.split("/")
    if (
        "\\" in value
        or any(char in value for char in "*?\0\r\n")
        or len(segments) < 2
        or segments[-1] != ROOT_AGENTS
        or any(segment in {"", ".", ".."} for segment in segments)
    ):
        raise RuleManifestError(f"{label} 条目必须是子目录下 AGENTS.md 的仓库相对路径：{value!r}")
    return value


def _normalize_task(value: str, label: str) -> str:
    if _KEBAB.fullmatch(value) is None:
        raise RuleManifestError(f"{label} 的任务名必须是小写 kebab-case：{value!r}")
    return value


def load_rule_routes(root: Path) -> RuleRoutes:
    """读取并校验 routes.toml 的 schema（类型、键集合、id/doc/pattern 形状）。"""

    path = root.joinpath(*ROUTES_PATH.parts)
    if path.is_symlink() or not path.is_file():
        raise RuleManifestError(f"缺少普通文件：{ROUTES_PATH}")
    try:
        payload = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise RuleManifestError(f"{ROUTES_PATH} 无法按 UTF-8 TOML 解析：{exc}") from exc

    keys = set(payload)
    if keys != TOP_LEVEL_KEYS:
        raise RuleManifestError(
            f"{ROUTES_PATH} 顶层键必须恰好是 {sorted(TOP_LEVEL_KEYS)}；"
            f"缺少 {sorted(TOP_LEVEL_KEYS - keys)}，多出 {sorted(keys - TOP_LEVEL_KEYS)}"
        )
    version = payload["version"]
    if type(version) is not int or version != ROUTES_VERSION:
        raise RuleManifestError(f"不支持的路由 schema 版本：{version!r}（需要 {ROUTES_VERSION}）")
    root_max_bytes = payload["root_max_bytes"]
    if type(root_max_bytes) is not int or root_max_bytes != ROOT_AGENTS_MAX_BYTES:
        raise RuleManifestError(f"root_max_bytes 必须固定为 {ROOT_AGENTS_MAX_BYTES}，实际为 {root_max_bytes!r}")
    root_only = _string_list(payload["root_only"], "root_only", _normalize_pattern)
    nested_agents = _string_list(payload["nested_agents"], "nested_agents", _normalize_nested_agent)

    raw_rules = payload["rules"]
    if not isinstance(raw_rules, list) or not raw_rules:
        raise RuleManifestError("rules 必须是非空的 [[rules]] 数组")
    rules: list[RuleRoute] = []
    seen_ids: set[str] = set()
    for index, item in enumerate(raw_rules):
        if not isinstance(item, dict) or set(item) != RULE_KEYS:
            raise RuleManifestError(f"rules[{index}] 必须恰好包含 id/doc/paths/tasks")
        rule_id = item["id"]
        if not isinstance(rule_id, str) or _KEBAB.fullmatch(rule_id) is None:
            raise RuleManifestError(f"rules[{index}].id 必须是小写 kebab-case：{rule_id!r}")
        if rule_id in seen_ids:
            raise RuleManifestError(f"规则 id 重复：{rule_id}")
        seen_ids.add(rule_id)
        expected_doc = f"{RULES_DIR}/{rule_id}.md"
        if item["doc"] != expected_doc:
            raise RuleManifestError(f"规则 {rule_id} 的 doc 必须是 {expected_doc}，实际为 {item['doc']!r}")
        paths = _string_list(item["paths"], f"规则 {rule_id} 的 paths", _normalize_pattern)
        tasks = _string_list(item["tasks"], f"规则 {rule_id} 的 tasks", _normalize_task)
        if not paths and not tasks:
            raise RuleManifestError(f"规则 {rule_id} 必须至少声明 paths 或 tasks 之一")
        rules.append(RuleRoute(rule_id, expected_doc, paths, tasks))
    return RuleRoutes(version, root_max_bytes, root_only, nested_agents, tuple(rules))


# ---- glob ----


@lru_cache(maxsize=None)
def _pattern_regex(pattern: str) -> str:
    segments = pattern.split("/")
    parts: list[str] = []
    after_globstar = False
    for index, segment in enumerate(segments):
        if segment == "**" and index == len(segments) - 1:
            parts.append("(?:/.*)?")
            break
        if index and not after_globstar:
            parts.append("/")
        if segment == "**":
            parts.append("(?:[^/]+/)*")
            after_globstar = True
            continue
        after_globstar = False
        parts.extend("[^/]*" if char == "*" else "[^/]" if char == "?" else re.escape(char) for char in segment)
    return "".join(parts)


@lru_cache(maxsize=None)
def _compile_pattern(pattern: str) -> re.Pattern[str]:
    return re.compile(_pattern_regex(pattern))


def route_matches(pattern: str, path: str) -> bool:
    """`*`/`?` 不跨 `/`；`**/` 匹配零或多级目录；`dir/**` 也匹配 `dir` 本身。"""

    return _compile_pattern(pattern).fullmatch(path) is not None


def _compile_union(patterns: Iterable[str]) -> re.Pattern[str] | None:
    regexes = [f"(?:{_pattern_regex(pattern)})" for pattern in patterns]
    return re.compile("|".join(regexes)) if regexes else None


class RouteMatcher:
    """把每条规则与 root_only 的 pattern 预编译为并集正则。"""

    def __init__(self, routes: RuleRoutes) -> None:
        self._rules = tuple((rule.id, _compile_union(rule.paths)) for rule in routes.rules)
        self._domain = _compile_union(pattern for rule in routes.rules for pattern in rule.paths)
        self._root_only = _compile_union(routes.root_only)

    def rule_ids(self, path: str) -> list[str]:
        return [rule_id for rule_id, regex in self._rules if regex is not None and regex.fullmatch(path)]

    def in_domain(self, path: str) -> bool:
        return self._domain is not None and self._domain.fullmatch(path) is not None

    def in_root_only(self, path: str) -> bool:
        return self._root_only is not None and self._root_only.fullmatch(path) is not None


# ---- repository ----


def repository_files(root: Path) -> tuple[str, ...]:
    """Git 可见文件：`git ls-files --cached --others --exclude-standard`。"""

    env = {key: value for key, value in os.environ.items() if key not in _GIT_LOCATION_ENV}
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            capture_output=True,
            check=False,
            env=env,
        )
    except OSError as exc:
        raise RuleManifestError(f"无法执行 git ls-files：{exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuleManifestError(f"git ls-files 失败（{root}）：{detail}")
    return tuple(sorted({item.decode("utf-8", errors="replace") for item in result.stdout.split(b"\0") if item}))


def _repo_path(root: Path, relative: str) -> Path:
    return root if relative == "." else root.joinpath(*relative.split("/"))


def _is_regular_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink()


def _summarize(items: Sequence[str], limit: int = 20) -> str:
    shown = ", ".join(items[:limit])
    return f"{shown} …（共 {len(items)} 个）" if len(items) > limit else shown


# ---- 解析 ----


def _relative_to_root(path: Path, root: Path) -> str | None:
    for candidate in (path.resolve(strict=False), Path(os.path.abspath(path))):
        try:
            return candidate.relative_to(root).as_posix()
        except ValueError:
            continue
    return None


def normalize_scope_path(raw: str, root: Path) -> str:
    """把 scope 路径归一为仓库相对 POSIX 路径；接受仓库内绝对路径与反斜杠。"""

    if not raw or any(char in raw for char in "\0\r\n"):
        raise RuleManifestError(f"scope 路径无效：{raw!r}")
    text = raw.replace("\\", "/")
    if ".." in text.split("/"):
        raise RuleManifestError(f"scope 路径不得包含 '..'：{raw}")
    native = Path(text)
    if text.startswith("/") or native.is_absolute() or native.drive:
        relative = _relative_to_root(native, root)
        if relative is None:
            raise RuleManifestError(f"scope 路径越出仓库：{raw}")
        text = relative
    value = "/".join(segment for segment in text.split("/") if segment not in {"", "."})
    return value or "."


def _expand_scope(root: Path, scope: Sequence[str]) -> tuple[str, ...]:
    files: tuple[str, ...] | None = None
    expanded: set[str] = set()
    for path in scope:
        if not _repo_path(root, path).is_dir():
            expanded.add(path)
            continue
        if files is None:
            files = repository_files(root)
        prefix = "" if path == "." else f"{path}/"
        children = [item for item in files if item.startswith(prefix)]
        if not children:
            raise RuleManifestError(f"scope 目录不含 Git 可见文件：{path}")
        expanded.update(children)
    return tuple(sorted(expanded))


def _nested_agent_dir(agent: str) -> str:
    return agent[: -len(NESTED_AGENTS_SUFFIX)]


def resolve_rules(root: Path, paths: Sequence[str], tasks: Sequence[str] = ()) -> Resolution:
    """scope 路径（文件或目录）与任务 → 领域文档并集 + 适用的上游嵌套 AGENTS.md。"""

    root = root.resolve()
    routes = load_rule_routes(root)
    requested_tasks = tuple(sorted(set(tasks)))
    unknown_tasks = [task for task in requested_tasks if task not in routes.allowed_tasks]
    if unknown_tasks:
        raise RuleManifestError(
            f"未知任务类型：{', '.join(unknown_tasks)}；允许的任务：{', '.join(routes.allowed_tasks)}"
        )
    if not paths and not requested_tasks:
        raise RuleManifestError("至少提供一个 scope 路径或 --task")

    scope = tuple(sorted({normalize_scope_path(path, root) for path in paths}))
    expanded = _expand_scope(root, scope)
    matcher = RouteMatcher(routes)
    matched_ids: set[str] = set()
    unrouted: list[str] = []
    overlapping: list[str] = []
    for path in expanded:
        rule_ids = matcher.rule_ids(path)
        in_root_only = matcher.in_root_only(path)
        if rule_ids and in_root_only:
            overlapping.append(f"{path}（{', '.join(rule_ids)}）")
        elif not rule_ids and not in_root_only:
            unrouted.append(path if _repo_path(root, path).exists() else f"{path}（不存在）")
        matched_ids.update(rule_ids)
    if overlapping:
        raise RuleManifestError(
            f"scope 路径同时命中领域路由与 root_only：{_summarize(overlapping)}；运行 --check 修正 {ROUTES_PATH}"
        )
    if unrouted:
        raise RuleManifestError(
            f"scope 路径未登记领域路由，也不在 root_only：{_summarize(unrouted)}；"
            f"请在 {ROUTES_PATH} 登记（见 {RULES_DIR}/{RULES_README}）"
        )
    matched_ids.update(rule.id for rule in routes.rules if set(rule.tasks) & set(requested_tasks))

    rules = tuple(sorted((rule for rule in routes.rules if rule.id in matched_ids), key=lambda rule: rule.id))
    upstream_agents = tuple(
        sorted(
            agent
            for agent in routes.nested_agents
            if any(path.startswith(f"{_nested_agent_dir(agent)}/") for path in expanded)
        )
    )
    missing = [
        item
        for item in [rule.doc for rule in rules] + list(upstream_agents)
        if not _is_regular_file(_repo_path(root, item))
    ]
    if missing:
        raise RuleManifestError(f"解析结果引用的文件不存在：{', '.join(missing)}；运行 --check 查看闭集问题")
    return Resolution(scope, requested_tasks, rules, upstream_agents)


# ---- --check ----


def root_agents_problems(root: Path) -> tuple[list[str], int]:
    """根 AGENTS.md：普通文件、UTF-8、非空、≤ root_max_bytes、恰好一行 fork 段标记。"""

    path = root / ROOT_AGENTS
    if path.is_symlink() or not path.is_file():
        return ["仓库根 AGENTS.md 必须是普通文件"], 0
    try:
        data = path.read_bytes()
    except OSError as exc:
        return [f"无法读取根 AGENTS.md：{exc}"], 0
    problems: list[str] = []
    if len(data) > ROOT_AGENTS_MAX_BYTES:
        problems.append(f"根 AGENTS.md 为 {len(data)} bytes，超过 root_max_bytes={ROOT_AGENTS_MAX_BYTES}")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        problems.append("根 AGENTS.md 必须是 UTF-8 文本")
        return problems, len(data)
    if not text.strip():
        problems.append("根 AGENTS.md 不得为空")
    markers = sum(1 for line in text.splitlines() if line.startswith(FORK_MARKER))
    if markers == 0:
        problems.append(f"根 AGENTS.md 缺少 fork 段标记行（以 {FORK_MARKER!r} 开头，追加在上游正文之后）")
    elif markers > 1:
        problems.append(f"根 AGENTS.md 的 fork 段标记行出现 {markers} 次，必须恰好 1 次")
    return problems, len(data)


def sort_problems(routes: RuleRoutes) -> list[str]:
    problems: list[str] = []
    ids = [rule.id for rule in routes.rules]
    if ids != sorted(ids):
        problems.append(f"rules 必须按 id 排序；期望顺序：{sorted(ids)}")
    for rule in routes.rules:
        for field, values in (("paths", rule.paths), ("tasks", rule.tasks)):
            if list(values) != sorted(values):
                problems.append(f"规则 {rule.id} 的 {field} 必须排序；期望：{sorted(values)}")
    for field, values in (("root_only", routes.root_only), ("nested_agents", routes.nested_agents)):
        if list(values) != sorted(values):
            problems.append(f"{field} 必须排序；期望：{sorted(values)}")
    return problems


def domain_doc_problems(root: Path, routes: RuleRoutes) -> tuple[list[str], dict[str, str]]:
    """领域文档闭集与体积；同时返回可读正文（doc → text）供重复段落检查。"""

    problems: list[str] = []
    rules_dir = root.joinpath(*RULES_DIR.parts)
    actual: set[str] = set()
    if rules_dir.is_dir():
        for entry in rules_dir.iterdir():
            if entry.name == RULES_README or not entry.name.lower().endswith(".md"):
                continue
            if entry.is_dir() and not entry.is_symlink():
                continue
            actual.add(f"{RULES_DIR}/{entry.name}")
    declared = [rule.doc for rule in routes.rules]
    unregistered = sorted(actual - set(declared))
    if unregistered:
        problems.append(f"{RULES_DIR} 下有未登记的领域文档：{unregistered}；请在 {ROUTES_PATH} 登记或删除")

    texts: dict[str, str] = {}
    missing: list[str] = []
    for doc in declared:
        path = _repo_path(root, doc)
        if not path.exists() and not path.is_symlink():
            missing.append(doc)
            continue
        if not _is_regular_file(path):
            problems.append(f"领域文档必须是普通文件：{doc}")
            continue
        try:
            data = path.read_bytes()
        except OSError as exc:
            problems.append(f"无法读取领域文档 {doc}：{exc}")
            continue
        if not data.strip():
            problems.append(f"领域文档为空：{doc}")
            continue
        if len(data) > DOMAIN_RULE_MAX_BYTES:
            problems.append(f"领域文档 {doc} 为 {len(data)} bytes，超过 {DOMAIN_RULE_MAX_BYTES}")
        try:
            texts[doc] = data.decode("utf-8")
        except UnicodeDecodeError:
            problems.append(f"领域文档必须是 UTF-8 文本：{doc}")
    if missing:
        problems.append(f"{ROUTES_PATH} 登记的领域文档不存在：{missing}")
    return problems, texts


def nested_agents_problems(routes: RuleRoutes, files: Sequence[str]) -> list[str]:
    """Git 可见的嵌套 AGENTS.md 集合必须与 nested_agents 精确相等。"""

    visible = {path for path in files if path.endswith(NESTED_AGENTS_SUFFIX)}
    registered = set(routes.nested_agents)
    problems: list[str] = []
    unregistered = sorted(visible - registered)
    stale = sorted(registered - visible)
    if unregistered:
        problems.append(
            f"发现未登记的嵌套 AGENTS.md：{unregistered}；上游新增嵌套 AGENTS.md 时须按序加入 "
            f"{ROUTES_PATH} 的 nested_agents，并按需在相关领域文档的「## 上游指令」中链接"
        )
    if stale:
        problems.append(f"nested_agents 登记的文件不是 Git 可见文件（过期条目）：{stale}；请从 {ROUTES_PATH} 移除")
    return problems


def _pattern_hits(pattern: str, files: Sequence[str], file_set: frozenset[str]) -> bool:
    if not any(char in pattern for char in "*?"):
        return pattern in file_set
    regex = _compile_pattern(pattern)
    return any(regex.fullmatch(path) for path in files)


def pattern_problems(routes: RuleRoutes, files: Sequence[str]) -> list[str]:
    """每个 pattern（含 root_only）至少命中 1 个 Git 可见文件。"""

    file_set = frozenset(files)
    problems = [
        f"规则 {rule.id} 的 pattern 未命中任何 Git 可见文件：{pattern}"
        for rule in routes.rules
        for pattern in rule.paths
        if not _pattern_hits(pattern, files, file_set)
    ]
    problems.extend(
        f"root_only 的 pattern 未命中任何 Git 可见文件：{pattern}"
        for pattern in routes.root_only
        if not _pattern_hits(pattern, files, file_set)
    )
    return problems


def coverage_problems(routes: RuleRoutes, files: Sequence[str]) -> list[str]:
    """每个 Git 可见文件恰好属于「至少一个领域」或「root_only」之一。"""

    matcher = RouteMatcher(routes)
    uncovered: list[str] = []
    overlapping: list[str] = []
    for path in files:
        in_domain = matcher.in_domain(path)
        in_root_only = matcher.in_root_only(path)
        if in_domain and in_root_only:
            overlapping.append(path)
        elif not in_domain and not in_root_only:
            uncovered.append(path)
    problems: list[str] = []
    if overlapping:
        problems.append(f"文件同时命中领域路由与 root_only（重叠）：{_summarize(overlapping)}")
    if uncovered:
        problems.append(f"Git 可见文件未被任何领域或 root_only 覆盖（未登记路由）：{_summarize(uncovered)}")
    return problems


def prose_units(text: str) -> set[str]:
    """领域文档的散文单元：空行分隔的段落及其中每个列表项（空白已归一为单个空格）。

    标题、表格行与围栏代码块不属于散文，不参与重复检查。
    """

    units: set[str] = set()
    block: list[str] = []
    item: list[str] = []
    fence: str | None = None

    def flush_item() -> None:
        if item:
            units.add(" ".join(" ".join(item).split()))
            item.clear()

    def flush_block() -> None:
        flush_item()
        if block:
            units.add(" ".join(" ".join(block).split()))
            block.clear()

    for line in text.splitlines():
        stripped = line.strip()
        if fence is not None:
            if stripped.startswith(fence):
                fence = None
            continue
        if stripped.startswith(("```", "~~~")):
            flush_block()
            fence = stripped[:3]
            continue
        if not stripped or stripped.startswith(("#", "|")):
            flush_block()
            continue
        marker = _LIST_ITEM.match(line)
        if marker:
            flush_item()
            content = line[marker.end():].strip()
            item.append(content)
            block.append(content)
            continue
        if item:
            item.append(stripped)
        block.append(stripped)
    flush_block()
    return {unit for unit in units if unit}


def duplicate_paragraph_problems(texts: dict[str, str]) -> list[str]:
    """不同领域文档之间不得出现 ≥160 字符的相同段落；比较时忽略全部空白（换行位置不同也算重复）。"""

    owners: dict[str, str] = {}
    problems: list[str] = []
    for doc in sorted(texts):
        for unit in sorted(prose_units(texts[doc])):
            if len(unit) < DUPLICATE_PARAGRAPH_MIN_CHARS:
                continue
            first = owners.setdefault("".join(unit.split()), doc)
            if first != doc:
                problems.append(
                    f"领域文档之间存在 ≥{DUPLICATE_PARAGRAPH_MIN_CHARS} 字符的重复段落：{first} 与 {doc}："
                    f"「{unit[:48]}…」"
                )
    return problems


def validate_repository(root: Path) -> CheckSummary:
    """--check：收集全部违规后一次性报告；无违规时返回摘要。"""

    root = root.resolve()
    problems, root_agents_bytes = root_agents_problems(root)
    try:
        routes = load_rule_routes(root)
    except RuleManifestError as exc:
        raise RuleManifestError("\n".join([*problems, str(exc)])) from exc
    problems.extend(sort_problems(routes))
    doc_problems, texts = domain_doc_problems(root, routes)
    problems.extend(doc_problems)
    try:
        files = repository_files(root)
    except RuleManifestError as exc:
        raise RuleManifestError("\n".join([*problems, str(exc)])) from exc
    problems.extend(nested_agents_problems(routes, files))
    problems.extend(pattern_problems(routes, files))
    problems.extend(coverage_problems(routes, files))
    problems.extend(duplicate_paragraph_problems(texts))
    if problems:
        raise RuleManifestError("\n".join(problems))
    return CheckSummary(routes, len(files), root_agents_bytes)


# ---- CLI ----


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="resolve_agent_rules.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("paths", nargs="*", metavar="PATH", help="本轮 scope 内的文件或目录（仓库相对或仓库内绝对路径）")
    parser.add_argument("--task", action="append", default=[], metavar="TASK", help="任务类型，可重复（如 review）")
    parser.add_argument("--json", action="store_true", dest="as_json", help="输出机器可读 JSON")
    parser.add_argument("--check", action="store_true", help="校验根 AGENTS.md、路由闭集与领域文档（须单独使用）")
    parser.add_argument("--root", type=Path, default=None, help="仓库根（默认：本脚本所在仓库）")
    return parser


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="replace", newline="\n")


def main(argv: Sequence[str] | None = None) -> int:
    _configure_stdio()
    parser = _parser()
    args = parser.parse_intermixed_args(argv)
    root = args.root if args.root is not None else REPO_ROOT
    if args.check and (args.paths or args.task or args.as_json):
        parser.error("--check 必须单独使用，不能与 PATH/--task/--json 同用")
    if not args.check and not args.paths and not args.task:
        parser.error("至少提供一个 PATH 或 --task（或单独使用 --check）")
    try:
        if args.check:
            print(validate_repository(root).describe())
            return 0
        resolution = resolve_rules(root, args.paths, args.task)
        if args.as_json:
            print(json.dumps(resolution.payload(), ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        else:
            for line in resolution.lines():
                print(line)
        return 0
    except RuleManifestError as exc:
        for line in str(exc).splitlines():
            print(f"error: {line}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
