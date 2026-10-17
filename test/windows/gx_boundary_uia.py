"""Windowless external MTA + real GUI lifecycle, IME and modal controllers."""
import ctypes as C
from ctypes import wintypes as W
import json
from pathlib import Path
import subprocess
import sys
import time

from gx_boundary_controller import Native, ROOT, EnvironmentUnavailable
from gx_session_ipc_fixture import wait
import gx_win_gui as gui


def popup(instance, exclude=()):
    return wait(lambda: next((w for w in instance.popups() if w.cls in ("GhosttyGxPopup", "GhosttyGxPopupShadow")
                             and w.hwnd not in exclude), None))


class Worker:
    def __init__(self, fixture, instance, hwnd, label, *, actions=None, notification=False, stress=False):
        self.fixture, self.instance, self.hwnd, self.label = fixture, instance, hwnd, label
        self.ready = fixture.out / (label + ".ready.json")
        self.signal = fixture.out / (label + ".continue")
        self.stdout_path, self.stderr_path = (fixture.out / (label + suffix) for suffix in (".stdout.json", ".stderr.txt"))
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--hwnd", str(hwnd),
                   "--pid", str(instance.pid), "--birth", str(instance.creation), "--exe", instance.exe,
                   "--sha256", fixture.report["app_sha256"], "--timeout", "45", "--listen-ms", "30000",
                   "--ready-file", str(self.ready), "--continue-file", str(self.signal), "--max-nodes", "512", "--max-depth", "16"]
        if actions:
            plan = fixture.out / (label + ".plan.json")
            plan.write_text(json.dumps(actions), encoding="utf-8")
            command += ["--action-plan", str(plan)]
        if notification:
            command.append("--expect-notification")
        if stress:
            command += ["--query-interval-ms", "20"]
        self.stdout, self.stderr = self.stdout_path.open("w", encoding="utf-8"), self.stderr_path.open("w", encoding="utf-8")
        self.process = subprocess.Popen(command, stdout=self.stdout, stderr=self.stderr)
        fixture.check("MTA-worker", command=command)

    def await_ready(self):
        def ready():
            if self.process.poll() is not None:
                raise AssertionError("MTA worker exited before registration/retention handshake")
            try:
                return json.loads(self.ready.read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError):
                return None
        return wait(ready, 15)

    def complete(self):
        self.signal.write_text("owned transition completed\n", encoding="utf-8")
        code = self.process.wait(timeout=20)
        self.stdout.close()
        self.stderr.close()
        result = json.loads(self.stdout_path.read_text(encoding="utf-8"))
        if code != 0 or result["status"] != "PASS":
            raise AssertionError(f"external MTA failed: {result}")
        self.fixture.check(self.label, result=result)
        return result

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)
        self.stdout.close()
        self.stderr.close()


def probe(fixture, instance, hwnd, label, action=None):
    command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--hwnd", str(hwnd),
               "--pid", str(instance.pid), "--birth", str(instance.creation), "--exe", instance.exe,
               "--sha256", fixture.report["app_sha256"], "--max-nodes", "512", "--max-depth", "16"]
    if action:
        plan = fixture.out / (label + ".plan.json")
        plan.write_text(json.dumps([action]), encoding="utf-8")
        command += ["--action-plan", str(plan)]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=20)
    (fixture.out / (label + ".json")).write_text(json.dumps({"argv": command, "returncode": result.returncode,
                                                            "stdout": result.stdout, "stderr": result.stderr}), encoding="utf-8")
    assert result.returncode == 0, result.stdout
    return json.loads(result.stdout)


def stale(fixture, instance, first, other):
    gui.win32().activate(first.hwnd)
    instance.press("ctrl+shift+p")
    old = popup(instance)
    worker = Worker(fixture, instance, old.hwnd, "hide-reopen", actions=[{
        "name": "Search", "pattern": "value", "operation": "set", "value": "GX_STALE_MUST_NOT_APPEAR",
        "after_signal": True, "expect_unavailable": True}])
    try:
        worker.await_ready()
        instance.press("escape")
        wait(lambda: not any(w.hwnd == old.hwnd for w in instance.popups()))
        instance.press("ctrl+shift+p")
        replacement = popup(instance)
        worker.complete()
        fresh = probe(fixture, instance, replacement.hwnd, "replacement-palette")
        assert not any(n.get("value") == "GX_STALE_MUST_NOT_APPEAR" for n in fresh["nodes"])
        fixture.capture(instance, "hide-reopen-inert", replacement)
        instance.press("escape")
    finally:
        worker.close()

    instance.press("ctrl+shift+m")
    root = popup(instance)
    probe(fixture, instance, root.hwnd, "expand-profile", {"name": "New Tab with Profile", "pattern": "expand_collapse", "operation": "expand"})
    child = popup(instance, (root.hwnd,))
    nodes = probe(fixture, instance, child.hwnd, "old-submenu")["nodes"]
    node = next(n for n in nodes if n["patterns"].get("invoke") and n["enabled"])
    worker = Worker(fixture, instance, child.hwnd, "submenu-replaced", actions=[{
        "automation_id": node["automation_id"], "pattern": "invoke", "operation": "invoke", "after_signal": True, "expect_unavailable": True}])
    try:
        worker.await_ready()
        instance.press("escape")
        wait(lambda: not any(w.hwnd == child.hwnd for w in instance.popups()))
        probe(fixture, instance, root.hwnd, "expand-split", {"name": "Split", "pattern": "expand_collapse", "operation": "expand"})
        replacement = popup(instance, (root.hwnd,))
        worker.complete()
        fixture.capture(instance, "submenu-old-provider-inert", replacement)
        instance.press("escape")
        instance.press("escape")
    finally:
        worker.close()

    before_tabs = other.query(4)
    worker = Worker(fixture, instance, first.hwnd, "root-destroyed", actions=[{
        "name": "New Tab", "pattern": "invoke", "operation": "invoke", "after_signal": True, "expect_unavailable": True}])
    try:
        worker.await_ready()
        first.guard()
        gui.win32().PostMessageW(first.hwnd, gui.WM_CLOSE, 0, 0)
        wait(lambda: not gui.win32().IsWindow(first.hwnd))
        worker.complete()
        assert other.query(4) == before_tabs
        fixture.capture_native(instance, other, "destroyed-provider-no-replacement-action")
    finally:
        worker.close()


