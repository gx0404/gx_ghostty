"""Native identity and per-case review records shared by Windows fixtures.

This module never launches a process, sends input, or reads the clipboard.
Missing observations remain explicit; screenshots alone cannot prove identity.
"""
from __future__ import annotations

import hashlib
import json
from contextlib import contextmanager
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def process_identity(api, pid):
    birth, image = api.process_creation(pid), api.process_image(pid)
    if not birth or not image or not api.process_alive(pid):
        raise AssertionError(f"process {pid} is no longer queryable")
    result = {"pid": pid, "birth": birth, "exe": image, "sha256": sha256(image)}
    if api.process_creation(pid) != birth:
        raise AssertionError("PID reused while hashing executable")
    return result


def native_snapshot(instance, *, hooks=True):
    # Lazy import keeps pure contract tests portable.
    import gx_win_gui as gui

    instance.ensure_owned()
    api = gui.win32()
    process = process_identity(api, instance.pid)
    if process["birth"] != instance.creation or not gui.same_path(process["exe"], instance.exe):
        raise gui.InputBlocked("fixture owner identity changed")
    windows = []
    for window in instance.windows():
        if window.cls != gui.WINDOW_CLASS:
            continue
        entry = {"hwnd": window.hwnd, "dpi": api.GetDpiForWindow(window.hwnd),
                 "visible": window.visible, "title": window.title,
                 "surface_id": None, "terminal_hwnd": None, "pty": None,
                 "scrollback_count": None, "scrollback_status": "PENDING_NATIVE_COUNTER"}
        if hooks and api.send_message(window.hwnd, 0x450, 0, 0, timeout_ms=2000) == 0x47585231:
            for field, selector in (("surface_id", 2), ("terminal_hwnd", 7), ("tabs", 12),
                                    ("leaves", 13), ("local_leaves", 14), ("remote_leaves", 15)):
                value = api.send_message(window.hwnd, 0x450, selector, 0, timeout_ms=2000)
                if value is None:
                    raise AssertionError(f"native identity query timed out: {selector}")
                entry[field] = value
            pid = api.send_message(window.hwnd, 0x450, 3, 0, timeout_ms=2000)
            if pid:
                entry["pty"] = process_identity(api, pid)
        windows.append(entry)
    instance.ensure_owned()
    return {"process": process, "windows": windows,
            "children": [process_identity(api, pid) for pid, _ in api.child_processes(instance.pid)]}


def write_review(out, case_id, boundary, environment, native_status, captures=(), **facts):
    """Write a new pending review, preserving an existing review on later saves."""
    directory = Path(out) / "reviews"
    directory.mkdir(exist_ok=True)
    path = directory / f"{case_id}.json"
    record = {"schema": 1, "case_id": case_id, "boundary": boundary,
              "environment": environment, "native_status": native_status,
              "status": "FAIL" if native_status == "FAIL" else "PENDING_REVIEW",
              "screenshots": [{"file": str(file), "sha256": sha256(Path(out) / file),
                               "status": "PENDING_REVIEW", "conclusion": None} for file in captures],
              **facts}
    # A reviewer owns the review, and the runner never overwrites their verdict.
    if not path.exists():
        path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return str(path.relative_to(out))


def drag_thresholds(dpi):
    if dpi <= 0:
        raise ValueError("DPI must be positive")
    return {axis: {"dpi": dpi, "threshold_dip": dip, "at_or_below_px": dip * dpi // 96,
                   "above_px": dip * dpi // 96 + 1, "exact_representable": dip * dpi % 96 == 0}
            for axis, dip in (("vertical", 15), ("horizontal", 10))}


@contextmanager
def fixture_slots(root, desktop_held=False):
    """Avoid nested acquisition when root already used Invoke-Desktop.

The explicit flag is a caller assertion, not a new way to acquire the desktop.
Every real run still requires the coordinator's idle and foreground guards.
"""
    if desktop_held:
        yield
        return
    import gx_slots
    with gx_slots.acquire(root / ".local/kernel-slots", "heavy", 45):
        with gx_slots.acquire(root / ".local/kernel-slots", "desktop", 45):
            yield
