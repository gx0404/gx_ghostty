#!/usr/bin/env python3
"""Tests for scripts/gx_win_gui.py: chords, coordinates, isolation, PNG output, the scenario files and
the input guard. Nothing here starts Ghostty or sends input; the Win32 backend is replaced by a fake.
"""

from __future__ import annotations

import contextlib
import io
import itertools
import struct
import json
import os
import re
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import gx_win_gui as gui  # noqa: E402

# The R0 acceptance checks every Windows scenario set must keep covering (W01-W15).
R0_COVERAGE = {
    "W01": "title-override", "W02": "edit-keys", "W03": "search-highlight", "W04": "split-focus",
    "W05": "palette-preview", "W06": "ctrl-click", "W07": "startup-failure", "W08": "clipboard",
    "W09": "wsl-focus", "W10": "wsl-horizontal-wheel", "W11": "wsl-side-buttons", "W12": "capture-loss",
    "W13": "quick-terminal", "W14": "opacity", "W15": "goto-and-move-tab",
}


class ChordTests(unittest.TestCase):
    def test_modifiers_and_keys(self):
        self.assertEqual(([0x11, 0x10], ord("T")), gui.parse_chord("ctrl+shift+t"))
        self.assertEqual(([0x12], 0x73), gui.parse_chord("Alt+F4"))
        self.assertEqual(([0x11], 0xC0), gui.parse_chord("ctrl+grave"))
        self.assertEqual(([], 0x87), gui.parse_chord("f24"))
        self.assertEqual(([], 0x63), gui.parse_chord("numpad3"))
        self.assertEqual(([0x11, 0x10], 0x21), gui.parse_chord("ctrl+shift+page_up"))
        self.assertEqual(([0x11], ord("9")), gui.parse_chord("control+9"))
        self.assertEqual(([0x11], ord("A")), gui.parse_chord("ctrl+ctrl+a"))

    def test_layout_dependent_oem_keys(self):
        self.assertEqual(([], 0xE2), gui.parse_chord("oem102"))
        self.assertEqual(([0x10], 0xDC), gui.parse_chord("shift+oem5"))
        self.assertEqual([0xBA, 0xBF, 0xC0, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF],
                         [gui.parse_chord(f"oem{index}")[1] for index in range(1, 9)])
        with self.assertRaises(gui.UsageError):
            gui.parse_chord("oem9")

    def test_rejections(self):
        for chord in ("", "ctrl+", "+a", "hyper+a", "ctrl+f25", "ctrl+nosuchkey"):
            with self.subTest(chord=chord), self.assertRaises(gui.UsageError):
                gui.parse_chord(chord)

    def test_utf16_units(self):
        self.assertEqual([0x61], gui.utf16_units("a"))
        self.assertEqual([0x4E2D], gui.utf16_units("中"))
        self.assertEqual([0xD83D, 0xDE00], gui.utf16_units("\U0001F600"))


class GeometryTests(unittest.TestCase):
    ANCHOR = (100, 200, 1100, 800)  # 1000 x 600 physical pixels

    def test_resolve_point(self):
        self.assertEqual((600, 500), gui.resolve_point(None, None, self.ANCHOR, 1.5))
        self.assertEqual((115, 230), gui.resolve_point(10, 20, self.ANCHOR, 1.5))
        self.assertEqual((1070, 785), gui.resolve_point(-20, -10, self.ANCHOR, 1.5))
        self.assertEqual((350, 320), gui.resolve_point("25%", "20%", self.ANCHOR, 2.0))
        with self.assertRaises(gui.UsageError):
            gui.resolve_point("left", 0, self.ANCHOR, 1.0)

    def test_normalize_absolute_on_a_desktop_left_of_the_primary(self):
        virtual = (-3840, -419, 7680, 2579)
        self.assertEqual((0, 0), gui.normalize_absolute(-3840, -419, virtual))
        self.assertEqual((65535, 65535), gui.normalize_absolute(3839, 2159, virtual))
        x, y = gui.normalize_absolute(0, 0, virtual)
        self.assertAlmostEqual(32772, x, delta=2)
        self.assertAlmostEqual(10652, y, delta=2)

    def test_rect_gap(self):
        self.assertEqual(("vertical", 503, (0, 400)), gui.rect_gap((0, 0, 500, 400), (506, 0, 1000, 600)))
        self.assertEqual(("horizontal", 302, (500, 1000)), gui.rect_gap((500, 0, 1000, 300), (500, 305, 1000, 600)))
        self.assertEqual(gui.rect_gap((506, 0, 1000, 600), (0, 0, 500, 400)), gui.rect_gap((0, 0, 500, 400), (506, 0, 1000, 600)))
        for a, b in (((0, 0, 10, 10), (5, 5, 20, 20)), ((0, 0, 10, 10), (20, 20, 30, 30))):
            with self.subTest(a=a, b=b), self.assertRaises(gui.GuiError):
                gui.rect_gap(a, b)

    def test_colors(self):
        self.assertEqual((0x2E, 0x34, 0x40), gui.parse_color("#2e3440"))
        self.assertEqual((0x1F, 0x1F, 0x28), gui.parse_color("1F1F28"))
        self.assertEqual("#2e3440", gui.color_hex((46, 52, 64)))
        self.assertTrue(gui.color_close((10, 20, 30), (11, 19, 30), 1))
        self.assertFalse(gui.color_close((10, 20, 30), (12, 20, 30), 1))
        for bad in ("#12345", "red", "#1234567"):
            with self.subTest(color=bad), self.assertRaises(gui.UsageError):
                gui.parse_color(bad)


class IsolationTests(unittest.TestCase):
    def test_launch_resolves_relative_isolation_before_changing_child_cwd(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            exe = directory / "ghostty.exe"
            exe.write_bytes(b"fixture")
            environment = directory / "env"
            environment.mkdir()
            relative_exe = Path("ghostty.exe")
            relative_environment = Path("env")
            native = mock.Mock()
            native.now_filetime.return_value = 1
            native.process_creation.return_value = 2
            with mock.patch.object(gui, "win32", return_value=native), mock.patch.object(gui.subprocess, "Popen") as popen:
                popen.return_value.pid = 123
                previous = Path.cwd()
                try:
                    os.chdir(directory)
                    gui.launch(relative_exe, relative_environment)
                finally:
                    os.chdir(previous)
            args, options = popen.call_args
            self.assertEqual(args[0][0], str(exe.resolve()))
            self.assertEqual(options["cwd"], str(environment.resolve()))
            self.assertEqual(options["env"]["LOCALAPPDATA"], str(environment.resolve()))
            self.assertEqual(options["env"]["XDG_CONFIG_HOME"], str(environment.resolve()))

    def test_isolated_environment(self):
        base = {"PATH": "C:/bin", "NO_COLOR": "1", "TERM": "dumb", "ColorTerm": "truecolor", "TERM_PROGRAM": "x",
                "GHOSTTY_RESOURCES_DIR": "r", "ghostty_gx_opengl": "software", "LocalAppData": "C:/real",
                "XDG_CONFIG_HOME": "C:/real/xdg", "HOME": "C:/h"}
        env = gui.isolated_environment(base, Path("E:/ev/env"), {"GHOSTTY_GX_OPENGL": "software"})
        self.assertEqual({"PATH": "C:/bin", "HOME": "C:/h", "LOCALAPPDATA": str(Path("E:/ev/env")),
                          "APPDATA": str(Path("E:/ev/env/appdata")),
                          "XDG_CONFIG_HOME": str(Path("E:/ev/env")),
                          "XDG_STATE_HOME": str(Path("E:/ev/env/state")),
                          "XDG_CACHE_HOME": str(Path("E:/ev/env/cache")),
                          "GHOSTTY_GX_OPENGL": "software"}, env)

    def test_state_cache_and_roaming_paths_ignore_inherited_case_variants(self):
        root = Path("E:/ev/env")
        base = {"AppData": "C:/real/roaming", "xdg_state_home": "C:/real/state",
                "Xdg_Cache_Home": "C:/real/cache", "LocalAppData": "C:/real/local",
                "xdg_config_home": "C:/real/config", "PATH": "C:/bin"}
        original = dict(base)
        env = gui.isolated_environment(base, root)
        expected = {"LOCALAPPDATA": root, "APPDATA": root / "appdata", "XDG_CONFIG_HOME": root,
                    "XDG_STATE_HOME": root / "state", "XDG_CACHE_HOME": root / "cache"}
        for name, path in expected.items():
            with self.subTest(name=name):
                self.assertEqual(str(path), env[name])
                self.assertEqual([name], [key for key in env if key.upper() == name])
        self.assertEqual(original, base)

    def test_explicit_environment_cannot_escape_private_profile_paths(self):
        for name in ("LOCALAPPDATA", "APPDATA", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
            for key in (name, name.lower()):
                with self.subTest(key=key), self.assertRaisesRegex(gui.UsageError, rf"cannot override the isolated "
                                                                                   rf"path variable {key}$"):
                    gui.isolated_environment({}, Path("E:/ev/env"), {key: "C:/outside"})

    def test_env_assignments(self):
        self.assertEqual({"A": "1=2", "B_": ""}, gui.env_assignments(["A=1=2", "B_="]))
        for bad in ("A", "=1", "1A=2", "A-B=1"):
            with self.subTest(value=bad), self.assertRaises(gui.UsageError):
                gui.env_assignments([bad])

    def test_profile_paths_and_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / "env"
            path = gui.write_config(env, "a = 1\r\nb = 2\n")
            self.assertEqual(env / "ghostty" / "config.ghostty", path)
            self.assertEqual(b"a = 1\nb = 2\n", path.read_bytes())
            self.assertEqual(env / "ghostty" / "logs" / "ghostty.log", gui.log_path(env))

    def test_prepare_env_dir_only_empties_its_own_profiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            foreign = Path(tmp) / "foreign"
            foreign.mkdir()
            (foreign / "keep.txt").write_text("x", encoding="utf-8")
            with self.assertRaises(gui.UsageError):
                gui.prepare_env_dir(foreign, fresh=True)
            self.assertTrue((foreign / "keep.txt").is_file())
            own = Path(tmp) / "own"
            gui.prepare_env_dir(own, fresh=True)
            (own / "old.txt").write_text("x", encoding="utf-8")
            gui.prepare_env_dir(own, fresh=True)
            self.assertFalse((own / "old.txt").exists())
            self.assertTrue((own / gui.ENV_MARKER).is_file())


class ImageTests(unittest.TestCase):
    def test_png_bytes_round_trip(self):
        rgb = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30])
        data = gui.png_bytes(2, 2, rgb)
        self.assertEqual(b"\x89PNG\r\n\x1a\n", data[:8])
        length, kind = struct.unpack(">I4s", data[8:16])
        self.assertEqual((13, b"IHDR"), (length, kind))
        self.assertEqual((2, 2, 8, 2, 0, 0, 0), struct.unpack(">IIBBBBB", data[16:29]))
        idat = data.index(b"IDAT")
        size = struct.unpack(">I", data[idat - 4:idat])[0]
        raw = zlib.decompress(data[idat + 4:idat + 4 + size])
        self.assertEqual(b"\x00" + rgb[:6] + b"\x00" + rgb[6:], raw)
        self.assertTrue(data.endswith(b"IEND\xaeB`\x82"))
        with self.assertRaises(ValueError):
            gui.png_bytes(3, 2, rgb)

    def test_image_pixels_and_crop(self):
        bgra = bytes([0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 30, 20, 10, 255])
        image = gui.Image(2, 2, bgra, left=-100, top=50)
        self.assertEqual((255, 0, 0), image.pixel(-100, 50))
        self.assertEqual((10, 20, 30), image.pixel(-99, 51))
        self.assertEqual(bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30]), image.rgb())
        with self.assertRaises(gui.GuiError):
            image.pixel(0, 0)
        part = gui.crop(image, (-99, 0, 500, 51))
        self.assertEqual((1, 1, -99, 50), (part.width, part.height, part.left, part.top))
        self.assertEqual((0, 255, 0), part.pixel(-99, 50))
        with self.assertRaises(gui.GuiError):
            gui.crop(image, (0, 0, 10, 10))


class ScenarioFileTests(unittest.TestCase):
    def test_the_windows_scenarios_cover_the_r0_checks(self):
        paths = gui.scenario_paths([])
        scenarios = [gui.load_scenario(path) for path in paths]
        ids = [scenario.id for scenario in scenarios]
        self.assertEqual([f"W{number:02d}" for number in range(1, len(ids) + 1)], ids)
        self.assertLessEqual(R0_COVERAGE.keys(), set(ids))
        for scenario in scenarios:
            with self.subTest(scenario=scenario.id):
                if scenario.id in R0_COVERAGE:
                    self.assertIn(R0_COVERAGE[scenario.id], scenario.path.name)
                self.assertTrue(scenario.expect, "list what the screenshots must show")
                self.assertTrue(scenario.title)
                self.assertTrue(scenario.full_config().endswith(gui.HARNESS_CONFIG))
                self.assertRegex(scenario.config, r"(?m)^language = (en|zh-CN)$")
                for requirement in scenario.requires:
                    self.assertRegex(requirement, r"^(wsl:|file:|windows-build:)")

    def test_selectors(self):
        self.assertEqual("W03", gui.load_scenario(gui.scenario_paths(["W03"])[0]).id)
        with self.assertRaises(gui.UsageError):
            gui.scenario_paths(["W99"])


class ScenarioValidationTests(unittest.TestCase):
    BASE = 'id = "W90"\ntitle = "t"\nconfig = "language = en"\n'

    def load(self, body: str, name: str = "W90-x.toml"):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / name
            path.write_text(self.BASE + body, encoding="utf-8")
            return gui.load_scenario(path)

    def test_valid_scenario(self):
        scenario = self.load('harness = false\n[[step]]\naction = "key"\nkeys = "ctrl+shift+t"\n'
                             '[[step]]\naction = "capture"\nname = "x"\nwhat = "all"\n')
        self.assertEqual(["key", "capture"], [step.action for step in scenario.steps])
        self.assertEqual("language = en\n", scenario.full_config())

    def test_the_file_header_documents_every_action(self):
        header = gui.__doc__ or ""
        steps = header[header.index("\nScenario files:"):]
        steps = steps[:steps.index("\n\n", 1)]
        for action in gui.ACTIONS:
            with self.subTest(action=action):
                self.assertRegex(steps, rf"(?m)^  (?:.*\s)?{action}\b")

    def test_rejections(self):
        capture = '[[step]]\naction = "capture"\nname = "x"\n'
        cases = {
            "unknown action": '[[step]]\naction = "explode"\n' + capture,
            "needs keys": '[[step]]\naction = "key"\n' + capture,
            "does not take": '[[step]]\naction = "sleep"\nseconds = 1\nfoo = 2\n' + capture,
            "unknown key": '[[step]]\naction = "key"\nkeys = "ctrl+nope"\n' + capture,
            "bad color": '[[step]]\naction = "pixel"\nexpect = "blue"\n' + capture,
            "capture at least one": '[[step]]\naction = "sleep"\nseconds = 1\n',
            "unknown keys": 'colour = 1\n' + capture,
            "button": '[[step]]\naction = "click"\nbutton = "x3"\n' + capture,
            "what": '[[step]]\naction = "capture"\nname = "x"\nwhat = "desktop"\n',
            "pattern": '[[step]]\naction = "wait_log"\npattern = "("\n' + capture,
        }
        for expected, body in cases.items():
            with self.subTest(case=expected), self.assertRaisesRegex(gui.UsageError, expected):
                self.load(body)
        with self.assertRaisesRegex(gui.UsageError, "file name"):
            self.load(capture, name="W91-x.toml")


class RequirementTests(unittest.TestCase):
    def test_requirements(self):
        distros = lambda: ["Ubuntu-24.04", "docker-desktop"]  # noqa: E731
        self.assertIsNone(gui.missing_requirement("wsl:Ubuntu-24.04", distros))
        self.assertIn("not installed", gui.missing_requirement("wsl:Debian", distros))
        self.assertIn("does not exist", gui.missing_requirement("file:Z:/no/such/file", distros))
        self.assertIsNone(gui.missing_requirement("windows-build:0", distros))
        self.assertIn("older than", gui.missing_requirement("windows-build:999999", distros))
        self.assertIn("unknown requirement", gui.missing_requirement("gpu:nvidia", distros))


class WaitFileTests(unittest.TestCase):
    def test_the_whole_text_must_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.txt"
            run = gui.ScenarioRun(None, Path("ghostty.exe"), Path(tmp))  # type: ignore[arg-type]
            step = {"path": str(path), "pattern": r"\A\^\[\[O\^\[\[I\Z", "timeout": 0.2}
            with self.assertRaisesRegex(gui.GuiError, "missing"):
                run.do_wait_file(step)
            path.write_text("^[[O^[[I^[[O", encoding="utf-8")
            with self.assertRaisesRegex(gui.GuiError, "holds"):
                run.do_wait_file(step)
            path.write_text("^[[O^[[I", encoding="utf-8")
            self.assertIn("out.txt", run.do_wait_file(step))

    def test_validation(self):
        self.assertEqual("wait_file", gui.validate_step("s", {"action": "wait_file", "path": "p", "pattern": "x"}).action)
        self.assertEqual("wait_file", gui.validate_step("s", {"action": "wait_file", "path": "{log}", "pattern": "x"}).action)
        for raw in ({"action": "wait_file", "path": "p"}, {"action": "wait_file", "path": "p", "pattern": "("},
                    {"action": "wait_file", "path": "{logs}", "pattern": "x"}, {"action": "wait_file", "path": 7, "pattern": "x"}):
            with self.subTest(raw=raw), self.assertRaises(gui.UsageError):
                gui.validate_step("s", raw)


