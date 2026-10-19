"""Owned Windows IPC/session scenarios; no registry, clipboard, or global hotkeys.

Run with --out an unused evidence directory and --exe a known application build.
Captures require separate visual review. This does not replace the GUI scenario suite.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import asdict
import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import subprocess
import shutil
import threading
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_slots  # noqa: E402
import gx_win_gui as gui  # noqa: E402
from gx_fixture_evidence import native_snapshot, sha256, write_review, fixture_slots, source_manifest

CONFIG = "language = en\nconfirm-close-surface = false\n"
CREATE_SUSPENDED = 0x00000004  # Win32 creation flag; not exported by every Python build.
WS_EX_NOACTIVATE = 0x08000000  # menu popups: Windows never makes them the foreground window
SESSION_BUSY = "The session is already in use by another instance."
# Popup.zig registers exactly these two classes; Toast requests shadow=true.
GX_POPUP_CLASSES = ("GhosttyGxPopup", "GhosttyGxPopupShadow")
POPUP_OBSERVATION_LIMIT = 32
POPUP_TEXT_LIMIT = 256
CASE_IDS = {"multi": "IPC-01", "disabled": "SES-00", "custom": "SES-03a",
            "roundtrip": "SES-01", "missing_profile": "SES-02", "priority": "SES-03",
            "cancel_close": "SES-04", "write_failure": "SES-05", "dual_writer": "SES-06",
            "privacy": "SES-07", "quick_excluded": "SES-08", "race": "IPC-02",
            "roots": "IPC-05a", "installs": "IPC-05b", "builds": "IPC-05c"}
CASE_IDS.update(crash_before_ready="IPC-03", squatter="IPC-04")


def pipe_names():
    return {name for name in os.listdir("\\\\.\\pipe\\") if name.startswith("ghostty-gx-v1-")}


class PipeApi:
    """Only connect to a pipe discovered from our own new host, never send actions."""
    def __init__(self):
        from ctypes import wintypes as w
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        for name, result, args in (
            ("CreateFileW", w.HANDLE, [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p, w.DWORD, w.DWORD, w.HANDLE]),
            ("CreateNamedPipeW", w.HANDLE, [w.LPCWSTR, w.DWORD, w.DWORD, w.DWORD, w.DWORD, w.DWORD, w.DWORD, ctypes.c_void_p]),
            ("GetNamedPipeServerProcessId", w.BOOL, [w.HANDLE, ctypes.POINTER(w.ULONG)]),
            ("CloseHandle", w.BOOL, [w.HANDLE]),
        ):
            function = getattr(self.api, name)
            function.restype, function.argtypes = result, args

    def close(self, handle):
        self.api.CloseHandle(handle)

    def occupy(self, name):
        handle = self.api.CreateNamedPipeW("\\\\.\\pipe\\" + name, 0x40080003, 14, 1, 4096, 4096, 1000, None)
        if handle in (None, ctypes.c_void_p(-1).value):
            raise AssertionError("endpoint was not free; refusing to replace an existing pipe")
        return handle


def complex_document(cwd):
    def leaf(index):
        return {"leaf": {"profile_id": "cmd", "cwd": {"kind": "windows", "path": str(cwd)},
                         "font_size": 11 + index, "title_override": f"叶 {index} 中文 🧪"}}
    return {"version": 1, "generation": 7, "windows": [
        {"active": 1, "title_override": f"窗口 {index} 中文 🧪", "geometry": {
            "width": 880, "height": 560, "x": 60 + index * 100, "y": 80 + index * 60, "dpi": 96},
         "tabs": [{"active": 4, "zoom": 4, "root": 0, "title_override": f"嵌套 {index} 🧪",
                   "nodes": [{"split": {"axis": "horizontal", "ratio": 0.3125, "first": 1, "second": 2}},
                             leaf(index), {"split": {"axis": "vertical", "ratio": 0.6875, "first": 3, "second": 4}},
                             leaf(index + 1), leaf(index + 2)]},
                  {"active": 0, "root": 0, "nodes": [leaf(index + 3)], "title_override": f"活动 {index} 中文"}]}
        for index in (0, 4)]}


def layout_contract(document):
    """Compare logical trees, allowing serialization to renumber flat nodes."""
    def tab_contract(tab):
        def node(index):
            value = tab["nodes"][index]
            if value.get("leaf") is not None:
                leaf = value["leaf"]
                return {key: leaf.get(key) for key in ("profile_id", "cwd", "font_size", "title_override")}
            split = value["split"]
            return {"axis": split["axis"], "ratio": split["ratio"],
                    "first": node(split["first"]), "second": node(split["second"])}
        return {"tree": node(tab.get("root", 0)), "active": node(tab["active"]),
                "zoom": None if tab.get("zoom") is None else node(tab["zoom"]),
                "title_override": tab.get("title_override")}
    return [{"active": window["active"], "title_override": window.get("title_override"),
             "tabs": [tab_contract(tab) for tab in window["tabs"]]} for window in document["windows"]]


def assert_private_document(document, forbidden_values=()):
    allowed = {"version", "generation", "windows", "skipped_leaves", "tabs", "active", "geometry", "width", "height",
               "x", "y", "dpi", "maximized", "title_override", "nodes", "root", "zoom", "leaf", "split", "axis",
               "ratio", "first", "second", "profile_id", "cwd", "cwd_unavailable", "kind", "path", "font_size"}
    def visit(value):
        if isinstance(value, dict):
            if set(value) - allowed:
                raise AssertionError(f"private session contains unexpected fields: {sorted(set(value) - allowed)}")
            for item in value.values():
                visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)
    visit(document)
    encoded = json.dumps(document, ensure_ascii=False)
    for secret in forbidden_values:
        if secret in encoded:
            raise AssertionError("private session persisted a dynamic title, command, environment or scrollback marker")


def wait(predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("bounded wait failed")


class ProcessControl:
    """Query and suspend/resume only the retained Popen handle; never reopen a PID."""
    def __init__(self):
        from ctypes import wintypes as w
        self.w = w
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.nt = ctypes.WinDLL("ntdll")
        for library, name, result, args in (
            (self.kernel, "GetProcessId", w.DWORD, [w.HANDLE]),
            (self.kernel, "GetProcessTimes", w.BOOL, [w.HANDLE, *([ctypes.POINTER(w.FILETIME)] * 4)]),
            (self.kernel, "QueryFullProcessImageNameW", w.BOOL, [w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)]),
            (self.kernel, "WaitForSingleObject", w.DWORD, [w.HANDLE, w.DWORD]),
            (self.nt, "NtSuspendProcess", ctypes.c_long, [w.HANDLE]),
            (self.nt, "NtResumeProcess", ctypes.c_long, [w.HANDLE]),
        ):
            function = getattr(library, name)
            function.restype, function.argtypes = result, args

    def identity(self, handle):
        created, exited, kernel, user = (self.w.FILETIME() for _ in range(4))
        image, length = ctypes.create_unicode_buffer(32768), self.w.DWORD(32768)
        if (not self.kernel.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited),
                                            ctypes.byref(kernel), ctypes.byref(user)) or
                not self.kernel.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(length))):
            raise AssertionError("cannot query owned process handle")
        return {"pid": self.kernel.GetProcessId(handle), "birth": (created.dwHighDateTime << 32) | created.dwLowDateTime,
                "exe": image.value, "live": self.kernel.WaitForSingleObject(handle, 0) == 0x102}

    def suspend(self, handle):
        return self.nt.NtSuspendProcess(handle)

    def resume(self, handle):
        return self.nt.NtResumeProcess(handle)


def owned_process_handle(process, instance, control):
    """The OS facts must match the launch identity, including the exact handle's PID."""
    handle = int(process._handle)
    actual = control.identity(handle)
    if (process.pid != instance.pid or actual["pid"] != instance.pid or not instance.creation or
            actual["birth"] != instance.creation or not actual["live"] or
            not gui.same_path(actual["exe"], instance.exe)):
        raise AssertionError("owned process handle identity mismatch")
    return handle


