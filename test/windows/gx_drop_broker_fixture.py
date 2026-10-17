"""VM-only, real OLE permission matrix with explicit token selection.

Run setup once, then target from pre-opened medium/high consoles of the SAME
user/logon/session. Run drop from the source-token console. No command elevates,
uses Explorer, changes UIPI, reads the clipboard, or sends Enter.

Examples (use absolute paths and the tested binary hashes):
  setup --root E:/gx-vm-test --exe ... --sha256 ... --source ... --source-sha256 ...
  target --root E:/gx-vm-test --integrity medium
  target --root E:/gx-vm-test --integrity high
  drop --root E:/gx-vm-test --direction medium-medium --case text --name mm-text
  drop --root E:/gx-vm-test --direction high-medium --case files --name hm-files
  drop --root E:/gx-vm-test --direction high-high --case text --name hh-text
  drop --root E:/gx-vm-test --direction medium-high --case text --name mh-text

medium-high launches the actual companion CLI under the existing medium token.
Its native COPY means admission only. From the high console, inspect the exact
dialog, then respond with its observed HWND. Allow requires explicit screenshot
coordinates; cancel uses Escape. Do this within the broker's 30-second deadline.
  inspect --root ... --name mh-text
  respond --root ... --name mh-text --popup-hwnd 0x... --decision allow --x ... --y ...

For multiline: allow the broker preview, inspect the separate protection dialog,
then cancel it. Never accept a multiline protection dialog in this fixture.
Snapshots always remain VISUAL_PENDING until a human/agent reads the images.
Use close --root ... --name ... to close only the verified companion; target
processes are retained for the matrix and closed with close --target medium/high.
"""
from __future__ import annotations

import argparse
import ctypes as c
from ctypes import wintypes as wt
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gx_slots
import gx_win_gui as gui
from gx_ole_fixture import OwnedDrag, wait, timeout_snapshot
from gx_fixture_evidence import write_review, fixture_slots


def require_broker_preview(case, stage, title):
    if stage != "broker-preview":
        raise ValueError("the protected-paste dialog can only be cancelled by this fixture")
    if case == "multiline" and title != "Paste into elevated terminal?":
        raise ValueError("multiline allow requires the exact English broker-preview title")


