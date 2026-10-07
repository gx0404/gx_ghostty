#!/usr/bin/env python3
"""钉版 Zig 包装器：解析 Zig、校验版本、补项目内全局缓存，再原样透传参数与退出码。

解析顺序：$GX_GHOSTTY_ZIG > $ZIG > <repo>/.local/toolchains/zig/zig-0.16.0/zig[.exe]
（安装根可用 GX_GHOSTTY_ZIG_HOME 覆盖）> PATH 中的 zig。环境变量一旦设置就是权威：
指向不存在的文件直接报错，不会悄悄回退到后面的候选。

选中的 Zig 必须满足 `zig version` == setup_zig.ZIG_VERSION（即 build.zig.zon 的
minimum_zig_version，由 scripts/test_setup_zig.py 锁定）。未设置 ZIG_GLOBAL_CACHE_DIR
时默认为 <repo>/.local/zig-cache/global（目录由 zig 自行创建）。

退出码：找不到 Zig 或版本不符退出 2（提示运行 just setup）；其余情况等于 zig 自身退出码。
用法：python scripts/zigw.py <zig 参数...>，例如 python scripts/zigw.py build test-lib-vt
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Mapping, NamedTuple, Sequence

try:
    import setup_zig
except ImportError:  # 以 scripts 包子模块方式导入时
    from scripts import setup_zig  # type: ignore[no-redef]

REPO_ROOT = Path(__file__).resolve().parents[1]
ENV_OVERRIDES = ("GX_GHOSTTY_ZIG", "ZIG")
CACHE_ENV = "ZIG_GLOBAL_CACHE_DIR"
SOURCE_LABELS = {"GX_GHOSTTY_ZIG": "$GX_GHOSTTY_ZIG", "ZIG": "$ZIG", "pinned": "钉版目录", "PATH": "PATH"}


class ZigwError(RuntimeError):
    """找不到可用的 Zig，或版本与钉版不符。"""


class ResolvedZig(NamedTuple):
    path: str
    source: str  # GX_GHOSTTY_ZIG / ZIG / pinned / PATH


def default_cache_dir(root: Path | None = None) -> Path:
    return (REPO_ROOT if root is None else Path(root)) / ".local" / "zig-cache" / "global"


def _lookup(value: str, env: Mapping[str, str]) -> str | None:
    """含路径分隔符的值按文件路径解析，裸命令名按 PATH 解析。"""
    if os.sep in value or (os.altsep is not None and os.altsep in value) or Path(value).is_absolute():
        candidate = Path(value).expanduser()
        return str(candidate.absolute()) if candidate.is_file() else None
    return setup_zig.which_on_path(value, env.get("PATH"))


def resolve_zig(env: Mapping[str, str] | None = None, root: Path | None = None) -> ResolvedZig:
    """按优先级选出 Zig 候选（不校验版本）；一个都没有时抛 ZigwError。"""
    env = os.environ if env is None else env
    for name in ENV_OVERRIDES:
        value = env.get(name, "").strip()
        if not value:
            continue
        found = _lookup(value, env)
        if found is None:
            raise ZigwError(
                f"${name}={value} 不是可执行的 zig；修正或取消该变量，或运行 just setup 安装钉版 Zig {setup_zig.ZIG_VERSION}"
            )
        return ResolvedZig(found, name)
    pinned = setup_zig.zig_binary(env, root)
    if pinned.is_file():
        return ResolvedZig(str(pinned), "pinned")
    found = setup_zig.which_on_path("zig", env.get("PATH"))
    if found:
        return ResolvedZig(found, "PATH")
    raise ZigwError(
        f"找不到 Zig {setup_zig.ZIG_VERSION}：运行 just setup 安装钉版到 {pinned.parent}，"
        f"或设置 GX_GHOSTTY_ZIG / ZIG 指向已有的 Zig {setup_zig.ZIG_VERSION}"
    )


def zig_version(path: str, env: Mapping[str, str] | None = None) -> str | None:
    return setup_zig.run_zig_version(path, env)


def require_zig(env: Mapping[str, str] | None = None, root: Path | None = None) -> ResolvedZig:
    """解析 Zig 并校验 `zig version` 等于钉版；不符时抛 ZigwError。"""
    zig = resolve_zig(env, root)
    version = zig_version(zig.path, env)
    if version == setup_zig.ZIG_VERSION:
        return zig
    found = version or "无法运行"
    if zig.source == "pinned":
        remedy = "钉版目录已损坏，覆盖重装：python scripts/setup_zig.py --force"
    elif zig.source == "PATH":
        remedy = "运行 just setup 安装钉版（钉版优先于 PATH）"
    else:
        remedy = f"让 ${zig.source} 指向 Zig {setup_zig.ZIG_VERSION}，或取消它后运行 just setup"
    raise ZigwError(
        f"{SOURCE_LABELS[zig.source]} 提供的 {zig.path} 版本为 {found}，本仓要求 Zig {setup_zig.ZIG_VERSION}；{remedy}"
    )


def child_env(env: Mapping[str, str] | None = None, root: Path | None = None) -> dict[str, str]:
    """子进程环境：仅当 ZIG_GLOBAL_CACHE_DIR 未设置（或为空）时补项目内默认值。"""
    result = dict(os.environ if env is None else env)
    if not result.get(CACHE_ENV, "").strip():
        result[CACHE_ENV] = str(default_cache_dir(root))
    return result


def _exit_status(code: int) -> int:
    if os.name == "nt":
        # NTSTATUS 之类的大退出码转成有符号值，SystemExit 才能原样还原。
        return code - (1 << 32) if code > 0x7FFFFFFF else code
    # POSIX 下被信号 N 终止时 returncode 为 -N，按 shell 惯例转成 128+N。
    return 128 - code if code < 0 else code


def run(zig_path: str, args: Sequence[str], env: Mapping[str, str]) -> int:
    process = subprocess.Popen([zig_path, *args], env=dict(env))
    try:
        return _exit_status(process.wait())
    except KeyboardInterrupt:
        # Ctrl+C 同时送达 zig；先等它自行退出，再次中断或超时才强杀。
        try:
            return _exit_status(process.wait(timeout=30))
        except (KeyboardInterrupt, subprocess.TimeoutExpired):
            process.kill()
            process.wait()
            return 130


def main(argv: Sequence[str] | None = None) -> int:
    setup_zig.utf8_stdio()
    args = sys.argv[1:] if argv is None else list(argv)
    env = child_env(os.environ, REPO_ROOT)
    try:
        zig = require_zig(env, REPO_ROOT)
    except ZigwError as exc:
        print(f"[zigw] error: {exc}", file=sys.stderr)
        return 2
    return run(zig.path, args, env)


if __name__ == "__main__":
    raise SystemExit(main())
