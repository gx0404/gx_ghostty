#!/usr/bin/env python3
"""gx_ghostty 的 graphify 固定入口：钉版 graphifyy 0.9.73，代码-only AST 抽取，无需 API key。

用法：python scripts/graphify.py [--root PATH] rebuild|check|query|path|explain ...

rebuild             全量重建 graphify-out/graph.json 与 GRAPH_REPORT.md（排除表 .graphifyignore），
                    随后写入并校验 graphify-out/source-fingerprint.json
check               只校验指纹（不需要 graphify；过期退出 2）
query|path|explain  直通 graphify，图谱固定为 graphify-out/graph.json，拒绝自带 --graph

graphify 查找顺序：$GX_GHOSTTY_GRAPHIFY_CLI > .local/tools/venv（用 venv 的 python -m graphify 运行）> PATH。
不直接执行 venv 里的 graphify.exe：它是安装时生成的未签名启动器，Windows 应用控制（智能应用控制）
会拦截（WinError 4551）；venv 的 python.exe 来自已签名的基础解释器，可以正常运行。
版本必须等于 PINNED_VERSION，除非显式设置 GX_GHOSTTY_GRAPHIFY_ALLOW_ANY_VERSION=1。
其余 graphify 子命令（extract、update、install、hook 等）一律拒绝，避免改写图谱或用户目录。
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import graphify_fingerprint  # noqa: E402

REPO_ROOT = SCRIPTS_DIR.parent
PINNED_VERSION = "0.9.73"
CLI_ENV = "GX_GHOSTTY_GRAPHIFY_CLI"
ALLOW_ANY_VERSION_ENV = "GX_GHOSTTY_GRAPHIFY_ALLOW_ANY_VERSION"
GRAPH_OUT = "graphify-out"
GRAPH_JSON = f"{GRAPH_OUT}/graph.json"
REPORT = f"{GRAPH_OUT}/GRAPH_REPORT.md"
PASSTHROUGH_COMMANDS = ("query", "path", "explain")
FREE_TEXT_COMMANDS = ("query", "explain")
EXTRACT_ARGS = (
    "extract", ".", "--out", ".", "--force", "--code-only", "--no-cluster", "--max-workers", "4",
)
CLUSTER_ARGS = ("cluster-only", ".", "--graph", GRAPH_JSON, "--no-viz", "--no-label")
USAGE = "用法：python scripts/graphify.py rebuild|check|query|path|explain ..."


class GraphifyError(RuntimeError):
    def __init__(self, message: str, code: int = 1) -> None:
        super().__init__(message)
        self.code = code if 0 < code < 256 else 1


def venv_cli(root: Path) -> Path:
    """venv 的 graphify 启动器：只用来判断 graphifyy 是否装进了 venv，不直接执行。"""
    if os.name == "nt":
        return root / ".local" / "tools" / "venv" / "Scripts" / "graphify.exe"
    return root / ".local" / "tools" / "venv" / "bin" / "graphify"


def venv_python(root: Path) -> Path:
    if os.name == "nt":
        return root / ".local" / "tools" / "venv" / "Scripts" / "python.exe"
    return root / ".local" / "tools" / "venv" / "bin" / "python"


def _is_executable(path: Path) -> bool:
    return path.is_file() and (os.name == "nt" or os.access(path, os.X_OK))


def resolve_cli(root: Path, env: dict[str, str]) -> list[str]:
    """返回运行 graphify 的命令前缀（argv 列表）。"""
    configured = env.get(CLI_ENV, "").strip()
    if configured:
        candidate = Path(configured)
        if candidate.is_absolute() or "/" in configured or "\\" in configured:
            candidate = candidate if candidate.is_absolute() else Path.cwd() / candidate
            if not _is_executable(candidate):
                raise GraphifyError(f"{CLI_ENV} 指向的文件不存在或不可执行：{configured}")
            return [str(candidate)]
        found = shutil.which(configured, path=env.get("PATH"))
        if not found:
            raise GraphifyError(f"PATH 中找不到 {CLI_ENV}={configured}")
        return [found]
    python = venv_python(root)
    if _is_executable(python) and venv_cli(root).is_file():
        return [str(python), "-m", "graphify"]
    found = shutil.which("graphify", path=env.get("PATH"))
    if found:
        return [found]
    raise GraphifyError(
        f"未安装 graphify；运行 just setup（钉版 graphifyy=={PINNED_VERSION} 装入 .local/tools/venv）"
    )


def graphify_env(base: dict[str, str], *, rebuild: bool = False) -> dict[str, str]:
    env = dict(base)
    # 输出目录由项目钉死，不继承外部 GRAPHIFY_OUT；禁止 graphify 顺手刷新用户级 skill 目录。
    env["GRAPHIFY_OUT"] = GRAPH_OUT
    env["GRAPHIFY_NO_AUTO_REFRESH"] = "1"
    if rebuild:
        # 固定 hash seed，避免社区划分与报告随解释器随机漂移。
        env["PYTHONHASHSEED"] = "0"
    return env


def cli_version(cli: list[str], env: dict[str, str]) -> str:
    try:
        result = subprocess.run(
            [*cli, "--version"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise GraphifyError(f"无法运行 {' '.join(cli)} --version：{exc}") from exc
    match = re.search(r"graphify\s+v?(\S+)", result.stdout)
    return match.group(1) if match else ""


def ensure_version(cli: list[str], env: dict[str, str]) -> None:
    if env.get(ALLOW_ANY_VERSION_ENV, "").strip() == "1":
        return
    version = cli_version(cli, env)
    if version != PINNED_VERSION:
        raise GraphifyError(
            f"graphify 版本 {version or 'unknown'} != 钉版 {PINNED_VERSION}；运行 just setup 重装。"
            f"升级钉版前先在临时副本比对图谱稳定性，临时放行请显式设置 {ALLOW_ANY_VERSION_ENV}=1"
        )


def _run(command: list[str], root: Path, env: dict[str, str]) -> int:
    try:
        return subprocess.run(command, cwd=str(root), env=env, check=False).returncode
    except OSError as exc:
        raise GraphifyError(f"无法运行 {command[0]}：{exc}") from exc


def rebuild(root: Path, cli: list[str], env: dict[str, str]) -> None:
    code = _run([*cli, *EXTRACT_ARGS], root, env)
    if code != 0:
        raise GraphifyError(f"graphify extract 失败（退出码 {code}）", code)
    if not (root / GRAPH_JSON).is_file():
        raise GraphifyError(f"抽取未生成图谱：{GRAPH_JSON}")
    code = _run([*cli, *CLUSTER_ARGS], root, env)
    if code != 0:
        raise GraphifyError(f"graphify cluster-only 失败（退出码 {code}）", code)
    if not (root / REPORT).is_file():
        raise GraphifyError(f"聚类未生成报告：{REPORT}")
    graphify_fingerprint.write_fingerprint(root)
    for note in graphify_fingerprint.check_fingerprint(root):
        print(f"note: {note}")
    print(f"[graphify] 图谱已重建：{GRAPH_JSON}（本机）+ {REPORT} 与指纹（入库）")


def reject_graph_override(args: list[str]) -> None:
    for arg in args:
        if arg == "--graph" or arg.startswith("--graph="):
            raise GraphifyError(f"禁止覆盖项目固定图谱 {GRAPH_JSON}", 2)


def passthrough_args(command: str, args: list[str]) -> list[str]:
    """query/explain 的自由文本可以拆成多个参数传入（just 变参），在第一个选项前合并为一句。"""
    if not args:
        raise GraphifyError(f"{command} 需要参数；{USAGE}", 2)
    reject_graph_override(args)
    if command in FREE_TEXT_COMMANDS:
        split = next((i for i, arg in enumerate(args) if arg.startswith("--")), len(args))
        if split == 0:
            raise GraphifyError(f"{command} 的第一个参数必须是查询文本", 2)
        args = [" ".join(args[:split]), *args[split:]]
    elif len([arg for arg in args if not arg.startswith("--")]) < 2:
        raise GraphifyError('path 需要两个节点："<source>" "<target>"', 2)
    return [command, *args, "--graph", GRAPH_JSON]


def run_command(argv: list[str], root: Path, base_env: dict[str, str]) -> int:
    if not argv or argv[0] in ("help", "-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    command, args = argv[0], argv[1:]
    if command == "check":
        if args:
            raise GraphifyError("check 不接受额外参数", 2)
        for note in graphify_fingerprint.check_fingerprint(root):
            print(f"note: {note}")
        print("[graphify] 源码指纹、管线与入库产物一致")
        return 0
    if command == "rebuild":
        if args:
            raise GraphifyError("rebuild 不接受额外参数", 2)
        env = graphify_env(base_env, rebuild=True)
        cli = resolve_cli(root, env)
        ensure_version(cli, env)
        rebuild(root, cli, env)
        return 0
    if command in PASSTHROUGH_COMMANDS:
        command_args = passthrough_args(command, args)
        if not (root / GRAPH_JSON).is_file():
            raise GraphifyError(f"本机尚未构建 {GRAPH_JSON}（不入库）；先运行 just graph")
        env = graphify_env(base_env)
        cli = resolve_cli(root, env)
        ensure_version(cli, env)
        return _run([*cli, *command_args], root, env)
    raise GraphifyError(
        f"不支持的子命令：{command}；本项目只放行 rebuild|check|query|path|explain，"
        "图谱一律经 just graph 全量重建",
        2,
    )


def main(argv: list[str] | None = None) -> int:
    graphify_fingerprint.configure_output()
    args = list(sys.argv[1:] if argv is None else argv)
    root = REPO_ROOT
    if args[:1] == ["--root"]:
        if len(args) < 2:
            print("[graphify] ERROR: --root 需要目录参数", file=sys.stderr)
            return 2
        root = Path(args[1]).resolve()
        args = args[2:]
    try:
        return run_command(args, root, dict(os.environ))
    except graphify_fingerprint.FingerprintError as exc:
        print(f"[graphify] ERROR: {exc}", file=sys.stderr)
        return 2
    except GraphifyError as exc:
        print(f"[graphify] ERROR: {exc}", file=sys.stderr)
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())
