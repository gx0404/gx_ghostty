#!/usr/bin/env python3
"""钉版 Zig 工具链：把 Zig 0.16.0 装进仓库内 .local/，不写任何用户全局状态。

安装位置：<repo>/.local/toolchains/zig/zig-0.16.0/（gitignored）。设置
GX_GHOSTTY_ZIG_HOME 可把安装根整体改到别处（多 worktree 共享或测试）。
scripts/zigw.py 按 $GX_GHOSTTY_ZIG > $ZIG > 本钉版目录 > PATH 解析 Zig。

模式：
  默认 / --check  只读诊断：钉版已装且 `zig version` 正确退出 0，否则退出 1。
  --install       下载官方包（sha256 钉版）、校验后原子落位；已装且有效则跳过（幂等）。
  --force         覆盖重装已存在（损坏）的钉版目录，隐含 --install。
安装失败退出 2。

下载源顺序：$GX_GHOSTTY_ZIG_MIRROR > https://pkg.machengine.org/zig/ > 官方
https://ziglang.org/download/0.16.0/。每个源都按同一 sha256 校验；下载速度跌破
速率地板或校验不符即切换下一个源。
"""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Mapping

REPO_ROOT = Path(__file__).resolve().parents[1]
ZIG_VERSION = "0.16.0"
INSTALL_DIR_NAME = f"zig-{ZIG_VERSION}"
HOME_ENV = "GX_GHOSTTY_ZIG_HOME"
MIRROR_ENV = "GX_GHOSTTY_ZIG_MIRROR"
# 官方 index.json 的 sha256 钉版（2026-09 获取，与 herdr 同一组值）。
PINS: dict[str, dict[str, str]] = {
    "x86_64-linux": {
        "tarball": f"zig-x86_64-linux-{ZIG_VERSION}.tar.xz",
        "sha256": "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
    },
    "aarch64-linux": {
        "tarball": f"zig-aarch64-linux-{ZIG_VERSION}.tar.xz",
        "sha256": "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
    },
    "x86_64-macos": {
        "tarball": f"zig-x86_64-macos-{ZIG_VERSION}.tar.xz",
        "sha256": "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7",
    },
    "aarch64-macos": {
        "tarball": f"zig-aarch64-macos-{ZIG_VERSION}.tar.xz",
        "sha256": "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
    },
    "x86_64-windows": {
        "tarball": f"zig-x86_64-windows-{ZIG_VERSION}.zip",
        "sha256": "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e",
    },
}
DOWNLOAD_BASE = f"https://ziglang.org/download/{ZIG_VERSION}/"
# 社区镜像按 <base><文件名> 布局提供官方包。国内网络下官方源常被限速，所以镜像
# 优先、官方兜底；来源可信度由 sha256 钉版保证，与下载源无关。
MIRROR_BASES = ("https://pkg.machengine.org/zig/",)
# 速率地板：前 8 秒内至少 512KB；此后自开始以来的平均速率至少 100KB/s，否则换源。
# 不设绝对时限，慢而稳定的源也能下完。
SPEED_FLOOR_BYTES = 512 * 1024
SPEED_PROBE_SECONDS = 8
MIN_SUSTAINED_RATE_BYTES_PER_SEC = 100 * 1024
PROGRESS_INTERVAL_SECONDS = 3
CHUNK_BYTES = 1 << 16
_MACHINES = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "x64": "x86_64",
    "arm64": "aarch64",
    "aarch64": "aarch64",
}
_SYSTEMS = {"linux": "linux", "darwin": "macos", "macos": "macos", "windows": "windows"}


class SetupZigError(RuntimeError):
    """安装前置不满足、下载失败或校验失败。"""


def _environ(env: Mapping[str, str] | None) -> Mapping[str, str]:
    return os.environ if env is None else env


def utf8_stdio() -> None:
    """Windows 控制台或管道默认编码可能打不出中文；CLI 入口统一改成 UTF-8。"""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            pass


def download_bases(env: Mapping[str, str] | None = None) -> list[str]:
    """下载源顺序：GX_GHOSTTY_ZIG_MIRROR 自定义源 → 内置镜像 → 官方。"""
    bases: list[str] = []
    custom = _environ(env).get(MIRROR_ENV, "").strip()
    if custom:
        bases.append(custom.rstrip("/") + "/")
    bases.extend(MIRROR_BASES)
    bases.append(DOWNLOAD_BASE)
    return list(dict.fromkeys(bases))


def platform_key(system: str | None = None, machine: str | None = None) -> str:
    system = (platform.system() if system is None else system).lower()
    machine = (platform.machine() if machine is None else machine).lower()
    key = f"{_MACHINES.get(machine, machine)}-{_SYSTEMS.get(system, system)}"
    if key not in PINS:
        raise SetupZigError(
            f"平台 {key} 没有钉版条目；请手动安装 Zig {ZIG_VERSION}，再用 GX_GHOSTTY_ZIG 指向它"
        )
    return key


