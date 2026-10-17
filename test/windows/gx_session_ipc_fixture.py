"""Owned Windows IPC/session scenarios; no registry, clipboard, or global hotkeys.

Run with --out an unused evidence directory and --exe a known application build.
Captures require separate visual review. This does not replace the GUI scenario suite.
"""
from __future__ import annotations

import argparse
import csv
import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import subprocess
import shutil
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_slots  # noqa: E402
import gx_win_gui as gui  # noqa: E402
from gx_fixture_evidence import native_snapshot, sha256, write_review, fixture_slots

CONFIG = "language = en\nconfirm-close-surface = false\n"
CREATE_SUSPENDED = 0x00000004  # Win32 creation flag; not exported by every Python build.
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


class Fixture:
    def __init__(self, exe, out, build, expected_hash=None, peer_exe=None, peer_hash=None):
        self.exe, self.out = exe.resolve(strict=True), out.resolve()
        if expected_hash and sha256(self.exe) != expected_hash.lower():
            raise ValueError("executable differs from the frozen-build SHA-256")
        self.out.mkdir(parents=True, exist_ok=False)
        self.owned = []
        self.processes = {}
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
        }

    def environment(self, name, config):
        path = self.out / name
        gui.prepare_env_dir(path, False)
        gui.write_config(path, config)
        return path

    def start(self, path, args=(), *, resume=True, exe=None, expected_hash=None):
        assert path.is_absolute()
        image = exe.resolve(strict=True) if exe else self.exe
        image_hash = sha256(image)
        assert image_hash == (expected_hash.lower() if expected_hash else self.report["app_sha256"])
        # Query identity before the launcher can exit. Retain our exact process
        # handle for exit codes and crash tests; never infer exit success by PID.
        launched = gui.win32().now_filetime()
        environment = gui.isolated_environment(os.environ, path, {"GHOSTTY_GX_REMOTE_TEST": "1"})
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
        # PrintWindow stays scoped to the owned HWND if Windows denies foreground.
        foreground = gui.win32().activate(window.hwnd)
        if not foreground:
            raise gui.InputBlocked("owned window foreground denied; stopping batch")
        time.sleep(0.2)
        instance.ensure_owned()
        method = "screen"
        instance.capture_window(window, method).save_png(self.out / f"{name}.png")
        self.report["captures"].append({"file": f"{name}.png", "method": method,
                                        "foreground": foreground, "review": "PENDING_REVIEW",
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
        self.seed_document(path, complex_document(path))
        first = self.start(path)
        wait(lambda: len(self.windows(first)) == 2)
        before = self.session(path).read_bytes()
        second = self.start(path)
        second.wait_window(15)
        self.capture(second, "dual-writer-busy-feedback")
        self.close(second)
        assert self.session(path).read_bytes() == before, "second writer changed the first writer's archive"
        self.quit(first)
        assert layout_contract(self.load_document(path)) == layout_contract(complex_document(path))
        self.report["cases"].append({"case_id": "SES-06", "name": "single-private-state-writer", "status": "PASS"})

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

    def cancel_close(self):
        path = self.environment("cancel-close", "language = en\nconfirm-close-surface = always\ngx-session-restore = true\n")
        self.seed_document(path, complex_document(path))
        instance = self.start(path)
        wait(lambda: len(self.windows(instance)) == 2)
        original = self.session(path).read_bytes()
        window = instance.require_window()
        instance.ensure_owned()
        gui.win32().PostMessageW(window.hwnd, gui.WM_CLOSE, 0, 0)
        dialog = wait(lambda: next((w for w in instance.popups() if w.cls in ("GhosttyGxPopup", "#32770")), None))
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
        self.seed_document(path, complex_document(path))
        instance = self.start(path)
        wait(lambda: len(self.windows(instance)) == 2)
        original = self.session(path).read_bytes()
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
            instance.activate()
            instance.press("ctrl+shift+t")
            instance.wait_log("session save failed", 10)
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
                except Exception as error:
                    self.report["cases"].append({"name": name, "status": "FAIL", "reason": str(error),
                                                 "traceback": traceback.format_exc()})
                finally:
                    for instance in self.owned[first:]:
                        if instance.log.is_file():
                            (self.out / f"{name}-{instance.pid}.log").write_bytes(instance.log.read_bytes())
                    for instance in self.owned:
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
