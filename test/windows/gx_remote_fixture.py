"""Two real app processes: native remote transfer, input, bindings and lifetime.

Requires a frozen executable with the explicitly enabled remote-test hooks
(GHOSTTY_GX_REMOTE_TEST=1). Uses guarded foreground keyboard and mouse input in
isolated owned windows and never injects wire protocol packets. The begin hook
calls the same RemoteCoordinator.returnRemoteTab/begin pair as a tab drag
(TabTransfer.zig), so drag-back and mixed-tab rejection use production code.

Cases, each recorded separately: transfer into an existing target window,
remote text input to the original shell, external MTA UIA of the remote pane,
performable fallback without a selection, activate_key_table_once, drag-back
to the source host and re-transfer, a chained new_split continuation that
makes the tab mixed, mixed transfer rejection, then source loss (default) or
target loss. Screenshots stay PENDING until a person reads them.
"""
from __future__ import annotations

import argparse
import ctypes
import datetime
from ctypes import wintypes
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_slots  # noqa: E402
import gx_win_gui as gui  # noqa: E402
from gx_fixture_evidence import native_snapshot, write_review, drag_thresholds, fixture_slots

BEGIN = 0x44F
QUERY = 0x450
MAGIC = 0x47585231
REMOTE_CLASS = gui.WINDOW_CLASS
REMOTE_PANE_CLASS = "GhosttyRemotePane"
WM_INPUTLANGCHANGEREQUEST = 0x0050
REMOTE = 1
READY = 2
ALL_FRAMES = 4
LEASE = 8
VISIBLE = 16
UNAVAILABLE = 32
REQUIRED_REMOTE = REMOTE | READY | ALL_FRAMES | LEASE | VISIBLE
# RemoteSurfaceView.State: waiting, live, unavailable, closed.
PANE_LIVE, PANE_UNAVAILABLE, PANE_CLOSED = 1, 2, 3
UIA_PANE = 50033
WM_IME_CONTROL = 0x0283
IMC_GETCONVERSIONMODE = 0x0001
IMC_SETCONVERSIONMODE = 0x0002
IMC_GETOPENSTATUS = 0x0005
IMC_SETOPENSTATUS = 0x0006
IME_CMODE_NATIVE = 0x0001
# Handles that are not HGLOBAL bytes: bitmap, metafile, palette, enhanced metafile, display variants.
GDI_HANDLE_FORMATS = {2, 3, 9, 14, 0x82, 0x83, 0x8E}
STANDARD_FORMATS = {1: "CF_TEXT", 2: "CF_BITMAP", 3: "CF_METAFILEPICT", 7: "CF_OEMTEXT", 8: "CF_DIB", 9: "CF_PALETTE",
                    13: "CF_UNICODETEXT", 14: "CF_ENHMETAFILE", 15: "CF_HDROP", 16: "CF_LOCALE", 17: "CF_DIBV5"}
SESSION_PROFILE = "custom:GXFixture"
UNSAFE_PASTE_TITLE = "Warning: Potentially Unsafe Paste"
OPTIONAL_CASES = ("uia", "performable", "once", "copy", "paste", "ole", "ime", "dragback", "bell", "mixed", "session")
CASE_IDS = {"transfer": "MIG-02", "remote-input-to-original-shell": "MIG-03",
            "remote-uia-external-mta": "UIA-01", "performable-fallback-without-selection": "MIG-06a",
            "activate-key-table-once": "MIG-06b", "chained-new-split-continuation": "MIG-06c",
            "persistent-key-table": "MIG-06d", "dragback-returns-original-tab": "MIG-02b",
            "drag-threshold": "MIG-01",
            "mixed-tab-transfer-rejected": "MIG-04b", "perf-input": "PERF-REMOTE-01"}


class Blocked(RuntimeError):
    pass


