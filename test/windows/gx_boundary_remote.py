"""Full-tree remote continuity and the coordinator-supplied ACK-loss seam."""
import json
from pathlib import Path
import time

from gx_boundary_controller import Native, PeerInterfaceUnavailable, assert_continuity
from gx_session_ipc_fixture import wait
from gx_fixture_evidence import native_snapshot
import gx_win_gui as gui


def core_set(tree):
    return {n["leaf"]["core"] for n in tree["nodes"] if "leaf" in n}


def find_tree(instance, cores):
    instance.ensure_owned()
    for window in instance.windows():
        if window.cls != gui.WINDOW_CLASS:
            continue
        native = Native(instance, window.hwnd)
        for tab in range(native.query(4)):
            tree = native.tree(tab)
            if core_set(tree) == cores:
                return native, tab, tree
    return None


class RemoteControls:
    """No guessed selector numbers. Fail closed until root supplies this schema."""
    REQUIRED = ("scrollback_total", "scrollback_viewport", "scrollback_offset", "input_applied", "input_query_count", "ack_dropped")
    def __init__(self, path):
        if path is None:
            raise PeerInterfaceUnavailable("A2r contract required: --remote-controls JSON; see README exact schema")
        self.spec = json.loads(Path(path).read_text(encoding="utf-8"))
        if self.spec.get("version") != 1 or type(self.spec.get("query_message")) is not int or not 0x400 <= self.spec["query_message"] < 0x8000:
            raise ValueError("invalid A2r query contract")
        for name in self.REQUIRED:
            if type(self.spec.get(name)) is not int or not 0 <= self.spec[name] <= 65535:
                raise ValueError(f"missing A2r selector: {name}")
        if set(self.spec.get("capability", {})) != {"selector", "value"} or set(self.spec.get("ack_drop", {})) != {"message", "wparam", "lparam"}:
            raise ValueError("A2r capability and one-shot ACK-drop controls must be explicit")
        values = [*self.spec["capability"].values(), *self.spec["ack_drop"].values()]
        if any(type(value) is not int for value in values) or not 0x400 <= self.spec["ack_drop"]["message"] < 0x8000:
            raise ValueError("A2r controls must be scalar private test messages")

    def call(self, instance, hwnd, message, wparam, lparam=0):
        instance.ensure_owned()
        if gui.win32().window_pid(hwnd) != instance.pid:
            raise gui.InputBlocked("A2r fixture HWND owner changed")
        result = gui.win32().send_message(hwnd, message, wparam, lparam, timeout_ms=2500)
        if result is None:
            raise AssertionError("A2r native control/query timed out")
        return result

    def query(self, instance, hwnd, field):
        return self.call(instance, hwnd, self.spec["query_message"], self.spec[field])

    def arm(self, instance, hwnd):
        capability = self.spec["capability"]
        if self.call(instance, hwnd, self.spec["query_message"], capability["selector"]) != capability["value"]:
            raise PeerInterfaceUnavailable("A2r frozen app does not expose the declared capability")
        control = self.spec["ack_drop"]
        assert self.call(instance, hwnd, control["message"], control["wparam"], control["lparam"]) == 1


