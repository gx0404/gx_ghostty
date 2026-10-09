#!/usr/bin/env python3
"""gx_ghostty 一键环境：钉版 Zig 与框架 venv 装进仓库内 .local/；--check 是只读体检。

默认（just setup）幂等补齐：
  1. 钉版 Zig 0.16.0 → .local/toolchains/zig/zig-0.16.0/（委托 setup_zig.py）。
     $GX_GHOSTTY_ZIG / $ZIG 已指向可用的 0.16.0 时，按 zigw 解析顺序它优先生效，跳过下载。
  2. 框架 venv → .local/tools/venv/，内装 graphifyy==0.9.73：有 uv 时用
     `uv venv --python <真实解释器> <venv>` + `uv pip install --python <venv python>`，
     否则 `python -m venv` + pip；已就绪则跳过。
--innosetup（just setup --innosetup，仅 Windows）另外安装钉版 Inno Setup 7.1.0：安装包按 sha256 校验
  （不符即删除并失败）后缓存在 .local/cache/innosetup/，以 /CURRENTUSER /PORTABLE=1 静默装进
  .local/tools/innosetup/（不写注册表、不建卸载项与快捷方式），供 just package-windows 生成安装包。
--check（just doctor）只读：不安装、不在仓库里建任何东西，输出 FOUND / MISSING / OPTIONAL 表；
  必需项（zig、python、git、venv、graphify，Windows 另加 MSVC）缺失时退出 1。
  Windows 上另在系统临时目录（仓库外，用后即删）试建一次符号链接，报告可选项 symlink，
  并报告可选项 innosetup（钉版 Inno Setup 是否已装进 .local/tools/innosetup/）。
--force 覆盖重装损坏的钉版 Zig。

WindowsApps 下的 python / python3 是 Python 安装管理器的别名，找不到匹配运行时会把
Python 装进当前目录；建 venv 一律用 find_real_python() 找到的真实解释器路径。
MSVC 与 git 属系统级工具，本脚本只检测不安装。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path
from typing import Callable, Iterable, Mapping, NamedTuple, Sequence

try:
    import setup_zig
    import zigw
except ImportError:  # 以 scripts 包子模块方式导入时
    from scripts import setup_zig, zigw  # type: ignore[no-redef]

REPO_ROOT = Path(__file__).resolve().parents[1]
GRAPHIFY_PACKAGE = "graphifyy"
GRAPHIFY_VERSION = "0.9.73"
GRAPHIFY_REQUIREMENT = f"{GRAPHIFY_PACKAGE}=={GRAPHIFY_VERSION}"
MIN_PYTHON = (3, 10)
VC_TOOLS_COMPONENT = "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
VSWHERE_RELATIVE = Path("Microsoft Visual Studio") / "Installer" / "vswhere.exe"
OPTIONAL_CLIS = ("codex", "claude", "kimi", "zcode", "actionlint", "uv")
ERROR_PRIVILEGE_NOT_HELD = 1314
SYMLINK_PRIVILEGE_HINT = "未开启开发者模式：just test-vt 的 tinyio 符号链接用例会以 PermissionDenied 失败"
INNOSETUP_VERSION = "7.1.0"
INNOSETUP_URL = "https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe"
INNOSETUP_SHA256 = "0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f"
INNOSETUP_MARKER = ".gx-innosetup"
INNOSETUP_HINT = "just setup --innosetup"
FOUND = "FOUND"
MISSING = "MISSING"
OPTIONAL = "OPTIONAL"

Runner = Callable[..., "subprocess.CompletedProcess[str]"]
Which = Callable[[str], "str | None"]


class SetupEnvError(RuntimeError):
    """环境安装步骤失败。"""


class Item(NamedTuple):
    name: str
    status: str  # FOUND / MISSING / OPTIONAL
    detail: str
    required: bool


def _getenv(env: Mapping[str, str], name: str) -> str:
    # Windows 上 dict(os.environ) 的键是大写，按原名与大写各查一次。
    return env.get(name) or env.get(name.upper()) or ""


def _run(runner: Runner, command: Sequence[str], **kwargs) -> "subprocess.CompletedProcess[str] | None":
    options = {
        "capture_output": True,
        "text": True,
        "encoding": "utf-8",
        "errors": "replace",
        "stdin": subprocess.DEVNULL,
        "timeout": 120,
        "check": False,
    }
    options.update(kwargs)
    try:
        return runner(list(command), **options)
    except (OSError, subprocess.SubprocessError):
        return None


def venv_dir(root: Path) -> Path:
    return Path(root) / ".local" / "tools" / "venv"


def venv_executable(venv: Path, name: str) -> Path:
    """venv 内可执行文件：Windows 为 Scripts/<name>.exe，其他平台为 bin/<name>。"""
    if os.name == "nt":
        return Path(venv) / "Scripts" / f"{name}.exe"
    return Path(venv) / "bin" / name


def innosetup_dir(root: Path) -> Path:
    return Path(root) / ".local" / "tools" / "innosetup"


def iscc_path(root: Path) -> Path:
    """钉版 Inno Setup 的命令行编译器；scripts/gx_windows_package.py 默认从这里取 ISCC。"""
    return innosetup_dir(root) / "ISCC.exe"


def innosetup_marker(root: Path) -> Path:
    return innosetup_dir(root) / INNOSETUP_MARKER


def innosetup_ready(root: Path) -> bool:
    """ISCC.exe 存在，且标记文件记录的正是钉版的版本与安装包 sha256。"""
    marker = innosetup_marker(root)
    if not iscc_path(root).is_file() or not marker.is_file():
        return False
    try:
        recorded = marker.read_text(encoding="utf-8").split()
    except (OSError, UnicodeDecodeError):
        return False
    return recorded == [INNOSETUP_VERSION, INNOSETUP_SHA256]


def is_windows_apps_alias(path: str | os.PathLike[str]) -> bool:
    """路径中任一段为 WindowsApps（不区分大小写）即视为应用执行别名。"""
    return any(part.lower() == "windowsapps" for part in re.split(r"[\\/]+", str(path)))


def _same_file(left: str, right: str) -> bool:
    return os.path.normcase(os.path.abspath(left)) == os.path.normcase(os.path.abspath(right))


def probe_python(candidate: str) -> str | None:
    """运行候选解释器取 sys.executable；版本低于 3.10 或无法运行时返回 None。"""
    if _same_file(candidate, sys.executable):
        return sys.executable if sys.version_info >= MIN_PYTHON else None
    code = "import sys; print(sys.executable if sys.version_info >= (3, 10) else '')"
    result = _run(subprocess.run, [candidate, "-c", code], timeout=30)
    if result is None or result.returncode != 0:
        return None
    return result.stdout.strip() or None


def _pymanager_minor(path: Path) -> int:
    match = re.search(r"pythoncore-3\.(\d+)", str(path))
    return int(match.group(1)) if match else -1


def python_candidates(env: Mapping[str, str] | None = None) -> list[str]:
    """候选顺序：当前解释器 → PATH 中全部 python3/python → Windows 安装管理器的运行时目录。"""
    env = os.environ if env is None else env
    candidates = [sys.executable]
    path_value = _getenv(env, "PATH")
    for name in ("python3", "python"):
        for entry in path_value.split(os.pathsep):
            entry = entry.strip().strip('"')
            if entry:
                found = shutil.which(os.path.join(entry, name))
                if found:
                    candidates.append(os.path.abspath(found))
    local = _getenv(env, "LOCALAPPDATA")
    if os.name == "nt" and local:
        installs = sorted((Path(local) / "Python").glob("pythoncore-3.*/python.exe"), key=_pymanager_minor, reverse=True)
        candidates.extend(str(path) for path in installs)
    return list(dict.fromkeys(candidate for candidate in candidates if candidate))


def find_real_python(
    candidates: Iterable[str] | None = None,
    probe: Callable[[str], str | None] = probe_python,
) -> str | None:
    """返回第一个可运行的 Python ≥3.10 的真实路径；WindowsApps 别名既不探测也不返回。"""
    for candidate in python_candidates() if candidates is None else candidates:
        if not candidate or is_windows_apps_alias(candidate):
            continue
        real = probe(candidate)
        if real and not is_windows_apps_alias(real):
            return real
    return None


def python_version(executable: str) -> str:
    if _same_file(executable, sys.executable):
        return platform.python_version()
    result = _run(subprocess.run, [executable, "-c", "import platform; print(platform.python_version())"], timeout=30)
    return result.stdout.strip() if result is not None and result.returncode == 0 else "?"


def _venv_probe_env() -> dict[str, str]:
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    for name in ("PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"):
        env.pop(name, None)
    return env


def graphify_version(venv: Path, runner: Runner = subprocess.run) -> str | None:
    """venv 中 graphifyy 的版本（读包元数据，不运行 graphify CLI）；不可用时返回 None。"""
    python = venv_executable(venv, "python")
    if not python.is_file():
        return None
    code = f"import importlib.metadata as m; print(m.version({GRAPHIFY_PACKAGE!r}))"
    result = _run(runner, [str(python), "-c", code], env=_venv_probe_env(), timeout=60)
    if result is None or result.returncode != 0:
        return None
    return result.stdout.strip() or None


def graphify_run_version(venv: Path, runner: Runner = subprocess.run) -> str | None:
    """实际运行 `<venv python> -m graphify --version`（scripts/graphify.py 的调用方式）得到的版本。

    包元数据存在不代表能运行：Windows 应用控制会拦截 venv 里生成的未签名 graphify.exe，
    所以体检按 graphify.py 的真实调用路径再跑一次；无法运行时返回 None。
    """
    python = venv_executable(venv, "python")
    if not python.is_file():
        return None
    env = dict(_venv_probe_env(), GRAPHIFY_NO_AUTO_REFRESH="1")
    result = _run(runner, [str(python), "-m", "graphify", "--version"], env=env, timeout=120)
    if result is None or result.returncode != 0:
        return None
    match = re.search(r"graphify\s+v?(\S+)", result.stdout or "")
    return match.group(1) if match else None


def venv_ready(venv: Path, runner: Runner = subprocess.run) -> bool:
    return graphify_version(venv, runner) == GRAPHIFY_VERSION and venv_executable(venv, "graphify").is_file()


def _runs(runner: Runner, command: Sequence[str]) -> bool:
    result = _run(runner, command, env=_venv_probe_env(), timeout=60)
    return result is not None and result.returncode == 0


# ---------------------------------------------------------------- doctor


def check_zig(env: Mapping[str, str], root: Path) -> Item:
    try:
        zig = zigw.require_zig(env, root)
    except zigw.ZigwError as exc:
        return Item("zig", MISSING, str(exc), True)
    origin = "钉版" if zig.source == "pinned" else f"非钉版，来自 {zigw.SOURCE_LABELS[zig.source]}"
    return Item("zig", FOUND, f"{setup_zig.ZIG_VERSION}（{origin}）{zig.path}", True)


def check_python(find: Callable[[], str | None] = find_real_python) -> Item:
    real = find()
    if not real:
        return Item("python", MISSING, "没有可运行的 Python ≥3.10（已跳过 WindowsApps 别名）", True)
    return Item("python", FOUND, f"{python_version(real)} {real}", True)


def check_git(which: Which = shutil.which, runner: Runner = subprocess.run) -> Item:
    git = which("git")
    if not git:
        return Item("git", MISSING, "未找到 git", True)
    result = _run(runner, [git, "--version"], timeout=30)
    if result is None or result.returncode != 0:
        return Item("git", MISSING, f"{git} 无法运行", True)
    return Item("git", FOUND, f"{result.stdout.strip()} {git}", True)


def vswhere_path(env: Mapping[str, str]) -> Path:
    base = _getenv(env, "ProgramFiles(x86)") or r"C:\Program Files (x86)"
    return Path(base) / VSWHERE_RELATIVE


def check_msvc(env: Mapping[str, str], runner: Runner = subprocess.run, is_windows: bool | None = None) -> Item | None:
    """仅 Windows：用 vswhere 查找带 VC 工具组件的 Visual Studio（含 Build Tools）。"""
    if not (os.name == "nt" if is_windows is None else is_windows):
        return None
    vswhere = vswhere_path(env)
    install_hint = "安装 Visual Studio 2022 Build Tools 并勾选「使用 C++ 的桌面开发」"
    if not vswhere.is_file():
        return Item("msvc", MISSING, f"未找到 {vswhere}；{install_hint}", True)
    command = [
        str(vswhere),
        "-latest",
        "-products",
        "*",
        "-requires",
        VC_TOOLS_COMPONENT,
        "-format",
        "json",
        "-utf8",
    ]
    result = _run(runner, command, timeout=60)
    if result is None or result.returncode != 0:
        return Item("msvc", MISSING, f"vswhere 运行失败；{install_hint}", True)
    try:
        instances = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        instances = []
    if not instances:
        return Item("msvc", MISSING, f"没有带 {VC_TOOLS_COMPONENT} 组件的 Visual Studio；{install_hint}", True)
    instance = instances[0]
    name = instance.get("displayName") or instance.get("productId") or "Visual Studio"
    version = instance.get("installationVersion", "?")
    return Item("msvc", FOUND, f"{name} {version} {instance.get('installationPath', '')}".strip(), True)


def check_venv(root: Path, runner: Runner = subprocess.run) -> list[Item]:
    venv = venv_dir(root)
    python = venv_executable(venv, "python")
    if not python.is_file():
        return [
            Item("venv", MISSING, f"{venv} 不存在；运行 just setup", True),
            Item("graphify", MISSING, f"需要 {GRAPHIFY_REQUIREMENT}（随 venv 安装）", True),
        ]
    venv_item = Item("venv", FOUND, str(python), True)
    version = graphify_version(venv, runner)
    cli = venv_executable(venv, "graphify")
    if version == GRAPHIFY_VERSION and cli.is_file():
        ran = graphify_run_version(venv, runner)
        if ran == GRAPHIFY_VERSION:
            detail = f"{GRAPHIFY_PACKAGE} {version}（`{python} -m graphify` 可运行）"
            return [venv_item, Item("graphify", FOUND, detail, True)]
        detail = (
            f"{GRAPHIFY_PACKAGE} {version} 已安装，但 `{python} -m graphify --version` "
            f"{'报告 ' + ran if ran else '无法运行'}；删除 .local/tools/venv 后重跑 just setup"
        )
        return [venv_item, Item("graphify", MISSING, detail, True)]
    state = f"版本为 {version}" if version else "未安装"
    if version == GRAPHIFY_VERSION:
        state = f"缺少 {cli}"
    return [venv_item, Item("graphify", MISSING, f"{GRAPHIFY_PACKAGE} {state}，需要 {GRAPHIFY_VERSION}；运行 just setup", True)]


def check_hooks(root: Path, which: Which = shutil.which, runner: Runner = subprocess.run) -> Item:
    git = which("git")
    if not git:
        return Item("hooksPath", OPTIONAL, "未找到 git，无法读取 core.hooksPath", False)
    result = _run(runner, [git, "-C", str(root), "config", "--get", "core.hooksPath"], timeout=30)
    value = result.stdout.strip() if result is not None and result.returncode == 0 else ""
    normalized = value.replace("\\", "/").rstrip("/")
    if normalized and normalized in {".githooks", (Path(root) / ".githooks").as_posix()}:
        return Item("hooksPath", FOUND, f"core.hooksPath={value}", False)
    state = f"当前为 {value}" if value else "未设置"
    return Item("hooksPath", OPTIONAL, f"core.hooksPath {state}（可选：just install-hooks）", False)


def check_symlink(is_windows: bool | None = None, symlink: Callable[[str, str], None] = os.symlink) -> Item | None:
    """仅 Windows：在系统临时目录（仓库外）试建符号链接，用后即删；只作可选项，不影响退出码。"""
    if not (os.name == "nt" if is_windows is None else is_windows):
        return None
    try:
        with tempfile.TemporaryDirectory(prefix="gx-doctor-", ignore_cleanup_errors=True) as tmp:
            target = Path(tmp) / "target"
            target.write_bytes(b"")
            symlink(str(target), str(Path(tmp) / "link"))
    except OSError as exc:
        if getattr(exc, "winerror", None) == ERROR_PRIVILEGE_NOT_HELD:
            return Item("symlink", OPTIONAL, SYMLINK_PRIVILEGE_HINT, False)
        return Item("symlink", OPTIONAL, f"试建符号链接失败（{exc}）：just test-vt 的 tinyio 符号链接用例可能失败", False)
    return Item("symlink", FOUND, "可创建符号链接", False)


def check_innosetup(root: Path, is_windows: bool | None = None) -> Item | None:
    """仅 Windows：钉版 Inno Setup 是否已装进 .local/tools/innosetup/；只作可选项。"""
    if not (os.name == "nt" if is_windows is None else is_windows):
        return None
    if innosetup_ready(root):
        return Item("innosetup", FOUND, f"Inno Setup {INNOSETUP_VERSION}（钉版）{iscc_path(root)}", False)
    target = innosetup_dir(root)
    if target.exists():
        detail = f"{target} 不是完整的钉版 Inno Setup {INNOSETUP_VERSION}；删除该目录后运行 {INNOSETUP_HINT}"
    else:
        detail = f"未安装（可选：just package-windows 生成安装包需要；{INNOSETUP_HINT}）"
    return Item("innosetup", OPTIONAL, detail, False)


def check_optional_clis(which: Which = shutil.which) -> list[Item]:
    items = []
    for name in OPTIONAL_CLIS:
        path = which(name)
        items.append(Item(name, FOUND, path, False) if path else Item(name, OPTIONAL, "未安装（可选）", False))
    return items


def collect(root: Path, env: Mapping[str, str]) -> list[Item]:
    items = [check_zig(env, root), check_python(), check_git()]
    msvc = check_msvc(env)
    if msvc is not None:
        items.append(msvc)
    items.extend(check_venv(root))
    items.append(check_hooks(root))
    symlink = check_symlink()
    if symlink is not None:
        items.append(symlink)
    innosetup = check_innosetup(root)
    if innosetup is not None:
        items.append(innosetup)
    items.extend(check_optional_clis())
    return items


def missing_required(items: Iterable[Item]) -> list[Item]:
    return [item for item in items if item.required and item.status == MISSING]


def exit_code(items: Iterable[Item]) -> int:
    return 1 if missing_required(items) else 0


def render(items: Sequence[Item]) -> str:
    width = max([len("ITEM"), *(len(item.name) for item in items)])
    lines = [f"{'STATUS':<9} {'ITEM':<{width}}  DETAIL"]
    for item in items:
        lines.append(f"{item.status:<9} {item.name:<{width}}  {item.detail}")
    return "\n".join(lines)


def doctor(root: Path, env: Mapping[str, str]) -> int:
    items = collect(root, env)
    print(f"[doctor] gx_ghostty 环境体检（只读）：{root}")
    print(render(items))
    missing = missing_required(items)
    if missing:
        names = "、".join(item.name for item in missing)
        print(f"[doctor] 缺少必需项：{names}；zig/venv/graphify 运行 just setup，其余按 DETAIL 提示安装")
        return 1
    print("[doctor] 必需项全部就绪（OPTIONAL 为可选项）")
    return 0


# ---------------------------------------------------------------- setup


def ensure_zig(env: Mapping[str, str], root: Path, force: bool = False) -> None:
    if not force and any(env.get(name, "").strip() for name in zigw.ENV_OVERRIDES):
        try:
            zig = zigw.require_zig(env, root)
        except zigw.ZigwError as exc:
            print(f"[setup-env] 警告：{exc}；仍安装钉版，但该变量设置期间 zigw 不会使用钉版")
        else:
            print(
                f"[setup-env] {zigw.SOURCE_LABELS[zig.source]} 已提供 Zig {setup_zig.ZIG_VERSION}（{zig.path}），"
                "按 zigw 解析顺序优先生效，跳过钉版下载"
            )
            return
    try:
        setup_zig.install(force=force, env=env, root=root)
    except setup_zig.SetupZigError as exc:
        raise SetupEnvError(str(exc)) from exc


def venv_commands(venv: Path, base_python: str, uv: str | None, *, recreate: bool, exists: bool) -> list[list[str]]:
    """建 venv 并安装钉版 graphifyy 的命令序列；recreate 时若目录已存在加 --clear 重建。"""
    python = str(venv_executable(venv, "python"))
    commands: list[list[str]] = []
    if uv:
        if recreate:
            create = [uv, "venv", "--python", base_python]
            if exists:
                create.append("--clear")
            commands.append([*create, str(venv)])
        commands.append([uv, "pip", "install", "--python", python, GRAPHIFY_REQUIREMENT])
    else:
        if recreate:
            create = [base_python, "-m", "venv"]
            if exists:
                create.append("--clear")
            commands.append([*create, str(venv)])
        commands.append([python, "-m", "pip", "install", "--disable-pip-version-check", GRAPHIFY_REQUIREMENT])
    return commands


def ensure_venv(
    root: Path,
    *,
    which: Which = shutil.which,
    runner: Runner = subprocess.run,
    find_python: Callable[[], str | None] = find_real_python,
    ready: Callable[[Path], bool] = venv_ready,
) -> None:
    venv = venv_dir(root)
    if ready(venv):
        print(f"[setup-env] 框架 venv 已就绪（{GRAPHIFY_REQUIREMENT}），跳过：{venv}")
        return
    base = find_python()
    if not base:
        raise SetupEnvError("没有可运行的 Python ≥3.10（已跳过 WindowsApps 别名），无法创建框架 venv")
    python = venv_executable(venv, "python")
    uv = which("uv")
    python_ok = python.is_file() and _runs(runner, [str(python), "-c", ""])
    recreate = not python_ok
    if not uv and python_ok:
        recreate = not _runs(runner, [str(python), "-m", "pip", "--version"])
    for command in venv_commands(venv, base, uv, recreate=recreate, exists=venv.exists()):
        print("[setup-env] $ " + subprocess.list2cmdline(command), flush=True)
        try:
            result = runner(command, check=False)
        except OSError as exc:
            raise SetupEnvError(f"无法运行 {command[0]}：{exc}") from exc
        if result.returncode != 0:
            raise SetupEnvError(f"命令失败（退出码 {result.returncode}）：{subprocess.list2cmdline(command)}")
    if not ready(venv):
        raise SetupEnvError(f"安装后校验失败：{venv} 中没有可用的 {GRAPHIFY_REQUIREMENT}")
    print(f"[setup-env] 框架 venv 就绪：{venv}（{GRAPHIFY_REQUIREMENT}）")


def file_sha256(path: Path) -> str:
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def download_verified(url: str, destination: Path, sha256: str, urlopen: Callable[..., object] = urllib.request.urlopen) -> None:
    """下载到 destination 并校验 sha256；已有且匹配则跳过，不匹配的下载删除后失败（fail closed）。"""
    destination = Path(destination)
    if destination.is_file() and file_sha256(destination) == sha256:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "gx_ghostty-setup-env"})
    try:
        with urlopen(request, timeout=120) as response, partial.open("wb") as stream:
            shutil.copyfileobj(response, stream, 1 << 20)
    except (OSError, ValueError) as exc:
        partial.unlink(missing_ok=True)
        raise SetupEnvError(f"下载失败 {url}：{exc}") from exc
    actual = file_sha256(partial)
    if actual != sha256:
        partial.unlink(missing_ok=True)
        raise SetupEnvError(f"sha256 不符，已删除下载：{url} 得到 {actual}，钉版为 {sha256}")
    os.replace(partial, destination)


def innosetup_command(installer: Path, target: Path, log: Path) -> list[str]:
    """Inno Setup 自身安装包的静默参数：当前用户、便携模式（不写注册表、不建卸载项与快捷方式）。"""
    return [
        str(installer),
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
        "/SP-",
        "/CURRENTUSER",
        "/PORTABLE=1",
        f"/DIR={target}",
        f"/LOG={log}",
    ]


def ensure_innosetup(
    root: Path,
    *,
    runner: Runner = subprocess.run,
    download: Callable[[str, Path, str], None] = download_verified,
    is_windows: bool | None = None,
) -> None:
    if not (os.name == "nt" if is_windows is None else is_windows):
        raise SetupEnvError("Inno Setup 只用于 Windows 安装包，非 Windows 主机不安装")
    target = innosetup_dir(root)
    if innosetup_ready(root):
        print(f"[setup-env] Inno Setup {INNOSETUP_VERSION} 已就绪，跳过：{iscc_path(root)}")
        return
    if target.exists():
        raise SetupEnvError(f"{target} 已存在但不是完整的钉版 Inno Setup {INNOSETUP_VERSION}；删除该目录后重试")
    cache = Path(root) / ".local" / "cache" / "innosetup"
    installer = cache / f"innosetup-{INNOSETUP_VERSION}-x64.exe"
    download(INNOSETUP_URL, installer, INNOSETUP_SHA256)
    command = innosetup_command(installer, target, cache / "install.log")
    print("[setup-env] $ " + subprocess.list2cmdline(command), flush=True)
    try:
        result = runner(command, check=False, timeout=900)
    except (OSError, subprocess.SubprocessError) as exc:
        raise SetupEnvError(f"无法运行 Inno Setup 安装包：{exc}") from exc
    if result.returncode != 0:
        raise SetupEnvError(f"Inno Setup 安装包退出码 {result.returncode}；日志：{cache / 'install.log'}")
    if not iscc_path(root).is_file():
        raise SetupEnvError(f"安装后没有找到 {iscc_path(root)}；日志：{cache / 'install.log'}")
    innosetup_marker(root).write_text(f"{INNOSETUP_VERSION} {INNOSETUP_SHA256}\n", encoding="utf-8", newline="\n")
    print(f"[setup-env] Inno Setup {INNOSETUP_VERSION} 就绪：{iscc_path(root)}")


def setup(root: Path, env: Mapping[str, str], force: bool = False, innosetup: bool = False) -> int:
    failures: list[tuple[str, str]] = []
    total = 3 if innosetup else 2
    print(f"[setup-env] 1/{total} 钉版 Zig {setup_zig.ZIG_VERSION}", flush=True)
    try:
        ensure_zig(env, root, force)
    except SetupEnvError as exc:
        failures.append(("zig", str(exc)))
    print(f"[setup-env] 2/{total} 框架 venv（{GRAPHIFY_REQUIREMENT}）", flush=True)
    try:
        ensure_venv(root)
    except SetupEnvError as exc:
        failures.append(("venv", str(exc)))
    if innosetup:
        print(f"[setup-env] 3/{total} 钉版 Inno Setup {INNOSETUP_VERSION}（.local/tools/innosetup，便携模式）", flush=True)
        try:
            ensure_innosetup(root)
        except SetupEnvError as exc:
            failures.append(("innosetup", str(exc)))
    if failures:
        for name, message in failures:
            print(f"[setup-env] 失败 {name}：{message}", file=sys.stderr)
        return 1
    print("[setup-env] 完成；运行 just doctor 复核（MSVC、git 等系统级工具只检测不安装）")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    setup_zig.utf8_stdio()
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog=__doc__.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="只读体检（just doctor），不安装任何东西")
    mode.add_argument("--force", action="store_true", help="覆盖重装损坏的钉版 Zig")
    parser.add_argument(
        "--innosetup",
        action="store_true",
        help=f"另外安装钉版 Inno Setup {INNOSETUP_VERSION} 到 .local/tools/innosetup（仅 Windows，生成安装包用）",
    )
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="仓库根目录（默认取脚本所在仓库）")
    args = parser.parse_args(argv)
    if args.check and args.innosetup:
        parser.error("--innosetup 只用于安装，不能与 --check 同用")
    root = Path(args.root).resolve()
    if args.check:
        return doctor(root, os.environ)
    return setup(root, os.environ, force=args.force, innosetup=args.innosetup)


if __name__ == "__main__":
    raise SystemExit(main())