class PausedProcess:
    """Keep the Store's kernel lease alive while excluding its owner's writes.

    No window query or PID-based operation is permitted here. Recovery uses the
    original handle: one resume attempt, or termination with confirmed exit.
    Watchdog expiry and forced cleanup can never count as a normal Quit.
    """
    def __init__(self, process, instance, evidence, *, control=None):
        self.process, self.instance, self.evidence = process, instance, evidence
        self.control = control if control is not None else ProcessControl()
        self.lock = threading.Lock()
        self.resume_due = False
        self.cleanup_required = False
        self.failed_restore = False
        self.failure_cleanup = {"status": "NOT_REQUIRED", "normal_quit": False, "exit_code": None, "attempts": []}
        self.timed_out = False
        self.watchdog_error = None
        self.timer = None
        self.evidence.update(timed_out=False, resume_verified=False, events=[], failure_cleanup=self.failure_cleanup)

    def __enter__(self):
        self.handle = owned_process_handle(self.process, self.instance, self.control)
        self.evidence.update(pid=self.instance.pid, birth=self.instance.creation, exe=self.instance.exe,
                             handle=self.handle, identity_verified=True, budget_seconds=45,
                             lease="Suspension retains the process and its Store lock handle; no unlock or close.")
        self.deadline = time.monotonic() + 45
        status = None
        try:
            # Register compensation BEFORE entering ctypes: an interruption can
            # hide a successful native return. Only a known failure cancels it.
            self.cleanup_required = True
            self.resume_due = True
            try:
                status = self.control.suspend(self.handle)
            finally:
                if status is not None and status < 0:
                    self.resume_due = False
                    self.cleanup_required = False
            self.evidence["suspend_status"] = status
            if status < 0:
                raise AssertionError("NtSuspendProcess failed for owned process")
            self.evidence["suspend_outcome"] = "success"
            self.evidence["events"].append({"phase": "suspended", "monotonic_ns": time.monotonic_ns()})
            self.timer = threading.Timer(max(0, self.deadline - time.monotonic()), self._watchdog)
            self.timer.daemon = True
            self.timer.start()
            return self
        except BaseException:
            try:
                self._resume("enter-failed")
            finally:
                if self.timer is not None:
                    self.timer.cancel()
                self.evidence["suspend_outcome"] = "unknown" if status is None else ("failed" if status < 0 else "success")
            raise

    def _resume(self, phase):
        # Serialize the watchdog against normal cleanup: never decrement a
        # suspend count twice. Retaining Popen keeps this handle owned throughout.
        with self.lock:
            if not self.resume_due:
                if self.cleanup_required:
                    self._terminate_locked(phase)
                return
            status, verified = None, False
            # Claim the single attempt before ctypes. If its result is unknown,
            # retrying could consume another suspend count. The independent
            # cleanup obligation survives until resume or exit is confirmed.
            try:
                self.resume_due = False
                status = self.control.resume(self.handle)
                if status < 0:
                    raise AssertionError("NtResumeProcess failed for owned process")
                if owned_process_handle(self.process, self.instance, self.control) != self.handle:
                    raise AssertionError("owned process handle changed after resume")
                verified = True
                self.cleanup_required = False
            finally:
                try:
                    if self.cleanup_required:
                        self._terminate_locked(phase)
                finally:
                    # Evidence cannot prevent cleanup or re-arm resume, even
                    # when a dictionary write itself raises an exception.
                    self.evidence["resume_outcome"] = "unknown" if status is None else ("failed" if status < 0 else "success")
                    self.evidence["resume_status"] = status
                    self.evidence["resume_verified"] = verified
                    self.evidence["events"].append({"phase": phase, "status": status, "monotonic_ns": time.monotonic_ns()})

    def _terminate_locked(self, phase):
        """Fail closed using retained Popen's Windows handle, never Instance.close.

        TerminateProcess is asynchronous. Even when terminate raises (including
        an interrupted return), only wait on that same handle can prove exit.
        This five-second failure cleanup is separate from the 45-second probe.
        """
        self.failed_restore = True
        terminate_error, wait_error, code = None, None, None
        try:
            if int(self.process._handle) != self.handle:
                raise AssertionError("owned Popen handle changed; refusing failure cleanup")
            try:
                self.process.terminate()
            except BaseException as error:
                terminate_error = f"{type(error).__name__}: {error}"
            finally:
                if int(self.process._handle) != self.handle:
                    raise AssertionError("owned Popen handle changed before exit confirmation")
                code = self.process.wait(timeout=5)
                if type(code) is not int:
                    raise AssertionError("owned process wait did not confirm an exit code")
                self.cleanup_required = False
        except BaseException as error:
            wait_error = f"{type(error).__name__}: {error}"
            raise
        finally:
            # Record only after the handle operations so logging cannot leave
            # a suspended first writer behind. Never label this normal Quit.
            attempt = {"phase": phase, "handle": self.handle, "exit_code": code,
                       "monotonic_ns": time.monotonic_ns()}
            if terminate_error:
                attempt["terminate_error"] = terminate_error
            if wait_error:
                attempt["wait_error"] = wait_error
            self.failure_cleanup["attempts"].append(attempt)
            self.failure_cleanup["status"] = "EXIT_UNCONFIRMED" if self.cleanup_required else "EXIT_CONFIRMED"
            self.failure_cleanup["exit_code"] = None if self.cleanup_required else code

    def fail_closed(self):
        """Runner fallback for an unconfirmed exit; never retry resume or use GUI."""
        with self.lock:
            if self.cleanup_required:
                self._terminate_locked("runner-cleanup")

    def _watchdog(self):
        self.timed_out = True
        try:
            self._resume("watchdog-resume")
        except BaseException as error:
            self.watchdog_error = str(error)
        finally:
            try:
                self.evidence["timed_out"] = True
                if self.watchdog_error:
                    self.evidence["watchdog_error"] = self.watchdog_error
            except BaseException as error:
                self.watchdog_error = self.watchdog_error or str(error)

    def remaining(self, limit=15):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            self._watchdog()
        if self.timed_out:
            raise AssertionError("first writer pause budget exceeded (45 seconds); isolation lost")
        if self.failed_restore:
            raise AssertionError("first writer required failure termination; not a normal Quit")
        return min(limit, remaining)

    def __exit__(self, *_):
        try:
            if self.deadline <= time.monotonic():
                self.timed_out = True
        finally:
            try:
                self._resume("finally-resume")
            finally:
                if self.timer is not None:
                    self.timer.cancel()
                    self.timer.join()
        self.evidence["timed_out"] = self.timed_out
        if self.watchdog_error:
            self.evidence["watchdog_error"] = self.watchdog_error
        if self.timed_out:
            raise AssertionError("first writer pause budget exceeded (45 seconds); isolation lost")
        if self.failed_restore:
            raise AssertionError("first writer required failure termination; not a normal Quit")


