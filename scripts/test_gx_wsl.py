#!/usr/bin/env python3
"""Tests for scripts/gx_wsl.py: wsl.exe command construction, argument parsing, the generated bash
scripts, the in-WSL Zig package prefetch program and Windows-side sync target resolution.

Nothing here starts WSL or touches the network; git tests use temporary repositories.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_wsl  # noqa: E402

CLONE = "~/src/gx_ghostty"


def wait_for_task_exit(task: Path, timeout: float = 5.0) -> None:
    """Wait for kernel task teardown, which can finish after Thread.join()."""
    deadline = time.monotonic() + timeout
    while task.exists():
        if time.monotonic() >= deadline:
            raise AssertionError(f"joined worker still present in {task}")
        time.sleep(0.01)


class TaskExitTests(unittest.TestCase):
    def test_joined_worker_can_remain_visible_until_kernel_teardown(self):
        task = mock.Mock(spec=Path)
        task.exists.side_effect = [True, True, False]
        with mock.patch(__name__ + ".time.monotonic", side_effect=[0, 0.1, 0.2]), \
                mock.patch(__name__ + ".time.sleep") as sleep:
            wait_for_task_exit(task)
        self.assertEqual(3, task.exists.call_count)
        self.assertEqual([mock.call(0.01), mock.call(0.01)], sleep.call_args_list)

    def test_missing_task_does_not_wait(self):
        task = mock.Mock(spec=Path)
        task.exists.return_value = False
        with mock.patch(__name__ + ".time.sleep") as sleep:
            wait_for_task_exit(task)
        sleep.assert_not_called()

    def test_worker_that_never_exits_fails_at_deadline(self):
        task = mock.Mock(spec=Path)
        task.exists.return_value = True
        with mock.patch(__name__ + ".time.monotonic", side_effect=[0, 5]), \
                mock.patch(__name__ + ".time.sleep") as sleep:
            with self.assertRaisesRegex(AssertionError, "joined worker still present"):
                wait_for_task_exit(task)
        sleep.assert_not_called()


def prefetch_namespace() -> dict:
    namespace: dict = {"__name__": "gx_wsl_prefetch"}
    exec(compile(gx_wsl.PREFETCH_PROGRAM, "gx_wsl_prefetch", "exec"), namespace)
    return namespace


def find_bash() -> str | None:
    """A real bash; neither Windows' system launcher nor Store alias counts."""
    system_root = os.path.normcase(os.environ.get("SystemRoot", r"C:\Windows"))
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry or (os.name == "nt" and os.path.normcase(os.path.abspath(entry)).startswith(system_root)):
            continue
        found = shutil.which("bash", path=entry)
        if found:
            if os.name == "nt" and Path(found).parent.name.lower() == "windowsapps":
                continue
            return found
    return None


def all_invocations() -> dict[str, gx_wsl.Invocation]:
    setup = gx_wsl.setup_invocations(CLONE, "E:/repo", check=False, apt=True)
    return {
        "apt": setup[0],
        "setup": setup[1],
        "check": gx_wsl.setup_invocations(CLONE, "E:/repo", check=True, apt=False)[0],
        "sync": gx_wsl.sync_invocation(CLONE, gx_wsl.SyncTarget("a" * 40, "E:/repo", "ref main")),
        "build": gx_wsl.build_invocation(CLONE, True, ["-Doptimize=ReleaseFast"]),
        "test": gx_wsl.zig_test_invocation(CLONE, "main", False, ["Terminal"], []),
        "smoke": gx_wsl.smoke_invocation(
            CLONE, out="out", lang="zh_CN", xdotool=None, config=None, wait=20, name=None, ghostty_args=[]
        ),
        "smoke-perf": gx_wsl.smoke_invocation(
            CLONE, out="out", lang=None, xdotool="s.xdo", config=None, wait=20, name="p", ghostty_args=["--x=1"],
            settle=0, perf=True, env=["GSK_RENDERER=cairo", "A_B=x y"],
        ),
        "run": gx_wsl.run_invocation(CLONE, lang=None, config=None, x11=True, ghostty_args=[]),
    }


class WslCommandTests(unittest.TestCase):
    def test_exec_bash_directly_with_positional_arguments(self) -> None:
        invocation = gx_wsl.Invocation("echo hi\n", (CLONE, "a b", "$(touch x)", ""))
        command = gx_wsl.wsl_command("Ubuntu-24.04", invocation)
        self.assertEqual(
            ["wsl.exe", "-d", "Ubuntu-24.04", "--cd", "~", "-e", "bash", "-c", "echo hi\n", "gx-wsl", CLONE, "a b", "$(touch x)", ""],
            command,
        )
        self.assertNotIn("--", command, "`wsl.exe --` re-parses the line with the login shell")

    def test_root_invocation_adds_user(self) -> None:
        command = gx_wsl.wsl_command("Debian", gx_wsl.Invocation("true\n", (), user="root"))
        self.assertEqual(["wsl.exe", "-d", "Debian", "-u", "root", "--cd", "~", "-e", "bash", "-c"], command[:10])

    def test_describe_hides_the_script(self) -> None:
        command = gx_wsl.wsl_command("Ubuntu-24.04", gx_wsl.Invocation("long\nscript\n", (CLONE, "x y")))
        self.assertEqual('wsl.exe -d Ubuntu-24.04 --cd ~ -e bash -c <script> gx-wsl ~/src/gx_ghostty "x y"', gx_wsl.describe(command))