class CaseAbort(RuntimeError):
    """A structural case failed; later cases depend on its state."""


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def wait(predicate, label, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {label}")


class Fixture:
    def __init__(self, args):
        self.exe = args.exe.resolve(strict=True)
        self.expected_hash = args.sha256.lower()
        self.out = args.out.resolve()
        self.capture_method = args.capture
        self.split_stress = args.split_stress
        self.end = args.end
        self.skip = set(args.skip or ()) | {"copy", "paste"}
        self.perf_count = args.perf_count
        self.perf_interval_ms = args.perf_interval_ms
        self.perf_input = "perf-input" in (args.only or ())
        self.owned = []
        self.processes = {}
        self.expected_exit = set()
        self.layout_saved = None
        self.hooks_v2 = None
        self.source_child = None
        self.dragback_terminal = None
        self.source_children = []
        self.target_children = []
        self.clipboard_saved = None
        self.allow_clipboard_loss = bool(args.allow_clipboard_loss)
        self.ole_source = args.ole_source.resolve(strict=True) if args.ole_source else None
        self.only = list(dict.fromkeys(args.only or ()))
        self.session_target = not self.only and "session" not in self.skip
        self.token = secrets.token_hex(12)
        self.check_build()
        self.out.mkdir(parents=True, exist_ok=False)
        self.environment = (self.out / "private").resolve()
        gui.prepare_env_dir(self.environment, False)
        # Bindings use upstream actions only. chain= appends a source text
        # action after the target-placed new_split; the once table routes even
        # a source action through the remote continuation.
        self.config_path = gui.write_config(self.environment, "\n".join((
            "language = en", "confirm-close-surface = false", "gx-single-instance = false",
            "gx-session-restore = false", "clipboard-paste-protection = true",
            "keybind = ctrl+alt+r=new_split:right",
            f"keybind = chain=text:echo {self.marker('chain')}>>chain.txt\\r",
            "keybind = performable:ctrl+c=copy_to_clipboard",
            "keybind = ctrl+alt+k=activate_key_table_once:gxonce",
            f"keybind = gxonce/e=text:echo {self.marker('once')}>>once.txt\\r",
            "keybind = ctrl+alt+t=activate_key_table:gxrepeat",
            f"keybind = gxrepeat/e=text:echo {self.marker('table')}>>table.txt\\r",
            "keybind = gxrepeat/escape=deactivate_key_table",
            "bell-features = border,no-attention,no-title",
            "gx-launch-profile = GXFixture=cmd.exe /d /k gx-remote-fixture.cmd",
            f"keybind = ctrl+alt+p=gx:new_tab_profile:{SESSION_PROFILE}",
            f"working-directory = {self.environment.as_posix()}",
            "command = cmd.exe /d /k gx-remote-fixture.cmd", "",
        )))
        # Both processes use the exact same config root. Only an owned role
        # environment variable selects their marker. Replaying the command adds
        # another line, independently of any UI/protocol status report.
        script = "\r\n".join((
            "@echo off", "setlocal DisableDelayedExpansion", "chcp 65001>nul",
            'if /i "%GX_REMOTE_FIXTURE_ROLE%"=="source" goto source',
            'if /i "%GX_REMOTE_FIXTURE_ROLE%"=="target" goto target',
            "exit /b 91", ":source",
            f'>>"%GX_REMOTE_FIXTURE_ROOT%\\source-launches.txt" echo GX_REMOTE_SOURCE_{self.token}',
            f"title GX_REMOTE_SOURCE_{self.token}", f"echo GX_REMOTE_SOURCE_{self.token}",
            "goto done", ":target",
            f'>>"%GX_REMOTE_FIXTURE_ROOT%\\target-launches.txt" echo GX_REMOTE_TARGET_{self.token}',
            f"title GX_REMOTE_TARGET_{self.token}", f"echo GX_REMOTE_TARGET_{self.token}",
            ":done", "endlocal", "prompt $G$S", "",
        ))
        (self.environment / "gx-remote-fixture.cmd").write_bytes(script.encode("ascii"))
        (self.environment / "bel.txt").write_bytes(b"\x07")
        self.config_check = self.validate_config()
        self.report = {
            "status": "PENDING", "scope": "two-PID transfer, input, bindings, UIA, drag-back, mixed rejection and peer loss",
            "app": str(self.exe), "app_sha256": self.expected_hash, "build_label": args.build,
            "rehearsal": bool(args.rehearsal),
            "evidence_class": "REHEARSAL_NOT_ACCEPTANCE" if args.rehearsal else "CANDIDATE",
            "environment": str(self.environment), "marker_token": self.token, "end": self.end,
            "skipped_cases": sorted(self.skip), "only": self.only, "config_validation": self.config_check,
            "keyboard_mouse_input": True, "clipboard_access": False, "wire_protocol_injected": False,
            "visual_review": "PENDING", "processes": [], "cases": [], "captures": [], "cleanup": [],
            "hook_contract": {"begin": BEGIN, "query": QUERY, "magic": MAGIC,
                              "begin_semantics": "returnRemoteTab(target process) first; a remote-only tab returns, a mixed tab is rejected (0), a local tab begins a transfer",
                              "selectors": {"0": "magic", "1": "flags", "2": "active source core Surface ID",
                                            "3": "local foreground PID, remote=0", "4": "remote last frame sequence",
                                            "5": "remote mapping generation", "6": "remote transaction",
                                            "7": "local active terminal HWND", "12": "window tab count (v2)",
                                            "13": "active tab leaves (v2)", "14": "active tab local leaves (v2)",
                                            "15": "active tab remote leaves (v2)"}},
            "limits": ["The begin return means accepted, never completed.",
                       "Drag-back and mixed rejection use the begin hook, which calls the TabTransfer functions; the pointer drag gesture itself is not exercised.",
                       "Stable core/HWND/cmd PID+birth and one launch establish continuity; no raw ConPTY handle is exported.",
                       "PrintWindow can verify readable remote pixel content only after review, not DWM on-screen presentation.",
                       "The once case cannot observe release suppression: cmd ignores key-up records.",
                       "Clipboard cases snapshot every HGLOBAL clipboard format and restore it byte for byte; a GDI-handle format blocks them unless --allow-clipboard-loss.",
                       "The IME case drives the installed Microsoft Pinyin of the owned target thread and restores its mode and layout; raw letters mean BLOCKED, not PASS.",
                       "Session pruning is observed in the target's gx-session.json; only the target runs with --gx-session-restore=true."],
        }
        self.save()
        if self.config_check["returncode"] != 0:
            raise Blocked("the fixture configuration does not validate with this build; a case would run without its binding")

    def validate_config(self):
        """The app's own +validate-config: a rejected binding must never make a case vacuous."""
        path = self.config_path
        # A pipe makes this GUI-subsystem exe return 1 without output; a file does not.
        output = self.out / "config-validate.txt"
        with output.open("xb") as stream:
            result = subprocess.run([str(self.exe), "+validate-config", f"--config-file={path}"], stdin=subprocess.DEVNULL,
                                    stdout=stream, stderr=subprocess.STDOUT, timeout=30,
                                    env=gui.isolated_environment(os.environ, self.environment, {}))
        return {"config": str(path), "returncode": result.returncode, "output": output.name,
                "text": output.read_text(encoding="utf-8", errors="replace")[-4000:]}

    # -- report ----------------------------------------------------------------

    def check_build(self):
        if sha256(self.exe) != self.expected_hash:
            raise Blocked("executable differs from the coordinator's frozen SHA-256")

    def save(self):
        (self.out / "report.json").write_text(json.dumps(self.report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        title = "# 双进程远程视图截图复核" + ("（预演：旧 app，不作验收证据）" if self.report["rehearsal"] else "")
        lines = [title, "", f"app sha256 {self.expected_hash}，标签 {self.report['build_label']}。",
                 "原生检查与图片判读分别签收；未读图一律 PENDING。", ""]
        for item in self.report["captures"]:
            lines.append(f'- [ ] [{item["file"]}]({item["file"]})：{item["expect"]}；{item["method"]}；PENDING')
        lines += ["", "PrintWindow 只允许签可见内容的限定诊断结论，不代 DWM 上屏或真实拖动/键盘验收。"]
        (self.out / "visual-review.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def record(self, name, status="PASS", **details):
        self.report["cases"].append({"name": name, "status": status, **details})
        self.save()

    def case(self, name, function, *args, critical=False, optional=None):
        """Run one case; a FAIL is recorded and later independent cases continue."""
        if optional is not None and optional in self.skip:
            self.record(name, "SKIPPED", reason=f"--skip {optional}")
            return None
        first_capture = len(self.report["captures"])
        first_record = len(self.report["cases"])
        try:
            return function(*args)
        except (gui.InputBlocked, Blocked, CaseAbort):
            raise
        except (AssertionError, gui.GuiError, subprocess.SubprocessError, OSError, ValueError) as exc:
            self.record(name, "FAIL", reason=str(exc), traceback=traceback.format_exc())
            if critical:
                raise CaseAbort(name) from exc
            return None
        finally:
            if name in CASE_IDS:
                rows = self.report["cases"][first_record:]
                status = "FAIL" if any(row["status"] == "FAIL" for row in rows) else "PENDING"
                if rows and all(row["status"] == "PASS" for row in rows):
                    status = "PASS"
                self.report.setdefault("case_reviews", []).append(write_review(
                    self.out, CASE_IDS[name], "R5-03" if name == "remote-uia-external-mta" else "R5-01X",
                    "host", status, [row["file"] for row in self.report["captures"][first_capture:]],
                    observations=rows, identity_scope="native snapshots in report; scrollback counter pending A2r"))
                self.save()

    def marker(self, role):
        return f"GX_REMOTE_{role.upper()}_{self.token}"

    def launches(self, role):
        path = self.environment / f"{role}-launches.txt"
        if not path.is_file():
            return []
        return path.read_text(encoding="ascii").splitlines()

    def once(self, role, count=1):
        actual = self.launches(role)
        if actual != [self.marker(role)] * count:
            raise AssertionError(f"{role} command launch count/content changed: {actual!r}")

    def same_launches(self, role, expected):
        actual = self.launches(role)
        if actual != expected:
            raise AssertionError(f"{role} shell launches changed: {expected!r} -> {actual!r}")

    def file_lines(self, name):
        path = self.environment / name
        if not path.is_file():
            return None
        return [line.strip() for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]

    def expect_lines(self, name, expected, label, seconds=15, settle=0.0):
        """Wait until a file written by the source shell holds exactly the expected lines."""
        deadline = time.monotonic() + seconds
        actual = self.file_lines(name)
        while actual != expected and time.monotonic() < deadline:
            time.sleep(0.05)
            actual = self.file_lines(name)
        if actual != expected:
            raise AssertionError(f"{label}: {name} holds {actual!r}, expected {expected!r}")
        if settle:
            time.sleep(settle)
            actual = self.file_lines(name)
            if actual != expected:
                raise AssertionError(f"{label}: {name} changed to {actual!r} after it matched")
        return actual

    # -- processes ---------------------------------------------------------------

    def start(self, role):
        self.check_build()
        if role in self.processes:
            raise AssertionError("a fixture role cannot be launched twice")
        environment = gui.isolated_environment(os.environ, self.environment, {
            "GHOSTTY_GX_REMOTE_TEST": "1", "GX_REMOTE_FIXTURE_ROLE": role,
            "GX_REMOTE_FIXTURE_ROOT": str(self.environment),
        })
        if self.perf_input:
            environment["GHOSTTY_GX_PERF"] = "1"
        stdout_path = self.out / f"{role}.stdout.txt"
        stderr_path = self.out / f"{role}.stderr.txt"
        launched = gui.win32().now_filetime()
        # Keep the actual process handle: re-querying an exited PID cannot tell
        # us its exit code, and a PID may already have been reused. File-backed
        # output avoids unbounded pipe buffering or a pipe-drain deadlock.
        with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
            argv = [str(self.exe), "--gx-single-instance=false"]
            if role == "target" and self.session_target:
                argv.append("--gx-session-restore=true")
            process = subprocess.Popen(argv,
                                       cwd=str(self.environment), env=environment,
                                       stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
        self.processes[role] = {"process": process, "stdout": stdout_path, "stderr": stderr_path, "instance": None}
        birth = gui.win32().process_creation(process.pid)
        self.report["processes"].append({"role": role, "pid": process.pid, "birth": birth, "argv": argv[1:],
                                         "exe": str(self.exe), "environment": str(self.environment),
                                         "stdout": stdout_path.name, "stderr": stderr_path.name})
        self.save()
        if birth is None:
            raise AssertionError(f"owned {role} app failed during launch; exit code {process.poll()!r}")
        instance = gui.Instance(process.pid, str(self.exe), self.environment, birth, launched)
        self.processes[role]["instance"] = instance
        self.owned.append(instance)
        instance.ensure_owned()
        # Do not save both identities to gx_win_gui's single session.json in the
        # shared root. Keep separate immutable identity records in this report.
        instance.wait_window(20)
        wait(lambda: self.launches(role), f"{role} startup marker")
        self.once(role)
        instance.remember_children()
        return instance

    def exited_processes(self):
        exited = []
        for role, tracked in self.processes.items():
            process = tracked["process"]
            code = process.poll()
            if code is not None and role not in self.expected_exit:
                exited.append({"role": role, "pid": process.pid, "exit_code": code,
                               "exit_code_hex32": f"0x{code & 0xffffffff:08x}"})
        return exited

    @staticmethod
    def tail(path, limit=65536):
        try:
            with path.open("rb") as stream:
                stream.seek(0, 2)
                size = stream.tell()
                stream.seek(max(0, size - limit))
                content = stream.read(limit)
            return {"file": str(path), "bytes": size, "truncated": size > limit,
                    "tail": content.decode("utf-8", errors="replace")}
        except OSError as exc:
            return {"file": str(path), "error": str(exc)}

    def diagnostics(self, stage):
        snapshot = {"stage": stage, "processes": [], "logs": []}
        for role, tracked in self.processes.items():
            process = tracked["process"]
            code = process.poll()
            entry = {"role": role, "pid": process.pid, "exit_code": code,
                     "exit_code_hex32": None if code is None else f"0x{code & 0xffffffff:08x}",
                     "expected_exit": role in self.expected_exit,
                     "stdout": self.tail(tracked["stdout"]), "stderr": self.tail(tracked["stderr"])}
            instance = tracked["instance"]
            if instance is not None and code is None:
                try:
                    entry["owned_windows"] = [asdict(item) for item in instance.windows()[:32]]
                except gui.GuiError as exc:
                    entry["window_query_error"] = str(exc)
                # A process can exit during the bounded owned-window query.
                code = process.poll()
                entry["exit_code"] = code
                entry["exit_code_hex32"] = None if code is None else f"0x{code & 0xffffffff:08x}"
            snapshot["processes"].append(entry)
        # The apps intentionally share isolation. Startup of the second process
        # can rotate the source log, so preserve both current and rotated tails
        # without guessing their ownership from the filename alone.
        current = gui.log_path(self.environment)
        for path in (current, current.with_name(current.name + ".1"), current.with_name(current.stem + ".1" + current.suffix)):
            snapshot["logs"].append(self.tail(path, 131072))
        self.report.setdefault("diagnostics", []).append(snapshot)
        self.save()

    # -- native queries ------------------------------------------------------------

    @staticmethod
    def fresh(instance, hwnd, cls):
        instance.ensure_owned()
        if gui.win32().window_pid(hwnd) != instance.pid:
            raise gui.InputBlocked("test HWND no longer belongs to the expected PID/birth/exe")
        windows = instance.windows()
        if cls == REMOTE_PANE_CLASS:
            windows = [child for parent in windows if parent.cls == gui.WINDOW_CLASS for child in gui.win32().child_windows(parent.hwnd, REMOTE_PANE_CLASS)]
        window = next((item for item in windows if item.hwnd == hwnd and item.cls == cls), None)
        if window is None:
            raise gui.InputBlocked("expected owned window/class no longer exists")
        return window

    def query(self, instance, hwnd, cls, selector):
        self.fresh(instance, hwnd, cls)
        value = gui.win32().send_message(hwnd, QUERY, selector, 0, timeout_ms=3000)
        if value is None:
            raise AssertionError(f"native query selector {selector} timed out")
        self.fresh(instance, hwnd, cls)
        return value

    def snapshot(self, instance, hwnd, cls):
        if self.query(instance, hwnd, cls, 0) != MAGIC:
            raise AssertionError("remote-test hook absent, disabled, or incompatible")
        keys = ("flags", "surface_id", "foreground_pid", "frame_sequence", "mapping_generation", "transaction", "terminal_hwnd")
        return {name: self.query(instance, hwnd, cls, selector) for selector, name in enumerate(keys, 1)}

    @staticmethod
    def remote_panes(instance, window_hwnd):
        instance.ensure_owned()
        return [child for child in gui.win32().child_windows(window_hwnd, REMOTE_PANE_CLASS) if child.visible]

    @staticmethod
    def local_terminals(instance, window_hwnd):
        instance.ensure_owned()
        return [child for child in gui.win32().child_windows(window_hwnd, gui.TERMINAL_CLASS) if child.visible]

    def layout(self, instance, window_hwnd):
        """Visible leaves of the window, plus the v2 tree counts when the build has them."""
        result = {"visible_remote_panes": len(self.remote_panes(instance, window_hwnd)),
                  "visible_local_terminals": len(self.local_terminals(instance, window_hwnd))}
        if self.hooks_v2:
            for selector, name in ((12, "tabs"), (13, "leaves"), (14, "local_leaves"), (15, "remote_leaves")):
                result[name] = self.query(instance, window_hwnd, gui.WINDOW_CLASS, selector)
        return result

    def detect_hooks(self, instance, window_hwnd):
        if self.hooks_v2 is None:
            self.hooks_v2 = self.query(instance, window_hwnd, gui.WINDOW_CLASS, 12) > 0
            self.report["hooks_v2"] = self.hooks_v2
            self.save()
        return self.hooks_v2

    @staticmethod
    def process_identity(pid):
        api = gui.win32()
        image = api.process_image(pid)
        birth = api.process_creation(pid)
        if not image or not birth or not api.process_alive(pid):
            raise AssertionError(f"owned child process {pid} is not queryable/alive")
        return {"pid": pid, "birth": birth, "exe": image}

    @staticmethod
    def same_process(identity):
        actual = Fixture.process_identity(identity["pid"])
        if actual["birth"] != identity["birth"] or not gui.same_path(actual["exe"], identity["exe"]):
            raise AssertionError("child PID was reused or its image changed")

    def command_children(self, instance):
        instance.ensure_owned()
        result = []
        for pid, name in gui.win32().child_processes(instance.pid):
            if name.lower() == "cmd.exe":
                result.append(self.process_identity(pid))
        return sorted(result, key=lambda item: item["pid"])

    def visible_windows(self, instance):
        instance.ensure_owned()
        return [w for w in instance.windows() if w.cls == gui.WINDOW_CLASS and w.visible and not w.cloaked]

    # -- input guards ----------------------------------------------------------------

    def use_us_layout(self, instance, hwnd):
        """VK-typed letters must not start an IME composition. Restored at cleanup."""
        api = gui.win32()
        current = api.keyboard_layout(hwnd)
        if self.layout_saved is None:
            self.layout_saved = (instance, hwnd, current)
            self.report["input_language"] = {"before": f"0x{current:08x}"}
        if current & 0xFFFF == 0x0409:
            return True
        api.request_us_layout(hwnd)
        try:
            wait(lambda: api.keyboard_layout(hwnd) & 0xFFFF == 0x0409, "US keyboard layout", 3)
        except AssertionError:
            self.report["input_language"]["us"] = f"not switched; still 0x{api.keyboard_layout(hwnd):08x}"
            self.save()
            return False
        self.report["input_language"]["us"] = f"0x{api.keyboard_layout(hwnd):08x}"
        self.save()
        return True

    def restore_layout(self):
        if self.layout_saved is None:
            return
        instance, hwnd, before = self.layout_saved
        api = gui.win32()
        try:
            if instance.alive() and api.IsWindow(hwnd) and api.keyboard_layout(hwnd) != before:
                api.PostMessageW(api.focus_window(hwnd), WM_INPUTLANGCHANGEREQUEST, 0, before)
                time.sleep(0.2)
            self.report["input_language"]["restored"] = f"0x{api.keyboard_layout(hwnd):08x}" if instance.alive() else "owner exited"
        except Exception as exc:  # noqa: BLE001 - report, never mask the result
            self.report["input_language"]["restore_error"] = str(exc)

    def focus_remote(self, target, window_hwnd):
        """The single visible remote pane, with keyboard focus inside the target."""
        target.activate()
        panes = self.remote_panes(target, window_hwnd)
        if len(panes) != 1:
            raise AssertionError(f"expected exactly one visible remote pane, found {len(panes)}")
        pane = panes[0]
        api = gui.win32()
        if api.focus_window(window_hwnd) != pane.hwnd:
            left, top, right, bottom = pane.rect
            target.mouse((left + right) // 2, top + (bottom - top) * 3 // 4)
            wait(lambda: api.focus_window(window_hwnd) == pane.hwnd, "remote pane keyboard focus", 3)
        target.ensure_foreground()
        if not self.query(target, pane.hwnd, REMOTE_PANE_CLASS, 1) & LEASE:
            raise AssertionError("remote pane has no input lease")
        return pane

    # -- evidence ----------------------------------------------------------------------

    def capture(self, instance, hwnd, cls, name, expect, force=False):
        attempts = []
        if self.capture_method == "none" and not force:
            # Stress repetitions keep native checks only; failures still force a capture.
            self.report.setdefault("not_captured", []).append({"name": name, "expect": expect})
            self.save()
            return
        methods = ("screen", "print") if self.capture_method in ("auto", "none") else (self.capture_method,)
        for method in methods:
            try:
                info = self.fresh(instance, hwnd, cls)
                if not info.visible or info.cloaked:
                    raise gui.GuiError("capture window is not visibly presented")
                if method == "screen":
                    gui.win32().activate(hwnd)
                    time.sleep(0.2)
                    info = self.fresh(instance, hwnd, cls)
                instance.capture_window(info, method).save_png(self.out / f"{name}.png")
                self.fresh(instance, hwnd, cls)
                self.report["captures"].append({"file": f"{name}.png", "method": method, "review": "PENDING",
                                                "expect": expect, "attempts": attempts, "window": asdict(info),
                                                "pid": instance.pid, "birth": instance.creation})
                self.save()
                return
            except gui.InputBlocked:
                raise
            except gui.GuiError as exc:
                attempts.append({"method": method, "status": "BLOCKED", "reason": str(exc)})
        # Capture limitations do not turn a native continuity check into GUI
        # success, nor require activation or input to an unrelated foreground.
        self.record(name + "/capture", "PENDING", attempts=attempts)

    # -- structural steps ------------------------------------------------------------

    def transfer(self, source, target, source_window, before, target_window, label):
        """BEGIN from a source window; wait for the target view and the source move."""
        self.check_build()
        self.fresh(source, source_window.hwnd, gui.WINDOW_CLASS)
        target.ensure_owned()
        accepted = gui.win32().send_message(source_window.hwnd, BEGIN, target.pid, target.creation, timeout_ms=5000)
        if accepted != 1:
            raise AssertionError(f"production remote.begin request not accepted: {accepted!r}")
        self.record(f"{label}begin-accepted-only", result=accepted, target_pid=target.pid, target_birth=target.creation)

        def remote_ready():
            source.ensure_owned()
            target.ensure_owned()
            for item in target.windows():
                if item.cls != REMOTE_CLASS:
                    continue
                state = self.snapshot(target, item.hwnd, REMOTE_CLASS)
                if state["flags"] & UNAVAILABLE:
                    raise AssertionError("target remote view became unavailable before the transfer completed")
                if state["flags"] & REQUIRED_REMOTE == REQUIRED_REMOTE and state["frame_sequence"] > 0:
                    return item, state
            return None

        remote, state = wait(remote_ready, "real remote mappings/first frame/lease/visible")
        if state["surface_id"] != before["surface_id"] or not state["mapping_generation"] or not state["transaction"]:
            raise AssertionError("remote view is not bound to the original source core and transaction")

        # Target enable precedes the source's target_enabled message. Wait for
        # the actual source model move, otherwise closing here would correctly
        # cancel an in-flight transfer rather than exercise host survival.
        def source_moved():
            source.ensure_owned()
            original = next((w for w in source.windows() if w.hwnd == source_window.hwnd), None)
            if original is None:
                return True
            try:
                active = self.query(source, original.hwnd, gui.WINDOW_CLASS, 2)
            except gui.InputBlocked:
                source.ensure_owned()
                if not any(w.hwnd == source_window.hwnd for w in source.windows()):
                    return True
                raise
            if active not in (0, before["surface_id"]):
                raise AssertionError("source replaced its original active core during transfer")
            return active == 0

        wait(source_moved, "source tree actually moved out of its window")
        # A one-tab move normally closes the empty source container itself. If
        # it remains empty, close only that window, never the hidden host.
        remaining = next((w for w in source.windows() if w.hwnd == source_window.hwnd), None)
        if remaining is not None:
            self.fresh(source, source_window.hwnd, gui.WINDOW_CLASS)
            if not gui.win32().PostMessageW(source_window.hwnd, gui.WM_CLOSE, 0, 0):
                raise AssertionError("could not close the emptied owned source window")
        wait(lambda: not self.visible_windows(source), "source ordinary window closure")
        if remote.hwnd != target_window.hwnd:
            raise AssertionError("transfer created another window instead of adopting into the existing target")
        return remote, state

    def restored_source(self, source, before):
        """The visible source window whose active core is the original surface."""
        for item in self.visible_windows(source):
            current = self.snapshot(source, item.hwnd, gui.WINDOW_CLASS)
            if current["surface_id"] == before["surface_id"]:
                return item, current
        return None

    def check_continuity(self, source, restored, before):
        if restored["terminal_hwnd"] != before["terminal_hwnd"] or restored["foreground_pid"] != self.source_child["pid"]:
            raise AssertionError("the source core came back with another terminal HWND or foreground shell")
        self.same_process(self.source_child)
        if self.command_children(source) != self.source_children:
            raise AssertionError("the source cmd shell was spawned or replaced")
        self.once("source")

    # -- cases ----------------------------------------------------------------------------

    def case_input(self, target, remote):
        self.focus_remote(target, remote.hwnd)
        input_marker = self.marker("input")
        target.type_text("echo " + input_marker + "> remote-input.txt")
        target.press("enter")
        self.expect_lines("remote-input.txt", [input_marker], "remote keyboard reaches the original source shell")
        self.same_process(self.source_child)
        self.record("remote-input-to-original-shell", marker=input_marker, child=self.source_child)

    def case_perf_input(self, target, remote):
        """Paced real input; metric interpretation and quiet acceptance belong to root."""
        pane = self.focus_remote(target, remote.hwnd)
        before = native_snapshot(target)
        samples = []
        interval = self.perf_interval_ms / 1000
        deadline = time.perf_counter()
        for index in range(self.perf_count):
            delay = deadline - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            target.ensure_foreground()
            self.fresh(target, pane.hwnd, REMOTE_PANE_CLASS)
            if gui.win32().focus_window(remote.hwnd) != pane.hwnd:
                raise gui.InputBlocked("remote input focus changed during paced sample")
            sent = time.perf_counter_ns()
            target.type_text(chr(ord("a") + index % 26), delay=0)
            samples.append({"index": index, "sent_perf_counter_ns": sent})
            deadline += interval
        time.sleep(0.5)
        self.same_process(self.source_child)
        self.capture(target, remote.hwnd, REMOTE_CLASS, "perf-input", "固定节奏字符停留在原 shell 行内；没有自动回车")
        self.record("perf-input", count=self.perf_count, interval_ms=self.perf_interval_ms,
                    metric="remote.input_to_present", clock="system QPC (product metric); Python schedule is diagnostic",
                    samples=samples, before=before, after=native_snapshot(target), enter_injected=False,
                    measurement_status="PENDING_ROOT_AGGREGATION", perf_enabled_roles=["source", "target"])

    def case_table(self, target, remote):
        if not self.use_us_layout(target, remote.hwnd):
            raise Blocked("persistent table needs US layout on the owned input thread")
        self.focus_remote(target, remote.hwnd)
        target.press("ctrl+alt+t")
        for count in (1, 2):
            target.press("e")
            self.expect_lines("table.txt", [self.marker("table")] * count, "persistent table remains active")
        target.press("escape")
        target.type_text("echo " + self.marker("table_exit") + ">table-exit.txt")
        target.press("enter")
        self.expect_lines("table-exit.txt", [self.marker("table_exit")], "table deactivation reaches shell")
        self.capture(target, remote.hwnd, REMOTE_CLASS, "table", "持久表连续执行两次并退出；原 PTY 继续接收输入")
        self.record("persistent-key-table", child=self.source_child, executions=2)

    def case_drag_threshold(self, source, window):
        source.activate()
        source.press("ctrl+shift+t")
        wait(lambda: self.query(source, window.hwnd, gui.WINDOW_CLASS, 12) == 2, "second tab")
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--hwnd", str(window.hwnd),
                   "--pid", str(source.pid), "--birth", str(source.creation), "--exe", str(self.exe),
                   "--sha256", self.expected_hash, "--max-nodes", "512"]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=15)
        (self.out / "drag-tab-geometry.json").write_text(result.stdout, encoding="utf-8")
        assert result.returncode == 0, "cannot discover live tab geometry"
        nodes = [node for node in json.loads(result.stdout)["nodes"] if node["control_type"] == 50019 and node.get("bounds")]
        assert len(nodes) == 2, "expected two UIA tab items"
        left, top, width, height = nodes[0]["bounds"]
        assert width > 60 and height > 10
        point = round(left + width / 3), round(top + height / 2)
        source.mouse(*point)
        before = native_snapshot(source)
        dpi = gui.win32().GetDpiForWindow(window.hwnd)
        threshold = drag_thresholds(dpi)
        below = threshold["vertical"]["at_or_below_px"]
        above = threshold["vertical"]["above_px"]
        source.drag(point, (point[0], point[1] + below), steps=1)
        time.sleep(0.2)
        assert len(self.visible_windows(source)) == 1, "at/below 15 DIP detached"
        self.capture(source, window.hwnd, gui.WINDOW_CLASS, "drag-at-or-below", "15 DIP 以下或恰等于阈值时仍是一窗两标签")
        released = False
        try:
            source.drag(point, (point[0], point[1] + above), steps=1, release=False)
            wait(lambda: len(self.visible_windows(source)) == 2, ">15 DIP detach", 5)
            source.press("escape")
            source.activate()
            release_point = source.point(100, 100)
            source.mouse(*release_point, action="up")
            released = True
            after = native_snapshot(source)
            before_leaves = {(w["surface_id"], w["terminal_hwnd"]) for w in before["windows"]}
            after_leaves = {(w["surface_id"], w["terminal_hwnd"]) for w in after["windows"]}
            assert before_leaves <= after_leaves, "detached active Surface/HWND was replaced"
            assert before["children"] == after["children"], "detach replaced a PTY process"
            for index, moved in enumerate(self.visible_windows(source)):
                self.capture(source, moved.hwnd, gui.WINDOW_CLASS, f"drag-after-{index}", "拖出后保留原终端；子进程身份以 JSON 核对")
            self.record("drag-threshold", threshold=threshold, before=before, after=after,
                        horizontal_status="PENDING_DRAG_ACTIVE_QUERY", exact_15_dip_native=threshold["vertical"]["exact_representable"],
                        scope="vertical native detach; exact 15 DIP only when integral pixels; horizontal pure test is separate")
        finally:
            if not released:
                # Releasing is itself guarded; do not send to another app after
                # foreground/identity loss, including in failure cleanup.
                source.ensure_foreground()
                source.mouse(*source.point(100, 100), action="up")

    def case_uia(self, target, remote):
        panes = self.remote_panes(target, remote.hwnd)
        if len(panes) != 1:
            raise AssertionError("expected one visible remote pane for the UIA probe")
        pane = panes[0]
        source_marker = self.marker("source")
        attempts = []
        for attempt in range(1, 9):
            self.fresh(target, pane.hwnd, REMOTE_PANE_CLASS)
            # The worker is an owned MTA subprocess; subprocess.run kills and
            # waits for exactly that worker on timeout.
            command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker",
                       "--hwnd", str(pane.hwnd), "--pid", str(target.pid), "--birth", str(target.creation),
                       "--exe", str(self.exe), "--timeout", "15", "--max-nodes", "64", "--max-depth", "4"]
            try:
                result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=20)
            except subprocess.TimeoutExpired:
                attempts.append({"attempt": attempt, "status": "TIMEOUT"})
                break
            evidence = f"uia-remote-{attempt}.json"
            (self.out / evidence).write_text(json.dumps({"command": command, "returncode": result.returncode,
                                                         "stdout": result.stdout, "stderr": result.stderr},
                                                        ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            try:
                probe = json.loads(result.stdout) if result.stdout.strip() else {}
            except json.JSONDecodeError:
                probe = {}
            nodes = probe.get("nodes", []) if probe.get("status") == "PASS" else []
            names = [str(node.get("name") or "") for node in nodes]
            attempts.append({"attempt": attempt, "evidence": evidence, "returncode": result.returncode,
                             "status": probe.get("status"), "error": probe.get("error"), "nodes": len(nodes)})
            if nodes:
                if probe.get("apartment") != "MTA" or probe.get("created_hwnd") is not False:
                    raise AssertionError("probe did not confirm the external windowless MTA contract")
                if nodes[0].get("control_type") != UIA_PANE:
                    raise AssertionError(f"remote root is not a pane: {nodes[0]!r}")
                # The first request asks the source for text; a later snapshot carries it.
                if any(source_marker in name for name in names[1:]):
                    self.record("remote-uia-external-mta", attempts=attempts, root=nodes[0],
                                text_nodes=len(nodes) - 1, marker=source_marker)
                    return
            time.sleep(0.5)
        raise AssertionError(f"remote UIA never exposed the source text {source_marker}: {attempts!r}")

    def case_performable(self, target, remote):
        self.focus_remote(target, remote.hwnd)
        first, second = self.marker("perf_a"), self.marker("perf_b")
        # No selection: copy_to_clipboard is not performed, so the source must
        # deliver the original Ctrl+C, which cancels this unfinished cmd line.
        target.type_text(f"echo {first}>>perf.txt")
        time.sleep(0.4)
        target.press("ctrl+c")
        time.sleep(0.8)
        target.type_text(f"echo {second}>>perf.txt")
        target.press("enter")
        lines = self.expect_lines("perf.txt", [second], "performable copy without a selection falls back to Ctrl+C", settle=0.5)
        self.same_process(self.source_child)
        self.record("performable-fallback-without-selection", binding="performable:ctrl+c=copy_to_clipboard", lines=lines,
                    boundary="Validated binding; the consuming half (copy with a selection) is a separate clipboard case.")

    def case_once(self, target, remote):
        if not self.use_us_layout(target, remote.hwnd):
            self.record("activate-key-table-once", "BLOCKED", reason="cannot switch the owned target thread to the US layout; VK letters would compose")
            return
        self.focus_remote(target, remote.hwnd)
        once, twice = self.marker("once"), self.marker("twice")
        target.press("ctrl+alt+k")
        time.sleep(0.4)
        target.press("e")
        self.expect_lines("once.txt", [once], "the once table runs its binding through the remote continuation")
        time.sleep(0.4)
        # The table is gone: this e is ordinary text that begins the next command.
        target.press("e")
        time.sleep(0.3)
        target.type_text(f"cho {twice}>>twice.txt")
        target.press("enter")
        self.expect_lines("twice.txt", [twice], "the second e reached the shell as text")
        self.expect_lines("once.txt", [once], "the once binding ran exactly once", settle=0.5)
        self.record("activate-key-table-once", table="gxonce", once=once, twice=twice)

    def case_dragback(self, source, target, remote, before):
        self.fresh(target, remote.hwnd, REMOTE_CLASS)
        if not self.query(target, remote.hwnd, REMOTE_CLASS, 1) & REMOTE:
            raise AssertionError("the active target tab is not the remote tab")
        layout_before = self.layout(target, remote.hwnd)
        source.ensure_owned()
        result = gui.win32().send_message(remote.hwnd, BEGIN, source.pid, source.creation, timeout_ms=5000)
        if result != 1:
            raise AssertionError(f"remote-only tab was not returned to its source host: {result!r}")
        restored_window, restored = wait(lambda: self.restored_source(source, before), "source restores its returned tab")
        wait(lambda: not self.remote_panes(target, remote.hwnd), "target removes the returned remote pane")
        self.check_continuity(source, restored, before)
        if self.command_children(target) != self.target_children:
            raise AssertionError("drag-back spawned or replaced a target shell")
        self.once("target")
        self.record("dragback-returns-original-tab", begin_result=result, restored=restored,
                    target_layout_before=layout_before, target_layout_after=self.layout(target, remote.hwnd),
                    source_launches=self.launches("source"), target_launches=self.launches("target"))
        terminal = next((child for child in gui.win32().child_windows(restored_window.hwnd, gui.TERMINAL_CLASS)
                         if child.hwnd == before["terminal_hwnd"]), None)
        if terminal is None or not terminal.visible:
            raise AssertionError(f"the returned terminal HWND is not a visible child of the restored window: {terminal!r}")
        time.sleep(1.0)
        self.capture(source, restored_window.hwnd, gui.WINDOW_CLASS, "source-dragged-back",
                     "拖回 1 秒后源窗口显示同一源终端：GX_REMOTE_SOURCE 标记与已执行输入仍在，无重新启动（空白即渲染未恢复）")
        self.dragback_terminal = terminal
        return restored_window

    def case_dragback_input(self, source, restored_window, before):
        """Local input after the return proves the shell and input path; the
        second screenshot shows whether drawing resumed after new output."""
        source.activate()
        source.ensure_foreground()
        if gui.win32().focus_window(restored_window.hwnd) != before["terminal_hwnd"]:
            raise AssertionError("keyboard focus is not on the returned terminal")
        # Escape clears whatever an earlier failed case left on the cmd line.
        source.press("escape")
        time.sleep(0.2)
        back = self.marker("back")
        source.type_text(f"echo {back}>>back.txt")
        source.press("enter")
        self.expect_lines("back.txt", [back], "the returned source terminal accepts local input")
        time.sleep(0.5)
        self.record("dragback-local-input", marker=back, terminal=asdict(self.dragback_terminal))
        self.capture(source, restored_window.hwnd, gui.WINDOW_CLASS, "source-dragged-back-typed",
                     "拖回后本地输入的 GX_REMOTE_BACK 行与此前全部内容都可见")

    def case_chain(self, target, remote):
        self.focus_remote(target, remote.hwnd)
        children = self.command_children(target)
        target.press("ctrl+alt+r")
        wait(lambda: len(self.command_children(target)) == len(children) + 1,
             "remote new_split creates a target-local terminal")
        lines = self.expect_lines("chain.txt", [self.marker("chain")], "the chained source text ran after the target new_split result")
        panes = wait(lambda: self.remote_panes(target, remote.hwnd), "remote pane retained beside the local split")
        if len(panes) != 1:
            raise AssertionError("mixed tab did not retain exactly its original remote view")
        # The cmd process exists before its script appends the launch marker.
        wait(lambda: len(self.launches("target")) >= 2, "the new local split ran its launch script")
        self.once("target", 2)
        # The split resizes the remote view; after it settles the original
        # remote pane must still be live, not the unavailable placeholder.
        time.sleep(1.0)
        pane_flags = self.require_live_remote(target, remote, "after the chained new_split")
        self.record("chained-new-split-continuation", target_children=self.command_children(target),
                    chain=lines, pane_flags=pane_flags, layout=self.layout(target, remote.hwnd))
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-mixed",
                     "原远程终端与新建的目标本地终端并排；源端 chain 命令行已执行，源命令不重放")

    def case_split_stress(self, target, remote, before, rounds):
        """Repeat layout changes in one target instance: a remote-originated
        new_split (with its chained source text), closing that new local split,
        and shrinking then restoring the target window. Every change re-maps
        the remote view; after each one the original pane must be live, bound to
        the original source core and still receiving frames."""
        api = gui.win32()
        left, top, right, bottom = self.fresh(target, remote.hwnd, REMOTE_CLASS).rect
        width, height = right - left, bottom - top
        chain = list(self.file_lines("chain.txt") or [])
        children = self.command_children(target)
        launches = self.launches("target")
        steps = []
        alive = []

        def settled(label, previous):
            # Read the remote pane itself (the window query follows the
            # focused leaf). Frame sequences restart with each mapping
            # generation and an idle shell need not draw, so progress is not
            # required here; liveness is: still live, same source core, and a
            # fresh echo marker typed into the pane must reach the source shell.
            state = wait(lambda: (lambda value: value if value["state"] == PANE_LIVE else None)(self.live_pane(target, remote, label)),
                         f"remote pane live {label}", 10)
            self.require_live_remote(target, remote, label)
            if state["surface_id"] != before["surface_id"]:
                raise AssertionError(f"remote pane lost its source core {label}: {state!r}")
            # End-to-end after every layout change: a unique marker typed into
            # the remote pane must run in the original source shell once.
            self.focus_remote(target, remote.hwnd)
            alive.append(f"{self.marker('alive')}_{len(alive) + 1}")
            target.type_text(f"echo {alive[-1]}>>alive.txt")
            target.press("enter")
            self.expect_lines("alive.txt", alive, f"input through the remote pane reached the source shell {label}")
            after = self.live_pane(target, remote, label)
            steps.append({"step": label, "before": previous, "settled": state, "after_echo": after,
                          "layout": self.layout(target, remote.hwnd)})
            return after

        def shells(expected):
            # A cmd that is starting or exiting can vanish between enumeration
            # and its identity query; that is not a result, so poll again.
            try:
                current = self.command_children(target)
            except AssertionError:
                return False
            return len(current) == expected if isinstance(expected, int) else current == expected

        state = self.live_pane(target, remote, "before the stress")
        try:
            for index in range(1, rounds + 1):
                # Remote-originated split; the chained source text runs exactly once more.
                self.focus_remote(target, remote.hwnd)
                known = {item.hwnd for item in self.local_terminals(target, remote.hwnd)}
                target.press("ctrl+alt+r")
                wait(lambda: shells(len(children) + 1), f"round {index}: new_split adds one target shell")
                chain.append(self.marker("chain"))
                self.expect_lines("chain.txt", chain, f"round {index}: the chained source text ran once")
                wait(lambda: len(self.launches("target")) == len(launches) + index,
                     f"round {index}: the new local split ran its launch script")
                added = wait(lambda: [item for item in self.local_terminals(target, remote.hwnd) if item.hwnd not in known],
                             f"round {index}: the new local split is visible")
                if len(added) != 1:
                    raise AssertionError(f"round {index}: expected one new local split, found {len(added)}")
                split = added[0]
                state = settled(f"after split {index}", state)
                # Close only the new local split. Focus is checked before every
                # keystroke so "exit" can never reach the source shell.
                if api.focus_window(remote.hwnd) != split.hwnd:
                    l, t, r, b = split.rect
                    target.mouse((l + r) // 2, (t + b) // 2)
                    wait(lambda: api.focus_window(remote.hwnd) == split.hwnd, f"round {index}: focus on the new split", 3)
                target.ensure_foreground()
                if api.focus_window(remote.hwnd) != split.hwnd:
                    raise AssertionError(f"round {index}: keyboard focus is not on the new local split")
                target.type_text("exit")
                if api.focus_window(remote.hwnd) != split.hwnd:
                    raise AssertionError(f"round {index}: focus left the new local split before Enter")
                target.press("enter")
                wait(lambda: shells(children), f"round {index}: exit ends only the new split's shell")
                wait(lambda: split.hwnd not in {item.hwnd for item in self.local_terminals(target, remote.hwnd)},
                     f"round {index}: the new split closes")
                state = settled(f"after close {index}", state)
                # Shrink, then restore, the target window (SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE).
                for w, h, what in ((width - 320, height - 200, "shrink"), (width, height, "restore")):
                    target.ensure_owned()
                    if not api.SetWindowPos(remote.hwnd, None, 0, 0, w, h, 0x0002 | 0x0004 | 0x0010):
                        raise AssertionError(f"round {index}: SetWindowPos {what} failed")
                    state = settled(f"after {what} {index}", state)
        except AssertionError:
            self.report.setdefault("stress_steps", steps)
            self.capture(target, remote.hwnd, REMOTE_CLASS, "target-stress-failure",
                         "失败时的目标窗口：远程窗格是否已显示 unavailable，或停在哪一步", force=True)
            raise
        self.same_process(self.source_child)
        if self.command_children(target) != children:
            raise AssertionError("split stress left extra or replaced target shells")
        self.once("source")
        generations = sorted({item["after_echo"]["mapping_generation"] for item in steps})
        self.record("split-resize-stress", rounds=rounds, layout_changes=len(steps), chain_lines=len(chain), alive_lines=len(alive),
                    mapping_generations=generations, steps=steps, target_launches=len(self.launches("target")))
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-stress-final",
                     f"{rounds} 轮 split/关闭/缩放后：左侧远程窗格仍显示源终端（{len(chain)} 行 CHAIN），右侧为链式新建的本地窗格")

    def tracked_files(self):
        return {name: self.file_lines(name) for name in ("alive.txt", "chain.txt", "once.txt", "perf.txt", "twice.txt", "remote-input.txt", "back.txt", "paste.txt", "safe-paste.txt", "ole.txt", "ime.txt", "keep.txt")}

    def case_mixed(self, source, target, remote):
        layout_before = self.layout(target, remote.hwnd)
        files_before = self.tracked_files()
        children_before = self.command_children(target)
        source.ensure_owned()
        result = gui.win32().send_message(remote.hwnd, BEGIN, source.pid, source.creation, timeout_ms=5000)
        if result != 0:
            raise AssertionError(f"a mixed local/remote tab was accepted for transfer: {result!r}")
        time.sleep(1.0)
        layout_after = self.layout(target, remote.hwnd)
        if layout_after != layout_before:
            raise AssertionError(f"rejected transfer changed the target tree: {layout_before!r} -> {layout_after!r}")
        if self.visible_windows(source):
            raise AssertionError("rejected transfer showed a source window")
        self.same_process(self.source_child)
        if self.command_children(target) != children_before or self.command_children(source) != self.source_children:
            raise AssertionError("rejected transfer spawned or replaced a shell")
        if self.tracked_files() != files_before:
            raise AssertionError("rejected transfer replayed source input")
        self.once("source")
        self.once("target", 2)
        self.record("mixed-tab-transfer-rejected", begin_result=result, layout=layout_after)

    def require_live_remote(self, target, remote, when):
        """Exactly one visible remote pane, still connected (not unavailable)."""
        panes = self.remote_panes(target, remote.hwnd)
        if len(panes) != 1:
            raise AssertionError(f"expected one visible remote pane {when}, found {len(panes)}")
        flags = self.query(target, panes[0].hwnd, REMOTE_PANE_CLASS, 1)
        if flags & UNAVAILABLE:
            raise AssertionError(f"the remote pane was already unavailable {when} (flags={flags})")
        return flags

    def live_pane(self, target, remote, label):
        """Fixture query on the single visible remote pane (RemotePane.query)."""
        panes = self.remote_panes(target, remote.hwnd)
        if len(panes) != 1:
            raise AssertionError(f"expected one visible remote pane {label}, found {len(panes)}")
        hwnd = panes[0].hwnd
        if self.query(target, hwnd, REMOTE_PANE_CLASS, 0) != MAGIC:
            raise AssertionError("remote pane test hook absent or incompatible")
        fields = {1: "flags", 2: "surface_id", 4: "frame_sequence", 5: "mapping_generation", 6: "transaction", 9: "state"}
        state = {"pane": hwnd, **{name: self.query(target, hwnd, REMOTE_PANE_CLASS, selector) for selector, name in fields.items()}}
        if state["flags"] & UNAVAILABLE or state["state"] in (PANE_UNAVAILABLE, PANE_CLOSED):
            raise AssertionError(f"remote pane became unavailable {label}: {state!r}")
        return state

    def case_source_loss(self, source, target, remote):
        # An earlier disconnect would make the unavailable state below trivial.
        self.require_live_remote(target, remote, "before the source was terminated")
        panes = self.remote_panes(target, remote.hwnd)
        if len(panes) != 1:
            raise AssertionError("expected one remote pane before the source loss")
        pane = panes[0]
        local_before = self.local_terminals(target, remote.hwnd)
        target_children = self.command_children(target)
        files_before = self.tracked_files()
        launches_before = self.launches("target")
        process = self.processes["source"]["process"]
        self.expected_exit.add("source")
        process.terminate()
        process.wait(timeout=15)
        self.record("owned-source-process-terminated", exit_code=process.returncode)

        def unavailable():
            value = self.query(target, pane.hwnd, REMOTE_PANE_CLASS, 1)
            return value if value & UNAVAILABLE else None

        flags = wait(unavailable, "target marks the remote pane unavailable after source loss", 20)
        if flags & LEASE:
            raise AssertionError("an unavailable remote pane kept its input lease")
        children_after = self.command_children(target)
        local_after = self.local_terminals(target, remote.hwnd)
        if children_after != target_children or len(local_after) != len(local_before):
            raise AssertionError(f"source loss changed target-local terminals: cmd {target_children!r} -> {children_after!r}, "
                                 f"visible local {[w.hwnd for w in local_before]!r} -> {[w.hwnd for w in local_after]!r}")
        self.same_launches("target", launches_before)
        self.record("source-loss-unavailable", flags=flags, layout=self.layout(target, remote.hwnd))
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-source-unavailable",
                     "远程窗格显示 The remote terminal is unavailable. 与 Close；旁边目标本地终端照常")
        # A click on an unavailable pane asks to close only that leaf.
        target.activate()
        left, top, right, bottom = self.fresh(target, pane.hwnd, REMOTE_PANE_CLASS).rect
        target.mouse((left + right) // 2, (top + bottom) // 2)
        wait(lambda: not self.remote_panes(target, remote.hwnd), "the unavailable remote leaf closes on click")
        if self.command_children(target) != target_children:
            raise AssertionError("closing the unavailable leaf changed target-local shells")
        if not self.local_terminals(target, remote.hwnd):
            raise AssertionError("closing the unavailable leaf closed the local split too")
        if self.tracked_files() != files_before:
            raise AssertionError("source loss replayed input")
        self.same_launches("target", launches_before)
        self.record("unavailable-leaf-closed-locally", layout=self.layout(target, remote.hwnd))
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-unavailable-closed",
                     "不可用远程叶关闭后只剩目标本地终端，窗口仍可用")

    def case_target_loss(self, source, target, before, remote):
        # Recovery must follow the target abort, not an earlier disconnect.
        self.require_live_remote(target, remote, "before the target was terminated")
        target_process = self.processes["target"]["process"]
        self.expected_exit.add("target")
        target.ensure_owned()
        # Terminate the retained Popen handle, never a guessed/reused PID. A
        # target process crash must return the source lease without replay.
        target_process.terminate()
        target_process.wait(timeout=15)
        self.record("owned-target-process-terminated", exit_code=target_process.returncode)
        restored_window, restored = wait(lambda: self.restored_source(source, before),
                                         "source original core recovery after real target abort/disconnect")
        self.check_continuity(source, restored, before)
        self.record("original-core-recovered-without-command-replay", before=before, restored=restored,
                    source_child=self.source_child, source_launches=self.launches("source"), target_launches=self.launches("target"))
        # Same presentation gate as the drag-back capture: the original
        # terminal HWND must be a visible child, then one second to draw.
        terminal = next((child for child in gui.win32().child_windows(restored_window.hwnd, gui.TERMINAL_CLASS)
                         if child.hwnd == before["terminal_hwnd"]), None)
        if terminal is None or not terminal.visible:
            raise AssertionError(f"the recovered terminal HWND is not a visible child of the source window: {terminal!r}")
        time.sleep(1.0)
        self.capture(source, restored_window.hwnd, gui.WINDOW_CLASS, "source-recovered",
                     "目标退出 1 秒后源窗口显示同一源终端：" + self.marker("source") + " 与已执行输入仍在（空白即渲染未恢复）")

    # -- batch 2: clipboard, OLE, IME, session, bell border ---------------------------------

    @staticmethod
    def clipboard_api():
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        user32.EnumClipboardFormats.argtypes = [wintypes.UINT]
        user32.EnumClipboardFormats.restype = wintypes.UINT
        user32.GetClipboardData.argtypes = [wintypes.UINT]
        user32.GetClipboardData.restype = wintypes.HANDLE
        user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
        user32.SetClipboardData.restype = wintypes.HANDLE
        kernel32.GlobalSize.argtypes = [wintypes.HGLOBAL]
        kernel32.GlobalSize.restype = ctypes.c_size_t
        kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
        kernel32.GlobalLock.restype = ctypes.c_void_p
        kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
        kernel32.GlobalUnlock.restype = wintypes.BOOL
        kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
        kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
        kernel32.GlobalFree.argtypes = [wintypes.HGLOBAL]
        kernel32.GlobalFree.restype = wintypes.HGLOBAL
        return user32, kernel32

    def clipboard_snapshot(self):
        """Every clipboard format as owned bytes; None for a GDI-handle format that cannot be copied."""
        user32, kernel32 = self.clipboard_api()
        api = gui.win32()
        api._open_clipboard()
        try:
            items, current, total = [], 0, 0
            while len(items) < 256:
                current = user32.EnumClipboardFormats(current)
                if not current:
                    break
                if current in GDI_HANDLE_FORMATS:
                    return None, current
                handle = user32.GetClipboardData(current)
                size = kernel32.GlobalSize(handle) if handle else 0
                pointer = kernel32.GlobalLock(handle) if size else None
                if not pointer:
                    return None, current
                try:
                    items.append((current, ctypes.string_at(pointer, size)))
                finally:
                    kernel32.GlobalUnlock(handle)
                total += size
                if total > 64 * 1024 * 1024:
                    return None, current
            return items, None
        finally:
            api.CloseClipboard()

    @staticmethod
    def format_name(fmt):
        if fmt in STANDARD_FORMATS:
            return STANDARD_FORMATS[fmt]
        buffer = ctypes.create_unicode_buffer(256)
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        return buffer.value if user32.GetClipboardFormatNameW(fmt, buffer, 256) else f"format-{fmt}"

    def claim_clipboard(self):
        """Snapshot the user's clipboard once, byte for byte, before any case writes it."""
        if self.clipboard_saved is not None:
            return True
        items, blocker = self.clipboard_snapshot()
        if items is None:
            self.report["clipboard"] = {"blocked_by_format": self.format_name(blocker)}
            if not self.allow_clipboard_loss:
                self.save()
                return False
            items = []
        # Held in memory only; the report never records clipboard bytes, text or sizes.
        self.clipboard_saved = items
        self.report["clipboard"] = {"format_count": len(items), "formats": [self.format_name(fmt) for fmt, _ in items]}
        self.report["clipboard_access"] = True
        self.save()
        return True

    def restore_clipboard(self):
        if self.clipboard_saved is None:
            return
        user32, kernel32 = self.clipboard_api()
        api = gui.win32()
        restored = []
        try:
            api._open_clipboard()
            try:
                api.EmptyClipboard()
                for fmt, data in self.clipboard_saved:
                    handle = kernel32.GlobalAlloc(0x0002, max(1, len(data)))  # GMEM_MOVEABLE
                    pointer = kernel32.GlobalLock(handle) if handle else None
                    if not pointer:
                        if handle:
                            kernel32.GlobalFree(handle)
                        continue
                    ctypes.memmove(pointer, data, len(data))
                    kernel32.GlobalUnlock(handle)
                    if user32.SetClipboardData(fmt, handle):
                        restored.append(fmt)
                    else:
                        kernel32.GlobalFree(handle)
            finally:
                api.CloseClipboard()
            items, _ = self.clipboard_snapshot()
            same = items is not None and {fmt: data for fmt, data in items if fmt in restored} == {fmt: data for fmt, data in self.clipboard_saved if fmt in restored}
            self.report["clipboard"]["restored_count"] = len(restored)
            self.report["clipboard"]["restored_identical"] = same and len(restored) == len(self.clipboard_saved)
            self.clipboard_saved = None
        except gui.GuiError as exc:
            self.report["clipboard"]["restore_error"] = str(exc)

    def pane_point(self, target, pane_hwnd, x_dip, y_dip):
        """A screen point inside the remote pane, in DIPs from its top-left (negative: from the right/bottom)."""
        rect = self.fresh(target, pane_hwnd, REMOTE_PANE_CLASS).rect
        return gui.resolve_point(x_dip, y_dip, rect, gui.win32().dpi(pane_hwnd) / 96)

    def case_copy(self, target, remote):
        if not self.claim_clipboard():
            self.record("mouse-selection-copy", "BLOCKED", reason="the clipboard holds a GDI-handle format this fixture cannot restore; pass --allow-clipboard-loss")
            return
        pane = self.focus_remote(target, remote.hwnd)
        api = gui.win32()
        sentinel = self.marker("clip_sentinel")
        api.set_clipboard_text(sentinel)
        keep = self.marker("keep")
        # An unfinished line: a copy that also delivered Ctrl+C would cancel it.
        target.type_text(f"echo {keep}")
        time.sleep(0.3)
        # Row 0 holds only the source marker; GX pads 10x8 DIP, so 12 DIP down is inside row 0.
        start = self.pane_point(target, pane.hwnd, 12, 12)
        end = self.pane_point(target, pane.hwnd, -14, 12)
        target.drag(start, end, steps=16)
        time.sleep(0.4)
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-remote-selection",
                     "远程窗格第 0 行的 GX_REMOTE_SOURCE 标记被鼠标拖选高亮，输入行仍是未执行的 echo GX_REMOTE_KEEP")
        target.press("ctrl+c")
        copied = wait(lambda: (text := api.clipboard_text()) not in (None, sentinel) and text, "the remote selection reaches the clipboard", 8)
        if copied.strip() != self.marker("source"):
            raise AssertionError(f"copied {copied!r}, expected the source marker {self.marker('source')!r}")
        time.sleep(0.3)
        target.type_text(">>keep.txt")
        target.press("enter")
        self.expect_lines("keep.txt", [keep], "a performed copy consumed Ctrl+C instead of cancelling the line", settle=0.3)
        self.record("mouse-selection-copy", copied=copied.strip(), drag={"start": start, "end": end},
                    binding="performable:ctrl+c=copy_to_clipboard")

    @staticmethod
    def new_popups(target, before):
        return [item for item in target.popups() if item.cls.startswith("GhosttyGxPopup") and item.hwnd not in before]

    def wait_dialog(self, target, before, title, label):
        """A new owned popup of the target whose window text is the dialog title (the shadow carries it)."""
        def found():
            return next((item for item in self.new_popups(target, before) if item.title == title), None)
        return wait(found, label, 10)

    def cancel_dialogs(self, target, before):
        """After a failure, answer a left-open owned dialog with its safe choice (Escape is Cancel)."""
        if not target.alive() or not self.new_popups(target, before):
            return
        try:
            gui.win32().activate(target.require_window().hwnd)
            target.press("escape")
            wait(lambda: not self.new_popups(target, before), "the left-open dialog closes", 3)
            self.report.setdefault("dialog_cleanup", []).append("escape")
        except (AssertionError, gui.GuiError) as exc:
            self.report.setdefault("dialog_cleanup", []).append(f"failed: {exc}")

    def case_paste(self, target, remote):
        before = {item.hwnd for item in target.popups()}
        try:
            self.paste_steps(target, remote)
        finally:
            self.cancel_dialogs(target, before)

    @staticmethod
    def local_time():
        return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]

    def case_safe_paste(self, target, remote):
        before = {item.hwnd for item in target.popups()}
        try:
            if not self.claim_clipboard():
                self.record("safe-paste-no-enter", "BLOCKED", reason="the clipboard holds a GDI-handle format this fixture cannot restore; pass --allow-clipboard-loss")
                return
            self.safe_paste_steps(target, remote)
        finally:
            self.cancel_dialogs(target, before)

    def safe_paste_steps(self, target, remote):
        """One safe line: no dialog, no Enter, and the paste binding's continuation
        must finish so that the next Enter reaches the source shell."""
        api = gui.win32()
        pane = self.focus_remote(target, remote.hwnd)
        timeline = []

        def mark(event):
            entry = {"event": event, "local_time": self.local_time()}
            try:
                entry["pane_flags"] = self.query(target, pane.hwnd, REMOTE_PANE_CLASS, 1)
                entry["pane_last_action"] = self.query(target, pane.hwnd, REMOTE_PANE_CLASS, 10)
                entry["pane_transaction"] = self.query(target, pane.hwnd, REMOTE_PANE_CLASS, 6)
            except (AssertionError, gui.GuiError) as exc:
                entry["query_error"] = str(exc)
            timeline.append(entry)
            self.report["safe_paste_timeline"] = timeline
            self.save()

        safe = self.marker("safe_paste")
        api.set_clipboard_text(f"echo {safe}>>safe-paste.txt")
        before = {item.hwnd for item in target.popups()}
        mark("before-ctrl-shift-v")
        target.press("ctrl+shift+v")
        mark("after-ctrl-shift-v")
        time.sleep(1.0)
        mark("settled-1s")
        if self.new_popups(target, before):
            raise AssertionError("a one-line paste asked for confirmation")
        if self.file_lines("safe-paste.txt") is not None:
            raise AssertionError("a one-line paste ran without Enter")
        target.ensure_foreground()
        mark("before-enter")
        target.press("enter")
        mark("after-enter")
        try:
            self.expect_lines("safe-paste.txt", [safe], "after a safe remote paste the next Enter reaches the shell")
        except AssertionError:
            mark("enter-not-delivered")
            self.capture(target, remote.hwnd, REMOTE_CLASS, "target-safe-paste-failure",
                         "失败现场：粘贴的单行停在远程提示符，Enter 未到达源端 shell")
            raise
        mark("result-file-matched")
        self.record("safe-paste-no-enter", marker=safe, timeline=timeline)
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-safe-paste",
                     "远程窗格中 echo GX_REMOTE_SAFE_PASTE…>>safe-paste.txt 只执行一次，执行后回到空提示符")

    def paste_steps(self, target, remote):
        if not self.claim_clipboard():
            self.record("protected-paste-no-enter", "BLOCKED", reason="the clipboard holds a GDI-handle format this fixture cannot restore; pass --allow-clipboard-loss")
            return
        api = gui.win32()
        self.safe_paste_steps(target, remote)
        self.focus_remote(target, remote.hwnd)
        first, second = self.marker("paste_1"), self.marker("paste_2")
        # LF only: Ghostty turns each newline into one Enter, so CRLF would add an empty command.
        api.set_clipboard_text(f"echo {first}>>paste.txt\necho {second}>>paste.txt")
        before = {item.hwnd for item in target.popups()}
        target.press("ctrl+shift+v")
        dialog = self.wait_dialog(target, before, UNSAFE_PASTE_TITLE, "the target asks before pasting multiline text")
        if self.file_lines("paste.txt") is not None:
            raise AssertionError("text reached the source before the confirmation was answered")
        time.sleep(0.3)
        # The default button is Cancel; Left moves to Paste Anyway.
        target.press("left")
        time.sleep(0.2)
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-paste-confirm",
                     "目标窗口上的 Warning: Potentially Unsafe Paste 对话框预览两行 echo，焦点在 Paste Anyway")
        target.press("enter")
        wait(lambda: not any(item.hwnd == dialog.hwnd for item in target.popups()), "the confirmation closes", 5)
        self.expect_lines("paste.txt", [first], "only the first pasted line ran", settle=1.5)
        # Nothing appended Enter: the second line still waits at the prompt.
        self.focus_remote(target, remote.hwnd)
        target.press("enter")
        self.expect_lines("paste.txt", [first, second], "the second pasted line was waiting at the prompt; the next Enter must reach the shell after a confirmed paste")
        cancel_1, cancel_2, after = self.marker("cancel_1"), self.marker("cancel_2"), self.marker("after_cancel")
        api.set_clipboard_text(f"echo {cancel_1}>>cancelled.txt\necho {cancel_2}>>cancelled.txt")
        before = {item.hwnd for item in target.popups()}
        target.press("ctrl+shift+v")
        dialog = self.wait_dialog(target, before, UNSAFE_PASTE_TITLE, "the target asks again")
        target.press("escape")
        wait(lambda: not any(item.hwnd == dialog.hwnd for item in target.popups()), "the cancelled confirmation closes", 5)
        time.sleep(1.0)
        if self.file_lines("cancelled.txt") is not None:
            raise AssertionError("a cancelled paste reached the source")
        self.focus_remote(target, remote.hwnd)
        target.type_text(f"echo {after}>>after-cancel.txt")
        target.press("enter")
        self.expect_lines("after-cancel.txt", [after], "a cancelled paste left the prompt empty")
        self.record("protected-paste-no-enter", dialog_title=dialog.title, pasted=[first, second], cancelled=[cancel_1, cancel_2])

    def case_ole(self, target, remote):
        if self.ole_source is None:
            self.record("same-privilege-ole-drop", "PENDING", reason="no --ole-source executable was supplied")
            return
        from gx_ole_fixture import OwnedDrag  # frozen helper: two-owner foreground and point guard
        source_exe = self.ole_source
        source_hash = sha256(source_exe)
        pane = self.focus_remote(target, remote.hwnd)
        target.type_text("echo ")
        work = self.out / "ole"
        work.mkdir()
        argv = [str(source_exe), "--run", f"--hwnd={pane.hwnd:#x}", f"--pid={target.pid}", f"--birth={target.creation}",
                f"--exe={self.exe}", f"--sha256={self.expected_hash}", f"--work-dir={work}", "--case=text",
                "--timeout-ms=7000", "--source-window"]
        process = None
        button_down = False
        drag = None
        with (work / "source.stdout.txt").open("xb") as stdout, (work / "source.stderr.txt").open("xb") as stderr:
            process = subprocess.Popen(argv, stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            birth = gui.win32().process_creation(process.pid)

            def ready():
                if process.poll() is not None:
                    raise AssertionError(f"OLE source exited before ready: {process.returncode}")
                return next(work.glob(f"gx-ole-{process.pid}-*/ready.json"), None)

            ready_path = wait(ready, "OLE source ready", 15)
            facts = json.loads(ready_path.read_text(encoding="utf-8"))
            if (facts.get("source_pid") != process.pid or facts.get("target_pid") != target.pid
                    or facts.get("target_birth") != target.creation or facts.get("target_hwnd") != pane.hwnd
                    or facts.get("app_sha256", "").lower() != self.expected_hash or not facts.get("source_hwnd")):
                raise AssertionError(f"OLE source ready facts do not match this fixture: {facts!r}")
            drag = OwnedDrag(target, self.exe, self.expected_hash, source_exe, source_hash, process, birth,
                             facts["source_hwnd"], self.fresh(target, pane.hwnd, REMOTE_PANE_CLASS))
            drag.activate_source()
            start = drag.start_point()
            end = self.pane_point(target, pane.hwnd, None, "60%")
            drag.mouse(*start, action="down")
            button_down = True
            for step in range(1, 17):
                drag.mouse(round(start[0] + (end[0] - start[0]) * step / 16), round(start[1] + (end[1] - start[1]) * step / 16))
                time.sleep(0.03)
            time.sleep(0.3)
            drag.mouse(*end, action="up", target_only=True)
            button_down = False
            process.wait(timeout=12)
            evidence = json.loads((ready_path.parent / "evidence.json").read_text(encoding="utf-8"))
            if process.returncode != 0:
                raise AssertionError(f"DoDragDrop source returned {process.returncode}: {evidence!r}")
        finally:
            if button_down and drag is not None and drag.last_point is not None:
                try:
                    drag.mouse(*drag.last_point, action="up")
                except gui.GuiError:
                    pass
            if process.poll() is None:
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    if gui.win32().process_creation(process.pid) == birth:
                        process.terminate()
                        process.wait(timeout=5)
        marker = f"GX_OLE_FIXTURE_{process.pid}"
        target.activate()
        self.focus_remote(target, remote.hwnd)
        target.type_text(">>ole.txt")
        target.press("enter")
        self.expect_lines("ole.txt", [marker], "the dropped text became an argument; no Enter was appended", settle=0.3)
        self.record("same-privilege-ole-drop", source=str(source_exe), source_sha256=source_hash, source_pid=process.pid,
                    effect=evidence.get("effect"), payload_bytes=evidence.get("payload_bytes"), marker=marker,
                    drag={"start": start, "end": end})
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-ole-dropped",
                     f"远程窗格里 echo {marker}>>ole.txt 作为一行执行，拖放没有提前回车")

    def ime_control(self, ime_window, command, value=0):
        result = gui.win32().send_message(ime_window, WM_IME_CONTROL, command, value, timeout_ms=2000)
        if result is None:
            raise AssertionError("the IME window did not answer WM_IME_CONTROL")
        return result

    def case_ime(self, target, remote):
        api = gui.win32()
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        user32.GetKeyboardLayoutList.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
        count = user32.GetKeyboardLayoutList(0, None)
        layouts = (ctypes.c_void_p * max(1, count))()
        count = user32.GetKeyboardLayoutList(count, layouts)
        installed = [int(layouts[index] or 0) & 0xFFFFFFFF for index in range(count)]
        chinese = next((value for value in installed if value & 0xFFFF == 0x0804), None)
        if chinese is None:
            self.record("ime-composition-commit", "BLOCKED", reason="no zh-CN input language is installed", layouts=[f"0x{v:08x}" for v in installed])
            return
        pane = self.focus_remote(target, remote.hwnd)
        if self.layout_saved is None:
            self.layout_saved = (target, remote.hwnd, api.keyboard_layout(remote.hwnd))
            self.report["input_language"] = {"before": f"0x{self.layout_saved[2]:08x}"}
        target.type_text("echo ")
        api.PostMessageW(api.focus_window(remote.hwnd), WM_INPUTLANGCHANGEREQUEST, 0, chinese)
        try:
            wait(lambda: api.keyboard_layout(remote.hwnd) == chinese, "the zh-CN input language", 3)
        except AssertionError:
            self.record("ime-composition-commit", "BLOCKED", reason="the owned target thread did not switch to zh-CN")
            return
        imm = ctypes.WinDLL("imm32", use_last_error=True)
        imm.ImmGetDefaultIMEWnd.argtypes = [wintypes.HWND]
        imm.ImmGetDefaultIMEWnd.restype = wintypes.HWND
        ime_window = imm.ImmGetDefaultIMEWnd(pane.hwnd)
        if not ime_window or api.window_pid(ime_window) != target.pid:
            self.record("ime-composition-commit", "BLOCKED", reason="no owned default IME window for the remote pane")
            return
        state = {"open": self.ime_control(ime_window, IMC_GETOPENSTATUS), "mode": self.ime_control(ime_window, IMC_GETCONVERSIONMODE)}
        try:
            self.ime_control(ime_window, IMC_SETOPENSTATUS, 1)
            self.ime_control(ime_window, IMC_SETCONVERSIONMODE, state["mode"] | IME_CMODE_NATIVE)
            time.sleep(0.2)
            for key in "nihao":
                target.press(key)
                time.sleep(0.08)
            time.sleep(0.6)
            self.capture(target, remote.hwnd, REMOTE_CLASS, "target-ime-composing",
                         "远程窗格光标处内联显示拼音组字（nihao 或候选），候选窗贴近光标")
            target.press("space")
            time.sleep(0.6)
        finally:
            try:
                self.ime_control(ime_window, IMC_SETCONVERSIONMODE, state["mode"])
                self.ime_control(ime_window, IMC_SETOPENSTATUS, state["open"])
            except AssertionError as exc:
                state["restore_error"] = str(exc)
            self.use_us_layout(target, remote.hwnd)
        target.type_text(">>ime.txt")
        target.press("enter")
        deadline = time.monotonic() + 10
        lines = self.file_lines("ime.txt")
        while lines is None and time.monotonic() < deadline:
            time.sleep(0.05)
            lines = self.file_lines("ime.txt")
        time.sleep(0.3)
        lines = self.file_lines("ime.txt")
        details = {"layout": f"0x{chinese:08x}", "ime_state_before": state, "lines": lines}
        if lines == ["你好"]:
            self.record("ime-composition-commit", **details)
        elif lines and all(line.isascii() for line in lines):
            self.record("ime-composition-commit", "BLOCKED", reason="the IME passed raw letters; its Chinese mode was not active", **details)
        else:
            raise AssertionError(f"IME commit did not reach the source shell as 你好: {details!r}")

    def session_document(self):
        path = self.environment / "state" / "ghostty" / "gx-session.json"
        try:
            text = path.read_text(encoding="utf-8")
            return text, json.loads(text)
        except (OSError, json.JSONDecodeError):
            return None, None

    def case_session(self, target, remote):
        """Only a launch-profile leaf is saved; the remote leaf and unknown-origin splits are pruned."""
        if not self.session_target:
            self.record("session-prunes-remote-leaf", "SKIPPED", reason="target started without --gx-session-restore=true")
            return
        target.activate()
        locals_ = self.local_terminals(target, remote.hwnd)
        if not locals_:
            raise AssertionError("the session case starts from the mixed tab's local leaf")
        # The profile binding must reach a target-local surface, never the remote source.
        api = gui.win32()
        target.mouse((locals_[0].rect[0] + locals_[0].rect[2]) // 2, (locals_[0].rect[1] + locals_[0].rect[3]) // 2)
        wait(lambda: api.focus_window(remote.hwnd) == locals_[0].hwnd, "focus on the target-local leaf", 2)
        children = self.command_children(target)
        launches = len(self.launches("target"))
        target.press("ctrl+alt+p")  # gx:new_tab_profile:custom:GXFixture records LaunchOrigin.profile
        wait(lambda: len(self.command_children(target)) == len(children) + 1, "the launch-profile tab starts its shell")
        wait(lambda: len(self.launches("target")) == launches + 1, "the launch-profile tab ran its script")
        wait(lambda: len(self.local_terminals(target, remote.hwnd)) == 1 and not self.remote_panes(target, remote.hwnd),
             "the profile tab is active")
        target.press("ctrl+shift+o")  # a plain split has no launch profile
        wait(lambda: len(self.command_children(target)) == len(children) + 2, "the profile tab split starts its shell")
        wait(lambda: len(self.local_terminals(target, remote.hwnd)) == 2, "the profile tab shows two leaves")
        # Tabs: the original (command, unknown origin), the mixed tab (remote +
        # unknown split) and this one (profile + unknown split).
        expected_skipped = 4

        def saved():
            text, document = self.session_document()
            if document is None:
                return None
            tabs = [tab for window in document.get("windows", []) for tab in window.get("tabs", [])]
            nodes = [node for tab in tabs for node in tab.get("nodes", [])]
            leaves = [node["leaf"] for node in nodes if node.get("leaf")]
            if (len(tabs) == 1 and len(nodes) == 1 and len(leaves) == 1 and leaves[0].get("profile_id") == SESSION_PROFILE
                    and document.get("skipped_leaves") == expected_skipped):
                return text, document
            return None

        try:
            text, document = wait(saved, "the session keeps only the profile leaf", 10)
        except AssertionError:
            text, document = self.session_document()
            if text is not None:
                (self.out / "session-snapshot.json").write_text(text, encoding="utf-8")
            raise AssertionError(f"session snapshot is not the pruned profile tab: {document!r}")
        (self.out / "session-snapshot.json").write_text(text, encoding="utf-8")
        if self.token in text:
            raise AssertionError("the saved session contains fixture terminal text or titles")
        self.record("session-prunes-remote-leaf", evidence="session-snapshot.json", skipped_leaves=document["skipped_leaves"],
                    saved_leaf=document["windows"][0]["tabs"][0]["nodes"][0]["leaf"], generation=document.get("generation"))
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-profile-tab",
                     "第三个标签：自定义 profile GXFixture 的终端与其普通分屏，均显示 GX_REMOTE_TARGET 标记")
        # GX defaults unbind alt+digit; the profile tab opened right after the
        # mixed tab (window-new-tab-position = current), so previous_tab returns.
        target.press("ctrl+pageup")
        wait(lambda: len(self.remote_panes(target, remote.hwnd)) == 1 and len(self.local_terminals(target, remote.hwnd)) == 1,
             "back on the mixed tab: one remote and one local leaf visible")

    def edge_colors(self, image, rect, scale):
        left, top, right, bottom = rect
        cx, cy = (left + right) // 2, (top + bottom) // 2
        inset = max(4, round(6 * scale))
        return {"top": image.pixel(cx, top), "bottom": image.pixel(cx, bottom - 1),
                "left": image.pixel(left, cy), "right": image.pixel(right - 1, cy),
                "inner_top": image.pixel(cx, top + inset), "inner_left": image.pixel(left + inset, cy)}

    @staticmethod
    def ringing(colors, baseline):
        edges = [colors[name] for name in ("top", "bottom", "left", "right")]
        uniform = all(gui.color_close(edges[0], edge, 12) for edge in edges)
        distinct = all(not gui.color_close(colors[name], baseline[name], 40) for name in ("top", "bottom", "left", "right"))
        apart = not gui.color_close(colors["top"], colors["inner_top"], 40) and not gui.color_close(colors["left"], colors["inner_left"], 40)
        return uniform and distinct and apart

    def case_bell(self, target, remote):
        panes = self.remote_panes(target, remote.hwnd)
        locals_ = self.local_terminals(target, remote.hwnd)
        if len(panes) != 1 or not locals_:
            raise AssertionError("the bell case needs the mixed tab: one remote pane beside a local leaf")
        pane = self.focus_remote(target, remote.hwnd)
        api = gui.win32()
        scale = api.dpi(pane.hwnd) / 96
        # The source shell sends BEL about two seconds later, from an isolated file.
        target.type_text("ping -n 3 127.0.0.1>nul&type bel.txt")
        target.press("enter")
        local = locals_[0]
        target.mouse((local.rect[0] + local.rect[2]) // 2, (local.rect[1] + local.rect[3]) // 2)
        wait(lambda: api.focus_window(remote.hwnd) == local.hwnd, "focus moves to the local leaf", 2)
        window = self.fresh(target, remote.hwnd, REMOTE_CLASS)
        rect = self.fresh(target, pane.hwnd, REMOTE_PANE_CLASS).rect
        baseline = self.edge_colors(target.capture_window(window, "screen"), rect, scale)
        deadline = time.monotonic() + 10
        ringing = None
        while time.monotonic() < deadline:
            image = target.capture_window(self.fresh(target, remote.hwnd, REMOTE_CLASS), "screen")
            colors = self.edge_colors(image, rect, scale)
            if self.ringing(colors, baseline):
                ringing = (image, colors)
                break
            time.sleep(0.1)
        if ringing is None:
            raise AssertionError(f"no bell border on all four remote edges after the delayed BEL: baseline {baseline!r}")
        ringing[0].save_png(self.out / "target-bell-border.png")
        self.report["captures"].append({"file": "target-bell-border.png", "method": "screen", "review": "PENDING",
                                        "expect": "焦点在右侧本地叶时，左侧远程窗格四边出现提示色细边框（来自远程 shell 的 BEL）",
                                        "window": asdict(window), "pid": target.pid, "birth": target.creation})
        self.save()
        if api.focus_window(remote.hwnd) != local.hwnd:
            raise AssertionError("the bell moved focus away from the local leaf")
        bell = {name: gui.color_hex(value) for name, value in ringing[1].items()}
        # Clicking the remote pane focuses it and clears the border.
        target.mouse(*self.pane_point(target, pane.hwnd, None, "70%"))
        wait(lambda: api.focus_window(remote.hwnd) == pane.hwnd, "focus returns to the remote pane", 2)

        def cleared():
            colors = self.edge_colors(target.capture_window(self.fresh(target, remote.hwnd, REMOTE_CLASS), "screen"), rect, scale)
            return colors if not any(gui.color_close(colors[name], ringing[1][name], 24) for name in ("top", "bottom", "left", "right")) else None

        after = wait(cleared, "the bell border clears on focus", 5)
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-bell-cleared", "点击远程窗格后其四边提示色边框消失，远程窗格有焦点")
        self.record("remote-bell-border", baseline={k: gui.color_hex(v) for k, v in baseline.items()}, ringing=bell,
                    cleared={k: gui.color_hex(v) for k, v in after.items()}, method="screen",
                    boundary="Pixel checks only locate the border; the screenshots still need reading.")

    # -- driver -------------------------------------------------------------------------

    def execute(self):
        source = self.start("source")
        if self.only == ["drag-threshold"]:
            self.case("drag-threshold", self.case_drag_threshold, source, source.require_window(), critical=True)
            return self.finish()
        target = self.start("target")
        if source.pid == target.pid or source.env_dir != target.env_dir:
            raise AssertionError("fixture does not have two processes in the same isolated domain")
        source_window = source.require_window()
        target_window = target.require_window()
        before = self.snapshot(source, source_window.hwnd, gui.WINDOW_CLASS)
        target_before = self.snapshot(target, target_window.hwnd, gui.WINDOW_CLASS)
        if not before["surface_id"] or not before["terminal_hwnd"] or not before["foreground_pid"]:
            raise AssertionError("source has no established core/HWND/foreground child")
        self.source_child = self.process_identity(before["foreground_pid"])
        if Path(self.source_child["exe"]).name.lower() != "cmd.exe":
            raise AssertionError("source foreground child is not the controlled cmd shell")
        self.source_children = self.command_children(source)
        self.target_children = self.command_children(target)
        if len(self.source_children) != 1 or len(self.target_children) != 1 or self.source_children[0] != self.source_child:
            raise AssertionError("each starting app must own exactly its one controlled cmd shell")
        self.record("two-independent-hosts", source=before, target=target_before, source_child=self.source_child,
                    source_cmd_children=self.source_children, target_cmd_children=self.target_children)
        self.capture(source, source_window.hwnd, gui.WINDOW_CLASS, "source-before", "迁移前源终端应有 " + self.marker("source"))

        remote, state = self.case("transfer", self.transfer, source, target, source_window, before, target_window, "",
                                  critical=True)
        self.same_process(self.source_child)
        if self.command_children(source) != self.source_children or self.command_children(target) != self.target_children:
            raise AssertionError("a cmd shell was replaced/created during migration")
        self.once("source")
        self.once("target")
        self.detect_hooks(target, remote.hwnd)
        self.record("source-host-survives-original-window", remote=state, original_surface_id=before["surface_id"],
                    child=self.source_child, layout=self.layout(target, remote.hwnd))
        self.capture(target, remote.hwnd, REMOTE_CLASS, "target-remote",
                     "目标远程视图应显示源标记 " + self.marker("source") + "；不是目标本地标记")
        if self.only:
            # Narrow diagnosis: transfer and its continuity checks above stay mandatory.
            probes = {"uia": ("remote-uia-external-mta", self.case_uia),
                      "input": ("remote-input-to-original-shell", self.case_input),
                      "performable": ("performable-fallback-without-selection", self.case_performable),
                      "once": ("activate-key-table-once", self.case_once),
                      "table": ("persistent-key-table", self.case_table),
                      "perf-input": ("perf-input", self.case_perf_input),
                      "copy": ("mouse-selection-copy", self.case_copy),
                      "paste": ("safe-paste-no-enter", self.case_safe_paste)}
            for name in self.only:
                label, function = probes[name]
                self.case(label, function, target, remote)
            return self.finish()
        self.case("remote-input-to-original-shell", self.case_input, target, remote, critical=True)
        self.case("remote-uia-external-mta", self.case_uia, target, remote, optional="uia")
        self.case("performable-fallback-without-selection", self.case_performable, target, remote, optional="performable")
        self.case("activate-key-table-once", self.case_once, target, remote, optional="once")
        self.case("persistent-key-table", self.case_table, target, remote)
        self.case("mouse-selection-copy", self.case_copy, target, remote, optional="copy")
        self.case("protected-paste-no-enter", self.case_paste, target, remote, optional="paste")
        self.case("same-privilege-ole-drop", self.case_ole, target, remote, optional="ole")
        self.case("ime-composition-commit", self.case_ime, target, remote, optional="ime")
        if "dragback" not in self.skip:
            restored_window = self.case("dragback-returns-original-tab", self.case_dragback, source, target, remote, before,
                                        critical=True)
            self.case("dragback-local-input", self.case_dragback_input, source, restored_window, before)
            remote, state = self.case("retransfer", self.transfer, source, target, restored_window, before, target_window,
                                      "retransfer/", critical=True)
            self.record("retransfer-into-existing-target", remote=state, layout=self.layout(target, remote.hwnd))
            self.capture(target, remote.hwnd, REMOTE_CLASS, "target-retransferred",
                         "再次迁移后目标窗口仍显示同一源终端内容，之前的输入还在")
        else:
            self.record("dragback-returns-original-tab", "SKIPPED", reason="--skip dragback")
        self.case("chained-new-split-continuation", self.case_chain, target, remote, critical=True)
        if self.split_stress:
            self.case("split-resize-stress", self.case_split_stress, target, remote, before, self.split_stress,
                      critical=True)
        self.case("remote-bell-border", self.case_bell, target, remote, optional="bell")
        self.case("mixed-tab-transfer-rejected", self.case_mixed, source, target, remote, optional="mixed")
        self.case("session-prunes-remote-leaf", self.case_session, target, remote, optional="session", critical=True)
        if self.end == "source-loss":
            self.case("source-loss-unavailable", self.case_source_loss, source, target, remote, critical=True)
        else:
            self.case("original-core-recovered-without-command-replay", self.case_target_loss, source, target, before,
                      remote, critical=True)
        return self.finish()

    def finish(self):
        self.check_build()
        failed = [item["name"] for item in self.report["cases"] if item["status"] == "FAIL"]
        blocked = [item["name"] for item in self.report["cases"] if item["status"] == "BLOCKED"]
        self.report["native_checks"] = "FAIL" if failed else ("PARTIAL" if blocked else "PASS")
        self.report["status"] = "FAIL" if failed else ("BLOCKED_PARTIAL" if blocked else "PASS_NATIVE_VISUAL_PENDING")
        return 1 if failed else (2 if blocked else 0)

    def run(self):
        result = 0
        try:
            result = self.execute()
        except Blocked as exc:
            self.record("blocked", "BLOCKED", reason=str(exc))
            self.report["status"] = "BLOCKED"
            result = 2
        except CaseAbort as exc:
            self.report["status"] = "FAIL"
            self.report["aborted_after"] = str(exc)
            result = 1
        except gui.InputBlocked as exc:
            exited = self.exited_processes()
            if exited:
                self.record("unexpected-owned-app-exit", "FAIL", reason=str(exc), processes=exited,
                            boundary="An expected-live app exited before cleanup; this is not an environment BLOCKED result.")
                self.report["status"] = "FAIL"
                result = 1
            else:
                self.record("blocked", "BLOCKED", reason=str(exc))
                self.report["status"] = "BLOCKED"
                result = 2
        except Exception as exc:
            self.record("failure", "FAIL", reason=str(exc), traceback=traceback.format_exc())
            self.report["status"] = "FAIL"
            result = 1
        finally:
            try:
                self.restore_layout()
                self.restore_clipboard()
                self.diagnostics("before-cleanup")
            except Exception as exc:
                self.report.setdefault("diagnostic_errors", []).append({"stage": "before-cleanup", "reason": str(exc)})
            # Closing the target first lets the real source recovery run even
            # after a failed assertion. No unknown process or stale PID is killed.
            for instance in reversed(self.owned):
                try:
                    if instance.alive():
                        how = instance.close()
                        self.report["cleanup"].append({"pid": instance.pid, "birth": instance.creation, "result": how})
                        if how == "terminated":
                            self.report["status"] = "FAIL"
                            result = 1
                except Exception as exc:
                    self.report["cleanup"].append({"pid": instance.pid, "status": "FAIL", "reason": str(exc)})
                    self.report["status"] = "FAIL"
                    result = 1
            for role, tracked in self.processes.items():
                process = tracked["process"]
                if tracked["instance"] is None and process.poll() is None:
                    # Even if the native birth query failed during startup, this
                    # Popen handle belongs to the exact process we created.
                    try:
                        process.terminate()
                        process.wait(timeout=5)
                        self.report["cleanup"].append({"role": role, "pid": process.pid,
                                                        "result": "terminated-owned-launcher-after-birth-query-failure"})
                    except Exception as exc:
                        self.report["cleanup"].append({"role": role, "pid": process.pid, "status": "FAIL", "reason": str(exc)})
                    self.report["status"] = "FAIL"
                    result = 1
            # A fixture-initiated close must end the app cleanly. An access
            # violation (0xC0000005) or any other code is a product failure.
            shutdown = []
            for role, tracked in self.processes.items():
                if role in self.expected_exit:
                    continue
                process = tracked["process"]
                try:
                    code = process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    code = None
                shutdown.append({"role": role, "pid": process.pid, "exit_code": code,
                                 "exit_code_hex32": None if code is None else f"0x{code & 0xffffffff:08x}"})
            if shutdown:
                clean = all(item["exit_code"] == 0 for item in shutdown)
                self.report["cases"].append({"name": "clean-shutdown-on-close", "status": "PASS" if clean else "FAIL",
                                             "processes": shutdown})
                if not clean:
                    self.report["status"] = "FAIL"
                    result = 1
            try:
                self.diagnostics("after-cleanup")
            except Exception as exc:
                self.report.setdefault("diagnostic_errors", []).append({"stage": "after-cleanup", "reason": str(exc)})
            self.save()
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--desktop-held", action="store_true", help="caller already holds Invoke-Desktop")
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--out", required=True, type=Path, help="new unused evidence directory")
    parser.add_argument("--build", required=True, help="build label recorded with the hash")
    parser.add_argument("--capture", choices=("auto", "screen", "print", "none"), default="auto",
                        help="none: native checks only (failures still capture); for stress repetitions")
    parser.add_argument("--split-stress", type=int, default=0, metavar="N",
                        help="after the chained split, N rounds of remote new_split, closing it and a window resize")
    parser.add_argument("--end", choices=("source-loss", "target-loss"), default="source-loss",
                        help="which peer to terminate last (only one can be lost per run)")
    parser.add_argument("--skip", action="append", choices=OPTIONAL_CASES, help="skip an optional case (repeatable)")
    parser.add_argument("--rehearsal", action="store_true", help="label the evidence as a rehearsal, never acceptance")
    parser.add_argument("--ole-source", type=Path, help="built test/windows/gx_ole_source.zig executable for the real OLE drag")
    parser.add_argument("--only", action="append", choices=("uia", "input", "performable", "once", "table", "perf-input", "drag-threshold"),
                        help="after the mandatory transfer run only these probes, in order, then close both apps (repeatable)")
    parser.add_argument("--perf-count", type=int, default=50)
    parser.add_argument("--perf-interval-ms", type=int, default=200)
    parser.add_argument("--allow-clipboard-loss", action="store_true",
                        help="run clipboard cases even when non-text clipboard data cannot be restored")
    args = parser.parse_args(argv)
    if args.only and "drag-threshold" in args.only and args.only != ["drag-threshold"]:
        parser.error("drag-threshold uses an independent local fixture; run it separately")
    if args.allow_clipboard_loss:
        parser.error("r6 forbids reading or replacing an unknown user clipboard")
    if not 1 <= args.perf_count <= 10000 or not 10 <= args.perf_interval_ms <= 10000:
        parser.error("perf-count must be 1..10000; perf-interval-ms must be 10..10000")
    if args.split_stress < 0:
        parser.error("--split-stress must be >= 0")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", args.sha256):
        parser.error("--sha256 must be a complete frozen-build digest")
    if os.name != "nt":
        parser.error("requires Windows")
    try:
        with fixture_slots(ROOT, args.desktop_held):
            fixture = Fixture(args)
            result = fixture.run()
            print(json.dumps({"status": fixture.report["status"], "report": str(fixture.out / "report.json")}, ensure_ascii=False))
            return result
    except (OSError, Blocked, TimeoutError) as exc:
        print(json.dumps({"status": "BLOCKED", "reason": str(exc)}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
