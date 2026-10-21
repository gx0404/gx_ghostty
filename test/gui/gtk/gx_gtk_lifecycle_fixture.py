#!/usr/bin/env python3
"""GTK lifecycle fixture: real Ghostty GX GTK windows on a private Xvfb display.

It drives the built GTK app with real X input (xdotool) and checks real
processes, files and screenshots. Nothing is mocked:

  session 1: create a launch profile on the Shell page of the settings (menu
  Edit Launch Profiles... -> New Launch Profile subpage) and a binding on the
  New Advanced Shortcut page of the shortcut editor -> use the saved binding -> move a split into a new tab and
  into a new window -> close the old window -> keep typing into the original
  terminal (PID, starttime and PTY unchanged) -> resize -> quit.
  session 2 (gx-session-restore = true): the custom profile asks before it
  restores, the temporary initial command is skipped, the saved structure and
  geometry come back, and the saved binding still works.

Run on Windows through the heavy slot (WSL + Xvfb, never the host desktop):

  python scripts/gx_slots.py --kind heavy --timeout 1800 -- \
      python test/gui/gtk/gx_gtk_lifecycle_fixture.py --out <new evidence dir>

--explore only opens the new-tab menu, the Shell page with its launch profile
list and New Launch Profile subpage, and the shortcut editor with its New
Advanced Shortcut page, takes screenshots (to calibrate click positions) and
saves nothing. The exit code
covers the automated checks only: every screenshot listed in notes.txt must
still be read before anything is recorded as PASS.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import uuid

DEFAULT_DISTRO = "Ubuntu-24.04"
DEFAULT_CLONE = "~/src/gx_ghostty-R5-00-overlay"
SCREEN = "1280x800x24"
FORBID = ("Theme parser error", "css parsing failed")
PROFILE_NAME = "Lifecycle"
PROFILE_COMMAND = "direct:/usr/bin/env GX_LC_ROLE=profile PS1=PROFILE$ /bin/bash --noprofile --norc"
BINDING = "ctrl+alt+j=gx:new_tab_profile:" + PROFILE_NAME
RESIZE = (1000, 680)
W2_POSITION = (440, 170)

# Click positions on the 1280x800 screen, first window at the origin. The
# window keeps its default 800x600 except while an editor is open: the
# settings dialog (920x680) and the shortcut editor (720x560) are clamped by
# the window, so the fixture sizes it like the GTK scenarios that pin these
# positions (G16/G18: 1100x600, G17/G31: 1100x740) and restores 800x600
# afterwards. Calibrate with --explore screenshots.
#   pm_*: in the 1100x600 window the settings dialog is clamped to 530 px
#         with its bottom edge at y=565 and the page switcher in its title
#         bar; after scrolling the Shell page to its end the list ends 24 px
#         above that edge and New Launch Profile is the last row, centred
#         27 px above the list end (G16/G18: NEW_Y = 565 - 24 - 27 = 514).
#         The subpage focuses the name entry, Tab moves to the command and
#         Return saves (back to the list with the toast Launch profiles saved.).
#   ed_*: the cheat sheet's Edit Keyboard Shortcuts button, the list scrolled
#         to New Advanced Shortcut, and Save in the editor header bar.
PM_WINDOW = (1100, 600)
ED_WINDOW = (1100, 740)
DEFAULT_WINDOW = (800, 600)
LAYOUT = {
    "terminal": (400, 360),
    "menu_edit_profiles": (90, 495),
    "pm_scroll": (550, 300),
    "pm_new_profile": (550, 514),
    "cheat_edit": (730, 110),
    "ed_scroll": (550, 450),
    "ed_new_advanced": (550, 598),
    "ed_save": (828, 112),
}

CONFIG_TEMPLATE = """language = en
command = direct:/usr/bin/env GX_LC_ROLE=default PS1=DEFAULT$ /bin/bash --noprofile --norc
initial-command = direct:/usr/bin/env GX_LC_ROLE=temp PS1=TEMP$ /bin/bash --noprofile --norc
env = GX_LC_RUN={run_id}
env = XDG_CONFIG_HOME=
env = XDG_STATE_HOME=
gx-session-restore = true
confirm-close-surface = false
keybind = ctrl+alt+m=gx:move_split_to_tab
keybind = ctrl+alt+w=gx:move_split_to_window
keybind = ctrl+alt+o=new_split:right
keybind = ctrl+alt+h=goto_split:left
keybind = ctrl+alt+x=close_window
keybind = ctrl+alt+q=quit
keybind = ctrl+alt+b=gx:new_tab_profile:bash
keybind = ctrl+alt+k=gx:keybinds
keybind = ctrl+alt+n=gx:new_tab_menu
keybind = ctrl+alt+1=goto_tab:1
keybind = ctrl+alt+2=goto_tab:2
keybind = ctrl+alt+3=goto_tab:3
"""


class Failure(AssertionError):
    pass


# --------------------------------------------------------------------------
# Host side: Windows -> wsl.exe; Linux runs the inside stage directly.

def to_wsl_path(path: Path) -> str:
    text = str(path.resolve())
    win = PureWindowsPath(text)
    if not win.drive or len(win.drive) != 2 or win.drive[1] != ":":
        raise SystemExit(f"cannot map {text} into WSL (need a drive-letter path)")
    rest = "/".join(win.parts[1:])
    return f"/mnt/{win.drive[0].lower()}/{rest}"


def host_main(args: argparse.Namespace, extra: list[str]) -> int:
    out = Path(args.out).resolve()
    if out.exists():
        print(f"[gx-gtk-lifecycle] error: {out} already exists; use a new evidence directory", flush=True)
        return 2
    if os.name != "nt":
        return inside_main(args, extra)
    command = ["wsl.exe", "-d", args.distro, "--cd", "~", "-e", "/usr/bin/python3", to_wsl_path(Path(__file__)),
               "--inside", "--clone", args.clone, "--out", to_wsl_path(out), *extra]
    print("[gx-gtk-lifecycle] " + " ".join(command), flush=True)
    return subprocess.call(command)


def inside_main(args: argparse.Namespace, extra: list[str]) -> int:
    for tool in ("xvfb-run", "Xvfb", "dbus-run-session", "xdotool", "scrot"):
        if shutil.which(tool) is None:
            print(f"[gx-gtk-lifecycle] error: {tool} is not installed (this fixture never installs anything)", flush=True)
            return 2
    command = ["xvfb-run", "-a", "-s", f"-screen 0 {SCREEN} -nolisten tcp", "dbus-run-session", "--",
               sys.executable, str(Path(__file__).resolve()), "--driver", "--clone", args.clone, "--out", args.out, *extra]
    print("[gx-gtk-lifecycle] " + " ".join(command), flush=True)
    return subprocess.call(command)


# --------------------------------------------------------------------------
# Linux /proc helpers.

def parse_stat(text: str) -> dict:
    head, tail = text.rsplit(")", 1)
    fields = tail.split()
    return {"comm": head.split("(", 1)[1], "state": fields[0], "ppid": int(fields[1]), "pgrp": int(fields[2]),
            "session": int(fields[3]), "tty_nr": int(fields[4]), "starttime": int(fields[19])}


def proc_identity(pid: int) -> dict:
    root = Path("/proc") / str(pid)
    stat = parse_stat((root / "stat").read_text())
    try:
        fd0 = os.readlink(root / "fd" / "0")
    except OSError:
        fd0 = None
    return {"pid": pid, "ppid": stat["ppid"], "session": stat["session"], "tty_nr": stat["tty_nr"],
            "starttime": stat["starttime"], "fd0": fd0, "comm": stat["comm"], "state": stat["state"],
            "exe": os.readlink(root / "exe")}


def environ_of(pid: int) -> dict:
    try:
        raw = (Path("/proc") / str(pid) / "environ").read_bytes()
    except OSError:
        return {}
    result = {}
    for item in raw.split(b"\0"):
        if b"=" in item:
            key, value = item.split(b"=", 1)
            result[key.decode(errors="replace")] = value.decode(errors="replace")
    return result


def cmdline_of(pid: int) -> list[str]:
    try:
        raw = (Path("/proc") / str(pid) / "cmdline").read_bytes()
    except OSError:
        return []
    return [part.decode(errors="replace") for part in raw.split(b"\0") if part]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# Driver: runs inside xvfb-run + dbus-run-session (a display private to this run).

class Driver:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.clone = Path(os.path.expanduser(args.clone)).resolve()
        self.exe = self.clone / "zig-out" / "bin" / "ghostty"
        self.out = Path(args.out)
        self.out.mkdir(parents=True, exist_ok=False)
        self.work = Path(tempfile.mkdtemp(prefix="gxlc"))
        self.marks = self.work / "marks"
        self.marks.mkdir()
        self.config_home = self.work / "xdg-config"
        self.state_home = self.work / "xdg-state"
        self.run_id = uuid.uuid4().hex[:12]
        self.log_handle = open(self.out / "fixture.log", "w", encoding="utf-8", newline="\n")
        self.child: subprocess.Popen | None = None
        self.pidfd: int | None = None
        self.gpid = 0
        self.session_label = ""
        self.exiting = False
        self.ignored: set[int] = set()
        self.report: dict = {
            "schema": "gx-gtk-lifecycle-v1", "run_id": self.run_id, "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "display": os.environ.get("DISPLAY"), "screen": SCREEN, "explore": bool(args.explore), "repro": bool(args.repro),
            "checks": [], "shots": [], "sessions": [], "identities": {}, "errors": [],
            "visual_review": "PENDING: read every screenshot listed in notes.txt",
        }

    # ---- logging and checks
    def log(self, message: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} [{self.session_label or '-'}] {message}"
        print("[gx-gtk-lifecycle] " + line, flush=True)
        self.log_handle.write(line + "\n")
        self.log_handle.flush()

    def check(self, name: str, ok: bool, detail=None) -> None:
        self.report["checks"].append({"name": name, "status": "PASS" if ok else "FAIL", "detail": detail})
        self.log(("PASS " if ok else "FAIL ") + name + (f" :: {json.dumps(detail, default=str)[:600]}" if detail is not None else ""))
        if not ok:
            raise Failure(name)

    def defect(self, name: str, ok: bool, detail=None) -> bool:
        """Record a product defect as FAIL but keep going, so later steps still run."""
        self.report["checks"].append({"name": name, "status": "PASS" if ok else "FAIL", "detail": detail,
                                      "continued": not ok})
        self.log(("PASS " if ok else "FAIL (continued) ") + name + f" :: {json.dumps(detail, default=str)[:600]}")
        return ok

    def wait(self, what: str, predicate, timeout: float = 15.0, interval: float = 0.1):
        deadline = time.monotonic() + timeout
        while True:
            self.require_alive()
            value = predicate()
            if value:
                return value
            if time.monotonic() >= deadline:
                raise Failure(f"timed out after {timeout:.0f} s waiting for {what}")
            time.sleep(interval)

    @staticmethod
    def wait_quiet(predicate, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.2)
        return bool(predicate())

    # ---- environment and process
    def environment(self) -> dict:
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("GHOSTTY_", "TERM")) and key not in ("NO_COLOR", "WAYLAND_DISPLAY")}
        env["PATH"] = ":".join(part for part in env.get("PATH", "/usr/bin:/bin").split(":") if not part.startswith("/mnt/"))
        env.update({"XDG_CONFIG_HOME": str(self.config_home), "XDG_STATE_HOME": str(self.state_home),
                    "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "LANGUAGE": "en", "GDK_BACKEND": "x11",
                    "LIBGL_ALWAYS_SOFTWARE": "1", "NO_AT_BRIDGE": "1", "SHELL": "/bin/sh",
                    "LD_LIBRARY_PATH": str(self.clone / "zig-out" / "lib")})
        return env

    def write_config(self) -> None:
        directory = self.config_home / "ghostty"
        directory.mkdir(parents=True, exist_ok=True)
        text = CONFIG_TEMPLATE.format(run_id=self.run_id)
        (directory / "config.ghostty").write_text(text, encoding="utf-8", newline="\n")
        (self.out / "config.ghostty").write_text(text, encoding="utf-8", newline="\n")

    def record_build(self) -> None:
        def git(*argv):
            return subprocess.run(["git", "-C", str(self.clone), *argv], capture_output=True, text=True).stdout.strip()
        receipt_path = self.clone / ".local" / "gx-wsl" / "gtk-build-receipt.json"
        version = subprocess.run([str(self.exe), "+version"], capture_output=True, text=True, timeout=60,
                                 env={**self.environment(), "XDG_CONFIG_HOME": str(self.work / "none")})
        stat = os.stat(self.exe)
        receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
        build = {"clone": str(self.clone), "head": git("rev-parse", "HEAD"), "head_subject": git("log", "-1", "--format=%s"),
                 "porcelain": git("status", "--porcelain"), "exe": str(self.exe), "exe_sha256": sha256_file(self.exe),
                 "exe_inode": stat.st_ino, "exe_mtime_ns": stat.st_mtime_ns,
                 "version_exit": version.returncode, "version": version.stdout, "receipt": receipt,
                 "install_note": "build receipt build_kind=" + str((receipt or {}).get("build_kind")) +
                                 "; a limited GUI check of this image, not a standard-install verification"}
        self.report["build"] = build
        self.log(f"exe sha256 {build['exe_sha256']} head {build['head']} receipt kind {(receipt or {}).get('build_kind')}")

    def launch(self, label: str) -> None:
        self.session_label = label
        if sha256_file(self.exe) != self.report["build"]["exe_sha256"]:
            raise Failure("executable changed since the run started")
        log_path = self.out / f"ghostty-{label}.log"
        with open(log_path, "w", encoding="utf-8") as log:
            self.child = subprocess.Popen([str(self.exe), "--gtk-single-instance=false"], stdout=log, stderr=log,
                                          stdin=subprocess.DEVNULL, cwd=str(self.work), env=self.environment(),
                                          start_new_session=True)
        self.pidfd = os.pidfd_open(self.child.pid)
        self.gpid = self.child.pid
        self.exiting = False
        identity = proc_identity(self.gpid)
        if identity["exe"] != str(self.exe):
            raise Failure(f"launched image {identity['exe']} is not {self.exe}")
        self.report["sessions"].append({"label": label, "pid": self.gpid, "starttime": identity["starttime"],
                                        "log": log_path.name})
        self.log(f"launched ghostty pid {self.gpid}")

    def alive(self) -> bool:
        return self.child is not None and self.child.poll() is None

    def require_alive(self) -> None:
        if self.child is not None and not self.exiting and self.child.poll() is not None:
            raise Failure(f"ghostty exited unexpectedly with {self.child.returncode}")

    def wait_exit(self, timeout: float = 20.0) -> int:
        self.exiting = True
        code = self.child.wait(timeout=timeout)
        if self.pidfd is not None:
            os.close(self.pidfd)
            self.pidfd = None
        return code

    def stop(self) -> None:
        if self.child is None:
            return
        if self.child.poll() is None and self.pidfd is not None:
            try:
                signal.pidfd_send_signal(self.pidfd, signal.SIGTERM)
                self.child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                signal.pidfd_send_signal(self.pidfd, signal.SIGKILL)
                self.child.wait(timeout=5)
            except ProcessLookupError:
                pass
            self.report["errors"].append(f"{self.session_label}: ghostty had to be stopped by the fixture")
        if self.pidfd is not None:
            os.close(self.pidfd)
            self.pidfd = None

    def marker_processes(self) -> list[int]:
        found = []
        for entry in Path("/proc").iterdir():
            if entry.name.isdigit() and environ_of(int(entry.name)).get("GX_LC_RUN") == self.run_id:
                found.append(int(entry.name))
        return found

    def kill_leftovers(self) -> list[dict]:
        leftovers = []
        for pid in self.marker_processes():
            leftovers.append({"pid": pid, "cmdline": cmdline_of(pid)})
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return leftovers

    # ---- terminals (direct shell children of ghostty, found by the run marker)
    def shells(self) -> list[dict]:
        result = []
        for pid in self.marker_processes():
            try:
                identity = proc_identity(pid)
            except (OSError, ValueError, IndexError):
                continue
            if identity["ppid"] != self.gpid or identity["state"] == "Z" or pid in self.ignored:
                continue
            argv = cmdline_of(pid)
            # The detected Bash profile runs as bash or as "/bin/sh -c '/usr/bin/bash --posix'" (shell integration).
            role = environ_of(pid).get("GX_LC_ROLE") or ("bash-profile" if any(part.split()[0].endswith("/bash") for part in argv[:3] if part.strip()) else "unknown")
            result.append({**identity, "role": role, "cmdline": argv})
        return sorted(result, key=lambda item: item["starttime"])

    def by_role(self, role: str) -> list[dict]:
        return [shell for shell in self.shells() if shell["role"] == role]

    def new_shell(self, role: str, known: set, timeout: float = 20.0) -> dict:
        found = self.wait(f"a new {role} terminal", lambda: [s for s in self.by_role(role) if s["pid"] not in known], timeout)
        if len(found) != 1:
            raise Failure(f"expected one new {role} terminal, found {len(found)}")
        return found[0]

    def pty_indices(self) -> list[int]:
        result = []
        root = Path("/proc") / str(self.gpid)
        for fd in (root / "fd").iterdir():
            try:
                if os.readlink(fd) not in ("/dev/ptmx", "/dev/pts/ptmx"):
                    continue
                info = (root / "fdinfo" / fd.name).read_text()
            except OSError:
                continue
            match = re.search(r"^tty-index:\s*(\d+)", info, re.M)
            if match:
                result.append(int(match.group(1)))
        return sorted(result)

    def snapshot_identity(self, key: str, shell: dict, stage: str) -> dict:
        current = proc_identity(shell["pid"])
        current["ghostty_pty_indices"] = self.pty_indices()
        self.report["identities"].setdefault(key, []).append({"stage": stage, **current})
        return current

    def check_same_terminal(self, key: str, original: dict, stage: str) -> None:
        current = self.snapshot_identity(key, original, stage)
        fields = ("pid", "ppid", "session", "tty_nr", "starttime", "fd0")
        pts = int(original["fd0"].rsplit("/", 1)[1]) if (original["fd0"] or "").startswith("/dev/pts/") else None
        self.check(f"{stage}: {key} keeps PID, parent, starttime, session and PTY",
                   all(current[f] == original[f] for f in fields) and current["state"] != "Z",
                   {"original": {f: original[f] for f in fields}, "current": {f: current[f] for f in fields}})
        self.check(f"{stage}: ghostty {self.gpid} still holds the PTY master of {original['fd0']}",
                   pts is not None and pts in current["ghostty_pty_indices"],
                   {"pts": pts, "ghostty_ptmx_tty_indices": current["ghostty_pty_indices"]})

    # ---- X11 input and windows
    def xdo(self, *argv: str, check: bool = True) -> str:
        self.require_alive()
        result = subprocess.run(["xdotool", *argv], capture_output=True, text=True, timeout=30)
        if check and result.returncode != 0:
            raise Failure(f"xdotool {' '.join(argv)} failed: {result.stderr.strip()}")
        return result.stdout

    def key(self, combo: str, settle: float = 1.0) -> None:
        self.log(f"key {combo}")
        self.xdo("key", "--clearmodifiers", combo)
        time.sleep(settle)

    def type(self, text: str, settle: float = 0.4) -> None:
        self.log(f"type {text!r}")
        self.xdo("type", "--clearmodifiers", "--delay", "15", text)
        time.sleep(settle)

    def click(self, x: int, y: int, settle: float = 0.8) -> None:
        self.log(f"click {x},{y}")
        self.xdo("mousemove", str(x), str(y))
        time.sleep(0.15)
        self.xdo("click", "1")
        time.sleep(settle)

    def focus(self, window_id: str, click: tuple[int, int] | None = None) -> None:
        """Give one toplevel the X input focus (Xvfb has no window manager) and verify it."""
        if click:
            self.click(*click, 0.4)
        self.xdo("windowfocus", "--sync", window_id)
        time.sleep(0.5)
        focused = self.xdo("getwindowfocus", check=False).strip()
        self.log(f"focus {window_id} -> X focus {focused}")
        if focused != window_id:
            raise Failure(f"X focus is {focused}, not {window_id}")

    def windows(self) -> list[dict]:
        found = self.xdo("search", "--onlyvisible", "--pid", str(self.gpid), check=False).split()
        result = []
        for window in found:
            geometry = self.xdo("getwindowgeometry", "--shell", window, check=False)
            values = dict(line.split("=", 1) for line in geometry.splitlines() if "=" in line)
            if not {"X", "Y", "WIDTH", "HEIGHT"} <= values.keys():
                continue
            result.append({"id": window, "x": int(values["X"]), "y": int(values["Y"]),
                           "width": int(values["WIDTH"]), "height": int(values["HEIGHT"]),
                           "name": self.xdo("getwindowname", window, check=False).strip()})
        return result

    def terminal_windows(self) -> list[dict]:
        return [w for w in self.windows() if w["width"] >= 400 and w["height"] >= 300]

    def shot(self, name: str, expect: str) -> None:
        path = self.out / f"{len(self.report['shots']) + 1:02d}-{self.session_label}-{name}.png"
        subprocess.run(["scrot", str(path)], check=True, timeout=30)
        if path.stat().st_size == 0:
            raise Failure(f"empty screenshot {path.name}")
        windows = self.windows() if self.alive() else []
        self.report["shots"].append({"file": path.name, "session": self.session_label, "expect": expect,
                                     "windows": windows, "sha256": sha256_file(path)})
        self.log(f"screenshot {path.name}")

    def size_window(self, window_id: str, size: tuple[int, int]) -> None:
        self.log(f"windowsize {window_id} {size[0]}x{size[1]}")
        self.xdo("windowsize", window_id, str(size[0]), str(size[1]))
        time.sleep(1.0)
        current = next((w for w in self.windows() if w["id"] == window_id), None)
        if current is None or abs(current["width"] - size[0]) > 2 or abs(current["height"] - size[1]) > 2:
            raise Failure(f"window {window_id} did not take {size[0]}x{size[1]}: {current}")

    def scroll_down(self, at: tuple[int, int], clicks: int) -> None:
        self.log(f"scroll down x{clicks} at {at[0]},{at[1]}")
        self.xdo("mousemove", str(at[0]), str(at[1]))
        self.xdo("click", "--repeat", str(clicks), "--delay", "15", "5")
        time.sleep(0.6)

    def type_marker(self, name: str, shell: dict, stage: str) -> None:
        target = self.marks / name
        self.type(f"printf '%s %s\\n' \"$$\" \"$(tty)\" >{target}")
        self.key("Return", 0.3)
        text = self.wait(f"marker {name}", lambda: target.exists() and target.read_text().strip(), 10)
        pid_text, tty = text.split()
        self.check(f"{stage}: typed input reached the original terminal",
                   int(pid_text) == shell["pid"] and tty == shell["fd0"],
                   {"marker": text, "expected_pid": shell["pid"], "expected_tty": shell["fd0"]})

    # ---- files
    def log_count(self, text: str) -> int:
        path = self.out / f"ghostty-{self.session_label}.log"
        try:
            return path.read_text(encoding="utf-8", errors="replace").count(text)
        except OSError:
            return 0

    def panic_lines(self) -> list[str]:
        path = self.out / f"ghostty-{self.session_label}.log"
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return []
        for index, line in enumerate(lines):
            if " panic: " in line:
                return lines[index:index + 8]
        return []

    def overlay_text(self) -> str:
        path = self.config_home / "ghostty" / "gui-settings.ghostty"
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def session_path(self) -> Path:
        return self.state_home / "ghostty" / "gx-session.json"

    def read_session(self):
        try:
            return json.loads(self.session_path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    def copy_state(self, suffix: str) -> None:
        source = self.state_home / "ghostty"
        if source.is_dir():
            for path in sorted(source.iterdir()):
                if path.is_file() and not path.name.endswith(".lock"):
                    shutil.copyfile(path, self.out / f"state-{suffix}-{path.name}")
        overlay = self.config_home / "ghostty" / "gui-settings.ghostty"
        if overlay.exists():
            shutil.copyfile(overlay, self.out / f"gui-settings-{suffix}.ghostty")

    @staticmethod
    def structure(document: dict) -> list:
        windows = []
        for window in document["windows"]:
            tabs = []
            for tab in window["tabs"]:
                def node(index, tab=tab):
                    value = tab["nodes"][index]
                    if value.get("leaf"):
                        return value["leaf"]["profile_id"]
                    split = value["split"]
                    return [split["axis"], node(split["first"]), node(split["second"])]
                tabs.append(node(tab.get("root", 0)))
            windows.append({"tabs": tabs, "active": window["active"]})
        return windows

    def write_report(self) -> None:
        (self.out / "result.json").write_text(json.dumps(self.report, indent=2, ensure_ascii=False, default=str) + "\n",
                                              encoding="utf-8", newline="\n")
        lines = [f"GTK lifecycle fixture run {self.run_id}: automated {self.report.get('automated_result')}",
                 "Read every screenshot before recording PASS. Expected:"]
        lines += [f"- {shot['file']}: {shot['expect']}" for shot in self.report["shots"]]
        failed = [check["name"] for check in self.report["checks"] if check["status"] != "PASS"]
        lines += ["", f"checks: {len(self.report['checks'])} total, {len(failed)} failed"] + [f"  FAIL {name}" for name in failed]
        if self.report["errors"]:
            lines += ["", "errors:"] + [f"  {error}" for error in self.report["errors"]]
        (self.out / "notes.txt").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")

    def repro(self) -> None:
        """Minimal close-window check: control (split, no move) vs. split left behind by move-to-tab."""
        self.launch("repro")
        self.wait("the first terminal window", self.terminal_windows, 60)
        time.sleep(3)
        first = self.wait("the first terminal", lambda: self.by_role("temp"), 20)[0]
        results = {}
        for variant in ("control-split-no-move", "split-left-by-move-to-tab"):
            window = self.terminal_windows()[0]
            self.focus(window["id"], (window["x"] + 400, window["y"] + 360))
            known = {s["pid"] for s in self.shells()}
            self.key("ctrl+alt+o", 1.0)
            right = self.new_shell("default", known)
            if variant == "split-left-by-move-to-tab":
                self.key("ctrl+alt+h", 0.8)
                self.key("ctrl+alt+m", 1.5)
            doomed = {first["pid"]: first, right["pid"]: right}
            self.shot(f"{variant}-before-close", f"{variant}: the window about to be closed")
            known = {s["pid"] for s in self.shells()}
            self.key("ctrl+shift+n", 1.5)
            spare_shell = self.new_shell("default", known)
            spare = next(w for w in self.terminal_windows() if w["id"] != window["id"])
            self.xdo("windowmove", spare["id"], "440", "170")
            time.sleep(1.0)
            closed_before = self.log_count("surface closed")
            self.focus(window["id"], (200, 420))
            self.key("ctrl+alt+x", 1.0)
            self.wait("the window to close", lambda: window["id"] not in {w["id"] for w in self.terminal_windows()}, 15)
            exited = self.wait_quiet(lambda: not ({s["pid"] for s in self.shells()} & set(doomed)), 15)
            still = [{k: s[k] for k in ("pid", "role", "fd0")} for s in self.shells() if s["pid"] in doomed]
            results[variant] = {"closed_window_terminals": [{k: s[k] for k in ("pid", "role", "fd0")} for s in doomed.values()],
                                "still_running": still, "ghostty_ptmx_tty_indices": self.pty_indices(),
                                "surface_closed_log_lines": self.log_count("surface closed") - closed_before}
            self.defect(f"repro {variant}: every terminal of the closed window exits", exited, results[variant])
            self.ignored |= {s["pid"] for s in still}
            self.shot(f"{variant}-after-close", f"{variant}: only the spare window remains at 440,170")
            first = spare_shell
        self.report["repro"] = results
        remaining = self.terminal_windows()[0]
        self.focus(remaining["id"], (remaining["x"] + 400, remaining["y"] + 330))
        self.key("ctrl+alt+q", 0.5)
        self.check("repro: quit exits cleanly", self.wait_exit() == 0, None)
        self.check("repro: no terminal process outlives the quit", self.wait_quiet(lambda: not self.marker_processes(), 10),
                   [cmdline_of(p) for p in self.marker_processes()])

    def quit_probe(self) -> None:
        """Which step makes quit abort? Each variant quits right after one step; state is reset unless kept."""
        overlay = self.config_home / "ghostty" / "gui-settings.ghostty"
        results = {}
        basic = (
            ("one-terminal", [], False, False, False), ("two-tabs", ["ctrl+shift+t"], False, False, False),
            ("one-split", ["ctrl+alt+o"], False, False, False), ("bash-profile-tab", ["ctrl+alt+b"], False, False, False),
            ("shortcuts-dialog", ["ctrl+alt+k", "Escape"], False, False, False),
            ("custom-profile-tab", ["ctrl+alt+j"], False, True, False),
            ("restore-custom-approved", [], True, True, True),
        )
        targeted = (
            # A split left in the source tab, which move-to-tab leaves unselected.
            ("move-to-tab-then-quit", ["ctrl+alt+o", "ctrl+alt+h", "ctrl+alt+m"], False, False, False),
            ("move-to-tab-revisit-source-then-quit", ["ctrl+alt+o", "ctrl+alt+h", "ctrl+alt+m", "ctrl+alt+1"], False, False, False),
            # Restore two tabs; the second is adopted while unselected.
            ("save-custom-and-bash-tabs", ["ctrl+alt+j", "ctrl+alt+b"], False, True, False),
            ("restore-two-tabs-no-visit-then-quit", [], True, True, True),
            ("restore-two-tabs-visit-second-then-quit", ["ctrl+alt+2"], True, True, True),
        )
        # A saved [custom, bash] session with the custom tab selected, then restores that each start from it.
        prep = ("prep-save-custom-selected", ["ctrl+alt+j", "ctrl+alt+b", "ctrl+alt+2"], False, True, False)
        restore = (
            prep,
            ("restore-quit", [], "snapshot", True, True),
            ("restore-visit-bash-quit", ["ctrl+alt+2"], "snapshot", True, True),
            ("restore-visit-bash-back-quit", ["ctrl+alt+2", "ctrl+alt+1"], "snapshot", True, True),
            ("restore-new-tab-quit", ["ctrl+alt+j"], "snapshot", True, True),
            ("restore-visit-back-new-tab-quit", ["ctrl+alt+2", "ctrl+alt+1", "ctrl+alt+j"], "snapshot", True, True),
            # Same keys without restore: temp tab, custom tab, bash tab, then switch and open another tab.
            ("control-no-restore-same-keys", ["ctrl+alt+j", "ctrl+alt+b", "ctrl+alt+2", "ctrl+alt+3", "ctrl+alt+2", "ctrl+alt+j"], False, True, False),
        )
        # Set B: is it the approval dialog or switching back to an earlier restored tab?
        restore_b = (
            ("prep-save-bash-bash-first-selected", ["ctrl+alt+b", "ctrl+alt+b", "ctrl+alt+2"], False, False, False),
            ("restore-trusted-first-selected-quit", [], "snapshot", False, False),
            ("prep-save-bash-bash-last-selected", ["ctrl+alt+b", "ctrl+alt+b"], False, False, False),
            ("restore-trusted-last-selected-quit", [], "snapshot", False, False),
            ("prep-save-custom-bash-last-selected", ["ctrl+alt+j", "ctrl+alt+b"], False, True, False),
            ("restore-approved-custom-unselected-visit-quit", ["ctrl+alt+1"], "snapshot", True, True),
        )
        if self.args.restore_probe == "b":
            variants = restore_b
        else:
            variants = restore if self.args.restore_probe else targeted if self.args.targeted else basic
        snapshot = self.work / "state-snapshot"
        for variant, keys, keep_state, custom, approve in variants:
            if keep_state == "snapshot":
                shutil.rmtree(self.state_home, ignore_errors=True)
                shutil.copytree(snapshot, self.state_home)
            elif not keep_state:
                shutil.rmtree(self.state_home, ignore_errors=True)
            if custom:
                overlay.write_text(f"gx-launch-profile = {PROFILE_NAME}={PROFILE_COMMAND}\nkeybind = {BINDING}\n", encoding="utf-8")
            elif overlay.exists():
                overlay.unlink()
            self.launch(f"quit-{variant}")
            if approve:
                self.wait("the restore confirmation", self.windows, 60)
                time.sleep(2)
                box = self.windows()[0]
                for offset in (40, 30, 52, 22):
                    self.click(box["x"] + box["width"] * 3 // 4, box["y"] + box["height"] - offset, 1.0)
                    if self.wait_quiet(lambda: self.by_role("profile"), 6):
                        break
            window = self.wait("the window", self.terminal_windows, 60)[0]
            time.sleep(3)
            self.focus(window["id"], (window["x"] + 400, window["y"] + 360))
            for combo in keys:
                self.key(combo, 1.5)
            self.shot("before-quit", f"{variant}: the window just before quit")
            roles = sorted(s["role"] for s in self.shells())
            self.key("ctrl+alt+q", 0.5)
            code = self.wait_exit()
            results[variant] = {"exit": code, "roles_before_quit": roles, "panic": self.panic_lines(),
                                "surface_started": self.log_count("started subcommand"),
                                "surface_closed": self.log_count("surface closed")}
            if variant.startswith("prep-"):
                shutil.rmtree(snapshot, ignore_errors=True)
                shutil.copytree(self.state_home, snapshot)
                self.copy_state(variant)
            self.defect(f"quit probe {variant}: quit exits cleanly", code == 0, results[variant])
            self.kill_leftovers()
        self.report["quit_probe"] = results

    def run(self) -> int:
        try:
            self.write_config()
            self.record_build()
            if self.args.repro:
                self.repro()
            elif self.args.quit_probe:
                self.quit_probe()
            else:
                self.session_one()
                if not self.args.explore:
                    self.session_two()
            failed = [c for c in self.report["checks"] if c["status"] != "PASS"]
            self.report["automated_result"] = "FAIL (continued past product defects)" if failed else "PASS"
        except Failure as exc:
            self.report["automated_result"] = "FAIL"
            self.report["errors"].append(str(exc))
            self.log(f"FAILED: {exc}")
            try:
                if self.alive():
                    self.shot("failure", "state at the failure (diagnostic only)")
            except Exception as shot_error:  # noqa: BLE001
                self.report["errors"].append(f"failure screenshot: {shot_error}")
        except Exception as exc:  # noqa: BLE001
            self.report["automated_result"] = "ERROR"
            self.report["errors"].append(traceback.format_exc())
            self.log(f"ERROR: {exc!r}")
        finally:
            self.stop()
            leftovers = self.kill_leftovers()
            if leftovers:
                self.report["errors"].append({"leftover_processes_killed": leftovers})
            self.copy_state("final")
            self.report["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            self.write_report()
            self.log_handle.close()
            shutil.rmtree(self.work, ignore_errors=True)
        return 0 if self.report.get("automated_result") == "PASS" else 1


    # ---- session 1: editors, transfers, close, resize, quit
    def session_one(self) -> None:
        self.launch("session1")
        self.wait("the first terminal window", self.terminal_windows, 60)
        time.sleep(3)
        self.check("session1: one window at startup", len(self.terminal_windows()) == 1, self.terminal_windows())
        temp = self.wait("the temporary initial-command terminal", lambda: self.by_role("temp"), 20)
        self.check("session1: the first terminal runs the temporary initial command",
                   len(temp) == 1 and not self.by_role("default"), [s["cmdline"] for s in self.shells()])
        terminal = temp[0]
        self.snapshot_identity("temp", terminal, "launch")
        self.click(*LAYOUT["terminal"])
        self.shot("start", "one GX window, one tab, prompt TEMP$ from the temporary initial command")

        # Launch profiles: new-tab dropdown -> Edit Launch Profiles... opens the
        # Shell page of the settings dialog; New Launch Profile opens a subpage.
        first = self.terminal_windows()[0]["id"]
        self.size_window(first, PM_WINDOW)
        self.key("ctrl+alt+n", 1.2)
        self.shot("new-tab-menu", "the new-tab dropdown lists the detected profiles and ends with Set Default Shell... and Edit Launch Profiles...")
        self.click(*LAYOUT["menu_edit_profiles"], 1.5)
        self.shot("shell-page", "the settings dialog opened on the Shell page (Shell selected in the page switcher in the title bar) with Default Shell and the Launch Profiles group")
        self.scroll_down(LAYOUT["pm_scroll"], 15)
        self.shot("profile-list", "the Shell page scrolled to its end: launch profile rows and New Launch Profile as the last row")
        self.click(*LAYOUT["pm_new_profile"], 1.0)
        if self.args.explore:
            self.shot("profile-new", "the New Launch Profile subpage: empty focused name entry, command entry, insensitive Save in the header bar")
            self.key("Escape", 0.8)
            self.key("Escape", 1.0)
        else:
            self.type(PROFILE_NAME)
            self.key("Tab", 0.4)
            self.type(PROFILE_COMMAND)
            self.shot("profile-draft", f"the New Launch Profile subpage holds the name {PROFILE_NAME} and its command; Save is sensitive")
            self.key("Return", 1.0)
            self.shot("profile-saved", f"back on the launch profile list with {PROFILE_NAME} as the new focused last profile row and the toast Launch profiles saved.")
            self.check("session1: the Shell page saved the custom profile to gui-settings.ghostty",
                       f"{PROFILE_NAME}={PROFILE_COMMAND}" in self.overlay_text(), self.overlay_text())
            # Escape first dismisses a visible toast; let it time out so Escape closes the dialog.
            # The toast pauses its timeout while hovered and sits right under New Launch Profile,
            # so move the pointer off it first.
            self.xdo("mousemove", str(LAYOUT["pm_scroll"][0]), str(LAYOUT["pm_scroll"][1]))
            time.sleep(2.2)
            self.key("Escape", 1.0)
        self.size_window(first, DEFAULT_WINDOW)
        self.click(*LAYOUT["terminal"], 0.6)
        self.shot("settings-closed", "the settings dialog is closed; the TEMP$ terminal fills the 800x600 window again")

        # Shortcut editor: Keyboard Shortcuts -> Edit Keyboard Shortcuts -> New Advanced Shortcut.
        self.size_window(first, ED_WINDOW)
        self.click(*LAYOUT["terminal"], 0.6)
        self.key("ctrl+alt+k", 1.5)
        self.shot("shortcuts", "the Keyboard Shortcuts reference with the Edit Keyboard Shortcuts header button")
        self.click(*LAYOUT["cheat_edit"], 1.5)
        self.shot("shortcut-editor", "the shortcut editor list: search, category groups with keycaps and source badges, + in the header bar")
        self.scroll_down(LAYOUT["ed_scroll"], 200)
        self.shot("shortcut-list-end", "the editor list scrolled to its end with New Advanced Shortcut as the last row")
        self.click(*LAYOUT["ed_new_advanced"], 1.0)
        if self.args.explore:
            self.shot("advanced-new", "the New Advanced Shortcut page with an empty raw keybind text view and Save in the header bar")
            for _ in range(3):
                self.key("Escape", 0.8)
            self.size_window(first, DEFAULT_WINDOW)
            self.click(*LAYOUT["terminal"], 0.6)
            self.shot("explore-closed", "dialogs closed, the TEMP$ terminal is visible")
            self.key("ctrl+alt+q", 0.5)
            self.log(f"explore: ghostty exited with {self.wait_exit()}")
            return
        self.type(BINDING)
        self.shot("binding-typed", f"New Advanced Shortcut: the raw text view holds {BINDING} before Save")
        self.click(*LAYOUT["ed_save"], 1.5)
        self.shot("binding-saved", "back on the editor list, scrolled to the top, with the banner Keyboard shortcuts saved.")
        self.check("session1: the shortcut editor saved the binding to gui-settings.ghostty",
                   BINDING in self.overlay_text(), self.overlay_text())
        self.check("session1: the editors changed nothing but the profile and the binding (default command untouched)",
                   not any(line.startswith("command") for line in self.overlay_text().splitlines()), self.overlay_text())
        self.copy_state("after-editors")
        # List -> Escape closes the editor, Escape again the shortcut reference.
        self.key("Escape", 0.8)
        self.key("Escape", 0.8)
        self.size_window(first, DEFAULT_WINDOW)
        self.click(*LAYOUT["terminal"], 0.6)
        self.shot("dialogs-closed", "both dialogs are closed; the TEMP$ terminal fills the 800x600 window again")

        # The saved binding launches the saved profile right away.
        known = {s["pid"] for s in self.shells()}
        self.key("ctrl+alt+j", 1.0)
        profile = self.new_shell("profile", known)
        self.check("session1: the saved binding opened the saved profile in this window",
                   len(self.terminal_windows()) == 1, profile["cmdline"])
        self.shot("saved-binding-profile-tab", "two tabs; the selected second tab shows PROFILE$ (saved binding -> saved profile)")

        # Move the original terminal (TEMP$) out of a split into a new tab.
        self.key("ctrl+alt+1", 1.0)
        known = {s["pid"] for s in self.shells()}
        self.key("ctrl+alt+o", 1.0)
        self.new_shell("default", known)
        self.key("ctrl+alt+h", 0.8)
        self.type_marker("t1-before-tab", terminal, "before move to tab")
        self.key("ctrl+alt+m", 1.5)
        self.check("move to tab: still one window", len(self.terminal_windows()) == 1, self.terminal_windows())
        self.check_same_terminal("temp", terminal, "move to tab")
        self.type_marker("t2-after-tab", terminal, "after move to tab")
        self.shot("split-moved-to-tab", "three tabs; the selected new tab (inserted right after the source tab) has one TEMP$ pane holding both printf marker commands")

        # Move it again, now out of a split into a new window.
        known = {s["pid"] for s in self.shells()}
        self.key("ctrl+alt+o", 1.0)
        self.new_shell("default", known)
        self.key("ctrl+alt+h", 0.8)
        self.type_marker("t3-before-window", terminal, "before move to window")
        old = {w["id"] for w in self.terminal_windows()}
        self.key("ctrl+alt+w", 1.0)
        windows = self.wait("the new window", lambda: (lambda ws: ws if len(ws) == 2 else None)(self.terminal_windows()), 15)
        time.sleep(1.5)
        w2 = next(w for w in windows if w["id"] not in old)
        self.check_same_terminal("temp", terminal, "move to window")
        self.xdo("windowmove", w2["id"], str(W2_POSITION[0]), str(W2_POSITION[1]))
        time.sleep(1.5)
        placed = {w["id"]: w for w in self.terminal_windows()}
        self.check("move to window: the new window can be placed beside the old one",
                   (placed[w2["id"]]["x"], placed[w2["id"]]["y"]) == W2_POSITION, placed)
        self.shot("split-moved-to-window", "two windows: the old one at the origin (three tabs, the left-over DEFAULT$ pane selected) and the new one at 440,170 with only the TEMP$ pane")

        # Close the old window, with the keyboard focus explicitly on it.
        w1 = next(w for w in windows if w["id"] in old)
        self.focus(w1["id"], (200, 420))
        doomed = {s["pid"]: s for s in self.shells() if s["pid"] != terminal["pid"]}
        self.report["identities"]["old_window_terminals"] = list(doomed.values())
        closed_before = self.log_count("surface closed")
        self.key("ctrl+alt+x", 1.0)
        self.wait("the old window to close", lambda: [w["id"] for w in self.terminal_windows()] == [w2["id"]], 15)
        exited = self.wait_quiet(lambda: not ({s["pid"] for s in self.shells()} & set(doomed)), 15)
        left = [doomed[s["pid"]] | {"state_now": s["state"]} for s in self.shells() if s["pid"] in doomed]
        if not self.defect("close old window: every terminal of the old window exits", exited,
                   {"old_window_terminals": [{k: v[k] for k in ("pid", "role", "fd0")} for v in doomed.values()],
                    "still_running": [{k: v[k] for k in ("pid", "role", "fd0", "state_now")} for v in left],
                    "ghostty_ptmx_tty_indices": self.pty_indices(),
                    "surface_closed_log_lines": self.log_count("surface closed") - closed_before}):
            # Keep the leaked shell out of later terminal counts; it is still reported and must die at quit.
            self.ignored |= {v["pid"] for v in left}
            self.report["leaked_after_close"] = left
        self.check("close old window: only the moved window and terminal remain",
                   [s["pid"] for s in self.shells()] == [terminal["pid"]], [s["cmdline"] for s in self.shells()])
        self.check_same_terminal("temp", terminal, "close old window")
        self.shot("old-window-closed", "only the moved window remains (at 440,170) with the TEMP$ terminal")

        # Keep typing into the original terminal.
        self.focus(w2["id"], (W2_POSITION[0] + 400, W2_POSITION[1] + 330))
        self.type_marker("t4-after-close", terminal, "after closing the old window")
        self.type("echo LC-CONTINUE-OK")
        self.key("Return", 0.8)
        self.check_same_terminal("temp", terminal, "continued input")
        self.shot("continued-input", "the TEMP$ terminal shows all four printf marker commands and LC-CONTINUE-OK in one scrollback")

        # A restorable layout: custom profile (needs approval), trusted bash
        # profile split with an unknown default-command pane (collapses on save).
        known = {s["pid"] for s in self.shells()}
        self.key("ctrl+alt+j", 1.0)
        profile = self.new_shell("profile", known)
        known.add(profile["pid"])
        self.key("ctrl+alt+b", 1.0)
        bash = self.new_shell("bash-profile", known)
        known.add(bash["pid"])
        self.key("ctrl+alt+o", 1.0)
        self.new_shell("default", known)
        self.key("ctrl+alt+2", 1.0)
        self.report["identities"]["restorable"] = {"profile": profile, "bash": bash}
        self.shot("restorable-layout", "one window, three tabs (TEMP$, PROFILE$, Bash split with DEFAULT$); the middle PROFILE$ tab is selected")

        # Resize, then quit: a quit keeps the session (closing the last window clears it).
        self.xdo("windowmove", w2["id"], "100", "60")
        time.sleep(1.0)
        self.xdo("windowsize", w2["id"], str(RESIZE[0]), str(RESIZE[1]))
        time.sleep(2.0)
        resized = next(w for w in self.terminal_windows() if w["id"] == w2["id"])
        self.check("resize: the window took the requested size",
                   abs(resized["width"] - RESIZE[0]) <= 2 and abs(resized["height"] - RESIZE[1]) <= 2, resized)
        self.report["pre_quit_window"] = resized
        self.shot("resized", f"the window is {RESIZE[0]}x{RESIZE[1]} at 100,60 with the terminal grid filling it; PROFILE$ tab selected")
        self.key("ctrl+alt+q", 0.5)
        code = self.wait_exit()
        self.defect("session1: quit exits cleanly", code == 0, {"exit": code, "panic": self.panic_lines()})
        if not self.defect("session1: no terminal process outlives the quit",
                           self.wait_quiet(lambda: not self.marker_processes(), 10),
                           [{"pid": p, "cmdline": cmdline_of(p)} for p in self.marker_processes()]):
            self.report["killed_after_session1"] = self.kill_leftovers()
        self.ignored = set()
        self.copy_state("after-quit")
        document = self.read_session()
        self.check("session1: gx-session.json exists and parses", document is not None, str(self.session_path()))
        self.report["session_after_quit"] = document
        structure = self.structure(document)
        self.check("saved session: one window with the custom and bash profiles; the temp leaf and unknown split are skipped",
                   structure == [{"tabs": ["custom:" + PROFILE_NAME, "bash"], "active": 0}] and document.get("skipped_leaves") == 2,
                   {"structure": structure, "skipped_leaves": document.get("skipped_leaves")})
        geometry = document["windows"][0].get("geometry") or {}
        self.check("saved session: geometry is the resized window size",
                   abs(geometry.get("width", 0) - resized["width"]) <= 2 and abs(geometry.get("height", 0) - resized["height"]) <= 2,
                   {"saved": geometry, "x11": resized})
        raw = self.session_path().read_text(encoding="utf-8")
        self.check("saved session: no command, environment or transcript is stored",
                   all(token not in raw for token in ("GX_LC_ROLE", "printf", "LC-CONTINUE", "/usr/bin/env")), None)

    # ---- session 2: gx-session-restore
    def session_two(self) -> None:
        saved = self.report["session_after_quit"]
        self.launch("session2")
        self.wait("the restore confirmation", self.windows, 60)
        time.sleep(3)
        dialog = self.windows()
        self.check("restore: only a confirmation window is shown and no terminal starts before approval",
                   len(dialog) == 1 and not self.terminal_windows(),
                   {"windows": dialog, "shells": self.shells()})
        self.check("restore: no terminal process runs before approval", not self.shells(), [s["cmdline"] for s in self.shells()])
        self.shot("restore-confirm", f"the Restore custom launch profile? dialog names {PROFILE_NAME} and its current command, offers Skip and Restore; no terminal window")
        box = dialog[0]
        for offset in (40, 30, 52, 22):
            self.click(box["x"] + box["width"] * 3 // 4, box["y"] + box["height"] - offset, 1.0)
            if self.wait_quiet(lambda: self.by_role("profile"), 8):
                break
        self.wait("the approved custom profile terminal", lambda: self.by_role("profile"), 20)
        self.wait("the restored window", self.terminal_windows, 20)
        time.sleep(2.5)
        restored = self.terminal_windows()
        pre = self.report["pre_quit_window"]
        self.check("restore: one window with the saved geometry",
                   len(restored) == 1 and abs(restored[0]["width"] - pre["width"]) <= 2 and abs(restored[0]["height"] - pre["height"]) <= 2,
                   {"restored": restored, "before_quit": pre, "saved": saved["windows"][0].get("geometry")})
        self.check("restore: the temporary initial command and the unknown split were not replayed",
                   not self.by_role("temp") and not self.by_role("default"), [s["cmdline"] for s in self.shells()])
        self.shot("restored", f"one {pre['width']}x{pre['height']} window with two tabs; the selected first tab shows PROFILE$; the second (Bash) tab is not started yet; a toast says some terminals were not restored")
        # The non-selected restored tab starts its terminal when it is first shown.
        self.focus(restored[0]["id"], (restored[0]["x"] + 400, restored[0]["y"] + 360))
        self.key("ctrl+alt+2", 1.0)
        self.wait("the trusted bash profile terminal", lambda: self.by_role("bash-profile"), 20)
        time.sleep(1.5)
        shells = self.shells()
        self.check("restore: exactly the approved custom profile and the trusted bash profile run (no approval asked for bash)",
                   sorted(s["role"] for s in shells) == ["bash-profile", "profile"], [s["cmdline"] for s in shells])
        self.shot("restored-second-tab", "the second restored tab runs the trusted Bash profile in its saved working directory")

        def resaved_with_geometry():
            document = self.read_session()
            if document and document.get("generation", 0) > saved["generation"] and document["windows"] \
                    and document["windows"][0].get("geometry"):
                return document
            return None
        self.key("ctrl+alt+1", 1.0)
        resaved = self.wait_quiet(resaved_with_geometry, 20) and resaved_with_geometry()
        self.report["session_after_restore"] = resaved or self.read_session()
        if self.defect("restore: the app saved the restored session again", bool(resaved), self.read_session()):
            tabs = lambda document: [window["tabs"] for window in self.structure(document)]
            self.check("restore: the resaved windows, tabs and profiles match (the active tab follows the user's later switch)",
                       tabs(resaved) == tabs(saved), {"saved": self.structure(saved), "resaved": self.structure(resaved)})
            new_geometry = resaved["windows"][0]["geometry"]
            old_geometry = saved["windows"][0].get("geometry") or {}
            self.check("restore: the resaved geometry matches",
                       (new_geometry.get("width"), new_geometry.get("height")) == (old_geometry.get("width"), old_geometry.get("height")),
                       {"saved": old_geometry, "resaved": new_geometry})
        known = {s["pid"] for s in self.shells()}
        self.key("ctrl+alt+j", 1.0)
        self.new_shell("profile", known)
        self.shot("binding-after-restart", "a new PROFILE$ tab next to the current one: the binding saved in session 1 still works after the restart")
        self.copy_state("after-restore")
        self.key("ctrl+alt+q", 0.5)
        code = self.wait_exit()
        self.defect("session2: quit exits cleanly", code == 0, {"exit": code, "panic": self.panic_lines()})


def driver_main(args: argparse.Namespace) -> int:
    for key in ("DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
        if not os.environ.get(key):
            print(f"[gx-gtk-lifecycle] error: {key} is not set; run without --driver", flush=True)
            return 2
    exe = Path(os.path.expanduser(args.clone)) / "zig-out" / "bin" / "ghostty"
    if not exe.is_file():
        print(f"[gx-gtk-lifecycle] error: {exe} is missing", flush=True)
        return 2
    driver = Driver(args)
    code = driver.run()
    for session in driver.report["sessions"]:
        path = driver.out / session["log"]
        text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
        hits = [line for line in text.splitlines() if any(token in line for token in FORBID)]
        if hits:
            print(f"[gx-gtk-lifecycle] {path.name}: forbidden log lines: {hits[:3]}", flush=True)
            code = 1
    print(f"[gx-gtk-lifecycle] automated result {driver.report['automated_result']} (exit {code}); "
          f"screenshots still need reading; evidence {driver.out}", flush=True)
    return code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True, help="new evidence directory")
    parser.add_argument("--distro", default=DEFAULT_DISTRO)
    parser.add_argument("--clone", default=DEFAULT_CLONE, help="WSL clone holding zig-out/bin/ghostty")
    parser.add_argument("--explore", action="store_true", help="only screenshot the dialogs to calibrate clicks")
    parser.add_argument("--repro", action="store_true", help="minimal close-window check after move-to-tab, with a control")
    parser.add_argument("--quit-probe", action="store_true", help="does a plain quit exit cleanly (one terminal, two tabs, a split)")
    parser.add_argument("--targeted", action="store_true", help="with --quit-probe: the unselected-tab adoption variants")
    parser.add_argument("--restore-probe", nargs="?", const="a", choices=("a", "b"), help="with --quit-probe: restore variants (set a or b)")
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--driver", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    extra = (["--explore"] if args.explore else []) + (["--repro"] if args.repro else []) + (["--quit-probe"] if args.quit_probe else []) + (["--targeted"] if args.targeted else []) + ([f"--restore-probe={args.restore_probe}"] if args.restore_probe else [])
    if args.driver:
        return driver_main(args)
    if args.inside:
        return inside_main(args, extra)
    return host_main(args, extra)


if __name__ == "__main__":
    sys.exit(main())