class ArgumentTests(unittest.TestCase):
    def parse(self, *argv: str, **environ: str):
        return gx_wsl.parse_args(list(argv), environ)

    def test_defaults_and_environment_overrides(self) -> None:
        args = self.parse("shell")
        self.assertEqual((gx_wsl.DEFAULT_DISTRO, gx_wsl.DEFAULT_CLONE, False), (args.distro, args.clone, args.dry_run))
        args = self.parse("shell", GX_WSL_DISTRO="Debian", GX_WSL_CLONE="~/src/other")
        self.assertEqual(("Debian", "~/src/other"), (args.distro, args.clone))

    def test_common_options_before_or_after_the_command(self) -> None:
        before = self.parse("--distro", "A", "--clone", "/home/u/c", "--dry-run", "build")
        after = self.parse("build", "--distro", "A", "--clone", "/home/u/c", "--dry-run")
        for args in (before, after):
            self.assertEqual(("A", "/home/u/c", True), (args.distro, args.clone, args.dry_run))
        self.assertEqual("B", self.parse("build", "--distro", "B", GX_WSL_DISTRO="A").distro)

    def test_build_help_reaches_zig_instead_of_argparse(self):
        for help_flag in ("--help", "-h", "--list-steps", "-l"):
            with self.subTest(help_flag=help_flag), contextlib.redirect_stdout(io.StringIO()):
                args = self.parse("build", "--gtk", "-Doptimize=ReleaseFast", help_flag)
                self.assertEqual(["-Doptimize=ReleaseFast", help_flag], args.extra)
                invocation = gx_wsl.plan(args)[0]
                self.assertEqual(help_flag, invocation.args[-1])
                self.assertIn("normal_build", invocation.script)

    def test_build_passes_unknown_arguments_through_in_order(self) -> None:
        args = self.parse("build", "--gtk", "-Doptimize=ReleaseFast", "test-lib-vt-schema", "-fno-sys=foo", "--summary", "all")
        self.assertTrue(args.gtk)
        self.assertEqual(["-Doptimize=ReleaseFast", "test-lib-vt-schema", "-fno-sys=foo", "--summary", "all"], args.extra)

    def test_test_collects_filters_and_passes_the_rest(self) -> None:
        args = self.parse("test", "--suite", "vt", "--filter", "a b", "--filter=c", "--jobs", "8", "-Dtest-filter=x")
        self.assertEqual(("vt", ["a b", "c"]), (args.suite, args.filter))
        self.assertEqual(["--jobs", "8", "-Dtest-filter=x"], args.extra)
        self.assertEqual("main", self.parse("test").suite)

    def test_smoke_options_and_ghostty_arguments(self) -> None:
        args = self.parse("smoke", "--out", "ev", "--lang", "en", "--wait", "2.5", "--", "--title=x y", "--font-size=9")
        self.assertEqual(("ev", "en", 2.5), (args.out, args.lang, args.wait))
        self.assertEqual(["--title=x y", "--font-size=9"], args.ghostty_args)
        defaults = self.parse("smoke", "--out", "ev")
        self.assertEqual((gx_wsl.SMOKE_WAIT_SECONDS, gx_wsl.SMOKE_SETTLE_SECONDS, False, []),
                         (defaults.wait, defaults.settle, defaults.perf, defaults.env))

    def test_smoke_perf_settle_and_env(self) -> None:
        args = self.parse("smoke", "--out", "ev", "--perf", "--settle", "0", "--env", "GSK_RENDERER=cairo",
                          "--env=GALLIUM_DRIVER=llvmpipe")
        self.assertEqual((True, 0.0), (args.perf, args.settle))
        self.assertEqual(["GSK_RENDERER=cairo", "GALLIUM_DRIVER=llvmpipe"], args.env)

    def test_rejections_exit_2(self) -> None:
        for argv in (
            ("smoke",),
            ("smoke", "--out", "ev", "--lang", "de"),
            ("smoke", "--out", "ev", "--wait", "0"),
            ("smoke", "--out", "ev", "--settle", "-1"),
            ("smoke", "--out", "ev", "--font-size=9"),
            ("run", "--perf"),
            ("setup", "--force"),
            ("sync", "a", "b"),
            ("test", "--suite", "app"),
            ("bogus",),
        ):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    self.parse(*argv)
                self.assertEqual(2, caught.exception.code)

    def test_no_abbreviations(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.parse("smoke", "--ou", "ev")


class ArgumentBuilderTests(unittest.TestCase):
    def test_build_args(self) -> None:
        self.assertEqual(["-Dapp-runtime=gtk", "-fno-sys=gtk4-layer-shell", "-Dx=1"], gx_wsl.build_args(True, ["-Dx=1"]))
        self.assertEqual(["-Dx=1"], gx_wsl.build_args(False, ["-Dx=1"]))

    def test_zig_test_args_follow_gx_ci(self) -> None:
        self.assertEqual(["--suite", "main", "-Dapp-runtime=none"], gx_wsl.zig_test_args("main", False, [], []))
        self.assertEqual(["--suite", "vt", "--filter", "a", "--jobs", "4"], gx_wsl.zig_test_args("vt", False, ["a"], ["--jobs", "4"]))
        self.assertEqual(
            ["--suite", "main", "-Dapp-runtime=gtk", "--zig-arg=-fno-sys=gtk4-layer-shell"],
            gx_wsl.zig_test_args("main", True, [], []),
        )
        workflow = (ROOT / ".github" / "workflows" / "gx-ci.yml").read_text(encoding="utf-8")
        self.assertIn("--suite main " + " ".join(gx_wsl.MAIN_SUITE_ARGS), workflow)

    def test_gtk_tests_need_the_main_suite(self) -> None:
        args = gx_wsl.parse_args(["test", "--suite", "vt", "--gtk"], {})
        with self.assertRaises(gx_wsl.GxWslError):
            gx_wsl.plan(args)

    def test_smoke_arguments(self) -> None:
        invocation = gx_wsl.smoke_invocation(
            CLONE, out="ev", lang="zh_CN", xdotool="s.xdo", config=None, wait=7.5, name=None, ghostty_args=["--title=t"]
        )
        self.assertEqual(
            (
                CLONE,
                os.path.abspath("ev"),
                "zh_CN.UTF-8",
                "zh_CN:zh",
                os.path.abspath("s.xdo"),
                "",
                "7.5",
                "ghostty-xvfb-zh_CN",
                "1280x800x24",
                "3",
                "0",
                "",
                gx_wsl.PERF_WORKLOAD,
                "--title=t",
            ),
            invocation.args,
        )
        plain = gx_wsl.smoke_invocation(CLONE, out="ev", lang=None, xdotool=None, config="c", wait=20, name="n1", ghostty_args=[])
        self.assertEqual(
            (CLONE, os.path.abspath("ev"), "", "", "", os.path.abspath("c"), "20", "n1", "1280x800x24", "3", "0", "",
             gx_wsl.PERF_WORKLOAD),
            plain.args,
        )
        perf = gx_wsl.smoke_invocation(
            CLONE, out="ev", lang=None, xdotool=None, config=None, wait=20, name=None, ghostty_args=[], settle=0.5,
            perf=True, env=["GSK_RENDERER=cairo", "X=a b=c"],
        )
        self.assertEqual(("0.5", "1", "GSK_RENDERER=cairo\nX=a b=c"), perf.args[9:12])

    def test_env_assignments_are_validated(self) -> None:
        self.assertEqual("", gx_wsl.env_assignments([]))
        self.assertEqual("A=\n_b2=x=y", gx_wsl.env_assignments(["A=", "_b2=x=y"]))
        for bad in ("A", "=x", "1A=x", "A-B=x", "A B=x", "A=x\ny", "A=x\ry", "DISPLAY=:0",
                    "WAYLAND_DISPLAY=wayland-0", "XDG_CONFIG_HOME=/other", "XDG_STATE_HOME=/other", "GDK_BACKEND=wayland"):
            with self.subTest(value=bad), self.assertRaises(gx_wsl.GxWslError):
                gx_wsl.env_assignments([bad])

    def test_smoke_name_is_a_plain_file_prefix(self) -> None:
        self.assertEqual("ghostty-xvfb", gx_wsl.smoke_name(None, None))
        self.assertEqual("ghostty-xvfb-en", gx_wsl.smoke_name("", "en"))
        self.assertEqual("run-1.zh", gx_wsl.smoke_name("run-1.zh", "zh_CN"))
        for bad in ("../x", "a/b", "a b", "-x", ".hidden", "a\\b"):
            with self.subTest(name=bad), self.assertRaises(gx_wsl.GxWslError):
                gx_wsl.smoke_name(bad, None)

    def test_run_arguments(self) -> None:
        invocation = gx_wsl.run_invocation(CLONE, lang="en", config=None, x11=True, ghostty_args=["-e", "top"])
        self.assertEqual((CLONE, "en_US.UTF-8", "en", "", "1", "-e", "top"), invocation.args)

    def test_clone_must_be_a_linux_path(self) -> None:
        for good in ("~", "~/src/x", "/home/u/x"):
            self.assertEqual(good, gx_wsl.check_clone_path(good))
        for bad in ("C:/Program Files/Git/home/u", "c:\\x", "\\\\wsl.localhost\\x", "src/x", "~user/x"):
            with self.subTest(clone=bad), self.assertRaises(gx_wsl.GxWslError):
                gx_wsl.check_clone_path(bad)


class ScriptTests(unittest.TestCase):
    def expanded_smoke(self, name):
        import ast
        import base64
        import zlib
        script = all_invocations()[name].script
        bootstrap = script.split("<<'GX_WSL_SESSION'\n", 1)[1].split("\nGX_WSL_SESSION", 1)[0]
        tree = ast.parse(bootstrap)
        payload = next(node.value for node in ast.walk(tree) if isinstance(node, ast.Constant)
                       and isinstance(node.value, str) and len(node.value) > 100)
        program = zlib.decompress(base64.b64decode(payload)).decode("utf-8")
        self.assertEqual(gx_wsl.PERF_PROGRAM.rsplit('\nif __name__ == "__main__":', 1)[0] + gx_wsl.SMOKE_PROGRAM, program)
        compile(program, "expanded-smoke", "exec")
        return script + "\n" + program

    def test_scripts_are_strict_and_free_of_argument_values(self) -> None:
        marker = "$(touch should-not-run)"
        invocation = gx_wsl.build_invocation(CLONE, False, [marker])
        self.assertIn(marker, invocation.args)
        self.assertNotIn(marker, invocation.script)
        for name, invocation in all_invocations().items():
            with self.subTest(script=name):
                self.assertTrue(invocation.script.startswith("set -euo pipefail\n"))

    def test_prefetch_program_is_embedded_once(self) -> None:
        function = gx_wsl.prefetch_function()
        self.assertIn(gx_wsl.PREFETCH_PROGRAM.strip(), function)
        lines = function.splitlines()
        self.assertEqual(1, lines.count(gx_wsl.PREFETCH_DELIMITER))
        self.assertIn(f"<<'{gx_wsl.PREFETCH_DELIMITER}'", function)
        for name in ("setup", "check", "build", "test"):
            self.assertIn(function, all_invocations()[name].script)

    def test_smoke_matches_the_gx_ci_gtk_smoke_job(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "gx-ci.yml").read_text(encoding="utf-8")
        script = self.expanded_smoke("smoke")
        self.assertIn(f"-screen 0 {gx_wsl.SMOKE_SCREEN}", workflow)
        self.assertIn("export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1", workflow)
        self.assertIn("export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1", script)
        self.assertIn("xvfb-run --auto-servernum", script)
        self.assertIn("--gtk-single-instance=false", script)
        self.assertIn("ghostty --gtk-single-instance=false", workflow)

    def test_smoke_waits_for_the_window_instead_of_a_fixed_delay(self) -> None:
        script = self.expanded_smoke("smoke")
        self.assertIn('["xdotool", "search", "--onlyvisible", "--pid", str(child.pid)]', script)
        self.assertIn("time.sleep(0.05)", script)
        self.assertNotIn("--sync", script)
        self.assertIn('require_identity(child.pid, meta["identity"], pidfd, digest)', script)
        self.assertIn('time.sleep(float(settle))', script)
        self.assertNotIn('time.sleep(float(wait_seconds))', script)
        for tool in ("xvfb-run", "xauth", "scrot", "xdotool"):
            self.assertIn(tool, script.split("for tool in ", 1)[1].split(";", 1)[0])
        self.assertIn("xdotool", gx_wsl.APT_PACKAGES)

    def test_perf_report_function_is_embedded_once(self) -> None:
        function = gx_wsl.perf_function()
        self.assertIn(gx_wsl.PERF_PROGRAM.strip(), function)
        self.assertEqual(1, function.splitlines().count(gx_wsl.PERF_DELIMITER))
        script = self.expanded_smoke("smoke-perf")
        self.assertIn(gx_wsl.smoke_function(), script)
        self.assertIn("export GHOSTTY_GX_PERF=1", script)
        self.assertIn('["-e", "sh", str(work / "workload.sh")]', script)
        self.assertIn('export "$assignment"', script)

    def test_ghostty_config_is_isolated(self) -> None:
        for name in ("smoke", "run"):
            script = all_invocations()[name].script
            self.assertIn('prepare_config "$', script)
            self.assertIn("export XDG_CONFIG_HOME=$home", script)
            self.assertIn("env = XDG_CONFIG_HOME=", script)
            self.assertIn("LD_LIBRARY_PATH=$clone/zig-out/lib", script)

    def test_blueprint_pin(self) -> None:
        self.assertRegex(gx_wsl.BLUEPRINT_SHA256, r"^[0-9a-f]{64}$")
        self.assertIn(f"/v{gx_wsl.BLUEPRINT_VERSION}/", gx_wsl.BLUEPRINT_URL)
        source = (ROOT / "src" / "apprt" / "gtk" / "build" / "blueprint.zig").read_text(encoding="utf-8")
        major, minor, patch = (int(part) for part in gx_wsl.BLUEPRINT_VERSION.split("."))
        self.assertIn(
            f"const required_blueprint_version = std.SemanticVersion{{\n    .major = {major},\n    .minor = {minor},\n    .patch = {patch},\n}};",
            source.replace("\r\n", "\n"),
            "the pinned blueprint-compiler should be exactly the minimum the GTK build accepts",
        )

    def test_smoke_argv_fits_windows_createprocess(self):
        invocation = all_invocations()["smoke-perf"]
        length = len(subprocess.list2cmdline(gx_wsl.wsl_command("Ubuntu-24.04", invocation)))
        self.assertLess(length, 32767)
        program = invocation.script.split("<<'GX_WSL_SESSION'\n", 1)[1].split("\nGX_WSL_SESSION", 1)[0]
        compile(program, "generated-smoke-session", "exec")

    def test_smoke_bootstrap_registers_source_for_tracebacks(self):
        import linecache
        bootstrap = gx_wsl.smoke_function().split("<<'GX_WSL_SESSION'\n", 1)[1].split("\nGX_WSL_SESSION", 1)[0]
        previous = linecache.cache.get("gx-wsl-session")
        try:
            executed = mock.Mock()
            exec(bootstrap, {"exec": executed})
            executed.assert_called_once()
            expected = gx_wsl.PERF_PROGRAM.rsplit('\nif __name__ == "__main__":', 1)[0] + gx_wsl.SMOKE_PROGRAM
            self.assertEqual(expected.splitlines(True), linecache.getlines("gx-wsl-session"))
        finally:
            if previous is None:
                linecache.cache.pop("gx-wsl-session", None)
            else:
                linecache.cache["gx-wsl-session"] = previous

    @unittest.skipUnless(find_bash(), "needs a bash for `bash -n`")
    def test_scripts_parse(self) -> None:
        bash = find_bash()
        assert bash is not None
        for name, invocation in all_invocations().items():
            with self.subTest(script=name):
                # stdin, not -c: an MSYS bash would re-parse a Windows command line argument.
                result = subprocess.run(
                    [bash, "-n"], input=invocation.script.encode("utf-8"), capture_output=True, check=False
                )
                self.assertEqual(0, result.returncode, result.stderr)


class PrefetchProgramTests(unittest.TestCase):
    def setUp(self) -> None:
        self.program = prefetch_namespace()
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "clone"
        self.root.mkdir()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_archive_url(self) -> None:
        archive_url = self.program["archive_url"]
        sha = "2826a37a4562284fdacd8fa029d49509cc9bffcd"
        self.assertEqual("https://x.org/a.tar.gz", archive_url("https://x.org/a.tar.gz"))
        self.assertEqual(f"https://github.com/o/r/archive/{sha}.tar.gz", archive_url(f"git+https://github.com/o/r#{sha}"))
        self.assertEqual(f"https://github.com/o/r/archive/{sha}.tar.gz", archive_url(f"git+https://github.com/o/r.git#{sha}"))
        self.assertEqual(f"https://github.com/o/zig/archive/{sha}.tar.gz", archive_url(f"git+https://github.com/o/zig?ref=b#{sha}"))
        self.assertEqual(f"https://codeberg.org/o/r/archive/{sha}.tar.gz", archive_url(f"git+https://codeberg.org/o/r#{sha}"))
        self.assertIsNone(archive_url(f"git+https://gitlab.com/o/r#{sha}"))
        self.assertIsNone(archive_url("git+https://github.com/o/r#main"))

    def test_zon_dependencies_skip_paths_and_comments(self) -> None:
        text = "\r\n".join(
            (
                ".{",
                "    .dependencies = .{",
                '        .a = .{ .path = "./pkg/a" },',
                "        .b = .{",
                "            // https://example.org/comment, not a dependency",
                '            .url = "https://x.org/b.tar.gz", // trailing comment',
                '            .hash = "b-0.0.0-AAAA",',
                "            .lazy = true,",
                "        },",
                '        .c = .{ .hash = "N-V-__8AAC", .url = "git+https://github.com/o/c#0123456789012345678901234567890123456789" },',
                "        // .d = .{",
                '        //     .url = "https://x.org/d.tar.gz",',
                '        //     .hash = "d-0.0.0-DDDD",',
                "        // },",
                "    },",
                "}",
            )
        )
        self.assertEqual(
            [("b-0.0.0-AAAA", "https://x.org/b.tar.gz"), ("N-V-__8AAC", "git+https://github.com/o/c#0123456789012345678901234567890123456789")],
            self.program["zon_dependencies"](text),
        )
        self.assertEqual('x = "a//b" ', self.program["strip_comments"]('x = "a//b" // c'))
        self.assertEqual('x = "a\\"//b"', self.program["strip_comments"]('x = "a\\"//b"// c'))

    def test_archive_name_keeps_the_extension(self) -> None:
        self.assertEqual("p-x.tar.zst", self.program["archive_name"]("p", "https://h/a/x.tar.zst?download=1"))

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_declared_merges_manifest_root_and_pkg(self) -> None:
        self.write("build.zig.zon.json", json.dumps({"m-1": {"name": "m", "url": "https://h/m.tar.gz", "hash": "sha256-x"}}))
        self.write("build.zig.zon", '.{ .dependencies = .{ .r = .{ .url = "https://h/r.tgz", .hash = "r-1" } } }')
        self.write("pkg/p/build.zig.zon", '.{ .dependencies = .{ .q = .{ .url = "https://h/q.tar.xz", .hash = "q-1" } } }')
        self.assertEqual(
            {"m-1": "https://h/m.tar.gz", "r-1": "https://h/r.tgz", "q-1": "https://h/q.tar.xz"},
            self.program["declared"](str(self.root)),
        )

    def run_check(self, cache: Path) -> tuple[int, str]:
        output = io.StringIO()
        with mock.patch.dict(os.environ, {"ZIG_GLOBAL_CACHE_DIR": str(cache)}), contextlib.redirect_stdout(output):
            code = self.program["main"](["-", str(self.root), "--check"])
        return code, output.getvalue()

    def test_check_mode_reports_missing_packages_and_follows_nested_ones(self) -> None:
        cache = Path(self._tmp.name) / "cache"
        (cache / "p").mkdir(parents=True)
        (cache / "p" / "cached-1.tar.gz").write_bytes(b"")
        self.write(
            "build.zig.zon",
            '.{ .dependencies = .{\n'
            '  .e = .{ .url = "https://h/e.tgz", .hash = "extracted-1" },\n'
            '  .c = .{ .url = "https://h/c.tgz", .hash = "cached-1" },\n'
            '  .m = .{ .url = "https://h/m.tgz", .hash = "missing-1" },\n'
            "} }",
        )
        self.write("zig-pkg/extracted-1/build.zig.zon", '.{ .dependencies = .{ .n = .{ .url = "https://h/n.tgz", .hash = "nested-1" } } }')
        code, output = self.run_check(cache)
        self.assertEqual(1, code)
        self.assertIn("zig packages: 2/4 available, 0 fetched now", output)
        self.assertIn("missing zig package: missing-1", output)
        self.assertIn("missing zig package: nested-1", output)

        (self.root / "zig-pkg" / "missing-1").mkdir()
        (self.root / "zig-pkg" / "nested-1").mkdir()
        code, output = self.run_check(cache)
        self.assertEqual(0, code, output)
        self.assertIn("zig packages: 4/4 available", output)


def perf_namespace() -> dict:
    namespace: dict = {"__name__": "gx_wsl_perf"}
    exec(compile(gx_wsl.PERF_PROGRAM, "gx_wsl_perf", "exec"), namespace)
    return namespace


def stat_line(tid: int, comm: str, minflt: int, majflt: int, utime: int, stime: int,
              starttime: int = 100) -> str:
    fields = ["S", "1", "1", "1", "0", "-1", "4194560", str(minflt), "0", str(majflt), "0", str(utime), str(stime)]
    fields += ["0"] * 39
    fields[19] = str(starttime)
    return f"{tid}\t{tid} ({comm}) {' '.join(fields)}"


class PerfProgramTests(unittest.TestCase):
    def setUp(self) -> None:
        self.program = perf_namespace()

    def test_parse_tasks_reads_names_with_spaces_and_parentheses(self) -> None:
        text = "\r\n".join((stat_line(10, "ghostty", 5, 1, 100, 20), stat_line(11, "a) b", 7, 0, 3, 4)))
        tasks = self.program["parse_tasks"](text)
        self.assertEqual({"10", "11"}, set(tasks))
        self.assertEqual({"comm": "a) b", "starttime": 100, "minflt": 7, "majflt": 0, "utime": 3, "stime": 4}, tasks["11"])

    def test_report_groups_threads_and_counts_log_lines(self) -> None:
        before = "\n".join((stat_line(10, "ghostty", 100, 1, 50, 10), stat_line(11, "renderer", 10, 0, 20, 5),
                            stat_line(12, "io", 0, 0, 1, 1), stat_line(13, "io", 0, 0, 0, 0),
                            stat_line(15, "llvmpipe-0", 0, 0, 0, 0), stat_line(16, "llvmpipe-1", 0, 0, 0, 0),
                            stat_line(17, "dconf worker", 0, 0, 0, 0)))
        after = "\n".join((stat_line(10, "ghostty", 150, 1, 150, 30), stat_line(11, "renderer", 30, 2, 320, 25),
                           stat_line(12, "io", 0, 0, 101, 1), stat_line(13, "io", 4, 0, 50, 0),
                           stat_line(15, "llvmpipe-0", 0, 0, 30, 10), stat_line(16, "llvmpipe-1", 0, 0, 20, 0),
                           stat_line(17, "dconf worker", 0, 0, 0, 0)))
        times = "pid 10\nwindow_seconds 1.5\nworkload_seconds 12.25\nworkload_finished 1\n"
        log = ("warning(gtk_opengl): failed to export DMABUF, falling back to CPU presentation\n" * 3
               + "info(gx_perf): first_frame 183456us\n")
        report = self.program["report"](before, after, times, log, 100)
        lines = report.splitlines()
        self.assertEqual("finished: yes", lines[2])
        for expected in ("metric window_seconds 1.500 s", "metric workload_seconds 12.250 s", "metric cpu.main 1.200 s",
                         "metric cpu.renderer 3.200 s", "metric cpu.io 1.500 s", "metric cpu.llvmpipe 0.600 s",
                         "metric cpu.total 6.500 s", "metric minflt.total 74", "metric majflt.total 2",
                         "metric dmabuf_warnings 3", "metric gx_perf_lines 1"):
            self.assertIn(expected, lines)
        cpu = [line.split()[1] for line in lines if line.startswith("metric cpu.")]
        self.assertEqual(["cpu.main", "cpu.renderer", "cpu.io", "cpu.llvmpipe", "cpu.dconf_worker", "cpu.total"], cpu)
        self.assertIn("dconf_worker", report)
        unfinished = self.program["report"](before, after, "pid 10\nworkload_finished 0\n", "", 100)
        self.assertIn("finished: no", unfinished)
        self.assertNotIn("metric ", unfinished)

    def test_tid_reuse_and_negative_counters_are_rejected(self) -> None:
        before = self.program["parse_tasks"](stat_line(10, "ghostty", 0, 0, 100, 0, 100))
        for birth in (100, 200):
            after = self.program["parse_tasks"](stat_line(10, "ghostty", 0, 0, 2, 0, birth))
            with self.subTest(starttime=birth), self.assertRaises(ValueError):
                self.program["deltas"](before, after, "10")

    def test_partial_stats_and_population_changes_are_rejected(self) -> None:
        for text in ("12\t", "13\tgarbage", "1\t1 (x) S 1 2", stat_line(1, "x", 0, 0, 1, 0) + "\n1\t"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.program["parse_tasks"](text)
        main = self.program["parse_tasks"](stat_line(10, "ghostty", 0, 0, 100, 0))
        added = self.program["parse_tasks"](stat_line(10, "ghostty", 0, 0, 101, 0) + "\n" + stat_line(11, "renderer", 0, 0, 50, 0))
        for before, after in ((main, added), (added, main)):
            with self.assertRaises(ValueError):
                self.program["deltas"](before, after, "10")

    def test_invalid_workload_or_missing_renderer_has_no_metrics(self) -> None:
        main = stat_line(10, "ghostty", 0, 0, 0, 0)
        report = self.program["report"](main, main, "pid 10\nworkload_finished 0\n", "", 100)
        self.assertIn("valid: no", report)
        self.assertNotIn("metric ", report)

    def test_zero_llvmpipe_and_warnings_count_lines(self) -> None:
        tasks = "\n".join((stat_line(10, "ghostty", 0, 0, 0, 0), stat_line(11, "renderer", 0, 0, 0, 0),
                            stat_line(12, "llvmpipe-0", 0, 0, 0, 0)))
        times = "pid 10\nworkload_finished 1\nwindow_seconds 1\nworkload_seconds 1\n"
        log = "failed to export DMABUF; failed to build dmabuf\n"
        report = self.program["report"](tasks, tasks, times, log, 100)
        self.assertIn("metric cpu.llvmpipe 0.000 s", report)
        self.assertIn("metric dmabuf_warnings 1", report)

    def test_main_reads_files_and_fails_without_statistics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = [Path(tmp) / name for name in ("before", "after", "times", "log")]
            renderer = "\n" + stat_line(2, "renderer", 0, 0, 0, 0)
            for path, text in zip(paths, (stat_line(1, "ghostty", 0, 0, 0, 0) + renderer,
                                          stat_line(1, "ghostty", 0, 0, 7, 3) + renderer,
                                          "pid 1\nworkload_finished 1\nwindow_seconds 1\nworkload_seconds 1\n", "")):
                path.write_text(text, encoding="utf-8")
            out = io.StringIO()
            with mock.patch.object(self.program["os"], "sysconf", return_value=100, create=True), contextlib.redirect_stdout(out):
                self.assertEqual(0, self.program["main"](["-", *map(str, paths)]))
                self.assertIn("metric cpu.main", out.getvalue())
                paths[1].write_text("", encoding="utf-8")
                self.assertEqual(1, self.program["main"](["-", *map(str, paths)]))

    def test_metric_tokens_preserve_odd_names_and_detect_collisions(self):
        tasks = "\n".join((stat_line(10, "ghostty", 0, 0, 0, 0), stat_line(11, "renderer", 0, 0, 0, 0),
                            stat_line(12, "ghostty:disk$0", 0, 0, 0, 0)))
        result = self.program["report"](tasks, tasks, "pid 10\nworkload_finished 1\nwindow_seconds 1\nworkload_seconds 1\n", "", 100)
        import gx_perf
        samples = gx_perf.parse_text(result)
        self.assertIn("cpu.ghostty:disk_0", samples.values)
        collision = tasks + "\n" + stat_line(13, "ghostty:disk_0", 0, 0, 0, 0)
        with self.assertRaises(ValueError):
            self.program["deltas"](self.program["parse_tasks"](collision), self.program["parse_tasks"](collision), "10")

    def test_transient_cpu_cannot_hide_between_equal_task_endpoints(self):
        tasks = "\n".join((stat_line(10, "ghostty", 0, 0, 0, 0), stat_line(11, "renderer", 0, 0, 0, 0)))
        def sample(ticks, start):
            stat = stat_line(10, "ghostty", 0, 0, ticks, 0).split("\t", 1)[1]
            return {"pre_stat": stat, "post_stat": stat, "begin_ns": start, "end_ns": start + 1_000_000}
        before, after = sample(0, 1_000_000_000), sample(100, 3_000_000_000)
        accounting = self.program["cpu_accounting"](tasks, tasks, before, after, "10", 100)
        self.assertEqual(100, accounting["process_counters"]["utime"])
        self.assertEqual(0, accounting["endpoint_counters"]["utime"])
        self.assertTrue(accounting["diagnostic_only"])
        self.assertFalse(accounting["diagnostic_within_bound"])
        self.assertNotIn("comparable", accounting)
        report = self.program["report"](tasks, tasks, "pid 10\nworkload_finished 1\nwindow_seconds 1\nworkload_seconds 1\n", "", 100, before, after)
        self.assertIn("metric cpu.total 1.000 s", report)
        self.assertIn("diagnostic only", report)
        with self.assertRaises(ValueError):
            self.program["cpu_accounting"](tasks, tasks, after, sample(0, 5_000_000_000), "10", 100)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux /proc accounting semantics")
    def test_linux_process_stat_keeps_exited_thread_cpu(self):
        import threading
        import time
        root = Path("/proc/self")
        pid = str(os.getpid())
        def stat(path):
            return self.program["parse_tasks"](pid + "\t" + path.read_text())[pid]
        before_proc, before_main = stat(root / "stat"), stat(root / "task" / pid / "stat")
        population = {path.name for path in (root / "task").iterdir()}
        cpu, native = [], []
        def worker():
            native.append(threading.get_native_id())
            begin = time.thread_time()
            total = 0
            for index in range(8_000_000):
                total += index % 19
            cpu.append(time.thread_time() - begin)
        thread = threading.Thread(target=worker)
        thread.start()
        thread.join()
        # CPython releases the join lock before the native thread finishes
        # exiting. Sample only after Linux has removed that task and folded
        # its CPU time into the process counters; keep the population check.
        wait_for_task_exit(root / "task" / str(native[0]))
        self.assertEqual(population, {path.name for path in (root / "task").iterdir()})
        after_proc, after_main = stat(root / "stat"), stat(root / "task" / pid / "stat")
        process_delta = sum(after_proc[key] - before_proc[key] for key in ("utime", "stime"))
        main_delta = sum(after_main[key] - before_main[key] for key in ("utime", "stime"))
        self.assertGreaterEqual(process_delta - main_delta, int(cpu[0] * os.sysconf("SC_CLK_TCK")) - 4)

    def test_prefix_is_rechecked_inside_lock_and_copy_is_exclusive(self):
        body = gx_wsl.SMOKE_BODY
        locked = body.split('mkdir "$lock"', 1)[1]
        self.assertIn('compgen -G "$out/$name*"', locked)
        self.assertNotIn('cp -n ', body)
        program = self.supervisor()
        with tempfile.TemporaryDirectory() as tmp:
            source, target = Path(tmp) / "source", Path(tmp) / "target"
            source.mkdir()
            target.mkdir()
            (source / "perf.log").write_text("new", encoding="utf-8")
            (target / "perf.log").write_text("old", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                program["copy_evidence"](source, target)
            self.assertEqual("old", (target / "perf.log").read_text())

    def supervisor(self):
        program = perf_namespace()
        exec(compile(gx_wsl.SMOKE_PROGRAM, "gx_wsl_smoke", "exec"), program)
        return program

    def test_query_or_noninstall_zero_exit_does_not_certify_old_image(self):
        from types import SimpleNamespace
        source = {"commit": "a" * 40, "tree": "b" * 40, "dirty": False, "dirty_paths": ""}
        image = {"sha256": "c" * 64, "device": 1, "inode": 2, "size": 3, "mtime_ns": 4}
        version = "Ghostty 1.3.2-HEAD+aaaaaaaaa\n  - build mode : .ReleaseFast\n"
        for extra in (["--help"], ["-h"], ["--list-steps"], ["-l"], ["test"], ["--unknown-flag"], ["--skip-oom-steps"]):
            program = {"__name__": "test_build_query"}
            exec(gx_wsl.RECEIPT_PROGRAM, program)
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as tmp:
                receipt = Path(tmp) / "receipt.json"
                receipt.write_text('{"perf_eligible": true, "executable": "old"}', encoding="utf-8")
                with mock.patch.dict(program, {"BUILD_RECEIPT": receipt, "source_identity": lambda: source,
                                               "image_info": mock.Mock(return_value=image)}), \
                        mock.patch.object(program["os"], "open", return_value=42) as opened, \
                        mock.patch.object(program["os"], "close"), \
                        mock.patch.object(program["subprocess"], "run", return_value=SimpleNamespace(
                            returncode=0, stdout=version, stderr="")) as run, contextlib.redirect_stdout(io.StringIO()):
                    code = program["build_main"](["-", "-Dapp-runtime=gtk", "-Doptimize=ReleaseFast", *extra])
                self.assertEqual(0, code, "ordinary query/non-install status is passed through")
                data = json.loads(receipt.read_text(encoding="utf-8"))
                self.assertIs(data["perf_eligible"], False)
                self.assertNotIn("executable", data)
                opened.assert_not_called()
                self.assertEqual(1, run.call_count, "no held-image/GPU version probe for non-installs")

    def test_legal_summary_value_and_inline_jobs_are_install_receipts(self):
        program = self.supervisor()
        source = {"commit": "a" * 40, "tree": "b" * 40, "dirty": False, "dirty_paths": ""}
        image = {"path": "/own/ghostty", "sha256": "c" * 64}
        version = "Ghostty 1.3.2-HEAD+aaaaaaaaa\n  - build mode : .ReleaseFast\n"
        base = ["python3", "scripts/zigw.py", "build", "-Dapp-runtime=gtk", "-Doptimize=ReleaseFast"]
        for extra in (["--summary", "all"], ["install", "--summary", "all", "-j4"], ["--color", "off", "-j4"]):
            receipt = {"schema": "gx-gtk-build-v1", "producer": "gx_wsl.py build", "build_exit": 0,
                       "build_argv": base + extra, "source_before": source, "source_after": source,
                       "executable": image, "version": version, "version_exit": 0}
            with self.subTest(extra=extra):
                self.assertEqual(receipt, program["validate_receipt"](receipt, source, image, version, 0))
        for extra in (["--help"], ["--list-steps"], ["test"], ["uninstall"], ["--"], ["--unknown-flag"],
                      ["-j", "4"], ["--summary"], ["--summary", "bad"], ["--skip-oom-steps"]):
            with self.subTest(rejected=extra), self.assertRaises(ValueError):
                program["validate_receipt"](receipt | {"build_argv": base + extra}, source, image, version, 0)

    def test_build_receipt_binds_source_binary_version_and_argv(self):
        program = self.supervisor()
        source = {"commit": "a" * 40, "tree": "b" * 40, "dirty": False, "dirty_paths": ""}
        image = {"path": "/own/ghostty", "sha256": "c" * 64}
        version = "Ghostty 1.3.2-HEAD+aaaaaaaaa\n  - build mode : .ReleaseFast\n"
        receipt = {"schema": "gx-gtk-build-v1", "producer": "gx_wsl.py build", "build_exit": 0,
                   "build_argv": ["python3", "scripts/zigw.py", "build", "-Dapp-runtime=gtk", "-Doptimize=ReleaseFast"],
                   "source_before": source, "source_after": source, "executable": image, "version": version, "version_exit": 0}
        self.assertEqual(receipt, program["validate_receipt"](receipt, source, image, version, 0))
        for changed in (source | {"dirty": True}, source | {"commit": "d" * 40}, source | {"tree": "e" * 40}):
            with self.assertRaises(ValueError):
                program["validate_receipt"](receipt, changed, image, version, 0)
        for changed in (receipt | {"build_exit": 1}, receipt | {"source_before": source | {"dirty": True}},
                        receipt | {"executable": image | {"sha256": "d" * 64}},
                        receipt | {"build_argv": receipt["build_argv"] + ["-Doptimize=Debug"]}):
            with self.assertRaises(ValueError):
                program["validate_receipt"](changed, source, image, version, 0)
        wrong = version.replace("aaaaaaaaa", "fffffffff")
        with self.assertRaisesRegex(ValueError, "source commit"):
            program["validate_receipt"](receipt | {"version": wrong}, source, image, wrong, 0)

    @unittest.skipUnless(find_bash(), "needs real bash")
    def test_prefix_race_is_rejected_after_acquiring_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            out.mkdir()
            script = r'''set -euo pipefail
enter_clone() { :; }
require_ghostty() { :; }
die() { exit "${2:-1}"; }
wslpath() { printf '%s\n' "$2"; }
xvfb-run() { exit 99; }
xauth() { :; }
scrot() { :; }
xdotool() { :; }
mkdir() {
 command mkdir "$@"
 case "${@: -1}" in
 */.gx-wsl-perf) printf 'raced\n' >"${1%/.gx-wsl-perf}/perf-raced.log" ;;
 esac
}
''' + gx_wsl.SMOKE_BODY
            args = [out.as_posix(), "", "", "", "", "20", "perf", "1280x800x24", "3", "0", "", gx_wsl.PERF_WORKLOAD]
            result = subprocess.run([find_bash(), "-s", "--", *args], input=script.encode("utf-8"),
                                    capture_output=True, check=False)
            self.assertEqual(2, result.returncode, result.stderr)
            self.assertEqual("raced\n", (out / "perf-raced.log").read_text())

    def test_process_identity_guard_rejects_reuse_and_exits(self):
        program = self.supervisor()
        expected = {"pid": 10, "starttime": 100, "exe": "/own/ghostty", "sha256": "a" * 64}
        for observed, ready in ((expected | {"starttime": 200}, []), (expected, [39]),
                                (expected | {"exe": "/other/ghostty"}, []), (expected | {"sha256": "b" * 64}, [])):
            with self.subTest(observed=observed, ready=ready), \
                    mock.patch.dict(program, {"process_identity": mock.Mock(return_value=observed)}), \
                    mock.patch.object(program["select"], "select", return_value=(ready, [], [])):
                with self.assertRaises(ValueError):
                    program["require_identity"](10, expected, 39, True)

    def test_cleanup_uses_owned_pidfd_even_after_identity_failure(self):
        program = self.supervisor()
        child = mock.Mock(pid=10)
        child.wait.return_value = -15
        meta = {"identity": {"pid": 10}, "errors": []}
        with mock.patch.dict(program, {"require_identity": mock.Mock(side_effect=ValueError("PID reused"))}), \
                mock.patch.object(program["signal"], "pidfd_send_signal", create=True) as send, \
                mock.patch.object(program["os"], "close") as close:
            program["stop_child"](child, 39, meta)
        send.assert_called_once_with(39, program["signal"].SIGTERM)
        close.assert_called_once_with(39)
        child.terminate.assert_not_called()
        child.kill.assert_not_called()
        self.assertEqual("failed; owned pidfd only", meta["cleanup_identity"])
        self.assertTrue(meta["errors"])

    def test_pidfd_open_failure_cleans_unreaped_direct_child(self):
        program = self.supervisor()
        child = mock.Mock(pid=10)
        child.wait.return_value = -15
        meta = {"errors": []}
        program["stop_child"](child, None, meta)
        child.terminate.assert_called_once_with()
        self.assertIn("unreaped direct Popen child", meta["cleanup"])

    def test_smoke_program_compiles_and_has_no_numeric_signal_fallback(self):
        self.supervisor()
        script = ScriptTests().expanded_smoke("smoke-perf") + gx_wsl.smoke_function()
        self.assertNotIn('kill "$pid"', script)
        self.assertNotIn("os.kill(", script)
        self.assertNotIn("child.poll(", script)
        self.assertIn("pidfd unavailable; refusing to launch", script)
        self.assertIn("perf requires verified ReleaseFast", script)


class ScenarioScriptTests(unittest.TestCase):
    def helper(self, name, scope):
        import ast
        tree = ast.parse(gx_wsl.SMOKE_PROGRAM)
        main = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "smoke_main")
        node = next(n for n in main.body if isinstance(n, ast.FunctionDef) and n.name == name)
        exec(compile(ast.Module(body=[node], type_ignores=[]), "scenario-helper", "exec"), scope)
        return scope[name]

    def test_capture_rejects_unsafe_and_duplicate_labels(self):
        import re
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "G17"
            capture = mock.Mock()
            scope = dict(re=re, Path=Path, prefix=prefix, capture=capture)
            helper = self.helper("scenario_capture", scope)
            for label in ("", "../escape", "a/b", "a\\b", ".hidden"):
                with self.subTest(label=label), self.assertRaises(ValueError):
                    helper(label)
            (Path(tmp) / "G17-used.png").write_bytes(b"existing")
            with self.assertRaises(ValueError):
                helper("used")
            capture.assert_not_called()
            helper("step-1")
            capture.assert_called_once_with("-step-1.png")

    def test_scenario_save_is_confined_and_never_overwrites(self):
        import re
        with tempfile.TemporaryDirectory() as tmp:
            scope = dict(re=re, evidence=Path(tmp), name="G17")
            helper = self.helper("scenario_save", scope)
            for suffix in ("../outside", "/absolute", "-a/b", "-a\\b", ""):
                with self.assertRaises(ValueError):
                    helper(suffix, "bad")
            helper("-result.json", "one")
            with self.assertRaises(FileExistsError):
                helper("-result.json", "two")
            self.assertEqual("one", (Path(tmp) / "G17-result.json").read_text())

    def test_process_snapshot_parses_descendants_and_rechecks_birth(self):
        import re
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp)
            def stat(pid, parent, birth, tty):
                fields = ["0"] * 30
                fields[0], fields[1], fields[4], fields[19] = "S", str(parent), str(tty), str(birth)
                return f"{pid} (name (with) spaces) " + " ".join(fields)
            for pid, parent, birth, tty in ((10, 1, 100, 0), (20, 10, 200, 7), (30, 20, 300, 7), (40, 1, 400, 9)):
                (proc / str(pid)).mkdir()
                (proc / str(pid) / "stat").write_text(stat(pid, parent, birth, tty))
            (proc / "not-a-pid").mkdir()
            (proc / "41").mkdir()
            (proc / "41/stat").write_text("bad")
            saved = mock.Mock()
            guard = mock.Mock()
            scope = dict(re=re, Path=lambda p: proc if str(p) == "/proc" else Path(p),
                         child=SimpleNamespace(pid=10), guard=guard, json=json,
                         save=saved, scenario_save=saved,
                         os=SimpleNamespace(readlink=lambda p: "/dev/pts/7" if p.name == "0" else "/bin/bash"))
            helper = self.helper("scenario_processes", scope)
            result = helper("before")
            self.assertEqual([20, 30], [r["pid"] for r in result])
            self.assertEqual((10, 200, 7, "/dev/pts/7", "/bin/bash"),
                             tuple(result[0][k] for k in ("ppid", "birth", "tty", "fd0", "exe")))
            self.assertEqual([mock.call("process snapshot", True), mock.call("process snapshot finished", True)], guard.call_args_list)
            with self.assertRaises(ValueError):
                helper("../invalid")
            def changed(path):
                (proc / "20/stat").write_text(stat(20, 10, 201, 7))
                return "/bin/bash"
            scope["os"].readlink = changed
            with self.assertRaisesRegex(ValueError, "identity changed"):
                helper("race")

    def test_python_and_legacy_dispatch_and_perf_rejection(self):
        from types import SimpleNamespace
        scope = dict(perf=False, Path=Path, os=SimpleNamespace(environ={"XDG_CONFIG_HOME":"config","XDG_STATE_HOME":"state"}),
                     scenario_capture=mock.Mock(), scenario_xdo=mock.Mock(), scenario_restart=mock.Mock(),
                     scenario_processes=mock.Mock(), scenario_save=mock.Mock(), time=SimpleNamespace(sleep=mock.Mock()),
                     evidence=Path("evidence"), meta={"window":"42"}, child=SimpleNamespace(pid=10),
                     json=json, checked=mock.Mock(), xdo="input.xdo")
        helper = self.helper("scenario_dispatch", scope)
        helper("# gx-scenario-python-v1\nsave('-ran.txt', 'yes')")
        scope["scenario_save"].assert_called_once_with("-ran.txt", "yes")
        scope["checked"].assert_not_called()
        helper("key Escape")
        scope["checked"].assert_called_once_with(["xdotool", "input.xdo", "10"], "xdotool script")
        scope["perf"] = True
        with self.assertRaisesRegex(ValueError, "performance"):
            helper("# gx-scenario-python-v1\nraise AssertionError('must not run')")

    def test_unexpected_script_errors_keep_type_and_traceback(self):
        scope = dict(meta={"errors":[]}, save=mock.Mock())
        helper = self.helper("scenario_failure", scope)
        try:
            {}["missing"]
        except KeyError as exc:
            helper(exc)
        self.assertIn("KeyError", scope["meta"]["errors"][0])
        suffix, trace = scope["save"].call_args.args
        self.assertEqual("-failure.txt", suffix)
        self.assertIn("KeyError", trace)
        self.assertIn("test_unexpected_script_errors", trace)

    def restart_helper(self, scope, child, pidfd):
        import ast
        import textwrap
        tree = ast.parse(gx_wsl.SMOKE_PROGRAM)
        main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "smoke_main")
        helper = next(node for node in main.body if isinstance(node, ast.FunctionDef) and node.name == "scenario_restart")
        source = ast.get_source_segment(gx_wsl.SMOKE_PROGRAM, helper)
        factory = "def factory(child, pidfd):\n" + textwrap.indent(source, "    ") + "\n    return scenario_restart\n"
        exec(compile(factory, "restart-fixture", "exec"), scope)
        return scope["factory"](child, pidfd)

    def test_restart_waits_for_owned_child_and_reuses_private_environment(self):
        import time
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            child = mock.Mock(pid=10)
            child.wait.return_value = 0
            new = mock.Mock(pid=20)
            sub = mock.Mock()
            sub.Popen.return_value = new
            operating = mock.Mock()
            operating.pidfd_open.return_value = 200
            meta = {"identity": {"pid": 10}, "executable": {"path": "/own/exe", "sha256": "abc"},
                    "command": ["/own/exe", "--gtk-single-instance=false"]}
            checked = mock.Mock(side_effect=[SimpleNamespace(returncode=0, stdout="42\n"), SimpleNamespace(stdout="20\n")])
            scope = dict(perf=False, guard=mock.Mock(), subprocess=sub, meta=meta, os=operating,
                         exe="/own/exe", held="/proc/self/fd/9", exe_fd=9, extra=["--cursor-style=bar"],
                         prefix=Path(tmp) / "case", process_identity=mock.Mock(return_value={"pid": 20, "sha256": "abc"}),
                         wait_seconds="2", checked=checked, time=time, settle="0")
            restart = self.restart_helper(scope, child, 100)
            self.assertEqual("42", restart())
            child.wait.assert_called_once_with(timeout=15)
            operating.close.assert_called_once_with(100)
            self.assertEqual(["/own/exe", "--gtk-single-instance=false", "--cursor-style=bar"], sub.Popen.call_args.args[0])
            self.assertEqual("/proc/self/fd/9", sub.Popen.call_args.kwargs["executable"])
            self.assertNotIn("env", sub.Popen.call_args.kwargs, "inherit the same private XDG homes")
            self.assertEqual(0, meta["sessions"][0]["exit"])
            self.assertEqual(["/own/exe", "--gtk-single-instance=false"], meta["sessions"][0]["command"])
            self.assertEqual(sub.Popen.call_args.args[0], meta["command"])

    def test_restart_rejects_perf_and_changed_process_before_input(self):
        for perf in (True, False):
            sub = mock.Mock()
            scope = dict(perf=perf, guard=mock.Mock(side_effect=ValueError("changed identity")), subprocess=sub)
            restart = self.restart_helper(scope, mock.Mock(), 100)
            with self.assertRaises(ValueError):
                restart()
            sub.run.assert_not_called()
            sub.Popen.assert_not_called()

    def scenario(self, fields):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "G17-script.toml"
            path.write_text('id="G17"\ntitle="script"\nconfig="language = en"\n' + fields, encoding="utf-8")
            return gx_wsl.load_gtk_scenario(path)

    def test_python_scenario_is_parsed_without_execution(self):
        case = self.scenario('script="raise RuntimeError(123)"\n')
        self.assertEqual("raise RuntimeError(123)", case.script)

    def test_script_and_xdotool_are_mutually_exclusive(self):
        with self.assertRaisesRegex(gx_wsl.GxWslError, "mutually exclusive"):
            self.scenario('script="pass"\nxdotool="sleep 1"\n')

    def test_invalid_python_is_rejected_before_launch(self):
        with self.assertRaisesRegex(gx_wsl.GxWslError, "invalid Python"):
            self.scenario('script="if (:"\n')


class SyncTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("git") is None:
            raise unittest.SkipTest("git is not installed")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.git(self.tmp, "init", "--quiet", "-b", "main", str(self.repo))
        self.git(self.repo, "config", "user.name", "t")
        self.git(self.repo, "config", "user.email", "t@example.org")
        self.git(self.repo, "config", "core.autocrlf", "false")
        (self.repo / ".gitignore").write_text("ignored/\n", encoding="utf-8")
        (self.repo / "a.txt").write_text("one\n", encoding="utf-8")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "--quiet", "-m", "one")
        self.head = self.git(self.repo, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def git(self, cwd: Path, *args: str) -> str:
        return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True).stdout.strip()

    def resolve(self, target: str | None, **options) -> gx_wsl.SyncTarget:
        with contextlib.redirect_stderr(io.StringIO()) as self.stderr:
            return gx_wsl.resolve_sync_target(target, repo_root=self.repo, **options)

    def test_ref(self) -> None:
        self.git(self.repo, "branch", "feature")
        target = self.resolve("feature")
        self.assertEqual(self.head, target.sha)
        self.assertEqual("ref feature", target.label)
        self.assertTrue(gx_wsl.same_path(self.repo, target.source))
        self.assertEqual(self.head, self.resolve(self.head[:10]).sha)

    def test_clean_worktree_defaults_to_the_repo_root(self) -> None:
        target = self.resolve(None)
        self.assertEqual(self.head, target.sha)
        self.assertFalse(target.uncommitted)
        self.assertIn("(main)", target.label)
        self.assertEqual("", self.stderr.getvalue())

    def test_dirty_worktree_without_dirty_syncs_head_and_says_so(self) -> None:
        (self.repo / "a.txt").write_text("two\n", encoding="utf-8")
        target = self.resolve(str(self.repo))
        self.assertEqual(self.head, target.sha)
        self.assertIn("--dirty", self.stderr.getvalue())

    def test_dirty_snapshot_keeps_the_worktree_untouched(self) -> None:
        (self.repo / "a.txt").write_text("two\n", encoding="utf-8")
        (self.repo / "new.txt").write_text("new\n", encoding="utf-8")
        (self.repo / "ignored").mkdir()
        (self.repo / "ignored" / "big.bin").write_text("x\n", encoding="utf-8")
        status_before = self.git(self.repo, "status", "--porcelain")
        target = self.resolve(str(self.repo), dirty=True)
        self.assertTrue(target.uncommitted)
        self.assertNotEqual(self.head, target.sha)
        self.assertEqual(self.head, self.git(self.repo, "rev-parse", f"{target.sha}^"))
        self.assertEqual("two", self.git(self.repo, "show", f"{target.sha}:a.txt"))
        self.assertEqual("new", self.git(self.repo, "show", f"{target.sha}:new.txt"))
        self.assertNotIn("ignored/big.bin", self.git(self.repo, "ls-tree", "-r", "--name-only", target.sha))
        self.assertEqual(status_before, self.git(self.repo, "status", "--porcelain"))
        self.assertEqual(self.head, self.git(self.repo, "rev-parse", "HEAD"))

    def test_dry_run_does_not_write_a_snapshot(self) -> None:
        (self.repo / "a.txt").write_text("two\n", encoding="utf-8")
        target = self.resolve(str(self.repo), dirty=True, dry_run=True)
        self.assertEqual("<snapshot>", target.sha)

    def test_linked_worktree_fetches_from_the_main_repository(self) -> None:
        linked = self.tmp / "linked"
        self.git(self.repo, "worktree", "add", "--quiet", "-b", "wip", str(linked))
        target = self.resolve(str(linked))
        self.assertEqual(self.head, target.sha)
        self.assertIn("(wip)", target.label)
        self.assertTrue(gx_wsl.same_path(self.repo, target.source))

    def test_rejections(self) -> None:
        (self.repo / "sub").mkdir()
        for target, options in (
            (str(self.repo / "sub"), {}),
            ("no-such-ref", {}),
            ("main", {"dirty": True}),
            ("--help", {}),
        ):
            with self.subTest(target=target), self.assertRaises(gx_wsl.GxWslError):
                self.resolve(target, **options)