class PathPlaceholderTests(unittest.TestCase):
    VALUES = {"env": "C:/out/W14/env", "log": "C:/out/W14/env/ghostty/logs/ghostty.log"}

    def test_placeholders_literal_braces_and_environment_variables(self):
        values = self.VALUES
        self.assertEqual(values["log"], gui.expand_path("{log}", values, "w"))
        self.assertEqual("C:/out/W14/env/shell/done.txt", gui.expand_path("{env}/shell/done.txt", values, "w"))
        self.assertEqual("C:/{GUID}/x", gui.expand_path("C:/{{GUID}}/x", values, "w"))
        with mock.patch.dict(os.environ, {"GX_PH_DIR": "D:/data", "GX_PH_NAME": "marker.txt"}):
            # Environment variables still expand around the placeholders, after them.
            self.assertEqual("D:/data/marker.txt", gui.expand_path("${GX_PH_DIR}/$GX_PH_NAME", values, "w"))
            self.assertEqual("C:/out/W14/env/marker.txt", gui.expand_path("{env}/${GX_PH_NAME}", values, "w"))
            if os.name == "nt":  # %NAME% is the Windows syntax of os.path.expandvars
                self.assertEqual("D:/data/marker.txt", gui.expand_path("%GX_PH_DIR%/%GX_PH_NAME%", values, "w"))
                self.assertEqual("C:/out/W14/env/marker.txt", gui.expand_path("{env}/%GX_PH_NAME%", values, "w"))
            # Values and literal braces are inserted verbatim: a $ or % inside them is never expanded again.
            odd = {"env": "C:/50%GX_PH_NAME%/$GX_PH_DIR", "log": "L"}
            self.assertEqual("C:/50%GX_PH_NAME%/$GX_PH_DIR/x", gui.expand_path("{env}/x", odd, "w"))
            self.assertEqual("{GX_PH_DIR}", gui.expand_path("{{GX_PH_DIR}}", values, "w"))

    def test_unknown_placeholders_and_unbalanced_braces_are_errors(self):
        for template, message in (("{logs}", "unknown placeholder {logs}"), ("{}", "unknown placeholder {}"),
                                  ("a{b", "unbalanced '{'"), ("a}b", "unbalanced '}'"), ("{{log}", "unbalanced '}'")):
            with self.subTest(template=template), self.assertRaisesRegex(gui.UsageError, re.escape(message)):
                gui.expand_path(template, self.VALUES, "w")
        with self.assertRaisesRegex(gui.UsageError, "not available here"):
            gui.expand_path("{log}", {}, "requires")

    def test_wait_file_reads_the_instance_log_through_the_placeholder(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "W14"
            env = out / "env"
            log = gui.log_path(env)
            log.parent.mkdir(parents=True)
            log.write_text("info(gx_perf): metric renderer.targets_live 2\n", encoding="utf-8")
            run = gui.ScenarioRun(None, Path("ghostty.exe"), out)  # type: ignore[arg-type]
            # Before the instance exists the placeholders name OUT/env; afterwards the instance's profile.
            self.assertEqual({"env": str(env.resolve()), "log": str(log.resolve())}, run.path_values())
            self.assertIn("ghostty.log", run.do_wait_file({"path": "{log}", "pattern": r"targets_live 2", "timeout": 0.2}))
            (env / "marker.txt").write_text("done", encoding="utf-8")
            run.instance = mock.Mock(env_dir=env)
            self.assertIn("marker.txt", run.do_wait_file({"path": "{env}/marker.txt", "pattern": "done", "timeout": 0.2}))
            with self.assertRaisesRegex(gui.GuiError, re.escape(str(log.resolve()))):
                run.do_wait_file({"path": "{log}", "pattern": "never", "timeout": 0.1})

    def test_scenarios_check_placeholders_when_they_load(self):
        head = 'id = "W98"\ntitle = "t"\nconfig = ""\n'
        capture = '[[step]]\naction = "capture"\nname = "c"\n'
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W98-placeholders.toml"

            def load(requires: str, wait_path: str):
                path.write_text(head + requires + '[[step]]\naction = "wait_file"\npath = ' + wait_path +
                                "\npattern = 'x'\n" + capture, encoding="utf-8")
                return gui.load_scenario(path)

            scenario = load("requires = ['file:C:/{{GUID}}/x']\n", "'{log}'")
            self.assertEqual(["file:C:/{{GUID}}/x"], scenario.requires)
            self.assertIn("does not exist", gui.missing_requirement(scenario.requires[0], lambda: []))
            with self.assertRaisesRegex(gui.UsageError, re.escape("unknown placeholder {logs}")):
                load("", "'{logs}'")
            # requires is checked before the run, when this scenario's own profile does not exist yet.
            with self.assertRaisesRegex(gui.UsageError, "not available here"):
                load("requires = ['file:{log}']\n", "'{log}'")
            with tempfile.TemporaryDirectory() as host:
                (Path(host) / "{marker}.txt").write_text("x", encoding="utf-8")
                with mock.patch.dict(os.environ, {"GX_PH_HOST": host}):
                    self.assertIsNone(gui.missing_requirement("file:${GX_PH_HOST}/{{marker}}.txt", lambda: []))


class CaptureTests(unittest.TestCase):
    def runner(self, out_dir: Path, classes: list[str]) -> gui.ScenarioRun:
        run = gui.ScenarioRun(None, Path("ghostty.exe"), out_dir)  # type: ignore[arg-type]
        run.instance = mock.Mock(spec=gui.Instance)
        run.instance.require_window.return_value = gui.WindowInfo(0, gui.WINDOW_CLASS, "main", (0, 0, 1, 1),
                                                                 True, False, False)
        run.instance.popups.return_value = [gui.WindowInfo(index, cls, "popup", (0, 0, 1, 1), True, False, True)
                                            for index, cls in enumerate(classes, 1)]
        run.instance.capture_window.side_effect = lambda info, method: gui.Image(1, 1, bytes((info.hwnd, 0, 0, 255)))
        return run

    def test_native_task_dialog_capture_keeps_the_real_class(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            run = self.runner(out, ["#32770"])
            main = run.gui.require_window.return_value
            popup = run.gui.popups.return_value[0]
            result = run.do_capture({"name": "native", "what": "all"})
            self.assertEqual(["01-native.png", "01-native-_23_32770-1.png"], run.captures)
            self.assertEqual(", ".join(run.captures), result)
            self.assertTrue(all((out / name).is_file() for name in run.captures))
            self.assertEqual(1, run.capture_steps)
            run.gui.capture_window.assert_has_calls([mock.call(main, "screen"), mock.call(popup, "screen")])
            self.assertEqual("#32770", popup.cls)
            self.assertIn("#32770", run.do_wait_popup({"cls": "#32770"}))

    def test_plain_popup_file_names_are_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = self.runner(Path(tmp), ["GhosttyGxPopupShadow"])
            run.do_capture({"name": "popup", "what": "popups", "method": "print"})
            self.assertEqual(["01-popup-GhosttyGxPopupShadow-1.png"], run.captures)
            run.gui.capture_window.assert_called_once_with(run.gui.popups.return_value[0], "print")

    def test_internal_class_fragments_stay_ascii_and_inside_out(self):
        classes = ["#32770", "弹窗😀", "../outside\\evil", "", "/", "\\", "\x00\n\r\t:*?\"<>|", "\ud800"]
        with tempfile.TemporaryDirectory() as tmp:
            for cls in classes:
                with self.subTest(cls=cls):
                    out = Path(tmp) / "out"
                    run = self.runner(out, [cls])
                    run.do_capture({"name": "popup", "what": "popups"})
                    run.do_capture({"name": "popup", "what": "popups"})
                    first, second = run.captures
                    self.assertRegex(first, r"\A01-popup-[A-Za-z0-9._-]+-1\.png\Z")
                    self.assertEqual(first[3:], second[3:])
                    for name in run.captures:
                        path = out / name
                        self.assertEqual(out.resolve(), path.resolve().parent)
                        self.assertTrue(path.is_file())
                    self.assertEqual(cls, run.gui.popups.return_value[0].cls)
            self.assertTrue(all(path.parent == out for path in Path(tmp).rglob("*.png")))

    def test_duplicate_and_encoded_classes_do_not_overwrite_popups(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            classes = ["#32770", "#32770", "_23_32770", "", "unknown"]
            run = self.runner(out, classes)
            run.do_capture({"name": "popup", "what": "popups"})
            self.assertEqual(len(classes), len(set(run.captures)))
            self.assertEqual(len(classes), len({(out / name).read_bytes() for name in run.captures}))
            for index, name in enumerate(run.captures, 1):
                self.assertTrue(name.endswith(f"-{index}.png"))
            self.assertEqual(classes, [info.cls for info in run.gui.popups.return_value])

    def test_user_capture_names_remain_strictly_validated(self):
        bad_names = ["", ".hidden", "-name", "_name", "../escape", "a/b", "a\\b", "a#b", "弹窗", "a b", "a\n",
                     "a\x00", "a:b", "a*", "a?", "a\"", "a<", "a>", "a|", "\ud800"]
        with tempfile.TemporaryDirectory() as tmp:
            for what in ("window", "quick", "popups", "all"):
                for name in bad_names:
                    with self.subTest(what=what, name=name):
                        run = self.runner(Path(tmp), ["GhosttyGxPopupShadow"])
                        with self.assertRaises(gui.UsageError):
                            run.do_capture({"name": name, "what": what})
                        self.assertEqual([], run.captures)
                        self.assertEqual(0, run.capture_steps)
            self.assertEqual([], list(Path(tmp).rglob("*.png")))


class FakeWin32:
    """Stands in for Win32: windows of other processes are in front; every SendInput is recorded."""

    def __init__(self, foreground_pid: int, point_pid: int) -> None:
        self.foreground_pid = foreground_pid
        self.point_pid = point_pid
        self.sent: list = []
        self.alive = True
        self.image = "C:/g/ghostty.exe"
        self.creation = 1
        self.stack: list = []  # window_stack(), top to bottom
        self.answers: dict = {}  # message -> what send_message returns (None: no answer)
        self.messages: list = []
        self.tops: list = []  # top_windows(pid)
        self.hung_windows: set = set()  # IsHungAppWindow
        self.layouts = [0x08040804, 0x04090409]  # GetKeyboardLayoutList, raw
        self.layout = 0x08040804  # the window thread's layout
        self.layout_follows = True  # a WM_INPUTLANGCHANGEREQUEST switches it
        self.requests: list = []
        self.loaded: list = []
        self.unloaded: list = []
        self.monitor_layout = [((0, 0, 1000, 800), (0, 0, 1000, 800))]  # monitors(): (monitor, work area)

    def process_alive(self, pid):
        return self.alive

    def process_image(self, pid):
        return self.image

    def process_creation(self, pid):
        return self.creation

    def foreground(self):
        return 0x1000

    def window_at(self, x, y):
        return 0x2000

    def window_pid(self, hwnd):
        return self.foreground_pid if hwnd == 0x1000 else self.point_pid

    def root_owner_pid(self, hwnd):
        return self.window_pid(hwnd)

    def class_name(self, hwnd):
        return "Chrome_WidgetWin_1"

    def key_input(self, vk, up):
        return ("key", vk, up)

    def unicode_input(self, unit, up):
        return ("unicode", unit, up)

    def mouse_input(self, flags, x=0, y=0, data=0):
        return ("mouse", flags, x, y, data)

    def top_windows(self, pid):
        return list(self.tops)

    def window_stack(self):
        return list(self.stack)

    def hung(self, hwnd):
        return hwnd in self.hung_windows

    def monitors(self):
        return list(self.monitor_layout)

    def current_user_sid(self):
        return "S-1-5-21-1"

    def PostMessageW(self, hwnd, message, wparam, lparam):
        self.messages.append((hwnd, message, wparam, lparam))
        return True

    def terminate(self, pid):
        self.terminated = [*getattr(self, "terminated", []), pid]
        self.alive = False
        return True

    def child_processes(self, pid):
        return []

    def keyboard_layouts(self):
        return list(self.layouts)

    def keyboard_layout(self, hwnd):
        return self.layout & 0xFFFFFFFF

    def request_layout(self, hwnd, hkl):
        self.requests.append(hkl)
        if self.layout_follows:
            self.layout = hkl

    def load_layout(self, klid):
        self.loaded.append(klid)
        value = int(klid, 16)
        hkl = (value << 16) | value if value >> 16 == 0 else 0xF0020000 | (value & 0xFFFF)
        if hkl not in self.layouts:
            self.layouts.append(hkl)
        return hkl

    def unload_layout(self, hkl):
        self.unloaded.append(hkl)
        self.layouts.remove(hkl)
        return True

    def LoadKeyboardLayoutW(self, *args):
        raise AssertionError(f"LoadKeyboardLayoutW{args} must not be called")

    def send_message(self, hwnd, message, wparam=0, lparam=0, timeout_ms=5000):
        self.messages.append((hwnd, message, wparam, lparam))
        answer = self.answers.get(message)
        return answer(wparam) if callable(answer) else answer

    def dpi(self, hwnd):
        return 96

    def send(self, inputs):
        self.sent.append(list(inputs))


class InputGuardTests(unittest.TestCase):
    PID = 4242

    def test_held_key_uses_repeat_downs_and_one_release(self):
        fake = FakeWin32(self.PID, self.PID)
        with mock.patch.object(gui, 'win32', return_value=fake), mock.patch.object(gui.time, 'sleep'):
            self.instance().hold_key('down', seconds=2, hz=30)
        self.assertEqual(61, len(fake.sent))
        self.assertTrue(all(events == [('key', 0x28, False)] for events in fake.sent[:-1]))
        self.assertEqual([('key', 0x28, True)], fake.sent[-1])

    def test_drag_checks_pointer_at_every_step(self):
        fake = FakeWin32(self.PID, self.PID)
        original = fake.send
        def send(events):
            original(events)
            fake.point_pid = 999
        fake.send = send
        with mock.patch.object(gui, 'win32', return_value=fake), mock.patch.object(gui.time, 'sleep'):
            with self.assertRaises(gui.InputBlocked):
                self.instance().drag((10, 10), (20, 20))
        self.assertEqual(2, len(fake.sent))
        self.assertEqual([('mouse', 0x4, 0, 0, 0)], fake.sent[-1])

    def test_held_key_stops_when_foreground_changes(self):
        fake = FakeWin32(self.PID, self.PID)
        def sleep(_):
            fake.foreground_pid = 999
        with mock.patch.object(gui, 'win32', return_value=fake), mock.patch.object(gui.time, 'sleep', side_effect=sleep):
            with self.assertRaises(gui.InputBlocked):
                self.instance().hold_key('down')
        self.assertEqual(2, len(fake.sent))
        self.assertEqual([('key', 0x28, True)], fake.sent[-1])

    def test_abort_release_and_guard_failure_are_audited(self):
        fake = FakeWin32(self.PID, self.PID)
        instance = self.instance()
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'guards.jsonl'
            def sleep(_):
                fake.foreground_pid = 999
            with mock.patch.dict(os.environ, {'GX_PERF_BATCH_ID': 'batch', 'GX_PERF_GUARD_LOG': str(log)}), \
                    mock.patch.object(gui, 'win32', return_value=fake), mock.patch.object(gui.time, 'sleep', side_effect=sleep):
                with self.assertRaises(gui.InputBlocked):
                    instance.hold_key('down')
            rows = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()]
            self.assertEqual(['pass', 'fail', 'pass'], [row['status'] for row in rows])
            self.assertTrue(rows[-1]['abort_release'])
            self.assertEqual('batch', rows[-1]['batch_id'])

    def test_no_release_without_down_and_abort_release_overrides_release_false(self):
        fake = FakeWin32(999, self.PID)
        with mock.patch.object(gui, 'win32', return_value=fake):
            with self.assertRaises(gui.InputBlocked):
                self.instance().hold_key('down')
        self.assertEqual([], fake.sent)
        fake.foreground_pid = self.PID
        with mock.patch.object(gui, 'win32', return_value=fake), mock.patch.object(gui.time, 'sleep', side_effect=RuntimeError('stop')):
            with self.assertRaises(RuntimeError):
                self.instance().drag((10, 10), (20, 20), release=False)
        self.assertEqual([('mouse', 0x4, 0, 0, 0)], fake.sent[-1])

    def guard_rows(self, action, fake, env_dir=None):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'guards.jsonl'
            instance = gui.Instance(self.PID, "C:/g/ghostty.exe", Path(env_dir or temp), creation=1, launched=0)
            with mock.patch.dict(os.environ, {'GX_PERF_BATCH_ID': 'batch', 'GX_PERF_GUARD_LOG': str(log)}), \
                    mock.patch.object(gui, 'win32', return_value=fake), mock.patch.object(gui.time, 'sleep'):
                with self.assertRaises(gui.InputBlocked) as blocked:
                    action(instance)
            rows = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()]
        return blocked.exception, rows, instance

    def test_guard_failures_carry_a_structured_cause(self):
        error, rows, _ = self.guard_rows(lambda instance: instance.press('enter'), FakeWin32(foreground_pid=16136, point_pid=self.PID))
        self.assertEqual('foreground_lost', error.cause)
        self.assertEqual([('guard', 'ensure_foreground', 'fail', 'foreground_lost')],
                         [(row['event'], row['check'], row['status'], row['cause']) for row in rows])
        self.assertEqual((16136, 'Chrome_WidgetWin_1', 'ghostty.exe'), (rows[0]['other_pid'], rows[0]['other_class'], rows[0]['other_image']))
        self.assertNotIn('title', rows[0])
        error, rows, _ = self.guard_rows(lambda instance: instance.mouse(5, 6), FakeWin32(foreground_pid=self.PID, point_pid=999))
        self.assertEqual('pointer_target_lost', error.cause)
        self.assertEqual([('ensure_foreground', 'pass', None), ('ensure_point', 'fail', 'pointer_target_lost')],
                         [(row['check'], row['status'], row.get('cause')) for row in rows])
        self.assertEqual(999, rows[-1]['other_pid'])
        with self.assertRaisesRegex(ValueError, 'cause'):
            gui.InputBlocked('x', cause='typo')
        self.assertEqual('other', gui.InputBlocked('legacy message').cause)

    def test_instance_gone_is_audited_once_and_not_after_an_intended_close(self):
        fake = FakeWin32(self.PID, self.PID)
        fake.alive = False
        def act(instance):
            try:
                instance.press('enter')
            finally:
                with self.assertRaises(gui.InputBlocked):
                    instance.windows()  # a second detection must not add a second instance row
        error, rows, instance = self.guard_rows(act, fake)
        self.assertEqual('instance_gone', error.cause)
        self.assertEqual([('instance', 'fail', 'instance_gone'), ('guard', 'fail', 'instance_gone')],
                         [(row['event'], row['status'], row['cause']) for row in rows])
        self.assertRegex(rows[0]['reason'], r'^ghostty pid \d+ has ended or is no longer the process this tool started; '
                                            r'no input was sent')
        self.assertEqual([], fake.sent)
        # close() that finds the process already gone audits the unexpected end too.
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'guards.jsonl'
            with mock.patch.dict(os.environ, {'GX_PERF_BATCH_ID': 'batch', 'GX_PERF_GUARD_LOG': str(log)}), \
                    mock.patch.object(gui, 'win32', return_value=fake):
                self.assertEqual('not running', self.instance().close())
                closing = self.instance()
                closing.closing = True  # an end this tool caused is not audited
                closing.note_gone('expected')
            rows = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()]
        self.assertEqual([('instance', 'instance_gone')], [(row['event'], row['cause']) for row in rows])
        self.assertRegex(rows[0]['reason'], r'^ghostty pid \d+ had ended, or was no longer the process this tool '
                                            r'started, before the close$')

    def test_a_hung_or_crashed_instance_is_a_product_cause_not_a_lost_foreground(self):
        main = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", (0, 0, 100, 100), True, False, False)

        def fake(cls="Chrome_WidgetWin_1", image="C:/Program Files/Chrome/chrome.exe", hung=(), answers=False):
            win = FakeWin32(foreground_pid=900, point_pid=900)
            win.tops, win.hung_windows = [main], set(hung)
            win.class_name = lambda hwnd: cls
            win.process_image = lambda pid: "C:/g/ghostty.exe" if pid == self.PID else image
            if answers:
                win.answers[gui.WM_NULL] = 0
            return win

        cases = {  # name: (fake, cause, message)
            "a window of it is hung": (fake(hung=[0x10]), "instance_hung", "IsHungAppWindow reports its GhosttyWindow 0x10"),
            "Ghost in front, no answer": (fake(cls="Ghost", image="C:/Windows/System32/dwm.exe"), "instance_hung",
                                          "Ghost \\(dwm.exe\\) is in front and its GhosttyWindow does not answer"),
            "WerFault in front, no answer": (fake(image="C:/Windows/System32/WerFault.exe"), "instance_hung",
                                             "\\(WerFault.exe\\) is in front"),
            "Ghost in front, it answers": (fake(cls="Ghost", answers=True), "foreground_lost", "is 0x1000 \\(Ghost"),
            "another window, no answer": (fake(), "foreground_lost", "the foreground window is 0x1000 "
                                                                     "\\(Chrome_WidgetWin_1, pid 900\\), not ghostty pid"),
        }
        for name, (win, cause, message) in cases.items():
            with self.subTest(case=name):
                error, rows, _ = self.guard_rows(lambda instance: instance.press("enter"), win)
                self.assertEqual((cause, cause), (error.cause, rows[-1]["cause"]))
                self.assertRegex(str(error), message)
                self.assertEqual([], win.sent)
        win = fake(cls="Ghost")  # the pointer guard of a click lands on the Ghost of the hung window
        win.foreground_pid = self.PID
        error, rows, _ = self.guard_rows(lambda instance: instance.mouse(10, 10), win)
        self.assertEqual(("instance_hung", "ensure_point", "Ghost"), (error.cause, rows[-1]["check"], rows[-1]["other_class"]))

    def test_a_chord_or_click_that_fails_part_way_releases_what_it_pressed(self):
        cases = {
            "chord": (lambda instance: instance.press("ctrl+shift+t"),
                      [("key", 0x54, True), ("key", 0x10, True), ("key", 0x11, True)], "ctrl+shift+t"),
            "ctrl+click": (lambda instance: instance.mouse(10, 10, mods=["ctrl"]),
                           [("mouse", 0x0004, 0, 0, 0), ("key", 0x11, True)], "ctrl+left"),
            "mouse_down": (lambda instance: instance.mouse(10, 10, action="down", button="right"),
                           [("mouse", 0x0010, 0, 0, 0)], "right"),
        }
        for name, (act, ups, control) in cases.items():
            with self.subTest(case=name):
                fake = FakeWin32(self.PID, self.PID)
                calls: list = []
                def send(inputs, calls=calls):
                    calls.append(list(inputs))
                    if len(calls) == 1:
                        raise gui.GuiError("SendInput sent 1 of 4 events (error 5)")
                fake.send = send
                with tempfile.TemporaryDirectory() as temp:
                    log = Path(temp) / "guards.jsonl"
                    instance = gui.Instance(self.PID, "C:/g/ghostty.exe", Path(temp), creation=1, launched=0)
                    with mock.patch.dict(os.environ, {"GX_PERF_BATCH_ID": "batch", "GX_PERF_GUARD_LOG": str(log)}), \
                            mock.patch.object(gui, "win32", return_value=fake), \
                            self.assertRaisesRegex(gui.GuiError, "sent 1 of 4"):
                        act(instance)
                    rows = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
                self.assertEqual(ups, calls[1])
                self.assertEqual(("release", control, True, "pass"), (rows[-1]["event"], rows[-1]["control"],
                                                                      rows[-1]["abort_release"], rows[-1]["status"]))
        fake = FakeWin32(self.PID, self.PID)  # a plain move presses nothing, so nothing is released
        fake.send = mock.Mock(side_effect=gui.GuiError("SendInput sent 0 of 1 events"))
        with mock.patch.object(gui, "win32", return_value=fake), self.assertRaises(gui.GuiError):
            gui.Instance(self.PID, "C:/g/ghostty.exe", Path("."), creation=1, launched=0).mouse(5, 5, action="move")
        self.assertEqual(1, fake.send.call_count)

    def test_the_caption_probe_audits_a_refusal_but_no_pass(self):
        window = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", (0, 0, 400, 300), True, False, False)
        fake = FakeWin32(self.PID, self.PID)
        fake.answers[0x0084] = 2  # HTCAPTION everywhere
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'guards.jsonl'
            instance = gui.Instance(self.PID, "C:/g/ghostty.exe", Path(temp), creation=1, launched=0)
            with mock.patch.dict(os.environ, {'GX_PERF_BATCH_ID': 'batch', 'GX_PERF_GUARD_LOG': str(log)}), \
                    mock.patch.object(gui, 'win32', return_value=fake), mock.patch.object(instance, "scale", return_value=1.0):
                self.assertEqual((384, 16), instance.caption_point(window))
                self.assertFalse(log.exists(), "a passed probe is not audited: nothing was sent")
                instance.ensure_point(10, 10)  # a real guard before input passes and is audited
            rows = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()]
        self.assertEqual([("guard", "ensure_point", "pass")], [(r["event"], r["check"], r["status"]) for r in rows])
        covered = FakeWin32(self.PID, 777)  # another process's window is under the caption point
        covered.answers[0x0084] = 2
        def blocked(instance):
            with mock.patch.object(instance, "scale", return_value=1.0):
                instance.caption_point(window)
        error, rows, _ = self.guard_rows(blocked, covered)
        self.assertEqual("pointer_target_lost", error.cause)
        self.assertEqual([("fail", True)], [(row["status"], row["probe"]) for row in rows])

    def wheel_rows(self, fake, **kwargs):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'guards.jsonl'
            with mock.patch.dict(os.environ, {'GX_PERF_BATCH_ID': 'batch', 'GX_PERF_GUARD_LOG': str(log)}), \
                    mock.patch.object(gui, 'win32', return_value=fake):
                try:
                    self.instance().wheel(5, 6, **kwargs)
                    error = None
                except gui.GuiError as exc:
                    error = exc
            rows = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()] if log.exists() else []
        return error, rows

    def test_wheel_holds_the_modifiers_around_the_notches_only(self):
        fake = FakeWin32(self.PID, self.PID)
        error, rows = self.wheel_rows(fake, delta=120, count=2, mods=["Ctrl", "shift", "control"])
        self.assertIsNone(error)
        self.assertEqual([[("key", 0x11, False), ("key", 0x10, False)],
                          [("mouse", 0xC001, 5, 6, 0), ("mouse", 0x800, 0, 0, 120), ("mouse", 0x800, 0, 0, 120)],
                          [("key", 0x10, True), ("key", 0x11, True)]], fake.sent)
        self.assertEqual(['ensure_foreground', 'ensure_point', 'ensure_foreground', 'ensure_point'],
                         [row['check'] for row in rows if row['event'] == 'guard'])
        release = [row for row in rows if row['event'] == 'release']
        self.assertEqual([('ctrl+shift', False)], [(row['control'], row['abort_release']) for row in release])

    def test_wheel_releases_the_modifiers_when_the_foreground_changes_after_the_downs(self):
        fake = FakeWin32(self.PID, self.PID)
        send = fake.send

        def lose_foreground(inputs):
            send(inputs)
            fake.foreground_pid = 999

        fake.send = lose_foreground
        error, rows = self.wheel_rows(fake, mods=["ctrl"])
        self.assertIsInstance(error, gui.InputBlocked)
        self.assertEqual([[("key", 0x11, False)], [("key", 0x11, True)]], fake.sent)
        self.assertEqual(('release', 'ctrl', True), (rows[-1]['event'], rows[-1]['control'], rows[-1]['abort_release']))

    def test_wheel_releases_the_modifiers_when_send_input_fails(self):
        for failing in (0, 1):  # the downs themselves, or the notches after them
            fake = FakeWin32(self.PID, self.PID)
            send, calls = fake.send, []

            def flaky(inputs):
                calls.append(inputs)
                if len(calls) == failing + 1:
                    raise gui.GuiError("SendInput sent 0 of 1 events")
                send(inputs)

            fake.send = flaky
            with self.subTest(failing=failing):
                error, rows = self.wheel_rows(fake, mods=["alt"])
                self.assertRegex(str(error), "SendInput sent 0")
                self.assertEqual([("key", 0x12, True)], fake.sent[-1])
                self.assertTrue(rows[-1]['abort_release'])

    def test_wheel_sends_nothing_when_a_guard_fails_first_and_one_batch_without_modifiers(self):
        fake = FakeWin32(self.PID, 999)
        error, _ = self.wheel_rows(fake, mods=["ctrl"])
        self.assertIsInstance(error, gui.InputBlocked)
        self.assertEqual([], fake.sent)
        fake = FakeWin32(self.PID, self.PID)
        self.assertIsNone(self.wheel_rows(fake, delta=-120, horizontal=True)[0])
        self.assertEqual([[("mouse", 0xC001, 5, 6, 0), ("mouse", 0x1000, 0, 0, -120)]], fake.sent)
        with self.assertRaisesRegex(gui.UsageError, "unknown modifier 'hyper'"):
            self.instance().wheel(5, 6, mods=["hyper"])

    def test_wheel_step_and_command_take_modifiers(self):
        self.assertEqual(["ctrl"], gui.validate_step("s", {"action": "wheel", "mods": ["ctrl"]}).params["mods"])
        for mods in ("ctrl", ["hyper"], [1]):
            with self.subTest(mods=mods), self.assertRaises(gui.UsageError):
                gui.validate_step("s", {"action": "wheel", "mods": mods})
        args = gui.build_parser().parse_args(["wheel", "E:/env", "10", "20", "--mods", "ctrl,shift", "--count", "3"])
        self.assertEqual(("ctrl,shift", 3), (args.mods, args.count))

    def test_completion_inside_a_caller_except_block_is_not_an_abort(self):
        fake = FakeWin32(self.PID, self.PID)
        instance = self.instance()
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'guards.jsonl'
            with mock.patch.dict(os.environ, {'GX_PERF_BATCH_ID': 'batch', 'GX_PERF_GUARD_LOG': str(log)}), \
                    mock.patch.object(gui, 'win32', return_value=fake), mock.patch.object(gui.time, 'sleep'):
                try:
                    raise RuntimeError('the caller is handling an unrelated error')
                except RuntimeError:
                    instance.drag((10, 10), (20, 20), steps=2, release=False)
                    instance.hold_key('down', seconds=1, hz=2)
            rows = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines()]
        releases = [row for row in rows if row['event'] == 'release']
        # drag(release=False) completed, so its button stays down; the key hold ends with one normal release.
        self.assertEqual(['down'], [row['control'] for row in releases])
        self.assertFalse(releases[0]['abort_release'])
        self.assertNotIn(('mouse', 0x4, 0, 0, 0), [event for batch in fake.sent for event in batch])
        self.assertEqual([('key', 0x28, True)], fake.sent[-1])

    def instance(self) -> gui.Instance:
        return gui.Instance(self.PID, "C:/g/ghostty.exe", Path("E:/ev/env"), creation=1, launched=0)

    def test_nothing_is_sent_while_another_process_is_in_front(self):
        fake = FakeWin32(foreground_pid=16136, point_pid=self.PID)
        with mock.patch.object(gui, "win32", return_value=fake):
            instance = self.instance()
            for action in (lambda: instance.type_text("echo hi\n"), lambda: instance.press("ctrl+shift+t"),
                           lambda: instance.mouse(10, 10), lambda: instance.wheel(10, 10)):
                with self.subTest(action=action), self.assertRaisesRegex(gui.InputBlocked, "no input was sent"):
                    action()
        self.assertEqual([], fake.sent)

    def test_mouse_input_needs_the_instance_under_the_pointer(self):
        fake = FakeWin32(foreground_pid=self.PID, point_pid=999)
        with mock.patch.object(gui, "win32", return_value=fake):
            with self.assertRaisesRegex(gui.InputBlocked, r"window at \(5, 6\)"):
                self.instance().mouse(5, 6, button="x1")
        self.assertEqual([], fake.sent)

    def test_same_pid_with_stale_identity_never_receives_input(self):
        for field, value in (("alive", False), ("creation", 2), ("image", "C:/other.exe"),
                             ("creation", None), ("image", None)):
            fake = FakeWin32(foreground_pid=self.PID, point_pid=self.PID)
            setattr(fake, field, value)
            with mock.patch.object(gui, "win32", return_value=fake):
                instance = self.instance()
                for action in (lambda: instance.type_text("x", delay=0), lambda: instance.press("enter"),
                               lambda: instance.mouse(5, 6), lambda: instance.wheel(5, 6)):
                    with self.subTest(field=field, value=value, action=action):
                        with self.assertRaises(gui.InputBlocked):
                            action()
                        self.assertEqual([], fake.sent)

    def test_identity_is_rechecked_between_text_input_events(self):
        fake = FakeWin32(foreground_pid=self.PID, point_pid=self.PID)
        send = fake.send

        def replace_after_send(inputs):
            send(inputs)
            fake.creation = 2

        fake.send = replace_after_send
        with mock.patch.object(gui, "win32", return_value=fake), self.assertRaises(gui.InputBlocked):
            self.instance().type_text("ab", delay=0)
        self.assertEqual(1, len(fake.sent))

    def test_the_backdrop_showing_through_does_not_cover_a_window(self):
        fake = FakeWin32(foreground_pid=self.PID, point_pid=1)  # the harness's own backdrop is under every point
        fake.capture_screen = lambda rect: rect
        info = gui.WindowInfo(0x10, gui.POPUP_CLASS, "", (0, 0, 10, 10), True, False, True)
        with mock.patch.object(gui, "win32", return_value=fake):
            with self.assertRaisesRegex(gui.GuiError, "is covered"):
                self.instance().capture_window(info)
            self.assertEqual((-5, -5, 15, 15), self.instance().capture_window(info, region=(-5, -5, 15, 15),
                                                                              see_through=(0x2000,)))

    def test_stale_identity_blocks_window_lookup_activation_and_capture(self):
        fake = FakeWin32(foreground_pid=self.PID, point_pid=self.PID)
        fake.creation = 2
        with mock.patch.object(gui, "win32", return_value=fake):
            instance = self.instance()
            for action in (instance.windows, instance.activate,
                           lambda: instance.capture_window(mock.Mock(spec=gui.WindowInfo))):
                with self.subTest(action=action), self.assertRaises(gui.InputBlocked):
                    action()
        self.assertEqual([], fake.sent)

    def test_events_when_the_instance_is_in_front(self):
        fake = FakeWin32(foreground_pid=self.PID, point_pid=self.PID)
        with mock.patch.object(gui, "win32", return_value=fake):
            instance = self.instance()
            instance.press("ctrl+shift+t")
            instance.type_text("a中", delay=0)
            instance.mouse(5, 6, button="x2", mods=["ctrl"])
        chord, a, han, click = fake.sent
        self.assertEqual([("key", 0x11, False), ("key", 0x10, False), ("key", ord("T"), False), ("key", ord("T"), True),
                          ("key", 0x10, True), ("key", 0x11, True)], chord)
        self.assertEqual([("unicode", 0x61, False), ("unicode", 0x61, True)], a)
        self.assertEqual([("unicode", 0x4E2D, False), ("unicode", 0x4E2D, True)], han)
        self.assertEqual([("key", 0x11, False), ("mouse", 0xC001, 5, 6, 0), ("mouse", 0x80, 0, 0, 2),
                          ("mouse", 0x100, 0, 0, 2), ("key", 0x11, True)], click)


