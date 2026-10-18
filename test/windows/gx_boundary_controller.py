"""r6 native boundary controllers. Requires an owned, frozen app and desktop slot.

Only scalar test messages are sent to PID/birth/hash-checked owned windows.
No remote protocol packet, clipboard content or foreign process is changed. An
owned GUI thread's input language may be switched for VK chords or IME input,
only to a layout already loaded for this user (the host never loads one;
--allow-load-layouts is VM only); it is always restored and the outcome
reported (README "宿主副作用说明").
Environment/API absence and missing peer interfaces have different statuses;
neither is reported as an implemented passing scenario.
"""
from __future__ import annotations

import argparse
import ctypes
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_win_gui as gui
from gx_fixture_evidence import fixture_slots, native_snapshot, process_identity, sha256, write_review, drag_thresholds
from gx_input_language import LayoutUnavailable, full_hkl, switch_to_us, unload_layouts
from gx_session_ipc_fixture import Fixture as SessionFixture, complex_document, wait

CONTROL, QUERY, MAGIC = 0x451, 0x452, 0x47584133


def signed_result(value):
    if value is None:
        return None
    if value < 0:
        return value
    bits = struct.calcsize("P") * 8
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


class EnvironmentUnavailable(RuntimeError):
    pass


class PeerInterfaceUnavailable(RuntimeError):
    pass


SETTLE_S = 0.3  # >=250 ms after the cursor sits on the exact pixel; read twice.
WM_INPUTLANGCHANGEREQUEST = 0x0050
GUI_INMOVESIZE = 0x0002


def primary_work_area():
    rect = gui.win32().RECT()  # gui.win32() first: per-monitor-v2 physical pixels.
    if not ctypes.windll.user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(rect), 0):  # SPI_GETWORKAREA
        raise EnvironmentUnavailable("SPI_GETWORKAREA is unavailable")
    return rect.left, rect.top, rect.right, rect.bottom


def side_by_side(area, width=1200, height=780, margin=24):
    """Two equal fixture windows, both fully inside the primary work area.

    Vertically centred: a caption drag near the top edge makes Windows 11
    show its Snap Layouts bar, a foreign top-level window that would own the
    drop point (observed in round3-batch-20261018-091219, drop at y=156)."""
    left, top, right, bottom = area
    w = min(width, (right - left - 3 * margin) // 2)
    h = min(height, bottom - top - 2 * margin)
    if w < 640 or h < 420:
        raise EnvironmentUnavailable(f"primary work area {area} cannot hold two visible fixture windows")
    y = top + (bottom - top - h) // 2
    return [(left + margin, y, w, h), (left + 2 * margin + w, y, w, h)]


# Every chord a boundary controller injects. Stage bindings avoid Ctrl+Alt+L/H:
# on the r3 host another program holds Ctrl+Alt+L as a global hotkey, so an
# injected press would act in that program instead of the owned app.
FIXTURE_CHORDS = ("ctrl+alt+r", "ctrl+alt+shift+j", "ctrl+alt+shift+k", "ctrl+alt+b",
                  "ctrl+shift+f", "ctrl+shift+p", "ctrl+shift+m", "ctrl+shift+t", "ctrl+shift+w")


def held_global_hotkeys(chords):
    """Chords another program holds as global hotkeys, by the product's own
    probe (shortcut_conflicts.zig): RegisterHotKey then UnregisterHotKey at
    once; ERROR_HOTKEY_ALREADY_REGISTERED means Windows would route the press
    to that program."""
    user = ctypes.WinDLL("user32", use_last_error=True)
    user.RegisterHotKey.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]
    user.RegisterHotKey.restype = ctypes.c_int
    user.UnregisterHotKey.argtypes = [ctypes.c_void_p, ctypes.c_int]
    flags = {0x11: 0x2, 0x12: 0x1, 0x10: 0x4, 0x5B: 0x8}  # MOD_CONTROL/ALT/SHIFT/WIN
    held = []
    for index, chord in enumerate(chords):
        mods, vk = gui.parse_chord(chord)
        ident = 0xA300 + index
        if user.RegisterHotKey(None, ident, sum(flags[mod] for mod in mods) | 0x4000, vk):  # MOD_NOREPEAT
            user.UnregisterHotKey(None, ident)
        elif ctypes.get_last_error() == 1409:  # ERROR_HOTKEY_ALREADY_REGISTERED
            held.append(chord)
        else:
            raise EnvironmentUnavailable(f"RegisterHotKey probe failed for {chord}: {ctypes.get_last_error()}")
    return held


TARGET_TRACE = re.compile(r"fixture_transfer_target outcome=(\w+) hwnd=0x([0-9a-f]+) pid=(\d+) class=(\S*)")


def target_traces(instance):
    """The product's gated record of the window that decided each real drop."""
    return [{"outcome": outcome, "hwnd": int(hwnd, 16), "pid": int(pid), "class": cls}
            for outcome, hwnd, pid, cls in TARGET_TRACE.findall(instance.log_text())]


def zorder_hit(point, skip):
    """Fixture mirror of TabTransfer.targetAt's hit test (first visible,
    uncloaked, non-minimized top-level window containing the point)."""
    api = gui.win32()
    user = ctypes.WinDLL("user32")
    user.GetTopWindow.argtypes = [ctypes.c_void_p]
    user.GetTopWindow.restype = ctypes.c_void_p
    hwnd = user.GetTopWindow(None) or 0
    while hwnd:
        if hwnd != skip and api.IsWindowVisible(hwnd) and not api.IsIconic(hwnd) and not api.cloaked(hwnd):
            left, top, right, bottom = api.raw_window_rect(hwnd)
            if left <= point[0] < right and top <= point[1] < bottom:
                return {"hwnd": hwnd, "class": api.class_name(hwnd), "pid": api.window_pid(hwnd)}
        hwnd = api.GetWindow(hwnd, 2) or 0  # GW_HWNDNEXT
    return None