def install_root(env: Mapping[str, str] | None = None, root: Path | None = None) -> Path:
    override = _environ(env).get(HOME_ENV, "").strip()
    if override:
        return Path(override).expanduser()
    return (REPO_ROOT if root is None else Path(root)) / ".local" / "toolchains" / "zig"


def install_dir(env: Mapping[str, str] | None = None, root: Path | None = None) -> Path:
    return install_root(env, root) / INSTALL_DIR_NAME


def zig_binary(env: Mapping[str, str] | None = None, root: Path | None = None) -> Path:
    """钉版 zig 可执行文件路径；Windows 官方包是 zig.exe，兼容手工布局里无后缀的 zig。"""
    directory = install_dir(env, root)
    names = ("zig.exe", "zig") if os.name == "nt" else ("zig",)
    for name in names:
        candidate = directory / name
        if candidate.is_file():
            return candidate
    return directory / names[0]


def which_on_path(name: str, path_value: str | None) -> str | None:
    """只在 PATH 列出的目录里找可执行文件（不像 Windows 默认那样先搜当前目录）。"""
    for entry in (path_value or "").split(os.pathsep):
        entry = entry.strip().strip('"')
        if not entry:
            continue
        found = shutil.which(os.path.join(entry, name))
        if found:
            return os.path.abspath(found)
    return None


