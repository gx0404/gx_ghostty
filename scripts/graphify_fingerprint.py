#!/usr/bin/env python3
"""graphify 图谱指纹：登记源码、管线与产物哈希，判断图谱是否过期。

用法：python scripts/graphify_fingerprint.py write|check [--root PATH]

write : just graph 重建后调用。先把 graphify-out/GRAPH_REPORT.md 规范为 LF，
        再写入 graphify-out/source-fingerprint.json（排序键、LF、无时间戳）。
check : 只读校验，不需要安装 graphify；源码、管线或入库产物任一漂移即退出 2。

源码集合镜像 graphify 0.9.73 在 `extract . --code-only` 下的选择：Git 可见文件中
带被索引扩展名（或无扩展名但 shebang 指向代码解释器）的文件，去掉 .graphifyignore
排除项，以及 graphify 无条件剪掉的目录（build/、dist/、target/ 等）。
文本统一按 LF 计算哈希，core.autocrlf 检出的 CRLF 副本与 Linux CI 得到同一指纹。
graph.json 是本机产物（不入库）：存在时才登记与校验，缺失时 check 只提示。
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = 1
INDEX_ROOT = "."
GRAPH_DIR = "graphify-out"
FINGERPRINT_NAME = "source-fingerprint.json"
REPORT_NAME = "GRAPH_REPORT.md"
LOCAL_GRAPH_NAME = "graph.json"
IGNORE_FILE = ".graphifyignore"
PIPELINE_INPUTS = (
    "scripts/graphify.py",
    "scripts/graphify_fingerprint.py",
    ".graphifyignore",
)

# fork 文档承诺指纹覆盖的扩展名（docs/ARCHITECTURE.md）；INDEXED_EXTENSIONS 必须是它的超集（测试锁定）。
CONTRACT_EXTENSIONS = (
    ".zig", ".swift", ".c", ".h", ".cpp", ".cc", ".hpp", ".m", ".mm", ".metal",
    ".py", ".sh", ".bash",
)
# graphify 0.9.73 detect.CODE_EXTENSIONS（--code-only 实际抽取的全集，按小写后缀匹配）。
INDEXED_EXTENSIONS = frozenset(
    {
        ".py", ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".ejs", ".ets",
        ".go", ".rs", ".vb", ".cbl", ".cob", ".cobol", ".cpy", ".java", ".groovy", ".gradle",
        ".cpp", ".cc", ".cxx", ".c", ".h", ".hpp", ".cu", ".cuh", ".metal", ".rb", ".rake",
        ".swift", ".kt", ".kts", ".cs", ".scala", ".php", ".lua", ".luau", ".toc", ".zig",
        ".ps1", ".psm1", ".psd1", ".ex", ".exs", ".m", ".mm", ".ml", ".mli", ".jl", ".vue",
        ".svelte", ".astro", ".dart", ".v", ".sv", ".svh", ".sql", ".r", ".f", ".f90", ".f95",
        ".f03", ".f08", ".pas", ".pp", ".dpr", ".dpk", ".lpr", ".inc", ".dfm", ".lfm", ".lpk",
        ".sh", ".bash", ".json", ".tf", ".tfvars", ".hcl", ".dm", ".dme", ".dmi", ".dmm",
        ".dmf", ".sln", ".slnx", ".csproj", ".fsproj", ".vbproj", ".xaml", ".razor", ".cshtml",
        ".cls", ".trigger", ".lisp", ".cl", ".lsp", ".asd", ".robot", ".resource", ".sol",
        ".erl", ".hrl", ".escript",
    }
)
# graphify 0.9.73 manifest_ingest.PACKAGE_MANIFEST_NAMES：按文件名走代码抽取。
PACKAGE_MANIFEST_NAMES = frozenset(
    {"apm.yml", "apm.yaml", "pyproject.toml", "cargo.toml", "go.mod", "pom.xml"}
)
# graphify 0.9.73 detect._SHEBANG_CODE_INTERPRETERS：无扩展名文件按 shebang 判定为代码。
SHEBANG_INTERPRETERS = frozenset(
    {
        "python", "python3", "python2", "ruby", "perl", "node", "nodejs", "bash", "sh",
        "dash", "zsh", "fish", "ksh", "tcsh", "lua", "php", "julia", "Rscript",
    }
)
# graphify 0.9.73 detect._SKIP_DIRS 中按名字无条件剪枝的目录；env/out/coverage/snapshots
# 等需要磁盘证据才剪的名字不在此列（graphify 对它们“存疑即保留”）。
NOISE_DIR_NAMES = frozenset(
    {
        "venv", ".venv", "node_modules", "__pycache__", ".git", "dist", "build", "target",
        "site-packages", "lib64", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",
        ".nox", ".eggs", "graphify-out", "lcov-report", "visual-tests", "visual-test",
        "__snapshots__", "storybook-static", "dist-protected", ".next", ".nuxt", ".turbo",
        ".angular", ".idea", ".cache", ".parcel-cache", ".svelte-kit", ".terraform",
        ".serverless", ".graphify", ".obsidian", ".smart-env", ".worktrees",
    }
)
# graphify 0.9.73 detect._SKIP_FILES。
SKIP_FILE_NAMES = frozenset(
    {
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "poetry.lock",
        "Gemfile.lock", "composer.lock", "go.sum", "go.work.sum", ".graphifyinclude",
    }
)
# 定位仓库的 Git 环境变量会让 `git -C <root>` 看到别的仓库（例如在 hook 里运行）。
_GIT_LOCATION_ENV = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
)


class FingerprintError(RuntimeError):
    """指纹缺失、过期、不一致，或无法计算。"""


@dataclass(frozen=True)
class IgnoreRule:
    pattern: str
    negated: bool
    directory_only: bool
    anchored: bool


def parse_ignore_rules(text: str) -> list[IgnoreRule]:
    """解析 gitignore 语法的子集：注释、`!` 取反、`/` 结尾只匹配目录、
    含 `/` 的模式锚定到仓库根、`*`/`?`/`[...]` 不跨 `/`、`**` 匹配任意层目录。"""
    rules: list[IgnoreRule] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        negated = line.startswith("!")
        if negated:
            line = line[1:]
        if line.startswith("\\"):
            line = line[1:]
        directory_only = line.endswith("/")
        body = line.rstrip("/")
        anchored = "/" in body
        body = body.lstrip("/")
        if body:
            rules.append(IgnoreRule(body, negated, directory_only, anchored))
    return rules


def _match_segments(path_parts: list[str], pattern_parts: list[str]) -> bool:
    memo: dict[tuple[int, int], bool] = {}

    def match(pi: int, qi: int) -> bool:
        key = (pi, qi)
        if key in memo:
            return memo[key]
        if qi == len(pattern_parts):
            result = pi == len(path_parts)
        elif pattern_parts[qi] == "**":
            result = match(pi, qi + 1) or (pi < len(path_parts) and match(pi + 1, qi))
        else:
            result = (
                pi < len(path_parts)
                and fnmatch.fnmatchcase(path_parts[pi], pattern_parts[qi])
                and match(pi + 1, qi + 1)
            )
        memo[key] = result
        return result

    return match(0, 0)


def _rule_matches(rule: IgnoreRule, rel: str, is_dir: bool) -> bool:
    if rule.directory_only and not is_dir:
        return False
    if rule.anchored:
        return _match_segments(rel.split("/"), rule.pattern.split("/"))
    return fnmatch.fnmatchcase(rel.rsplit("/", 1)[-1], rule.pattern)


def _last_match(rules: list[IgnoreRule], rel: str, is_dir: bool) -> bool:
    ignored = False
    for rule in rules:
        if _rule_matches(rule, rel, is_dir):
            ignored = not rule.negated
    return ignored


def is_ignored(rel_path: str, rules: list[IgnoreRule]) -> bool:
    """gitignore 语义：任一祖先目录被排除则整棵子树排除（`!` 不能救回其中文件）。"""
    if not rules:
        return False
    parts = rel_path.split("/")
    for depth in range(1, len(parts)):
        if _last_match(rules, "/".join(parts[:depth]), is_dir=True):
            return True
    return _last_match(rules, rel_path, is_dir=False)


def in_noise_dir(rel_path: str) -> bool:
    parents = rel_path.split("/")[:-1]
    for index, name in enumerate(parents):
        if name in NOISE_DIR_NAMES or name.endswith(("_venv", ".egg-info")):
            return True
        if name == "worktrees" and index > 0 and parents[index - 1].startswith("."):
            return True
    return False


def _env_command(args: list[str], allow_split: bool = True) -> list[str]:
    """剥掉 env(1) 的选项与 NAME=value，返回真正的命令 argv（镜像 graphify）。"""
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            return args[index + 1:]
        if allow_split:
            for flag in ("-S", "-vS"):
                if arg == flag:
                    rest = " ".join(args[index + 1:])
                    return _env_command(shlex.split(rest), allow_split=False) if rest else []
                if arg.startswith(flag) and len(arg) > len(flag) and not arg.startswith("--"):
                    packed = " ".join([arg[len(flag):], *args[index + 1:]])
                    return _env_command(shlex.split(packed), allow_split=False)
            if arg.startswith("--split-string="):
                packed = " ".join([arg.split("=", 1)[1], *args[index + 1:]])
                return _env_command(shlex.split(packed), allow_split=False)
            if arg == "--split-string":
                if index + 1 >= len(args):
                    return []
                packed = " ".join(args[index + 1:])
                return _env_command(shlex.split(packed), allow_split=False)
        if arg in {"-u", "-C", "-P", "-a", "--unset", "--chdir", "--argv0"}:
            if index + 2 > len(args):
                return []
            index += 2
            continue
        if arg.startswith(("-u", "-C", "-P", "-a")) and len(arg) > 2 and not arg.startswith("--"):
            index += 1
            continue
        if arg.startswith(("--unset=", "--chdir=", "--argv0=")):
            index += 1
            continue
        if arg in {"-", "-i", "-0", "-v", "--ignore-environment", "--null", "--debug",
                   "--list-signal-handling"}:
            index += 1
            continue
        if arg.startswith(("--default-signal", "--ignore-signal", "--block-signal")):
            index += 1
            continue
        if arg.startswith("-"):
            return []
        if "=" in arg:
            index += 1
            continue
        return args[index:]
    return []


def shebang_interpreter(path: Path) -> str | None:
    try:
        with path.open("rb") as handle:
            head = handle.read(256)
    except OSError:
        return None
    if not head.startswith(b"#!"):
        return None
    line = head.split(b"\n")[0].decode("utf-8", errors="replace")[2:].strip()
    try:
        parts = shlex.split(line)
    except ValueError:
        return None
    if not parts:
        return None
    interpreter = PurePosixPath(parts[0].replace("\\", "/")).name
    if interpreter == "env":
        try:
            command = _env_command(parts[1:])
        except ValueError:
            return None
        if not command:
            return None
        interpreter = PurePosixPath(command[0].replace("\\", "/")).name
    return interpreter


def is_indexed_file(root: Path, rel_path: str) -> bool:
    name = rel_path.rsplit("/", 1)[-1]
    if name.lower() in PACKAGE_MANIFEST_NAMES:
        return True
    suffix = PurePosixPath(name).suffix.lower()
    if suffix:
        return suffix in INDEXED_EXTENSIONS
    return shebang_interpreter(root / rel_path) in SHEBANG_INTERPRETERS


def git_env() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if key not in _GIT_LOCATION_ENV}


def git_visible_files(root: Path) -> list[str]:
    """`git ls-files --cached --others --exclude-standard` 中仍存在于磁盘的普通文件。"""
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            check=False,
            env=git_env(),
        )
    except OSError as exc:
        raise FingerprintError(f"无法运行 git：{exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise FingerprintError(f"git ls-files 失败：{detail or result.returncode}")
    files: set[str] = set()
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        rel = raw.decode("utf-8", errors="surrogateescape")
        if (root / rel).is_file():
            files.add(rel)
    return sorted(files)


def load_ignore_rules(root: Path) -> list[IgnoreRule]:
    path = root / IGNORE_FILE
    if not path.is_file():
        raise FingerprintError(f"缺少 {IGNORE_FILE}；图谱排除表是管线输入，不能省略")
    try:
        text = path.read_bytes().decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise FingerprintError(f"{IGNORE_FILE} 不是 UTF-8：{exc}") from exc
    return parse_ignore_rules(text)


def graph_sources(root: Path) -> list[str]:
    rules = load_ignore_rules(root)
    return [
        rel
        for rel in git_visible_files(root)
        if rel.rsplit("/", 1)[-1] not in SKIP_FILE_NAMES
        and not in_noise_dir(rel)
        and not is_ignored(rel, rules)
        and is_indexed_file(root, rel)
    ]


def normalized_bytes(path: Path) -> bytes:
    return path.read_bytes().replace(b"\r\n", b"\n")


def sha256_text_file(path: Path) -> str:
    return hashlib.sha256(normalized_bytes(path)).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def source_digest(root: Path, sources: list[str]) -> str:
    digest = hashlib.sha256()
    for rel in sources:
        digest.update(rel.encode("utf-8", errors="surrogateescape"))
        digest.update(b"\0")
        digest.update(sha256_text_file(root / rel).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def pipeline_digests(root: Path) -> dict[str, str]:
    digests: dict[str, str] = {}
    for rel in PIPELINE_INPUTS:
        path = root / rel
        if not path.is_file():
            raise FingerprintError(f"管线输入缺失：{rel}")
        digests[rel] = sha256_text_file(path)
    return digests


def build_payload(root: Path) -> dict:
    sources = graph_sources(root)
    graph_dir = root / GRAPH_DIR
    artifacts: dict[str, str] = {}
    report = graph_dir / REPORT_NAME
    if report.is_file():
        artifacts[REPORT_NAME] = sha256_text_file(report)
    graph_json = graph_dir / LOCAL_GRAPH_NAME
    if graph_json.is_file():
        artifacts[LOCAL_GRAPH_NAME] = sha256_file(graph_json)
    return {
        "schema_version": SCHEMA_VERSION,
        "index_root": INDEX_ROOT,
        "source": {"file_count": len(sources), "sha256": source_digest(root, sources)},
        "pipeline": pipeline_digests(root),
        "artifacts": artifacts,
    }


def render(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def write_fingerprint(root: Path = REPO_ROOT) -> Path:
    graph_dir = root / GRAPH_DIR
    report = graph_dir / REPORT_NAME
    if not report.is_file():
        raise FingerprintError(f"缺少 {GRAPH_DIR}/{REPORT_NAME}；先完成 graphify 抽取与聚类（just graph）")
    content = report.read_bytes()
    normalized = content.replace(b"\r\n", b"\n")
    if normalized != content:
        report.write_bytes(normalized)
    payload = build_payload(root)
    target = graph_dir / FINGERPRINT_NAME
    target.write_bytes(render(payload).encode("utf-8"))
    print(
        f"fingerprint written: {GRAPH_DIR}/{FINGERPRINT_NAME}"
        f"（{payload['source']['file_count']} 个源文件）"
    )
    return target


def check_fingerprint(root: Path = REPO_ROOT) -> list[str]:
    """返回提示信息；任何漂移抛 FingerprintError（列出全部原因）。"""
    target = root / GRAPH_DIR / FINGERPRINT_NAME
    rebuild_hint = "运行 just graph 重建，并提交 GRAPH_REPORT.md 与 source-fingerprint.json"
    if not target.is_file():
        raise FingerprintError(f"缺少 {GRAPH_DIR}/{FINGERPRINT_NAME}；{rebuild_hint}")
    try:
        stored = json.loads(target.read_bytes().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FingerprintError(f"指纹文件不可读：{exc}；{rebuild_hint}") from exc
    if not isinstance(stored, dict) or stored.get("schema_version") != SCHEMA_VERSION:
        raise FingerprintError(f"指纹 schema 版本不匹配（期望 {SCHEMA_VERSION}）；{rebuild_hint}")

    current = build_payload(root)
    problems: list[str] = []
    notes: list[str] = []
    stored_source = stored.get("source") if isinstance(stored.get("source"), dict) else {}
    if stored_source.get("sha256") != current["source"]["sha256"]:
        old_count = stored_source.get("file_count")
        new_count = current["source"]["file_count"]
        counts = f"（被索引文件 {old_count} → {new_count}）" if old_count != new_count else ""
        problems.append(f"源码指纹已变化{counts}：被索引的源文件有增删改，图谱已过期")
    stored_pipeline = stored.get("pipeline") if isinstance(stored.get("pipeline"), dict) else {}
    for name in sorted(set(stored_pipeline) | set(current["pipeline"])):
        if stored_pipeline.get(name) != current["pipeline"].get(name):
            problems.append(f"管线输入已变化：{name}")
    stored_artifacts = stored.get("artifacts") if isinstance(stored.get("artifacts"), dict) else {}
    if REPORT_NAME not in stored_artifacts:
        problems.append(f"指纹未登记 {GRAPH_DIR}/{REPORT_NAME}")
    elif REPORT_NAME not in current["artifacts"]:
        problems.append(f"入库产物缺失：{GRAPH_DIR}/{REPORT_NAME}")
    elif stored_artifacts[REPORT_NAME] != current["artifacts"][REPORT_NAME]:
        problems.append(f"{GRAPH_DIR}/{REPORT_NAME} 与指纹不一致（报告被手改或未随指纹一起更新）")
    if LOCAL_GRAPH_NAME in stored_artifacts:
        if LOCAL_GRAPH_NAME not in current["artifacts"]:
            notes.append(
                f"{GRAPH_DIR}/{LOCAL_GRAPH_NAME} 本机未构建（不入库）；"
                "query/path/explain 需先运行 just graph"
            )
        elif stored_artifacts[LOCAL_GRAPH_NAME] != current["artifacts"][LOCAL_GRAPH_NAME]:
            problems.append(f"本机 {GRAPH_DIR}/{LOCAL_GRAPH_NAME} 与指纹不一致（来自另一次重建）")
    if problems:
        detail = "\n".join(f"  - {problem}" for problem in problems)
        raise FingerprintError(f"图谱已过期：\n{detail}\n{rebuild_hint}")
    return notes


def configure_output() -> None:
    """控制台编码不支持中文时用替换字符输出，避免 UnicodeEncodeError 吞掉真实退出码。"""
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(errors="replace")
            except (OSError, ValueError):
                pass


def main(argv: list[str] | None = None) -> int:
    configure_output()
    parser = argparse.ArgumentParser(
        description="graphify 图谱指纹：write 登记，check 只读校验（漂移退出 2）",
    )
    parser.add_argument("mode", choices=("write", "check"))
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="仓库根目录（默认为脚本所在仓库）")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        if args.mode == "write":
            write_fingerprint(root)
        else:
            for note in check_fingerprint(root):
                print(f"note: {note}")
            print(f"OK: {GRAPH_DIR}/{FINGERPRINT_NAME} 与源码、管线、入库产物一致")
    except FingerprintError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
