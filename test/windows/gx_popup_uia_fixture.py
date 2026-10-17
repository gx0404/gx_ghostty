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

    def start(self, mode, *, activate=True):
        self.check_build()
        env_dir = (self.out / f"env-{mode}").resolve()
        gui.prepare_env_dir(env_dir, False)
        # The off case leaves the variable absent, verifying the default.
        extra = {"GHOSTTY_GX_REMOTE_TEST": "1"}
        if mode == "on":
            extra["GHOSTTY_GX_POPUP_DCOMP"] = "1"
        instance = gui.launch(self.exe, env_dir, config=CONFIG, env=extra)
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
        if self.actions:
            self.stale_palette(instance, mode)
            self.root_actions(instance, mode)
        self.report["cleanup"].append({"pid": instance.pid, "birth": instance.creation, "result": instance.close()})
        self.save()

    def run(self):
        try:
            if self.readonly_root:
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
    args = parser.parse_args(argv)
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