def run_zig_version(binary: Path | str, env: Mapping[str, str] | None = None) -> str | None:
    """运行 `<zig> version`，返回去空白的输出；无法运行或退出码非 0 时返回 None。"""
    try:
        result = subprocess.run(
            [str(binary), "version"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdin=subprocess.DEVNULL,
            env=None if env is None else dict(env),
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def check(env: Mapping[str, str] | None = None, root: Path | None = None) -> int:
    platform_key()
    binary = zig_binary(env, root)
    healthy = False
    if binary.is_file():
        version = run_zig_version(binary)
        if version == ZIG_VERSION:
            healthy = True
            print(f"[setup-zig] INSTALLED {binary}（zig version {version}）")
        else:
            print(
                f"[setup-zig] BROKEN {binary}（zig version {version or '无法运行'}，期望 {ZIG_VERSION}）；"
                "覆盖重装：python scripts/setup_zig.py --force"
            )
    else:
        print(f"[setup-zig] MISSING {binary}；安装：just setup（或 python scripts/setup_zig.py --install）")
    on_path = which_on_path("zig", _environ(env).get("PATH"))
    if on_path:
        print(f"[setup-zig] PATH zig：{on_path}（zig version {run_zig_version(on_path) or '无法运行'}）")
    else:
        print("[setup-zig] PATH zig：无")
    return 0 if healthy else 1


def too_slow(downloaded: int, elapsed: float) -> bool:
    """速率地板：探测窗口内不判；之后总量低于 512KB 或平均速率低于 100KB/s 即判慢。"""
    if elapsed <= SPEED_PROBE_SECONDS:
        return False
    return downloaded < SPEED_FLOOR_BYTES or downloaded < MIN_SUSTAINED_RATE_BYTES_PER_SEC * elapsed


def _download_one(url: str, destination: Path) -> None:
    print(f"[setup-zig] 下载 {url}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": f"gx-ghostty-setup-zig/{ZIG_VERSION}"})
    start = last_report = time.monotonic()
    downloaded = 0
    total: int | None = None
    try:
        with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as handle:
            length = response.headers.get("Content-Length")
            if length and length.isdigit():
                total = int(length)
            while True:
                chunk = response.read(CHUNK_BYTES)
                if not chunk:
                    break
                handle.write(chunk)
                downloaded += len(chunk)
                now = time.monotonic()
                elapsed = now - start
                rate = downloaded / 1024 / max(elapsed, 0.001)
                if now - last_report >= PROGRESS_INTERVAL_SECONDS:
                    size = f"{downloaded / 1048576:.1f}MB"
                    if total is not None:
                        size += f"/{total / 1048576:.1f}MB"
                    print(f"[setup-zig]   {size}（{rate:.0f}KB/s）", flush=True)
                    last_report = now
                if too_slow(downloaded, elapsed):
                    raise SetupZigError(f"源速度过低（{rate:.0f}KB/s），切换下一个源")
    except urllib.error.HTTPError as exc:
        raise SetupZigError(f"HTTP {exc.code}") from exc
    except (urllib.error.URLError, OSError) as exc:
        raise SetupZigError(f"网络失败：{exc}") from exc
    if total is not None and downloaded != total:
        raise SetupZigError(f"下载不完整：{downloaded}/{total} 字节")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_verified(pin: Mapping[str, str], destination: Path, env: Mapping[str, str] | None = None) -> str:
    """按源顺序下载并做 sha256 校验；返回成功的 URL。某个源失败或校验不符就换下一个。"""
    errors: list[str] = []
    for base in download_bases(env):
        url = base + pin["tarball"]
        destination.unlink(missing_ok=True)
        try:
            _download_one(url, destination)
        except SetupZigError as exc:
            print(f"[setup-zig] {exc}", flush=True)
            errors.append(f"{url}：{exc}")
            continue
        digest = sha256_file(destination)
        if digest == pin["sha256"]:
            return url
        message = f"sha256 不符（{digest} != {pin['sha256']}），切换下一个源"
        print(f"[setup-zig] {message}", flush=True)
        errors.append(f"{url}：{message}")
    destination.unlink(missing_ok=True)
    raise SetupZigError("所有下载源都失败：\n  " + "\n  ".join(errors))


def archive_stem(tarball: str) -> str:
    for suffix in (".tar.xz", ".zip"):
        if tarball.endswith(suffix):
            return tarball[: -len(suffix)]
    raise SetupZigError(f"不支持的归档格式：{tarball}")


def _extract_with_system_tar(archive: Path, dest: Path) -> None:
    tar = shutil.which("tar")
    if not tar:
        raise SetupZigError("当前 Python 缺少 lzma 模块且找不到系统 tar，无法解压 .tar.xz")
    result = subprocess.run(
        [tar, "-xJf", str(archive), "-C", str(dest)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.returncode != 0:
        raise SetupZigError(f"tar 解压失败：{result.stderr.strip()}")


def extract_archive(archive: Path, dest: Path) -> None:
    """.zip 一律用 zipfile；.tar.xz 用 tarfile，仅当 Python 缺 lzma 时退回系统 `tar -xJf`。"""
    name = archive.name
    if name.endswith(".zip"):
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(dest)
        return
    if name.endswith(".tar.xz"):
        try:
            import lzma  # noqa: F401
        except ImportError:
            _extract_with_system_tar(archive, dest)
            return
        with tarfile.open(archive, "r:xz") as bundle:
            if hasattr(tarfile, "data_filter"):
                bundle.extractall(dest, filter="data")
            else:
                bundle.extractall(dest)
        return
    raise SetupZigError(f"不支持的归档格式：{name}")


def _rename_with_retry(source: Path, target: Path) -> None:
    # Windows 上杀毒软件可能短暂占用刚解压的文件，目录改名偶发 PermissionError。
    for attempt in range(5):
        try:
            source.rename(target)
            return
        except PermissionError:
            if attempt == 4:
                raise
            time.sleep(1)


def install(force: bool = False, env: Mapping[str, str] | None = None, root: Path | None = None) -> int:
    key = platform_key()
    pin = PINS[key]
    target = install_dir(env, root)
    if target.exists() and not force:
        binary = zig_binary(env, root)
        if binary.is_file():
            version = run_zig_version(binary)
            if version == ZIG_VERSION:
                print(f"[setup-zig] 已安装且有效，跳过：{binary}（zig version {version}）")
                return 0
            raise SetupZigError(
                f"{target} 已存在但 zig version 为 {version or '无法运行'}（期望 {ZIG_VERSION}）；"
                "覆盖重装：python scripts/setup_zig.py --force"
            )
        raise SetupZigError(f"{target} 已存在但缺少 zig 可执行文件；覆盖重装：python scripts/setup_zig.py --force")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".setup-zig-", dir=target.parent, ignore_cleanup_errors=True) as tmp_name:
        tmp = Path(tmp_name)
        archive = tmp / pin["tarball"]
        fetch_verified(pin, archive, env)
        print("[setup-zig] sha256 校验通过，解压中", flush=True)
        extract_archive(archive, tmp)
        extracted = tmp / archive_stem(pin["tarball"])
        executable = extracted / ("zig.exe" if key.endswith("-windows") else "zig")
        if not executable.is_file():
            raise SetupZigError(f"归档结构异常：缺少 {executable.relative_to(tmp)}")
        if target.exists():
            shutil.rmtree(target)
        _rename_with_retry(extracted, target)
    binary = zig_binary(env, root)
    version = run_zig_version(binary)
    if version != ZIG_VERSION:
        raise SetupZigError(f"安装后 zig version 为 {version or '无法运行'}，期望 {ZIG_VERSION}")
    print(f"[setup-zig] 已安装 {binary}（zig version {version}）")
    return 0


def main(argv: list[str] | None = None) -> int:
    utf8_stdio()
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog=__doc__.split("\n", 2)[2],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="只读诊断（默认行为）")
    mode.add_argument("--install", action="store_true", help="下载并安装钉版 Zig；已装且有效则跳过")
    parser.add_argument("--force", action="store_true", help="覆盖重装已存在的钉版目录（隐含 --install）")
    args = parser.parse_args(argv)
    if args.check and args.force:
        parser.error("--force 不能与 --check 同用")
    try:
        if args.install or args.force:
            return install(force=args.force)
        return check()
    except SetupZigError as exc:
        print(f"[setup-zig] error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