def zig_source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class TestHookTests(unittest.TestCase):
    PID = 4242
    MAIN = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", (0, 0, 100, 100), True, False, False)

    def instance(self, fake):
        instance = gui.Instance(self.PID, "C:/g/ghostty.exe", Path("E:/ev/env"), creation=1, launched=0)
        patch = mock.patch.object(gui.Instance, "require_window", return_value=self.MAIN)
        patch.start()
        self.addCleanup(patch.stop)
        return instance

    def test_message_numbers_follow_the_product_source(self):
        title_bar = zig_source("src/apprt/win32/chrome/TitleBar.zig")
        for name, value in (("WM_GHOSTTY_SIMULATE_D2D_FAILURE", gui.WM_GHOSTTY_SIMULATE_D2D_FAILURE),
                            ("WM_GHOSTTY_CAPTION_QUERY", gui.WM_GHOSTTY_CAPTION_QUERY)):
            with self.subTest(name=name):
                match = re.search(rf"pub const {name}: u32 = w32\.WM_USER \+ (0x[0-9A-Fa-f]+);", title_bar)
                self.assertIsNotNone(match)
                self.assertEqual(gui.WM_USER + int(match.group(1), 16), value)
        self.assertIn("(@as(isize, @intFromBool(self.direct2d_failed)) << 3)", title_bar)

    def test_simulated_d2d_failure_is_confirmed_by_the_caption_state(self):
        fake = FakeWin32(self.PID, self.PID)
        fake.answers = {gui.WM_GHOSTTY_SIMULATE_D2D_FAILURE: 1, gui.WM_GHOSTTY_CAPTION_QUERY: 0b1001}
        with mock.patch.object(gui, "win32", return_value=fake):
            self.assertEqual(0b1001, self.instance(fake).simulate_d2d_failure())
        self.assertEqual([(0x10, gui.WM_USER + 0x4C, 0, 0), (0x10, gui.WM_USER + 0x4D, 0, 0)], fake.messages)
        self.assertEqual([], fake.sent)

    def test_simulated_d2d_failure_without_an_answer_or_the_hook_fails(self):
        cases = {"did not answer WM_GHOSTTY_SIMULATE_D2D_FAILURE": {},
                 "returned 0, not 1: the build lacks the hook": {gui.WM_GHOSTTY_SIMULATE_D2D_FAILURE: 0},
                 "did not answer WM_GHOSTTY_CAPTION_QUERY": {gui.WM_GHOSTTY_SIMULATE_D2D_FAILURE: 1},
                 "does not report the Direct2D failure": {gui.WM_GHOSTTY_SIMULATE_D2D_FAILURE: 1,
                                                          gui.WM_GHOSTTY_CAPTION_QUERY: 0b0001}}
        for expected, answers in cases.items():
            fake = FakeWin32(self.PID, self.PID)
            fake.answers = answers
            with self.subTest(expected=expected), mock.patch.object(gui, "win32", return_value=fake):
                with self.assertRaisesRegex(gui.GuiError, expected):
                    self.instance(fake).simulate_d2d_failure()

    def test_system_theme_wparam_packs_app_simulated_system_theme(self):
        # The values of the Zig test "SimulatedSystemTheme packs the scheme and high contrast".
        self.assertEqual(0, gui.system_theme_wparam())
        self.assertEqual(2, gui.system_theme_wparam("dark"))
        self.assertEqual(0b0101, gui.system_theme_wparam("light", "on"))
        self.assertEqual(0b1000, gui.system_theme_wparam("follow", "off"))
        self.assertEqual(0b0110, gui.system_theme_wparam("dark", "on"))
        for scheme, high_contrast in (("system", "follow"), ("dark", "true"), ("Dark", "on")):
            with self.subTest(scheme=scheme, high_contrast=high_contrast), self.assertRaises(gui.UsageError):
                gui.system_theme_wparam(scheme, high_contrast)

    def test_system_theme_contract_follows_the_product_source(self):
        window = zig_source("src/apprt/win32/Window.zig")
        match = re.search(r"pub const WM_GHOSTTY_SIMULATE_SYSTEM_THEME: u32 = w32\.WM_USER \+ (0x[0-9A-Fa-f]+);", window)
        self.assertEqual(gui.WM_GHOSTTY_SIMULATE_SYSTEM_THEME, gui.WM_USER + int(match.group(1), 16))
        app = zig_source("src/apprt/win32/App.zig")
        struct = re.search(r"pub const SimulatedSystemTheme = packed struct\(usize\) \{(.*?)\n\};", app, re.S).group(1)
        fields = re.findall(r"(\w+): enum\(u2\) \{([^}]*)\}", struct)
        self.assertEqual(["scheme", "high_contrast"], [name for name, _ in fields])  # scheme in the low bits
        for (name, body), mapping in zip(fields, (gui.SYSTEM_THEME_SCHEMES, gui.SYSTEM_THEME_HIGH_CONTRAST)):
            values = {key: int(value) for key, value in re.findall(r"(\w+) = (\d+)", body)}
            ours = {("system" if key == "follow" else key): value for key, value in mapping.items()}
            with self.subTest(field=name):
                self.assertEqual(values, ours)

    def test_simulated_system_theme_needs_the_hook_to_accept_it(self):
        wparams = []
        fake = FakeWin32(self.PID, self.PID)
        fake.answers = {gui.WM_GHOSTTY_SIMULATE_SYSTEM_THEME: lambda wparam: wparams.append(wparam) or 1}
        with mock.patch.object(gui, "win32", return_value=fake):
            self.assertEqual(0b0110, self.instance(fake).simulate_system_theme("dark", "on"))
        self.assertEqual([(0x10, gui.WM_USER + 0x49, 0b0110, 0)], fake.messages)
        for expected, answer in (("did not answer", None), ("returned 0, not 1", 0)):
            fake = FakeWin32(self.PID, self.PID)
            fake.answers = {gui.WM_GHOSTTY_SIMULATE_SYSTEM_THEME: answer}
            with self.subTest(expected=expected), mock.patch.object(gui, "win32", return_value=fake):
                with self.assertRaisesRegex(gui.GuiError, expected):
                    self.instance(fake).simulate_system_theme("light")
        with self.assertRaises(gui.UsageError):
            self.instance(fake).simulate_system_theme("sepia")

    def test_system_theme_step(self):
        self.assertEqual({"scheme": "dark", "high_contrast": "off"},
                         gui.validate_step("s", {"action": "simulate_system_theme", "scheme": "dark",
                                                 "high_contrast": "off"}).params)
        for raw in ({"scheme": "night"}, {"high_contrast": True}, {"contrast": "on"}):
            with self.subTest(raw=raw), self.assertRaises(gui.UsageError):
                gui.validate_step("s", {"action": "simulate_system_theme", **raw})
        run = gui.ScenarioRun(None, Path("ghostty.exe"), Path("."))  # type: ignore[arg-type]
        run.instance = mock.Mock(spec=gui.Instance)
        run.instance.simulate_system_theme.return_value = 0b0101
        self.assertEqual("simulated apps scheme light, high contrast on (wparam 0x5)",
                         run.do_simulate_system_theme({"scheme": "light", "high_contrast": "on"}))
        run.instance.simulate_system_theme.assert_called_once_with("light", "on")

    def test_the_step_and_its_validation(self):
        self.assertEqual("simulate_d2d_failure", gui.validate_step("s", {"action": "simulate_d2d_failure"}).action)
        self.assertEqual({"window": "quick"},
                         gui.validate_step("s", {"action": "simulate_d2d_failure", "window": "quick"}).params)
        with self.assertRaisesRegex(gui.UsageError, "does not take"):
            gui.validate_step("s", {"action": "simulate_d2d_failure", "wparam": 1})
        run = gui.ScenarioRun(None, Path("ghostty.exe"), Path("."))  # type: ignore[arg-type]
        run.instance = mock.Mock(spec=gui.Instance)
        run.instance.simulate_d2d_failure.return_value = 0b1000
        self.assertIn("0b1000", run.do_simulate_d2d_failure({"window": "quick"}))
        run.instance.simulate_d2d_failure.assert_called_once_with("quick")


