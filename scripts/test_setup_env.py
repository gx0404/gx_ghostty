#!/usr/bin/env python3
"""scripts/setup_env.py 测试：--check 只读、WindowsApps 别名跳过、体检状态判定与 venv 安装命令。"""

from __future__ import annotations

import errno
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import setup_env  # noqa: E402
import setup_zig  # noqa: E402
import zigw  # noqa: E402

SCRIPT = SCRIPTS / "setup_env.py"
ALIAS = r"C:\Users\dev\AppData\Local\Microsoft\WindowsApps\python3.exe"
REAL = r"C:\Users\dev\AppData\Local\Python\pythoncore-3.14-64\python.exe"


class FakeRunner:
    """按命令首个匹配片段返回预设结果，并记录全部调用。"""

    def __init__(self, responses: dict[str, tuple[int, str]] | None = None) -> None:
        self.responses = responses or {}
        self.calls: list[list[str]] = []

    def __call__(self, command, **kwargs):
        command = [str(part) for part in command]
        self.calls.append(command)
        joined = " ".join(command)
        for needle, (code, stdout) in self.responses.items():
            if needle in joined:
                return subprocess.CompletedProcess(command, code, stdout, "")
        return subprocess.CompletedProcess(command, 0, "", "")


class CheckModeTests(unittest.TestCase):
    def test_check_creates_nothing_and_fails_on_missing_required(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            root.mkdir()
            zig_home = Path(tmp) / "zig-home"
            env = {key: value for key, value in os.environ.items() if key not in ("GX_GHOSTTY_ZIG", "ZIG")}
            env.update(
                {
                    setup_zig.HOME_ENV: str(zig_home),
                    "PYTHONDONTWRITEBYTECODE": "1",
                    "PYTHONIOENCODING": "utf-8",
                }
            )
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--check", "--root", str(root)],
                capture_output=True,
                text=True,
                encoding="utf-8",
                env=env,
                check=False,
            )
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("MISSING", result.stdout)
            self.assertIn("graphify", result.stdout)
            for name in ("zig", "python", "git", "venv", "hooksPath", *setup_env.OPTIONAL_CLIS):
                self.assertIn(name, result.stdout)
            symlink_rows = [line for line in result.stdout.splitlines() if re.match(r"^\S+\s+symlink\s", line)]
            innosetup_rows = [line for line in result.stdout.splitlines() if re.match(r"^\S+\s+innosetup\s", line)]
            if os.name == "nt":
                self.assertEqual(1, len(symlink_rows), result.stdout)
                self.assertRegex(symlink_rows[0], r"^(FOUND|OPTIONAL)\s")
                self.assertEqual(1, len(innosetup_rows), result.stdout)
                self.assertRegex(innosetup_rows[0], r"^OPTIONAL\s.*just setup --innosetup")
            else:
                self.assertEqual([], symlink_rows)
                self.assertEqual([], innosetup_rows)
            self.assertEqual([], list(root.iterdir()), "--check 不得在仓库里建任何东西")
            self.assertFalse(zig_home.exists(), "--check 不得创建 Zig 安装根")


class PythonDetectionTests(unittest.TestCase):
    def test_windows_apps_alias_detection(self) -> None:
        for path in (
            ALIAS,
            "C:/Users/dev/AppData/Local/Microsoft/windowsapps/python.exe",
            r"C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_x64__qbz5n2kfra8p0\python.exe",
        ):
            with self.subTest(path=path):
                self.assertTrue(setup_env.is_windows_apps_alias(path))
        for path in (REAL, "/usr/bin/python3", "/home/dev/windowsappsx/python3"):
            with self.subTest(path=path):
                self.assertFalse(setup_env.is_windows_apps_alias(path))

    def test_skips_alias_without_probing_it(self) -> None:
        probed: list[str] = []

        def probe(candidate: str) -> str | None:
            probed.append(candidate)
            return candidate

        self.assertEqual(REAL, setup_env.find_real_python([ALIAS, REAL], probe))
        self.assertEqual([REAL], probed)

    def test_rejects_candidates_that_resolve_into_windows_apps(self) -> None:
        def probe(candidate: str) -> str | None:
            return ALIAS if candidate == "python-shim" else candidate

        self.assertEqual("/usr/bin/python3", setup_env.find_real_python(["python-shim", "/usr/bin/python3"], probe))

    def test_returns_none_when_nothing_runs(self) -> None:
        self.assertIsNone(setup_env.find_real_python([ALIAS, "/missing/python"], lambda candidate: None))

    def test_default_candidates_start_with_current_interpreter(self) -> None:
        self.assertEqual(sys.executable, setup_env.python_candidates({"PATH": ""})[0])
        real = setup_env.find_real_python()
        self.assertIsNotNone(real)
        self.assertFalse(setup_env.is_windows_apps_alias(real or ""))


