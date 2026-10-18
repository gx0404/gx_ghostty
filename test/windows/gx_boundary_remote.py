"""Full-tree remote continuity and the coordinator-supplied ACK-loss seam."""
import json
from pathlib import Path
import time

from gx_boundary_controller import InputLanguage, Native, PeerInterfaceUnavailable, assert_continuity, signed_result
from gx_session_ipc_fixture import wait
from gx_fixture_evidence import native_snapshot
import gx_win_gui as gui


def core_set(tree):
    return {n["leaf"]["core"] for n in tree["nodes"] if "leaf" in n}


def find_tree(instance, cores):
    """The owned window and tab holding exactly `cores`, or None.

    A transfer or drag-back closes and creates windows while this polls; a
    window destroyed mid-scan is skipped. A live HWND whose identity changed
    still fails (Native.guard), as does any other error."""
    instance.ensure_owned()
    for window in instance.windows():
        if window.cls != gui.WINDOW_CLASS:
            continue
        try:
            native = Native(instance, window.hwnd)
            for tab in range(native.query(4)):
                tree = native.tree(tab)
                if core_set(tree) == cores:
                    return native, tab, tree
        except (gui.InputBlocked, AssertionError, PeerInterfaceUnavailable):
            if gui.win32().IsWindow(window.hwnd):
                raise
    return None


class RemoteControls:
    """A2r GhosttyRemotePane test contract from root-supplied JSON; no guessed selectors.

    LRESULTs are signed: -1 is an invalid argument or duplicate arming, -2 not
    ready or disconnected; both fail closed and never read as counter growth.
    Only after capability equals the magic is any value (including 0) real:
    with the gate off DefWindowProcW answers 0 for these messages."""
    REQUIRED = ("scrollback_total", "scrollback_viewport", "scrollback_offset", "input_applied", "input_query_count", "ack_dropped")
    MONOTONIC = ("input_applied", "input_query_count", "ack_dropped")
    PANE_CLASS = "GhosttyRemotePane"
    ERRORS = {-1: "invalid argument or duplicate arming", -2: "not ready or disconnected"}

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
        if self.spec["capability"]["value"] <= 0:
            raise ValueError("A2r capability magic must be positive")

    def call(self, instance, hwnd, message, wparam, lparam=0):
        instance.ensure_owned()
        api = gui.win32()
        if api.window_pid(hwnd) != instance.pid or api.class_name(hwnd) != self.PANE_CLASS:
            raise gui.InputBlocked("A2r fixture HWND is not the owned GhosttyRemotePane")
        result = api.send_message(hwnd, message, wparam, lparam, timeout_ms=2500)
        if result is None:
            raise AssertionError("A2r native control/query timed out")
        return signed_result(result)  # SendMessageTimeoutW reports LRESULT bits unsigned.

    def query(self, instance, hwnd, field):
        value = self.call(instance, hwnd, self.spec["query_message"], self.spec[field])
        if value < 0:
            raise AssertionError(f"A2r query {field} returned {value}: {self.ERRORS.get(value, 'negative result')}")
        return value

    def wait_ready(self, instance, hwnd, timeout=15.0):
        """Poll capability until it equals the magic; only then take baselines."""
        capability = self.spec["capability"]
        deadline = time.monotonic() + timeout
        last = None
        while True:
            last = self.call(instance, hwnd, self.spec["query_message"], capability["selector"])
            if last == capability["value"]:
                return last
            if time.monotonic() > deadline:
                break
            time.sleep(0.05)
        if last == 0:
            raise PeerInterfaceUnavailable("GhosttyRemotePane answered 0: A2r controls are absent from this build or the gate is off")
        raise AssertionError(f"A2r capability did not become ready within {timeout:g}s (last {last}: {self.ERRORS.get(last, 'unexpected')})")

    def snapshot(self, instance, hwnd):
        return {name: self.query(instance, hwnd, name) for name in self.REQUIRED}

    def arm(self, instance, hwnd):
        self.wait_ready(instance, hwnd)
        control = self.spec["ack_drop"]
        result = self.call(instance, hwnd, control["message"], control["wparam"], control["lparam"])
        if result != 1:
            raise AssertionError(f"A2r ACK-drop arming returned {result}: {self.ERRORS.get(result, 'not armed')}")
        return result


def settle_counter(read, baseline, timeout=10.0, quiet=0.75):
    """A monotonic A2r counter after it passed baseline and stopped moving."""
    deadline = time.monotonic() + timeout
    value = read()
    while value <= baseline:
        if time.monotonic() > deadline:
            raise AssertionError(f"counter did not move past {baseline}")
        time.sleep(0.05)
        value = read()
    while True:
        time.sleep(quiet)
        again = read()
        if again < value:
            raise AssertionError("monotonic A2r counter decreased")
        if again == value:
            return value
        value = again
        if time.monotonic() > deadline:
            raise AssertionError("counter never settled")


