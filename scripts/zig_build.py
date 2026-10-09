#!/usr/bin/env python3
"""`just build` 的入口：给 `scripts/zigw.py build` 补平台默认参数，其余参数与退出码原样透传。

Windows 主机上，参数里没有 `-Dtarget=…`、也不是 `-Demit-lib-vt` 构建时，补上
`-Dtarget=x86_64-windows-gnu`：目标未写 ABI 时 `src/build/Config.zig` 强制 msvc，要求装有
Visual Studio 与 Windows SDK；GNU ABI 用 Zig 自带的 MinGW 头文件与导入库，产出 win32 应用
`zig-out/bin/ghostty.exe`（Windows 目标的 `-Dapp-runtime` 默认即 win32）。其他主机、显式
`-Dtarget` 与 lib-vt 构建（`just build-vt`）保持 zig build 原样。

用法：python scripts/zig_build.py [zig build 参数...]
"""

from __future__ import annotations

import sys
from typing import Sequence

try:
    import zigw
except ImportError:  # 以 scripts 包子模块方式导入时
    from scripts import zigw  # type: ignore[no-redef]

WINDOWS_TARGET = "-Dtarget=x86_64-windows-gnu"


def builds_lib_vt(args: Sequence[str]) -> bool:
    """`-Demit-lib-vt` 或 `-Demit-lib-vt=<非 false>` 表示 libghostty-vt 构建。"""
    for arg in args:
        if arg == "-Demit-lib-vt":
            return True
        if arg.startswith("-Demit-lib-vt="):
            return arg.split("=", 1)[1] != "false"
    return False


def build_args(args: Sequence[str], windows: bool) -> list[str]:
    """传给 zig 的完整参数（含 build 子命令）；Windows 上按需在用户参数前补默认目标。"""
    args = list(args)
    explicit_target = any(arg.startswith("-Dtarget=") for arg in args)
    if windows and not explicit_target and not builds_lib_vt(args):
        args.insert(0, WINDOWS_TARGET)
    return ["build", *args]


def main(argv: Sequence[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else list(argv)
    return zigw.main(build_args(args, sys.platform == "win32"))


if __name__ == "__main__":
    raise SystemExit(main())