class StatusTests(unittest.TestCase):
    def test_exit_code_only_counts_required_missing(self) -> None:
        Item = setup_env.Item
        ok = [Item("zig", "FOUND", "", True), Item("uv", "OPTIONAL", "", False)]
        self.assertEqual(0, setup_env.exit_code(ok))
        self.assertEqual(0, setup_env.exit_code([*ok, Item("hooksPath", "OPTIONAL", "", False)]))
        self.assertEqual(1, setup_env.exit_code([*ok, Item("graphify", "MISSING", "", True)]))

    def test_render_lists_every_item(self) -> None:
        items = [setup_env.Item("zig", "FOUND", "0.16.0", True), setup_env.Item("codex", "OPTIONAL", "未安装（可选）", False)]
        table = setup_env.render(items).splitlines()
        self.assertEqual(3, len(table))
        self.assertTrue(table[1].startswith("FOUND"))
        self.assertTrue(table[2].startswith("OPTIONAL"))

    def test_optional_clis_are_never_missing(self) -> None:
        items = setup_env.check_optional_clis(lambda name: "/opt/bin/uv" if name == "uv" else None)
        self.assertEqual(list(setup_env.OPTIONAL_CLIS), [item.name for item in items])
        self.assertEqual({"FOUND", "OPTIONAL"}, {item.status for item in items})
        self.assertFalse(any(item.required for item in items))
        self.assertEqual("FOUND", next(item for item in items if item.name == "uv").status)

    def test_zig_row_follows_zigw(self) -> None:
        with mock.patch.object(zigw, "require_zig", return_value=zigw.ResolvedZig("/r/zig", "pinned")):
            item = setup_env.check_zig({}, ROOT)
        self.assertEqual(("FOUND", True), (item.status, item.required))
        self.assertIn("钉版", item.detail)
        with mock.patch.object(zigw, "require_zig", return_value=zigw.ResolvedZig("/x/zig", "ZIG")):
            self.assertIn("$ZIG", setup_env.check_zig({}, ROOT).detail)
        with mock.patch.object(zigw, "require_zig", side_effect=zigw.ZigwError("找不到 Zig；运行 just setup")):
            item = setup_env.check_zig({}, ROOT)
        self.assertEqual(("MISSING", True), (item.status, item.required))

    def test_python_and_git_rows(self) -> None:
        self.assertEqual("MISSING", setup_env.check_python(lambda: None).status)
        self.assertEqual("FOUND", setup_env.check_python(lambda: sys.executable).status)
        self.assertEqual("MISSING", setup_env.check_git(lambda name: None).status)
        runner = FakeRunner({"--version": (0, "git version 2.50.0")})
        self.assertEqual("FOUND", setup_env.check_git(lambda name: "/usr/bin/git", runner).status)

    def test_hooks_path_is_optional(self) -> None:
        found = setup_env.check_hooks(ROOT, lambda name: "git", FakeRunner({"core.hooksPath": (0, ".githooks\n")}))
        self.assertEqual(("FOUND", False), (found.status, found.required))
        unset = setup_env.check_hooks(ROOT, lambda name: "git", FakeRunner({"core.hooksPath": (1, "")}))
        self.assertEqual(("OPTIONAL", False), (unset.status, unset.required))
        self.assertIn("just install-hooks", unset.detail)
        other = setup_env.check_hooks(ROOT, lambda name: "git", FakeRunner({"core.hooksPath": (0, ".husky\n")}))
        self.assertEqual("OPTIONAL", other.status)


class MsvcTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.program_files = Path(self._tmp.name)
        self.env = {"PROGRAMFILES(X86)": str(self.program_files)}

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _vswhere(self) -> Path:
        path = self.program_files / setup_env.VSWHERE_RELATIVE
        path.parent.mkdir(parents=True)
        path.write_bytes(b"")
        return path

    def test_skipped_off_windows(self) -> None:
        self.assertIsNone(setup_env.check_msvc(self.env, FakeRunner(), is_windows=False))

    def test_missing_vswhere(self) -> None:
        item = setup_env.check_msvc(self.env, FakeRunner(), is_windows=True)
        self.assertEqual(("MISSING", True), (item.status, item.required))

    def test_found_with_vc_tools_component(self) -> None:
        self._vswhere()
        payload = json.dumps(
            [{"displayName": "Visual Studio 生成工具 2022", "installationVersion": "17.14.37710.0", "installationPath": r"C:\BuildTools"}]
        )
        runner = FakeRunner({"vswhere": (0, payload)})
        item = setup_env.check_msvc(self.env, runner, is_windows=True)
        self.assertEqual(("FOUND", True), (item.status, item.required))
        self.assertIn("17.14", item.detail)
        command = runner.calls[0]
        self.assertIn(setup_env.VC_TOOLS_COMPONENT, command)
        self.assertEqual("*", command[command.index("-products") + 1])

    def test_missing_vc_tools_component(self) -> None:
        self._vswhere()
        item = setup_env.check_msvc(self.env, FakeRunner({"vswhere": (0, "[]")}), is_windows=True)
        self.assertEqual("MISSING", item.status)

    def test_default_vswhere_location(self) -> None:
        expected = Path(r"C:\Program Files (x86)") / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
        self.assertEqual(expected, setup_env.vswhere_path({}))


def _unexpected_symlink(target: str, link: str) -> None:
    raise AssertionError("不应试建符号链接")


def _privilege_not_held(target: str, link: str) -> None:
    # What os.symlink raises on Windows without Developer Mode: [WinError 1314], errno EINVAL.
    error = OSError(errno.EINVAL, "A required privilege is not held by the client")
    error.winerror = setup_env.ERROR_PRIVILEGE_NOT_HELD
    raise error


class SymlinkTests(unittest.TestCase):
    def test_skipped_off_windows(self) -> None:
        self.assertIsNone(setup_env.check_symlink(is_windows=False, symlink=_unexpected_symlink))

    def test_found_when_a_link_can_be_created_outside_the_repo(self) -> None:
        calls: list[tuple[str, str]] = []
        item = setup_env.check_symlink(is_windows=True, symlink=lambda target, link: calls.append((target, link)))
        self.assertEqual(("symlink", "FOUND", "可创建符号链接", False), tuple(item))
        self.assertEqual(1, len(calls))
        link = Path(calls[0][1])
        self.assertFalse(link.resolve().is_relative_to(ROOT.resolve()), "试建位置必须在仓库外")
        self.assertFalse(link.parent.exists(), "试建用的临时目录用后即删")

    def test_privilege_not_held_is_optional_with_developer_mode_hint(self) -> None:
        item = setup_env.check_symlink(is_windows=True, symlink=_privilege_not_held)
        self.assertEqual(("OPTIONAL", False), (item.status, item.required))
        self.assertEqual(setup_env.SYMLINK_PRIVILEGE_HINT, item.detail)
        self.assertIn("开发者模式", item.detail)
        self.assertIn("PermissionDenied", item.detail)
        self.assertEqual(0, setup_env.exit_code([item]))

    def test_other_failures_are_optional_too(self) -> None:
        def unsupported(target: str, link: str) -> None:
            raise OSError(errno.EINVAL, "reparse points unsupported")

        item = setup_env.check_symlink(is_windows=True, symlink=unsupported)
        self.assertEqual(("OPTIONAL", False), (item.status, item.required))
        self.assertIn("reparse points unsupported", item.detail)

    def test_collect_lists_symlink_after_hooks_path_and_never_requires_it(self) -> None:
        Item = setup_env.Item
        stubs = {
            "check_zig": lambda env, root: Item("zig", "FOUND", "", True),
            "check_python": lambda: Item("python", "FOUND", "", True),
            "check_git": lambda: Item("git", "FOUND", "", True),
            "check_msvc": lambda env: None,
            "check_venv": lambda root: [],
            "check_hooks": lambda root: Item("hooksPath", "OPTIONAL", "", False),
            "check_optional_clis": lambda: [Item("uv", "OPTIONAL", "", False)],
        }
        hint = Item("symlink", "OPTIONAL", setup_env.SYMLINK_PRIVILEGE_HINT, False)
        inno = Item("innosetup", "OPTIONAL", "未安装", False)
        with mock.patch.multiple(setup_env, check_symlink=lambda: hint, check_innosetup=lambda root: inno, **stubs):
            items = setup_env.collect(ROOT, {})
        self.assertEqual(["zig", "python", "git", "hooksPath", "symlink", "innosetup", "uv"], [item.name for item in items])
        self.assertEqual(0, setup_env.exit_code(items))
        with mock.patch.multiple(setup_env, check_symlink=lambda: None, check_innosetup=lambda root: None, **stubs):
            names = [item.name for item in setup_env.collect(ROOT, {})]
        self.assertNotIn("symlink", names)
        self.assertNotIn("innosetup", names)


class InnoSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def install_files(self, marker: str | None = None) -> None:
        iscc = setup_env.iscc_path(self.root)
        iscc.parent.mkdir(parents=True, exist_ok=True)
        iscc.write_bytes(b"MZ")
        setup_env.innosetup_marker(self.root).write_text(
            marker or f"{setup_env.INNOSETUP_VERSION} {setup_env.INNOSETUP_SHA256}\n", encoding="utf-8")

    def test_pin_is_the_gx_shell_release_pin(self) -> None:
        self.assertEqual("7.1.0", setup_env.INNOSETUP_VERSION)
        self.assertEqual(
            "https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe", setup_env.INNOSETUP_URL
        )
        self.assertEqual("0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f", setup_env.INNOSETUP_SHA256)
        self.assertEqual(self.root / ".local" / "tools" / "innosetup" / "ISCC.exe", setup_env.iscc_path(self.root))

    def test_doctor_row(self) -> None:
        self.assertIsNone(setup_env.check_innosetup(self.root, is_windows=False))
        missing = setup_env.check_innosetup(self.root, is_windows=True)
        self.assertEqual(("OPTIONAL", False), (missing.status, missing.required))
        self.assertIn(setup_env.INNOSETUP_HINT, missing.detail)
        self.install_files(marker="6.4.0 deadbeef\n")
        stale = setup_env.check_innosetup(self.root, is_windows=True)
        self.assertEqual("OPTIONAL", stale.status)
        self.assertIn("删除该目录", stale.detail)
        self.install_files()
        found = setup_env.check_innosetup(self.root, is_windows=True)
        self.assertEqual(("FOUND", False), (found.status, found.required))
        self.assertIn("7.1.0", found.detail)
        self.assertEqual(0, setup_env.exit_code([missing, stale, found]))

    def test_installs_portably_for_the_current_user(self) -> None:
        downloads: list[tuple[str, Path, str]] = []

        def download(url: str, destination: Path, sha256: str) -> None:
            downloads.append((url, destination, sha256))
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"installer")

        def runner(command, **kwargs):
            target = Path(next(arg for arg in command if arg.startswith("/DIR="))[5:])
            (target / "ISCC.exe").parent.mkdir(parents=True, exist_ok=True)
            (target / "ISCC.exe").write_bytes(b"MZ")
            return subprocess.CompletedProcess(command, 0)

        calls = []
        with redirect_stdout(io.StringIO()):
            setup_env.ensure_innosetup(
                self.root, runner=lambda command, **kwargs: calls.append(command) or runner(command), download=download, is_windows=True
            )
        self.assertEqual([(setup_env.INNOSETUP_URL, self.root / ".local/cache/innosetup/innosetup-7.1.0-x64.exe", setup_env.INNOSETUP_SHA256)], downloads)
        command = calls[0]
        for flag in ("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/PORTABLE=1", f"/DIR={setup_env.innosetup_dir(self.root)}"):
            self.assertIn(flag, command)
        self.assertTrue(setup_env.innosetup_ready(self.root))
        with redirect_stdout(io.StringIO()) as out:
            setup_env.ensure_innosetup(self.root, runner=runner, download=download, is_windows=True)
        self.assertIn("跳过", out.getvalue())
        self.assertEqual(1, len(downloads))

    def test_install_failures(self) -> None:
        def download(url: str, destination: Path, sha256: str) -> None:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"installer")

        with self.assertRaisesRegex(setup_env.SetupEnvError, "非 Windows"):
            setup_env.ensure_innosetup(self.root, download=download, is_windows=False)
        with redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(setup_env.SetupEnvError, "退出码 5"):
                setup_env.ensure_innosetup(
                    self.root, runner=lambda command, **kwargs: subprocess.CompletedProcess(command, 5), download=download, is_windows=True
                )
            with self.assertRaisesRegex(setup_env.SetupEnvError, "ISCC.exe"):
                setup_env.ensure_innosetup(
                    self.root, runner=lambda command, **kwargs: subprocess.CompletedProcess(command, 0), download=download, is_windows=True
                )
        setup_env.innosetup_dir(self.root).mkdir(parents=True)
        with self.assertRaisesRegex(setup_env.SetupEnvError, "删除该目录"):
            setup_env.ensure_innosetup(self.root, download=download, is_windows=True)

    def test_download_is_verified_and_discarded_on_mismatch(self) -> None:
        payload = b"inno setup installer"
        digest = hashlib.sha256(payload).hexdigest()
        destination = self.root / "cache" / "installer.exe"
        opened = []

        def urlopen(request, timeout=None):
            opened.append(request.full_url)
            return io.BytesIO(payload)

        with self.assertRaisesRegex(setup_env.SetupEnvError, "sha256 不符"):
            setup_env.download_verified("https://example.invalid/x.exe", destination, "0" * 64, urlopen=urlopen)
        self.assertEqual([], list(destination.parent.iterdir()))
        setup_env.download_verified("https://example.invalid/x.exe", destination, digest, urlopen=urlopen)
        self.assertEqual(payload, destination.read_bytes())
        setup_env.download_verified("https://example.invalid/x.exe", destination, digest, urlopen=urlopen)
        self.assertEqual(2, len(opened))

    def test_setup_flag_and_check_conflict(self) -> None:
        with mock.patch.object(setup_env, "ensure_zig"), mock.patch.object(setup_env, "ensure_venv"), mock.patch.object(
            setup_env, "ensure_innosetup", side_effect=setup_env.SetupEnvError("下载失败")
        ) as ensure, redirect_stdout(io.StringIO()) as out, mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            self.assertEqual(1, setup_env.setup(self.root, {}, innosetup=True))
            self.assertEqual(0, setup_env.setup(self.root, {}))
        ensure.assert_called_once_with(self.root)
        self.assertIn("3/3", out.getvalue())
        self.assertIn("innosetup", err.getvalue())
        with mock.patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit) as raised:
            setup_env.main(["--check", "--innosetup"])
        self.assertEqual(2, raised.exception.code)


class VenvTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.venv = setup_env.venv_dir(self.root)
        self.python = setup_env.venv_executable(self.venv, "python")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _fake_venv(self, *, cli: bool = True) -> None:
        self.python.parent.mkdir(parents=True)
        self.python.write_bytes(b"")
        if cli:
            setup_env.venv_executable(self.venv, "graphify").write_bytes(b"")

    def test_layout(self) -> None:
        self.assertEqual(self.root / ".local" / "tools" / "venv", self.venv)
        expected = self.venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
        self.assertEqual(expected, self.python)

    def test_rows_when_venv_missing(self) -> None:
        items = setup_env.check_venv(self.root, FakeRunner())
        self.assertEqual([("venv", "MISSING"), ("graphify", "MISSING")], [(i.name, i.status) for i in items])

    def test_rows_with_pinned_graphify(self) -> None:
        self._fake_venv()
        runner = FakeRunner({"importlib.metadata": (0, "0.9.73\n"), "-m graphify --version": (0, "graphify 0.9.73\n")})
        items = setup_env.check_venv(self.root, runner)
        self.assertEqual([("venv", "FOUND"), ("graphify", "FOUND")], [(i.name, i.status) for i in items])
        self.assertIn([str(self.python), "-m", "graphify", "--version"], runner.calls)

    def test_installed_but_unrunnable_graphify_is_missing(self) -> None:
        # Windows 应用控制拦截时：元数据显示已安装，但按 graphify.py 的方式运行失败。
        self._fake_venv()
        runner = FakeRunner({"importlib.metadata": (0, "0.9.73\n"), "-m graphify --version": (1, "")})
        items = setup_env.check_venv(self.root, runner)
        self.assertEqual("MISSING", items[1].status)
        self.assertIn("无法运行", items[1].detail)

    def test_rows_with_wrong_graphify_version(self) -> None:
        self._fake_venv()
        items = setup_env.check_venv(self.root, FakeRunner({"importlib.metadata": (0, "0.9.20\n")}))
        self.assertEqual("MISSING", items[1].status)
        self.assertIn("0.9.20", items[1].detail)

    def test_commands_with_uv(self) -> None:
        commands = setup_env.venv_commands(self.venv, REAL, "uv", recreate=True, exists=False)
        self.assertEqual(
            [
                ["uv", "venv", "--python", REAL, str(self.venv)],
                ["uv", "pip", "install", "--python", str(self.python), "graphifyy==0.9.73"],
            ],
            commands,
        )

    def test_commands_without_uv(self) -> None:
        commands = setup_env.venv_commands(self.venv, REAL, None, recreate=True, exists=False)
        self.assertEqual(
            [
                [REAL, "-m", "venv", str(self.venv)],
                [str(self.python), "-m", "pip", "install", "--disable-pip-version-check", "graphifyy==0.9.73"],
            ],
            commands,
        )

    def test_broken_existing_venv_is_cleared(self) -> None:
        commands = setup_env.venv_commands(self.venv, REAL, "uv", recreate=True, exists=True)
        self.assertEqual(["uv", "venv", "--python", REAL, "--clear", str(self.venv)], commands[0])
        healthy = setup_env.venv_commands(self.venv, REAL, "uv", recreate=False, exists=True)
        self.assertEqual(1, len(healthy))

    def test_ensure_venv_skips_when_ready(self) -> None:
        runner = FakeRunner()
        with redirect_stdout(io.StringIO()):
            setup_env.ensure_venv(self.root, which=lambda name: "uv", runner=runner, find_python=lambda: REAL, ready=lambda venv: True)
        self.assertEqual([], runner.calls)

    def test_ensure_venv_creates_with_uv_and_real_python(self) -> None:
        runner = FakeRunner()
        states = iter([False, True])
        with redirect_stdout(io.StringIO()):
            setup_env.ensure_venv(
                self.root,
                which=lambda name: "uv" if name == "uv" else None,
                runner=runner,
                find_python=lambda: REAL,
                ready=lambda venv: next(states),
            )
        self.assertEqual(
            [
                ["uv", "venv", "--python", REAL, str(self.venv)],
                ["uv", "pip", "install", "--python", str(self.python), "graphifyy==0.9.73"],
            ],
            runner.calls,
        )

    def test_ensure_venv_without_python_fails(self) -> None:
        with self.assertRaises(setup_env.SetupEnvError):
            setup_env.ensure_venv(self.root, which=lambda name: None, runner=FakeRunner(), find_python=lambda: None, ready=lambda venv: False)

    def test_ensure_venv_reports_failed_command(self) -> None:
        runner = FakeRunner({"pip install": (1, "")})
        with redirect_stdout(io.StringIO()), self.assertRaises(setup_env.SetupEnvError):
            setup_env.ensure_venv(self.root, which=lambda name: "uv", runner=runner, find_python=lambda: REAL, ready=lambda venv: False)


