"""Run real DoDragDrop against a fresh, identity-checked isolated cmd terminal.

This script never uses the system clipboard and never sends Enter. COPY reports
OLE admission only; saved screenshots require visual review of paste behavior.
"""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_slots  # noqa: E402
import gx_win_gui as gui  # noqa: E402
from gx_fixture_evidence import native_snapshot, write_review, fixture_slots

CASES = {"text": "OLE-00", "unicode": "OLE-01", "single_file": "OLE-02a", "files": "OLE-02b",
         "shell_metachar_files": "OLE-03a", "quoted_path": "OLE-03b", "uri": "OLE-04",
         "multiline": "OLE-05", "unterminated": "OLE-06a", "bad_hdrop": "OLE-06b",
         "bad_uri": "OLE-06c", "text_limit": "OLE-06d", "too_many_files": "OLE-06e"}
REJECTED = {"unterminated", "bad_hdrop", "bad_uri", "text_limit", "too_many_files", "quoted_path"}


def wait(test, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if value := test():
            return value
        time.sleep(0.04)
    raise TimeoutError("bounded fixture wait expired")


def timeout_snapshot(instance, source, source_pid, source_birth, source_hash, work):
    """Read only verified owned GUI thread state; no input or focus changes."""
    instance.ensure_owned()
    backend = gui.win32()
    if (backend.process_creation(source_pid) != source_birth
            or not gui.same_path(backend.process_image(source_pid) or "", source)
            or hashlib.sha256(source.read_bytes()).hexdigest() != source_hash):
        raise ValueError("source identity changed before timeout diagnostics")
    user = ctypes.WinDLL("user32", use_last_error=True)

    class Info(ctypes.Structure):
        _fields_ = [("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD),
                    ("hwndActive", wintypes.HWND), ("hwndFocus", wintypes.HWND),
                    ("hwndCapture", wintypes.HWND), ("hwndMenuOwner", wintypes.HWND),
                    ("hwndMoveSize", wintypes.HWND), ("hwndCaret", wintypes.HWND),
                    ("rcCaret", wintypes.RECT)]

    user.GetGUIThreadInfo.argtypes = [wintypes.DWORD, ctypes.POINTER(Info)]
    user.GetGUIThreadInfo.restype = wintypes.BOOL
    user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user.GetWindowThreadProcessId.restype = wintypes.DWORD

    def sample(thread_id):
        info = Info()
        info.cbSize = ctypes.sizeof(Info)
        if not user.GetGUIThreadInfo(thread_id, ctypes.byref(info)):
            return {"thread_id": thread_id, "error": ctypes.get_last_error()}
        return {"thread_id": thread_id, "flags": info.flags,
                **{key: int(getattr(info, key) or 0) for key in
                   ("hwndActive", "hwndFocus", "hwndCapture", "hwndMenuOwner", "hwndMoveSize")}}

    window = instance.require_window()
    pid = wintypes.DWORD()
    target_thread = user.GetWindowThreadProcessId(window.hwnd, ctypes.byref(pid))
    if pid.value != instance.pid:
        raise ValueError("target HWND identity changed before timeout diagnostics")
    traces = list(work.glob(f"gx-ole-{source_pid}-*/trace.jsonl"))
    events = []
    if traces:
        for line in traces[0].read_text(encoding="utf-8").splitlines()[:256]:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # A final synchronous write may still be in progress.
    source_thread = next((event["thread_id"] for event in events if "thread_id" in event), None)
    foreground = backend.foreground()
    result = {"target": sample(target_thread),
              "source": sample(source_thread) if source_thread else {"status": "thread_id_unavailable"},
              "foreground_hwnd": foreground, "foreground_pid": backend.window_pid(foreground) if foreground else 0,
              "trace_events": len(events), "last_events": events[-12:]}
    # Screenshot guard deliberately remains the original target-only guard.
    try:
        instance.ensure_foreground()
        instance.capture_window(window, "screen").save_png(work / "timeout.png")
        result["capture"] = "timeout.png"
    except Exception as error:
        result["capture_error"] = str(error)
    return result


class OwnedDrag:
    """Fixture-only two-owner guard. The generic GUI input guard is unchanged."""
    def __init__(self, instance, exe, app_hash, source, source_hash, process, birth, source_hwnd, terminal):
        self.instance, self.exe, self.app_hash = instance, exe, app_hash.lower()
        self.source, self.source_hash, self.process, self.birth = source, source_hash.lower(), process, birth
        self.source_hwnd, self.terminal = source_hwnd, terminal
        self.target_hwnd = instance.require_window().hwnd
        self.last_point = None
        self.check_identity()

    def check_identity(self):
        self.instance.ensure_owned()
        w = gui.win32()
        if (self.process.poll() is not None or w.process_creation(self.process.pid) != self.birth
                or not gui.same_path(w.process_image(self.process.pid) or "", self.source)
                or hashlib.sha256(self.source.read_bytes()).hexdigest() != self.source_hash
                or hashlib.sha256(self.exe.read_bytes()).hexdigest() != self.app_hash):
            raise gui.InputBlocked("owned drag process/image identity changed; no input sent")
        if (not w.IsWindow(self.source_hwnd) or w.window_pid(self.source_hwnd) != self.process.pid
                or w.class_name(self.source_hwnd) != "GxOwnedOleDragSource"
                or not w.IsWindow(self.target_hwnd) or w.window_pid(self.target_hwnd) != self.instance.pid
                or not w.IsWindow(self.terminal.hwnd) or w.window_pid(self.terminal.hwnd) != self.instance.pid
                or w.GetAncestor(self.terminal.hwnd, 2) != self.target_hwnd):
            raise gui.InputBlocked("owned drag HWND identity changed; no input sent")

    def activate_source(self):
        self.check_identity()
        if not gui.win32().activate(self.source_hwnd):
            raise gui.InputBlocked("cannot activate the verified source window; no input sent")
        self.check_foreground()

    def check_foreground(self):
        self.check_identity()
        w = gui.win32()
        foreground = w.foreground()
        if not foreground or w.window_pid(foreground) not in (self.process.pid, self.instance.pid):
            raise gui.InputBlocked("foreground is outside the two owned drag processes; no input sent")
        if w.GetAncestor(foreground, 3) not in (self.source_hwnd, self.target_hwnd):
            raise gui.InputBlocked("foreground HWND is outside the owned source/target windows; no input sent")

    def mouse(self, x, y, action="move", target_only=False):
        self.check_foreground()
        w = gui.win32()
        hit = w.window_at(x, y)
        root = w.GetAncestor(hit, 2) if hit else 0
        owner = w.window_pid(hit) if hit else 0
        if not ((root == self.source_hwnd and owner == self.process.pid)
                or (root == self.target_hwnd and owner == self.instance.pid)):
            raise gui.InputBlocked("drag point is outside both owned windows; no input sent")
        if target_only and hit != self.terminal.hwnd:
            raise gui.InputBlocked("drop endpoint is not the verified terminal HWND; no input sent")
        events = [w.mouse_input(0x0001 | 0x8000 | 0x4000, x, y)]
        if action == "down":
            events.append(w.mouse_input(0x0002))
        elif action == "up":
            events.append(w.mouse_input(0x0004))
        elif action != "move":
            raise ValueError("invalid owned drag action")
        w.send(events)
        self.last_point = (x, y)

    def start_point(self):
        self.check_identity()
        w = gui.win32()
        rect = w.RECT()
        if not w.GetClientRect(self.source_hwnd, ctypes.byref(rect)):
            raise gui.InputBlocked("cannot locate owned source client")
        point = w.POINT((rect.right - rect.left) // 2, (rect.bottom - rect.top) // 2)
        if not w.ClientToScreen(self.source_hwnd, ctypes.byref(point)):
            raise gui.InputBlocked("cannot translate owned source client")
        return point.x, point.y


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desktop-held", action="store_true", help="caller already holds Invoke-Desktop")
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--case", choices=tuple(CASES), action="append", required=True)
    parser.add_argument("--source-window", action="store_true", help="Use a real owned source-window drag gesture")
    args = parser.parse_args()
    exe, source, out = args.exe.resolve(strict=True), args.source.resolve(strict=True), args.out.resolve()
    if hashlib.sha256(exe.read_bytes()).hexdigest().lower() != args.sha256.lower():
        raise ValueError("app hash differs from authorized build")
    out.mkdir(parents=True, exist_ok=False)
    report = {"app": str(exe), "app_sha256": args.sha256, "source": str(source),
              "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "cases": [],
              "clipboard_access": False, "enter_injected": False, "visual_review": "PENDING"}
    with fixture_slots(ROOT, args.desktop_held):
        for case in args.case:
            instance, process, button_down = None, None, False
            stdout_file, stderr_file = None, None
            drag = None
            record = {"case": case, "case_id": CASES[case], "boundary": "R5-04", "environment": "host",
                      "status": "RUNNING", "captures": []}
            report["cases"].append(record)
            work = out / case
            work.mkdir()
            try:
                profile = work / "profile"
                gui.prepare_env_dir(profile, False)
                gui.write_config(profile, "language = en\nconfirm-close-surface = false\n"
                                 "command = cmd.exe /d /k prompt GX_OWNED$G$S\n"
                                 "gx-single-instance = false\ngx-session-restore = false\n"
                                 "clipboard-paste-protection = true\nwindow-width = 100\nwindow-height = 28\n")
                instance = gui.launch(exe, profile, env={"GHOSTTY_GX_REMOTE_TEST": "1"})
                record.update(pid=instance.pid, birth=instance.creation, profile=str(profile))
                instance.wait_window(15)
                time.sleep(1)
                instance.remember_children()
                instance.activate()  # A denied foreground request stops here.
                instance.ensure_foreground()
                window = instance.require_window()
                terminals = wait(lambda: instance.terminals(window))
                terminal = terminals[0]
                record["terminal_hwnd"] = terminal.hwnd
                record["before_identity"] = native_snapshot(instance)
                x = terminal.rect[0] + 120
                y = terminal.rect[1] + 80
                instance.capture_window(window, "screen").save_png(work / "before.png")
                record["captures"].append("before.png")
                if not args.source_window:
                    instance.mouse(x, y, action="down")
                    button_down = True
                argv = [str(source), "--run", f"--hwnd={terminal.hwnd:#x}", f"--pid={instance.pid}",
                        f"--birth={instance.creation}", f"--exe={exe}", f"--sha256={args.sha256}",
                        f"--work-dir={work}", f"--case={case}", "--timeout-ms=7000"]
                if args.source_window:
                    argv.append("--source-window")
                stdout_file = (work / "source.stdout.txt").open("wb", buffering=0)
                stderr_file = (work / "source.stderr.txt").open("wb", buffering=0)
                process = subprocess.Popen(argv, stdout=stdout_file, stderr=stderr_file,
                                           creationflags=subprocess.CREATE_NO_WINDOW)
                record["source_pid"] = process.pid
                record["source_birth"] = gui.win32().process_creation(process.pid)
                ready = wait(lambda: next(work.glob(f"gx-ole-{process.pid}-*/ready.json"), None)
                             if process.poll() is None else (_ for _ in ()).throw(RuntimeError("OLE source exited before ready")))
                record["ready"] = json.loads(ready.read_text(encoding="utf-8"))
                files_before = {str(file.relative_to(work)): hashlib.sha256(file.read_bytes()).hexdigest()
                                for file in ready.parent.glob("*.txt")}
                time.sleep(0.3)
                if args.source_window:
                    facts = record["ready"]
                    if (facts.get("source_pid") != process.pid or facts.get("target_pid") != instance.pid
                            or facts.get("target_birth") != instance.creation or facts.get("target_hwnd") != terminal.hwnd
                            or facts.get("app_sha256", "").lower() != args.sha256.lower() or not facts.get("source_hwnd")):
                        raise ValueError("source ready identities do not match this fixture")
                    drag = OwnedDrag(instance, exe, args.sha256, source, report["source_sha256"], process,
                                     record["source_birth"], facts["source_hwnd"], terminal)
                    drag.activate_source()
                    start = drag.start_point()
                    end = (terminal.rect[2] - 80, terminal.rect[1] + 160)
                    record["drag"] = {"source_hwnd": facts["source_hwnd"], "start": start, "end": end, "steps": 16}
                    drag.mouse(*start, action="down")
                    button_down = True
                    for step in range(1, 17):
                        x = round(start[0] + (end[0] - start[0]) * step / 16)
                        y = round(start[1] + (end[1] - start[1]) * step / 16)
                        drag.mouse(x, y)
                        time.sleep(0.03)
                    time.sleep(0.3)
                    drag.mouse(*end, action="up", target_only=True)
                else:
                    instance.ensure_foreground()
                    instance.mouse(x, y, action="up")
                button_down = False
                process.wait(timeout=12)
                record["source_exit"] = process.returncode
                record["native"] = json.loads((ready.parent / "evidence.json").read_text(encoding="utf-8"))
                expected_exit = 4 if case in REJECTED else 0
                if process.returncode != expected_exit:
                    raise AssertionError(f"DoDragDrop source returned {process.returncode}")
                expected_effect = 0 if case in REJECTED else 1
                if record["native"]["effect"] != expected_effect:
                    raise AssertionError("unexpected OLE admission effect")
                if record["native"]["get_data"] != record["native"]["medium_releases"]:
                    raise AssertionError("OLE storage medium was not released exactly once")
                record["after_identity"] = native_snapshot(instance)
                record["source_files"] = {str(file.relative_to(work)): hashlib.sha256(file.read_bytes()).hexdigest()
                                          for file in ready.parent.glob("*.txt")}
                if record["source_files"] != files_before:
                    raise AssertionError("source file was moved, removed or changed during drop")
                time.sleep(0.5)
                if args.source_window:
                    instance.activate()
                instance.ensure_foreground()
                instance.capture_window(instance.require_window(), "screen").save_png(work / "after.png")
                record["captures"].append("after.png")
                if case == "multiline":
                    popups = wait(lambda: instance.popups())
                    popup = max(popups, key=lambda item: (item.rect[2]-item.rect[0]) * (item.rect[3]-item.rect[1]))
                    instance.capture_window(popup, "screen").save_png(work / "protected-confirm.png")
                    record["captures"].append("protected-confirm.png")
                    record["protected_confirmation"] = {"hwnd": popup.hwnd, "class": popup.cls}
                    instance.press("escape")  # Cancel; never authorize multiline execution.
                    time.sleep(0.2)
                    instance.capture_window(instance.require_window(), "screen").save_png(work / "cancelled.png")
                    record["captures"].append("cancelled.png")
                record["status"] = "NATIVE_PASS_VISUAL_PENDING"
            except Exception as error:
                record.update(status="FAIL", reason=str(error), traceback=traceback.format_exc())
                if isinstance(error, subprocess.TimeoutExpired) and instance is not None and process is not None:
                    try:
                        record["timeout_diagnostics"] = timeout_snapshot(
                            instance, source, process.pid, record["source_birth"], report["source_sha256"], work)
                    except Exception as diagnostic_error:
                        record["timeout_diagnostics"] = {"error": str(diagnostic_error)}
            finally:
                if button_down and instance is not None:
                    try:
                        if drag is not None and drag.last_point is not None:
                            drag.mouse(*drag.last_point, action="up")
                        else:
                            instance.ensure_foreground()
                            instance.mouse(x, y, action="up")
                        record["mouse_cleanup"] = "released on verified owned window"
                    except Exception as error:
                        record["mouse_cleanup"] = f"BLOCKED: {error}; no input sent"
                if process is not None and process.poll() is None:
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        if (gui.same_path(gui.win32().process_image(process.pid) or "", source)
                                and gui.win32().process_creation(process.pid) == record.get("source_birth")):
                            process.terminate()
                            process.wait(timeout=5)
                            record["source_cleanup"] = "terminated owned timed-out fixture; not lifecycle PASS"
                if stdout_file is not None:
                    stdout_file.close()
                if stderr_file is not None:
                    stderr_file.close()
                if instance is not None:
                    if instance.log.exists():
                        (work / "ghostty.log").write_bytes(instance.log.read_bytes())
                    if instance.alive():
                        record["app_cleanup"] = instance.close(5)
                (out / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
                write_review(work, CASES[case], "R5-04 typed DoDragDrop, no Enter/clipboard", "host",
                             "FAIL" if record["status"] == "FAIL" else "PASS", record["captures"],
                             observation=record, paste_verification="PENDING_REVIEW",
                             source_scope="controlled IDataObject; Explorer has a separate case")
            if record["status"] == "FAIL":
                break  # Do not expand after a failed identity/focus/native check.
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return int(any(case["status"] == "FAIL" for case in report["cases"]))


if __name__ == "__main__":
    raise SystemExit(main())