def run(fixture):
    source, initial, target, destination = fixture.stage(remote=True)
    initial.control(5, 0)
    fixture.populate_history(source, initial)
    before = initial.tree()
    cores = core_set(before)
    source_identity = native_snapshot(source)
    target_identity = native_snapshot(target)
    fixture.capture_native(source, initial, "remote-whole-tree-before")
    accepted = gui.win32().send_message(initial.hwnd, 0x44f, target.pid, target.creation, timeout_ms=5000)
    assert accepted == 1
    def ready():
        found = find_tree(target, cores)
        if not found:
            return None
        native, tab, tree = found
        native.control(5, tab)
        flags = gui.win32().send_message(native.hwnd, 0x450, 1, 0, timeout_ms=2500)
        if flags is not None and flags & 31 == 31:
            return native, tree
        return None
    destination, after = wait(ready, 30)
    wait(lambda: initial.query(4) == 1)
    assert_continuity(before, after, remote=True)
    hidden, hidden_tab, hidden_tree = wait(lambda: find_tree(source, cores))
    assert_continuity(before, hidden_tree)
    assert source_identity["process"] == native_snapshot(source)["process"]
    assert source_identity["children"] == native_snapshot(source)["children"]
    assert target_identity["children"] == native_snapshot(target)["children"]
    fixture.check("cross-host-complete-tree", before=before, target=after, source_hidden=hidden_tree,
                  source=source_identity["process"], target_process=target_identity["process"])
    fixture.capture_native(target, destination, "remote-complete-tree")
    if fixture.case_id == "MIG-02b":
        assert gui.win32().send_message(destination.hwnd, 0x44f, source.pid, source.creation, timeout_ms=5000) == 1
        def returned():
            found = find_tree(source, cores)
            if found and any(w.hwnd == found[0].hwnd and w.visible and not w.cloaked for w in source.windows()):
                return found
        restored, tab, result = wait(returned, 30)
        gui.win32().SetWindowPos(restored.hwnd, None, 80, 160, 1200, 780, 0x0014)
        time.sleep(0.3)
        result = restored.tree(tab)
        assert_continuity(before, result)
        fixture.check("complete-tree-drag-back", result=result)
        fixture.capture_native(source, restored, "drag-back")
        return

    gui.win32().activate(destination.hwnd)
    active = next(n["leaf"] for n in after["nodes"] if "leaf" in n and n["leaf"]["core"] == after["active_core"])
    pane = active["hwnd"]
    rect = gui.win32().window_rect(pane)
    target.mouse((rect[0] + rect[2]) // 2, (rect[1] + rect[3]) // 2)
    assert gui.win32().focus_window(destination.hwnd) == pane, "input focus is not the remote pane"
    marker = "GX_A3_REMOTE_ORIGINAL_PTY"
    output = source.env_dir / "remote-original-pty.txt"
    target.type_text(f"echo {marker}_%GX_A3_REMOTE_ROLE%>remote-original-pty.txt")
    target.press("enter")
    wait(lambda: output.exists() and output.read_text().strip() == marker + "_source")
    fixture.check("actual-input-original-PTY", marker=marker, file=str(output), source_hidden=hidden.tree(hidden_tab))
    if fixture.case_id == "MIG-07":
        controls = RemoteControls(fixture.args.remote_controls)
        target.type_text("set /p GX_A3_ACK=")
        target.press("enter")
        time.sleep(0.2)
        counts = {name: controls.query(target, pane, name) for name in controls.REQUIRED}
        controls.arm(target, pane)
        target.type_text("x")
        wait(lambda: controls.query(target, pane, "ack_dropped") > counts["ack_dropped"])
        wait(lambda: controls.query(target, pane, "input_query_count") > counts["input_query_count"])
        target.press("enter")
        target.type_text("echo %GX_A3_ACK%>ack-exactly-once.txt")
        target.press("enter")
        path = source.env_dir / "ack-exactly-once.txt"
        wait(lambda: path.exists())
        assert path.read_text().strip() == "x", "lost ACK replayed terminal input"
        fixture.check("ACK-lost-query-not-replay", before=counts,
                      after={name: controls.query(target, pane, name) for name in controls.REQUIRED})
    if fixture.case_id == "MIG-08":
        gui.win32().PostMessageW(initial.hwnd, gui.WM_CLOSE, 0, 0)
        wait(lambda: not gui.win32().IsWindow(initial.hwnd))
        gui.win32().activate(destination.hwnd)
        target.press("ctrl+alt+r")
        wait(lambda: len(destination.tree()["nodes"]) == len(before["nodes"]) + 2)
        current = destination.tree()
        remote_index = next(i for i, n in enumerate(current["nodes"]) if "leaf" in n and n["leaf"]["core"] == before["active_core"])
        destination.control(6, -1)
        destination.control(7, remote_index)
        target.type_text("for /l %i in (1,1,200) do @echo GX_A3_REMOTE_SEARCH_%i")
        target.press("enter")
        time.sleep(0.5)
        target.press("ctrl+shift+f")
        wait(lambda: target.popups())
        target.type_text("GX_A3_REMOTE_SEARCH")
        wait(lambda: destination.query(25, destination.query(3), remote_index) > 0)
        fixture.check("remote-search-matches", count=destination.query(25, destination.query(3), remote_index))
        fixture.capture_native(target, destination, "remote-search-after-source-close")
        target.press("escape")
        target.press("ctrl+alt+b")
        wait(lambda: next(n["leaf"]["offset"] for n in hidden.tree(hidden_tab)["nodes"]
                          if "leaf" in n and n["leaf"]["core"] == before["active_core"]) > 0)
        scroll_before = hidden.tree(hidden_tab)
        rect = gui.win32().window_rect(pane)
        target.wheel((rect[0] + rect[2]) // 2, (rect[1] + rect[3]) // 2, count=4)
        def scrolled():
            state = hidden.tree(hidden_tab)
            a = next(n["leaf"] for n in scroll_before["nodes"] if "leaf" in n and n["leaf"]["core"] == before["active_core"])
            b = next(n["leaf"] for n in state["nodes"] if "leaf" in n and n["leaf"]["core"] == before["active_core"])
            return state if b["offset"] < a["offset"] else None
        fixture.check("closed-source-split-search-scroll", scrolled=wait(scrolled))
    fixture.capture_native(target, destination, "remote-live-after")