class EnsureZigTests(unittest.TestCase):
    def test_valid_env_override_skips_download(self) -> None:
        with mock.patch.object(zigw, "require_zig", return_value=zigw.ResolvedZig("/opt/zig/zig", "ZIG")), mock.patch.object(
            setup_zig, "install", side_effect=AssertionError("不应下载钉版")
        ), redirect_stdout(io.StringIO()) as out:
            setup_env.ensure_zig({"ZIG": "/opt/zig/zig"}, ROOT)
        self.assertIn("跳过", out.getvalue())

    def test_installs_pinned_without_override(self) -> None:
        with mock.patch.object(setup_zig, "install", return_value=0) as install:
            setup_env.ensure_zig({}, ROOT)
        install.assert_called_once_with(force=False, env={}, root=ROOT)

    def test_broken_override_still_installs_pinned(self) -> None:
        with mock.patch.object(zigw, "require_zig", side_effect=zigw.ZigwError("$ZIG 不可用")), mock.patch.object(
            setup_zig, "install", return_value=0
        ) as install, redirect_stdout(io.StringIO()):
            setup_env.ensure_zig({"ZIG": "/bad"}, ROOT)
        install.assert_called_once()

    def test_install_failure_becomes_setup_error(self) -> None:
        with mock.patch.object(setup_zig, "install", side_effect=setup_zig.SetupZigError("所有下载源都失败")):
            with self.assertRaises(setup_env.SetupEnvError):
                setup_env.ensure_zig({}, ROOT, force=True)


if __name__ == "__main__":
    unittest.main()
