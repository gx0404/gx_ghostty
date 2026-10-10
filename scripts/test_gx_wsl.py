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
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_wsl  # noqa: E402

CLONE = "~/src/gx_ghostty"


def prefetch_namespace() -> dict:
    namespace: dict = {"__name__": "gx_wsl_prefetch"}
    exec(compile(gx_wsl.PREFETCH_PROGRAM, "gx_wsl_prefetch", "exec"), namespace)
    return namespace


def find_bash() -> str | None:
    """A real bash for `bash -n`; the WSL launcher under %SystemRoot% does not count."""
    system_root = os.path.normcase(os.environ.get("SystemRoot", r"C:\Windows"))
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry or (os.name == "nt" and os.path.normcase(os.path.abspath(entry)).startswith(system_root)):
            continue
        found = shutil.which("bash", path=entry)
        if found:
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
        for bad in ("A", "=x", "1A=x", "A-B=x", "A B=x", "A=x\ny", "A=x\ry"):
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
        script = all_invocations()["smoke"].script
        self.assertIn(f"-screen 0 {gx_wsl.SMOKE_SCREEN}", workflow)
        self.assertIn("export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1", workflow)
        self.assertIn("export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1", script)
        self.assertIn("xvfb-run --auto-servernum", script)
        self.assertIn("--gtk-single-instance=false", script)
        self.assertIn("ghostty --gtk-single-instance=false", workflow)

    def test_smoke_waits_for_the_window_instead_of_a_fixed_delay(self) -> None:
        script = all_invocations()["smoke"].script
        self.assertIn('found=$(xdotool search --onlyvisible --pid "$pid" 2>/dev/null) || found=', script)
        self.assertIn("sleep 0.05", script)
        self.assertNotIn("--sync", script)
        self.assertIn('if [ -n "$window" ] || ! alive "$pid"; then', script)
        self.assertIn('sleep "$settle"', script)
        self.assertNotIn('sleep "$wait_seconds"', script)
        for tool in ("xvfb-run", "xauth", "scrot", "xdotool"):
            self.assertIn(tool, script.split("for tool in ", 1)[1].split(";", 1)[0])
        self.assertIn("xdotool", gx_wsl.APT_PACKAGES)

    def test_perf_report_function_is_embedded_once(self) -> None:
        function = gx_wsl.perf_function()
        self.assertIn(gx_wsl.PERF_PROGRAM.strip(), function)
        self.assertEqual(1, function.splitlines().count(gx_wsl.PERF_DELIMITER))
        script = all_invocations()["smoke-perf"].script
        self.assertIn(function, script)
        self.assertIn("export GHOSTTY_GX_PERF=1", script)
        self.assertIn('-e sh "$work/workload.sh"', script)
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

    @unittest.skipUnless(find_bash(), "needs a bash for `bash -n`")
    def test_scripts_parse(self) -> None:
        bash = find_bash()
        assert bash is not None
        for name, invocation in all_invocations().items():
            with self.subTest(script=name):
                # stdin, not -c: an MSYS bash would re-parse a Windows command line argument.
                result = subprocess.run(
                    [bash, "-n"], input=invocation.script, capture_output=True, text=True, encoding="utf-8", check=False
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


def stat_line(tid: int, comm: str, minflt: int, majflt: int, utime: int, stime: int) -> str:
    fields = ["S", "1", "1", "1", "0", "-1", "4194560", str(minflt), "0", str(majflt), "0", str(utime), str(stime)]
    return f"{tid}\t{tid} ({comm}) {' '.join(fields + ['0'] * 39)}"


class PerfProgramTests(unittest.TestCase):
    def setUp(self) -> None:
        self.program = perf_namespace()

    def test_parse_tasks_reads_names_with_spaces_and_parentheses(self) -> None:
        text = "\n".join((stat_line(10, "ghostty", 5, 1, 100, 20), stat_line(11, "a) b", 7, 0, 3, 4), "12\t", "13\tgarbage"))
        tasks = self.program["parse_tasks"](text)
        self.assertEqual({"10", "11"}, set(tasks))
        self.assertEqual({"comm": "a) b", "minflt": 7, "majflt": 0, "utime": 3, "stime": 4}, tasks["11"])

    def test_report_groups_threads_and_counts_log_lines(self) -> None:
        before = "\n".join((stat_line(10, "ghostty", 100, 1, 50, 10), stat_line(11, "renderer", 10, 0, 20, 5),
                            stat_line(12, "io", 0, 0, 1, 1), stat_line(14, "pool-0", 0, 0, 0, 0),
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
        self.assertEqual(["cpu.main", "cpu.renderer", "cpu.io", "cpu.llvmpipe", "cpu.total"], cpu)
        rows = {line.split()[0]: line.split()[1] for line in lines if line and not line.startswith(("metric", "#"))
                and ":" not in line.split()[0]}
        self.assertEqual("2", rows["llvmpipe"])
        self.assertEqual("1", rows["dconf_worker"])
        self.assertIn("threads that exited during the workload (not counted): 14", report)
        unfinished = self.program["report"](before, after, "pid 10\nworkload_finished 0\n", "", 100)
        self.assertIn("finished: no", unfinished)

    def test_main_reads_files_and_fails_without_statistics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = [Path(tmp) / name for name in ("before", "after", "times", "log")]
            for path, text in zip(paths, (stat_line(1, "ghostty", 0, 0, 0, 0), stat_line(1, "ghostty", 0, 0, 7, 3),
                                          "pid 1\n", "")):
                path.write_text(text, encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(0, self.program["main"](["-", *map(str, paths)]))
            self.assertIn("metric cpu.main", out.getvalue())
            paths[1].write_text("", encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(1, self.program["main"](["-", *map(str, paths)]))


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
            first, second = root / "G01-a.toml", root / "G02-b.toml"
            first.write_text('id = "G01"\ntitle = "first"\nconfig = "language = en"\nexpect = ["a.png: x"]\n',
                             encoding="utf-8")
            second.write_text('id = "G02"\ntitle = "second"\nconfig = "language = en"\nxdotool = "key ctrl+t"\n',
                              encoding="utf-8")
            logs = {"G01": "fine\n", "G02": "Theme parser error: <data>:1:2: boom\n"}

            def fake_execute(distro: str, invocation: gx_wsl.Invocation, *, dry_run: bool) -> int:
                target, name = Path(invocation.args[1]), invocation.args[7]
                (target / f"{name}.log").write_text(logs[name], encoding="utf-8")
                return 0

            args = argparse.Namespace(clone=CLONE, distro="Ubuntu-24.04", dry_run=False, out=str(root / "out"),
                                      scenarios=[str(first), str(second)])
            with mock.patch.object(gx_wsl, "execute", side_effect=fake_execute), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = gx_wsl.run_gtk_scenarios(args)
            self.assertEqual(1, code)
            out = root / "out"
            self.assertEqual("language = en", (out / "G01" / "config.ghostty").read_text(encoding="utf-8"))
            self.assertFalse((out / "G01" / "script.xdo").exists())
            self.assertEqual("key ctrl+t", (out / "G02" / "script.xdo").read_text(encoding="utf-8"))
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
        self.assertIn("exec python3 scripts/zigw.py build", out)

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
