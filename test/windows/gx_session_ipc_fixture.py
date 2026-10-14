"""Owned Windows IPC/session scenarios; no registry, clipboard, or global hotkeys.

Run with --out an unused evidence directory and --exe a known application build.
Captures require separate visual review. This does not replace the GUI scenario suite.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_slots  # noqa: E402
import gx_win_gui as gui  # noqa: E402

CONFIG = "language = en\nconfirm-close-surface = false\n"


def wait(predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("bounded wait failed")


class Fixture:
    def __init__(self, exe, out, build):
        self.exe, self.out = exe.resolve(strict=True), out.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.owned = []
        self.report = {
            "exe": str(self.exe), "app_sha256": hashlib.sha256(self.exe.read_bytes()).hexdigest(),
            "app_mtime_ns": self.exe.stat().st_mtime_ns, "build_label": build,
            "tree_boundary": "Build label is caller supplied; the current source tree is not a build receipt.",
            "cases": [], "processes": [], "captures": [], "visual_review": "PENDING",
        }

    def environment(self, name, config):
        path = self.out / name
        gui.prepare_env_dir(path, False)
        gui.write_config(path, config)
        return path

    def start(self, path, args=()):
        assert path.is_absolute()
        assert hashlib.sha256(self.exe.read_bytes()).hexdigest() == self.report["app_sha256"]
        instance = gui.launch(self.exe, path, args=args)
        self.owned.append(instance)
        instance.ensure_owned()
        self.report["processes"].append({
            "pid": instance.pid, "birth": instance.creation, "exe": instance.exe,
            "environment": str(path), "argv": list(args),
        })
        return instance

    @staticmethod
    def windows(instance):
        return [item for item in instance.windows() if item.cls == gui.WINDOW_CLASS
                and item.visible and not item.cloaked and not item.toolwindow]

    def capture(self, instance, name, window=None):
        instance.ensure_owned()
        window = window or instance.require_window()
        # PrintWindow stays scoped to the owned HWND if Windows denies foreground.
        foreground = gui.win32().activate(window.hwnd)
        time.sleep(0.2)
        instance.ensure_owned()
        method = "screen" if foreground else "print"
        instance.capture_window(window, method).save_png(self.out / f"{name}.png")
        self.report["captures"].append({"file": f"{name}.png", "method": method,
                                        "foreground": foreground, "review": "PENDING"})

    def close(self, instance):
        for window in self.windows(instance):
            instance.ensure_owned()
            gui.win32().PostMessageW(window.hwnd, gui.WM_CLOSE, 0, 0)
        wait(lambda: not instance.alive())

    @staticmethod
    def quit(instance):
        # Find only this process's message-only window and use its normal quit path.
        api = ctypes.WinDLL("user32", use_last_error=True).FindWindowExW
        api.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p]
        api.restype = ctypes.c_void_p
        after = None
        while True:
            after = api(ctypes.c_void_p(-3), after, "GhosttyMsg", None)
            if not after:
                raise AssertionError("owned message window not found")
            instance.ensure_owned()
            if gui.win32().window_pid(after) == instance.pid:
                gui.win32().PostMessageW(after, 0x8000 + 0x62, 0, 0)
                break
        wait(lambda: not instance.alive())

    @staticmethod
    def session(path):
        return path / "state/ghostty/gx-session.json"

    def seed(self, path):
        document = {"version": 1, "generation": 7, "windows": [{"active": 0, "geometry": {
            "width": 960, "height": 600, "x": 80, "y": 80, "dpi": 96}, "tabs": [{
            "active": 0, "nodes": [{"leaf": {"profile_id": "custom:Fixture"}}],
            "title_override": "Restored fixture",
        }]}]}
        target = self.session(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(document), encoding="utf-8")
        return target.read_bytes()

    def multi(self):
        path = self.environment("multi", CONFIG + "command = cmd.exe /d /k prompt $G$S\n")
        host = self.start(path)
        host.wait_window(15)
        host.remember_children()
        before = len(self.windows(host))
        launcher = self.start(path)
        wait(lambda: not launcher.alive())
        wait(lambda: len(self.windows(host)) == before + 1)
        host.remember_children()
        self.report["cases"].append({"name": "ordinary launcher reuses host", "status": "PASS",
                                     "host": host.pid, "launcher": launcher.pid, "windows": before + 1})
        self.capture(host, "multi-host-two-windows")
        child = self.start(path, ("-e", "cmd.exe", "/d", "/k", "prompt $G$S"))
        child.wait_window(15)
        child.remember_children()
        assert child.pid != host.pid and host.alive() and len(self.windows(host)) == before + 1
        self.report["cases"].append({"name": "-e independent", "status": "PASS", "pid": child.pid})
        self.capture(child, "execute-independent")
        self.close(child)
        self.close(host)

    def disabled(self):
        path = self.environment("disabled", CONFIG + "gx-launch-profile = Fixture=cmd.exe /d /k prompt $G$S\n")
        original = self.seed(path)
        instance = self.start(path)
        instance.wait_window(15)
        time.sleep(0.4)
        assert not instance.popups()
        assert self.session(path).read_bytes() == original
        self.capture(instance, "restore-default-disabled")
        self.close(instance)
        assert self.session(path).read_bytes() == original
        self.report["cases"].append({"name": "restore disabled by default preserves session", "status": "PASS"})

    def custom(self):
        path = self.environment("custom", CONFIG + "gx-session-restore = true\ngx-launch-profile = Fixture=cmd.exe /d /k prompt $G$S\n")
        self.seed(path)
        for number in (1, 2):
            instance = self.start(path)
            dialog = wait(lambda: next((w for w in instance.popups() if w.cls == "#32770"), None))
            self.capture(instance, f"custom-confirm-{number}", dialog)
            assert not gui.win32().child_processes(instance.pid), "custom command ran before approval"
            instance.ensure_owned()
            assert gui.win32().window_pid(dialog.hwnd) == instance.pid
            # Dialogs.native uses button_id_base 100 for the first (OK) button.
            gui.win32().PostMessageW(dialog.hwnd, 0x400 + 102, 100, 0)
            instance.wait_window(15)
            instance.remember_children()
            self.capture(instance, f"custom-restored-{number}")
            actual = instance.require_window().title
            assert actual == "Restored fixture", f"restart {number}: expected restored title, found {actual!r}"
            if number == 1:
                self.quit(instance)
                assert json.loads(self.session(path).read_text(encoding="utf-8"))["windows"]
                (self.out / "custom-after-quit.json").write_bytes(self.session(path).read_bytes())
            else:
                self.close(instance)
                assert json.loads(self.session(path).read_text(encoding="utf-8"))["windows"] == []
                (self.out / "custom-after-close.json").write_bytes(self.session(path).read_bytes())
        self.report["cases"].append({"name": "custom confirms each restart; Quit keeps snapshot; close empties", "status": "PASS"})

    def run(self, cases):
        with gx_slots.acquire(ROOT / ".local/kernel-slots", "heavy", 45):
            with gx_slots.acquire(ROOT / ".local/kernel-slots", "desktop", 45):
                for name in cases:
                    first = len(self.owned)
                    try:
                        getattr(self, name)()
                    except Exception as error:
                        self.report["cases"].append({"name": name, "status": "FAIL", "reason": str(error),
                                                     "traceback": traceback.format_exc()})
                    finally:
                        for instance in self.owned[first:]:
                            if instance.log.is_file():
                                (self.out / f"{name}-{instance.pid}.log").write_bytes(instance.log.read_bytes())
                        for instance in self.owned:
                            if instance.alive():
                                instance.close(1)
                        (self.out / "report.json").write_text(json.dumps(self.report, indent=2), encoding="utf-8")
        print(json.dumps(self.report, indent=2))
        return int(any(case["status"] == "FAIL" for case in self.report["cases"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--build-label", required=True)
    parser.add_argument("--case", action="append", choices=("multi", "disabled", "custom"))
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows interactive desktop required")
    return Fixture(args.exe, args.out, args.build_label).run(args.case or ("multi", "disabled", "custom"))


if __name__ == "__main__":
    raise SystemExit(main())