def compose_ime(instance, native):
    api = gui.win32()
    user = C.WinDLL("user32", use_last_error=True)
    user.GetKeyboardLayoutList.argtypes, user.GetKeyboardLayoutList.restype = [C.c_int, C.POINTER(C.c_void_p)], C.c_int
    count = user.GetKeyboardLayoutList(0, None)
    layouts = (C.c_void_p * max(1, count))()
    count = user.GetKeyboardLayoutList(count, layouts)
    chinese = next((layouts[i] for i in range(count) if layouts[i] & 0xffff in (0x0804, 0x0404)), None)
    if not chinese:
        raise EnvironmentUnavailable("no installed Chinese IME in this desktop session")
    original = api.keyboard_layout(native.hwnd)
    hwnd = api.focus_window(native.hwnd)
    assert api.window_pid(hwnd) == instance.pid and api.class_name(hwnd) == gui.TERMINAL_CLASS
    try:
        api.PostMessageW(hwnd, 0x50, 0, chinese)
        wait(lambda: api.keyboard_layout(hwnd) & 0xffff == chinese & 0xffff, 5)
        imm = C.WinDLL("imm32", use_last_error=True)
        imm.ImmGetDefaultIMEWnd.argtypes, imm.ImmGetDefaultIMEWnd.restype = [W.HWND], W.HWND
        ime = imm.ImmGetDefaultIMEWnd(hwnd)
        if not ime or api.window_pid(ime) != instance.pid:
            raise EnvironmentUnavailable("owned thread's IME control window is unavailable")
        api.send_message(ime, 0x283, 6, 1, timeout_ms=2000)
        api.send_message(ime, 0x283, 2, 1, timeout_ms=2000)
        before = native.query(106)
        instance.press("n")
        instance.press("i")
        wait(lambda: native.query(106) > before, 5)
        instance.press("escape")
        return {"layout": chinese, "composition_events": native.query(106) - before}
    finally:
        if instance.alive() and api.IsWindow(hwnd):
            api.PostMessageW(hwnd, 0x50, 0, original)


def stress(fixture, instance, native):
    gui.win32().activate(native.hwnd)
    native.control(6, -1)
    worker = Worker(fixture, instance, native.hwnd, "continuous-query-stress", stress=True)
    unavailable = None
    try:
        worker.await_ready()
        for _ in range(6):
            instance.press("ctrl+alt+h")
            instance.press("ctrl+alt+l")
        try:
            fixture.check("IME-composition-during-MTA-query", **compose_ime(instance, native))
        except EnvironmentUnavailable as error:
            unavailable = error
            fixture.check("IME-environment-unavailable", reason=str(error))
        instance.press("ctrl+shift+t")
        instance.press("ctrl+shift+w")
        instance.press("ctrl+shift+m")
        menu = popup(instance)
        fixture.capture(instance, "stress-menu", menu)
        instance.press("escape")
        native.control(10, posted=True)
        dialog = popup(instance)
        fixture.capture(instance, "stress-modal", dialog)
        instance.press("escape")
        time.sleep(0.3)
        result = worker.complete()
        assert result["queries_during_wait"] - result["unavailable_queries"] >= 5, "no usable queries during stress"
        fixture.capture_native(instance, native, "stress-after")
    finally:
        worker.close()
    if unavailable:
        raise unavailable


def run(fixture):
    instance, first, _, other = fixture.stage()
    if fixture.case_id == "UIA-02":
        stale(fixture, instance, first, other)
    elif fixture.case_id == "UIA-03":
        stress(fixture, instance, first)
    else:
        worker = Worker(fixture, instance, first.hwnd, "notification-receipt", notification=True)
        try:
            ready = worker.await_ready()
            if not ready["registered"]:
                raise EnvironmentUnavailable("IUIAutomation5 notification registration unavailable")
            assert first.control(9) == 1, "native UIA notification API rejected event"
            time.sleep(0.2)
            result = worker.complete()
            assert any(e["message"] == "The session could not be saved." for e in result["events"])
            threads = result["threads"]
            assert threads["query_thread"] == threads["registration_thread"] == threads["removal_thread"]
            fixture.capture_native(instance, first, "notification-owned-root")
        finally:
            worker.close()