class FakeAcl:
    """Stands in for icacls: remembers which directories deny the user; probe() reads that state
    (and a file's write bit), so nothing depends on the platform or on running as root."""

    def __init__(self, deny_works=True, remove_works=True, reset_works=True, log=None, delete_denied=True):
        self.deny_works, self.remove_works, self.reset_works = deny_works, remove_works, reset_works
        self.delete_denied = delete_denied  # whether the deny entry also stops DELETE of the entries inside
        self.calls = log if log is not None else []
        self.denied: set = set()

    def __call__(self, args):
        self.calls.append(list(args))
        path, verb = args[0], args[1]
        if verb == "/deny" and self.deny_works:
            self.denied.add(path)
        elif (verb == "/remove:d" and self.remove_works) or (verb == "/reset" and self.reset_works):
            self.denied.discard(path)
        return 0, "Successfully processed 1 files"

    def probe(self, path):
        if path.is_dir():
            return str(path) not in self.denied
        return bool(path.stat().st_mode & gui.stat.S_IWRITE)

    def delete_check(self, path):
        entries = sorted(entry.name for entry in path.iterdir())
        protected = str(path) in self.denied and self.delete_denied
        return len(entries), [] if protected else entries


class ReadOnlyTests(unittest.TestCase):
    SID = "S-1-5-21-1"

    def paths(self, acl):
        return gui.ReadOnlyPaths(acl=acl, sid=lambda: self.SID, probe=acl.probe, delete_check=acl.delete_check)

    def test_file_step_validation(self):
        for raw in ({"path": "a", "text": ""}, {"path": "d", "directory": True}, {"path": "d", "readonly": False},
                    {"path": "d", "directory": True, "readonly": True}, {"path": "a", "text": "x", "readonly": True}):
            with self.subTest(raw=raw):
                self.assertEqual("file", gui.validate_step("s", {"action": "file", **raw}).action)
        cases = {"needs text, directory = true or readonly": {"path": "a"},
                 "text or directory, not both": {"path": "a", "text": "", "directory": True},
                 "directory only takes true": {"path": "a", "directory": False},
                 "readonly must be true or false": {"path": "a", "readonly": "yes"},
                 "text must be a string": {"path": "a", "text": 1}}
        for expected, raw in cases.items():
            with self.subTest(case=expected), self.assertRaisesRegex(gui.UsageError, expected):
                gui.validate_step("s", {"action": "file", **raw})

    def test_a_directory_gets_an_inheritable_deny_entry_and_is_released(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "state"
            directory.mkdir()
            acl = FakeAcl()
            paths = self.paths(acl)
            self.assertEqual("state is read-only (acl; a write attempt was refused, and it has no entries to try "
                             "DELETE access on)", paths.protect(directory, "state"))
            self.assertEqual([[str(directory), "/deny", f"*{self.SID}:(OI)(CI)(DE,WD,AD,WEA,WA,DC)"]], acl.calls)
            self.assertEqual({directory: "acl"}, paths.paths)
            self.assertEqual("state is read-only already", paths.protect(directory, "state"))
            self.assertEqual("state is writable again (acl)", paths.release(directory, "state"))
            self.assertEqual([str(directory), "/remove:d", f"*{self.SID}"], acl.calls[-1])
            self.assertEqual({}, paths.paths)
            self.assertEqual(["readonly", "writable"], [event["event"] for event in paths.events])
            self.assertEqual({"entries_tried": 0, "deletable": []}, paths.events[0]["delete_probe"])

    def test_existing_entries_must_not_be_deletable(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "state"
            directory.mkdir()
            (directory / "session.json").write_text("{}", encoding="utf-8")
            (directory / "windows").mkdir()
            paths = self.paths(FakeAcl())
            self.assertEqual("state is read-only (acl; a write attempt was refused, DELETE access to its 2 existing "
                             "entries too)", paths.protect(directory, "state"))
            self.assertEqual({"entries_tried": 2, "deletable": []}, paths.events[0]["delete_probe"])
            paths.release(directory, "state")
            acl = FakeAcl(delete_denied=False)  # an entry without DE: deletable through an inherited allow
            paths = self.paths(acl)
            with self.assertRaisesRegex(gui.GuiError, r"state: session.json, windows could still be deleted after "
                                                      r"making it read-only; released it again"):
                paths.protect(directory, "state")
            self.assertEqual(["/deny", "/remove:d"], [call[1] for call in acl.calls])
            self.assertEqual({}, paths.paths)

    def test_the_delete_probe_opens_for_delete_without_deleting(self):
        fake = FakeWin32(1, 1)
        fake.can_open_for_delete = mock.Mock(side_effect=lambda entry: entry.name == "b")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(gui, "win32", return_value=fake):
            for name in "cab":
                (Path(tmp) / name).write_text(name, encoding="utf-8")
            self.assertEqual((3, ["b"]), gui.deletable_entries(Path(tmp)))
            self.assertEqual((1, []), gui.deletable_entries(Path(tmp), limit=1))
            self.assertEqual(["a", "b", "c"], sorted(path.name for path in Path(tmp).iterdir()))

    def test_a_deny_entry_without_effect_is_undone_and_fails_the_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            acl = FakeAcl(deny_works=False)
            paths = self.paths(acl)
            with self.assertRaisesRegex(gui.GuiError, r"still writable after making it read-only \(acl\)"):
                paths.protect(directory, "state")
            self.assertEqual(["/deny", "/remove:d"], [call[1] for call in acl.calls])
            self.assertEqual({}, paths.paths)

    def test_release_falls_back_to_reset_and_reports_what_stays_read_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "state"
            directory.mkdir()
            acl = FakeAcl(remove_works=False)
            paths = self.paths(acl)
            paths.protect(directory, "state")
            self.assertEqual("state is writable again (acl, reset)", paths.release(directory, "state"))
            self.assertEqual([str(directory), "/reset", "/T", "/C"], acl.calls[-1])
            acl = FakeAcl(remove_works=False, reset_works=False)
            paths = self.paths(acl)
            paths.protect(directory, "state")
            with self.assertRaisesRegex(gui.GuiError, r"still not writable after releasing it \(acl, reset\)"):
                paths.release(directory, "state")
            self.assertIn(directory, paths.paths)
            self.assertEqual(["state: release failed: state is still not writable after releasing it (acl, reset)"],
                             paths.release_all(Path(tmp)))
            acl.reset_works = True
            self.assertEqual(["state is writable again (acl, reset)"], paths.release_all(Path(tmp)))
            self.assertEqual({}, paths.paths)

    def test_a_file_gets_the_read_only_attribute(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "session.json"
            path.write_text("{}", encoding="utf-8")
            acl = FakeAcl()
            paths = self.paths(acl)
            self.assertIn("(attribute;", paths.protect(path, "session.json"))
            self.assertFalse(path.stat().st_mode & gui.stat.S_IWRITE)
            self.assertEqual("session.json is writable again (attribute)", paths.release(path, "session.json"))
            self.assertTrue(path.stat().st_mode & gui.stat.S_IWRITE)
            self.assertEqual([], acl.calls)
            with self.assertRaisesRegex(gui.GuiError, "does not exist"):
                paths.protect(Path(tmp) / "absent", "absent")

    def test_file_steps_inside_the_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / "env"
            env.mkdir()
            run = gui.ScenarioRun(None, Path("ghostty.exe"), Path(tmp))  # type: ignore[arg-type]
            run.instance = mock.Mock(spec=gui.Instance)
            run.instance.env_dir = env
            acl = FakeAcl()
            run.readonly = self.paths(acl)
            state = os.path.join("state", "ghostty")
            self.assertEqual(f"{state} is a directory; {state} is read-only (acl; a write attempt was refused, and it "
                             "has no entries to try DELETE access on)",
                             run.do_file({"path": "state/ghostty", "directory": True, "readonly": True}))
            with self.assertRaisesRegex(gui.GuiError, "read-only from an earlier step"):
                run.do_file({"path": "state/ghostty", "text": "x"})
            with mock.patch.object(gui.Path, "write_text", side_effect=PermissionError("denied")):
                with self.assertRaisesRegex(gui.GuiError, r"cannot write state.ghostty.s.json: denied"):
                    run.do_file({"path": "state/ghostty/s.json", "text": "{}"})
            self.assertEqual("a.txt written", run.do_file({"path": "a.txt", "text": "x"}))
            with self.assertRaises(gui.UsageError):
                run.do_file({"path": "../outside", "readonly": True})

    def test_a_scenario_releases_what_it_left_read_only_after_closing_the_instance(self):
        log: list = []
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W90-ro.toml"
            path.write_text('id = "W90"\ntitle = "t"\nconfig = "language = en"\nbackdrop = false\n'
                            'backdrop_reason = "fake capture"\n[[step]]\naction = "file"\npath = "state"\n'
                            'directory = true\nreadonly = true\n[[step]]\naction = "capture"\nname = "x"\n',
                            encoding="utf-8")
            acl = FakeAcl(log=log)
            with mock.patch.object(gui, "run_icacls", acl), mock.patch.object(gui, "write_probe", acl.probe):
                run = gui.ScenarioRun(gui.load_scenario(path), Path("ghostty.exe"), Path(tmp) / "out")
            instance = mock.Mock()
            instance.env_dir = (Path(tmp) / "out" / "env").resolve()
            instance.log = Path(tmp) / "absent.log"
            instance.popups.return_value = []
            instance.capture_window.return_value.save_png.side_effect = lambda target: target
            instance.close.side_effect = lambda: log.append("close") or "closed"
            with mock.patch.object(gui, "launch", return_value=instance), \
                    mock.patch.object(gui, "win32", return_value=FakeWin32(4242, 4242)), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                report = run.run()
        self.assertEqual("ok", report["status"])
        self.assertEqual(["/deny", "close", "/remove:d"], [entry if entry == "close" else entry[1] for entry in log])
        self.assertEqual(["state is writable again (acl)"], report["readonly"]["released_at_end"])
        self.assertEqual(["readonly", "writable"], [event["event"] for event in report["readonly"]["events"]])


class CleanupTests(unittest.TestCase):
    def test_the_release_survives_a_cleanup_that_raises(self):
        log: list = []
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W90-ro.toml"
            path.write_text('id = "W90"\ntitle = "t"\nconfig = "language = en"\nbackdrop = false\n'
                            'backdrop_reason = "fake capture"\n[[step]]\naction = "file"\npath = "state"\n'
                            'directory = true\nreadonly = true\n[[step]]\naction = "capture"\nname = "x"\n',
                            encoding="utf-8")
            acl = FakeAcl(log=log)
            with mock.patch.object(gui, "run_icacls", acl), mock.patch.object(gui, "write_probe", acl.probe), \
                    mock.patch.object(gui, "deletable_entries", acl.delete_check):
                run = gui.ScenarioRun(gui.load_scenario(path), Path("ghostty.exe"), Path(tmp) / "out", keep_open=True)
            instance = mock.Mock()
            instance.env_dir = (Path(tmp) / "out" / "env").resolve()
            instance.original_layout, instance.loaded_layouts = None, []
            instance.popups.return_value = []
            instance.capture_window.return_value.save_png.side_effect = lambda target: target
            instance.save.side_effect = OSError("the disk is full")  # --keep-open saves the session
            with mock.patch.object(gui, "launch", return_value=instance), \
                    mock.patch.object(gui, "win32", return_value=FakeWin32(4242, 4242)), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaisesRegex(OSError, "the disk is full"):
                run.run()
        self.assertEqual(["/deny", "/remove:d"], [entry[1] for entry in log], "released although the cleanup raised")
        self.assertEqual({}, run.readonly.paths)

    def test_remove_tree_resets_what_an_aborted_run_left_and_says_how_to_recover(self):
        calls: list = []
        acl = lambda args: calls.append(list(args)) or (0, "Successfully processed 3 files")  # noqa: E731
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "W90"
            (target / "env").mkdir(parents=True)
            self.assertEqual("removed", gui.remove_tree(target, acl))
            self.assertEqual([], calls)
            (target / "env").mkdir(parents=True)
            real = gui.shutil.rmtree
            with mock.patch.object(gui.shutil, "rmtree", side_effect=[PermissionError("denied"), None]) as rmtree:
                self.assertIn("after icacls /reset (exit 0)", gui.remove_tree(target, acl))
            self.assertEqual([[str(target), "/reset", "/T", "/C", "/Q"]], calls)
            self.assertEqual(2, rmtree.call_count)
            with mock.patch.object(gui.shutil, "rmtree", side_effect=[PermissionError("denied"),
                                                                      PermissionError("still denied")]):
                with self.assertRaisesRegex(gui.GuiError, r"cannot remove .*still denied.*recover by hand: icacls "
                                                          r"\".*W90\" /reset /T /C /Q, then attrib -R"):
                    gui.remove_tree(target, acl)
            real(target)


class CaptureWindowTests(unittest.TestCase):
    PID = 4242
    MAIN = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "Ghostty", (0, 0, 100, 100), True, False, False)
    DIALOG = gui.WindowInfo(0x20, gui.DIALOG_CLASS, "Ghostty", (10, 10, 60, 40), True, False, False)

    def instance(self):
        return gui.Instance(self.PID, "C:/g/ghostty.exe", Path("E:/ev/env"), creation=1, launched=0)

    def test_validation_and_the_capture_requirement(self):
        self.assertEqual("capture_window", gui.validate_step("s", {"action": "capture_window", "name": "x",
                                                                   "cls": "#32770"}).action)
        cases = {"needs cls or title": {"name": "x"},
                 "method must be print or screen": {"name": "x", "cls": "#32770", "method": "desktop"},
                 "timeout must be a number": {"name": "x", "cls": "#32770", "timeout": 600},
                 "bad title pattern": {"name": "x", "title": "("}}
        for expected, raw in cases.items():
            with self.subTest(case=expected), self.assertRaisesRegex(gui.UsageError, expected):
                gui.validate_step("s", {"action": "capture_window", **raw})
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W90-x.toml"
            path.write_text('id = "W90"\ntitle = "t"\nconfig = "language = en"\nwait_window = false\n'
                            '[[step]]\naction = "capture_window"\nname = "error"\ncls = "#32770"\n', encoding="utf-8")
            self.assertFalse(gui.load_scenario(path).wait_window)
            path.write_text('id = "W90"\ntitle = "t"\nconfig = "language = en"\nwait_window = "no"\n'
                            '[[step]]\naction = "capture_window"\nname = "error"\ncls = "#32770"\n', encoding="utf-8")
            with self.assertRaisesRegex(gui.UsageError, "wait_window must be true or false"):
                gui.load_scenario(path)

    def test_find_window_skips_the_main_window_and_waits_for_the_dialog(self):
        fake = FakeWin32(self.PID, self.PID)
        fake.tops = [self.MAIN, gui.WindowInfo(0x30, gui.DIALOG_CLASS, "Ghostty", (0, 0, 9, 9), False, False, False)]
        calls = []

        def sleep(_):
            calls.append(1)
            fake.tops = [self.MAIN, self.DIALOG]

        with mock.patch.object(gui, "win32", return_value=fake), mock.patch.object(gui.time, "sleep", side_effect=sleep):
            self.assertEqual(self.DIALOG, self.instance().find_window(title="^Ghostty$", timeout=5))
            self.assertEqual(1, len(calls))
            self.assertEqual(self.DIALOG, self.instance().find_window(gui.DIALOG_CLASS))
            with self.assertRaisesRegex(gui.GuiError, "no window of ghostty pid 4242 with class TaskDialog .* within 0s"):
                self.instance().find_window("TaskDialog", timeout=0)
            with self.assertRaises(gui.UsageError):
                self.instance().find_window()
            fake.alive = False
            with self.assertRaises(gui.InputBlocked):
                self.instance().find_window(gui.DIALOG_CLASS)

    def test_the_step_saves_a_print_capture_like_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = gui.ScenarioRun(None, Path("ghostty.exe"), Path(tmp))  # type: ignore[arg-type]
            run.instance = mock.Mock(spec=gui.Instance)
            run.instance.find_window.return_value = self.DIALOG
            run.instance.capture_window.side_effect = lambda info, method: screen(info.rect)
            self.assertEqual("01-error.png: #32770 50x30 'Ghostty'",
                             run.do_capture_window({"name": "error", "cls": "#32770", "timeout": 3}))
            run.instance.find_window.assert_called_once_with("#32770", None, 3.0)
            run.instance.capture_window.assert_called_once_with(self.DIALOG, "print")
            self.assertEqual((["01-error.png"], 1), (run.captures, run.capture_steps))
            self.assertTrue((Path(tmp) / "01-error.png").is_file())

    def test_a_scenario_that_never_shows_its_main_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W90-x.toml"
            path.write_text('id = "W90"\ntitle = "t"\nconfig = "language = en"\nwait_window = false\n'
                            '[[step]]\naction = "capture_window"\nname = "error"\ncls = "#32770"\n', encoding="utf-8")
            run = gui.ScenarioRun(gui.load_scenario(path), Path("ghostty.exe"), Path(tmp) / "out")
            instance = mock.Mock()
            instance.log = Path(tmp) / "absent.log"
            instance.find_window.return_value = self.DIALOG
            instance.capture_window.side_effect = lambda info, method: screen(info.rect)
            backdrop = mock.patch.object(gui, "BackdropWindow", FakeBackdropWindow)
            FakeBackdropWindow.made = []
            with backdrop, mock.patch.object(gui, "launch", return_value=instance), \
                    mock.patch.object(gui, "win32", return_value=FakeWin32(4242, 4242)), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                report = run.run()
        self.assertEqual(("ok", False, ["01-error.png"]), (report["status"], report["wait_window"], report["captures"]))
        instance.wait_window.assert_not_called()
        instance.activate.assert_not_called()
        self.assertEqual([], FakeBackdropWindow.made, "a print capture needs no backdrop")


class LayoutTests(unittest.TestCase):
    PID = 4242
    MAIN = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", (0, 0, 100, 100), True, False, False)

    def setUp(self):
        self.fake = FakeWin32(self.PID, self.PID)
        for patch in (mock.patch.object(gui, "win32", return_value=self.fake),
                      mock.patch.object(gui.Instance, "require_window", return_value=self.MAIN),
                      mock.patch.object(gui, "vm_guard", return_value="test VM: mock"),  # VmGuardTests checks it
                      mock.patch.object(gui.time, "sleep")):
            patch.start()
            self.addCleanup(patch.stop)
        self.instance = gui.Instance(self.PID, "C:/g/ghostty.exe", Path("E:/ev/env"), creation=1, launched=0)

    def test_resolve_layout(self):
        loaded = [0x08040804, 0x04090409, 0xE0010804, 0xFFFFFFFFF0020407]
        self.assertEqual((0x04090409, None), gui.resolve_layout("0x04090409", loaded))
        self.assertEqual((0x04090409, None), gui.resolve_layout("0X4090409", loaded))
        self.assertEqual((0x04090409, "00000409"), gui.resolve_layout("00000409", loaded))
        self.assertEqual((None, "00000407"), gui.resolve_layout("00000407", loaded))
        self.assertEqual((0xE0010804, "E0010804"), gui.resolve_layout("e0010804", loaded))
        self.assertEqual((None, "00010407"), gui.resolve_layout("00010407", loaded), "a variant needs its HKL")
        self.assertEqual((0xFFFFFFFFF0020407, None), gui.resolve_layout("0xf0020407", loaded))
        for bad in ("us", "0409", "0x123456789", "", "000004090"):
            with self.subTest(target=bad), self.assertRaises(gui.UsageError):
                gui.resolve_layout(bad, loaded)
        self.assertEqual(0x04090409, gui.as_lparam(0x04090409))
        if gui.ctypes.sizeof(gui.ctypes.c_void_p) == 8:
            self.assertEqual(0xFFFFFFFFF0020407 - (1 << 64), gui.as_lparam(0xFFFFFFFFF0020407))

    def test_switching_to_a_loaded_layout_and_back(self):
        self.assertEqual("keyboard layout 0x08040804 -> 0x04090409", self.instance.switch_layout("00000409"))
        self.assertEqual(([0x04090409], 0x08040804), (self.fake.requests, self.instance.original_layout))
        self.assertIn("(already)", self.instance.switch_layout("0x04090409"))
        self.assertEqual("switched back: keyboard layout 0x04090409 -> 0x08040804", self.instance.restore_layout())
        self.assertIsNone(self.instance.original_layout)
        self.assertIsNone(self.instance.restore_layout())
        self.assertEqual(([], []), (self.fake.loaded, self.fake.unloaded))

    def test_a_layout_that_is_not_loaded_is_refused_without_allow_load(self):
        with self.assertRaisesRegex(gui.GuiError, r"00000407 is not loaded for this user \(GetKeyboardLayoutList: "
                                                  r"0x08040804, 0x04090409\); pick a loaded one; only inside a VM"):
            self.instance.switch_layout("00000407")
        with self.assertRaisesRegex(gui.GuiError, "name an HKL from that list"):
            self.instance.switch_layout("0x04070407", allow_load=True)
        self.assertEqual(([], []), (self.fake.loaded, self.fake.requests))
        self.assertIsNone(self.instance.original_layout)

    def test_allow_load_loads_switches_and_unloads_only_what_it_added(self):
        self.assertEqual("keyboard layout 0x08040804 -> 0x04070407 (loaded 00000407)",
                         self.instance.switch_layout("00000407", allow_load=True))
        self.assertEqual((["00000407"], [0x04070407]), (self.fake.loaded, self.instance.loaded_layouts))
        self.fake.layouts.append(0xF0020407)  # a variant this user already has
        self.instance.switch_layout("00010407", allow_load=True)
        self.assertEqual([0x04070407], self.instance.loaded_layouts, "an existing layout is never unloaded")
        self.assertEqual(["unloaded 0x04070407"], self.instance.unload_layouts())
        self.assertEqual(([0x04070407], []), (self.fake.unloaded, self.instance.loaded_layouts))
        self.assertIn(0xF0020407, self.fake.layouts)

    def test_a_thread_that_does_not_switch_fails_or_is_reported(self):
        self.fake.layout_follows = False
        clock = iter(range(100))
        with mock.patch.object(gui.time, "monotonic", side_effect=lambda: next(clock)):
            with self.assertRaisesRegex(gui.GuiError, "still uses 0x08040804, not 0x04090409, 2s after"):
                self.instance.switch_layout("0x04090409")
            self.assertEqual("layout is still 0x08040804", self.instance.switch_layout("0x04090409", strict=False))
        self.fake.alive = False
        self.assertEqual("not switched back to 0x08040804: the instance is gone", self.instance.restore_layout())

    def test_ime_off_only_switches_to_a_loaded_us_layout(self):
        self.assertEqual("switched to US (keyboard layout 0x08040804 -> 0x04090409)", self.instance.ime_off())
        self.assertEqual(([0x04090409], 0x08040804), (self.fake.requests, self.instance.original_layout))
        self.assertEqual("already US", self.instance.ime_off())
        self.fake.layout, self.fake.layouts, self.fake.requests = 0x08040804, [0x08040804], []
        with self.assertRaisesRegex(gui.GuiError, "no English \\(US\\) keyboard layout is loaded.*does not load one"):
            self.instance.ime_off()
        self.assertEqual(([], []), (self.fake.requests, self.fake.loaded))
        self.fake.layouts, self.fake.layout_follows = [0x08040804, 0x04090409], False
        clock = iter(range(100))
        with mock.patch.object(gui.time, "monotonic", side_effect=lambda: next(clock)):
            self.assertEqual("layout is still 0x08040804", self.instance.ime_off())

    def test_the_step_the_run_cleanup_order_and_the_session(self):
        self.assertEqual("layout", gui.validate_step("s", {"action": "layout", "target": "0x08040804"}).action)
        for raw in ({}, {"target": "german"}, {"target": "00000407", "allow_load": True}):
            with self.subTest(raw=raw), self.assertRaises(gui.UsageError):
                gui.validate_step("s", {"action": "layout", **raw})
        run = gui.ScenarioRun(None, Path("ghostty.exe"), Path("."), allow_load_layouts=True)  # type: ignore[arg-type]
        run.instance = mock.Mock(spec=gui.Instance)
        run.instance.switch_layout.return_value = "switched"
        self.assertEqual("switched", run.do_layout({"target": "00000407"}))
        run.instance.switch_layout.assert_called_once_with("00000407", allow_load=True)
        log: list = []
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W90-layout.toml"
            path.write_text('id = "W90"\ntitle = "t"\nconfig = "language = en"\nbackdrop = false\n'
                            'backdrop_reason = "mock"\n[[step]]\naction = "capture"\nname = "x"\n', encoding="utf-8")
            run = gui.ScenarioRun(gui.load_scenario(path), Path("ghostty.exe"), Path(tmp) / "out")
            instance = mock.Mock()
            instance.log = Path(tmp) / "absent.log"
            instance.popups.return_value = []
            instance.capture_window.return_value.save_png.side_effect = lambda target: target
            instance.original_layout, instance.loaded_layouts = 0x08040804, [0x04070407]
            instance.restore_layout.side_effect = lambda: log.append("switch back") or "switched back"
            instance.close.side_effect = lambda: log.append("close") or "closed"
            instance.unload_layouts.side_effect = lambda: log.append("unload") or ["unloaded 0x04070407"]
            with mock.patch.object(gui, "launch", return_value=instance), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                report = run.run()
        self.assertEqual(["switch back", "close", "unload"], log)
        self.assertEqual({"switched_back": "switched back", "unloaded": ["unloaded 0x04070407"]}, report["layouts"])
        with tempfile.TemporaryDirectory() as tmp:
            saved = gui.Instance(1, "C:/g/ghostty.exe", Path(tmp), creation=1, launched=0,
                                 original_layout=0x08040804, loaded_layouts=[0x04070407])
            saved.save()
            again = gui.Instance.load(Path(tmp))
            self.assertEqual((0x08040804, [0x04070407]), (again.original_layout, again.loaded_layouts))
        parser = gui.build_parser()
        args = parser.parse_args(["layout", "E:/env", "--list"])
        self.assertEqual((None, True, False), (args.target, args.list, args.allow_load))
        args = parser.parse_args(["layout", "E:/env", "00000407", "--allow-load"])
        self.assertEqual(("00000407", True), (args.target, args.allow_load))
        self.assertTrue(parser.parse_args(["run", "--allow-load-layouts", "W01"]).allow_load_layouts)


class BlockedTests(unittest.TestCase):
    """A keyboard layout this user has not loaded is a missing host precondition: BLOCKED, exit 3."""

    @staticmethod
    def steps(*raw):
        return [gui.validate_step(f"s{index}", item) for index, item in enumerate(raw, 1)]

    def test_layout_blockers(self):
        steps = self.steps({"action": "ime_off"}, {"action": "layout", "target": "0x04070407"},
                           {"action": "layout", "target": "00000407"}, {"action": "layout", "target": "0x08040804"})
        self.assertEqual([], gui.layout_blockers(steps, [0x08040804, 0x04090409, 0x04070407]))
        reasons = gui.layout_blockers(steps, [0x08040804])
        self.assertEqual(["step 1 ime_off needs a loaded English (US) layout (GetKeyboardLayoutList: 0x08040804)",
                          "step 2 layout 0x04070407 is not loaded (GetKeyboardLayoutList: 0x08040804)",
                          "step 3 layout 00000407 is not loaded (GetKeyboardLayoutList: 0x08040804); only "
                          "--allow-load-layouts, in the VM, may load it"], reasons)
        self.assertEqual(reasons[:2], gui.layout_blockers(steps, [0x08040804], allow_load=True))
        self.assertEqual([], gui.layout_blockers(self.steps({"action": "sleep", "seconds": 1}), []))

    def run_all(self, scenarios, layouts, launch=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            exe = root / "ghostty.exe"
            exe.write_bytes(b"")
            paths = []
            for name, body in scenarios.items():
                path = root / f"{name}-x.toml"
                path.write_text(f'id = "{name}"\ntitle = "t"\nconfig = "language = en"\nbackdrop = false\n'
                                f'backdrop_reason = "mock"\n' + body + '[[step]]\naction = "capture"\nname = "x"\n',
                                encoding="utf-8")
                paths.append(path)
            fake = FakeWin32(1, 1)
            fake.layouts = list(layouts)
            out = root / "out"
            stderr = io.StringIO()
            with mock.patch.object(gui, "win32", return_value=fake), \
                    mock.patch.object(gui, "launch", side_effect=launch or AssertionError("nothing may start")), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                code = gui.run_scenarios(paths, exe=exe, out=out, allow_side_effects=False, retries=1, keep_open=False)
            reports = {name: json.loads((out / name / "run.json").read_text(encoding="utf-8")) for name in scenarios}
            notes = {name: (out / name / "notes.txt").read_text(encoding="utf-8") for name in scenarios}
            return code, (out / "SUMMARY.txt").read_text(encoding="utf-8"), reports, notes, stderr.getvalue()

    def test_a_scenario_that_needs_a_missing_layout_is_blocked_before_it_starts(self):
        code, summary, reports, notes, stderr = self.run_all({"W90": '[[step]]\naction = "ime_off"\n'}, [0x08040804])
        self.assertEqual(3, code)
        self.assertIn("W90 BLOCKED t: step 1 ime_off needs a loaded English (US) layout", summary)
        self.assertIn("record them PENDING with the reason, never PASS", summary)
        self.assertEqual(("blocked", 1), (reports["W90"]["status"], len(reports["W90"]["blockers"])))
        self.assertIn("BLOCKED: a precondition of this machine is missing", notes["W90"])
        self.assertIn("W90 BLOCKED before the start", stderr)

    def test_a_failure_elsewhere_still_exits_1(self):
        code, summary, reports, _, _ = self.run_all(
            {"W90": '[[step]]\naction = "ime_off"\n', "W91": '[[step]]\naction = "sleep"\nseconds = 0\n'},
            [0x08040804], launch=gui.GuiError("ghostty pid 1 exited right after the start"))
        self.assertEqual(1, code)
        self.assertEqual(("blocked", "failed", 2), (reports["W90"]["status"], reports["W91"]["status"],
                                                    reports["W91"]["attempt"]))

    def test_a_layout_that_disappears_during_the_run_blocks_it_and_is_not_retried(self):
        instance = mock.Mock()
        instance.pid, instance.creation, instance.original_layout, instance.loaded_layouts = 1, 1, None, []
        instance.log = Path("absent.log")
        instance.wait_window.return_value = {}
        instance.close.return_value = "closed"
        instance.ime_off.side_effect = gui.Blocked("no English (US) keyboard layout is loaded for this user")
        code, summary, reports, notes, _ = self.run_all({"W90": '[[step]]\naction = "ime_off"\n'},
                                                        [0x08040804, 0x04090409], launch=lambda *a, **k: instance)
        self.assertEqual((3, "blocked", 1), (code, reports["W90"]["status"], reports["W90"]["attempt"]))
        self.assertEqual([], reports["W90"]["captures"], "no failure screenshot for a missing precondition")
        self.assertIn("W90 BLOCKED t:", summary)

    def test_the_session_commands_exit_3(self):
        instance = mock.Mock(spec=gui.Instance)
        instance.alive.return_value = True
        instance.ime_off.side_effect = gui.Blocked("no English (US) keyboard layout is loaded for this user")
        stderr = io.StringIO()
        with mock.patch.object(gui.Instance, "load", return_value=instance), contextlib.redirect_stderr(stderr):
            self.assertEqual(3, gui.main(["ime-off", "E:/env"]))
        self.assertIn("BLOCKED: no English (US) keyboard layout", stderr.getvalue())
        fake = FakeWin32(1, 1)
        fake.layouts = [0x08040804]
        layout = gui.Instance(1, "C:/g/ghostty.exe", Path("E:/ev/env"), creation=1, launched=0)
        with mock.patch.object(gui, "win32", return_value=fake), self.assertRaises(gui.Blocked), \
                mock.patch.object(gui.Instance, "require_window", return_value=LayoutTests.MAIN):
            layout.switch_layout("00000407")


class VmGuardTests(unittest.TestCase):
    """--allow-load (run: --allow-load-layouts) loads keyboard layouts only inside the test VM."""

    HOST = "ASUS System Product Name American Megatrends Inc. 1701 ASUSTeK COMPUTER INC."
    VM = "QEMU Standard PC (Q35 + ICH9, 2009) EDK II edk2-stable202408 QEMU"

    def test_both_the_marker_and_the_vm_firmware_are_needed(self):
        cases = {
            "host": ({}, self.HOST, r"GX_WIN_GUI_VM=1 is not set; the firmware \(ASUS .*\) is not the test VM's"),
            "host with the marker": ({"GX_WIN_GUI_VM": "1"}, self.HOST, r"only runs inside the test VM: the firmware"),
            "VM without the marker": ({}, self.VM, r"only runs inside the test VM: GX_WIN_GUI_VM=1 is not set; nothing"),
            "marker not 1": ({"GX_WIN_GUI_VM": "yes"}, self.VM, r"GX_WIN_GUI_VM=1 is not set"),
            "no firmware strings": ({"GX_WIN_GUI_VM": "1"}, "", r"the firmware \(unknown\)"),
        }
        for name, (environ, bios, expected) in cases.items():
            with self.subTest(case=name), self.assertRaisesRegex(gui.UsageError, expected):
                gui.vm_guard("--allow-load-layouts", environ, lambda bios=bios: bios)
        self.assertEqual(f"test VM: GX_WIN_GUI_VM=1, firmware {self.VM}",
                         gui.vm_guard("x", {"GX_WIN_GUI_VM": "1"}, lambda: self.VM))

    def test_nothing_is_loaded_or_started_on_the_host(self):
        fake = FakeWin32(1, 1)
        fake.layouts = [0x08040804]
        instance = gui.Instance(1, "C:/g/ghostty.exe", Path("E:/ev/env"), creation=1, launched=0)
        with mock.patch.object(gui, "win32", return_value=fake), mock.patch.object(gui, "bios_description",
                                                                                   return_value=self.HOST), \
                mock.patch.dict(os.environ, {"GX_WIN_GUI_VM": ""}), \
                mock.patch.object(gui.Instance, "require_window", return_value=LayoutTests.MAIN):
            with self.assertRaisesRegex(gui.UsageError, "loading keyboard layout 00000407 only runs inside the test VM"):
                instance.switch_layout("00000407", allow_load=True)
            self.assertEqual(([], []), (fake.loaded, instance.loaded_layouts))
            with tempfile.TemporaryDirectory() as tmp:
                exe = Path(tmp) / "ghostty.exe"
                exe.write_bytes(b"")
                scenario = Path(tmp) / "W90-x.toml"
                scenario.write_text('id = "W90"\ntitle = "t"\nconfig = "language = en"\n[[step]]\naction = "layout"\n'
                                    'target = "00000407"\n[[step]]\naction = "capture"\nname = "x"\n', encoding="utf-8")
                stderr = io.StringIO()
                with mock.patch.object(gui, "launch", side_effect=AssertionError("nothing may start")), \
                        contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
                    code = gui.main(["run", "--exe", str(exe), "--out", str(Path(tmp) / "out"), "--allow-load-layouts",
                                     str(scenario)])
                    self.assertEqual(2, code)
                    self.assertIn("--allow-load-layouts only runs inside the test VM", stderr.getvalue())
                    self.assertFalse((Path(tmp) / "out").exists())
                    session = mock.Mock(spec=gui.Instance)
                    session.alive.return_value = True
                    with mock.patch.object(gui.Instance, "load", return_value=session):
                        self.assertEqual(2, gui.main(["layout", str(Path(tmp) / "env"), "00000407", "--allow-load"]))
                    session.switch_layout.assert_not_called()

    def test_inside_the_vm_run_json_and_notes_record_it(self):
        instance = mock.Mock()
        instance.pid, instance.creation, instance.original_layout, instance.loaded_layouts = 1, 1, None, []
        instance.log = Path("absent.log")
        instance.wait_window.return_value = {}
        instance.close.return_value = "closed"
        instance.switch_layout.return_value = "keyboard layout 0x08040804 -> 0x04070407 (loaded 00000407)"
        instance.capture_window.return_value.save_png.side_effect = lambda target: target
        instance.popups.return_value = []
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "ghostty.exe"
            exe.write_bytes(b"")
            path = Path(tmp) / "W90-x.toml"
            path.write_text('id = "W90"\ntitle = "t"\nconfig = "language = en"\nbackdrop = false\nbackdrop_reason = "mock"\n'
                            '[[step]]\naction = "layout"\ntarget = "00000407"\n[[step]]\naction = "capture"\nname = "x"\n',
                            encoding="utf-8")
            fake = FakeWin32(1, 1)
            fake.layouts = [0x08040804]
            with mock.patch.object(gui, "win32", return_value=fake), mock.patch.object(gui, "launch", return_value=instance), \
                    mock.patch.object(gui, "bios_description", return_value=self.VM), \
                    mock.patch.dict(os.environ, {"GX_WIN_GUI_VM": "1"}), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = gui.run_scenarios([path], exe=exe, out=Path(tmp) / "out", allow_side_effects=False, retries=0,
                                         keep_open=False, allow_load_layouts=True)
            report = json.loads((Path(tmp) / "out" / "W90" / "run.json").read_text(encoding="utf-8"))
            notes = (Path(tmp) / "out" / "W90" / "notes.txt").read_text(encoding="utf-8")
        self.assertEqual((0, "ok"), (code, report["status"]))
        self.assertEqual(f"test VM: GX_WIN_GUI_VM=1, firmware {self.VM}", report["allow_load_layouts"])
        self.assertIn("keyboard layouts: --allow-load-layouts (test VM: GX_WIN_GUI_VM=1, firmware QEMU", notes)
        instance.switch_layout.assert_called_once_with("00000407", allow_load=True)


class RestartTests(unittest.TestCase):
    BODY = ('id = "W90"\ntitle = "t"\nconfig = "language = en"\nbackdrop = false\nbackdrop_reason = "mock"\n'
            'args = ["--x"]\n[env]\nGHOSTTY_GX_OPENGL = "software"\nKEEP = "1"\n')

    def scenario(self, tmp: str, steps: str = '[[step]]\naction = "capture"\nname = "x"\n'):
        path = Path(tmp) / "W90-restart.toml"
        path.write_text(self.BODY + steps, encoding="utf-8")
        return gui.load_scenario(path)

    def test_validation(self):
        ok = gui.validate_step("s", {"action": "restart", "timeout": 30, "wait": False,
                                     "env": {"GHOSTTY_GX_A11Y": "screen-reader"}})
        self.assertEqual("restart", ok.action)
        cases = {"map variable names to strings": {"env": {"A": 1}},
                 "cannot change the isolated paths: LocalAppData": {"env": {"LocalAppData": "C:/x"}},
                 "wait must be true or false": {"wait": "no"},
                 "timeout must be a number": {"timeout": 0}}
        for expected, raw in cases.items():
            with self.subTest(case=expected), self.assertRaisesRegex(gui.UsageError, expected):
                gui.validate_step("s", {"action": "restart", **raw})
        with self.assertRaisesRegex(gui.UsageError, "timeout must be a number"):
            gui.validate_step("s", {"action": "restart", "timeout": 121})

    def test_close_without_force_never_terminates(self):
        fake = FakeWin32(4242, 4242)
        instance = gui.Instance(4242, "C:/g/ghostty.exe", Path("E:/ev/env"), creation=1, launched=0)
        with mock.patch.object(gui, "win32", return_value=fake), mock.patch.object(gui.time, "sleep"):
            with self.assertRaisesRegex(gui.GuiError, "did not exit within 0s after WM_CLOSE; not forcing it"):
                instance.close(0, force=False)
            self.assertFalse(instance.closing)
            self.assertFalse(hasattr(fake, "terminated"))
            self.assertEqual("terminated", instance.close(0))
        self.assertEqual([4242], fake.terminated)

    def test_restart_starts_the_same_profile_again_with_the_overrides(self):
        with tempfile.TemporaryDirectory() as tmp:
            scenario = self.scenario(tmp)
            run = gui.ScenarioRun(scenario, Path("ghostty.exe"), Path(tmp))
            old = mock.Mock(spec=gui.Instance)
            old.pid, old.creation, old.env_dir, old.restarts = 100, 7, Path(tmp) / "env", []
            old.original_layout, old.loaded_layouts = 0x08040804, [0x04070407]
            old.close.return_value = "closed"
            new = mock.Mock(spec=gui.Instance)
            new.pid, new.creation = 200, 9
            new.wait_window.return_value = {"shown_ms": 321.0}
            run.instance = old
            with mock.patch.object(gui, "launch", return_value=new) as launched:
                detail = run.do_restart({"timeout": 15, "env": {"GHOSTTY_GX_A11Y": "screen-reader"}})
            self.assertEqual("pid 100 closed; restarted as pid 200 with GHOSTTY_GX_A11Y=screen-reader", detail)
            old.close.assert_called_once_with(15.0, force=False)
            launched.assert_called_once_with(Path("ghostty.exe"), Path(tmp) / "env", config=None,
                                             env={"GHOSTTY_GX_OPENGL": "software", "KEEP": "1",
                                                  "GHOSTTY_GX_A11Y": "screen-reader"}, args=["--x"])
            new.wait_window.assert_called_once_with(20)
            new.activate.assert_called_once_with()
            self.assertIs(new, run.instance)
            record = run.restarts[0]
            self.assertEqual((100, "7", "closed", 200, "9", {"GHOSTTY_GX_A11Y": "screen-reader"}, {"shown_ms": 321.0}),
                             (record["old_pid"], record["old_creation_filetime_100ns"], record["closed"],
                              record["new_pid"], record["new_creation_filetime_100ns"], record["env_overrides"],
                              record["startup_ms"]))
            self.assertEqual([record], new.restarts)
            self.assertEqual((0x08040804, [0x04070407]), (new.original_layout, new.loaded_layouts))

    def test_restart_refuses_held_buttons_a_gone_instance_and_a_close_that_hangs(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = gui.ScenarioRun(self.scenario(tmp), Path("ghostty.exe"), Path(tmp))
            run.instance = mock.Mock(spec=gui.Instance)
            run.held_buttons = ["left"]
            with self.assertRaisesRegex(gui.GuiError, r"held mouse buttons \(left\)"):
                run.do_restart({})
            run.instance.close.assert_not_called()
            run.held_buttons = []
            run.instance.pid = 100
            run.instance.close.return_value = "not running"
            with mock.patch.object(gui, "launch") as launched:
                with self.assertRaisesRegex(gui.GuiError, "was not running any more"):
                    run.do_restart({})
                run.instance.close.side_effect = gui.GuiError("did not exit within 10s after WM_CLOSE; not forcing it")
                with self.assertRaisesRegex(gui.GuiError, "not forcing it"):
                    run.do_restart({})
                launched.assert_not_called()
            self.assertEqual([], run.restarts)

    def test_restarts_reach_run_json_and_the_session_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            scenario = self.scenario(tmp, '[[step]]\naction = "restart"\nwait = false\n'
                                          '[[step]]\naction = "capture"\nname = "x"\n')
            run = gui.ScenarioRun(scenario, Path("ghostty.exe"), Path(tmp) / "out")
            old, new = mock.Mock(), mock.Mock()
            for instance, pid in ((old, 100), (new, 200)):
                instance.pid, instance.creation, instance.restarts = pid, pid, []
                instance.env_dir = Path(tmp) / "out" / "env"
                instance.log = Path(tmp) / "absent.log"
                instance.popups.return_value = []
                instance.capture_window.return_value.save_png.side_effect = lambda target: target
            old.close.return_value = "closed"
            with mock.patch.object(gui, "launch", side_effect=[old, new]), \
                    mock.patch.object(gui, "win32", return_value=FakeWin32(4242, 4242)), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                report = run.run()
            self.assertEqual("ok", report["status"])
            self.assertEqual([(100, 200)], [(item["old_pid"], item["new_pid"]) for item in report["restarts"]])
            self.assertNotIn("startup_ms", report["restarts"][0])
            new.close.assert_called_once_with()
            saved = gui.Instance(200, "C:/g/ghostty.exe", Path(tmp), creation=1, launched=0, restarts=report["restarts"])
            saved.save()
            self.assertEqual(report["restarts"], gui.Instance.load(Path(tmp)).restarts)


class ScenarioReleaseTests(unittest.TestCase):
    BODY = ('id = "W90"\ntitle = "t"\nconfig = "language = en"\n'
            'backdrop = false\nbackdrop_reason = "the release tests capture through a mock"\n')

    def run_scenario(self, steps: str, capture_error: bool):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W90-release.toml"
            path.write_text(self.BODY + steps, encoding="utf-8")
            run = gui.ScenarioRun(gui.load_scenario(path), Path("ghostty.exe"), Path(tmp) / "out")
            instance = mock.Mock()
            instance.log = Path(tmp) / "absent.log"
            instance.popups.return_value = []
            instance.point.return_value = (5, 6)
            if capture_error:
                instance.capture_window.side_effect = gui.GuiError("capture failed")
            else:
                instance.capture_window.return_value.save_png.side_effect = lambda target: target
            fake = FakeWin32(4242, 4242)
            with mock.patch.object(gui, "launch", return_value=instance), mock.patch.object(gui, "win32", return_value=fake), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                report = run.run()
            return report, instance

    def test_scenario_stopped_after_mouse_down_releases_the_button_only(self):
        down = '[[step]]\naction = "mouse_down"\nbutton = "x2"\nx = 5\ny = 6\n'
        report, instance = self.run_scenario(down + '[[step]]\naction = "capture"\nname = "held"\n', capture_error=True)
        self.assertEqual("failed", report["status"])
        self.assertEqual(["x2"], report["released_buttons"])
        instance.release_input.assert_called_once_with([("mouse", 0x100, 0, 0, 2)], "x2", True)
        instance.close.assert_called_once()
        up = '[[step]]\naction = "mouse_up"\nbutton = "x2"\nx = 5\ny = 6\n'
        report, instance = self.run_scenario(down + up + '[[step]]\naction = "capture"\nname = "done"\n', capture_error=False)
        self.assertEqual("ok", report["status"])
        self.assertNotIn("released_buttons", report)
        instance.release_input.assert_not_called()
        # A completed scenario that never released its press is cleaned up too, without the abort label.
        report, instance = self.run_scenario(down + '[[step]]\naction = "capture"\nname = "left-held"\n', capture_error=False)
        self.assertEqual(["x2"], report["released_buttons"])
        instance.release_input.assert_called_once_with([("mouse", 0x100, 0, 0, 2)], "x2", False)


def screen(region, paint=(), color=(255, 255, 255)):
    """A black screen capture of `region` with the `paint` rectangles in `color`."""
    left, top, right, bottom = region
    width, height = right - left, bottom - top
    data = bytearray(b"\x00\x00\x00\xff" * (width * height))
    pixel = bytes((color[2], color[1], color[0], 0xFF))
    for x0, y0, x1, y1 in paint:
        x0, x1 = max(x0, left), min(x1, right)
        if x0 >= x1:
            continue
        for y in range(max(y0, top), min(y1, bottom)):
            offset = ((y - top) * width + (x0 - left)) * 4
            data[offset:offset + (x1 - x0) * 4] = pixel * (x1 - x0)
    return gui.Image(width, height, bytes(data), left, top)


# The host's monitors as EnumDisplayMonitors reports them to a Per-Monitor-V2 process (both at 150 %):
# DISPLAY1, the primary, and DISPLAY2, a portrait monitor left of it that reaches higher and lower.
HOST_MONITORS = [((0, 0, 3840, 2160), (0, 0, 3840, 2088)), ((-2160, -419, 0, 3421), (-2160, -419, 0, 3349))]
# The same arrangement, smaller, for the tests that build screen images.
SMALL_MONITORS = [((0, 0, 1000, 800), (0, 0, 1000, 760)), ((-600, -100, 0, 900), (-600, -100, 0, 860))]


REAL_BACKDROP_WINDOW = gui.BackdropWindow


class FakeBackdropWindow:
    """Stands in for BackdropWindow: nothing is created on the desktop."""

    made: list = []
    close_error: Exception | None = None  # what close() raises, as a thread that does not end would

    def __init__(self, color):
        self.color = color
        self.hwnd = 0xB0
        self.opened = None
        self.placed: list = []
        self.closed = 0
        FakeBackdropWindow.made.append(self)

    def open(self, rect):
        self.opened = rect

    def place(self, rect, under):
        self.placed.append((rect, under))

    def close(self):
        self.closed += 1
        if FakeBackdropWindow.close_error is not None:
            raise FakeBackdropWindow.close_error
        return "destroyed"


class BackdropTests(unittest.TestCase):
    PID = 4242
    WINDOW = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", (100, 100, 140, 130), True, False, False)
    PROBE = (76, 76, 164, 154)  # the window and its 24 DIP band at 96 dpi

    def setUp(self):
        FakeBackdropWindow.made = []
        FakeBackdropWindow.close_error = None
        self.fake = FakeWin32(self.PID, self.PID)
        self.main = gui.StackEntry(0x10, gui.WINDOW_CLASS, self.WINDOW.rect, self.PID, self.PID)
        self.backdrop_entry = gui.StackEntry(0xB0, gui.BACKDROP_CLASS + "000000", (0, 0, 1000, 800), 1, 1)
        self.fake.stack = [self.main, self.backdrop_entry]
        self.instance = mock.Mock(spec=gui.Instance)
        self.instance.pid = self.PID
        self.frames = []

        def capture_window(info, method, region=None, see_through=()):
            if method == "print":
                return screen(info.rect, [info.rect])
            frame = self.frames.pop(0) if self.frames else []
            return screen(region or info.rect, [info.rect] + list(frame))

        self.instance.capture_window.side_effect = capture_window
        patches = [mock.patch.object(gui, "win32", return_value=self.fake),
                   mock.patch.object(gui, "BackdropWindow", FakeBackdropWindow),
                   mock.patch.object(gui.time, "sleep")]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_pure_helpers(self):
        self.assertEqual((5, 5, 10, 10), gui.rect_intersection((0, 0, 10, 10), (5, 5, 20, 20)))
        self.assertIsNone(gui.rect_intersection((0, 0, 10, 10), (10, 0, 20, 10)))
        self.assertEqual((-5, 0, 30, 40), gui.rect_union([(0, 0, 10, 10), (-5, 20, 30, 40), (50, 50, 50, 60)]))
        self.assertIsNone(gui.rect_union([(0, 0, 0, 10)]))
        self.assertEqual((-2, -2, 12, 12), gui.rect_inflate((0, 0, 10, 10), 2))
        self.assertEqual((150, 0), (gui.rect_area((0, 0, 10, 15)), gui.rect_area((0, 0, -1, 15))))
        self.assertEqual([(0, 0, 10, 10)], gui.rect_subtract((0, 0, 10, 10), []))
        self.assertEqual([], gui.rect_subtract((0, 0, 10, 10), [(-5, -5, 20, 20)]))
        pieces = gui.rect_subtract((0, 0, 10, 10), [(2, 3, 5, 6), (8, 0, 20, 20)])
        self.assertEqual(100 - 9 - 20, sum(gui.rect_area(piece) for piece in pieces))
        for a, b in itertools.combinations(pieces, 2):
            self.assertIsNone(gui.rect_intersection(a, b), (a, b))
        self.assertEqual([(-300, 200, 0, 700)], gui.rect_subtract((-300, 200, 500, 700), [(0, 0, 3840, 2088)]))
        self.assertEqual([(0, 1), (3, 9)], gui.row_spans([(3, 0, 9, 5), (0, 0, 1, 5), (4, 0, 6, 5), (20, 0, 30, 5)],
                                                          2, 0, 10))
        self.assertEqual([(0, 2), (5, 6), (9, 10)], gui.spans_without([(0, 10)], [(2, 5), (6, 9)]))
        self.assertEqual(gui.MA_NOACTIVATE, gui.backdrop_message(gui.WM_MOUSEACTIVATE))
        self.assertIsNone(gui.backdrop_message(gui.WM_CLOSE))

    def test_shade_accepts_the_color_and_its_shadows_only(self):
        self.assertTrue(gui.backdrop_shade((0, 0, 0), (0, 0, 0)))
        self.assertTrue(gui.backdrop_shade((2, 1, 2), (0, 0, 0)))
        self.assertFalse(gui.backdrop_shade((3, 0, 0), (0, 0, 0)))
        magenta = (200, 100, 50)
        for pixel in ((200, 100, 50), (100, 50, 25), (20, 10, 5), (0, 0, 0), (201, 99, 51)):
            with self.subTest(pixel=pixel):
                self.assertTrue(gui.backdrop_shade(pixel, magenta))
        for pixel in ((100, 100, 50), (230, 115, 57), (255, 255, 255), (50, 100, 200)):
            with self.subTest(pixel=pixel):
                self.assertFalse(gui.backdrop_shade(pixel, magenta))

    def test_band_counts_only_pixels_outside_the_instance_windows(self):
        image = screen((0, 0, 10, 10), [(3, 3, 7, 7)])
        self.assertEqual({"checked_pixels": 84, "foreign_pixels": 0, "first_foreign": None},
                         gui.backdrop_band(image, [(3, 3, 7, 7), (50, 0, 60, 10), (-20, 0, -10, 10)], (0, 0, 0)))
        # inside: only those pieces count; a white corner outside them (the taskbar) is never looked at.
        corner = screen((0, 0, 10, 10), [(3, 3, 7, 7), (8, 8, 10, 10)])
        self.assertEqual({"checked_pixels": 20 + 10 - 2, "foreign_pixels": 0, "first_foreign": None},
                         gui.backdrop_band(corner, [(3, 3, 7, 7)], (0, 0, 0), inside=[(0, 0, 10, 2), (0, 0, 1, 10)]))
        stats = gui.backdrop_band(screen((0, 0, 10, 10), [(3, 3, 7, 7), (9, 0, 10, 1)]), [(3, 3, 7, 7)], (0, 0, 0))
        self.assertEqual((84, 1, [9, 0, "#ffffff"]), (stats["checked_pixels"], stats["foreign_pixels"], stats["first_foreign"]))
        offset = screen((-30, 40, -20, 50), [(-25, 45, -24, 46)], color=(9, 9, 9))
        self.assertEqual([-25, 45, "#090909"], gui.backdrop_band(offset, [], (0, 0, 0))["first_foreign"])

    def test_audit_lists_other_processes_above_the_backdrop_only(self):
        area = (0, 0, 100, 100)
        foreign = gui.StackEntry(0x1, "Chrome_WidgetWin_1", (50, 50, 300, 300), 777, 777)
        stack = [foreign,
                 gui.StackEntry(0x2, "Elsewhere", (200, 200, 300, 300), 777, 777),
                 gui.StackEntry(0x3, "Cloaked", (0, 0, 100, 100), 777, 777, cloaked=True),
                 gui.StackEntry(0x4, "Minimized", (0, 0, 100, 100), 777, 777, iconic=True),
                 gui.StackEntry(0x5, "Empty", (10, 10, 10, 50), 777, 777),
                 gui.StackEntry(0x6, "IME", (0, 0, 100, 100), 778, self.PID),
                 gui.StackEntry(0x7, gui.POPUP_CLASS, (0, 0, 100, 100), self.PID, self.PID),
                 gui.StackEntry(0xB0, "backdrop", (0, 0, 1000, 800), 1, 1),
                 gui.StackEntry(0x8, "Below", (0, 0, 100, 100), 777, 777)]
        self.assertEqual(([foreign], True), gui.backdrop_audit(stack, 0xB0, self.PID, [area]))
        self.assertEqual(([foreign], False), gui.backdrop_audit(stack[:3], 0xB0, self.PID, [area]))
        # Only the areas count, not their bounding rectangle: 0x2 lies between the two.
        self.assertEqual(([foreign], True), gui.backdrop_audit(stack, 0xB0, self.PID, [area, (400, 400, 500, 500)]))
        self.assertEqual(([], True), gui.backdrop_audit(stack, 0xB0, self.PID, [(0, 0, 40, 40), (400, 400, 500, 500)]))

    def test_above_backdrop(self):
        popup = gui.StackEntry(0x20, gui.POPUP_CLASS, (0, 0, 10, 10), self.PID, self.PID)
        hidden = gui.StackEntry(0x30, gui.POPUP_CLASS, (0, 0, 10, 10), self.PID, self.PID, iconic=True)
        stack = [popup, hidden, self.backdrop_entry, self.main]
        self.assertEqual([True, False, False, False],
                         [gui.above_backdrop(stack, 0xB0, hwnd) for hwnd in (0x20, 0x30, 0x10, 0x99)])
        self.assertTrue(gui.above_backdrop([self.main], 0xB0, 0x10), "with no backdrop in the stack it is not under it")

    def test_a_window_that_falls_under_the_backdrop_fails_the_capture(self):
        self.fake.stack = [self.backdrop_entry, self.main]
        with self.assertRaisesRegex(gui.GuiError, r"window 0x10 is not above the backdrop.*not saved"):
            gui.Backdrop("#000000").capture(self.instance, self.WINDOW, "screen", "01-under.png")
        # Above it before the capture, under it right after: still a failure, and never retried.
        backdrop = gui.Backdrop("#000000")
        over, under = [self.main, self.backdrop_entry], [self.backdrop_entry, self.main]
        self.fake.window_stack = mock.Mock(side_effect=[over, over, under])
        with self.assertRaisesRegex(gui.GuiError, r"not above the backdrop"):
            backdrop.capture(self.instance, self.WINDOW, "screen", "02-under.png")
        self.assertEqual((False, 1, "fail"), (backdrop.checks[0]["window_above_backdrop"], backdrop.checks[0]["attempts"],
                                              backdrop.checks[0]["status"]))

    def test_cover_reaches_every_monitor_the_windows_or_the_band_reach(self):
        primary, portrait = HOST_MONITORS[0], HOST_MONITORS[1]
        cases = {
            "away from the edge": ([(800, 400, 2400, 1400)], [], [primary[1]]),
            "across x = 0": ([(-600, 300, 1200, 1200)], [], [primary[1], portrait[1]]),
            "only the band crosses": ([(20, 300, 1200, 1200)], [gui.rect_inflate((20, 300, 1200, 1200), 36)],
                                      [primary[1], portrait[1]]),
            "the band stays on the primary": ([(40, 300, 1200, 1200)], [gui.rect_inflate((40, 300, 1200, 1200), 36)],
                                              [primary[1]]),
            "maximized": ([primary[1]], [gui.rect_inflate(primary[1], 36)], [primary[1], portrait[1]]),
            "fullscreen over the taskbar": ([primary[0]], [gui.rect_inflate(primary[0], 36)], [primary[0], portrait[1]]),
            "on the portrait's taskbar": ([(-900, 3300, -100, 3400)], [], [portrait[0]]),
            "on no monitor": ([(1000, -900, 1400, -500)], [], []),
        }
        for name, (windows, wanted, expected) in cases.items():
            with self.subTest(case=name):
                self.assertEqual(expected, gui.backdrop_cover(HOST_MONITORS, windows, wanted))

    def test_the_band_goes_on_across_a_covered_neighbour_and_never_over_a_taskbar(self):
        primary_work = HOST_MONITORS[0][1]
        window = (20, 300, 1200, 1200)
        cover = gui.backdrop_cover(HOST_MONITORS, [window], [gui.rect_inflate(window, 36)])
        pieces = gui.backdrop_regions(window, 36, cover)
        self.assertEqual(4 * 36 * 36 + 2 * 36 * (1200 - 20) + 2 * 36 * 900,
                         sum(gui.rect_area(piece) for piece in pieces))
        self.assertTrue(any(piece[2] <= 0 for piece in pieces), "the band on the portrait monitor")
        self.assertEqual([], [piece for piece in pieces if gui.rect_intersection(piece, window)])
        # Only the band on a covered area: without the portrait monitor the band ends at x = 0.
        self.assertTrue(all(piece[0] >= 0 for piece in gui.backdrop_regions(window, 36, [primary_work])))
        # Maximized on the primary, whose taskbar is lower than the portrait's: the band is the strip on
        # the portrait monitor; the taskbar below the window is in no piece, so the audit never sees it.
        cover = gui.backdrop_cover(HOST_MONITORS, [primary_work], [gui.rect_inflate(primary_work, 36)])
        pieces = gui.backdrop_regions(primary_work, 36, cover)
        self.assertEqual([(-36, -36, 0, 2124)], pieces)
        taskbar = gui.StackEntry(0x77, "Shell_TrayWnd", (0, 2088, 3840, 2160), 900, 900)
        maximized = gui.StackEntry(0x10, gui.WINDOW_CLASS, primary_work, self.PID, self.PID)
        stack = [taskbar, maximized, self.backdrop_entry]
        self.assertEqual(([], True), gui.backdrop_audit(stack, 0xB0, self.PID, [primary_work, *pieces]))
        self.assertIsNotNone(gui.rect_intersection(taskbar.rect, gui.rect_union([primary_work, *pieces])))

    def test_screen_capture_through_a_checked_backdrop(self):
        backdrop = gui.Backdrop("#000000")
        image = backdrop.capture(self.instance, self.WINDOW, "screen", "01-x.png")
        window = FakeBackdropWindow.made[0]
        self.assertEqual(((0, 0, 0), (0, 0, 1000, 800)), (window.color, window.opened))
        self.assertEqual([((0, 0, 1000, 800), 0x10)], window.placed)
        self.instance.capture_window.assert_called_once_with(self.WINDOW, "screen", region=self.PROBE, see_through=(0xB0,))
        self.assertEqual((40, 30, 100, 100), (image.width, image.height, image.left, image.top))
        check = backdrop.checks[0]
        self.assertEqual(("pass", 88 * 78 - 44 * 34, 0, 1, [], True),
                         (check["status"], check["checked_pixels"], check["foreign_pixels"], check["attempts"],
                          check["foreign_windows"], check["window_above_backdrop"]))
        result = backdrop.finish()
        self.assertEqual(1, window.closed)
        self.assertEqual(["created", "destroyed"], [event["event"] for event in result["events"]])
        self.assertEqual({"color": "#000000", "reason": None}, result["initial"])
        self.assertEqual((1, 1), (result["placements"], result["restacks"]))

    def test_a_backdrop_out_of_place_is_put_back_and_given_time_to_compose(self):
        backdrop = gui.Backdrop("#000000")
        backdrop.ensure(self.instance)  # new: restacked and fresh
        backdrop.fresh = False
        with mock.patch.object(gui.time, "sleep") as sleep:
            backdrop.ensure(self.instance)  # already right under the instance: nothing to wait for
            sleep.assert_not_called()
            foreign = gui.StackEntry(0x99, "Chrome_WidgetWin_1", (0, 0, 50, 50), 777, 777)
            self.fake.stack = [self.main, foreign, self.backdrop_entry]  # activation left a window in between
            backdrop.ensure(self.instance)
            sleep.assert_called_once_with(gui.BACKDROP_COMPOSE_S)
        self.assertEqual((3, 2, False), (backdrop.placements, backdrop.restacks, backdrop.fresh))
        self.fake.monitor_layout = [((0, 0, 1200, 900), (0, 0, 1200, 900))]  # the monitor grew
        backdrop.ensure(self.instance)
        self.assertEqual(((0, 0, 1200, 900), True), (backdrop.area, backdrop.fresh))

    def test_the_lowest_instance_window_and_every_monitor_of_the_instance_count(self):
        popup = gui.StackEntry(0x20, gui.POPUP_CLASS, (1900, 10, 1990, 60), self.PID, self.PID)
        self.fake.stack = [popup, gui.StackEntry(0x99, "Other", (600, 600, 700, 700), 777, 777), self.main,
                           self.backdrop_entry]
        self.fake.monitor_layout = [((0, 0, 1000, 800), (0, 0, 1000, 760)), ((1000, 0, 2000, 800), (1000, 0, 2000, 800))]
        gui.Backdrop("#000000").ensure(self.instance)
        self.assertEqual([((0, 0, 2000, 800), 0x10)], FakeBackdropWindow.made[0].placed)

    def place_main(self, rect, monitors=SMALL_MONITORS):
        self.fake.monitor_layout = list(monitors)
        self.main = gui.StackEntry(0x10, gui.WINDOW_CLASS, rect, self.PID, self.PID)
        self.fake.stack = [self.main, self.backdrop_entry]
        return gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", rect, True, False, False)

    def test_a_window_across_two_monitors_is_covered_and_checked_on_both(self):
        info = self.place_main((-200, 100, 200, 300))
        backdrop = gui.Backdrop("#000000")
        backdrop.capture(self.instance, info, "screen", "01-across.png")
        window = FakeBackdropWindow.made[0]
        self.assertEqual(((-600, -100, 1000, 860), [((-600, -100, 1000, 860), 0x10)]), (window.opened, window.placed))
        self.instance.capture_window.assert_called_once_with(info, "screen", region=(-224, 76, 224, 324),
                                                             see_through=(0xB0,))
        check = backdrop.checks[0]
        self.assertEqual([[0, 0, 1000, 760], [-600, -100, 0, 860]], check["covered"])
        self.assertEqual(("pass", 448 * 248 - 404 * 204), (check["status"], check["checked_pixels"]))
        self.assertTrue(any(piece[2] <= 0 for piece in check["band_regions"]))
        self.assertTrue(any(piece[0] >= 0 for piece in check["band_regions"]))
        # A desktop pixel in the band on the portrait side fails the capture.
        self.frames = [[(-210, 200, -209, 201)]]
        with self.assertRaisesRegex(gui.GuiError, r"1 of \d+ band pixels are not #000000 \(first #ffffff at "
                                                  r"\(-210, 200\)\).*not saved"):
            backdrop.capture(self.instance, info, "screen", "02-across.png")

    def test_a_band_at_the_screen_edge_ends_there(self):
        info = self.place_main((10, 100, 300, 300), [SMALL_MONITORS[0]])
        backdrop = gui.Backdrop("#000000")
        backdrop.capture(self.instance, info, "screen", "01-edge.png")
        check = backdrop.checks[0]
        self.assertEqual(("pass", [[0, 0, 1000, 760]], [0, 76, 324, 324]), (check["status"], check["covered"], check["band"]))

    def test_a_window_partly_on_no_monitor_fails_before_any_capture_and_saves_nothing(self):
        info = self.place_main((-200, 100, 300, 400), [SMALL_MONITORS[0]])
        with tempfile.TemporaryDirectory() as tmp:
            run = gui.ScenarioRun(None, Path("ghostty.exe"), Path(tmp))  # type: ignore[arg-type]
            run.backdrop = gui.Backdrop("#000000")
            run.instance = self.instance
            self.instance.require_window.return_value = info
            with self.assertRaisesRegex(gui.GuiError, r"60000 of 150000 window pixels lie outside the privacy "
                                                      r"backdrop.*\[-200, 100, 0, 400\].*not saved"):
                run.do_capture({"name": "off-screen"})
            self.assertEqual([], list(Path(tmp).iterdir()))
        self.instance.capture_window.assert_not_called()
        check = run.backdrop.checks[0]
        self.assertEqual(("fail", [[-200, 100, 0, 400]], 60000), (check["status"], check["uncovered"],
                                                                  check["uncovered_pixels"]))

    def test_a_fullscreen_window_gets_its_whole_monitor_and_a_taskbar_on_top_fails_it(self):
        info = self.place_main((0, 0, 1000, 800), [SMALL_MONITORS[0]])
        backdrop = gui.Backdrop("#000000")
        backdrop.capture(self.instance, info, "screen", "01-fullscreen.png")
        self.assertEqual(("pass", [[0, 0, 1000, 800]]), (backdrop.checks[0]["status"], backdrop.checks[0]["covered"]))
        self.assertEqual((0, 0, 1000, 800), FakeBackdropWindow.made[0].opened)
        self.fake.stack.insert(0, gui.StackEntry(0x77, "Shell_TrayWnd", (0, 760, 1000, 800), 900, 900))
        with self.assertRaisesRegex(gui.GuiError, r"1 window\(s\) of other processes show there \(Shell_TrayWnd"):
            backdrop.capture(self.instance, info, "screen", "02-fullscreen.png")

    def test_a_maximized_window_passes_with_the_taskbar_on_top_and_saves_no_taskbar_pixel(self):
        info = self.place_main(SMALL_MONITORS[0][1])
        self.fake.stack.insert(0, gui.StackEntry(0x77, "Shell_TrayWnd", (0, 760, 1000, 800), 900, 900))
        self.frames = [[(0, 760, 1000, 800)]]  # the white taskbar below the window, inside the captured probe
        backdrop = gui.Backdrop("#000000")
        image = backdrop.capture(self.instance, info, "screen", "01-maximized.png")
        check = backdrop.checks[0]
        self.assertEqual(("pass", [-24, -24, 1000, 784], [[-24, -24, 0, 784]]),
                         (check["status"], check["band"], check["band_regions"]))
        self.assertEqual((1000, 760, 0, 0), (image.width, image.height, image.left, image.top), "it ends above the taskbar")

    def test_the_backdrop_grows_to_what_captures_need_and_never_shrinks(self):
        info = self.place_main((20, 100, 400, 400))
        backdrop = gui.Backdrop("#000000")
        self.assertEqual([(0, 0, 1000, 760)], backdrop.ensure(self.instance))
        self.assertEqual((0, 0, 1000, 760), backdrop.area)
        backdrop.fresh = False
        backdrop.capture(self.instance, info, "screen", "01-near-the-edge.png")  # its band reaches the portrait
        self.assertEqual(((-600, -100, 1000, 860), [(0, 0, 1000, 760), (-600, -100, 0, 860)]),
                         (backdrop.area, backdrop.covers))
        popup = gui.WindowInfo(0x20, gui.POPUP_CLASS, "", (600, 200, 700, 300), True, False, False)
        self.fake.stack.insert(0, gui.StackEntry(0x20, gui.POPUP_CLASS, popup.rect, self.PID, self.PID))
        backdrop.capture(self.instance, popup, "screen", "02-popup.png")
        self.assertEqual([[0, 0, 1000, 760]], backdrop.checks[1]["covered"])
        self.assertEqual((-600, -100, 1000, 860), backdrop.area, "it does not shrink back")
        result = backdrop.finish()
        self.assertEqual([], backdrop.teardown_failures())
        self.assertEqual(["created", "grown", "destroyed"], [event["event"] for event in result["events"]])
        self.assertEqual([[0, 0, 1000, 760], [-600, -100, 0, 860]], result["events"][1]["covers"])
        self.assertEqual(([], None), (backdrop.covers, backdrop.area))

    def test_another_process_in_the_capture_fails_and_nothing_is_saved(self):
        self.fake.stack.insert(0, gui.StackEntry(0x99, "Chrome_WidgetWin_1", (120, 0, 900, 120), 777, 777))
        with tempfile.TemporaryDirectory() as tmp:
            run = gui.ScenarioRun(None, Path("ghostty.exe"), Path(tmp))  # type: ignore[arg-type]
            run.backdrop = gui.Backdrop("#000000")
            run.instance = self.instance
            self.instance.require_window.return_value = self.WINDOW
            with self.assertRaisesRegex(gui.GuiError, r"1 window\(s\) of other processes show there "
                                                      r"\(Chrome_WidgetWin_1 pid 777 ghostty.exe\).*not saved"):
                run.do_capture({"name": "leak"})
            self.assertEqual([], list(Path(tmp).iterdir()))
        check = run.backdrop.checks[0]
        self.assertEqual(("fail", [{"hwnd": "0x99", "class": "Chrome_WidgetWin_1", "pid": 777, "image": "ghostty.exe"}]),
                         (check["status"], check["foreign_windows"]))
        self.assertNotIn("title", json.dumps(run.backdrop.checks))

    def test_band_pixels_get_the_settle_time_of_a_new_backdrop_only(self):
        self.frames = [[(80, 80, 81, 81)]]  # the first frame still shows the desktop in the band
        clock = iter(range(100))
        with mock.patch.object(gui.time, "monotonic", side_effect=lambda: next(clock) * 0.1):
            backdrop = gui.Backdrop("#000000")
            backdrop.capture(self.instance, self.WINDOW, "screen", "01-a.png")
            self.assertEqual(("pass", 2), (backdrop.checks[0]["status"], backdrop.checks[0]["attempts"]))
            self.frames = [[(80, 80, 81, 81)]] * 30
            with self.assertRaisesRegex(gui.GuiError, rf"1 of {88 * 78 - 44 * 34} band pixels are not #000000 "
                                                      r"\(first #ffffff at \(80, 80\)\)"):
                backdrop.capture(self.instance, self.WINDOW, "screen", "02-b.png")
        self.assertEqual(("fail", 1), (backdrop.checks[1]["status"], backdrop.checks[1]["attempts"]))

    def test_a_backdrop_missing_from_the_stack_fails(self):
        self.fake.stack = [self.main]
        with self.assertRaisesRegex(gui.GuiError, "not in the window stack"):
            gui.Backdrop("#000000").capture(self.instance, self.WINDOW, "screen", "01-x.png")

    def test_print_captures_and_a_backdrop_that_is_off_do_not_need_the_desktop(self):
        gui.Backdrop("#000000").capture(self.instance, self.WINDOW, "print", "01-x.png")
        backdrop = gui.Backdrop(None, "W14 shows the wallpaper")
        backdrop.capture(self.instance, self.WINDOW, "screen", "02-x.png")
        self.assertIsNone(backdrop.ensure(self.instance))
        self.assertEqual([mock.call(self.WINDOW, "print"), mock.call(self.WINDOW, "screen")],
                         self.instance.capture_window.call_args_list)
        self.assertEqual([], FakeBackdropWindow.made)

    def test_switching_color_or_off_replaces_or_removes_the_window(self):
        backdrop = gui.Backdrop("#000000")
        backdrop.ensure(self.instance)
        backdrop.fresh = False
        backdrop.set("#ff00ff", None)
        backdrop.ensure(self.instance)
        self.assertTrue(backdrop.fresh, "a new window gets time to paint")
        self.assertEqual([(0, 0, 0), (255, 0, 255)], [window.color for window in FakeBackdropWindow.made])
        self.assertEqual([1, 0], [window.closed for window in FakeBackdropWindow.made])
        backdrop.set(None, "check the desktop shows through")
        self.assertEqual([1, 1], [window.closed for window in FakeBackdropWindow.made])
        self.assertIsNone(backdrop.window)

    def test_the_window_styles_keep_it_out_of_the_taskbar_alt_tab_and_the_foreground(self):
        self.assertEqual(gui.WS_POPUP, REAL_BACKDROP_WINDOW.STYLE)
        self.assertTrue(REAL_BACKDROP_WINDOW.EXSTYLE & gui.WS_EX_TOOLWINDOW)
        self.assertTrue(REAL_BACKDROP_WINDOW.EXSTYLE & gui.WS_EX_NOACTIVATE)
        self.assertFalse(REAL_BACKDROP_WINDOW.EXSTYLE & gui.WS_EX_APPWINDOW)


class BackdropScenarioTests(unittest.TestCase):
    BASE = 'id = "W90"\ntitle = "t"\nconfig = "language = en"\n'
    CAPTURE = '[[step]]\naction = "capture"\nname = "x"\n'

    def load(self, body: str):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W90-x.toml"
            path.write_text(self.BASE + body, encoding="utf-8")
            return gui.load_scenario(path)

    def test_settings_and_their_validation(self):
        self.assertEqual(("#000000", None), (self.load(self.CAPTURE).backdrop, self.load(self.CAPTURE).backdrop_reason))
        self.assertEqual("#ff00ff", self.load('backdrop = "FF00FF"\n' + self.CAPTURE).backdrop)
        off = self.load('backdrop = false\nbackdrop_reason = "W14 checks the wallpaper"\n' + self.CAPTURE)
        self.assertEqual((None, "W14 checks the wallpaper"), (off.backdrop, off.backdrop_reason))
        cases = {
            "needs backdrop_reason": 'backdrop = false\n',
            "only goes with backdrop = false": 'backdrop_reason = "x"\n',
            "backdrop: bad color": 'backdrop = "pink"\n',
            "true, false or a #rrggbb": 'backdrop = 1\n',
            "enabled = false needs a reason": '[[step]]\naction = "backdrop"\nenabled = false\n',
            "reason only goes with enabled = false": '[[step]]\naction = "backdrop"\nreason = "x"\n',
            "off has no color": '[[step]]\naction = "backdrop"\nenabled = false\nreason = "x"\ncolor = "#000000"\n',
            "must be true or false": '[[step]]\naction = "backdrop"\nenabled = "no"\n',
            "bad color": '[[step]]\naction = "backdrop"\ncolor = "#12"\n',
        }
        for expected, body in cases.items():
            with self.subTest(case=expected), self.assertRaisesRegex(gui.UsageError, expected):
                self.load(body + self.CAPTURE)

    def run_scenario(self, body: str, fail: bool = False, stderr: io.StringIO | None = None):
        fake = FakeWin32(4242, 4242)
        window = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", (100, 100, 140, 130), True, False, False)
        fake.stack = [gui.StackEntry(0x10, gui.WINDOW_CLASS, window.rect, 4242, 4242),
                      gui.StackEntry(0xB0, "backdrop", (0, 0, 1000, 800), 1, 1)]
        FakeBackdropWindow.made = []
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "W90-x.toml"
            path.write_text(self.BASE + body, encoding="utf-8")
            scenario = gui.load_scenario(path)
            run = gui.ScenarioRun(scenario, Path("ghostty.exe"), Path(tmp) / "out")
            instance = mock.Mock()
            instance.pid = 4242
            instance.log = Path(tmp) / "absent.log"
            instance.popups.return_value = []
            instance.require_window.return_value = window
            instance.capture_window.side_effect = (
                gui.GuiError("capture failed") if fail else
                lambda info, method, region=None, see_through=(): screen(region or info.rect, [info.rect]))
            with mock.patch.object(gui, "launch", return_value=instance), mock.patch.object(gui, "win32", return_value=fake), \
                    mock.patch.object(gui, "BackdropWindow", FakeBackdropWindow), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr or io.StringIO()):
                report = run.run()
            return report, gui.notes_text(scenario, report), [path.name for path in (Path(tmp) / "out").glob("*.png")]

    def test_a_scenario_runs_on_the_default_backdrop_and_always_removes_it(self):
        report, notes, pngs = self.run_scenario(BackdropScenarioTests.CAPTURE)
        self.assertEqual(("ok", ["01-x.png"]), (report["status"], pngs))
        self.assertEqual(1, FakeBackdropWindow.made[0].closed)
        self.assertEqual(["pass"], [check["status"] for check in report["backdrop"]["checks"]])
        self.assertIn("backdrop: #000000 under the instance's windows", notes)
        report, notes, pngs = self.run_scenario(BackdropScenarioTests.CAPTURE, fail=True)
        self.assertEqual(("failed", []), (report["status"], pngs))
        self.assertEqual(1, FakeBackdropWindow.made[0].closed)
        self.assertEqual("destroyed", report["backdrop"]["events"][-1]["result"])

    def test_a_backdrop_that_is_not_destroyed_fails_the_scenario(self):
        self.addCleanup(setattr, FakeBackdropWindow, "close_error", None)
        FakeBackdropWindow.close_error = gui.GuiError("the privacy backdrop thread did not end within 5s")
        stderr = io.StringIO()
        report, notes, pngs = self.run_scenario(BackdropScenarioTests.CAPTURE, stderr=stderr)
        self.assertEqual(("failed", ["01-x.png"]), (report["status"], pngs), "the capture itself passed")
        self.assertEqual("the privacy backdrop was not destroyed (scenario end: failed: the privacy backdrop thread "
                         "did not end within 5s)", report["reason"])
        self.assertIn("W90 FAILED: the privacy backdrop was not destroyed", stderr.getvalue())
        self.assertIn("status: failed (the privacy backdrop was not destroyed", notes)
        report, _, _ = self.run_scenario(BackdropScenarioTests.CAPTURE, fail=True)
        self.assertRegex(report["reason"], r"^capture failed; the privacy backdrop was not destroyed \(")

    def test_notes_warn_about_a_material_that_shows_the_wallpaper(self):
        self.assertEqual("gx-window-material = mica", gui.wallpaper_material("a = 1\ngx-window-material = mica\n"))
        self.assertIsNone(gui.wallpaper_material("gx-window-material = mica\ngx-window-material = solid\n"))
        self.assertEqual("gx-window-material = acrylic, background-blur = 20",
                         gui.wallpaper_material("background-blur = 20\n", ["--gx-window-material=acrylic"]))
        self.assertIsNone(gui.wallpaper_material("background-blur = false\n", ["--gx-window-material="]))
        w14 = gui.load_scenario(next(gui.SCENARIO_DIR.glob("W14-*.toml")))
        self.assertIn("wallpaper: gx-window-material = mica makes DWM sample the desktop wallpaper",
                      gui.notes_text(w14, {"status": "ok"}))
        _, notes, _ = self.run_scenario(BackdropScenarioTests.CAPTURE)
        self.assertNotIn("wallpaper:", notes)

    def test_a_scenario_without_the_backdrop_says_so(self):
        body = 'backdrop = false\nbackdrop_reason = "W14 checks the wallpaper"\n' + BackdropScenarioTests.CAPTURE
        report, notes, pngs = self.run_scenario(body)
        self.assertEqual(("ok", [], ["01-x.png"]), (report["status"], FakeBackdropWindow.made, pngs))
        self.assertIn("backdrop: OFF (W14 checks the wallpaper)", notes)
        report, notes, _ = self.run_scenario('[[step]]\naction = "backdrop"\ncolor = "#00ff00"\n'
                                             + BackdropScenarioTests.CAPTURE)
        self.assertEqual([(0, 0, 0), (0, 255, 0)], [window.color for window in FakeBackdropWindow.made])
        self.assertIn("a backdrop step changed it", notes)


class SessionCaptureTests(unittest.TestCase):
    """The session commands capture and pixel put their screen captures behind a backdrop too."""

    WINDOW = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", (100, 100, 140, 130), True, False, False)
    POPUP = gui.WindowInfo(0x20, gui.POPUP_CLASS, "", (300, 300, 340, 330), True, False, False)

    def setUp(self):
        FakeBackdropWindow.made = []
        FakeBackdropWindow.close_error = None
        self.fake = FakeWin32(4242, 4242)
        self.fake.stack = [gui.StackEntry(0x20, gui.POPUP_CLASS, self.POPUP.rect, 4242, 4242),
                           gui.StackEntry(0x10, gui.WINDOW_CLASS, self.WINDOW.rect, 4242, 4242),
                           gui.StackEntry(0xB0, "backdrop", (0, 0, 1000, 800), 1, 1)]
        self.instance = mock.Mock(spec=gui.Instance)
        self.instance.pid = 4242
        self.instance.alive.return_value = True
        self.instance.require_window.return_value = self.WINDOW
        self.instance.popups.return_value = [self.POPUP]
        self.instance.point.return_value = (120, 110)
        self.instance.capture_window.side_effect = (
            lambda info, method, region=None, see_through=(): screen(region or info.rect, [info.rect]))
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.out = Path(tmp.name)
        for patch in (mock.patch.object(gui, "win32", return_value=self.fake),
                      mock.patch.object(gui, "BackdropWindow", FakeBackdropWindow),
                      mock.patch.object(gui.Instance, "load", return_value=self.instance),
                      mock.patch.object(gui.time, "sleep")):
            patch.start()
            self.addCleanup(patch.stop)

    def command(self, *argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = gui.main([argv[0], str(self.out / "env"), *argv[1:]])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_a_screen_capture_and_a_pixel_read_go_through_a_backdrop_of_their_own(self):
        code, out, err = self.command("capture", str(self.out / "shot.png"))
        self.assertEqual(0, code, err)
        self.assertTrue((self.out / "shot.png").is_file())
        self.assertEqual(1, len(FakeBackdropWindow.made))
        self.assertEqual(((0, 0, 0), 1), (FakeBackdropWindow.made[0].color, FakeBackdropWindow.made[0].closed))
        self.assertIn("privacy backdrop #000000: 1 of 1 checks passed; destroyed", err)
        self.instance.capture_window.assert_called_once_with(self.WINDOW, "screen", region=(76, 76, 164, 154),
                                                             see_through=(0xB0,))
        code, out, err = self.command("pixel", "1", "2", "--backdrop", "FF00FF")
        self.assertEqual((0, "(120, 110) #ffffff\n"), (code, out))
        self.assertEqual(((255, 0, 255), 1), (FakeBackdropWindow.made[1].color, FakeBackdropWindow.made[1].closed))

    def test_the_popups_share_one_backdrop_and_a_failed_check_saves_nothing(self):
        code, out, err = self.command("capture", str(self.out / "p.png"), "--popups")
        self.assertEqual((0, 1), (code, len(FakeBackdropWindow.made)), err)
        self.assertTrue((self.out / f"p-{gui.POPUP_CLASS}-1.png").is_file())
        self.fake.stack.insert(0, gui.StackEntry(0x99, "Chrome_WidgetWin_1", (0, 0, 900, 900), 777, 777))
        code, out, err = self.command("capture", str(self.out / "leak.png"))
        self.assertEqual(1, code)
        self.assertRegex(err, r"privacy backdrop check failed for leak.png: 1 window\(s\) of other processes")
        self.assertFalse((self.out / "leak.png").exists())
        self.assertEqual(1, FakeBackdropWindow.made[1].closed, "destroyed although the check failed")

    def test_print_and_no_backdrop_need_no_window_and_no_backdrop_warns(self):
        code, _, err = self.command("capture", str(self.out / "print.png"), "--method", "print")
        self.assertEqual((0, [], ""), (code, FakeBackdropWindow.made, err))
        code, _, err = self.command("capture", str(self.out / "bare.png"), "--no-backdrop", "checks the wallpaper")
        self.assertEqual((0, []), (code, FakeBackdropWindow.made))
        self.assertIn("warning: screen capture without the privacy backdrop (checks the wallpaper)", err)
        self.assertEqual([mock.call(self.WINDOW, "print"), mock.call(self.WINDOW, "screen")],
                         self.instance.capture_window.call_args_list)

    def test_bad_options_and_a_backdrop_that_is_not_destroyed(self):
        for argv in (("capture", "x.png", "--backdrop", "pink"), ("pixel", "1", "2", "--no-backdrop", " "),
                     ("capture", "x.png", "--backdrop", "#000000", "--no-backdrop", "x")):
            with self.subTest(argv=argv):
                self.assertEqual(2, self.command(*argv)[0])
        self.assertEqual([], FakeBackdropWindow.made)
        FakeBackdropWindow.close_error = gui.GuiError("the privacy backdrop 0xb0 still exists")
        code, out, err = self.command("capture", str(self.out / "kept.png"))
        self.assertEqual(1, code)
        self.assertTrue((self.out / "kept.png").is_file(), "the capture itself passed")
        self.assertIn("error: the privacy backdrop was not destroyed (command end: failed: the privacy backdrop "
                      "0xb0 still exists)", err)


@unittest.skipUnless(sys.platform == "win32", "the ctypes structures are Windows only")
class Win32StructureTests(unittest.TestCase):
    def test_input_structure_size_matches_the_platform(self):
        import ctypes

        backend = gui.win32()
        self.assertEqual(40 if ctypes.sizeof(ctypes.c_void_p) == 8 else 28, ctypes.sizeof(backend.INPUT))
        self.assertEqual(4, len(backend.virtual_screen()))

    def test_current_user_sid(self):
        self.assertRegex(gui.win32().current_user_sid(), r"^S-1-5-\d+(-\d+)+$")

    def test_backdrop_window_structures_match_the_platform(self):
        import ctypes

        backend = gui.win32()
        wide = ctypes.sizeof(ctypes.c_void_p) == 8
        self.assertEqual(80 if wide else 48, ctypes.sizeof(backend.WNDCLASSEXW))
        self.assertEqual(48 if wide else 28, ctypes.sizeof(backend.MSG))
        self.assertEqual(40, ctypes.sizeof(backend.MONITORINFO))

    def test_monitors_come_with_work_areas_on_them(self):
        monitors = gui.win32().monitors()  # read-only: EnumDisplayMonitors and GetMonitorInfoW
        self.assertTrue(monitors)
        for whole, work in monitors:
            self.assertEqual(work, gui.rect_intersection(whole, work), (whole, work))


if __name__ == "__main__":
    unittest.main()