def inside(rect, point):
    return rect[0] <= point[0] < rect[2] and rect[1] <= point[1] < rect[3]


def contains(outer, inner):
    return outer[0] <= inner[0] and outer[1] <= inner[1] and inner[2] <= outer[2] and inner[3] <= outer[3]


def drag_full_windows():
    value = ctypes.c_int(0)
    if not ctypes.windll.user32.SystemParametersInfoW(0x0026, 0, ctypes.byref(value), 0):  # SPI_GETDRAGFULLWINDOWS
        raise EnvironmentUnavailable("SPI_GETDRAGFULLWINDOWS is unavailable")
    return bool(value.value)


def cursor_pos():
    point = gui.win32().POINT()
    if not ctypes.windll.user32.GetCursorPos(ctypes.byref(point)):
        raise AssertionError("GetCursorPos failed")
    return point.x, point.y


def poll_cursor(point, timeout=0.5):
    deadline = time.monotonic() + timeout
    actual = cursor_pos()
    while actual != tuple(point) and time.monotonic() < deadline:
        time.sleep(0.01)
        actual = cursor_pos()
    return actual


def stable_rect(hwnd, timeout=1.0):
    """Window rect once the native move loop applied the last pointer move."""
    api = gui.win32()
    deadline = time.monotonic() + timeout
    rect = api.raw_window_rect(hwnd)
    while time.monotonic() < deadline:
        time.sleep(0.05)
        again = api.raw_window_rect(hwnd)
        if again == rect:
            break
        rect = again
    return rect


def thread_state(hwnd):
    """The owned GUI thread's native move/size loop window and mouse capture."""
    api = gui.win32()
    info = api.GUITHREADINFO()
    info.cbSize = ctypes.sizeof(info)
    if not api.GetGUIThreadInfo(api.window_thread(hwnd), ctypes.byref(info)):
        raise AssertionError("GetGUIThreadInfo failed for an owned window")
    return {"move_size": (info.hwndMoveSize or 0) if info.flags & GUI_INMOVESIZE else 0, "capture": info.hwndCapture or 0}


def absolute(api, normalized):
    item = api.mouse_input(0x0001 | 0x8000 | 0x4000, 0, 0)  # MOVE | ABSOLUTE | VIRTUALDESK
    item.u.mi.dx, item.u.mi.dy = normalized
    return item


def calibrate(instance, point, tries=12):
    """Normalized SendInput coordinates that land on this exact physical pixel.

    The 0..65535 mapping can round by one pixel, which is the entire difference
    between the two sides of a strict threshold. Calibration runs with the
    button up, so it can change only hover state."""
    api = gui.win32()
    vx, vy, vw, vh = api.virtual_screen()
    per_pixel = (65535 / max(vw - 1, 1), 65535 / max(vh - 1, 1))
    normalized = list(gui.normalize_absolute(*point, (vx, vy, vw, vh)))
    seen = []
    for _ in range(tries):
        instance.ensure_foreground()
        instance.ensure_point(*point)
        api.send([absolute(api, normalized)])
        actual = poll_cursor(point)
        seen.append((tuple(normalized), actual))
        if actual == tuple(point):
            return tuple(normalized)
        for axis in (0, 1):
            error = point[axis] - actual[axis]
            if error:
                step = error * per_pixel[axis]
                step = round(step) if abs(step) >= 1 else (1 if error > 0 else -1)
                normalized[axis] = max(0, min(65535, normalized[axis] + step))
    raise EnvironmentUnavailable(f"SendInput cannot place the cursor exactly on {point}: {seen}")


def owned_helper_language(layout, timeout=3.0):
    """Restore the user input language through a fixture-owned top-level window.

    Used only when the owned app already exited; never posts to another app."""
    from ctypes import wintypes as W
    user = ctypes.WinDLL("user32", use_last_error=True)
    user.CreateWindowExW.restype = W.HWND
    user.CreateWindowExW.argtypes = [W.DWORD, W.LPCWSTR, W.LPCWSTR, W.DWORD, ctypes.c_int, ctypes.c_int,
                                     ctypes.c_int, ctypes.c_int, W.HWND, W.HMENU, W.HINSTANCE, W.LPVOID]
    user.DestroyWindow.argtypes = [W.HWND]
    user.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    user.PeekMessageW.argtypes = [ctypes.POINTER(W.MSG), W.HWND, W.UINT, W.UINT, W.UINT]
    user.TranslateMessage.argtypes = [ctypes.POINTER(W.MSG)]
    user.DispatchMessageW.argtypes = [ctypes.POINTER(W.MSG)]
    user.GetKeyboardLayout.argtypes = [W.DWORD]
    user.GetKeyboardLayout.restype = ctypes.c_void_p
    left, top, _, _ = primary_work_area()
    hwnd = user.CreateWindowExW(0x00000080 | 0x00000008, "STATIC", "GX A3 input language restore",
                                0x80000000 | 0x10000000, left, top, 2, 2, None, None, None, None)
    if not hwnd:
        return {"method": "owned-helper-window", "restored": False, "error": ctypes.get_last_error()}
    try:
        activated = gui.win32().activate(hwnd)
        user.PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST, 0, full_hkl(layout))
        message = W.MSG()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while user.PeekMessageW(ctypes.byref(message), None, 0, 0, 1):  # PM_REMOVE
                user.TranslateMessage(ctypes.byref(message))
                user.DispatchMessageW(ctypes.byref(message))
            current = (user.GetKeyboardLayout(0) or 0) & 0xFFFFFFFF
            if current == layout & 0xFFFFFFFF:
                return {"method": "owned-helper-window", "activated": activated, "restored": True}
            time.sleep(0.02)
        return {"method": "owned-helper-window", "activated": activated, "restored": False, "current": f"0x{current:08x}"}
    finally:
        user.DestroyWindow(hwnd)


