"""Owned popup UIA/DComp evidence, with exact build and process identity guards.

Uses gx_win_gui isolation and input guards, and gx_win_uia's external MTA worker.
Never changes clipboard, system settings, or the user's configuration. Screenshots
always require human review; PrintWindow cannot establish GL/DComp screen output.
Only run after the coordinator freezes the executable and supplies its SHA-256.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_slots  # noqa: E402
import gx_win_gui as gui  # noqa: E402
from gx_fixture_evidence import native_snapshot, write_review, fixture_slots, source_manifest

WM_POPUP_DCOMP = 0x400 + 0x4E
POPUP_CLASSES = {"GhosttyGxPopup", "GhosttyGxPopupShadow"}
CONFIG = """language = en
confirm-close-surface = false
gx-open-config-ui = settings
command = cmd.exe /d /k prompt $G$S
"""
POPUPS = (
    ("menu", "ctrl+shift+m", ("invoke",)),
    ("palette", "ctrl+shift+p", ("value", "selection")),
    ("settings", "ctrl+comma", ("selection", "selection_item")),
)
PHASES = {0: "reset", 1: "target", 2: "surface", 3: "begin", 4: "end", 5: "commit"}
# UIA-01 dynamic focus (needs A1 0002): the owned shell's prompt asks to WRITE a
# marker to the clipboard (OSC 52, ST-terminated via cmd's $E), which opens the
# clipboard dialog with its "Remember choice" check box. The fixture only ever
# answers Deny (also the default button): the clipboard is never read or written.
CLIPBOARD_MARKER = "GX_UIA_01_FOCUS"
DIALOG_CONFIG = CONFIG.replace("command = cmd.exe /d /k prompt $G$S",
                               "clipboard-write = ask\ncommand = cmd.exe /d /k prompt $E]52;c;R1hfVUlBXzAxX0ZPQ1VT$E\\$G$S")
# UIA-05 (D-29): a terminal split on a chord the fixture checks no other
# program holds as a global hotkey.
SPLIT_CHORD = "ctrl+alt+shift+d"
TERMINAL_CONFIG = CONFIG + f"keybind = {SPLIT_CHORD}=new_split:right\n"
TERMINAL_CLASS = "GhosttyTerminal"
UIA_PANE, UIA_EDIT, UIA_LIST_ITEM, UIA_LIST, UIA_MENU_ITEM = 50033, 50004, 50007, 50008, 50011
ELEMENT_SELECTED = 20012


def focusable(nodes, **pattern):
    return [node for node in nodes if node.get("focusable") is True and node.get("enabled") is True
            and all(node.get("patterns", {}).get(name) is value for name, value in pattern.items())]


def palette_focus_rows(nodes, value):
    """The client focuses Search, then calls Value.SetValue on the same element
    it held before the focus call (UIA-01's original 0x80040201)."""
    search = next(iter(focusable(nodes, value=True)), None)
    if search is None:
        raise AssertionError("palette exposes no focusable Value element")
    return [{"automation_id": search["automation_id"], "pattern": "element", "operation": "set_focus",
             "expect_focus": True, "expect_focused_element": True},
            {"automation_id": search["automation_id"], "pattern": "value", "operation": "set", "value": value}]


def menu_focus_rows(nodes):
    """The focus moves New Tab -> Split; New Tab, held since before both moves,
    reports no focus and still accepts Invoke (one new tab). A menu popup never
    has the Win32 focus, so GetFocusedElement and events are not asserted here."""
    items = {node["name"]: node for node in focusable(nodes)}
    first, second = items.get("New Tab"), items.get("Split")
    if first is None or second is None or first["patterns"].get("invoke") is not True:
        raise AssertionError("menu lacks focusable New Tab (Invoke) and Split items")
    return [{"automation_id": first["automation_id"], "pattern": "element", "operation": "set_focus", "expect_focus": True},
            {"automation_id": second["automation_id"], "pattern": "element", "operation": "set_focus", "expect_focus": True},
            {"automation_id": first["automation_id"], "pattern": "element", "operation": "check_focus", "expect_focus": False},
            {"automation_id": first["automation_id"], "pattern": "invoke", "operation": "invoke"}]


def dialog_focus_rows(nodes):
    """The focus moves Deny -> the check box with HasKeyboardFocus,
    GetFocusedElement and a FocusChanged event; Deny, held since before, reports
    no focus; the check box held since before still toggles. Deny itself is
    invoked afterwards on a fresh element: the toggle changes the dialog model."""
    check = next(iter(focusable(nodes, toggle=True)), None)
    deny = next((node for node in focusable(nodes, invoke=True) if node["name"] == "Deny"), None)
    if check is None or deny is None:
        raise AssertionError("clipboard dialog lacks a focusable check box and Deny button")
    return [{"automation_id": deny["automation_id"], "pattern": "element", "operation": "set_focus", "expect_focus": True},
            {"automation_id": check["automation_id"], "pattern": "element", "operation": "set_focus", "expect_focus": True,
             "expect_focused_element": True, "expect_focus_event": True},
            {"automation_id": deny["automation_id"], "pattern": "element", "operation": "check_focus", "expect_focus": False},
            {"automation_id": check["automation_id"], "pattern": "toggle", "operation": "toggle"}]


def terminal_root_facts(root, hwnd, language="Terminal"):
    """D-29: the root of a terminal HWND's own provider is the named pane
    (UIA-05); returns the failed facts, empty when all hold."""
    facts = {"control_type": root.get("control_type") == UIA_PANE, "named": bool(root.get("name")),
             "localized_type": root.get("localized_type") == language,
             "automation_id": str(root.get("automation_id", "")).startswith("gx-terminal-"),
             "native_window_handle": (root.get("native_window_handle") or 0) & 0xFFFFFFFF == hwnd & 0xFFFFFFFF}
    return [name for name, holds in facts.items() if not holds]


def terminal_elements(nodes):
    """The terminal elements of a window's tree (their own HWND providers)."""
    return [node for node in nodes if str(node.get("automation_id", "")).startswith("gx-terminal-")]


def duplicate_panes(nodes):
    """Window fragment nodes that repeat a terminal as an unnamed-HWND twin
    (D-29): a pane with a terminal's name that is not that terminal."""
    names = {node.get("name") for node in terminal_elements(nodes)}
    return [node for node in nodes if node.get("control_type") == UIA_PANE and node.get("name") in names
            and node not in terminal_elements(nodes)]


def next_after_focus(nodes, control_type):
    """The focused element of `control_type` and the next one in tree order."""
    items = [node for node in nodes if node.get("control_type") == control_type and node.get("focusable")]
    index = next((i for i, node in enumerate(items) if node.get("focused")), None)
    if index is None or index + 1 >= len(items):
        return None, None
    return items[index], items[index + 1]


def next_after_selection(nodes):
    """The selected list item and the next one in tree order."""
    rows = [node for node in nodes if node.get("control_type") == UIA_LIST_ITEM and node.get("patterns", {}).get("selection_item")]
    index = next((i for i, node in enumerate(rows) if node.get("selected")), None)
    if index is None or index + 1 >= len(rows):
        return None, None
    return rows[index], rows[index + 1]


def later_events(events, **match):
    """Events recorded after the worker's ready file whose fields all match."""
    return [event for event in events if event.get("after_ready") and all(event.get(key) == value for key, value in match.items())]


def choose_popup(windows):
    return next((window for window in windows if window.cls in POPUP_CLASSES), None)


class Blocked(RuntimeError):
    pass


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def status_bits(value: int) -> dict:
    return {"raw": value, "opted_in": bool(value & 1), "native": bool(value & 2),
            "current_frame": bool(value & 4), "warp": bool(value & 8), "legacy_fallback": bool(value & 16)}


def wait(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("bounded popup transition timed out")


class Fixture:
    def __init__(self, args):
        self.exe = args.exe.resolve(strict=True)
        self.out = args.out.resolve()
        self.expected_hash = args.sha256.lower()
        self.method = args.capture
        self.readonly_root = args.readonly_root
        self.actions = args.actions
        self.focus_checks = args.focus_checks
        self.terminal_checks = args.terminal_checks
        self.event_checks = args.event_checks
        self.modes = ("off", "on") if args.mode == "both" else (args.mode,)
        self.owned = []
        self.check_build()
        self.out.mkdir(parents=True, exist_ok=False)
        self.report = {
            "status": "PENDING", "app_sha256": self.expected_hash, "exe": str(self.exe),
            "app_mtime_ns": self.exe.stat().st_mtime_ns, "build_label": args.build,
            "tree_boundary": "Caller-supplied build hash; current source files do not prove build inputs.",
            "capture_method": self.method, "visual_review": "PENDING", "cases": [],
            "scope": "root/window/pane external MTA only" if self.readonly_root else "popup UIA and DComp",
            "processes": [], "captures": [], "cleanup": [],
            "fixture_sources": source_manifest(),
            "limits": ["No screen reader product certification or notification receipt test.",
                       "No physical device removal, Win10 compatibility, or performance claim.",
                       "Fault injection tests the native popup failure path, not terminal GPU reset.",
                       "PrintWindow is diagnostic only and cannot establish GL/DComp on-screen output."],
        }
        self.save()

    def check_build(self):
        if sha256(self.exe) != self.expected_hash:
            raise Blocked("executable SHA-256 differs from the coordinator's frozen build")

    def save(self):
        (self.out / "report.json").write_text(json.dumps(self.report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        lines = ["# Popup UIA / DComp 截图复核", "", "每张图需逐一打开后填写结论；文件存在和脚本成功均不代表读图通过。", ""]
        for item in self.report["captures"]:
            lines.append(f'- [ ] [{item["file"]}]({item["file"]})：{item["expect"]}；方式 {item["method"]}；PENDING')
        if self.method == "print":
            lines += ["", "PrintWindow 只能诊断局部绘制，不能证明 OpenGL 或 DirectComposition 已上屏；视觉验收仍 PENDING。"]
        (self.out / "visual-review.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def record(self, name, status, **details):
        self.report["cases"].append({"name": name, "status": status, **details})
        self.save()

    def start(self, mode, *, activate=True, config=CONFIG, variant=""):
        self.check_build()
        env_dir = (self.out / f"env-{mode}{variant}").resolve()
        gui.prepare_env_dir(env_dir, False)
        # The off case leaves the variable absent, verifying the default.
        extra = {"GHOSTTY_GX_REMOTE_TEST": "1"}
        if mode == "on":
            extra["GHOSTTY_GX_POPUP_DCOMP"] = "1"
        instance = gui.launch(self.exe, env_dir, config=config, env=extra)
        self.owned.append(instance)
        instance.ensure_owned()
        instance.save()
        self.report["processes"].append({"pid": instance.pid, "birth": instance.creation,
                                         "exe": instance.exe, "environment": str(env_dir), "mode": mode})
        self.save()
        instance.wait_window(20)
        instance.remember_children()
        instance.save()
        if activate:
            instance.activate()
            instance.ensure_foreground()
        renderer = instance.wait_log(r"loaded OpenGL [0-9]", 10)
        self.record(f"{mode}/startup", "PASS", renderer=renderer,
                    windows=[asdict(item) for item in instance.windows()])
        return instance

    @staticmethod
    def fresh_popup(instance, hwnd):
        instance.ensure_owned()
        if gui.win32().window_pid(hwnd) != instance.pid:
            raise gui.InputBlocked("popup HWND no longer belongs to the fixture process")
        found = next((item for item in instance.popups() if item.hwnd == hwnd and item.cls in POPUP_CLASSES), None)
        if found is None:
            raise gui.InputBlocked("expected popup is no longer visible and uncloaked")
        return found

    @staticmethod
    def fresh_root(instance, hwnd):
        instance.ensure_owned()
        if gui.win32().window_pid(hwnd) != instance.pid:
            raise gui.InputBlocked("root HWND no longer belongs to the fixture process")
        found = next((item for item in instance.windows() if item.hwnd == hwnd and item.cls == gui.WINDOW_CLASS
                      and item.visible and not item.cloaked), None)
        if found is None:
            raise gui.InputBlocked("expected root window is no longer present")
        return found

    def capture(self, instance, hwnd, name, expect):
        instance.ensure_foreground()
        popup = self.fresh_popup(instance, hwnd)
        path = self.out / f"{name}.png"
        instance.capture_window(popup, self.method).save_png(path)
        self.fresh_popup(instance, hwnd)
        self.report["captures"].append({"file": path.name, "method": self.method, "review": "PENDING",
                                         "expect": expect, "pid": instance.pid, "birth": instance.creation,
                                         "window": asdict(popup), "eligible_for_screen_review": self.method == "screen"})
        self.save()

    def native_status(self, instance, hwnd, phase=None):
        instance.ensure_foreground()
        self.fresh_popup(instance, hwnd)
        value = gui.win32().send_message(hwnd, WM_POPUP_DCOMP, int(phase is not None), phase or 0, timeout_ms=5000)
        if value is None:
            raise AssertionError("owned popup DComp query/reset timed out")
        self.fresh_popup(instance, hwnd)
        return status_bits(value)

    @staticmethod
    def require_native(status):
        if not (status["opted_in"] and status["native"] and status["current_frame"] and not status["legacy_fallback"]):
            raise Blocked(f"native DComp frame unavailable: {status}")

    def uia(self, instance, hwnd, name, required_patterns, *, root=False):
        fresh = self.fresh_root if root else self.fresh_popup
        fresh(instance, hwnd)
        # Run the worker directly: this fixture owns the single MTA subprocess
        # and subprocess.run kills/waits that exact worker on timeout.
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker",
                   "--hwnd", str(hwnd), "--pid", str(instance.pid), "--birth", str(instance.creation),
                   "--exe", str(self.exe), "--timeout", "15", "--max-nodes", "512", "--max-depth", "12"]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=15)
        evidence = {"command": command, "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
        path = self.out / f"{name}-uia.json"
        path.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        fresh(instance, hwnd)
        if result.returncode != 0:
            raise AssertionError(f"external MTA UIA probe failed: {path.name}")
        probe = json.loads(result.stdout)
        if probe.get("status") != "PASS" or probe.get("apartment") != "MTA" or probe.get("created_hwnd") is not False:
            raise AssertionError("probe did not confirm the external windowless MTA contract")
        nodes = probe.get("nodes", [])
        if probe.get("truncated") or len(nodes) < 2:
            raise AssertionError("UIA snapshot is empty or truncated")
        custom_nodes = [node for node in nodes if str(node.get("automation_id", "")).startswith("gx-")]
        if len(custom_nodes) < 2:
            raise AssertionError("UIA tree has no custom GX children; native fallback is not sufficient")
        for pattern in required_patterns:
            if not any(node.get("patterns", {}).get(pattern) is True for node in custom_nodes):
                raise AssertionError(f"popup does not expose required {pattern} pattern")
        self.record(name + "/external-MTA", "PASS", evidence=path.name, nodes=len(nodes), custom_nodes=len(custom_nodes), required_patterns=required_patterns)
        return probe

    def pattern_call(self, instance, popup, node, pattern, operation, value=None):
        """One real COM action on the exact id observed in this popup epoch."""
        name = f"action-{len(self.report['cases'])}-{pattern}-{operation}"
        action = {"automation_id": node["automation_id"], "pattern": pattern, "operation": operation}
        if value is not None:
            action["value"] = value
        plan = self.out / (name + ".plan.json")
        plan.write_text(json.dumps([action]), encoding="utf-8")
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--hwnd", str(popup.hwnd),
                   "--pid", str(instance.pid), "--birth", str(instance.creation), "--exe", str(self.exe),
                   "--sha256", self.expected_hash, "--max-nodes", "512", "--action-plan", str(plan)]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=15)
        path = self.out / (name + ".json")
        path.write_text(json.dumps({"command": command, "exit_code": result.returncode,
                                   "stdout": result.stdout, "stderr": result.stderr}, indent=2), encoding="utf-8")
        if result.returncode != 0:
            raise AssertionError(f"external pattern action failed: {path.name}")
        observation = json.loads(result.stdout)
        assert len(observation["actions"]) == 1
        self.record(name, "PASS", case_id="UIA-01", native=observation, boundary="COM action accepted; resulting UI separately reviewed")

    def focus_plan(self, instance, popup, name, rows):
        """One external MTA worker holds every target from one enumeration, moves
        the focus, then acts on the elements it already holds (UIA-01)."""
        plan = self.out / (name + ".plan.json")
        plan.write_text(json.dumps(rows), encoding="utf-8")
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--hwnd", str(popup.hwnd),
                   "--pid", str(instance.pid), "--birth", str(instance.creation), "--exe", str(self.exe),
                   "--sha256", self.expected_hash, "--max-nodes", "512", "--timeout", "20", "--action-plan", str(plan)]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=25)
        path = self.out / (name + ".json")
        path.write_text(json.dumps({"command": command, "exit_code": result.returncode,
                                   "stdout": result.stdout, "stderr": result.stderr}, indent=2), encoding="utf-8")
        if result.returncode != 0:
            raise AssertionError(f"dynamic focus sequence failed: {path.name}")
        observation = json.loads(result.stdout)
        if len(observation["actions"]) != len(rows):
            raise AssertionError(f"dynamic focus sequence ran {len(observation['actions'])} of {len(rows)} actions")
        self.record(name, "PASS", case_id="UIA-01", native=observation,
                    boundary="focus moved; elements held from before the move still answer and act")
        return observation

    def focus_menu(self, instance, mode):
        root = instance.require_window()
        before = gui.win32().send_message(root.hwnd, 0x450, 12, 0, timeout_ms=2000)
        assert before and before < 64
        instance.ensure_foreground()
        opened = {item.hwnd for item in instance.popups()}
        instance.press("ctrl+shift+m")
        menu = wait(lambda: next((item for item in instance.popups() if item.hwnd not in opened and item.cls in POPUP_CLASSES), None))
        time.sleep(0.4)
        probe = self.uia(instance, menu.hwnd, mode + "-focus-menu", ("invoke",))
        self.focus_plan(instance, self.fresh_popup(instance, menu.hwnd), mode + "-focus-menu-sequence", menu_focus_rows(probe["nodes"]))
        wait(lambda: gui.win32().send_message(root.hwnd, 0x450, 12, 0, timeout_ms=2000) == before + 1)
        wait(lambda: not any(item.hwnd == menu.hwnd for item in instance.popups()))
        image = mode + "-focus-menu-invoked.png"
        instance.ensure_foreground()
        instance.capture_window(instance.require_window(), self.method).save_png(self.out / image)
        self.report["captures"].append({"file": image, "method": self.method, "review": "PENDING_REVIEW",
                                         "expect": "焦点在 New Tab 与 Split 间移动后，此前保留的 New Tab 元素 Invoke 新增一标签"})
        self.save()

    def focus_dialog(self, mode):
        instance = self.start(mode, config=DIALOG_CONFIG, variant="-dialog")
        dialog = wait(lambda: choose_popup(instance.popups()), 15)
        time.sleep(0.4)
        dialog = self.fresh_popup(instance, dialog.hwnd)
        self.capture(instance, dialog.hwnd, mode + "-focus-dialog", f"剪贴板写入询问对话框，预览 {CLIPBOARD_MARKER}，有记住选择复选框")
        probe = self.uia(instance, dialog.hwnd, mode + "-focus-dialog", ("toggle", "invoke"))
        before = next(node for node in focusable(probe["nodes"], toggle=True))
        self.focus_plan(instance, dialog, mode + "-focus-dialog-sequence", dialog_focus_rows(probe["nodes"]))
        after = self.uia(instance, dialog.hwnd, mode + "-focus-dialog-after-toggle", ("toggle", "invoke"))
        toggled = next(node for node in focusable(after["nodes"], toggle=True))
        if toggled["toggle_state"] == before["toggle_state"]:
            raise AssertionError("Toggle on the check box held since before the focus moves did not reach the dialog")
        self.capture(instance, dialog.hwnd, mode + "-focus-dialog-toggled", "复选框已勾选，焦点环在复选框上")
        deny = next(node for node in focusable(after["nodes"], invoke=True) if node["name"] == "Deny")
        self.pattern_call(instance, dialog, deny, "invoke", "invoke")
        wait(lambda: not any(item.hwnd == dialog.hwnd for item in instance.popups()))
        self.record(mode + "-focus-dialog/denied", "PASS", case_id="UIA-01", clipboard="denied by Invoke(Deny); never written")
        self.report["cleanup"].append({"pid": instance.pid, "birth": instance.creation, "result": instance.close()})
        self.save()

    def stale_palette(self, instance, mode):
        instance.press("ctrl+shift+p")
        popup = wait(lambda: choose_popup(instance.popups()))
        name = mode + "-stale-palette"
        plan, ready, proceed = (self.out / (name + suffix) for suffix in (".plan.json", ".ready.json", ".continue"))
        plan.write_text(json.dumps([{"name": "Search", "pattern": "value", "operation": "set",
                                    "value": "STALE_MUST_NOT_APPEAR", "after_signal": True, "expect_unavailable": True}]), encoding="utf-8")
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--hwnd", str(popup.hwnd),
                   "--pid", str(instance.pid), "--birth", str(instance.creation), "--exe", str(self.exe),
                   "--sha256", self.expected_hash, "--action-plan", str(plan), "--ready-file", str(ready),
                   "--continue-file", str(proceed), "--listen-ms", "10000", "--timeout", "15"]
        with (self.out / (name + ".stdout.json")).open("w", encoding="utf-8") as stdout, (self.out / (name + ".stderr.txt")).open("w", encoding="utf-8") as stderr:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
            try:
                wait(lambda: ready.exists() or process.poll() is not None)
                assert process.poll() is None, "MTA retention worker exited before ready"
                instance.press("escape")
                wait(lambda: not any(w.hwnd == popup.hwnd for w in instance.popups()))
                instance.press("ctrl+shift+p")
                replacement = wait(lambda: choose_popup(instance.popups()))
                instance.ensure_foreground()
                proceed.write_text("transition completed\n", encoding="utf-8")
                assert process.wait(timeout=15) == 0, "old provider did not become unavailable"
                self.capture(instance, replacement.hwnd, name, "重新打开的面板不出现 STALE_MUST_NOT_APPEAR")
                self.record(name, "PASS", case_id="UIA-02", old_hwnd=popup.hwnd, new_hwnd=replacement.hwnd,
                            identity=native_snapshot(instance), worker=name + ".stdout.json")
                write_review(self.out, "UIA-02-" + mode, "R5-03 hide/reopen old provider inert", "host", "PASS", [name + ".png"])
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
        instance.press("escape")

    def root_actions(self, instance, mode):
        root = instance.require_window()
        probe = self.uia(instance, root.hwnd, mode + "-root-before-action", ("invoke", "selection_item"), root=True)
        node = next(n for n in probe["nodes"] if n["name"] == "New Tab" and n["patterns"].get("invoke"))
        before = gui.win32().send_message(root.hwnd, 0x450, 12, 0, timeout_ms=2000)
        assert before and before < 64
        self.pattern_call(instance, root, node, "invoke", "invoke")
        wait(lambda: gui.win32().send_message(root.hwnd, 0x450, 12, 0, timeout_ms=2000) == before + 1)
        probe = self.uia(instance, root.hwnd, mode + "-root-after-invoke", ("selection_item",), root=True)
        node = next(n for n in probe["nodes"] if n["control_type"] == 50019 and n["patterns"].get("selection_item"))
        self.pattern_call(instance, root, node, "selection_item", "select")
        image = mode + "-root-actions.png"
        instance.ensure_foreground()
        instance.capture_window(root, self.method).save_png(self.out / image)
        self.report["captures"].append({"file": image, "method": self.method, "expect": "UIA Invoke 新增一标签，SelectionItem 切回首标签", "review": "PENDING_REVIEW"})
        write_review(self.out, "UIA-01-root-" + mode, "R5-03 actual Invoke/SelectionItem", "host", "PASS", [image], identity=native_snapshot(instance))

    def fault_phases(self, instance, hwnd):
        for phase, label in PHASES.items():
            # Every failure begins from a verified current native frame.
            restored = self.native_status(instance, hwnd, 0)
            self.require_native(restored)
            actual = restored if phase == 0 else self.native_status(instance, hwnd, phase)
            if phase and not (actual["opted_in"] and actual["legacy_fallback"] and actual["current_frame"] and not actual["native"]):
                raise AssertionError(f"{label} failure did not produce successful legacy fallback: {actual}")
            name = f"on-settings-{label}"
            self.record(name, "PASS", expected="current native frame" if not phase else "current legacy frame after native failure",
                        message=WM_POPUP_DCOMP, wparam=1, lparam=phase, before=restored, actual=actual)
            time.sleep(0.15)
            self.capture(instance, hwnd, name, "设置内容完整、无空白或残影；故障阶段应显示 legacy 补绘")
        restored = self.native_status(instance, hwnd, 0)
        self.require_native(restored)
        self.record("on/settings-final-recovery", "PASS", actual=restored)
        self.capture(instance, hwnd, "on-settings-final-recovery", "恢复原生合成后设置内容与故障前一致")

    def run_mode(self, mode):
        instance = self.start(mode)
        for label, chord, patterns in POPUPS:
            before = {item.hwnd for item in instance.popups()}
            instance.press(chord)
            popup = wait(lambda: next((item for item in instance.popups()
                                      if item.hwnd not in before and item.cls in POPUP_CLASSES), None))
            time.sleep(0.4)
            popup = self.fresh_popup(instance, popup.hwnd)
            instance.ensure_foreground()
            name = f"{mode}-{label}"
            actual = self.native_status(instance, popup.hwnd)
            if mode == "off":
                if actual["raw"] != 0:
                    raise AssertionError(f"DComp was enabled without opt-in: {actual}")
            else:
                self.require_native(actual)
            self.record(name + "/backend", "PASS", actual=actual)
            self.capture(instance, popup.hwnd, name, f"{label} 文字和控件清晰、边缘完整、没有黑块或空窗")
            probe = self.uia(instance, popup.hwnd, name, patterns)
            if self.actions:
                # Safe reversible operations, chosen from the live published tree.
                if label == "palette":
                    if self.focus_checks:
                        self.focus_plan(instance, popup, name + "-focus-value", palette_focus_rows(probe["nodes"], "font"))
                    else:
                        node = next(n for n in probe["nodes"] if n["patterns"].get("value"))
                        self.pattern_call(instance, popup, node, "value", "set", "font")
                    actual = self.uia(instance, popup.hwnd, name + "-value-after", ("value",))
                    assert any(n.get("value") == "font" for n in actual["nodes"]), "Value.SetValue did not reach GUI model"
                elif label == "settings":
                    node = next(n for n in probe["nodes"] if n["name"] == "Interaction" and n["patterns"].get("selection_item"))
                    self.pattern_call(instance, popup, node, "selection_item", "select")
                    toggles = self.uia(instance, popup.hwnd, name + "-toggle-tree", ())
                    node = next((n for n in toggles["nodes"] if n["enabled"] and n["patterns"].get("toggle")), None)
                    if node is None:
                        raise AssertionError("Interaction page has no enabled Toggle provider")
                    else:
                        label_before = node["name"]
                        self.pattern_call(instance, popup, node, "toggle", "toggle")
                        refreshed = self.uia(instance, popup.hwnd, name + "-toggle-after", ())
                        replacement = next(n for n in refreshed["nodes"] if n["name"] == label_before and n["patterns"].get("toggle"))
                        assert replacement["toggle_state"] != node["toggle_state"], "Toggle did not change GUI state"
                        self.pattern_call(instance, popup, replacement, "toggle", "toggle")
                elif label == "menu":
                    node = next(n for n in probe["nodes"] if n["patterns"].get("expand_collapse"))
                    self.pattern_call(instance, popup, node, "expand_collapse", "expand")
                    instance.press("escape")  # Close just the submenu before the root below.
                self.capture(instance, popup.hwnd, name + "-action-after", f"{label} 实际 COM 操作后的可见状态")
            if mode == "on" and label == "settings":
                self.fault_phases(instance, popup.hwnd)
            instance.press("escape")
            wait(lambda: not any(item.hwnd == popup.hwnd for item in instance.popups()))
            instance.ensure_owned()
        if self.actions and self.focus_checks:
            self.focus_menu(instance, mode)
        if self.actions:
            self.stale_palette(instance, mode)
            self.root_actions(instance, mode)
        self.report["cleanup"].append({"pid": instance.pid, "birth": instance.creation, "result": instance.close()})
        self.save()

    @staticmethod
    def fresh_terminal(instance, hwnd):
        instance.ensure_owned()
        api = gui.win32()
        if api.window_pid(hwnd) != instance.pid or api.class_name(hwnd) != TERMINAL_CLASS:
            raise gui.InputBlocked("terminal HWND no longer belongs to the fixture process")

    def terminal_probe(self, instance, hwnd, name, rows=None):
        """External MTA probe of a terminal child HWND; its root must be the
        app's own provider (gx_win_uia checks FrameworkId GhosttyGX)."""
        self.fresh_terminal(instance, hwnd)
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--hwnd", str(hwnd),
                   "--pid", str(instance.pid), "--birth", str(instance.creation), "--exe", str(self.exe),
                   "--timeout", "15", "--max-nodes", "64", "--max-depth", "4"]
        if rows:
            plan = self.out / (name + ".plan.json")
            plan.write_text(json.dumps(rows), encoding="utf-8")
            command += ["--sha256", self.expected_hash, "--action-plan", str(plan)]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=20)
        path = self.out / f"{name}-uia.json"
        path.write_text(json.dumps({"command": command, "returncode": result.returncode, "stdout": result.stdout,
                                    "stderr": result.stderr}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        self.fresh_terminal(instance, hwnd)
        if result.returncode != 0:
            raise AssertionError(f"terminal UIA probe failed: {path.name}")
        probe = json.loads(result.stdout)
        if probe.get("status") != "PASS" or probe.get("apartment") != "MTA" or probe.get("created_hwnd") is not False:
            raise AssertionError("probe did not confirm the external windowless MTA contract")
        return probe

    def capture_root(self, instance, name, expect):
        instance.ensure_foreground()
        window = instance.require_window()
        instance.capture_window(window, self.method).save_png(self.out / name)
        self.report["captures"].append({"file": name, "method": self.method, "review": "PENDING_REVIEW", "expect": expect,
                                         "pid": instance.pid, "birth": instance.creation, "window": asdict(window)})
        self.save()

    def terminal_checks_run(self):
        """UIA-05 (D-29): the terminal HWND with the system focus is the named
        pane screen readers announce, each terminal appears once in its window's
        tree, and a UIA SetFocus on another pane raises its FocusChanged."""
        from gx_boundary_controller import held_global_hotkeys
        held = held_global_hotkeys([SPLIT_CHORD])
        if held:
            raise Blocked(f"another program holds the split chord as a global hotkey: {held}")
        instance = self.start("off", config=TERMINAL_CONFIG, variant="-terminal")
        window = instance.require_window()
        terminals = instance.terminals(window)
        focused = instance.focused_terminal()
        if [item.hwnd for item in terminals] != [focused]:
            raise AssertionError(f"expected one focused terminal, found {[item.hwnd for item in terminals]} focus {focused}")
        probe = self.terminal_probe(instance, focused, "terminal-single")
        root = probe["nodes"][0]
        failed = terminal_root_facts(root, focused)
        if failed:
            raise AssertionError(f"D-29 terminal root facts failed: {failed}: {root}")
        rows = [{"automation_id": root["automation_id"], "pattern": "element", "operation": "check_focus",
                 "expect_focus": True, "expect_focused_element": True}]
        self.terminal_probe(instance, focused, "terminal-single-focus", rows)
        tree = self.uia(instance, window.hwnd, "terminal-window", (), root=True)
        if [node["automation_id"] for node in terminal_elements(tree["nodes"])] != [root["automation_id"]] or duplicate_panes(tree["nodes"]):
            raise AssertionError("the window tree does not hold the terminal exactly once")
        if tree["nodes"][0].get("name") != root["name"]:
            raise AssertionError(f"terminal name {root['name']!r} differs from the window title {tree['nodes'][0].get('name')!r}")
        self.record("UIA-05/single", "PASS", case_id="UIA-05", hwnd=focused, root=root,
                    evidence=["terminal-single-uia.json", "terminal-single-focus-uia.json", "terminal-window-uia.json"])
        instance.ensure_foreground()
        instance.press(SPLIT_CHORD)
        wait(lambda: len(instance.terminals(window)) == 2)
        time.sleep(0.4)
        split_focus = instance.focused_terminal()
        other = next(item.hwnd for item in instance.terminals(window) if item.hwnd != split_focus)
        tree = self.uia(instance, window.hwnd, "terminal-split-window", (), root=True)
        ids = [node["automation_id"] for node in terminal_elements(tree["nodes"])]
        if len(ids) != 2 or len(set(ids)) != 2 or duplicate_panes(tree["nodes"]):
            raise AssertionError(f"split window tree does not hold two distinct terminals once each: {ids}")
        target = self.terminal_probe(instance, other, "terminal-split-other")["nodes"][0]
        failed = terminal_root_facts(target, other)
        if failed:
            raise AssertionError(f"D-29 split pane root facts failed: {failed}: {target}")
        rows = [{"automation_id": target["automation_id"], "pattern": "element", "operation": "set_focus",
                 "expect_focus": True, "expect_focused_element": True, "expect_focus_event": True}]
        self.terminal_probe(instance, other, "terminal-split-focus", rows)
        wait(lambda: instance.focused_terminal() == other)
        self.capture_root(instance, "terminal-split-focus.png", "两个左右分屏，焦点（光标与焦点样式）在左侧原终端；无空白或残影")
        self.record("UIA-05/split-focus", "PASS", case_id="UIA-05", terminals=ids, focused=other,
                    evidence=["terminal-split-window-uia.json", "terminal-split-other-uia.json", "terminal-split-focus-uia.json"])
        write_review(self.out, "UIA-05", "D-29 terminal HWND is the named UIA pane", "host", "PASS",
                     ["terminal-split-focus.png"], identity=native_snapshot(instance))
        self.report["cleanup"].append({"pid": instance.pid, "birth": instance.creation, "result": instance.close()})
        self.save()

    def observe(self, instance, hwnd, name, flags, act):
        """One external MTA worker on `hwnd` records events while `act` drives
        the keyboard between its ready file and the continue file."""
        ready, proceed = (self.out / (name + suffix) for suffix in (".ready.json", ".continue"))
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--hwnd", str(hwnd),
                   "--pid", str(instance.pid), "--birth", str(instance.creation), "--exe", str(self.exe),
                   "--max-nodes", "512", "--max-depth", "12", "--timeout", "25", "--listen-ms", "20000",
                   "--ready-file", str(ready), "--continue-file", str(proceed), *flags]
        stdout_path = self.out / (name + ".stdout.json")
        with stdout_path.open("w", encoding="utf-8") as stdout, (self.out / (name + ".stderr.txt")).open("w", encoding="utf-8") as stderr:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
            try:
                wait(lambda: ready.exists() or process.poll() is not None, 20)
                if process.poll() is not None:
                    raise AssertionError(f"observing worker exited before ready: {stdout_path.name}")
                act()
                time.sleep(1.0)
                proceed.write_text("keys delivered\n", encoding="utf-8")
                if process.wait(timeout=25) != 0:
                    raise AssertionError(f"observing worker failed: {stdout_path.name}")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
        return json.loads(stdout_path.read_text(encoding="utf-8"))

    def open_popup(self, instance, chord):
        before = {item.hwnd for item in instance.popups()}
        instance.ensure_foreground()
        instance.press(chord)
        popup = wait(lambda: next((item for item in instance.popups() if item.hwnd not in before and item.cls in POPUP_CLASSES), None))
        time.sleep(0.5)
        return self.fresh_popup(instance, popup.hwnd)

    def close_popup(self, instance, popup):
        instance.ensure_foreground()
        instance.press("escape")
        wait(lambda: not any(item.hwnd == popup.hwnd for item in instance.popups()))

    def event_checks_run(self):
        """UIA-06 (D-03 N2-N4): a real external client subscribed to
        FocusChanged and ElementSelected receives the events of keyboard moves
        in the menu, the command palette and Settings."""
        instance = self.start("off", variant="-events")
        failures = []
        menu = self.open_popup(instance, "ctrl+shift+m")
        result = self.observe(instance, menu.hwnd, "events-menu", ["--observe-focus"], lambda: instance.press("down"))
        before, expected = next_after_focus(result["nodes"], UIA_MENU_ITEM)
        if expected is None:
            raise AssertionError("N2: the keyboard-opened menu reports no focused item with a next one")
        received = later_events(result["focus_events"], automation_id=expected["automation_id"], name=expected["name"])
        self.capture(instance, menu.hwnd, "events-menu-down", f"主菜单键盘高亮从 {before['name']} 移到 {expected['name']}")
        self.record("UIA-06/N2-menu-down", "PASS" if received else "FAIL", case_id="UIA-06", expected=expected["name"],
                    focus_events=result["focus_events"], evidence="events-menu.stdout.json")
        if not received:
            failures.append(f"N2 menu Down: no FocusChanged for {expected['name']}")
        self.close_popup(instance, menu)

        palette = self.open_popup(instance, "ctrl+shift+p")
        result = self.observe(instance, palette.hwnd, "events-palette", ["--observe-selection", "--observe-focus"],
                              lambda: instance.press("down"))
        nodes = result["nodes"]
        search = next((node for node in nodes if node.get("control_type") == UIA_EDIT and node.get("patterns", {}).get("value")), None)
        results = next((node for node in nodes if node.get("control_type") == UIA_LIST), None)
        controls = bool(search and results and results["automation_id"] in (search.get("controller_for") or []))
        before, expected = next_after_selection(nodes)
        if expected is None:
            raise AssertionError("N3: the palette shows no selected result with a next one")
        received = later_events(result["selection_events"], name=expected["name"], event_id=ELEMENT_SELECTED)
        self.capture(instance, palette.hwnd, "events-palette-down", f"命令面板选中从 {before['name']} 移到 {expected['name']}")
        self.record("UIA-06/N3-palette-down", "PASS" if received and controls else "FAIL", case_id="UIA-06",
                    expected=expected["name"], search_controls_results=controls,
                    selection_events=result["selection_events"], evidence="events-palette.stdout.json")
        if not received or not controls:
            failures.append(f"N3 palette Down: ElementSelected for {expected['name']}={bool(received)}, Search controls Results={controls}")
        self.close_popup(instance, palette)

        settings = self.open_popup(instance, "ctrl+comma")
        result = self.observe(instance, settings.hwnd, "events-settings", ["--observe-focus", "--observe-selection"],
                              lambda: instance.press("tab"))
        before = next((node for node in result["nodes"] if node.get("focused")), None)
        moved = [event for event in later_events(result["focus_events"])
                 if before is None or (event.get("automation_id"), event.get("name")) != (before["automation_id"], before["name"])]
        self.capture(instance, settings.hwnd, "events-settings-tab", "设置浮层按 Tab 后焦点环移到下一个控件")
        self.record("UIA-06/N4-settings-tab", "PASS" if moved else "FAIL", case_id="UIA-06",
                    before=before and before["name"], focus_events=result["focus_events"],
                    selection_events=result["selection_events"], evidence="events-settings.stdout.json")
        if not moved:
            failures.append("N4 settings Tab: no FocusChanged event for another element")
        self.close_popup(instance, settings)
        images = ["events-menu-down.png", "events-palette-down.png", "events-settings-tab.png"]
        write_review(self.out, "UIA-06", "D-03 N2-N4 focus and selection events received by a real client", "host",
                     "FAIL" if failures else "PASS", images, identity=native_snapshot(instance), failures=failures)
        self.report["cleanup"].append({"pid": instance.pid, "birth": instance.creation, "result": instance.close()})
        self.save()
        if failures:
            raise AssertionError("; ".join(failures))

    def run(self):
        try:
            if self.terminal_checks or self.event_checks:
                if self.terminal_checks:
                    self.terminal_checks_run()
                if self.event_checks:
                    self.event_checks_run()
                self.report["status"] = "PENDING_VISUAL_REVIEW"
            elif self.readonly_root:
                instance = self.start("off", activate=False)
                root = instance.require_window()
                probe = self.uia(instance, root.hwnd, "readonly-root", ("window",), root=True)
                if not any(node.get("control_type") == 50033 and str(node.get("automation_id", "")).startswith("gx-") for node in probe["nodes"]):
                    raise AssertionError("root provider does not expose its terminal pane")
                self.record("readonly-root/pane", "PASS", scope="read-only properties, no UIA actions or input")
                custom_caption = any(node.get("name") == "Minimize" and str(node.get("automation_id", "")).startswith("gx-") for node in probe["nodes"])
                if custom_caption and any(node.get("control_type") == 50037 for node in probe["nodes"]):
                    raise AssertionError("self-drawn GX caption also exposes a synthetic native title bar")
                self.record("readonly-root/nonclient", "PASS", custom_caption=custom_caption)
                self.report["visual_review"] = "NOT_PERFORMED_ROOT_ONLY"
                self.report["status"] = "PASS_READONLY_NATIVE"
            else:
                for mode in self.modes:
                    self.run_mode(mode)
                    if self.actions and self.focus_checks:
                        self.focus_dialog(mode)
                self.report["status"] = "PENDING_VISUAL_REVIEW"
            self.check_build()
            pending = any(case["status"] == "PENDING" for case in self.report["cases"])
            self.report["automated_checks"] = "PARTIAL" if pending else "PASS"
            return 2 if pending else 0
        except (Blocked, gui.InputBlocked) as exc:
            self.record("blocked", "BLOCKED", reason=str(exc))
            self.report["status"] = "BLOCKED"
            self.failure_capture()
            return 2
        except Exception as exc:
            self.record("failure", "FAIL", reason=str(exc), traceback=traceback.format_exc())
            self.report["status"] = "FAIL"
            self.failure_capture()
            return 1
        finally:
            for instance in self.owned:
                try:
                    if instance.alive():
                        self.report["cleanup"].append({"pid": instance.pid, "birth": instance.creation, "result": instance.close()})
                except Exception as exc:
                    self.report["cleanup"].append({"pid": instance.pid, "status": "FAIL", "reason": str(exc)})
                    self.report["status"] = "FAIL"
            self.save()

    def failure_capture(self):
        if self.readonly_root or not self.owned:
            return
        instance = self.owned[-1]
        try:
            instance.ensure_owned()
            instance.ensure_foreground()
            window = instance.require_window()
            instance.capture_window(window, self.method).save_png(self.out / "failure-owned-window.png")
            self.report["captures"].append({"file": "failure-owned-window.png", "method": self.method,
                                             "review": "PENDING", "expect": "失败现场；不作为通过证据",
                                             "pid": instance.pid, "birth": instance.creation, "window": asdict(window)})
        except Exception as exc:
            self.report["failure_capture"] = {"status": "BLOCKED", "reason": str(exc)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desktop-held", action="store_true", help="caller already holds Invoke-Desktop")
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--sha256", required=True, help="exact hash provided after the app build completes")
    parser.add_argument("--out", type=Path, required=True, help="new, unused evidence directory")
    parser.add_argument("--build", default="coordinator-frozen-build")
    parser.add_argument("--capture", choices=("screen", "print"), default="screen")
    parser.add_argument("--mode", choices=("both", "off", "on"), default="both")
    parser.add_argument("--readonly-root", action="store_true", help="query only root/window/pane properties, without activation, input, screenshots, or popup claims")
    parser.add_argument("--actions", action="store_true", help="exercise reversible COM patterns and retained-provider hide/reopen")
    parser.add_argument("--focus-checks", action="store_true",
                        help="with --actions: UIA-01 dynamic focus sequences (palette, menu, clipboard dialog; needs A1 0002)")
    parser.add_argument("--terminal-checks", action="store_true",
                        help="UIA-05 (D-29): the focused terminal HWND is the named pane, once per window; split SetFocus event")
    parser.add_argument("--event-checks", action="store_true",
                        help="UIA-06 (D-03 N2-N4): FocusChanged/ElementSelected of menu, palette and Settings keyboard moves")
    args = parser.parse_args(argv)
    if (args.terminal_checks or args.event_checks) and (args.readonly_root or args.actions):
        parser.error("--terminal-checks/--event-checks run on their own")
    if args.focus_checks and not args.actions:
        parser.error("--focus-checks requires --actions")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", args.sha256):
        parser.error("--sha256 must be a complete SHA-256 digest")
    if os.name != "nt":
        parser.error("this fixture requires Windows")
    try:
        # Same lock order as other coordinated fixtures. Never run while a
        # performance window owns desktop, or without a free heavy slot.
        with fixture_slots(ROOT, args.desktop_held):
            fixture = Fixture(args)
            result = fixture.run()
            print(json.dumps({"status": fixture.report["status"], "report": str(fixture.out / "report.json")}, ensure_ascii=False))
            return 1 if fixture.report["status"] == "FAIL" else result
    except (OSError, Blocked, TimeoutError) as exc:
        print(json.dumps({"status": "BLOCKED", "reason": str(exc)}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