class Fixture:
    def __init__(self, exe, out, build, expected_hash=None, peer_exe=None, peer_hash=None):
        self.exe, self.out = exe.resolve(strict=True), out.resolve()
        if expected_hash and sha256(self.exe) != expected_hash.lower():
            raise ValueError("executable differs from the frozen-build SHA-256")
        self.out.mkdir(parents=True, exist_ok=False)
        self.owned = []
        self.processes = {}
        self.pause_guards = {}
        self.expected_terminations = set()
        self.peer_exe = peer_exe.resolve(strict=True) if peer_exe else None
        self.peer_hash = peer_hash
        if self.peer_exe and (not peer_hash or sha256(self.peer_exe) != peer_hash.lower()):
            raise ValueError("peer executable differs from frozen-build SHA-256")
        self.report = {
            "exe": str(self.exe), "app_sha256": hashlib.sha256(self.exe.read_bytes()).hexdigest(),
            "app_mtime_ns": self.exe.stat().st_mtime_ns, "build_label": build,
            "tree_boundary": "Build label is caller supplied; the current source tree is not a build receipt.",
            "cases": [], "processes": [], "captures": [], "visual_review": "PENDING",
            "fixture_sources": source_manifest(),
        }
        for module in (gui, gx_slots):
            source = Path(module.__file__)
            self.report["fixture_sources"][str(source.relative_to(ROOT)).replace("\\", "/")] = sha256(source)

    def environment(self, name, config):
        path = self.out / name
        gui.prepare_env_dir(path, False)
        gui.write_config(path, config)
        return path

    def start(self, path, args=(), *, resume=True, exe=None, expected_hash=None, env=None):
        assert path.is_absolute()
        image = exe.resolve(strict=True) if exe else self.exe
        image_hash = sha256(image)
        assert image_hash == (expected_hash.lower() if expected_hash else self.report["app_sha256"])
        # Query identity before the launcher can exit. Retain our exact process
        # handle for exit codes and crash tests; never infer exit success by PID.
        launched = gui.win32().now_filetime()
        environment = gui.isolated_environment(os.environ, path, {"GHOSTTY_GX_REMOTE_TEST": "1", **(env or {})})
        process = subprocess.Popen([str(image), *args], cwd=path, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   creationflags=CREATE_SUSPENDED)
        birth = gui.win32().process_creation(process.pid)
        if not birth:
            process.terminate()
            process.wait(timeout=5)
            raise AssertionError("cannot identify owned suspended launcher")
        instance = gui.Instance(process.pid, str(image), path, birth, launched)
        self.processes[instance.pid] = process
        self.owned.append(instance)
        instance.ensure_owned()
        self.report["processes"].append({
            "pid": instance.pid, "birth": instance.creation, "exe": instance.exe,
            "environment": str(path), "argv": list(args), "sha256": image_hash,
        })
        if resume:
            self.resume(instance)
        return instance

    def resume(self, instance):
        instance.ensure_owned()
        function = ctypes.WinDLL("ntdll").NtResumeProcess
        function.argtypes, function.restype = [ctypes.c_void_p], ctypes.c_long
        if function(int(self.processes[instance.pid]._handle)) < 0:
            raise AssertionError("NtResumeProcess failed for owned launcher")

    @staticmethod
    def windows(instance):
        return [item for item in instance.windows() if item.cls == gui.WINDOW_CLASS
                and item.visible and not item.cloaked and not item.toolwindow]

    def capture(self, instance, name, window=None):
        instance.ensure_owned()
        window = window or instance.require_window()
        # A menu popup never becomes the foreground window: the owned window
        # that owns it (GA_ROOTOWNER) must hold the foreground instead.
        foreground_hwnd = window.hwnd
        if gui.win32().GetWindowLongPtrW(window.hwnd, -20) & WS_EX_NOACTIVATE:
            foreground_hwnd = gui.win32().GetAncestor(window.hwnd, 3)
            if not foreground_hwnd or foreground_hwnd == window.hwnd or gui.win32().window_pid(foreground_hwnd) != instance.pid:
                raise gui.InputBlocked("non-activating popup has no owned owner window; stopping batch")
        # PrintWindow stays scoped to the owned HWND if Windows denies foreground.
        foreground = gui.win32().activate(foreground_hwnd)
        if not foreground:
            raise gui.InputBlocked("owned window foreground denied; stopping batch")
        time.sleep(0.2)
        instance.ensure_owned()
        window = gui.win32().info(window.hwnd)
        if gui.win32().window_pid(window.hwnd) != instance.pid:
            raise gui.InputBlocked("capture HWND owner changed")
        if not window.visible:
            raise AssertionError(f"window {window.hwnd:#x} closed before its capture")
        occluders = set()
        left, top, right, bottom = window.rect
        for fx, fy in ((0.5, 0.1), (0.5, 0.5), (0.5, 0.9)):
            hit = gui.win32().window_at(round(left + (right - left) * fx), round(top + (bottom - top) * fy))
            root = gui.win32().GetAncestor(hit, 2) if hit else 0
            if root and root != window.hwnd:
                occluders.add(root)
        method = "screen"
        instance.capture_window(window, method).save_png(self.out / f"{name}.png")
        self.report["captures"].append({"file": f"{name}.png", "method": method,
                                        "foreground": foreground, "foreground_hwnd": foreground_hwnd, "review": "PENDING_REVIEW",
                                        "window": asdict(window), "occluder_hwnds": sorted(occluders),
                                        "identity": native_snapshot(instance)})

    def close(self, instance):
        for window in self.windows(instance):
            instance.ensure_owned()
            gui.win32().PostMessageW(window.hwnd, gui.WM_CLOSE, 0, 0)
        wait(lambda: not instance.alive())
        assert self.processes[instance.pid].wait(timeout=5) == 0, "owned app crashed during close"

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

    def seed_document(self, path, document):
        target = self.session(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
        return target.read_bytes()

    def load_document(self, path):
        return json.loads(self.session(path).read_text(encoding="utf-8"))

    def roundtrip(self):
        path = self.environment("roundtrip", CONFIG + "gx-session-restore = true\n")
        original = complex_document(path)
        self.seed_document(path, original)
        expected = layout_contract(original)
        previous = None
        for number in (1, 2):
            instance = self.start(path)
            wait(lambda: len(self.windows(instance)) == 2)
            instance.remember_children()
            identity = native_snapshot(instance)
            if previous is not None:
                assert (instance.pid, instance.creation) != previous, "restart reused native identity"
            previous = instance.pid, instance.creation
            for index, window in enumerate(self.windows(instance)):
                self.capture(instance, f"roundtrip-{number}-window-{index}", window)
            shells = [child for child in identity["children"] if Path(child["exe"]).name.lower() == "cmd.exe"]
            assert len(shells) == 8, "restored leaves did not start exactly eight fresh shells"
            self.quit(instance)
            assert self.processes[instance.pid].wait(timeout=10) == 0
            saved = self.load_document(path)
            assert layout_contract(saved) == expected, "layout/title/font/cwd/zoom/active leaf changed on restart"
            assert_private_document(saved)
            (self.out / f"roundtrip-{number}.json").write_bytes(self.session(path).read_bytes())
            self.report["cases"].append({"case_id": "SES-01", "name": f"roundtrip-{number}", "status": "PASS", "identity": identity})

    def missing_profile(self):
        path = self.environment("missing-profile", CONFIG + "gx-session-restore = true\n")
        original = self.seed(path)  # No custom:Fixture exists in current config.
        instance = self.start(path)
        instance.wait_window(15)
        self.capture(instance, "missing-profile-feedback")
        self.quit(instance)
        assert self.session(path).read_bytes() == original, "failed restore overwrote saved session"
        self.report["cases"].append({"case_id": "SES-02", "name": "missing-profile-preserves-archive", "status": "PASS",
                                     "feedback": "PENDING_REVIEW"})

    def priority(self):
        for label, args in (("command", ("--command=cmd.exe /d /k title GX_CLI_COMMAND",)),
                            ("execute", ("-e", "cmd.exe", "/d", "/k", "title GX_CLI_EXECUTE")),
                            ("initial", ("--initial-command=cmd.exe /d /k title GX_CLI_INITIAL",))):
            path = self.environment("priority-" + label, CONFIG + "gx-session-restore = true\n")
            original = self.seed_document(path, complex_document(path))
            instance = self.start(path, args)
            instance.wait_window(15)
            wait(lambda: "GX_CLI_" in instance.require_window().title)
            assert len(self.windows(instance)) == 1
            self.capture(instance, "priority-" + label)
            self.quit(instance)
            assert self.session(path).read_bytes() == original
        path = self.environment("no-replay", CONFIG + "gx-session-restore = true\ninitial-command = cmd.exe /d /k echo REPLAY>replayed.txt\n")
        self.seed_document(path, complex_document(path))
        instance = self.start(path)
        wait(lambda: len(self.windows(instance)) == 2)
        self.capture(instance, "initial-command-not-replayed")
        self.quit(instance)
        assert not (path / "replayed.txt").exists(), "restore replayed initial-command"
        self.report["cases"].append({"case_id": "SES-03", "name": "CLI-priority-and-no-replay", "status": "PASS"})

    def dual_writer(self):
        path = self.environment("dual-writer", CONFIG + "gx-session-restore = true\ngx-single-instance = false\n")
        evidence = {"phase": "seed", "events": [], "archives": [], "logs": [], "pause": {}}
        self.report["dual_writer"] = evidence
        expected = complex_document(path)
        expected_layout = layout_contract(expected)

        def phase(name):
            evidence["phase"] = name
            evidence["events"].append({"phase": name, "monotonic_ns": time.monotonic_ns()})

        def archive(label, raw=None):
            entry = {"phase": label, "source": str(self.session(path)), "monotonic_ns": time.monotonic_ns(),
                     "file": f"dual-writer-{label}.raw", "pause_timed_out": evidence["pause"].get("timed_out")}
            evidence["archives"].append(entry)
            try:
                raw = self.session(path).read_bytes() if raw is None else raw
                (self.out / entry["file"]).write_bytes(raw)
                entry.update(sha256=hashlib.sha256(raw).hexdigest(), size=len(raw))
            except BaseException as error:
                entry["error"] = str(error)
                raise
            # Preserve bytes before parsing; read failures stay explicit above.
            # Parsed metadata never substitutes for byte equality.
            try:
                entry["generation"] = json.loads(raw)["generation"]
            except (ValueError, KeyError, TypeError) as error:
                entry["parse_error"] = str(error)
            return raw

        def shared_logs(label):
            for suffix in ("", ".1"):
                source = gui.log_path(path).with_name("ghostty.log" + suffix)
                entry = {"phase": label, "source": str(source), "attribution": "shared path; not a per-PID log"}
                evidence["logs"].append(entry)
                if not source.is_file():
                    entry["missing"] = True
                    continue
                try:
                    raw = source.read_bytes()
                    name = f"dual-writer-{label}-shared-ghostty.log{suffix}"
                    (self.out / name).write_bytes(raw)
                    entry.update(file=name, sha256=hashlib.sha256(raw).hexdigest(), size=len(raw))
                except BaseException as error:
                    entry["error"] = str(error)
                    raise

        try:
            archive("seed", self.seed_document(path, expected))
            first = self.start(path)
            phase("first-ready")
            wait(lambda: len(self.windows(first)) == 2)
            evidence["first"] = native_snapshot(first)
            previous = None

            def ready():
                nonlocal previous
                first.ensure_owned()
                raw = self.session(path).read_bytes()
                document = json.loads(raw)
                if document["generation"] <= expected["generation"]:
                    return None
                if layout_contract(document) != expected_layout:
                    archive("ready-invalid", raw)
                    raise AssertionError("first writer saved an unexpected logical layout")
                stable, previous = raw == previous, raw
                return raw if stable else None

            ready_raw = archive("ready", wait(ready, 15))
            phase("pause-first")
            paused = PausedProcess(self.processes[first.pid], first, evidence["pause"])
            self.pause_guards[first.pid] = paused
            with paused:
                second = None
                try:
                    phase("before")
                    before = archive("before")
                    baseline = json.loads(before)
                    assert baseline["generation"] >= json.loads(ready_raw)["generation"]
                    assert layout_contract(baseline) == expected_layout, "first layout changed before suspension"
                    shared_logs("before")
                    paused.remaining()
                    phase("second-start")
                    second = self.start(path)
                    evidence["second"] = {"pid": second.pid, "birth": second.creation, "exe": second.exe}
                    second.wait_window(paused.remaining())
                    phase("second-busy")
                    evidence["busy"] = {"status": "NOT_OBSERVED", "expected_text": SESSION_BUSY,
                                        "source_pid": second.pid, "source_birth": second.creation, "polls": 0,
                                        "observations": [], "observations_limit": POPUP_OBSERVATION_LIMIT,
                                        "text_limit": POPUP_TEXT_LIMIT, "text_truncated_count": 0, "observations_dropped": 0}

                    def busy_popup():
                        paused.remaining()
                        second.ensure_owned()
                        busy = evidence["busy"]
                        busy["polls"] += 1
                        api = gui.win32()
                        # Observe only second's HWNDs, including hidden/cloaked
                        # ones for timeout diagnostics. Never query paused first.
                        for popup in second.windows():
                            pid = api.window_pid(popup.hwnd)
                            observation = {"class": popup.cls[:POPUP_TEXT_LIMIT], "title": popup.title[:POPUP_TEXT_LIMIT],
                                           "hwnd": popup.hwnd, "pid": pid, "visible": popup.visible, "cloaked": popup.cloaked,
                                           "text_truncated": len(popup.cls) > POPUP_TEXT_LIMIT or len(popup.title) > POPUP_TEXT_LIMIT}
                            # Count window samples with any truncated text,
                            # including repeats and records later evicted.
                            busy["text_truncated_count"] += int(observation["text_truncated"])
                            if observation not in busy["observations"]:
                                if len(busy["observations"]) == POPUP_OBSERVATION_LIMIT:
                                    busy["observations"].pop(0)
                                    busy["observations_dropped"] += 1
                                busy["observations"].append(observation)
                            # Truncated diagnostic strings never authorize a
                            # match: require the exact native class and text.
                            if (popup.cls not in GX_POPUP_CLASSES or popup.title != SESSION_BUSY
                                    or not popup.visible or popup.cloaked
                                    or popup.rect[2] <= popup.rect[0] or popup.rect[3] <= popup.rect[1]):
                                continue
                            owner = api.GetAncestor(popup.hwnd, 3)
                            owner_pid = api.window_pid(owner) if owner else 0
                            observation.update(owner_hwnd=owner, owner_pid=owner_pid)
                            if not owner or owner == popup.hwnd or pid != second.pid or owner_pid != second.pid:
                                raise gui.InputBlocked("Busy popup has no owned second-writer window")
                            second.ensure_owned()
                            return popup
                        return None

                    popup = wait(busy_popup, paused.remaining())
                    phase("second-busy-capture")
                    count = len(self.report["captures"])
                    self.capture(second, "dual-writer-busy-feedback", popup)
                    assert len(self.report["captures"]) == count + 1
                    captured = self.report["captures"][-1]
                    assert captured["window"]["hwnd"] == popup.hwnd and captured["window"]["title"] == SESSION_BUSY, "Busy popup changed before capture"
                    assert captured["window"]["cls"] == popup.cls, "Busy popup class changed before capture"
                    assert captured["identity"]["process"]["pid"] == second.pid and captured["identity"]["process"]["birth"] == second.creation
                    evidence["busy"].update(status="OBSERVED_NATIVE", text=SESSION_BUSY, hwnd=popup.hwnd,
                                            **{"class": popup.cls}, pid=second.pid, birth=second.creation,
                                            capture=captured["file"], visual_review="PENDING_REVIEW")
                    paused.remaining()
                except BaseException:
                    evidence["failed_phase"] = evidence["phase"]
                    raise
                finally:
                    try:
                        if second is not None:
                            phase("second-close")
                            try:
                                if self.processes[second.pid].poll() is None:
                                    self.close(second)
                            finally:
                                evidence["second_exit"] = self.processes[second.pid].poll()
                            assert evidence["second_exit"] == 0, "second writer did not exit normally"
                    except BaseException:
                        evidence.setdefault("failed_phase", evidence["phase"])
                        raise
                    finally:
                        phase("after-before-resume")
                        after = archive("after")
                        shared_logs("after")
                paused.remaining()
                phase("compare-paused")
                evidence["bytes_equal_while_paused"] = after == before
                assert evidence["bytes_equal_while_paused"], "archive changed while first writer was suspended"
                phase("first-resume")
            phase("first-quit")
            self.quit(first)
            evidence["first_exit"] = self.processes[first.pid].wait(timeout=5)
            assert evidence["first_exit"] == 0, "first writer did not exit normally"
            final = json.loads(archive("first-quit"))
            assert final["generation"] > baseline["generation"], "first writer did not save after resume"
            assert final["windows"] and layout_contract(final) == expected_layout, "first writer archive is no longer usable"
            phase("complete")
        except BaseException as error:
            evidence.setdefault("failed_phase", evidence["phase"])
            evidence["error"] = str(error)
            archive("failure")
            raise
        finally:
            shared_logs("final")
        self.report["cases"].append({"case_id": "SES-06", "name": "single-private-state-writer", "status": "PASS",
                                     "evidence": evidence})

    def privacy(self):
        marker = "GX_PRIVATE_53B18"
        path = self.environment("privacy", CONFIG + "gx-session-restore = true\n")
        self.seed_document(path, complex_document(path))
        instance = self.start(path)
        wait(lambda: len(self.windows(instance)) == 2)
        instance.activate()
        instance.type_text(f"set {marker}_ENV={marker}_SECRET&title {marker}_DYNAMIC&echo {marker}_SCROLLBACK")
        instance.press("enter")
        self.capture(instance, "privacy-before-quit")
        self.quit(instance)
        saved = self.load_document(path)
        assert_private_document(saved, (marker,))
        self.report["cases"].append({"case_id": "SES-07", "name": "archive-schema-and-private-markers", "status": "PASS"})

    def restored_baseline(self, instance, path, expected, case):
        """Observe the owned startup save, not just restored HWNDs, within 15s.

        Same generation/layout/two-identical-byte criteria as SES-06 readiness.
        This combines the old window wait and save readiness in ONE budget;
        elapsed time and screenshots are never evidence of readiness.
        """
        deadline = time.monotonic() + 15
        expected_layout = layout_contract(expected)
        evidence = {"pid": instance.pid, "birth": instance.creation, "exe": instance.exe,
                    "seed_generation": expected["generation"], "budget_seconds": 15,
                    "polls": 0, "status": "WAITING"}
        self.report.setdefault("startup_readiness", {})[case] = evidence
        previous = None

        def remaining():
            seconds = deadline - time.monotonic()
            if seconds <= 0:
                raise AssertionError("startup readiness deadline exceeded")
            return seconds

        def sample():
            nonlocal previous
            instance.ensure_owned()
            evidence["polls"] += 1
            if len(self.windows(instance)) != len(expected["windows"]):
                previous = None
                return None
            raw = self.session(path).read_bytes()
            document = json.loads(raw)
            evidence["last_generation"] = document["generation"]
            if document["generation"] <= expected["generation"]:
                previous = None
                return None
            if layout_contract(document) != expected_layout:
                evidence["invalid_sha256"] = hashlib.sha256(raw).hexdigest()
                raise AssertionError("startup saved an unexpected logical layout")
            stable, previous = raw == previous, raw
            return raw if stable else None

        def ready():
            remaining()
            value = sample()
            remaining()  # A poll begun in budget may still finish too late.
            return value

        try:
            raw = wait(ready, remaining())
            remaining()
            instance.ensure_owned()
            result = {"generation": json.loads(raw)["generation"],
                      "sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw), "stable_samples": 2}
            remaining()  # Include final ownership query and baseline bookkeeping.
        except BaseException as error:
            evidence.update(status="FAIL", error=str(error))
            raise
        evidence.update(status="READY", **result)
        return raw

    def cancel_close(self):
        path = self.environment("cancel-close", "language = en\nconfirm-close-surface = always\ngx-session-restore = true\n")
        expected = complex_document(path)
        self.seed_document(path, expected)
        instance = self.start(path)
        original = self.restored_baseline(instance, path, expected, "cancel_close")
        window = instance.require_window()
        instance.ensure_owned()
        gui.win32().PostMessageW(window.hwnd, gui.WM_CLOSE, 0, 0)
        dialog = wait(lambda: next((w for w in instance.popups() if w.cls in (*GX_POPUP_CLASSES, "#32770")), None))
        self.capture(instance, "cancel-close-confirm", dialog)
        instance.press("escape")
        wait(lambda: not any(w.hwnd == dialog.hwnd for w in instance.popups()))
        assert len(self.windows(instance)) == 2 and self.session(path).read_bytes() == original
        self.capture(instance, "cancel-close-preserved")
        # End the controlled shells explicitly; no forced process termination is
        # used as evidence for the cancelled close behavior.
        gui.write_config(path, CONFIG + "gx-session-restore = true\n")
        instance.press("ctrl+shift+comma")
        time.sleep(0.3)
        self.quit(instance)
        self.report["cases"].append({"case_id": "SES-04", "name": "cancel-close-preserves-archive", "status": "PASS"})

    def write_failure(self):
        path = self.environment("write-failure", CONFIG + "gx-session-restore = true\n")
        expected = complex_document(path)
        self.seed_document(path, expected)
        instance = self.start(path)
        original = self.restored_baseline(instance, path, expected, "write_failure")
        directory = self.session(path).parent.resolve()
        assert directory.is_relative_to(path.resolve())
        acl = self.out / "write-failure-original.acl"
        sid_rows = list(csv.reader(subprocess.check_output(["whoami", "/user", "/fo", "csv", "/nh"], text=True).splitlines()))
        sid = sid_rows[0][1]
        assert sid.startswith("S-1-")
        def icacls(*args):
            result = subprocess.run(["icacls", *map(str, args)], cwd=directory.parent, capture_output=True, text=True)
            self.report.setdefault("acl_commands", []).append({"argv": list(map(str, args)), "exit_code": result.returncode,
                                                               "stdout": result.stdout, "stderr": result.stderr})
            if result.returncode:
                raise AssertionError("private state ACL operation failed")
        icacls(directory.name, "/save", acl, "/t")
        try:
            icacls(directory.name, "/deny", f"*{sid}:(OI)(CI)(WD,AD,DC,D)")
            try:
                with (directory / "denied-write-probe").open("x"):
                    pass
            except PermissionError:
                pass
            else:
                raise AssertionError("private state directory is still writable; failure injection invalid")
            instance.ensure_owned()
            # Exclude errors from startup, ACL setup and earlier attempts. An
            # error must be newly appended after this injection/action boundary.
            before_log = instance.log.read_bytes() if instance.log.is_file() else b""
            observation = {"pid": instance.pid, "birth": instance.creation,
                           "start_byte": len(before_log), "status": "WAITING"}
            self.report["write_failure_log"] = observation
            instance.activate()
            instance.press("ctrl+shift+t")

            def new_failure():
                instance.ensure_owned()
                current = instance.log.read_bytes() if instance.log.is_file() else b""
                if not current.startswith(before_log):
                    raise AssertionError("owned log was truncated or replaced after injection")
                suffix = current[len(before_log):]
                if b"session save failed" not in suffix:
                    return False
                observation.update(status="OBSERVED", end_byte=len(current),
                                   suffix_sha256=hashlib.sha256(suffix).hexdigest())
                return True

            try:
                wait(new_failure, 10)
            except BaseException as error:
                observation.update(status="FAIL", error=str(error))
                raise
            self.capture(instance, "write-failure-feedback")
            assert self.session(path).read_bytes() == original
            self.quit(instance)
            assert self.session(path).read_bytes() == original
        finally:
            icacls(".", "/restore", acl)
        self.report["cases"].append({"case_id": "SES-05", "name": "readonly-state-preserves-old-archive", "status": "PASS",
                                     "injection": "private directory DACL denies writes/deletes; original ACL restored"})

    def quick_excluded(self):
        path = self.environment("quick-excluded", CONFIG + "gx-session-restore = true\nkeybind = ctrl+alt+q=toggle_quick_terminal\n")
        expected = complex_document(path)
        self.seed_document(path, expected)
        instance = self.start(path)
        wait(lambda: len(self.windows(instance)) == 2)
        instance.activate()
        instance.press("ctrl+alt+q")
        quick = wait(lambda: next((w for w in instance.windows() if w.cls == gui.WINDOW_CLASS and w.toolwindow and w.visible), None))
        self.capture(instance, "quick-excluded-visible", quick)
        instance.press("ctrl+alt+q")
        self.quit(instance)
        assert layout_contract(self.load_document(path)) == layout_contract(expected)
        self.report["cases"].append({"case_id": "SES-08", "name": "quick-terminal-excluded", "status": "PASS", "quick_hwnd": quick.hwnd})

    def race(self):
        path = self.environment("race", CONFIG + "command = cmd.exe /d /k prompt $G$S\n")
        launchers = [self.start(path, resume=False) for _ in range(6)]
        for instance in launchers:
            self.resume(instance)
        wait(lambda: sum(item.alive() for item in launchers) == 1, 30)
        host = next(item for item in launchers if item.alive())
        wait(lambda: len(self.windows(host)) == 6, 30)
        exits = {str(item.pid): self.processes[item.pid].wait(timeout=5) for item in launchers if item is not host}
        assert all(code == 0 for code in exits.values()), exits
        self.capture(host, "race-one-host-six-windows")
        self.report["cases"].append({"case_id": "IPC-02", "name": "six-launcher-election", "status": "PASS",
                                     "host": native_snapshot(host), "launcher_exit_codes": exits,
                                     "hotkey_registration": "PENDING_NATIVE_COUNTER"})
        self.close(host)

    def roots(self):
        config = CONFIG + "command = cmd.exe /d /k prompt $G$S\n"
        first = self.start(self.environment("root-a", config))
        second = self.start(self.environment("root-b", config))
        for instance in (first, second):
            instance.wait_window(15)
            self.capture(instance, "isolated-root-" + str(instance.pid))
        assert first.pid != second.pid and first.alive() and second.alive()
        self.report["cases"].append({"case_id": "IPC-05a", "name": "different-config-roots", "status": "PASS",
                                     "scope": "config root only; build/install/token/session/account need separate runs"})

    def installs(self):
        path = self.environment("install-profile", CONFIG + "command = cmd.exe /d /k prompt $G$S\n")
        destination = self.out / "second-install" / "bin"
        destination.mkdir(parents=True)
        clone = destination / self.exe.name
        shutil.copy2(self.exe, clone)
        for library in self.exe.parent.glob("*.dll"):
            shutil.copy2(library, destination / library.name)
        resources = self.exe.parent.parent / "share"
        if resources.exists():
            shutil.copytree(resources, destination.parent / "share")
        first = self.start(path)
        first.wait_window(15)
        second = self.start(path, exe=clone, expected_hash=self.report["app_sha256"])
        second.wait_window(15)
        assert first.alive() and second.alive() and first.pid != second.pid
        self.capture(first, "install-original")
        self.capture(second, "install-copy")
        self.report["cases"].append({"case_id": "IPC-05b", "name": "same-build-different-install-path", "status": "PASS",
                                     "original": str(self.exe), "copy": str(clone), "shared_config": str(path)})

    def builds(self):
        if not self.peer_exe or self.peer_hash.lower() == self.report["app_sha256"]:
            self.report["cases"].append({"case_id": "IPC-05c", "name": "different-builds", "status": "PENDING",
                                         "reason": "root must supply --peer-exe/--peer-sha256 for a distinct frozen build"})
            return
        path = self.environment("build-profile", CONFIG + "command = cmd.exe /d /k prompt $G$S\n")
        first = self.start(path)
        first.wait_window(15)
        second = self.start(path, exe=self.peer_exe, expected_hash=self.peer_hash)
        second.wait_window(15)
        assert first.alive() and second.alive() and first.pid != second.pid
        self.capture(first, "build-primary")
        self.capture(second, "build-peer")
        self.report["cases"].append({"case_id": "IPC-05c", "name": "different-builds", "status": "PASS",
                                     "scope": "different build and install path together; does not isolate the build dimension alone"})

    def squatter(self):
        path = self.environment("squatter", CONFIG + "command = cmd.exe /d /k prompt $G$S\n")
        before = pipe_names()
        discovery = self.start(path)
        discovery.wait_window(15)
        new = pipe_names() - before
        assert len(new) == 1, "cannot unambiguously identify own IPC endpoint"
        name = new.pop()
        api = PipeApi()
        # A genuine connection verifies the OS server PID before using the name.
        handle = api.api.CreateFileW("\\\\.\\pipe\\" + name, 0xc0000000, 0, None, 3, 0x40110000, None)
        if handle in (None, ctypes.c_void_p(-1).value):
            raise AssertionError("cannot inspect owned endpoint")
        try:
            pid = ctypes.c_ulong()
            assert api.api.GetNamedPipeServerProcessId(handle, ctypes.byref(pid)) and pid.value == discovery.pid
        finally:
            api.close(handle)
        self.capture(discovery, "squatter-discovery-owned-host")
        self.close(discovery)
        assert self.processes[discovery.pid].wait(timeout=10) == 0
        wait(lambda: name not in pipe_names())
        fake = api.occupy(name)
        try:
            # The fake server never sends an ACK or a claimed trusted identity.
            # The client's bounded ready/authentication failure must not create
            # a fallback Surface or return a successful launcher exit status.
            launcher = self.start(path)
            observed_windows, observed_children = [], []
            deadline = time.monotonic() + 20
            while launcher.alive() and time.monotonic() < deadline:
                observed_windows.extend(w.hwnd for w in self.windows(launcher))
                observed_children.extend(gui.win32().child_processes(launcher.pid))
                time.sleep(0.02)
            code = self.processes[launcher.pid].wait(timeout=2)
            assert code != 0 and not observed_windows and not observed_children
            self.report["cases"].append({"case_id": "IPC-04", "name": "preoccupied-endpoint-fails-closed", "status": "PASS",
                                         "endpoint": name, "fake_server_pid": os.getpid(), "exit_code": code,
                                         "scope": "nonresponsive squatter; forged valid hello needs native replay fixture"})
        finally:
            api.close(fake)

    def crash_before_ready(self):
        path = self.environment("ready-crash", CONFIG + "command = cmd.exe /d /k prompt $G$S\n")
        before = pipe_names()
        host = self.start(path, resume=False)
        self.resume(host)
        wait(lambda: pipe_names() - before, 15)
        suspend = ctypes.WinDLL("ntdll").NtSuspendProcess
        suspend.argtypes, suspend.restype = [ctypes.c_void_p], ctypes.c_long
        assert suspend(int(self.processes[host.pid]._handle)) >= 0
        try:
            if self.windows(host) or gui.win32().child_processes(host.pid):
                self.report["cases"].append({"case_id": "IPC-03", "name": "crash-before-ready", "status": "PENDING",
                                             "reason": "host reached GUI/PTY before suspension; no pre-ready claim"})
                return
            launcher = self.start(path)
            time.sleep(0.3)
            assert not self.windows(launcher) and not gui.win32().child_processes(launcher.pid)
            self.processes[host.pid].terminate()
            self.expected_terminations.add(host.pid)
            host_code = self.processes[host.pid].wait(timeout=5)
            code = self.processes[launcher.pid].wait(timeout=20)
            assert code != 0, "secondary claimed successful GUI ACK after host exited before ready"
            self.report["cases"].append({"case_id": "IPC-03", "name": "crash-before-ready", "status": "PASS",
                                         "host_exit": host_code, "launcher_exit": code,
                                         "host_pid": host.pid, "host_birth": host.creation})
        finally:
            if host.alive():
                self.resume(host)

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

    def run(self, cases, desktop_held=False):
        with fixture_slots(ROOT, desktop_held):
            for name in cases:
                first = len(self.owned)
                first_capture = len(self.report["captures"])
                first_result = len(self.report["cases"])
                try:
                    getattr(self, name)()
                except BaseException as error:
                    if not isinstance(error, Exception) and name != "dual_writer":
                        raise
                    self.report["cases"].append({"name": name, "status": "FAIL", "reason": str(error),
                                                 "traceback": traceback.format_exc(),
                                                 **({"evidence": self.report["dual_writer"]} if name == "dual_writer" and "dual_writer" in self.report else {})})
                    if not isinstance(error, Exception):
                        raise
                finally:
                    for instance in self.owned[first:]:
                        if name != "dual_writer" and instance.log.is_file():
                            (self.out / f"{name}-{instance.pid}.log").write_bytes(instance.log.read_bytes())
                    for instance in self.owned:
                        guard = self.pause_guards.get(instance.pid)
                        if guard is not None and (guard.failed_restore or guard.cleanup_required):
                            cleanup = {"name": name + "/cleanup", "status": "FAIL", "pid": instance.pid,
                                       "reason": "first writer required handle-only failure cleanup; never normal Quit",
                                       "evidence": guard.failure_cleanup}
                            self.report["cases"].append(cleanup)
                            try:
                                guard.fail_closed()
                            except BaseException as error:
                                cleanup["error"] = f"{type(error).__name__}: {error}"
                            continue  # In particular, no alive/close call on a possibly suspended GUI.
                        if instance.alive():
                            outcome = instance.close(1)
                            if outcome == "terminated":
                                self.report["cases"].append({"name": name + "/cleanup", "status": "FAIL", "reason": "owned app required termination"})
                    for instance in self.owned[first:]:
                        code = self.processes[instance.pid].poll()
                        # A deliberately denied launcher is checked inside
                        # its case. All live GUI owners must close cleanly.
                        if name not in ("squatter", "crash_before_ready") and code != 0:
                            self.report["cases"].append({"name": name + "/exit", "status": "FAIL", "pid": instance.pid, "exit_code": code})
                    rows = self.report["cases"][first_result:]
                    write_review(self.out, CASE_IDS[name], "R5-06" if CASE_IDS[name].startswith("IPC-") else "R5-02",
                                 "host", "FAIL" if any(row["status"] == "FAIL" for row in rows) else
                                 ("PASS" if rows and all(row["status"] == "PASS" for row in rows) else "PENDING"),
                                 [row["file"] for row in self.report["captures"][first_capture:]], observations=rows)
                    (self.out / "report.json").write_text(json.dumps(self.report, indent=2), encoding="utf-8")
                if any(row["status"] == "FAIL" for row in self.report["cases"][first_result:]):
                    break  # Keep the first failure; never continue after an input/identity guard failure.
        print(json.dumps(self.report, indent=2))
        if any(case["status"] == "FAIL" for case in self.report["cases"]):
            return 1
        return 2 if any(case["status"] == "PENDING" for case in self.report["cases"]) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desktop-held", action="store_true", help="caller already holds Invoke-Desktop")
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--sha256", help="frozen build hash; omit only for explicitly labelled diagnostics")
    parser.add_argument("--peer-exe", type=Path)
    parser.add_argument("--peer-sha256")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--build-label", required=True)
    parser.add_argument("--case", action="append", choices=("multi", "disabled", "custom", "roundtrip", "missing_profile",
                                                            "priority", "cancel_close", "write_failure", "dual_writer", "privacy",
                                                            "quick_excluded", "race", "roots", "installs", "builds", "squatter", "crash_before_ready"))
    args = parser.parse_args()
    if bool(args.peer_exe) != bool(args.peer_sha256):
        parser.error("peer-exe and peer-sha256 must be supplied together")
    if os.name != "nt":
        parser.error("Windows interactive desktop required")
    return Fixture(args.exe, args.out, args.build_label, args.sha256, args.peer_exe, args.peer_sha256).run(args.case or ("multi", "disabled", "custom"), args.desktop_held)


if __name__ == "__main__":
    raise SystemExit(main())