class InputLanguage:
    """Switch an owned GUI thread's input language and always attempt restore.

    With the default per-user input method setting a thread language change is
    visible to other apps, so restore runs through the owned app or, after it
    exited, a fixture-owned helper window; the outcome is reported, never hidden."""
    def __init__(self, fixture, instance, hwnd):
        self.fixture, self.instance, self.hwnd = fixture, instance, hwnd
        self.original = gui.win32().keyboard_layout(hwnd)
        # VM only: may load a missing US layout; what it adds is unloaded in restore.
        self.allow_load = bool(getattr(getattr(fixture, "args", None), "allow_load_layouts", False))
        self.added = []

    def us(self):
        """Microsoft Pinyin swallows Ctrl+Shift+F: use a loaded English (US) layout.

        gx_win_gui's ime_off of this tree loads 00000409 when it is missing, so it
        is not used; a missing US layout is an environment condition on the host."""
        try:
            result = switch_to_us(gui.win32(), self.hwnd, added=self.added, allow_load=self.allow_load)
        except LayoutUnavailable as error:
            raise EnvironmentUnavailable(str(error)) from None
        self.fixture.check("input-language-us", **result)
        if not result["switched"]:
            raise AssertionError(f"the owned GUI thread did not switch to the US layout: {result}")
        return result

    def request(self, layout):
        api = gui.win32()
        api.PostMessageW(api.focus_window(self.hwnd), WM_INPUTLANGCHANGEREQUEST, 0, full_hkl(layout))

    def restore(self):
        api = gui.win32()
        outcome = {"original": f"0x{self.original:08x}"}
        try:
            if self.instance.alive() and api.IsWindow(self.hwnd) and api.window_pid(self.hwnd) == self.instance.pid:
                if api.keyboard_layout(self.hwnd) == self.original:
                    outcome.update(method="unchanged", restored=True)
                else:
                    self.request(self.original)
                    deadline = time.monotonic() + 3
                    while api.keyboard_layout(self.hwnd) != self.original and time.monotonic() < deadline:
                        time.sleep(0.02)
                    outcome.update(method="owned-app", restored=api.keyboard_layout(self.hwnd) == self.original)
            if not outcome.get("restored"):
                outcome.update(owned_helper_language(self.original))
        except Exception as error:  # noqa: BLE001 - recorded, then fails the case below
            outcome.update(restored=False, error=str(error))
        if self.added:
            outcome["unloaded"] = unload_layouts(self.added)
        self.fixture.report.setdefault("input_language", []).append(outcome)
        if not outcome.get("restored") or not all(item["unloaded"] for item in outcome.get("unloaded", ())):
            raise AssertionError(f"input language was not restored: {outcome}")
        return outcome


class Native:
    def __init__(self, instance, hwnd):
        self.instance, self.hwnd = instance, hwnd
        self.window_id = None
        if self.query(0) != MAGIC:
            raise PeerInterfaceUnavailable("r6 A3 native fixture message capability is missing")
        self.window_id = self.query(2)

    def guard(self):
        self.instance.ensure_owned()
        if gui.win32().window_pid(self.hwnd) != self.instance.pid:
            raise gui.InputBlocked("fixture window PID changed")
        if self.window_id is not None and signed_result(gui.win32().send_message(self.hwnd, QUERY, 2, 0, timeout_ms=2500)) != self.window_id:
            raise gui.InputBlocked("fixture HWND was reused for another window identity")

    def query(self, selector, tab=0, node=0):
        self.guard()
        value = gui.win32().send_message(self.hwnd, QUERY, selector, tab | (node << 16), timeout_ms=2500)
        if value is None:
            raise AssertionError(f"native query timed out: {selector}")
        self.guard()
        return signed_result(value)

    def control(self, operation, value=0, *, posted=False):
        self.guard()
        if posted:
            if not gui.win32().PostMessageW(self.hwnd, CONTROL, operation, value):
                raise AssertionError("test control could not be posted")
            return None
        result = gui.win32().send_message(self.hwnd, CONTROL, operation, value, timeout_ms=5000)
        if result is None:
            raise AssertionError(f"native control timed out: {operation}")
        return signed_result(result)

    def tab_rect(self, tab):
        x, y, width, height = [self.query(field, tab) for field in (30, 31, 32, 33)]
        if width < 20 or height < 8:
            raise AssertionError("native painted tab rectangle is not visible")
        return x, y, width, height

    def tree(self, tab=None):
        tab = self.query(3) if tab is None else tab
        count = self.query(5, tab)
        if not 1 <= count <= 511:
            raise AssertionError(f"invalid live tree count: {count}")
        nodes = []
        for index in range(count):
            kind = self.query(10, tab, index)
            if kind == 2:
                bits = self.query(15, tab, index)
                nodes.append({"split": {"axis": self.query(16, tab, index),
                                        "ratio": struct.unpack("<f", struct.pack("<I", bits))[0],
                                        "first": self.query(17, tab, index), "second": self.query(18, tab, index)}})
            elif kind == 1:
                value = {"core": self.query(11, tab, index) & ((1 << 64) - 1),
                         "hwnd": self.query(12, tab, index), "parent": self.query(13, tab, index),
                         "pty_pid": self.query(14, tab, index), "title_hash": self.query(19, tab, index),
                         "total": self.query(20, tab, index), "viewport": self.query(21, tab, index),
                         "offset": self.query(22, tab, index)}
                if value["pty_pid"] > 0:
                    value["pty"] = process_identity(gui.win32(), value["pty_pid"])
                nodes.append({"leaf": value})
            else:
                raise AssertionError(f"invalid live node kind: {kind}")
        zoom = self.query(6, tab)
        return {"nodes": nodes, "active_core": self.query(7, tab) & ((1 << 64) - 1),
                "zoom": None if not zoom else zoom - 1, "title_hash": self.query(9, tab),
                "tab_id": self.query(8, tab) & ((1 << 64) - 1), "window_id": self.query(2), "hwnd": self.hwnd}