def receipt_rows(text, pid, birth=None):
    return [{"pid": int(source), "request": int(request), "outcome": outcome, "birth": int(created) if created else None}
            for source, request, outcome, created in re.findall(
                r"fixture_receipt pid=(\d+) request=(\d+) outcome=(pasted|cancelled|rejected|target_gone|expired|paste_failed)\b(?: birth=(\d+))?", text)
            if int(source) == pid and (birth is None or (created and int(created) == birth))]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, data):
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def token(pid):
    """Native token facts, not claimed labels supplied by a manifest.

    A UAC split pair (same user, Limited medium + Full high) lives in two logon
    sessions; TOKEN_LINKED_TOKEN records the other one. linked_logon_id is set
    only when the linked token is the exact opposite half of such a pair."""
    kernel = c.WinDLL("kernel32", use_last_error=True)
    adv = c.WinDLL("advapi32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    kernel.OpenProcess.restype = wt.HANDLE
    kernel.CloseHandle.argtypes = [wt.HANDLE]
    adv.OpenProcessToken.argtypes = [wt.HANDLE, wt.DWORD, c.POINTER(wt.HANDLE)]
    adv.GetTokenInformation.argtypes = [wt.HANDLE, c.c_int, c.c_void_p, wt.DWORD, c.POINTER(wt.DWORD)]
    adv.GetLengthSid.argtypes = [c.c_void_p]
    adv.GetLengthSid.restype = wt.DWORD
    adv.GetSidSubAuthorityCount.argtypes = [c.c_void_p]
    adv.GetSidSubAuthorityCount.restype = c.POINTER(c.c_ubyte)
    adv.GetSidSubAuthority.argtypes = [c.c_void_p, wt.DWORD]
    adv.GetSidSubAuthority.restype = c.POINTER(wt.DWORD)

    def info(handle, kind):
        # TOKEN_SESSION_ID, TOKEN_ELEVATION_TYPE and TOKEN_ELEVATION are fixed
        # DWORD contracts; Windows rejects an oversized buffer with BAD_LENGTH.
        size = 4 if kind in (12, 18, 20) else c.sizeof(wt.HANDLE) if kind == 19 else 4096
        buffer = c.create_string_buffer(size)
        used = wt.DWORD()
        if not adv.GetTokenInformation(handle, kind, buffer, len(buffer), c.byref(used)):
            raise OSError(c.get_last_error(), "GetTokenInformation")
        return buffer

    def describe(handle):
        user = info(handle, 1)
        sid = c.cast(user, c.POINTER(c.c_void_p))[0]
        label = info(handle, 25)
        label_sid = c.cast(label, c.POINTER(c.c_void_p))[0]
        count = adv.GetSidSubAuthorityCount(label_sid)[0]
        level = adv.GetSidSubAuthority(label_sid, count - 1)[0]
        return {"sid_hash": hashlib.sha256(c.string_at(sid, adv.GetLengthSid(sid))).hexdigest(),
                "logon_id": int.from_bytes(info(handle, 10).raw[8:16], "little"),
                "session_id": int.from_bytes(info(handle, 12).raw[:4], "little"),
                "elevation_type": {1: "default", 2: "full", 3: "limited"}.get(
                    int.from_bytes(info(handle, 18).raw[:4], "little"), "unknown"),
                "elevated": bool(int.from_bytes(info(handle, 20).raw[:4], "little")),
                "integrity": "low" if level < 0x2000 else "medium" if level < 0x3000 else "high" if level < 0x4000 else "system"}

    process = kernel.OpenProcess(0x1000, False, pid)
    if not process:
        raise OSError(c.get_last_error(), "OpenProcess token inspection")
    handle = wt.HANDLE()
    try:
        if not adv.OpenProcessToken(process, 8, c.byref(handle)):
            raise OSError(c.get_last_error(), "OpenProcessToken")
        facts = describe(handle)
        facts["linked_logon_id"] = None
        if facts["elevation_type"] in ("full", "limited"):
            linked = c.cast(info(handle, 19), c.POINTER(wt.HANDLE))[0]
            if linked:
                try:
                    other = describe(linked)
                finally:
                    kernel.CloseHandle(linked)
                if is_opposite_half(facts, other):
                    facts["linked_logon_id"] = other["logon_id"]
        return facts
    finally:
        if handle:
            kernel.CloseHandle(handle)
        kernel.CloseHandle(process)


def is_opposite_half(owner, linked):
    """Exact Limited-medium/Full-high halves of one user's split token."""
    full_high = lambda f: f["elevation_type"] == "full" and f["integrity"] == "high" and f["elevated"]
    limited_medium = lambda f: f["elevation_type"] == "limited" and f["integrity"] == "medium" and not f["elevated"]
    return ((full_high(owner) and limited_medium(linked)) or (limited_medium(owner) and full_high(linked))) and \
        owner["sid_hash"] == linked["sid_hash"] and owner["session_id"] == linked["session_id"] and \
        0 not in (owner["logon_id"], linked["logon_id"]) and owner["logon_id"] != linked["logon_id"]


def require_level(level, pid=None):
    facts = token(pid or os.getpid())
    if facts["integrity"] != level or facts["elevated"] != (level == "high"):
        raise ValueError(f"Use an already-open {level} console; no elevation is performed")
    return facts


def same_session(a, b):
    """Same user and Windows session; one logon for one integrity level, or the
    two linked halves of that user's UAC split token for medium/high."""
    if a["sid_hash"] != b["sid_hash"] or a["session_id"] != b["session_id"]:
        raise ValueError("matrix participants must be the same user and Windows session")
    if a["integrity"] == b["integrity"]:
        if a["elevated"] != b["elevated"] or a["logon_id"] != b["logon_id"]:
            raise ValueError("same-integrity participants must share one logon session")
        return
    if {a["integrity"], b["integrity"]} != {"medium", "high"}:
        raise ValueError("only medium/high split-token pairs may cross integrity")
    if (a.get("linked_logon_id") is None or b.get("linked_logon_id") is None
            or a["linked_logon_id"] != b["logon_id"] or b["linked_logon_id"] != a["logon_id"]
            or a["logon_id"] == b["logon_id"]):
        raise ValueError("medium/high participants are not the two linked halves of one UAC split token")


def settings(root):
    value = json.loads((root / "fixture.json").read_text(encoding="utf-8"))
    if value.get("schema") != 1 or Path(value["root"]).resolve() != root:
        raise ValueError("not this fixture root")
    for path, expected in ((value["exe"], value["sha256"]), (value["source"], value["source_sha256"])):
        if digest(path) != expected:
            raise ValueError("fixture image hash changed")
    if digest(gui.config_path(root / "profile")) != value["config_sha256"]:
        raise ValueError("private fixture configuration changed")
    return value


def record(instance, config):
    instance.ensure_owned()
    return {"fixture_id": config["id"], "pid": instance.pid, "birth": instance.creation,
            "launched": instance.launched, "exe": instance.exe, "sha256": config["sha256"],
            "profile": str(instance.env_dir), "token": token(instance.pid)}


class Receiver(gui.Instance):
    def require_window(self, kind="main"):
        return next((item for item in self.windows() if item.cls == "GhosttyDropCompanion" and item.visible), None) or (_ for _ in ()).throw(gui.GuiError("no verified companion window"))


def owner(data, config, companion=False):
    if data["fixture_id"] != config["id"] or not gui.same_path(data["exe"], config["exe"]) or data["sha256"] != config["sha256"]:
        raise ValueError("foreign fixture owner")
    if not gui.same_path(data["profile"], Path(config["root"]) / "profile"):
        raise ValueError("unexpected isolation domain")
    kind = Receiver if companion else gui.Instance
    instance = kind(data["pid"], data["exe"], Path(data["profile"]), data["birth"], data["launched"])
    instance.ensure_owned()
    if digest(instance.exe) != data["sha256"] or token(instance.pid) != data["token"]:
        raise ValueError("owner token/image changed")
    return instance


def setup(args):
    root = args.root.resolve()
    app, source = args.exe.resolve(strict=True), args.source.resolve(strict=True)
    if digest(app) != args.sha256.lower() or digest(source) != args.source_sha256.lower():
        raise ValueError("setup binary hash mismatch")
    root.mkdir(parents=True, exist_ok=False)
    profile = root / "profile"
    gui.prepare_env_dir(profile, False)
    gui.write_config(profile, "language = en\nconfirm-close-surface = false\n"
                     "command = cmd.exe /d /k prompt GX_BROKER_OWNED$G$S\n"
                     "gx-single-instance = false\ngx-session-restore = false\n"
                     "clipboard-paste-protection = true\nwindow-width = 100\nwindow-height = 28\n")
    save(root / "fixture.json", {"schema": 1, "id": str(uuid.uuid4()), "root": str(root),
                              "exe": str(app), "sha256": digest(app), "source": str(source), "source_sha256": digest(source),
                              "config_sha256": digest(gui.config_path(profile))})
    print(f"Prepared private fixture at {root}; use existing medium/high consoles of the same user.")


def start_target(args, config):
    require_level(args.integrity)
    path = args.root / f"target-{args.integrity}.json"
    if path.exists():
        raise ValueError("target manifest already exists; use a fresh fixture root")
    instance = gui.launch(Path(config["exe"]), args.root / "profile", env={"GHOSTTY_GX_REMOTE_TEST": "1"})
    value = record(instance, config)
    save(path, value)  # Preserve ownership even if startup fails.
    instance.wait_window(15)
    instance.activate()
    if args.tabs > 1:
        from gx_boundary_controller import Native
        native = Native(instance, instance.require_window().hwnd)
        for count in range(2, args.tabs + 1):
            instance.press("ctrl+shift+t")
            wait(lambda: native.query(4) == count)
    instance.capture_window(instance.require_window(), "screen").save_png(args.root / f"target-{args.integrity}.png")
    print(json.dumps(value, indent=2))


def case_path(root, name):
    if not name or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for char in name):
        raise ValueError("case name must contain only ASCII letters, digits, hyphen or underscore")
    return root / "cases" / name


