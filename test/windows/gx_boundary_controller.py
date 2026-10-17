"""r6 native boundary controllers. Requires an owned, frozen app and desktop slot.

Only scalar test messages are sent to PID/birth/hash-checked owned windows.
No remote protocol packet, clipboard content, global system setting or foreign
process is changed. Environment/API absence and missing peer interfaces have
different statuses; neither is reported as an implemented passing scenario.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_win_gui as gui
from gx_fixture_evidence import fixture_slots, native_snapshot, process_identity, sha256, write_review, drag_thresholds
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
                                "keybind = ctrl+alt+r=new_split:right\nkeybind = ctrl+alt+l=goto_split:left\n"
                                "keybind = ctrl+alt+h=goto_split:right\nkeybind = ctrl+alt+b=scroll_to_bottom\n")
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
        ordered = sorted(self.windows(source), key=lambda w: w.title)
        source_window = ordered[0]
        if remote:
            target = self.start(path, ("--gx-session-restore=false",), env={"GX_A3_REMOTE_ROLE": "target"})
            target.wait_window(30)
            target_window = target.require_window()
        else:
            target, target_window = source, ordered[1]
        # Equal physical client geometry avoids treating reflow as lost history.
        api = gui.win32()
        for window, x in ((source_window, 80), (target_window, 1500)):
            api.SetWindowPos(window.hwnd, None, x, 160, 1200, 780, 0x0014)
        time.sleep(0.4)
        return source, Native(source, source_window.hwnd), target, Native(target, target_window.hwnd)

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

    def drag(self, instance, start, end, *, release=True, steps=20):
        instance.ensure_foreground()
        instance.drag(start, end, steps=steps, release=release, step_delay=0.025)

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
            assert second.query(4) == 64
            x, y, w, h = first.tab_rect(0)
            tx, ty, tw, th = second.tab_rect(63)
            gui.win32().activate(first.hwnd)
            self.drag(source, (round(x + w / 3), round(y + h / 2)), (round(tx + tw / 3), round(ty + th / 2)))
            time.sleep(0.5)
            assert second.query(4) == 64 and first.query(4) == 1
            assert_continuity(before, first.tree())
            self.check("full-target-refused", source=first.tree(), target_tabs=second.query(4))
        elif self.case_id == "MIG-05":
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
            assert first.control(3, second.hwnd) == 1
            assert_continuity(before, second.tree())
            self.check("complete-tree-merge", before=before, after=second.tree())
            detached = second.control(4)
            assert detached > 0
            third = Native(source, detached)
            # Normalize destination size before comparing physical scroll metrics.
            gui.win32().SetWindowPos(third.hwnd, None, 80, 160, 1200, 780, 0x0014)
            time.sleep(0.3)
            assert_continuity(before, third.tree())
            self.check("complete-tree-detach", after=third.tree())
            self.capture_native(source, third, "detached")
            if self.case_id == "MIG-08":
                first.guard()
                gui.win32().PostMessageW(first.hwnd, gui.WM_CLOSE, 0, 0)
                wait(lambda: not gui.win32().IsWindow(first.hwnd))
                gui.win32().activate(third.hwnd)
                source.press("ctrl+alt+r")
                wait(lambda: third.query(5, third.query(3)) == len(before["nodes"]) + 2)
                source.press("ctrl+shift+f")
                wait(lambda: source.popups())
                source.type_text("GX_A3_SEARCH")
                source.press("escape")
                third.control(6, -1)
                # Real shell output and wheel input, never copied transcript.
                source.type_text("for /l %i in (1,1,200) do @echo GX_A3_SEARCH_%i")
                source.press("enter")
                time.sleep(0.5)
                terminal = source.terminals(next(w for w in source.windows() if w.hwnd == third.hwnd))[0]
                left, top, right, bottom = terminal.rect
                source.wheel((left + right) // 2, (top + bottom) // 2, count=4)
                self.check("source-closed-split-search-scroll", after=third.tree())
                self.capture_native(source, third, "source-closed-live")
        for index, window in enumerate(self.windows(source)):
            self.capture(source, f"after-{index}", window)

    def thresholds(self, instance, native):
        gui.win32().activate(native.hwnd)
        x, y, w, h = native.tab_rect(0)
        point = round(x + w / 3), round(y + h / 2)
        limits = drag_thresholds(native.query(23))
        for pixels, active in ((limits["horizontal"]["at_or_below_px"], 0), (limits["horizontal"]["above_px"], 1)):
            instance.mouse(*point, action="down")
            try:
                instance.mouse(point[0] + pixels, point[1], action="move")
                wait(lambda: native.query(1) == active)
                self.check("horizontal-strict", pixels=pixels, dip=pixels * 96 / native.query(23), drag_active=native.query(1))
                self.capture_native(instance, native, f"horizontal-{pixels}")
            finally:
                instance.ensure_foreground()
                instance.mouse(point[0] + pixels, point[1], action="up")
        # Existing vertical controller is retained, now using native geometry.
        below = limits["vertical"]["at_or_below_px"]
        self.drag(instance, point, (point[0], point[1] + below), steps=1)
        assert len(self.windows(instance)) == 2
        instance.mouse(*point, action="down")
        try:
            instance.mouse(point[0], point[1] + limits["vertical"]["above_px"], action="move")
            wait(lambda: len(self.windows(instance)) == 3)
            self.check("vertical-strict", limits=limits, windows=3)
        finally:
            instance.ensure_foreground()
            # Release first; Escape would deliberately roll the detach back.
            gui.win32().send([gui.win32().mouse_input(gui.MOUSE_BUTTONS["left"][1])])

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
    parser.add_argument("--case", required=True, action="append", choices=("MIG-01", "MIG-02", "MIG-02-local", "MIG-02b", "MIG-03", "MIG-04", "MIG-05", "MIG-07", "MIG-08",
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