def logical_tree(value):
    visited = set()
    def visit(index):
        if index in visited or not 0 <= index < len(value["nodes"]):
            raise AssertionError("cycle, alias or out-of-range tree node")
        visited.add(index)
        node = value["nodes"][index]
        if "leaf" in node:
            return node["leaf"]["core"]
        split = node["split"]
        return split["axis"], split["ratio"], visit(split["first"]), visit(split["second"])
    topology = visit(0)
    if len(visited) != len(value["nodes"]):
        raise AssertionError("orphan live tree node")
    zoom = None if value["zoom"] is None else value["nodes"][value["zoom"]]["leaf"]["core"]
    return topology, value["active_core"], zoom, value["title_hash"]


def assert_continuity(before, after, *, remote=False):
    if logical_tree(before) != logical_tree(after):
        raise AssertionError("topology/ratio/active leaf/zoom/manual tab title changed")
    old = {n["leaf"]["core"]: n["leaf"] for n in before["nodes"] if "leaf" in n}
    new = {n["leaf"]["core"]: n["leaf"] for n in after["nodes"] if "leaf" in n}
    for core, first in old.items():
        second = new[core]
        if not remote:
            for field in ("hwnd", "pty", "title_hash", "total", "viewport", "offset"):
                if first.get(field) != second.get(field):
                    raise AssertionError(f"leaf {core}: {field} changed during transfer")