class GtkScenarioTests(unittest.TestCase):
    BASE = 'id = "G90"\ntitle = "t"\nconfig = "language = en"\n'

    def load(self, body: str, name: str = "G90-x.toml") -> gx_wsl.GtkScenario:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / name
            path.write_text(self.BASE + body, encoding="utf-8")
            return gx_wsl.load_gtk_scenario(path)

    def test_the_gtk_scenarios_load(self) -> None:
        scenarios = [gx_wsl.load_gtk_scenario(path) for path in gx_wsl.gtk_scenario_paths([])]
        ids = [scenario.id for scenario in scenarios]
        self.assertGreaterEqual(len(ids), 6)
        self.assertEqual([f"G{number:02d}" for number in range(1, len(ids) + 1)], ids)
        for scenario in scenarios:
            with self.subTest(scenario=scenario.id):
                self.assertTrue(scenario.title)
                self.assertTrue(scenario.expect, "list what the screenshots must show")
                self.assertRegex(scenario.config, r"(?m)^language = (en|zh-CN)$")
                self.assertEqual(gx_wsl.SCENARIO_FORBID, scenario.forbid)

    def test_valid_scenario(self) -> None:
        scenario = self.load('lang = "zh_CN"\nwait = 5\nsettle = 1.5\nargs = ["--maximize"]\nexpect = ["x"]\n'
                             'forbid = ["boom"]\n[env]\nGSK_RENDERER = "cairo"\n')
        self.assertEqual(("zh_CN", 5.0, 1.5), (scenario.lang, scenario.wait, scenario.settle))
        self.assertEqual(("GSK_RENDERER=cairo",), scenario.env)
        self.assertEqual(("--maximize",), scenario.args)
        self.assertEqual(("boom",), scenario.forbid)

    def test_rejections(self) -> None:
        cases = {
            "unknown key": ('colour = "red"\n', "G90-x.toml"),
            "file name": ("", "G91-x.toml"),
            "lang": ('lang = "fr"\n', "G90-x.toml"),
            "env name": ('[env]\n"A-B" = "1"\n', "G90-x.toml"),
            "forbid regex": ('forbid = ["("]\n', "G90-x.toml"),
            "toml": ("wait = \n", "G90-x.toml"),
        }
        for case, (body, name) in cases.items():
            with self.subTest(case=case), self.assertRaises(gx_wsl.GxWslError):
                self.load(body, name)
        with self.assertRaises(gx_wsl.GxWslError):
            gx_wsl.gtk_scenario_paths(["G99"])

    def test_forbidden_lines(self) -> None:
        log = "ok\nGtk-WARNING: Theme parser error: gtk.css:3:1: x\nfine\nwarning(gtk): css parsing failed\n"
        self.assertEqual(2, len(gx_wsl.forbidden_lines(log, gx_wsl.SCENARIO_FORBID)))
        self.assertEqual([], gx_wsl.forbidden_lines("all good\n", gx_wsl.SCENARIO_FORBID))

    def test_runner_writes_inputs_notes_and_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first, second, third = root / "G01-a.toml", root / "G02-b.toml", root / "G03-c.toml"
            first.write_text('id = "G01"\ntitle = "first"\nconfig = "language = en"\nexpect = ["a.png: x"]\n',
                             encoding="utf-8")
            second.write_text('id = "G02"\ntitle = "second"\nconfig = "language = en"\nxdotool = "key ctrl+t"\n',
                              encoding="utf-8")
            third.write_text('id="G03"\ntitle="python"\nconfig="language = en"\nscript="capture(123)"\n', encoding="utf-8")
            logs = {"G01": "fine\n", "G02": "Theme parser error: <data>:1:2: boom\n", "G03": "fine\n"}

            def fake_execute(distro: str, invocation: gx_wsl.Invocation, *, dry_run: bool) -> int:
                target, name = Path(invocation.args[1]), invocation.args[7]
                (target / f"{name}.log").write_text(logs[name], encoding="utf-8")
                if name == "G03":
                    self.assertEqual(target / "script.py", Path(invocation.args[4]))
                return 0

            args = argparse.Namespace(clone=CLONE, distro="Ubuntu-24.04", dry_run=False, out=str(root / "out"),
                                      scenarios=[str(first), str(second), str(third)])
            with mock.patch.object(gx_wsl, "execute", side_effect=fake_execute), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = gx_wsl.run_gtk_scenarios(args)
            self.assertEqual(1, code)
            out = root / "out"
            self.assertEqual("language = en", (out / "G01" / "config.ghostty").read_text(encoding="utf-8"))
            self.assertFalse((out / "G01" / "script.xdo").exists())
            self.assertEqual("key ctrl+t", (out / "G02" / "script.xdo").read_text(encoding="utf-8"))
            self.assertEqual("# gx-scenario-python-v1\ncapture(123)", (out / "G03" / "script.py").read_text(encoding="utf-8"))
            self.assertFalse((out / "G03" / "script.xdo").exists())
            summary = (out / "SUMMARY.txt").read_text(encoding="utf-8")
            self.assertIn("G01 OK first", summary)
            self.assertIn("G02 FAILED (1 forbidden log lines", summary)
            self.assertIn("- a.png: x", (out / "G01" / "notes.txt").read_text(encoding="utf-8"))