def remote_leaf(tree, core):
    return next(n["leaf"] for n in tree["nodes"] if "leaf" in n and n["leaf"]["core"] == core)


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
        fixture.place(restored.hwnd, 0)
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
        controls.wait_ready(target, pane)
        applied = lambda: controls.query(target, pane, "input_applied")
        # Control: the identical one-character input without ACK loss gives the
        # expected applied delta, so the lossy run proves "exactly once".
        start = applied()
        target.type_text("y")
        control_delta = settle_counter(applied, start) - start
        target.press("backspace")
        time.sleep(0.75)
        target.type_text("set /p GX_A3_ACK=")
        target.press("enter")
        time.sleep(0.75)
        counts = controls.snapshot(target, pane)
        time.sleep(0.5)
        again = controls.snapshot(target, pane)
        if any(again[name] != counts[name] for name in controls.MONOTONIC):
            raise AssertionError(f"A2r counters still moving before the baseline: {counts} -> {again}")
        controls.arm(target, pane)
        target.type_text("x")
        wait(lambda: controls.query(target, pane, "ack_dropped") > counts["ack_dropped"])
        wait(lambda: controls.query(target, pane, "input_query_count") > counts["input_query_count"])
        lossy_delta = settle_counter(applied, counts["input_applied"]) - counts["input_applied"]
        dropped = controls.query(target, pane, "ack_dropped") - counts["ack_dropped"]
        if dropped != 1 or lossy_delta != control_delta:
            raise AssertionError(f"ACK loss changed applied input: dropped {dropped}, lossy {lossy_delta}, control {control_delta}")
        target.press("enter")
        target.type_text("echo %GX_A3_ACK%>ack-exactly-once.txt")
        target.press("enter")
        path = source.env_dir / "ack-exactly-once.txt"
        wait(lambda: path.exists() and path.read_text().strip())
        # The original PTY's set /p received exactly one x: no replayed input.
        assert path.read_text().strip() == "x", "lost ACK replayed terminal input"
        fixture.check("ACK-lost-query-not-replay", before=counts, control_delta=control_delta, lossy_delta=lossy_delta,
                      ack_dropped=dropped, file=str(path), after=controls.snapshot(target, pane))
    if fixture.case_id == "MIG-08":
        controls = RemoteControls(fixture.args.remote_controls)
        controls.wait_ready(target, pane)
        gui.win32().PostMessageW(initial.hwnd, gui.WM_CLOSE, 0, 0)
        wait(lambda: not gui.win32().IsWindow(initial.hwnd))
        # The hidden source host keeps the original PTY; the pane stays live.
        controls.wait_ready(target, pane)
        gui.win32().activate(destination.hwnd)
        language = InputLanguage(fixture, target, destination.hwnd)
        try:
            language.us()
            target.press("ctrl+alt+r")
            wait(lambda: len(destination.tree()["nodes"]) == len(before["nodes"]) + 2)
            tab = destination.query(3)
            current = destination.tree()
            remote_index = next(i for i, n in enumerate(current["nodes"]) if "leaf" in n and n["leaf"]["core"] == before["active_core"])
            destination.control(6, -1)
            destination.control(7, remote_index)
            target.type_text("for /l %i in (1,1,200) do @echo GX_A3_REMOTE_SEARCH_%i")
            target.press("enter")
            wait(lambda: controls.query(target, pane, "scrollback_total") > controls.query(target, pane, "scrollback_viewport") + 100)
            target.press("ctrl+shift+f")
            wait(lambda: destination.query(24, tab, remote_index) == 1)
            target.type_text("GX_A3_REMOTE_SEARCH")
            wait(lambda: destination.query(25, tab, remote_index) > 0)
            fixture.check("remote-search-matches", count=destination.query(25, tab, remote_index))
            fixture.capture_native(target, destination, "remote-search-after-source-close")
            target.press("escape")
            target.press("ctrl+alt+b")
            def at_bottom():
                state = controls.snapshot(target, pane)
                bottom = state["scrollback_offset"] + state["scrollback_viewport"] == state["scrollback_total"]
                return state if bottom and state["scrollback_offset"] > 0 else None
            bottom = wait(at_bottom)
            rect = gui.win32().window_rect(pane)
            target.wheel((rect[0] + rect[2]) // 2, (rect[1] + rect[3]) // 2, count=4)
            scrolled = wait(lambda: (lambda state: state if state["scrollback_offset"] < bottom["scrollback_offset"] else None)(controls.snapshot(target, pane)))
            # The source PageList itself, read in the source process, agrees.
            def agrees():
                local = remote_leaf(hidden.tree(hidden_tab), before["active_core"])
                state = controls.snapshot(target, pane)
                same = (local["total"], local["viewport"], local["offset"]) == (state["scrollback_total"], state["scrollback_viewport"], state["scrollback_offset"])
                return {"local": local, "remote": state} if same else None
            agreed = wait(agrees, 5)
            fixture.check("closed-source-split-search-scroll", bottom=bottom, scrolled=scrolled, source_host=agreed)
        finally:
            language.restore()
    fixture.capture_native(target, destination, "remote-live-after")