class BoundaryFixture(SessionFixture):
    def __init__(self, args):
        super().__init__(args.exe, args.out, args.build, args.sha256)
        self.args = args
        self.case_id = args.case
        self.report.update(case_id=args.case, native=[], status="RUNNING", visual_review="PENDING_REVIEW")

    def check(self, name, **facts):
        self.report["native"].append({"name": name, **facts})

    def stage(self, *, full=False, one_source=False, remote=False):
        path = self.environment("profile", "language = en\nconfirm-close-surface = false\ngx-single-instance = false\n"
                                "gx-session-restore = true\ncommand = cmd.exe /d /k prompt $G$S\n"
                                "keybind = ctrl+alt+r=new_split:right\nkeybind = ctrl+alt+shift+j=goto_split:left\n"
                                "keybind = ctrl+alt+shift+k=goto_split:right\nkeybind = ctrl+alt+b=scroll_to_bottom\n")
        held = held_global_hotkeys(FIXTURE_CHORDS)
        self.check("fixture-chords-not-held-by-other-programs", chords=FIXTURE_CHORDS, held=held)
        if held:
            raise EnvironmentUnavailable(f"another program holds fixture chords as global hotkeys: {held}")
        seed = complex_document(path)
        if one_source:
            seed["windows"][0]["tabs"] = seed["windows"][0]["tabs"][:1]
            seed["windows"][0]["active"] = 0
        else:
            seed["windows"][0]["active"] = 0
        if full:
            leaf = {"active": 0, "nodes": [{"leaf": {"profile_id": "cmd", "cwd": {"kind": "windows", "path": str(path)}}}]}
            seed["windows"][1]["tabs"] = [leaf] * 64
            seed["windows"][1]["active"] = 63
        if remote:
            seed["windows"] = seed["windows"][:1]
        self.seed_document(path, seed)
        source = self.start(path, env={"GX_A3_REMOTE_ROLE": "source"})
        wait(lambda: len(self.windows(source)) == len(seed["windows"]), 60)
        if full:
            # Identify by native tab count, never by title order.
            def by_count():
                counts = {w.hwnd: Native(source, w.hwnd).query(4) for w in self.windows(source)}
                small = [hwnd for hwnd, count in counts.items() if count == 1]
                large = [hwnd for hwnd, count in counts.items() if count == 64]
                return (small[0], large[0]) if len(small) == 1 and len(large) == 1 else None
            source_hwnd, target_hwnd = wait(by_count, 60)
            source_window = next(w for w in self.windows(source) if w.hwnd == source_hwnd)
            target, target_window = source, next(w for w in self.windows(source) if w.hwnd == target_hwnd)
        else:
            ordered = sorted(self.windows(source), key=lambda w: w.title)
            source_window = ordered[0]
            if remote:
                target = self.start(path, ("--gx-session-restore=false",), env={"GX_A3_REMOTE_ROLE": "target"})
                target.wait_window(30)
                target_window = target.require_window()
            else:
                target, target_window = source, ordered[1]
        # Equal physical client geometry avoids treating reflow as lost history;
        # both windows lie fully inside the primary monitor's work area.
        self.area = primary_work_area()
        self.slots = side_by_side(self.area)
        for slot, window in enumerate((source_window, target_window)):
            self.place(window.hwnd, slot)
        time.sleep(0.4)
        placed = {hex(w.hwnd): gui.win32().window_rect(w.hwnd) for w in (source_window, target_window)}
        if not all(contains(self.area, rect) for rect in placed.values()):
            raise AssertionError(f"fixture windows {placed} are not inside the primary work area {self.area}")
        self.check("windows-inside-primary-work-area", area=self.area, slots=self.slots, rects=placed)
        return source, Native(source, source_window.hwnd), target, Native(target, target_window.hwnd)

    def place(self, hwnd, slot):
        x, y, w, h = self.slots[slot]
        gui.win32().SetWindowPos(hwnd, None, x, y, w, h, 0x0014)  # NOZORDER | NOACTIVATE

    def capture_native(self, instance, native, label):
        window = next(w for w in instance.windows() if w.hwnd == native.hwnd)
        self.capture(instance, label, window)

    def populate_history(self, instance, native):
        original = native.tree()
        original_zoom = original["zoom"]
        active = next(i for i, node in enumerate(original["nodes"]) if "leaf" in node and node["leaf"]["core"] == original["active_core"])
        native.control(6, -1)
        gui.win32().activate(native.hwnd)
        for index, node in enumerate(original["nodes"]):
            if "leaf" not in node:
                continue
            assert native.control(7, index) == 1
            instance.type_text("for /l %i in (1,1,200) do @echo GX_A3_HISTORY_%i")
            instance.press("enter")
            tab = native.query(3)
            wait(lambda: native.query(20, tab, index) > native.query(21, tab, index) + 100)
        native.control(7, active)
        native.control(6, -1 if original_zoom is None else original_zoom)
        time.sleep(0.3)
        assert native.tree()["title_hash"] != 0, "manual title override was not restored"

    def release(self, instance, hwnds):
        """Release the injected left button only into the owned app.

        A lost foreground with owned capture or move loop still routes the
        button-up to the owned app; otherwise nothing is sent to anyone."""
        api = gui.win32()
        instance.ensure_owned()
        owned = lambda hwnd: bool(hwnd) and api.window_pid(hwnd) == instance.pid
        alive = next((hwnd for hwnd in hwnds if api.IsWindow(hwnd) and owned(hwnd)), None)
        state = thread_state(alive) if alive else {"move_size": 0, "capture": 0}
        if owned(api.foreground()) or owned(state["capture"]) or owned(state["move_size"]):
            api.send([api.mouse_input(gui.MOUSE_BUTTONS["left"][1])])
            return
        raise gui.InputBlocked("left button left down: the owned app lost foreground and capture")

    def exact_move(self, instance, normalized, point):
        instance.ensure_foreground()
        instance.ensure_point(*point)
        api = gui.win32()
        api.send([absolute(api, normalized)])
        actual = poll_cursor(point, 1.0)
        if actual != tuple(point):
            raise AssertionError(f"cursor reached {actual}, not the calibrated pixel {point}")

    @staticmethod
    def settled(read):
        """The UI thread has had >=250 ms to process the queued move; read twice."""
        time.sleep(SETTLE_S)
        first = read()
        time.sleep(SETTLE_S)
        return [first, read()]

    def migration(self):
        source, first, target, second = self.stage(full=self.case_id == "MIG-04", one_source=self.case_id == "MIG-04")
        first.control(5, 0)
        if self.case_id not in ("MIG-01", "MIG-04"):
            self.populate_history(source, first)
        before = first.tree()
        self.check("complete-native-before", tree=before, identity=native_snapshot(source))
        self.capture_native(source, first, "before")
        if self.case_id == "MIG-01":
            self.thresholds(source, first)
            return
        if self.case_id == "MIG-04":
            self.full_target(source, first, second, before)
            return
        if self.case_id == "MIG-05":
            # Each nonfirst failure necessarily rolls back real moved HWNDs.
            leaves = sum("leaf" in node for node in before["nodes"])
            for index in range(1, leaves + 1):
                first.control(1, index)
                result = first.control(3, second.hwnd)
                self.check("SetParent-injected-result", index=index, result=result)
                assert result == -1
                assert_continuity(before, first.tree())
                assert all(n["leaf"]["parent"] == first.hwnd for n in first.tree()["nodes"] if "leaf" in n)
                self.check("SetParent-failure-rollback", index=index, after=first.tree())
            first.control(1, 0)
            first.control(2, leaves)  # The seeded active/zoomed leaf is last and visibly parented.
            assert first.control(3, second.hwnd) == 1
            assert first.query(40) >= 1 and first.query(41) == first.query(40)
            assert_continuity(before, second.tree())
            self.check("inside-SetParent-reentry-rejected", entries=first.query(40), after=second.tree())
        else:
            # MIG-02-local / MIG-08-local: product moveTabToWindow and
            # detachTabForDrag through CONTROL 3/4 (no mouse gesture here).
            assert first.control(3, second.hwnd) == 1
            assert_continuity(before, second.tree())
            self.check("complete-tree-merge", before=before, after=second.tree())
            detached = second.control(4)
            assert detached > 0
            third = Native(source, detached)
            # Normalize destination size before comparing physical scroll metrics.
            self.place(third.hwnd, 0)
            time.sleep(0.3)
            assert_continuity(before, third.tree())
            self.check("complete-tree-detach", after=third.tree())
            self.capture_native(source, third, "detached")
            if self.case_id == "MIG-08-local":
                self.closed_source_continues(source, first, third, before)
        for index, window in enumerate(self.windows(source)):
            self.capture(source, f"after-{index}", window)

    def closed_source_continues(self, instance, first, third, before):
        """Close the original source window, then split/search/wheel the moved tree."""
        api = gui.win32()
        first.guard()
        api.PostMessageW(first.hwnd, gui.WM_CLOSE, 0, 0)
        wait(lambda: not api.IsWindow(first.hwnd))
        if not api.activate(third.hwnd):
            raise gui.InputBlocked("owned window foreground denied")
        language = InputLanguage(self, instance, third.hwnd)
        try:
            language.us()
            instance.press("ctrl+alt+r")
            wait(lambda: third.query(5, third.query(3)) == len(before["nodes"]) + 2)
            tab = third.query(3)
            index = next(i for i, n in enumerate(third.tree(tab)["nodes"]) if "leaf" in n and n["leaf"]["core"] == before["active_core"])
            third.control(6, -1)
            assert third.control(7, index) == 1
            # Real shell output and wheel input, never copied transcript.
            instance.type_text("for /l %i in (1,1,200) do @echo GX_A3_SEARCH_%i")
            instance.press("enter")
            wait(lambda: third.query(20, tab, index) > third.query(21, tab, index) + 100)
            instance.press("ctrl+shift+f")
            wait(lambda: third.query(24, tab, index) == 1)
            instance.type_text("GX_A3_SEARCH")
            wait(lambda: third.query(25, tab, index) > 0)
            self.check("source-closed-search", matches=third.query(25, tab, index))
            self.capture_native(instance, third, "source-closed-search")
            instance.press("escape")
            instance.press("ctrl+alt+b")
            bottom = wait(lambda: third.query(22, tab, index) or None)
            leaf = next(n["leaf"] for n in third.tree(tab)["nodes"] if "leaf" in n and n["leaf"]["core"] == before["active_core"])
            left, top, right, lower = api.window_rect(leaf["hwnd"])
            instance.wheel((left + right) // 2, (top + lower) // 2, count=4)
            scrolled = wait(lambda: (lambda value: value if value < bottom else None)(third.query(22, tab, index)))
            self.check("source-closed-split-search-scroll", bottom_offset=bottom, scrolled_offset=scrolled, after=third.tree(tab))
            self.capture_native(instance, third, "source-closed-live")
        finally:
            language.restore()

    def cross_window_drop(self, instance, source, target, label):
        """Real gesture: vertical detach of the single source tab starts the
        product's native move loop; the drop is released on the target tab bar."""
        api = gui.win32()
        if not drag_full_windows():
            raise EnvironmentUnavailable("window contents are not shown while dragging; the native move loop is unobservable")
        for native in (target, source):  # source ends on top, the target directly below it
            if not api.activate(native.hwnd):
                raise gui.InputBlocked("owned window foreground denied")
        tab = target.query(3)
        x, y, w, h = source.tab_rect(0)
        tx, ty, tw, th = target.tab_rect(tab)
        start = round(x + w / 3), round(y + h / 2)
        end = round(tx + tw / 3), round(ty + th / 2)
        detach = start[0], start[1] + drag_thresholds(source.query(23))["vertical"]["above_px"] + 4
        for name, point in (("start", start), ("detach", detach), ("end", end)):
            if not inside(self.area, point):
                raise AssertionError(f"{label}: {name} point {point} is outside the primary work area {self.area}")
        roots = {name: api.GetAncestor(api.window_at(*point), 2) for name, point in (("start", start), ("end", end))}
        if roots != {"start": source.hwnd, "end": target.hwnd}:
            raise AssertionError(f"{label}: gesture endpoints are not on the visible owned tab bars: {roots}")
        counters = lambda: tuple(target.query(field) for field in (107, 108, 109))
        before = counters()
        traced = len(target_traces(instance))
        record = {"label": label, "start": start, "detach": detach, "end": end, "target_tab": tab,
                  "target_tabs": target.query(4), "source_rect_before": api.raw_window_rect(source.hwnd),
                  "counters_before": before}
        instance.mouse(*start, action="down")
        try:
            instance.mouse(*detach, action="move")
            wait(lambda: thread_state(source.hwnd)["move_size"] == source.hwnd, 5)
            record["loop_cursor"] = cursor_pos()
            record["loop_rect"] = api.raw_window_rect(source.hwnd)
            steps = 24
            for index in range(1, steps + 1):
                point = (round(detach[0] + (end[0] - detach[0]) * index / steps),
                         round(detach[1] + (end[1] - detach[1]) * index / steps))
                instance.ensure_foreground()
                hit = api.window_at(*point)
                if not hit or api.window_pid(hit) != instance.pid:
                    raise gui.InputBlocked(f"{label}: drag path left the owned windows at {point}")
                api.send([api.mouse_input(0x0001 | 0x8000 | 0x4000, *point)])
                time.sleep(0.03)
            record["release_cursor"] = poll_cursor(end, 1.0)
            record["moving_rect"] = stable_rect(source.hwnd)
            record["hit_before_release"] = zorder_hit(end, source.hwnd)
        finally:
            self.release(instance, (source.hwnd, target.hwnd))
        wait(lambda: counters()[0] == before[0] + 1, 10)
        record["product_trace"] = wait(lambda: target_traces(instance)[traced:] or None, 5)
        time.sleep(SETTLE_S)
        after = counters()
        record.update(counters_after=after, move_loop_after=thread_state(target.hwnd)["move_size"],
                      delta={"drops": after[0] - before[0], "full_refusals": after[1] - before[1], "merges": after[2] - before[2]})
        return record

    def full_target(self, instance, source, target, before):
        api = gui.win32()
        if (target.query(4), source.query(4)) != (64, 1):
            raise AssertionError("MIG-04 needs a restored 64-tab target and a single-tab source")
        refused = self.cross_window_drop(instance, source, target, "full-64")
        self.check("full-target-drop", **refused)
        decided = [{"outcome": "full", "hwnd": target.hwnd, "pid": instance.pid, "class": gui.WINDOW_CLASS}]
        if refused["delta"] != {"drops": 1, "full_refusals": 1, "merges": 0} or refused["product_trace"] != decided:
            raise AssertionError(f"the real drop did not reach the full-target refusal: {refused['delta']}, "
                                 f"decided by {refused['product_trace']}, z-order hit {refused['hit_before_release']}")
        moved = [refused["moving_rect"][axis] - refused["loop_rect"][axis] for axis in (0, 1)]
        pointer = [refused["release_cursor"][axis] - refused["loop_cursor"][axis] for axis in (0, 1)]
        if abs(pointer[0]) < 100 or max(abs(moved[axis] - pointer[axis]) for axis in (0, 1)) > 3:
            raise AssertionError(f"source window did not follow the pointer in the native move loop: {moved} vs {pointer}")
        if not api.IsWindow(source.hwnd) or (target.query(4), source.query(4)) != (64, 1):
            raise AssertionError("refused drop changed the tab counts or closed the source")
        assert_continuity(before, source.tree())
        self.check("full-target-refused", moved=moved, pointer=pointer, source=source.tree(), target_tabs=target.query(4))
        self.capture_native(instance, target, "full-target-after-refusal")
        self.capture_native(instance, source, "source-after-refusal")
        # Positive control: the identical gesture merges once the target has room,
        # proving the refusal above was reached by a real drop, not a miss.
        self.place(source.hwnd, 0)
        assert target.control(8) == 1  # Removes the active single-leaf tab (64 -> 63).
        wait(lambda: target.query(4) == 63)
        time.sleep(0.5)
        cores = {n["leaf"]["core"] for n in before["nodes"] if "leaf" in n}
        source_hwnd = source.hwnd
        merged = self.cross_window_drop(instance, source, target, "control-63")
        self.check("control-target-drop", **merged)
        decided = [{"outcome": "local", "hwnd": target.hwnd, "pid": instance.pid, "class": gui.WINDOW_CLASS}]
        if merged["delta"] != {"drops": 1, "full_refusals": 0, "merges": 1} or merged["product_trace"] != decided:
            raise AssertionError(f"the control drop did not merge: {merged['delta']}, decided by {merged['product_trace']}, "
                                 f"z-order hit {merged['hit_before_release']}")
        wait(lambda: not api.IsWindow(source_hwnd), 10)
        if target.query(4) != 64:
            raise AssertionError("merged control drop did not fill the target to 64")
        index = next(i for i in range(64) if target.query(5, i) == len(before["nodes"])
                     and {n["leaf"]["core"] for n in target.tree(i)["nodes"] if "leaf" in n} == cores)
        assert_continuity(before, target.tree(index))
        self.check("control-merged-complete-tree", tab=index, tree=target.tree(index))
        self.capture_native(instance, target, "control-target-after-merge")

    def thresholds(self, instance, native):
        gui.win32().activate(native.hwnd)
        x, y, w, h = native.tab_rect(0)
        point = round(x + w / 3), round(y + h / 2)
        dpi = native.query(23)
        limits = drag_thresholds(dpi)
        sides = {"press": point,
                 "h_at": (point[0] + limits["horizontal"]["at_or_below_px"], point[1]),
                 "h_above": (point[0] + limits["horizontal"]["above_px"], point[1]),
                 "v_at": (point[0], point[1] + limits["vertical"]["at_or_below_px"]),
                 "v_above": (point[0], point[1] + limits["vertical"]["above_px"])}
        exact = {name: calibrate(instance, target) for name, target in sides.items()}
        self.check("exact-cursor-calibration", dpi=dpi, limits=limits, pixels=sides, normalized=exact)
        api = gui.win32()
        # One press crosses each boundary: the at-or-below read happens only
        # after the cursor is on the exact pixel and the UI thread settled.
        self.exact_move(instance, exact["press"], sides["press"])
        api.send([api.mouse_input(gui.MOUSE_BUTTONS["left"][0])])
        try:
            self.exact_move(instance, exact["h_at"], sides["h_at"])
            reads = self.settled(lambda: native.query(1))
            self.check("horizontal-at-or-below", pixels=sides["h_at"][0] - point[0], dip=(sides["h_at"][0] - point[0]) * 96 / dpi, drag_active=reads)
            if reads != [0, 0]:
                raise AssertionError(f"drag became active at or below 10 DIP: {reads}")
            self.capture_native(instance, native, "horizontal-at-or-below")
            self.exact_move(instance, exact["h_above"], sides["h_above"])
            wait(lambda: native.query(1) == 1, 5)
            self.check("horizontal-above", pixels=sides["h_above"][0] - point[0], dip=(sides["h_above"][0] - point[0]) * 96 / dpi, drag_active=1)
            self.capture_native(instance, native, "horizontal-above")
        finally:
            self.release(instance, (native.hwnd,))
        time.sleep(0.5)
        windows = len(self.windows(instance))
        self.exact_move(instance, exact["press"], sides["press"])
        api.send([api.mouse_input(gui.MOUSE_BUTTONS["left"][0])])
        try:
            self.exact_move(instance, exact["v_at"], sides["v_at"])
            reads = self.settled(lambda: (len(self.windows(instance)), native.query(1), thread_state(native.hwnd)["move_size"]))
            self.check("vertical-at-or-below", pixels=sides["v_at"][1] - point[1], dip=(sides["v_at"][1] - point[1]) * 96 / dpi, reads=reads)
            if reads != [(windows, 0, 0)] * 2:
                raise AssertionError(f"detach started at or below 15 DIP: {reads}")
            self.exact_move(instance, exact["v_above"], sides["v_above"])
            wait(lambda: len(self.windows(instance)) == windows + 1, 10)
            self.check("vertical-above", pixels=sides["v_above"][1] - point[1], dip=(sides["v_above"][1] - point[1]) * 96 / dpi, windows=windows + 1)
        finally:
            # Release first; Escape would deliberately roll the detach back.
            self.release(instance, [w.hwnd for w in self.windows(instance)] + [native.hwnd])
        time.sleep(0.5)
        self.check("vertical-after-release", windows=len(self.windows(instance)))

    def run_case(self):
        result = 0
        try:
            if self.case_id in ("MIG-02", "MIG-02b", "MIG-03", "MIG-07", "MIG-08"):
                import gx_boundary_remote
                gx_boundary_remote.run(self)
            elif self.case_id.startswith("IPC-"):
                import gx_boundary_ipc
                gx_boundary_ipc.run(self)
            elif self.case_id.startswith("UIA-"):
                import gx_boundary_uia
                gx_boundary_uia.run(self)
            elif self.case_id.startswith("OLE-"):
                import gx_boundary_ole
                gx_boundary_ole.run(self)
            else:
                self.migration()
            self.report["status"] = "PASS_NATIVE_VISUAL_PENDING"
        except EnvironmentUnavailable as error:
            self.report.update(status="PENDING", reason=str(error))
            result = 2
        except PeerInterfaceUnavailable as error:
            self.report.update(status="WAITING_INTERFACE", reason=str(error))
            result = 2
        except Exception as error:
            self.report.update(status="FAIL", reason=str(error), traceback=traceback.format_exc())
            # Failure capture never takes focus back after a guard failure.
            # Only the already-foreground owned window may be read here.
            for instance in reversed(self.owned):
                try:
                    instance.ensure_foreground()
                    foreground = gui.win32().foreground()
                    window = next(w for w in instance.windows() if w.hwnd == foreground and w.visible)
                    name = "failure-owned-foreground.png"
                    instance.capture_window(window, "screen").save_png(self.out / name)
                    self.report["captures"].append({"file": name, "method": "screen", "review": "PENDING_REVIEW"})
                    break
                except Exception as capture_error:
                    self.report.setdefault("failure_capture_errors", []).append(str(capture_error))
                    continue
            result = 1
        finally:
            for instance in reversed(self.owned):
                try:
                    if instance.alive():
                        outcome = instance.close(5)
                        if outcome == "terminated":
                            self.report.update(status="FAIL", cleanup="owned GUI required termination")
                            result = 1
                    if instance.log.exists():
                        (self.out / f"app-{instance.pid}.log").write_bytes(instance.log.read_bytes())
                    self.report.setdefault("exits", []).append({"pid": instance.pid, "birth": instance.creation,
                                                               "exit_code": self.processes[instance.pid].poll()})
                except Exception as cleanup_error:
                    self.report.setdefault("cleanup_errors", []).append({"pid": instance.pid, "error": str(cleanup_error)})
                    self.report["status"], result = "FAIL", 1
            write_review(self.out, self.case_id, "r6 native boundary", "host", self.report["status"],
                         [c["file"] for c in self.report["captures"]], observations=self.report["native"])
            (self.out / "report.json").write_text(json.dumps(self.report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--desktop-held", action="store_true")
    parser.add_argument("--ole-source", type=Path)
    parser.add_argument("--remote-controls", type=Path, help="root-provided A2r native selector contract")
    parser.add_argument("--allow-load-layouts", action="store_true",
                        help="VM only: load English (US) when it is not loaded (unloaded again); never on the host")
    parser.add_argument("--case", required=True, action="append", choices=("MIG-01", "MIG-02", "MIG-02-local", "MIG-02b", "MIG-03", "MIG-04", "MIG-05", "MIG-07", "MIG-08", "MIG-08-local",
                                                          "IPC-02h", "IPC-03", "IPC-04b", "IPC-06", "IPC-07",
                                                          "UIA-02", "UIA-03", "UIA-04", "OLE-07", "OLE-08", "OLE-09"))
    args = parser.parse_args(argv)
    if len(set(args.case)) != len(args.case):
        parser.error("each case runs at most once per batch; use a new reviewed batch after a fix")
    batch = len(args.case) > 1
    if batch:
        args.out.mkdir(parents=True, exist_ok=False)
    results = []
    with fixture_slots(ROOT, args.desktop_held):
        for case_id in args.case:
            case_args = argparse.Namespace(**{**vars(args), "case": case_id, "out": args.out / case_id if batch else args.out})
            fixture = BoundaryFixture(case_args)
            result = fixture.run_case()
            row = {"case_id": case_id, "status": fixture.report["status"], "exit_code": result, "report": str(fixture.out / "report.json")}
            results.append(row)
            print(json.dumps(row), flush=True)
            if batch:
                (args.out / "batch.json").write_text(json.dumps({"planned": args.case, "results": results}, indent=2) + "\n", encoding="utf-8")
            if result:
                return result
    return 0


if __name__ == "__main__":
    sys.modules["gx_boundary_controller"] = sys.modules[__name__]
    raise SystemExit(main())