class MainTests(unittest.TestCase):
    def run_main(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = gx_wsl.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_dry_run_prints_command_and_script(self) -> None:
        code, out, _ = self.run_main("build", "--gtk", "--dry-run", "-Doptimize=ReleaseFast")
        self.assertEqual(0, code)
        self.assertIn(
            "[gx-wsl] wsl.exe -d Ubuntu-24.04 --cd ~ -e bash -c <script> gx-wsl ~/src/gx_ghostty "
            "-Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -Doptimize=ReleaseFast",
            out,
        )
        self.assertIn('normal_build "$@"', out)
        self.assertIn('subprocess.run([sys.executable, "scripts/zigw.py", "build", *args]', out)
        self.assertIn("gtk-build-receipt.json", out)

    def test_setup_apt_runs_root_first(self) -> None:
        code, out, _ = self.run_main("--dry-run", "setup", "--apt")
        self.assertEqual(0, code)
        commands = [line for line in out.splitlines() if line.startswith("[gx-wsl] wsl.exe")]
        self.assertEqual(2, len(commands))
        self.assertIn(" -u root ", commands[0])
        self.assertNotIn(" -u root ", commands[1])

    def test_errors_exit_2(self) -> None:
        code, _, err = self.run_main("--clone", "C:/x", "build", "--dry-run")
        self.assertEqual(2, code)
        self.assertIn("--clone must be a Linux path", err)
        with mock.patch.object(gx_wsl.shutil, "which", return_value=None):
            code, _, err = self.run_main("build")
        self.assertEqual(2, code)
        self.assertIn("wsl.exe not found", err)
        code, _, _ = self.run_main("smoke")
        self.assertEqual(2, code)

    def test_shell_without_wsl_prints_instructions(self) -> None:
        with mock.patch.object(gx_wsl.shutil, "which", return_value=None):
            code, out, _ = self.run_main("shell")
        self.assertEqual(0, code)
        self.assertIn("wsl.exe -d Ubuntu-24.04", out)
        self.assertIn("python3 scripts/zigw.py build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell", out)
        self.assertIn('LD_LIBRARY_PATH="$PWD/zig-out/lib" ./zig-out/bin/ghostty', out)


if __name__ == "__main__":
    unittest.main()