def drop(args, config):
    source_level, target_level = args.direction.split("-")
    local = require_level(source_level)
    target_data = json.loads((args.root / f"target-{target_level}.json").read_text(encoding="utf-8"))
    target = owner(target_data, config)
    require_level(target_level, target.pid)
    same_session(local, target_data["token"])
    work = case_path(args.root, args.name)
    work.mkdir(parents=True, exist_ok=False)
    report = {"fixture_id": config["id"], "direction": args.direction, "case": args.case,
              "target": target_data, "route": "companion" if args.direction == "medium-high" else "direct",
              "clipboard_access": False, "enter_injected": False, "status": "RUNNING", "visual_review": "PENDING"}
    process, receiver, drag, button_down = None, target, None, False
    try:
        if args.direction == "medium-high":
            # This launch inherits the existing medium token. There is no runas,
            # linked-token creation, Explorer launch, registry or UIPI change.
            cli = ["--gx-shell-action=drop-companion", f"--gx-drop-target-pid={target.pid}",
                   f"--gx-drop-target-birth={target.creation}"]
            helper = gui.launch(Path(config["exe"]), args.root / "profile", args=cli, env={"GHOSTTY_GX_REMOTE_TEST": "1"})
            helper_data = record(helper, config)
            require_level("medium", helper.pid)
            report["companion"] = helper_data
            report["companion_cli"] = cli
            save(work / "report.json", report)
            receiver = owner(helper_data, config, companion=True)
            window = wait(lambda: next((item for item in receiver.windows() if item.cls == "GhosttyDropCompanion" and item.visible), None))
            terminal = window
        else:
            window = receiver.require_window()
            terminal = wait(lambda: receiver.terminals(window))[0]
        receiver.activate()
        receiver.capture_window(window, "screen").save_png(work / "receiver-before.png")
        command = [config["source"], "--run", "--source-window", f"--hwnd={terminal.hwnd:#x}",
                   f"--pid={receiver.pid}", f"--birth={receiver.creation}", f"--exe={config['exe']}",
                   f"--sha256={config['sha256']}", f"--work-dir={work}", f"--case={args.case}", "--timeout-ms=7000"]
        with (work / "source.stdout.txt").open("wb", buffering=0) as stdout, (work / "source.stderr.txt").open("wb", buffering=0) as stderr:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
            birth = gui.win32().process_creation(process.pid)
            report["source"] = {"pid": process.pid, "birth": birth, "token": require_level(source_level, process.pid), "sha256": config["source_sha256"]}
            same_session(report["source"]["token"], local)
            ready_path = wait(lambda: next(work.glob(f"gx-ole-{process.pid}-*/ready.json"), None) if process.poll() is None else (_ for _ in ()).throw(RuntimeError("source exited before ready")))
            ready = json.loads(ready_path.read_text(encoding="utf-8"))
            if (ready["target_pid"] != receiver.pid or ready["target_birth"] != receiver.creation
                    or ready["target_hwnd"] != terminal.hwnd or ready["source_pid"] != process.pid
                    or ready["app_sha256"].lower() != config["sha256"]):
                raise ValueError("source ready identity mismatch")
            drag = OwnedDrag(receiver, Path(config["exe"]), config["sha256"], Path(config["source"]),
                             config["source_sha256"], process, birth, ready["source_hwnd"], terminal)
            drag.activate_source()
            start = drag.start_point()
            client = gui.win32().client_rect(terminal.hwnd)
            end = (client[2] - 35, (client[1] + client[3]) // 2)
            drag.mouse(*start, action="down")
            button_down = True
            for step in range(1, 17):
                drag.mouse(round(start[0] + (end[0] - start[0]) * step / 16), round(start[1] + (end[1] - start[1]) * step / 16))
                time.sleep(0.03)
            drag.mouse(*end, action="up", target_only=True)
            button_down = False
            process.wait(timeout=12)
            native = json.loads((ready_path.parent / "evidence.json").read_text(encoding="utf-8"))
            report["native"] = native
            if process.returncode != 0 or native["effect"] != 1 or native["get_data"] != native["medium_releases"] or native["get_data"] < 1:
                raise AssertionError("real OLE did not admit and release the typed payload")
            report["status"] = "BROKER_CONFIRMATION_PENDING" if report["route"] == "companion" else "NATIVE_PASS_VISUAL_PENDING"
            # Do not activate a lower receiver over the elevated preview.
            if report["route"] == "direct":
                receiver.activate()
                receiver.capture_window(receiver.require_window(), "screen").save_png(work / "target-after.png")
    except Exception as error:
        report.update(status="FAIL", error=str(error))
        if isinstance(error, subprocess.TimeoutExpired) and process is not None:
            try:
                report["timeout"] = timeout_snapshot(receiver, Path(config["source"]), process.pid,
                                                      report["source"]["birth"], config["source_sha256"], work)
            except Exception as detail:
                report["timeout"] = {"error": str(detail)}
    finally:
        if button_down and drag is not None and drag.last_point is not None:
            try:
                drag.mouse(*drag.last_point, action="up")
                report["mouse_cleanup"] = "released on verified owned window"
            except Exception as error:
                report["mouse_cleanup"] = f"BLOCKED: {error}"
        if process is not None and process.poll() is None:
            source = report.get("source", {})
            if (gui.win32().process_creation(process.pid) == source.get("birth")
                    and gui.same_path(gui.win32().process_image(process.pid) or "", config["source"])
                    and digest(config["source"]) == config["source_sha256"]):
                process.terminate()
                process.wait(timeout=5)
                report["source_cleanup"] = "terminated owned unfinished fixture; not lifecycle PASS"
        save(work / "report.json", report)
    print(json.dumps(report, indent=2))
    return int(report["status"] == "FAIL")


def inspect_or_respond(args, config):
    work = case_path(args.root, args.name)
    report = json.loads((work / "report.json").read_text(encoding="utf-8"))
    target = owner(report["target"], config)
    level = report["target"]["token"]["integrity"]
    same_session(require_level(level), report["target"]["token"])
    stamp = str(time.time_ns())
    popups = [popup for popup in target.popups() if popup.cls in ("GhosttyGxPopup", "GhosttyGxPopupShadow", "#32770")]
    evidence = {"status": "VISUAL_PENDING", "popups": [], "enter_injected": False}
    for popup in popups:
        filename = f"popup-{stamp}-{popup.hwnd:x}.png"
        target.capture_window(popup, "screen").save_png(work / filename)
        evidence["popups"].append({"hwnd": popup.hwnd, "class": popup.cls, "title": popup.title, "rect": popup.rect, "capture": filename})
    if args.command == "respond":
        popup = next((item for item in popups if item.hwnd == args.popup_hwnd), None)
        if popup is None:
            raise ValueError("the explicitly selected popup no longer exists")
        if not gui.win32().activate(popup.hwnd):
            raise gui.InputBlocked("cannot activate the verified confirmation")
        def guard_popup():
            owner(report["target"], config)
            w = gui.win32()
            if w.foreground() != popup.hwnd or w.class_name(popup.hwnd) != popup.cls or w.window_pid(popup.hwnd) != target.pid:
                raise gui.InputBlocked("confirmation identity/foreground changed; no input sent")
        guard_popup()
        if args.decision == "allow":
            require_broker_preview(report["case"], args.stage, popup.title)
            if args.x is None or args.y is None or gui.win32().window_at(args.x, args.y) != popup.hwnd:
                raise ValueError("allow requires reviewed button coordinates inside the exact popup")
            if args.delay_ms:
                time.sleep(args.delay_ms / 1000)
                guard_popup()
            target.mouse(args.x, args.y)
        else:
            target.press("escape")
        evidence["decision"] = args.decision
        time.sleep(0.3)
    target.capture_window(target.require_window(), "screen").save_png(work / f"target-{stamp}.png")
    if "companion" in report:
        companion = owner(report["companion"], config, companion=True)
        companion.capture_window(companion.require_window(), "screen").save_png(work / f"companion-{stamp}.png")
    save(work / f"observation-{stamp}.json", evidence)
    print(json.dumps(evidence, indent=2))


def receipt(args, config):
    work = case_path(args.root, args.name)
    report = json.loads((work / "report.json").read_text(encoding="utf-8"))
    companion = owner(report["companion"], config, companion=True)
    same_session(require_level("medium"), report["companion"]["token"])
    rows = []
    for path in (companion.log, companion.log.with_name(companion.log.name + ".1")):
        if path.exists():
            rows.extend(receipt_rows(path.read_text(encoding="utf-8", errors="replace"), companion.pid, companion.creation))
    case_id = {"rejected": "BRK-01", "expired": "BRK-02", "target_gone": "BRK-03", "cancelled": "BRK-04", "pasted": "BRK-05", "paste_failed": "BRK-06"}[args.expect]
    companion.activate()
    image = f"{case_id}-receipt.png"
    companion.capture_window(companion.require_window(), "screen").save_png(work / image)
    # The gated receipt hook is part of this build. Missing evidence is a
    # failed native assertion, not an unimplemented controller or environment.
    status = "PASS" if rows and rows[-1]["outcome"] == args.expect else "FAIL"
    result = {"case_id": case_id, "boundary": "R5-04 broker final receipt", "environment": "VM medium/high split token",
              "status": status, "expected": args.expect, "rows": rows, "companion": report["companion"],
              "reason": "missing final receipt for this PID/birth" if not rows else None}
    save(work / f"{case_id}-native.json", result)
    write_review(work, case_id, result["boundary"], result["environment"], status, [image], observation=result)
    print(json.dumps(result, indent=2))
    return int(status == "FAIL")


def close(args, config):
    if args.target:
        value = json.loads((args.root / f"target-{args.target}.json").read_text(encoding="utf-8"))
        instance = owner(value, config)
    else:
        report = json.loads((case_path(args.root, args.name) / "report.json").read_text(encoding="utf-8"))
        value = report["companion"]
        instance = owner(value, config, companion=True)
    same_session(require_level(value["token"]["integrity"]), value["token"])
    hwnd = instance.require_window().hwnd
    gui.win32().PostMessageW(hwnd, 0x10, 0, 0)
    wait(lambda: not instance.alive(), timeout=8)
    print("Verified owned process closed normally.")


def boundary(args, config):
    """Run from the existing high-token console, never elevate or bypass UIPI."""
    from gx_boundary_controller import Native
    require_level("high")
    data = json.loads((args.root / "target-high.json").read_text(encoding="utf-8"))
    target = owner(data, config)
    same_session(require_level("high"), data["token"])
    native = Native(target, target.require_window().hwnd)
    if args.transition == "rejected":
        assert native.control(21, 1) == 1
        print("Armed one authenticated broker admission rejection. Now run medium drop, then receipt --expect rejected.")
    else:
        work = case_path(args.root, args.name)
        report = json.loads((work / "report.json").read_text(encoding="utf-8"))
        assert report["target"]["pid"] == target.pid and report["target"]["birth"] == target.creation
        assert native.query(4) >= 2 or native.query(5, native.query(3)) > 1, "keep another live tab/pane before closing the selected target"
        before = native.tree()
        dialogs = [w for w in target.popups() if w.cls in ("GhosttyGxPopup", "GhosttyGxPopupShadow", "#32770")]
        assert len(dialogs) == 1, "expected the single live broker preview"
        dialog = dialogs[0]
        target.capture_window(dialog, "screen").save_png(work / "target-gone-preview.png")
        assert native.control(22) == 1
        if not gui.win32().activate(dialog.hwnd):
            raise gui.InputBlocked("cannot activate the owned old preview")
        target.ensure_foreground()
        target.press("escape")
        wait(lambda: not any(w.hwnd == dialog.hwnd for w in target.popups()))
        assert target.alive()
        target.capture_window(target.require_window(), "screen").save_png(work / "target-gone-survivor.png")
        save(work / "target-gone-transition.json", {"case_id": "BRK-03", "before": before, "after": native.tree(),
                                                    "target_pid": target.pid, "target_birth": target.creation})
        print("Selected target removed; host remains alive. Verify medium receipt --expect target_gone.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("setup", "target", "drop", "inspect", "respond", "receipt", "boundary", "close"):
        command = sub.add_parser(name)
        command.add_argument("--root", type=Path, required=True)
        command.add_argument("--desktop-held", action="store_true", help="caller already holds Invoke-Desktop")
        if name == "setup":
            for item in ("exe", "source"):
                command.add_argument(f"--{item}", type=Path, required=True)
            command.add_argument("--sha256", required=True)
            command.add_argument("--source-sha256", required=True)
        if name == "target":
            command.add_argument("--integrity", choices=("medium", "high"), required=True)
            command.add_argument("--tabs", type=int, choices=(1, 2), default=2)
        if name == "boundary":
            command.add_argument("--transition", choices=("rejected", "target-gone"), required=True)
            command.add_argument("--name", required=True)
        if name in ("drop", "inspect", "respond", "receipt", "close"):
            command.add_argument("--name", required=name != "close")
        if name == "drop":
            command.add_argument("--direction", choices=("medium-medium", "medium-high", "high-medium", "high-high"), required=True)
            command.add_argument("--case", choices=("text", "multiline", "files"), required=True)
        if name == "respond":
            command.add_argument("--popup-hwnd", type=lambda text: int(text, 0), required=True)
            command.add_argument("--decision", choices=("allow", "cancel"), required=True)
            command.add_argument("--x", type=int)
            command.add_argument("--y", type=int)
            command.add_argument("--stage", choices=("broker-preview", "protected-paste"), default="broker-preview")
            command.add_argument("--delay-ms", type=int, default=0, help="31000 for the expired preview case; <=32000")
        if name == "receipt":
            command.add_argument("--expect", choices=("pasted", "cancelled", "rejected", "target_gone", "expired", "paste_failed"), required=True)
        if name == "close":
            command.add_argument("--target", choices=("medium", "high"))
    args = parser.parse_args()
    if getattr(args, "delay_ms", 0) not in range(32001):
        parser.error("delay-ms must be 0..32000")
    args.root = args.root.resolve()
    if args.command == "setup":
        setup(args)
        return 0
    config = settings(args.root)
    with fixture_slots(ROOT, args.desktop_held):
        if args.command == "boundary":
            boundary(args, config)
            return 0
        if args.command == "receipt":
            return receipt(args, config)
        if args.command == "target":
            start_target(args, config)
        elif args.command == "drop":
            return drop(args, config)
        elif args.command in ("inspect", "respond"):
            inspect_or_respond(args, config)
        else:
            close(args, config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
