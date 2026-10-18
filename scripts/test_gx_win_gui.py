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


class ScenarioReleaseTests(unittest.TestCase):
    BODY = 'id = "W90"\ntitle = "t"\nconfig = "language = en"\n'

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


@unittest.skipUnless(sys.platform == "win32", "the ctypes structures are Windows only")
class Win32StructureTests(unittest.TestCase):
    def test_input_structure_size_matches_the_platform(self):
        import ctypes

        backend = gui.win32()
        self.assertEqual(40 if ctypes.sizeof(ctypes.c_void_p) == 8 else 28, ctypes.sizeof(backend.INPUT))
        self.assertEqual(4, len(backend.virtual_screen()))


if __name__ == "__main__":
    unittest.main()
