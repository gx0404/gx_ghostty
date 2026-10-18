#!/usr/bin/env python3
"""Tests for scripts/gx_win_gui.py: chords, coordinates, isolation, PNG output, the scenario files and
the input guard. Nothing here starts Ghostty or sends input; the Win32 backend is replaced by a fake.
"""

from __future__ import annotations

import contextlib
import io
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
                with self.subTest(key=key), self.assertRaises(gui.UsageError):
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
        for raw in ({"action": "wait_file", "path": "p"}, {"action": "wait_file", "path": "p", "pattern": "("}):
            with self.subTest(raw=raw), self.assertRaises(gui.UsageError):
                gui.validate_step("s", raw)


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
        return []

    def window_stack(self):
        return list(self.stack)

    def work_area(self, hwnd):
        return (0, 0, 1000, 800)

    def current_user_sid(self):
        return "S-1-5-21-1"

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

    def __init__(self, deny_works=True, remove_works=True, reset_works=True, log=None):
        self.deny_works, self.remove_works, self.reset_works = deny_works, remove_works, reset_works
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


class ReadOnlyTests(unittest.TestCase):
    SID = "S-1-5-21-1"

    def paths(self, acl):
        return gui.ReadOnlyPaths(acl=acl, sid=lambda: self.SID, probe=acl.probe)

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
            self.assertEqual("state is read-only (acl; a write attempt was refused)", paths.protect(directory, "state"))
            self.assertEqual([[str(directory), "/deny", f"*{self.SID}:(OI)(CI)(WD,AD,WEA,WA,DC)"]], acl.calls)
            self.assertEqual({directory: "acl"}, paths.paths)
            self.assertEqual("state is read-only already", paths.protect(directory, "state"))
            self.assertEqual("state is writable again (acl)", paths.release(directory, "state"))
            self.assertEqual([str(directory), "/remove:d", f"*{self.SID}"], acl.calls[-1])
            self.assertEqual({}, paths.paths)
            self.assertEqual(["readonly", "writable"], [event["event"] for event in paths.events])

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
            self.assertEqual(f"{state} is a directory; {state} is read-only (acl; a write attempt was refused)",
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
    for x0, y0, x1, y1 in paint:
        for y in range(max(y0, top), min(y1, bottom)):
            for x in range(max(x0, left), min(x1, right)):
                offset = ((y - top) * width + (x - left)) * 4
                data[offset:offset + 3] = bytes((color[2], color[1], color[0]))
    return gui.Image(width, height, bytes(data), left, top)


REAL_BACKDROP_WINDOW = gui.BackdropWindow


class FakeBackdropWindow:
    """Stands in for BackdropWindow: nothing is created on the desktop."""

    made: list = []

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
        return "destroyed"


class BackdropTests(unittest.TestCase):
    PID = 4242
    WINDOW = gui.WindowInfo(0x10, gui.WINDOW_CLASS, "main", (100, 100, 140, 130), True, False, False)
    PROBE = (76, 76, 164, 154)  # the window and its 24 DIP band at 96 dpi

    def setUp(self):
        FakeBackdropWindow.made = []
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
        self.assertEqual(([foreign], True), gui.backdrop_audit(stack, 0xB0, self.PID, area))
        self.assertEqual(([foreign], False), gui.backdrop_audit(stack[:3], 0xB0, self.PID, area))

    def test_screen_capture_through_a_checked_backdrop(self):
        backdrop = gui.Backdrop("#000000")
        image = backdrop.capture(self.instance, self.WINDOW, "screen", "01-x.png")
        window = FakeBackdropWindow.made[0]
        self.assertEqual(((0, 0, 0), (0, 0, 1000, 800)), (window.color, window.opened))
        self.assertEqual([((0, 0, 1000, 800), 0x10)], window.placed)
        self.instance.capture_window.assert_called_once_with(self.WINDOW, "screen", region=self.PROBE, see_through=(0xB0,))
        self.assertEqual((40, 30, 100, 100), (image.width, image.height, image.left, image.top))
        check = backdrop.checks[0]
        self.assertEqual(("pass", 88 * 78 - 44 * 34, 0, 1, []),
                         (check["status"], check["checked_pixels"], check["foreign_pixels"], check["attempts"],
                          check["foreign_windows"]))
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
        self.fake.work_area = lambda hwnd: (0, 0, 1200, 900)  # the window moved to a larger monitor
        backdrop.ensure(self.instance)
        self.assertEqual(((0, 0, 1200, 900), True), (backdrop.area, backdrop.fresh))

    def test_the_lowest_instance_window_and_every_monitor_of_the_instance_count(self):
        popup = gui.StackEntry(0x20, gui.POPUP_CLASS, (900, 10, 990, 60), self.PID, self.PID)
        self.fake.stack = [popup, gui.StackEntry(0x99, "Other", (600, 600, 700, 700), 777, 777), self.main,
                           self.backdrop_entry]
        self.fake.work_area = lambda hwnd: (0, 0, 1000, 800) if hwnd == 0x10 else (1000, 0, 2000, 800)
        gui.Backdrop("#000000").ensure(self.instance)
        self.assertEqual([((0, 0, 2000, 800), 0x10)], FakeBackdropWindow.made[0].placed)

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

    def run_scenario(self, body: str, fail: bool = False):
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
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
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

    def test_a_scenario_without_the_backdrop_says_so(self):
        body = 'backdrop = false\nbackdrop_reason = "W14 checks the wallpaper"\n' + BackdropScenarioTests.CAPTURE
        report, notes, pngs = self.run_scenario(body)
        self.assertEqual(("ok", [], ["01-x.png"]), (report["status"], FakeBackdropWindow.made, pngs))
        self.assertIn("backdrop: OFF (W14 checks the wallpaper)", notes)
        report, notes, _ = self.run_scenario('[[step]]\naction = "backdrop"\ncolor = "#00ff00"\n'
                                             + BackdropScenarioTests.CAPTURE)
        self.assertEqual([(0, 0, 0), (0, 255, 0)], [window.color for window in FakeBackdropWindow.made])
        self.assertIn("a backdrop step changed it", notes)


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


if __name__ == "__main__":
    unittest.main()
