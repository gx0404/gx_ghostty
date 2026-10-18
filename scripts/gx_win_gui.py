#!/usr/bin/env python3
"""Windows GUI automation for Ghostty GX: isolated launches, guarded input, screenshots and scenarios.

Usage: python scripts/gx_win_gui.py COMMAND [ARGS...]      (just win-gui COMMAND [ARGS...])

Scenario commands (scenarios are TOML files, by default test/gui/win32/W*.toml):
  list [SCENARIO...]
        Print id, title, requirements and side effects of the scenarios.
  run [--out DIR] [--exe PATH] [--allow-side-effects] [--retries N] [--keep-open] [--allow-load-layouts]
      [SCENARIO...]
        Run scenarios one after another. Each gets DIR/<id>/ (default
        .local/evidence/win-gui/<time>/<id>/) with a fresh isolated profile in env/, its
        screenshots, run.json (every step with its timing and result), the Ghostty log and
        notes.txt (what each screenshot must show). A scenario whose requirement is missing
        (such as a WSL distro) is SKIPPED; one with side effects (such as opening the
        default browser) runs only with --allow-side-effects. A scenario whose ime_off or
        layout step needs a keyboard layout this user does not have loaded is BLOCKED before
        anything starts (run.json status blocked, with the reason): it did not run here.

Session commands drive one instance whose state is ENV_DIR/session.json:
  start ENV_DIR [--exe PATH] [--config FILE] [--env NAME=VALUE]... [--timeout S] [-- ARGS...]
  stop ENV_DIR                      close the instance (WM_CLOSE, then terminate it)
  windows ENV_DIR                   list its top-level windows and terminals
  activate ENV_DIR                  bring its main window to the foreground
  capture ENV_DIR OUT.png [--popups] [--quick] [--method screen|print]
          [--backdrop #RRGGBB | --no-backdrop REASON]           (see Privacy backdrop)
  pixel ENV_DIR X Y [--in ANCHOR] [--method screen|print] [--backdrop #RRGGBB | --no-backdrop REASON]
                                    print the color at a point
  type ENV_DIR TEXT                 KEYEVENTF_UNICODE, "\\n" is Enter
  key ENV_DIR CHORD [--repeat N]    real virtual keys with scan codes, e.g. ctrl+shift+t; oem1..oem8 and
                                    oem102 name the layout-dependent keys (VK_OEM_*, e.g. German ^ is
                                    oem5, the ISO <> key oem102)
  click ENV_DIR X Y [--in ANCHOR] [--button left|right|middle|x1|x2] [--count N] [--mods ctrl,...]
  wheel ENV_DIR X Y [--in ANCHOR] [--delta N] [--horizontal] [--count N] [--mods ctrl,shift,alt,...]
  drag ENV_DIR X1 Y1 X2 Y2 [--in ANCHOR] [--steps N] [--button B]
  wait-log ENV_DIR REGEX [--timeout S]
  dpi ENV_DIR DPI                   test hook WM_GHOSTTY_SIMULATE_DPI (WM_USER+0x47)
  d2d-failure ENV_DIR [--quick]     test hook WM_GHOSTTY_SIMULATE_D2D_FAILURE (WM_USER+0x4C)
  system-theme ENV_DIR [--scheme follow|light|dark] [--high-contrast follow|on|off]
                                    test hook WM_GHOSTTY_SIMULATE_SYSTEM_THEME (WM_USER+0x49)
  ime-off ENV_DIR                   switch the window's thread to a loaded US layout (never loads one)
  layout ENV_DIR [HKL|KLID] [--allow-load] [--list]
                                    switch the window's thread to a keyboard layout (see Keyboard
                                    layouts); without one, or with --list, print the loaded layouts
  cancel-mode ENV_DIR               SendMessage WM_CANCELMODE to the focused terminal

Scenario files: id, title and config (HARNESS_CONFIG is appended unless harness = false), optional
env, args, requires, side_effects, expect and wait_window (false: the steps start right after the
launch instead of when the main window shows, for a start that fails before it), and [[step]] tables
with an action and its keys
([bracketed] keys are optional; x/y/in/window address a point as described under Input safety):
  wait_window [timeout window]          activate [window]               sleep seconds
  wait_log pattern [timeout]            assert_log pattern [present]
  wait_file path pattern [timeout]      (the whole text of the file at path matches; see Paths)
  wait_title pattern [timeout window]   assert_title pattern [window]
  type text [delay repeat]              key keys [repeat delay]          clipboard text
  click [x y in window button count mods]           mouse_down / mouse_up [x y in window button mods]
  move [x y in window]                  drag from to [in window steps button]
  drag_divider between fraction [steps]             wheel [x y in window delta horizontal count mods]
  capture name [what=window|quick|popups|all method=screen|print]
  capture_window name [cls title timeout method]   another top-level window of the instance (not a
                                        GhosttyWindow; e.g. the MessageBox or TaskDialog of a failed
                                        start): class cls and/or title matching the regex title, waited
                                        for up to timeout (default 10 s, at most 120), saved like capture
                                        with PrintWindow (method = "print", the default) or the screen
  pixel [x y in window expect differs tolerance method label]
  dpi value                             ime_off                          cancel_mode [terminal]
  gpu_reset [terminal]                  assert_responsive [timeout]      resize width height
  wait_terminals count [timeout window] wait_popup [cls timeout present new]
  close [timeout]                       file path [text directory readonly]  (see below)
  backdrop [color enabled reason]       switch the privacy backdrop for the following steps
  layout target                         switch the window's thread to the keyboard layout target (an HKL
                                        such as "0x08040804" or a KLID such as "00000407"); switched back
                                        and unloaded at the end (see Keyboard layouts)
  restart [timeout env wait]            close the instance gracefully (WM_CLOSE, then wait up to timeout,
                                        default 10 s; it is never forced) and start it again on the same
                                        isolated profile and config, with the scenario env plus env (a
                                        table, e.g. env = { GHOSTTY_GX_A11Y = "screen-reader" }); wait =
                                        false skips waiting for the new main window. run.json: restarts
  simulate_d2d_failure [window]         the window's title bar acts as if Direct2D failed and falls
                                        back to the system caption (WM_USER+0x4C to that GhosttyWindow;
                                        checked with WM_GHOSTTY_CAPTION_QUERY bit 3)
  simulate_system_theme [scheme high_contrast]  the app acts as if Windows switched its apps color
                                        scheme (follow|light|dark) and high contrast (follow|on|off)
                                        without touching the Windows settings (WM_USER+0x49, wparam
                                        App.SimulatedSystemTheme); follow/follow returns to the system
A failed step stops the scenario; buttons a mouse_down step left pressed are released at the end. A
key, click or mouse_down whose SendInput fails part way releases its key, button and modifiers at once.
wheel with mods (a list such as ["ctrl"], e.g. Ctrl+wheel font zoom) presses those keys first, checks
the guards again, sends the notches and then always releases exactly those keys, also when a guard
or SendInput fails in between (audited as an abort release under GX_PERF_GUARD_LOG).

file: path is relative to the isolated profile and must stay inside it. text writes the file (UTF-8,
LF); directory = true creates the directory; readonly = true|false protects or releases the path.
A read-only file gets the read-only attribute; a directory, whose attribute Windows ignores for
writes, gets an inheritable ACL entry denying the current user DE, WD, AD, WEA, WA and DC: no new
files or subdirectories, and the entries inside can be neither written nor renamed nor deleted
(reading and listing still work; the directory itself stays renamable through its parent). Both are
probed after being set and after being released: a write attempt, and for a directory opening each
of its first 16 existing entries for DELETE access (which deletes nothing; run.json says when there
were none). Whatever is still read-only when the scenario ends or fails is released, after the
instance closed and whatever else the cleanup did (run.json: readonly). If the harness itself was
killed before that, the next run of the scenario resets the leftover entries before it empties the
directory; by hand: icacls "DIR" /reset /T /C /Q, then attrib -R "DIR\\*" /S /D.

Privacy backdrop: a scenario puts one solid window (backdrop = "#rrggbb", default #000000) right
under the lowest of its instance's windows. It covers the work area of every display monitor that
one of those windows, or a screen capture with the 24 DIP band around it, reaches (the whole monitor
where a window reaches past the work area, such as a fullscreen window over the taskbar); being one
window it is the bounding rectangle of those areas, and it only grows during a scenario. It is
borderless, never activated, not in the taskbar or Alt-Tab, and destroyed when the scenario ends or
fails. backdrop = false (with backdrop_reason, for a test that must see the desktop through the
window) turns it off, and notes.txt and run.json say so. Before every screen capture or pixel read
it is put back under the instance and checked: every pixel of the captured window must lie on a
covered area (a window partly on no monitor fails before anything is captured), the window must be
above the backdrop before and after the capture, no window of another process may show inside the
window or its band on the covered areas, and every band pixel outside the instance's windows must be
the backdrop color or its shadow; otherwise the step fails and the screenshot is not saved. A
backdrop that cannot be destroyed fails the scenario. run.json lists every check (covered areas,
band pieces, pixels counted, foreign windows by class, pid and image, no titles). The session
commands capture and pixel do the same with --method screen: a backdrop of their own (--backdrop,
default #000000) for that one command, destroyed before it returns (exit 1 when that fails);
--no-backdrop REASON captures without one and prints a warning. A window material (a
gx-window-material other than solid, or background-blur) makes DWM sample the desktop wallpaper,
which no backdrop covers; notes.txt says so for such a scenario.

Keyboard layouts: layout, the layout step and ime_off only switch to a layout GetKeyboardLayoutList
reports for this user: they post WM_INPUTLANGCHANGEREQUEST to the window's focused thread and wait up
to 2 s for GetKeyboardLayout to confirm it. They never call LoadKeyboardLayout and never change the
user's language list, so on the host a layout that is not loaded is refused. Only --allow-load (run:
--allow-load-layouts) loads a missing KLID (such as 00000407 for German dead keys) and unloads it
again at stop or at the end of the scenario, and only inside the test VM: GX_WIN_GUI_VM=1 must be set
and the firmware in HKLM\\HARDWARE\\DESCRIPTION\\System\\BIOS must be the VM's QEMU/OVMF (the pattern of
test/windows/gx_vm_validation.ps1); anywhere else the option is refused (exit code 2) before
anything starts, and run.json and notes.txt record the evidence. A plain KLID 0000LLLL names the HKL
0xLLLLLLLL and an IME KLID E0xxxxxx itself; other KLIDs (variants such as 00010407) need their HKL from
layout --list. Before the first switch the thread's layout is remembered; stop and the end of a
scenario switch back to it while the instance still runs. A missing layout is a missing host
precondition, not a failure: run checks every ime_off and layout step before it starts the scenario
and reports it BLOCKED; the commands ime-off and layout, and a step that meets one anyway, end
BLOCKED as well (exit code 3). Scenarios should not need a layout: bind the action under test to a
function key, which no input method takes, instead of switching layouts.

Isolation: LOCALAPPDATA and XDG_CONFIG_HOME point at ENV_DIR, so the configuration is
ENV_DIR/ghostty/config.ghostty and the log ENV_DIR/ghostty/logs/ghostty.log. APPDATA,
XDG_STATE_HOME and XDG_CACHE_HOME use ENV_DIR/appdata, ENV_DIR/state and ENV_DIR/cache;
--env cannot override these isolated paths. NO_COLOR, TERM, COLORTERM, TERM_PROGRAM*,
GHOSTTY_* and GHOSTTY_GX_* of the calling shell are removed (pass
GX switches such as GHOSTTY_GX_OPENGL=software with --env). Only the instance this tool
started is ever closed: before terminating it checks that the process still has the image
path and creation time it was started with.

Input safety: the process is Per-Monitor-V2 DPI aware and works in physical pixels.
Coordinates are DIP relative to an anchor (`client`, the main window's client area, or
`terminal:N`, the N-th visible terminal ordered top to bottom, left to right), converted
with the window's DPI (or the DPI a `dpi` step simulated); negative values count from the
right or bottom edge. Before every SendInput the foreground window must belong to the
instance, and before every mouse event the window under the point too, otherwise nothing is
sent and the command fails. Text is typed with KEYEVENTF_UNICODE; chords are real virtual
keys with scan codes and the extended-key flag. With GX_PERF_GUARD_LOG set (scripts/gx_perf.py
quiet-batch) every guard, release and unexpected end of the instance is appended as one
gx-input-guard-v1 JSON line; a refusal carries `cause` (instance_gone, instance_hung,
foreground_lost, pointer_target_lost, foreign_input, other) and title-free facts about the window in
the way. instance_hung: one of the instance's windows is hung (IsHungAppWindow), or the window in the
way is the Ghost Windows shows for a hung window or a WerFault dialog while the instance does not
answer WM_NULL within 2 s; quiet-batch reads it, like instance_gone, as a product failure. The same
vocabulary has instance_self_activated, written only by gx_perf win32-idle (without input the
instance took the foreground back or restored a minimized window), also a product failure.

Paths: the path of a wait_file step may use {log}, the absolute path of this scenario instance's
ghostty.log (ENV/ghostty/logs/ghostty.log), and {env}, its isolated profile directory ENV; write {{
and }} for literal braces. Placeholders are replaced first and inserted verbatim; environment
variables (%NAME%, $NAME, ${NAME}) in the rest of the path are expanded after them. An unknown
placeholder or an unbalanced brace fails when the scenario loads, never as a literal path. The
file: paths of `requires` take the same syntax but no placeholder: they are host prerequisites,
checked before the run, when this scenario's own profile does not exist yet.

Screenshots: `screen` (default) copies the window's visible bounds from the screen like
CopyFromScreen and fails if another process's window covers it; `print` uses PrintWindow with
PW_RENDERFULLCONTENT and works for covered windows. Popups (GhosttyGxPopup, scrollbars, dialogs)
are separate top-level windows of the process and are captured one by one.

Exit codes: 0 success; 1 a failed step, assertion or scenario; 2 usage errors, a missing
executable, or a platform other than Windows; 3 BLOCKED: a host precondition such as a keyboard
layout is missing (run: some scenario is BLOCKED and none failed), record it PENDING, never PASS.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as _datetime
import functools
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import threading
import time
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
TAG = "[gx-win-gui]"
DEFAULT_EXE = REPO_ROOT / "zig-out" / "bin" / "ghostty.exe"
SCENARIO_DIR = REPO_ROOT / "test" / "gui" / "win32"
EVIDENCE_ROOT = REPO_ROOT / ".local" / "evidence" / "win-gui"
SESSION_FILE = "session.json"
ENV_MARKER = ".gx-win-gui-env"

WINDOW_CLASS = "GhosttyWindow"
TERMINAL_CLASS = "GhosttyTerminal"
POPUP_CLASS = "GhosttyGxPopup"
DIALOG_CLASS = "#32770"

# Variables of the calling shell that would change what Ghostty or its shell shows.
STRIPPED_ENV = ("NO_COLOR", "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "GHOSTTY_LOG")
STRIPPED_ENV_PREFIXES = ("GHOSTTY_",)
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# The variables isolated_environment points into the profile; neither --env nor a scenario changes them.
ISOLATED_VARIABLES = ("LOCALAPPDATA", "APPDATA", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")

# Appended to every scenario configuration unless it sets harness = false: no close
# confirmation, so the harness can always close the instance it started.
HARNESS_CONFIG = "confirm-close-surface = false\n"

WM_NULL = 0x0000
WM_CLOSE = 0x0010
WM_CANCELMODE = 0x001F
WM_INPUTLANGCHANGEREQUEST = 0x0050
KLF_NOTELLSHELL = 0x0080
LAYOUT_SWITCH_S = 2.0  # how long the window's thread may take to switch its keyboard layout
WM_USER = 0x0400
WM_GHOSTTY_SIMULATE_DPI = WM_USER + 0x47
WM_GHOSTTY_SIMULATE_GPU_RESET = WM_USER + 0x48
# chrome/TitleBar.zig: handled by the title bar of the top-level GhosttyWindow before anything else.
WM_GHOSTTY_SIMULATE_D2D_FAILURE = WM_USER + 0x4C  # wparam/lparam unused; 1 = the native fallback is queued
WM_GHOSTTY_CAPTION_QUERY = WM_USER + 0x4D  # bit 0 active, 1 owner lock, 2 native buttons, 3 Direct2D failed
CAPTION_DIRECT2D_FAILED = 0b1000
# Window.zig: any GhosttyWindow; the whole app (every window) hears the broadcasts Windows would send.
WM_GHOSTTY_SIMULATE_SYSTEM_THEME = WM_USER + 0x49  # wparam App.SimulatedSystemTheme; 1 = simulated
SYSTEM_THEME_SCHEMES = {"follow": 0, "light": 1, "dark": 2}  # App.SimulatedSystemTheme.scheme (follow = system)
SYSTEM_THEME_HIGH_CONTRAST = {"follow": 0, "on": 1, "off": 2}  # .high_contrast, two bits above the scheme

# Privacy backdrop of scenario runs (Backdrop, BackdropWindow).
BACKDROP_DEFAULT = "#000000"
BACKDROP_CLASS = "GxWinGuiBackdrop"
BACKDROP_TITLE = "gx_win_gui privacy backdrop"
BACKDROP_BAND_DIP = 24  # band around a screen capture whose pixels must show the backdrop
BACKDROP_EDGE_PX = 2  # edges of the instance's windows (DWM border, antialiasing) left out of the band
BACKDROP_TOLERANCE = 2  # per channel
BACKDROP_SETTLE_S = 1.0  # how long a new or moved backdrop may take to paint and reach the screen
BACKDROP_COMPOSE_S = 0.05  # a few frames for DWM to compose a changed z-order before a capture
WS_POPUP = 0x80000000
WS_EX_TOOLWINDOW = 0x00000080
WS_EX_APPWINDOW = 0x00040000
WS_EX_NOACTIVATE = 0x08000000
WM_DESTROY = 0x0002
WM_MOUSEACTIVATE = 0x0021
MA_NOACTIVATE = 3
SWP_NOACTIVATE = 0x0010
SWP_SHOWWINDOW = 0x0040
SWP_NOOWNERZORDER = 0x0200

MOD_KEYS = {"ctrl": 0x11, "control": 0x11, "shift": 0x10, "alt": 0x12, "menu": 0x12, "win": 0x5B,
            "super": 0x5B, "meta": 0x5B}
MOD_NAMES = {0x11: "ctrl", 0x10: "shift", 0x12: "alt", 0x5B: "win"}
NAMED_KEYS = {
    "enter": 0x0D, "return": 0x0D, "esc": 0x1B, "escape": 0x1B, "tab": 0x09, "space": 0x20,
    "backspace": 0x08, "delete": 0x2E, "del": 0x2E, "insert": 0x2D, "ins": 0x2D, "home": 0x24,
    "end": 0x23, "pageup": 0x21, "page_up": 0x21, "pgup": 0x21, "pagedown": 0x22, "page_down": 0x22,
    "pgdn": 0x22, "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28, "grave": 0xC0,
    "grave_accent": 0xC0, "backtick": 0xC0, "minus": 0xBD, "equal": 0xBB, "plus": 0xBB, "comma": 0xBC,
    "period": 0xBE, "slash": 0xBF, "semicolon": 0xBA, "apostrophe": 0xDE, "quote": 0xDE,
    "bracketleft": 0xDB, "backslash": 0xDC, "bracketright": 0xDD, "apps": 0x5D, "capslock": 0x14,
    "printscreen": 0x2C, "pause": 0x13, "numlock": 0x90, "scrolllock": 0x91,
    # VK_OEM_*: what they type depends on the layout (dead keys, the ISO key left of Z).
    "oem1": 0xBA, "oem2": 0xBF, "oem3": 0xC0, "oem4": 0xDB, "oem5": 0xDC, "oem6": 0xDD, "oem7": 0xDE,
    "oem8": 0xDF, "oem102": 0xE2,
}
# What stands in front of a hung or crashed window: the Ghost window Windows shows instead of a hung
# window, and the Windows Error Reporting dialogs.
HANG_CLASSES = ("Ghost",)
CRASH_IMAGES = ("werfault.exe", "werfaultsecure.exe")

# Keys that need KEYEVENTF_EXTENDEDKEY when MapVirtualKeyW cannot say (older systems).
EXTENDED_VKS = frozenset((0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D,
                          0x6F, 0x90, 0xA3, 0xA5))
MOUSE_BUTTONS = {
    # name: (down flag, up flag, mouseData)
    "left": (0x0002, 0x0004, 0),
    "right": (0x0008, 0x0010, 0),
    "middle": (0x0020, 0x0040, 0),
    "x1": (0x0080, 0x0100, 1),
    "x2": (0x0080, 0x0100, 2),
}


class GuiError(RuntimeError):
    """A failed step or command; reported with exit code 1."""


class UsageError(GuiError):
    """A usage or environment problem; reported with exit code 2."""


class Blocked(GuiError):
    """A precondition of this machine is missing (such as a keyboard layout this user has not loaded):
    the scenario or command cannot run here; reported as BLOCKED with exit code 3."""


class InputBlocked(GuiError):
    """Input was not sent because the foreground or pointed-at window is not the instance's.

    `cause` classifies the refusal for the gx-input-guard-v1 audit: instance_gone (the
    instance ended or its process identity changed), instance_hung (it hangs or crashed: see
    Instance.hang_evidence), foreground_lost, pointer_target_lost, foreign_input (input this
    tool did not send was observed) or other. `details` holds title-free facts about the window
    in the way (other_pid, other_class, other_image). The audit vocabulary also has
    instance_self_activated, which only gx_perf win32-idle writes (its idle_state_window check)."""

    CAUSES = ("instance_gone", "instance_hung", "instance_self_activated", "foreground_lost", "pointer_target_lost",
              "foreign_input", "other")

    def __init__(self, message: str, cause: str = "other", **details: Any) -> None:
        if cause not in self.CAUSES:
            raise ValueError(f"unknown input-block cause {cause!r}")
        super().__init__(message)
        self.cause = cause
        self.details = details


# ---------------------------------------------------------------------------
# Pure helpers (covered by scripts/test_gx_win_gui.py on any platform)
# ---------------------------------------------------------------------------


# wait_file paths: {log} and {env} name this scenario instance's files (see Paths in the module help).
PATH_PLACEHOLDERS = ("env", "log")
PATH_TOKEN_RE = re.compile(r"\$\{[^{}]*\}|\{\{|\}\}|\{[^{}]*\}|[{}]")


def expand_path(template: str, values: Mapping[str, str], where: str) -> str:
    """`template` with each {name} replaced by values[name] ({{ and }} are literal braces), then the
    environment variables of the remaining text expanded (os.path.expandvars, which also reads ${NAME}).
    Placeholder values and literal braces are inserted verbatim, never expanded again. An unknown
    placeholder or an unbalanced brace is a UsageError, never a literal path."""
    chunks: list[tuple[str, bool]] = []  # (text, expand environment variables)
    position = 0
    for match in PATH_TOKEN_RE.finditer(template):
        chunks.append((template[position:match.start()], True))
        position = match.end()
        token = match.group(0)
        if token.startswith("${"):
            chunks.append((token, True))
        elif token in ("{{", "}}"):
            chunks.append((token[0], False))
        elif token in ("{", "}"):
            raise UsageError(f"{where}: unbalanced {token!r} in path {template!r}; write {{{{ or }}}} for a literal brace")
        elif token[1:-1] in values:
            chunks.append((values[token[1:-1]], False))
        elif token[1:-1] in PATH_PLACEHOLDERS:
            raise UsageError(f"{where}: {token} is not available here: {{env}} and {{log}} name this scenario's own "
                             "profile, which only exists while it runs (use them in a wait_file step)")
        else:
            known = ", ".join("{" + name + "}" for name in sorted(values)) or "none"
            raise UsageError(f"{where}: unknown placeholder {token} in path {template!r} (known: {known}; "
                             "write {{ and }} for literal braces)")
    chunks.append((template[position:], True))
    merged: list[tuple[str, bool]] = []
    for text, expand in chunks:
        if merged and expand and merged[-1][1]:
            merged[-1] = (merged[-1][0] + text, True)
        else:
            merged.append((text, expand))
    return "".join(os.path.expandvars(text) if expand else text for text, expand in merged)


def parse_chord(chord: str) -> tuple[list[int], int]:
    """`ctrl+shift+t` -> ([VK_CONTROL, VK_SHIFT], ord('T')). Raises UsageError for unknown keys."""
    parts = [part.strip().lower() for part in chord.split("+")]
    if not parts or any(not part for part in parts):
        raise UsageError(f"bad key chord {chord!r}")
    *mods, key = parts
    vks = []
    for mod in mods:
        if mod not in MOD_KEYS:
            raise UsageError(f"unknown modifier {mod!r} in {chord!r}")
        if MOD_KEYS[mod] not in vks:
            vks.append(MOD_KEYS[mod])
    return vks, key_vk(key, chord)


def modifier_vks(mods: Iterable[str]) -> list[int]:
    """Virtual keys of modifier names (ctrl, shift, alt, win and their aliases) without repeats."""
    vks: list[int] = []
    for mod in mods:
        name = mod.strip().lower() if isinstance(mod, str) else mod
        if name not in MOD_KEYS:
            raise UsageError(f"unknown modifier {mod!r}; use {', '.join(MOD_KEYS)}")
        if MOD_KEYS[name] not in vks:
            vks.append(MOD_KEYS[name])
    return vks


def key_vk(key: str, chord: str = "") -> int:
    if len(key) == 1 and ("a" <= key <= "z" or "0" <= key <= "9"):
        return ord(key.upper())
    if key in NAMED_KEYS:
        return NAMED_KEYS[key]
    match = re.fullmatch(r"f([1-9]|1[0-9]|2[0-4])", key)
    if match:
        return 0x6F + int(match.group(1))
    match = re.fullmatch(r"(?:numpad|kp_?)([0-9])", key)
    if match:
        return 0x60 + int(match.group(1))
    if key in MOD_KEYS:
        return MOD_KEYS[key]
    raise UsageError(f"unknown key {key!r}" + (f" in {chord!r}" if chord else ""))


def hkl_text(hkl: int) -> str:
    return f"0x{hkl & 0xFFFFFFFF:08x}"


def resolve_layout(target: str, loaded: Sequence[int]) -> tuple[int | None, str | None]:
    """The layout `target` names, an HKL such as 0x08040804 or a KLID such as 00000407: its raw handle
    from `loaded` (GetKeyboardLayoutList), None when it is not loaded; and the KLID that would load it
    (None for an HKL). A KLID 0000LLLL is the HKL 0xLLLLLLLL, an IME KLID E0xxxxxx is its own HKL;
    other KLIDs (layout variants) cannot be matched without loading them."""
    text = str(target).strip()
    by_value = {hkl & 0xFFFFFFFF: hkl for hkl in loaded}
    if re.fullmatch(r"0[xX][0-9A-Fa-f]{1,8}", text):
        return by_value.get(int(text, 16)), None
    if re.fullmatch(r"[0-9A-Fa-f]{8}", text):
        klid = text.upper()
        value = int(klid, 16)
        if value >> 16 == 0:
            wanted: int | None = (value << 16) | value
        elif klid.startswith("E0"):
            wanted = value
        else:
            wanted = None
        return (by_value.get(wanted) if wanted is not None else None), klid
    raise UsageError(f"keyboard layout {target!r}: use an HKL such as 0x08040804 or a KLID such as 00000407")


VM_MARKER = "GX_WIN_GUI_VM"  # set to 1 inside the test VM only
# The firmware of the QEMU/OVMF test VM; the same pattern as the guest guard of test/windows/gx_vm_validation.ps1.
VM_FIRMWARE = re.compile(r"QEMU|Bochs|SeaBIOS|OVMF|EDK II", re.IGNORECASE)
BIOS_VALUES = ("SystemManufacturer", "SystemProductName", "BIOSVendor", "BIOSVersion", "BaseBoardManufacturer")


def bios_description() -> str:
    """The firmware strings of HKLM\\HARDWARE\\DESCRIPTION\\System\\BIOS (read only); "" where there are none."""
    try:
        import winreg
    except ImportError:
        return ""
    values = []
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\BIOS") as key:
            for name in BIOS_VALUES:
                try:
                    values.append(str(winreg.QueryValueEx(key, name)[0]).strip())
                except OSError:
                    pass
    except OSError:
        return ""
    return " ".join(value for value in values if value)


def vm_guard(what: str, environ: Mapping[str, str] | None = None, bios: Callable[[], str] | None = None) -> str:
    """Refuse `what` (loading keyboard layouts) outside the test VM: GX_WIN_GUI_VM=1 must be set and the
    firmware must be the VM's QEMU/OVMF. The evidence when it may run."""
    environ = os.environ if environ is None else environ
    description = (bios or bios_description)()
    marker = environ.get(VM_MARKER) == "1"
    firmware = bool(VM_FIRMWARE.search(description))
    if not (marker and firmware):
        missing = ([] if marker else [f"{VM_MARKER}=1 is not set"]) + (
            [] if firmware else [f"the firmware ({description or 'unknown'}) is not the test VM's QEMU/OVMF"])
        raise UsageError(f"{what} only runs inside the test VM: {'; '.join(missing)}; nothing was loaded")
    return f"test VM: {VM_MARKER}=1, firmware {description}"


def layout_blockers(steps: Sequence[Any], loaded: Sequence[int], allow_load: bool = False) -> list[str]:
    """Why the ime_off and layout `steps` (Step objects) cannot run with the keyboard layouts `loaded` for
    this user (GetKeyboardLayoutList), before anything starts; empty when they can. allow_load (VM only)
    makes a KLID that is not loaded available."""
    names = ", ".join(hkl_text(value) for value in loaded) or "none"
    reasons = []
    for index, step in enumerate(steps, 1):
        if step.action == "ime_off" and not any(hkl & 0xFFFF == 0x0409 for hkl in loaded):
            reasons.append(f"step {index} ime_off needs a loaded English (US) layout (GetKeyboardLayoutList: {names})")
        elif step.action == "layout":
            target = str(step.params["target"])
            hkl, klid = resolve_layout(target, loaded)
            if hkl is None and not (allow_load and klid is not None):
                reasons.append(f"step {index} layout {target} is not loaded (GetKeyboardLayoutList: {names})"
                               + ("; only --allow-load-layouts, in the VM, may load it" if klid is not None else ""))
    return reasons


def as_lparam(value: int) -> int:
    """A pointer-sized handle as the signed LPARAM that carries it."""
    bits = ctypes.sizeof(ctypes.c_void_p) * 8
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def utf16_units(text: str) -> list[int]:
    data = text.encode("utf-16-le", "surrogatepass")
    return [int.from_bytes(data[i:i + 2], "little") for i in range(0, len(data), 2)]


def normalize_absolute(x: int, y: int, virtual: tuple[int, int, int, int]) -> tuple[int, int]:
    """SendInput MOUSEEVENTF_ABSOLUTE|VIRTUALDESK coordinates (0..65535) for a physical point."""
    vx, vy, vw, vh = virtual
    nx = round((x - vx) * 65535 / max(vw - 1, 1))
    ny = round((y - vy) * 65535 / max(vh - 1, 1))
    return max(0, min(65535, nx)), max(0, min(65535, ny))


def resolve_point(x: float | str | None, y: float | str | None, anchor: tuple[int, int, int, int],
                  scale: float) -> tuple[int, int]:
    """A physical screen point for DIP (x, y) inside `anchor` (left, top, right, bottom, physical).

    None means the center; negative values count from the right or bottom edge; a string
    such as "25%" is that fraction of the anchor's width or height.
    """
    left, top, right, bottom = anchor

    def axis(value: float | str | None, start: int, end: int) -> int:
        if value is None:
            return (start + end) // 2
        if isinstance(value, str):
            match = re.fullmatch(r"(\d+(?:\.\d+)?)%", value.strip())
            if not match:
                raise UsageError(f"bad coordinate {value!r}; use DIP numbers or a percentage such as 25%")
            return start + round((end - start) * float(match.group(1)) / 100)
        offset = round(value * scale)
        return end + offset if value < 0 else start + offset

    return axis(x, left, right), axis(y, top, bottom)


def parse_color(text: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"#?([0-9a-fA-F]{6})", text.strip())
    if not match:
        raise UsageError(f"bad color {text!r}, expected #rrggbb")
    value = int(match.group(1), 16)
    return (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF


def color_hex(rgb: Sequence[int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb)


def color_close(a: Sequence[int], b: Sequence[int], tolerance: int) -> bool:
    return all(abs(int(x) - int(y)) <= tolerance for x, y in zip(a, b))


def system_theme_wparam(scheme: str = "follow", high_contrast: str = "follow") -> int:
    """The wparam of WM_GHOSTTY_SIMULATE_SYSTEM_THEME: App.SimulatedSystemTheme packed into a usize."""
    if scheme not in SYSTEM_THEME_SCHEMES:
        raise UsageError(f"unknown color scheme {scheme!r}; use {', '.join(SYSTEM_THEME_SCHEMES)}")
    if high_contrast not in SYSTEM_THEME_HIGH_CONTRAST:
        raise UsageError(f"unknown high contrast {high_contrast!r}; use {', '.join(SYSTEM_THEME_HIGH_CONTRAST)}")
    return SYSTEM_THEME_SCHEMES[scheme] | (SYSTEM_THEME_HIGH_CONTRAST[high_contrast] << 2)


def env_assignments(values: Iterable[str]) -> dict[str, str]:
    result = {}
    for value in values:
        name, sep, rest = value.partition("=")
        if not sep or not ENV_NAME_RE.match(name):
            raise UsageError(f"--env takes NAME=VALUE, got {value!r}")
        result[name] = rest
    return result


def isolated_environment(base: Mapping[str, str], env_dir: Path, extra: Mapping[str, str] | None = None) -> dict[str, str]:
    """Keep config, state, cache and roaming data private; extra cannot override those paths."""
    paths = {"LOCALAPPDATA": env_dir, "APPDATA": env_dir / "appdata", "XDG_CONFIG_HOME": env_dir,
             "XDG_STATE_HOME": env_dir / "state", "XDG_CACHE_HOME": env_dir / "cache"}
    for name in extra or {}:
        if name.upper() in paths:
            raise UsageError(f"--env cannot override the isolated path variable {name}")
    env = {}
    for name, value in base.items():
        upper = name.upper()
        if upper in paths or upper in STRIPPED_ENV or any(upper.startswith(prefix) for prefix in STRIPPED_ENV_PREFIXES):
            continue
        env[name] = value
    env.update({name: str(path) for name, path in paths.items()})
    env.update(extra or {})
    return env


def config_path(env_dir: Path) -> Path:
    return env_dir / "ghostty" / "config.ghostty"


def log_path(env_dir: Path) -> Path:
    return env_dir / "ghostty" / "logs" / "ghostty.log"


def write_config(env_dir: Path, text: str) -> Path:
    path = config_path(env_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.replace("\r\n", "\n"), encoding="utf-8", newline="\n")
    return path


def png_bytes(width: int, height: int, rgb: bytes) -> bytes:
    """An 8-bit RGB PNG (filter 0 on every row) of `rgb`, row-major top-down."""
    if len(rgb) != width * height * 3:
        raise ValueError("pixel data does not match the image size")
    stride = width * 3
    raw = b"".join(b"\x00" + rgb[row * stride:(row + 1) * stride] for row in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")


@dataclass
class Image:
    """A capture: top-down BGRA pixels at physical resolution, plus where it was on screen."""

    width: int
    height: int
    bgra: bytes
    left: int = 0
    top: int = 0

    def rgb(self) -> bytes:
        out = bytearray(self.width * self.height * 3)
        out[0::3] = self.bgra[2::4]
        out[1::3] = self.bgra[1::4]
        out[2::3] = self.bgra[0::4]
        return bytes(out)

    def pixel(self, x: int, y: int) -> tuple[int, int, int]:
        """The color at screen point (x, y)."""
        cx, cy = x - self.left, y - self.top
        if not (0 <= cx < self.width and 0 <= cy < self.height):
            raise GuiError(f"point ({x}, {y}) is outside the capture at ({self.left}, {self.top}) "
                           f"{self.width}x{self.height}")
        offset = (cy * self.width + cx) * 4
        b, g, r = self.bgra[offset], self.bgra[offset + 1], self.bgra[offset + 2]
        return r, g, b

    def save_png(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(png_bytes(self.width, self.height, self.rgb()))
        return path


def rect_gap(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> tuple[str, int, tuple[int, int]]:
    """The divider between two adjacent rects: ("vertical", x, (y0, y1)) or ("horizontal", y, (x0, x1))."""
    if a[2] <= b[0] or b[2] <= a[0]:
        first, second = (a, b) if a[2] <= b[0] else (b, a)
        y0, y1 = max(a[1], b[1]), min(a[3], b[3])
        if y0 >= y1:
            raise GuiError("the terminals are side by side but do not overlap vertically")
        return "vertical", (first[2] + second[0]) // 2, (y0, y1)
    if a[3] <= b[1] or b[3] <= a[1]:
        first, second = (a, b) if a[3] <= b[1] else (b, a)
        x0, x1 = max(a[0], b[0]), min(a[2], b[2])
        if x0 >= x1:
            raise GuiError("the terminals are stacked but do not overlap horizontally")
        return "horizontal", (first[3] + second[1]) // 2, (x0, x1)
    raise GuiError("the terminals overlap; there is no divider between them")


Rect = tuple[int, int, int, int]  # left, top, right, bottom in physical screen pixels


def rect_intersection(a: Rect, b: Rect) -> Rect | None:
    left, top, right, bottom = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    return (left, top, right, bottom) if left < right and top < bottom else None


def rect_union(rects: Iterable[Rect]) -> Rect | None:
    """The bounding rectangle of the non-empty `rects`, None without any."""
    rects = [rect for rect in rects if rect[0] < rect[2] and rect[1] < rect[3]]
    if not rects:
        return None
    return (min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects))


def rect_inflate(rect: Rect, by: int) -> Rect:
    return rect[0] - by, rect[1] - by, rect[2] + by, rect[3] + by


def rect_area(rect: Rect) -> int:
    return max(0, rect[2] - rect[0]) * max(0, rect[3] - rect[1])


def rect_subtract(rect: Rect, holes: Iterable[Rect]) -> list[Rect]:
    """The parts of `rect` outside every one of `holes`, as disjoint rectangles."""
    pieces = [rect] if rect[0] < rect[2] and rect[1] < rect[3] else []
    for hole in holes:
        rest: list[Rect] = []
        for piece in pieces:
            cut = rect_intersection(piece, hole)
            if cut is None:
                rest.append(piece)
                continue
            left, top, right, bottom = piece
            if top < cut[1]:
                rest.append((left, top, right, cut[1]))
            if cut[3] < bottom:
                rest.append((left, cut[3], right, bottom))
            if left < cut[0]:
                rest.append((left, cut[1], cut[0], cut[3]))
            if cut[2] < right:
                rest.append((cut[2], cut[1], right, cut[3]))
        pieces = rest
    return pieces


Monitor = tuple[Rect, Rect]  # a display monitor and its work area (without the taskbar), physical pixels


def backdrop_cover(monitors: Sequence[Monitor], windows: Sequence[Rect], wanted: Sequence[Rect] = ()) -> list[Rect]:
    """What the privacy backdrop has to cover: the work area of every monitor that one of the instance's
    `windows` or a `wanted` region (a capture with its band) reaches, and the whole monitor where one of
    the windows reaches past the work area (a fullscreen window over the taskbar)."""
    cover: list[Rect] = []
    for monitor, work in monitors:
        if not any(rect_intersection(monitor, rect) for rect in (*windows, *wanted)):
            continue
        beyond = any(rect_subtract(part, [work]) for rect in windows if (part := rect_intersection(monitor, rect)))
        area = monitor if beyond else work
        if area not in cover:
            cover.append(area)
    return cover


def backdrop_regions(capture: Rect, band: int, cover: Sequence[Rect]) -> list[Rect]:
    """The `band` pixels wide frame around `capture` that lies on the covered areas, as disjoint pieces;
    the band of a capture at a monitor edge goes on where a covered neighbour monitor continues it."""
    ring = rect_inflate(capture, band)
    pieces: list[Rect] = []
    for area in cover:
        part = rect_intersection(ring, area)
        if part is not None:
            pieces += [piece for piece in rect_subtract(part, [capture]) if piece not in pieces]
    return pieces


def row_spans(rects: Iterable[Rect], y: int, left: int, right: int) -> list[tuple[int, int]]:
    """The merged [start, end) x spans that `rects` cover on row y, clipped to [left, right)."""
    spans = sorted((max(r[0], left), min(r[2], right)) for r in rects if r[1] <= y < r[3])
    merged: list[tuple[int, int]] = []
    for start, end in spans:
        if start >= end:
            continue
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def spans_without(spans: Iterable[tuple[int, int]], holes: Sequence[tuple[int, int]]) -> list[tuple[int, int]]:
    """`spans` minus the sorted, merged `holes`."""
    free: list[tuple[int, int]] = []
    for start, end in spans:
        x = start
        for hole_start, hole_end in holes:
            if hole_end <= x or hole_start >= end:
                continue
            if hole_start > x:
                free.append((x, hole_start))
            x = max(x, hole_end)
        if x < end:
            free.append((x, end))
    return free


def backdrop_shade(pixel: Sequence[int], color: Sequence[int], tolerance: int = BACKDROP_TOLERANCE) -> bool:
    """Whether `pixel` is the backdrop color, or that color darkened by a window shadow over it."""
    weight = sum(c * c for c in color)
    if weight == 0:
        return max(pixel) <= tolerance
    k = min(1.0, max(0.0, sum(p * c for p, c in zip(pixel, color)) / weight))
    return all(abs(p - k * c) <= tolerance + 0.5 for p, c in zip(pixel, color))


def backdrop_band(image: Image, keep_out: Sequence[Rect], color: Sequence[int],
                  tolerance: int = BACKDROP_TOLERANCE, inside: Sequence[Rect] | None = None) -> dict[str, Any]:
    """Check every pixel of `image` (only those inside the `inside` rectangles, when given) outside the
    `keep_out` rectangles (the instance's windows): how many were checked, how many are neither the
    backdrop color nor its shadow, and where the first one is."""
    right_edge = image.left + image.width
    low = [max(0, c - tolerance) for c in color]
    high = [min(255, c + tolerance) for c in color]
    checked = foreign = 0
    first: list[Any] | None = None
    for y in range(image.top, image.top + image.height):
        allowed = [(image.left, right_edge)] if inside is None else row_spans(inside, y, image.left, right_edge)
        free = spans_without(allowed, row_spans(keep_out, y, image.left, right_edge))
        row = (y - image.top) * image.width - image.left
        for start, end in free:
            data = image.bgra[(row + start) * 4:(row + end) * 4]
            checked += end - start
            channels = (data[2::4], data[1::4], data[0::4])  # red, green, blue
            if all(low[i] <= min(channels[i]) and max(channels[i]) <= high[i] for i in range(3)):
                continue
            for index in range(end - start):
                pixel = (data[index * 4 + 2], data[index * 4 + 1], data[index * 4])
                if not backdrop_shade(pixel, color, tolerance):
                    foreign += 1
                    if first is None:
                        first = [start + index, y, color_hex(pixel)]
    return {"checked_pixels": checked, "foreign_pixels": foreign, "first_foreign": first}


# ---------------------------------------------------------------------------
# Win32 backend
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class WindowInfo:
    hwnd: int
    cls: str
    title: str
    rect: tuple[int, int, int, int]  # visible bounds, physical screen pixels
    visible: bool
    cloaked: bool
    toolwindow: bool

    def describe(self) -> str:
        state = ("visible" if self.visible else "hidden") + (", cloaked" if self.cloaked else "")
        left, top, right, bottom = self.rect
        return (f"{self.hwnd:#010x} {self.cls:<24} {right - left}x{bottom - top}+{left}+{top} {state}"
                + (" toolwindow" if self.toolwindow else "") + (f" {self.title!r}" if self.title else ""))


@dataclass(frozen=True)
class StackEntry:
    """A visible top-level window of any process, in z-order; its title is never read."""

    hwnd: int
    cls: str
    rect: Rect  # visible bounds, physical screen pixels
    pid: int
    owner_pid: int  # pid of its root owner window
    cloaked: bool = False
    iconic: bool = False

    def shows(self) -> bool:
        return not (self.cloaked or self.iconic) and self.rect[0] < self.rect[2] and self.rect[1] < self.rect[3]

    def belongs_to(self, pid: int) -> bool:
        return pid in (self.pid, self.owner_pid)


def backdrop_audit(stack: Sequence[StackEntry], backdrop: int, pid: int,
                   areas: Sequence[Rect]) -> tuple[list[StackEntry], bool]:
    """Windows of other processes above the backdrop that show inside one of `areas` (top to bottom),
    and whether the backdrop is in `stack` at all."""
    foreign = []
    for entry in stack:
        if entry.hwnd == backdrop:
            return foreign, True
        if entry.shows() and not entry.belongs_to(pid) and any(rect_intersection(entry.rect, area) for area in areas):
            foreign.append(entry)
    return foreign, False


def above_backdrop(stack: Sequence[StackEntry], backdrop: int, hwnd: int) -> bool:
    """Whether the window hwnd shows above the backdrop in `stack` (a window under it shows only the
    backdrop color in a screen capture)."""
    for entry in stack:
        if entry.hwnd == backdrop:
            return False
        if entry.hwnd == hwnd:
            return entry.shows()
    return False


def backdrop_message(message: int) -> int | None:
    """What the backdrop window procedure answers itself (None: DefWindowProcW): clicks never activate it."""
    return MA_NOACTIVATE if message == WM_MOUSEACTIVATE else None


class Win32:
    """ctypes bindings for the user32, gdi32, dwmapi and kernel32 calls this tool needs."""

    def __init__(self) -> None:
        if sys.platform != "win32":
            raise UsageError("this tool drives the Windows GUI and only runs on Windows")
        from ctypes import wintypes as wt

        self.wt = wt
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.dwmapi = ctypes.WinDLL("dwmapi")
        ulong_ptr = ctypes.c_size_t
        lresult = ctypes.c_ssize_t

        class POINT(ctypes.Structure):
            _fields_ = [("x", wt.LONG), ("y", wt.LONG)]

        class RECT(ctypes.Structure):
            _fields_ = [("left", wt.LONG), ("top", wt.LONG), ("right", wt.LONG), ("bottom", wt.LONG)]

        class MOUSEINPUT(ctypes.Structure):
            _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD), ("dwFlags", wt.DWORD),
                        ("time", wt.DWORD), ("dwExtraInfo", ulong_ptr)]

        class KEYBDINPUT(ctypes.Structure):
            _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD), ("time", wt.DWORD),
                        ("dwExtraInfo", ulong_ptr)]

        class HARDWAREINPUT(ctypes.Structure):
            _fields_ = [("uMsg", wt.DWORD), ("wParamL", wt.WORD), ("wParamH", wt.WORD)]

        class INPUTUNION(ctypes.Union):
            _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]

        class INPUT(ctypes.Structure):
            _fields_ = [("type", wt.DWORD), ("u", INPUTUNION)]

        class BITMAPINFOHEADER(ctypes.Structure):
            _fields_ = [("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG), ("biPlanes", wt.WORD),
                        ("biBitCount", wt.WORD), ("biCompression", wt.DWORD), ("biSizeImage", wt.DWORD),
                        ("biXPelsPerMeter", wt.LONG), ("biYPelsPerMeter", wt.LONG), ("biClrUsed", wt.DWORD),
                        ("biClrImportant", wt.DWORD)]

        class BITMAPINFO(ctypes.Structure):
            _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wt.DWORD * 3)]

        class FILETIME(ctypes.Structure):
            _fields_ = [("low", wt.DWORD), ("high", wt.DWORD)]

        class GUITHREADINFO(ctypes.Structure):
            _fields_ = [("cbSize", wt.DWORD), ("flags", wt.DWORD), ("hwndActive", wt.HWND), ("hwndFocus", wt.HWND),
                        ("hwndCapture", wt.HWND), ("hwndMenuOwner", wt.HWND), ("hwndMoveSize", wt.HWND),
                        ("hwndCaret", wt.HWND), ("rcCaret", RECT)]

        class PROCESSENTRY32W(ctypes.Structure):
            _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ProcessID", wt.DWORD),
                        ("th32DefaultHeapID", ulong_ptr), ("th32ModuleID", wt.DWORD), ("cntThreads", wt.DWORD),
                        ("th32ParentProcessID", wt.DWORD), ("pcPriClassBase", wt.LONG), ("dwFlags", wt.DWORD),
                        ("szExeFile", wt.WCHAR * 260)]

        self.WNDPROC = ctypes.WINFUNCTYPE(lresult, wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM)

        class WNDCLASSEXW(ctypes.Structure):
            _fields_ = [("cbSize", wt.UINT), ("style", wt.UINT), ("lpfnWndProc", self.WNDPROC), ("cbClsExtra", ctypes.c_int),
                        ("cbWndExtra", ctypes.c_int), ("hInstance", wt.HINSTANCE), ("hIcon", wt.HICON),
                        ("hCursor", wt.HICON), ("hbrBackground", wt.HBRUSH), ("lpszMenuName", wt.LPCWSTR),
                        ("lpszClassName", wt.LPCWSTR), ("hIconSm", wt.HICON)]

        class MSG(ctypes.Structure):
            _fields_ = [("hwnd", wt.HWND), ("message", wt.UINT), ("wParam", wt.WPARAM), ("lParam", wt.LPARAM),
                        ("time", wt.DWORD), ("pt", POINT), ("lPrivate", wt.DWORD)]

        class MONITORINFO(ctypes.Structure):
            _fields_ = [("cbSize", wt.DWORD), ("rcMonitor", RECT), ("rcWork", RECT), ("dwFlags", wt.DWORD)]

        self.POINT, self.RECT, self.INPUT, self.FILETIME = POINT, RECT, INPUT, FILETIME
        self.BITMAPINFO, self.GUITHREADINFO, self.PROCESSENTRY32W = BITMAPINFO, GUITHREADINFO, PROCESSENTRY32W
        self.WNDCLASSEXW, self.MSG, self.MONITORINFO = WNDCLASSEXW, MSG, MONITORINFO
        self.WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
        self.MONITORENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HMONITOR, wt.HDC, ctypes.POINTER(RECT), wt.LPARAM)

        def declare(dll, name, restype, *argtypes):
            function = getattr(dll, name)
            function.restype = restype
            function.argtypes = list(argtypes)
            setattr(self, name, function)

        u, g, k = self.user32, self.gdi32, self.kernel32
        declare(u, "EnumWindows", wt.BOOL, self.WNDENUMPROC, wt.LPARAM)
        declare(u, "EnumChildWindows", wt.BOOL, wt.HWND, self.WNDENUMPROC, wt.LPARAM)
        declare(u, "GetWindowThreadProcessId", wt.DWORD, wt.HWND, ctypes.POINTER(wt.DWORD))
        declare(u, "GetClassNameW", ctypes.c_int, wt.HWND, wt.LPWSTR, ctypes.c_int)
        declare(u, "GetWindowTextW", ctypes.c_int, wt.HWND, wt.LPWSTR, ctypes.c_int)
        declare(u, "IsWindow", wt.BOOL, wt.HWND)
        declare(u, "IsWindowVisible", wt.BOOL, wt.HWND)
        declare(u, "IsIconic", wt.BOOL, wt.HWND)
        declare(u, "IsHungAppWindow", wt.BOOL, wt.HWND)
        declare(u, "GetWindowRect", wt.BOOL, wt.HWND, ctypes.POINTER(RECT))
        declare(u, "GetClientRect", wt.BOOL, wt.HWND, ctypes.POINTER(RECT))
        declare(u, "ClientToScreen", wt.BOOL, wt.HWND, ctypes.POINTER(POINT))
        declare(u, "GetWindowLongPtrW", ctypes.c_ssize_t, wt.HWND, ctypes.c_int)
        declare(u, "GetForegroundWindow", wt.HWND)
        declare(u, "SetForegroundWindow", wt.BOOL, wt.HWND)
        declare(u, "BringWindowToTop", wt.BOOL, wt.HWND)
        declare(u, "ShowWindow", wt.BOOL, wt.HWND, ctypes.c_int)
        declare(u, "SetWindowPos", wt.BOOL, wt.HWND, wt.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                wt.UINT)
        declare(u, "AttachThreadInput", wt.BOOL, wt.DWORD, wt.DWORD, wt.BOOL)
        declare(u, "IsWindowEnabled", wt.BOOL, wt.HWND)
        declare(u, "GetWindow", wt.HWND, wt.HWND, wt.UINT)
        declare(u, "WindowFromPoint", wt.HWND, POINT)
        declare(u, "GetAncestor", wt.HWND, wt.HWND, wt.UINT)
        declare(u, "SendInput", wt.UINT, wt.UINT, ctypes.POINTER(INPUT), ctypes.c_int)
        declare(u, "MapVirtualKeyW", wt.UINT, wt.UINT, wt.UINT)
        declare(u, "GetSystemMetrics", ctypes.c_int, ctypes.c_int)
        declare(u, "GetDpiForWindow", wt.UINT, wt.HWND)
        declare(u, "SendMessageTimeoutW", lresult, wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM, wt.UINT, wt.UINT,
                ctypes.POINTER(ulong_ptr))
        declare(u, "PostMessageW", wt.BOOL, wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM)
        declare(u, "PrintWindow", wt.BOOL, wt.HWND, wt.HDC, wt.UINT)
        declare(u, "GetDC", wt.HDC, wt.HWND)
        declare(u, "ReleaseDC", ctypes.c_int, wt.HWND, wt.HDC)
        declare(u, "LoadKeyboardLayoutW", wt.HKL, wt.LPCWSTR, wt.UINT)
        declare(u, "UnloadKeyboardLayout", wt.BOOL, wt.HKL)
        declare(u, "GetKeyboardLayoutList", ctypes.c_int, ctypes.c_int, ctypes.POINTER(wt.HKL))
        declare(u, "GetKeyboardLayout", wt.HKL, wt.DWORD)
        declare(u, "GetGUIThreadInfo", wt.BOOL, wt.DWORD, ctypes.POINTER(GUITHREADINFO))
        declare(u, "OpenClipboard", wt.BOOL, wt.HWND)
        declare(u, "CloseClipboard", wt.BOOL)
        declare(u, "EmptyClipboard", wt.BOOL)
        declare(u, "SetClipboardData", wt.HANDLE, wt.UINT, wt.HANDLE)
        declare(u, "GetClipboardData", wt.HANDLE, wt.UINT)
        declare(u, "IsClipboardFormatAvailable", wt.BOOL, wt.UINT)
        declare(u, "RegisterClassExW", wt.ATOM, ctypes.POINTER(WNDCLASSEXW))
        declare(u, "CreateWindowExW", wt.HWND, wt.DWORD, wt.LPCWSTR, wt.LPCWSTR, wt.DWORD, ctypes.c_int, ctypes.c_int,
                ctypes.c_int, ctypes.c_int, wt.HWND, wt.HMENU, wt.HINSTANCE, wt.LPVOID)
        declare(u, "DefWindowProcW", lresult, wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM)
        declare(u, "GetMessageW", wt.BOOL, ctypes.POINTER(MSG), wt.HWND, wt.UINT, wt.UINT)
        declare(u, "TranslateMessage", wt.BOOL, ctypes.POINTER(MSG))
        declare(u, "DispatchMessageW", lresult, ctypes.POINTER(MSG))
        declare(u, "PostQuitMessage", None, ctypes.c_int)
        declare(u, "LoadCursorW", wt.HICON, wt.HINSTANCE, wt.LPVOID)
        declare(u, "EnumDisplayMonitors", wt.BOOL, wt.HDC, ctypes.POINTER(RECT), self.MONITORENUMPROC, wt.LPARAM)
        declare(u, "GetMonitorInfoW", wt.BOOL, wt.HMONITOR, ctypes.POINTER(MONITORINFO))
        declare(g, "CreateSolidBrush", wt.HBRUSH, wt.COLORREF)
        declare(k, "GetModuleHandleW", wt.HMODULE, wt.LPCWSTR)
        declare(g, "CreateCompatibleDC", wt.HDC, wt.HDC)
        declare(g, "CreateDIBSection", wt.HBITMAP, wt.HDC, ctypes.POINTER(BITMAPINFO), wt.UINT,
                ctypes.POINTER(ctypes.c_void_p), wt.HANDLE, wt.DWORD)
        declare(g, "SelectObject", wt.HGDIOBJ, wt.HDC, wt.HGDIOBJ)
        declare(g, "BitBlt", wt.BOOL, wt.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.HDC,
                ctypes.c_int, ctypes.c_int, wt.DWORD)
        declare(g, "DeleteObject", wt.BOOL, wt.HGDIOBJ)
        declare(g, "DeleteDC", wt.BOOL, wt.HDC)
        declare(self.dwmapi, "DwmGetWindowAttribute", ctypes.c_long, wt.HWND, wt.DWORD, ctypes.c_void_p, wt.DWORD)
        declare(k, "OpenProcess", wt.HANDLE, wt.DWORD, wt.BOOL, wt.DWORD)
        declare(k, "CloseHandle", wt.BOOL, wt.HANDLE)
        declare(k, "QueryFullProcessImageNameW", wt.BOOL, wt.HANDLE, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD))
        declare(k, "GetProcessTimes", wt.BOOL, wt.HANDLE, ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME),
                ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME))
        declare(k, "GetSystemTimePreciseAsFileTime", None, ctypes.POINTER(FILETIME))
        declare(k, "TerminateProcess", wt.BOOL, wt.HANDLE, wt.UINT)
        declare(k, "WaitForSingleObject", wt.DWORD, wt.HANDLE, wt.DWORD)
        declare(k, "GetCurrentThreadId", wt.DWORD)
        declare(k, "GlobalAlloc", wt.HGLOBAL, wt.UINT, ctypes.c_size_t)
        declare(k, "GlobalLock", ctypes.c_void_p, wt.HGLOBAL)
        declare(k, "GlobalUnlock", wt.BOOL, wt.HGLOBAL)
        declare(k, "GlobalFree", wt.HGLOBAL, wt.HGLOBAL)
        declare(k, "CreateToolhelp32Snapshot", wt.HANDLE, wt.DWORD, wt.DWORD)
        declare(k, "Process32FirstW", wt.BOOL, wt.HANDLE, ctypes.POINTER(PROCESSENTRY32W))
        declare(k, "Process32NextW", wt.BOOL, wt.HANDLE, ctypes.POINTER(PROCESSENTRY32W))
        declare(k, "GetCurrentProcess", wt.HANDLE)
        declare(k, "CreateFileW", wt.HANDLE, wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.LPVOID, wt.DWORD, wt.DWORD, wt.HANDLE)
        declare(k, "LocalFree", wt.HLOCAL, wt.HLOCAL)
        self.advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
        declare(self.advapi32, "OpenProcessToken", wt.BOOL, wt.HANDLE, wt.DWORD, ctypes.POINTER(wt.HANDLE))
        declare(self.advapi32, "GetTokenInformation", wt.BOOL, wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD,
                ctypes.POINTER(wt.DWORD))
        declare(self.advapi32, "ConvertSidToStringSidW", wt.BOOL, ctypes.c_void_p, ctypes.POINTER(wt.LPWSTR))
        self._enable_dpi_awareness()

    def _enable_dpi_awareness(self) -> None:
        # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2; fails harmlessly when already set.
        try:
            setter = self.user32.SetProcessDpiAwarenessContext
            setter.restype = self.wt.BOOL
            setter.argtypes = [ctypes.c_void_p]
            if setter(ctypes.c_void_p(-4)):
                return
        except AttributeError:
            pass
        try:
            ctypes.WinDLL("shcore").SetProcessDpiAwareness(2)
        except (AttributeError, OSError):
            self.user32.SetProcessDPIAware()

    # -- processes ---------------------------------------------------------

    def now_filetime(self) -> int:
        value = self.FILETIME()
        self.GetSystemTimePreciseAsFileTime(ctypes.byref(value))
        return (value.high << 32) | value.low

    def _open(self, pid: int, access: int = 0x1000 | 0x00100000):  # QUERY_LIMITED_INFORMATION | SYNCHRONIZE
        handle = self.OpenProcess(access, False, pid)
        return handle or None

    def process_image(self, pid: int) -> str | None:
        handle = self._open(pid)
        if handle is None:
            return None
        try:
            size = self.wt.DWORD(32768)
            buffer = ctypes.create_unicode_buffer(size.value)
            if not self.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                return None
            return buffer.value
        finally:
            self.CloseHandle(handle)

    def process_creation(self, pid: int) -> int | None:
        handle = self._open(pid)
        if handle is None:
            return None
        try:
            created, exited, kernel, user = self.FILETIME(), self.FILETIME(), self.FILETIME(), self.FILETIME()
            if not self.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel),
                                        ctypes.byref(user)):
                return None
            return (created.high << 32) | created.low
        finally:
            self.CloseHandle(handle)

    def process_alive(self, pid: int) -> bool:
        handle = self._open(pid)
        if handle is None:
            return False
        try:
            return self.WaitForSingleObject(handle, 0) == 0x102  # WAIT_TIMEOUT: still running
        finally:
            self.CloseHandle(handle)

    def terminate(self, pid: int) -> bool:
        handle = self._open(pid, 0x0001 | 0x1000 | 0x00100000)  # PROCESS_TERMINATE too
        if handle is None:
            return False
        try:
            return bool(self.TerminateProcess(handle, 1))
        finally:
            self.CloseHandle(handle)

    def child_processes(self, pid: int) -> list[tuple[int, str]]:
        snapshot = self.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
        if not snapshot or snapshot == ctypes.c_void_p(-1).value:
            return []
        children = []
        try:
            entry = self.PROCESSENTRY32W()
            entry.dwSize = ctypes.sizeof(entry)
            ok = self.Process32FirstW(snapshot, ctypes.byref(entry))
            while ok:
                if entry.th32ParentProcessID == pid and entry.th32ProcessID != pid:
                    children.append((entry.th32ProcessID, entry.szExeFile))
                ok = self.Process32NextW(snapshot, ctypes.byref(entry))
        finally:
            self.CloseHandle(snapshot)
        return children

    def can_open_for_delete(self, path: Path) -> bool:
        """Whether the current user may open `path` with DELETE access, as deleting or renaming it would;
        nothing is deleted (the handle is closed without a delete disposition)."""
        flags = 0x02000000 if path.is_dir() else 0  # FILE_FLAG_BACKUP_SEMANTICS opens a directory
        handle = self.CreateFileW(str(path), 0x00010000, 7, None, 3, flags, None)  # DELETE, share all, OPEN_EXISTING
        if handle is None or handle == ctypes.c_void_p(-1).value:
            error = ctypes.get_last_error()
            if error == 5:  # ERROR_ACCESS_DENIED
                return False
            raise GuiError(f"cannot probe {path} for DELETE access (CreateFileW error {error})")
        self.CloseHandle(handle)
        return True

    def current_user_sid(self) -> str:
        """The string SID of the user this process runs as (TokenUser)."""
        token = self.wt.HANDLE()
        if not self.OpenProcessToken(self.GetCurrentProcess(), 0x0008, ctypes.byref(token)):  # TOKEN_QUERY
            raise GuiError(f"OpenProcessToken failed (error {ctypes.get_last_error()})")
        try:
            size = self.wt.DWORD(0)
            self.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))  # TokenUser
            buffer = ctypes.create_string_buffer(size.value)
            if not size.value or not self.GetTokenInformation(token, 1, buffer, size, ctypes.byref(size)):
                raise GuiError(f"GetTokenInformation failed (error {ctypes.get_last_error()})")
            sid = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_void_p))[0]  # TOKEN_USER.User.Sid
            text = self.wt.LPWSTR()
            if not self.ConvertSidToStringSidW(sid, ctypes.byref(text)):
                raise GuiError(f"ConvertSidToStringSidW failed (error {ctypes.get_last_error()})")
            try:
                return text.value or ""
            finally:
                self.LocalFree(ctypes.cast(text, ctypes.c_void_p))
        finally:
            self.CloseHandle(token)

    # -- windows -----------------------------------------------------------

    def window_pid(self, hwnd: int) -> int:
        pid = self.wt.DWORD(0)
        self.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        return pid.value

    def window_thread(self, hwnd: int) -> int:
        return self.GetWindowThreadProcessId(hwnd, None)

    def class_name(self, hwnd: int) -> str:
        buffer = ctypes.create_unicode_buffer(256)
        self.GetClassNameW(hwnd, buffer, 256)
        return buffer.value

    def window_text(self, hwnd: int) -> str:
        buffer = ctypes.create_unicode_buffer(1024)
        self.GetWindowTextW(hwnd, buffer, 1024)
        return buffer.value

    def hung(self, hwnd: int) -> bool:
        """IsHungAppWindow: the window's thread has not taken a message for about 5 s."""
        return bool(self.IsHungAppWindow(hwnd))

    def cloaked(self, hwnd: int) -> bool:
        value = self.wt.DWORD(0)
        if self.DwmGetWindowAttribute(hwnd, 14, ctypes.byref(value), ctypes.sizeof(value)) != 0:  # DWMWA_CLOAKED
            return False
        return value.value != 0

    def window_rect(self, hwnd: int) -> tuple[int, int, int, int]:
        rect = self.RECT()
        if self.DwmGetWindowAttribute(hwnd, 9, ctypes.byref(rect), ctypes.sizeof(rect)) != 0:  # EXTENDED_FRAME_BOUNDS
            self.GetWindowRect(hwnd, ctypes.byref(rect))
        return rect.left, rect.top, rect.right, rect.bottom

    def raw_window_rect(self, hwnd: int) -> tuple[int, int, int, int]:
        rect = self.RECT()
        self.GetWindowRect(hwnd, ctypes.byref(rect))
        return rect.left, rect.top, rect.right, rect.bottom

    def client_rect(self, hwnd: int) -> tuple[int, int, int, int]:
        rect = self.RECT()
        self.GetClientRect(hwnd, ctypes.byref(rect))
        origin = self.POINT(0, 0)
        self.ClientToScreen(hwnd, ctypes.byref(origin))
        return origin.x, origin.y, origin.x + rect.right, origin.y + rect.bottom

    def info(self, hwnd: int) -> WindowInfo:
        exstyle = self.GetWindowLongPtrW(hwnd, -20)  # GWL_EXSTYLE
        return WindowInfo(hwnd, self.class_name(hwnd), self.window_text(hwnd), self.window_rect(hwnd),
                          bool(self.IsWindowVisible(hwnd)), self.cloaked(hwnd), bool(exstyle & 0x80))

    def top_windows(self, pid: int) -> list[WindowInfo]:
        found: list[int] = []

        @self.WNDENUMPROC
        def collect(hwnd, _):
            if self.window_pid(hwnd) == pid:
                found.append(hwnd)
            return True

        self.EnumWindows(collect, 0)
        return [self.info(hwnd) for hwnd in found]

    def window_stack(self) -> list[StackEntry]:
        """The visible top-level windows of every process from the top of the z-order down (the order
        EnumWindows reports), without their titles."""
        found: list[int] = []

        @self.WNDENUMPROC
        def collect(hwnd, _):
            found.append(hwnd)
            return True

        self.EnumWindows(collect, 0)
        return [StackEntry(hwnd, self.class_name(hwnd), self.window_rect(hwnd), self.window_pid(hwnd),
                           self.root_owner_pid(hwnd), self.cloaked(hwnd), bool(self.IsIconic(hwnd)))
                for hwnd in found if self.IsWindowVisible(hwnd)]

    def monitors(self) -> list[Monitor]:
        """Every display monitor with its work area (without the taskbar), in physical screen pixels."""
        found: list[Monitor] = []

        @self.MONITORENUMPROC
        def collect(monitor, _dc, _rect, _data):
            info = self.MONITORINFO()
            info.cbSize = ctypes.sizeof(info)
            if self.GetMonitorInfoW(monitor, ctypes.byref(info)):
                whole, work = info.rcMonitor, info.rcWork
                found.append(((whole.left, whole.top, whole.right, whole.bottom),
                              (work.left, work.top, work.right, work.bottom)))
            return True

        if not self.EnumDisplayMonitors(None, None, collect, 0) or not found:
            raise GuiError(f"cannot enumerate the display monitors (error {ctypes.get_last_error()})")
        return found

    def child_windows(self, hwnd: int, cls: str | None = None) -> list[WindowInfo]:
        found: list[int] = []

        @self.WNDENUMPROC
        def collect(child, _):
            if cls is None or self.class_name(child) == cls:
                found.append(child)
            return True

        self.EnumChildWindows(hwnd, collect, 0)
        return [self.info(child) for child in found]

    def root_owner_pid(self, hwnd: int) -> int:
        root = self.GetAncestor(hwnd, 3) or hwnd  # GA_ROOTOWNER
        return self.window_pid(root)

    def foreground(self) -> int:
        return self.GetForegroundWindow() or 0

    def window_at(self, x: int, y: int) -> int:
        return self.WindowFromPoint(self.POINT(x, y)) or 0

    def dpi(self, hwnd: int) -> int:
        return self.GetDpiForWindow(hwnd) or 96

    def send_message(self, hwnd: int, message: int, wparam: int = 0, lparam: int = 0, timeout_ms: int = 5000) -> int | None:
        """SendMessageTimeoutW with SMTO_ABORTIFHUNG: the result, or None if the window did not answer."""
        result = ctypes.c_size_t(0)
        if not self.SendMessageTimeoutW(hwnd, message, wparam, lparam, 0x0002, timeout_ms, ctypes.byref(result)):
            return None
        return result.value

    def activate(self, hwnd: int) -> bool:
        """Bring hwnd to the foreground; while a modal popup disables it, that popup instead (as a click would)."""
        if not self.IsWindowEnabled(hwnd):
            popup = self.GetWindow(hwnd, 6)  # GW_ENABLEDPOPUP
            if popup and popup != hwnd:
                hwnd = popup
        if self.foreground() == hwnd:
            return True
        if self.IsIconic(hwnd):
            self.ShowWindow(hwnd, 9)  # SW_RESTORE
        current = self.GetCurrentThreadId()
        fg_thread = self.window_thread(self.foreground()) if self.foreground() else 0
        attached = bool(fg_thread and fg_thread != current and self.AttachThreadInput(current, fg_thread, True))
        try:
            self.BringWindowToTop(hwnd)
            self.SetForegroundWindow(hwnd)
        finally:
            if attached:
                self.AttachThreadInput(current, fg_thread, False)
        for _ in range(50):
            if self.foreground() == hwnd:
                return True
            time.sleep(0.01)
        return False

    def focus_window(self, hwnd: int) -> int:
        """The focused window of hwnd's GUI thread (for WM_CANCELMODE and layout requests), else hwnd."""
        info = self.GUITHREADINFO()
        info.cbSize = ctypes.sizeof(info)
        if self.GetGUIThreadInfo(self.window_thread(hwnd), ctypes.byref(info)) and info.hwndFocus:
            return info.hwndFocus
        return hwnd

    def keyboard_layout(self, hwnd: int) -> int:
        return (self.GetKeyboardLayout(self.window_thread(hwnd)) or 0) & 0xFFFFFFFF

    def keyboard_layouts(self) -> list[int]:
        """GetKeyboardLayoutList: the input locales loaded for this user, as raw HKL values."""
        count = self.GetKeyboardLayoutList(0, None)
        if count <= 0:
            return []
        buffer = (self.wt.HKL * count)()
        count = self.GetKeyboardLayoutList(count, buffer)
        return [value or 0 for value in buffer[:max(0, count)]]

    def request_layout(self, hwnd: int, hkl: int) -> None:
        """Ask hwnd's focused window to switch its thread to the loaded layout hkl."""
        if not self.PostMessageW(self.focus_window(hwnd), WM_INPUTLANGCHANGEREQUEST, 0, as_lparam(hkl)):
            raise GuiError(f"cannot post WM_INPUTLANGCHANGEREQUEST (error {ctypes.get_last_error()})")

    def load_layout(self, klid: str) -> int:
        """LoadKeyboardLayoutW without activating it (Instance.switch_layout with allow_load, VM only)."""
        hkl = self.LoadKeyboardLayoutW(klid, KLF_NOTELLSHELL)
        if not hkl:
            raise GuiError(f"cannot load keyboard layout {klid} (error {ctypes.get_last_error()})")
        return hkl

    def unload_layout(self, hkl: int) -> bool:
        return bool(self.UnloadKeyboardLayout(hkl))

    def request_us_layout(self, hwnd: int) -> None:
        # Kept for test/windows fixtures. It LOADS 00000409 when it is missing, which the host must not
        # do; gx_win_gui itself uses Instance.ime_off/switch_layout, which never load on their own.
        layout = self.LoadKeyboardLayoutW("00000409", 0)
        if not layout:
            raise GuiError("cannot load the US keyboard layout")
        self.PostMessageW(self.focus_window(hwnd), WM_INPUTLANGCHANGEREQUEST, 0, layout)

    # -- input -------------------------------------------------------------

    def virtual_screen(self) -> tuple[int, int, int, int]:
        return tuple(self.GetSystemMetrics(index) for index in (76, 77, 78, 79))  # type: ignore[return-value]

    def key_input(self, vk: int, up: bool) -> Any:
        scan = self.MapVirtualKeyW(vk, 4)  # MAPVK_VK_TO_VSC_EX: extended keys carry 0xE0 or 0xE1
        extended = (scan >> 8) in (0xE0, 0xE1) or vk in EXTENDED_VKS
        item = self.INPUT()
        item.type = 1  # INPUT_KEYBOARD
        item.u.ki.wVk = vk
        item.u.ki.wScan = scan & 0xFF
        item.u.ki.dwFlags = (0x0001 if extended else 0) | (0x0002 if up else 0)
        return item

    def unicode_input(self, unit: int, up: bool) -> Any:
        item = self.INPUT()
        item.type = 1
        item.u.ki.wVk = 0
        item.u.ki.wScan = unit
        item.u.ki.dwFlags = 0x0004 | (0x0002 if up else 0)  # KEYEVENTF_UNICODE
        return item

    def mouse_input(self, flags: int, x: int = 0, y: int = 0, data: int = 0) -> Any:
        item = self.INPUT()
        item.type = 0  # INPUT_MOUSE
        if flags & 0x8000:
            item.u.mi.dx, item.u.mi.dy = normalize_absolute(x, y, self.virtual_screen())
        item.u.mi.mouseData = data & 0xFFFFFFFF
        item.u.mi.dwFlags = flags
        return item

    def send(self, inputs: Sequence[Any]) -> None:
        if not inputs:
            return
        array = (self.INPUT * len(inputs))(*inputs)
        sent = self.SendInput(len(inputs), array, ctypes.sizeof(self.INPUT))
        if sent != len(inputs):
            raise GuiError(f"SendInput sent {sent} of {len(inputs)} events (error {ctypes.get_last_error()}); "
                           "is the target elevated or the desktop locked?")

    # -- capture -----------------------------------------------------------

    def _dib(self, width: int, height: int):
        info = self.BITMAPINFO()
        info.bmiHeader.biSize = ctypes.sizeof(info.bmiHeader)
        info.bmiHeader.biWidth = width
        info.bmiHeader.biHeight = -height  # top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        bits = ctypes.c_void_p()
        bitmap = self.CreateDIBSection(None, ctypes.byref(info), 0, ctypes.byref(bits), None, 0)
        if not bitmap:
            raise GuiError(f"CreateDIBSection {width}x{height} failed")
        return bitmap, bits

    def capture_screen(self, rect: tuple[int, int, int, int]) -> Image:
        left, top, right, bottom = rect
        width, height = right - left, bottom - top
        if width <= 0 or height <= 0:
            raise GuiError(f"empty capture rectangle {rect}")
        screen = self.GetDC(None)
        memory = self.CreateCompatibleDC(screen)
        bitmap, bits = self._dib(width, height)
        old = self.SelectObject(memory, bitmap)
        try:
            if not self.BitBlt(memory, 0, 0, width, height, screen, left, top, 0x00CC0020 | 0x40000000):
                raise GuiError("BitBlt from the screen failed")
            data = ctypes.string_at(bits, width * height * 4)
        finally:
            self.SelectObject(memory, old)
            self.DeleteObject(bitmap)
            self.DeleteDC(memory)
            self.ReleaseDC(None, screen)
        return Image(width, height, data, left, top)

    def capture_print(self, hwnd: int) -> Image:
        outer = self.raw_window_rect(hwnd)
        visible = self.window_rect(hwnd)
        width, height = outer[2] - outer[0], outer[3] - outer[1]
        screen = self.GetDC(None)
        memory = self.CreateCompatibleDC(screen)
        bitmap, bits = self._dib(width, height)
        old = self.SelectObject(memory, bitmap)
        try:
            if not self.PrintWindow(hwnd, memory, 2):  # PW_RENDERFULLCONTENT
                raise GuiError(f"PrintWindow failed for {hwnd:#x}")
            data = ctypes.string_at(bits, width * height * 4)
        finally:
            self.SelectObject(memory, old)
            self.DeleteObject(bitmap)
            self.DeleteDC(memory)
            self.ReleaseDC(None, screen)
        full = Image(width, height, data, outer[0], outer[1])
        return crop(full, visible)

    # -- clipboard ---------------------------------------------------------

    def _open_clipboard(self) -> None:
        for _ in range(50):
            if self.OpenClipboard(None):
                return
            time.sleep(0.02)
        raise GuiError("cannot open the clipboard (another program holds it)")

    def clipboard_text(self) -> str | None:
        self._open_clipboard()
        try:
            if not self.IsClipboardFormatAvailable(13):  # CF_UNICODETEXT
                return None
            handle = self.GetClipboardData(13)
            if not handle:
                return None
            pointer = self.GlobalLock(handle)
            try:
                return ctypes.wstring_at(pointer)
            finally:
                self.GlobalUnlock(handle)
        finally:
            self.CloseClipboard()

    def set_clipboard_text(self, text: str) -> None:
        data = text.encode("utf-16-le") + b"\x00\x00"
        self._open_clipboard()
        try:
            self.EmptyClipboard()
            handle = self.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
            if not handle:
                raise GuiError("GlobalAlloc failed")
            pointer = self.GlobalLock(handle)
            ctypes.memmove(pointer, data, len(data))
            self.GlobalUnlock(handle)
            if not self.SetClipboardData(13, handle):
                self.GlobalFree(handle)
                raise GuiError("SetClipboardData failed")
        finally:
            self.CloseClipboard()


def crop(image: Image, rect: tuple[int, int, int, int]) -> Image:
    """The part of `image` inside the screen rectangle `rect` (clamped to the image)."""
    left = max(rect[0], image.left)
    top = max(rect[1], image.top)
    right = min(rect[2], image.left + image.width)
    bottom = min(rect[3], image.top + image.height)
    if right <= left or bottom <= top:
        raise GuiError("the crop rectangle is outside the capture")
    width = right - left
    rows = []
    for y in range(top, bottom):
        start = ((y - image.top) * image.width + (left - image.left)) * 4
        rows.append(image.bgra[start:start + width * 4])
    return Image(width, bottom - top, b"".join(rows), left, top)


_WIN32: Win32 | None = None


def win32() -> Win32:
    global _WIN32
    if _WIN32 is None:
        _WIN32 = Win32()
    return _WIN32


_BACKDROP_LOCK = threading.Lock()
_BACKDROP_PROC: Any = None  # window procedure of every backdrop class, alive as long as the process


class BackdropWindow:
    """The privacy backdrop: a solid WS_POPUP window with WS_EX_TOOLWINDOW (no taskbar button, not in
    Alt-Tab) and WS_EX_NOACTIVATE (never takes the foreground; clicks answer MA_NOACTIVATE). It is
    created and pumped on a thread of its own, so it keeps answering while the harness waits; when
    that thread or the process ends, Windows destroys it."""

    STYLE = WS_POPUP
    EXSTYLE = WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE

    def __init__(self, color: tuple[int, int, int]) -> None:
        self.color = color
        self.hwnd = 0
        self._thread: threading.Thread | None = None
        self._ready = threading.Event()
        self._error: BaseException | None = None

    def open(self, rect: Rect) -> None:
        self._thread = threading.Thread(target=self._pump, args=(rect,), name="gx-win-gui-backdrop", daemon=True)
        self._thread.start()
        if not self._ready.wait(5):
            raise GuiError("the privacy backdrop window did not start within 5s")
        if self._error is not None:
            raise GuiError(f"cannot create the privacy backdrop: {self._error}")

    def _register(self, w: Win32) -> str:
        global _BACKDROP_PROC
        name = BACKDROP_CLASS + color_hex(self.color)[1:]
        with _BACKDROP_LOCK:
            if _BACKDROP_PROC is None:
                def procedure(hwnd, message, wparam, lparam):
                    if message == WM_DESTROY:
                        w.PostQuitMessage(0)
                        return 0
                    answer = backdrop_message(message)
                    return w.DefWindowProcW(hwnd, message, wparam, lparam) if answer is None else answer

                _BACKDROP_PROC = w.WNDPROC(procedure)
            red, green, blue = self.color
            wc = w.WNDCLASSEXW()
            wc.cbSize = ctypes.sizeof(wc)
            wc.lpfnWndProc = _BACKDROP_PROC
            wc.hInstance = w.GetModuleHandleW(None)
            wc.hCursor = w.LoadCursorW(None, ctypes.c_void_p(32512))  # IDC_ARROW
            wc.hbrBackground = w.CreateSolidBrush(red | (green << 8) | (blue << 16))
            wc.lpszClassName = name
            if not w.RegisterClassExW(ctypes.byref(wc)):
                error = ctypes.get_last_error()
                w.DeleteObject(wc.hbrBackground)
                if error != 1410:  # ERROR_CLASS_ALREADY_EXISTS: an earlier backdrop of this color
                    raise GuiError(f"RegisterClassExW failed (error {error})")
        return name

    def _pump(self, rect: Rect) -> None:
        try:
            w = win32()
            name = self._register(w)
            left, top, right, bottom = rect
            hwnd = w.CreateWindowExW(self.EXSTYLE, name, BACKDROP_TITLE, self.STYLE, left, top, right - left,
                                     bottom - top, None, None, w.GetModuleHandleW(None), None)
            if not hwnd:
                raise GuiError(f"CreateWindowExW failed (error {ctypes.get_last_error()})")
            self.hwnd = hwnd
        except BaseException as exc:  # noqa: BLE001 - open() reports it
            self._error = exc
            self._ready.set()
            return
        self._ready.set()
        message = w.MSG()
        while w.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
            w.TranslateMessage(ctypes.byref(message))
            w.DispatchMessageW(ctypes.byref(message))

    def place(self, rect: Rect, under: int) -> None:
        """Cover `rect` right below the window `under` in the z-order, shown and not activated."""
        left, top, right, bottom = rect
        if not win32().SetWindowPos(self.hwnd, under, left, top, right - left, bottom - top,
                                    SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER):
            raise GuiError(f"cannot place the privacy backdrop (SetWindowPos error {ctypes.get_last_error()})")

    def close(self, timeout: float = 5.0) -> str:
        w = win32()
        if self.hwnd and w.IsWindow(self.hwnd):
            w.PostMessageW(self.hwnd, WM_CLOSE, 0, 0)
        if self._thread is not None:
            self._thread.join(timeout)
            if self._thread.is_alive():
                raise GuiError(f"the privacy backdrop thread did not end within {timeout:g}s")
        if self.hwnd and w.IsWindow(self.hwnd):
            raise GuiError(f"the privacy backdrop {self.hwnd:#x} still exists")
        return "destroyed"


class Backdrop:
    """The privacy backdrop of one scenario run: what it is set to, its window, and every check."""

    def __init__(self, color: str | None, reason: str | None = None) -> None:
        self.color = color  # "#rrggbb" while on, None while off
        self.reason = reason  # why it is off
        self.initial = {"color": color, "reason": reason}
        self.window: Any = None
        self.area: Rect | None = None  # where it was placed last: the bounding rectangle of `covers`
        self.covers: list[Rect] = []  # every area this window had to cover so far; it never shrinks
        self.fresh = False  # new or moved since the last passing check: give it time to paint
        self.placements = 0
        self.restacks = 0  # placements that changed its position or the z-order
        self.events: list[dict[str, Any]] = []
        self.checks: list[dict[str, Any]] = []

    def set(self, color: str | None, reason: str | None) -> str:
        if color != self.color:
            self.drop("switched")
        self.color, self.reason = color, reason
        self.events.append({"event": "set", "color": color, "reason": reason})
        return f"backdrop {color}" if color else f"backdrop off: {reason}"

    def ensure(self, instance: "Instance", capture: Rect | None = None, band: int = 0) -> list[Rect] | None:
        """Cover what the instance's windows, and a `capture` with its `band`, need (backdrop_cover) right
        under the lowest of those windows; what they need (None while off, [] on no monitor at all)."""
        if self.color is None:
            return None
        instance.ensure_owned()
        w = win32()
        stack = w.window_stack()
        mine = [index for index, entry in enumerate(stack) if entry.shows() and entry.belongs_to(instance.pid)]
        if not mine:
            raise GuiError(f"ghostty pid {instance.pid} shows no window to put the privacy backdrop under")
        windows = [stack[index].rect for index in mine] + ([capture] if capture else [])
        need = backdrop_cover(w.monitors(), windows, [rect_inflate(capture, band)] if capture else [])
        if not need:
            return need  # nothing of the instance is on a monitor; a capture of it fails as uncovered
        covers = self.covers + [area for area in need if area not in self.covers]
        area = rect_union(covers)
        assert area is not None
        if self.window is None:
            window = BackdropWindow(parse_color(self.color))
            window.open(area)
            self.window = window
            self.events.append({"event": "created", "color": self.color, "area": list(area),
                                "covers": [list(item) for item in covers]})
        elif area != self.area:
            self.events.append({"event": "grown", "area": list(area), "covers": [list(item) for item in covers]})
        self.covers = covers
        position = next((index for index, entry in enumerate(stack) if entry.hwnd == self.window.hwnd), None)
        moved = area != self.area
        restacked = moved or position != mine[-1] + 1  # not right under the lowest window of the instance
        self.window.place(area, stack[mine[-1]].hwnd)
        self.placements += 1
        if moved:
            self.fresh = True
            self.area = area
        if restacked:
            self.restacks += 1
            time.sleep(BACKDROP_COMPOSE_S)
        return need

    def capture(self, instance: "Instance", info: WindowInfo, method: str, label: str) -> Image:
        """A capture of `info`; from the screen only while nothing but the instance and the backdrop shows."""
        if self.color is None or method != "screen":
            return instance.capture_window(info, method)
        w = win32()
        color = parse_color(self.color)
        band = max(1, round(BACKDROP_BAND_DIP * w.dpi(info.hwnd) / 96))
        need = self.ensure(instance, info.rect, band)
        assert need is not None
        check: dict[str, Any] = {"capture": label, "window": info.cls, "rect": list(info.rect),
                                 "covered": [list(area) for area in need]}
        uncovered = rect_subtract(info.rect, need)
        if uncovered:
            pixels = sum(rect_area(piece) for piece in uncovered)
            check.update({"uncovered": [list(piece) for piece in uncovered], "uncovered_pixels": pixels,
                          "status": "fail"})
            self.checks.append(check)
            raise GuiError(f"privacy backdrop check failed for {label}: {pixels} of {rect_area(info.rect)} window "
                           f"pixels lie outside the privacy backdrop, on no display monitor it covers ("
                           + ", ".join(str(list(piece)) for piece in uncovered) + "); the screenshot was not saved")
        band_regions = backdrop_regions(info.rect, band, need)
        regions = [info.rect, *band_regions]
        probe = rect_union(regions)
        assert probe is not None
        deadline = time.monotonic() + (BACKDROP_SETTLE_S if self.fresh else 0)
        attempts = 0
        while True:
            attempts += 1
            before = w.window_stack()
            image = instance.capture_window(info, "screen", region=probe, see_through=(self.window.hwnd,))
            after = w.window_stack()
            foreign: dict[int, StackEntry] = {}
            found = above = True
            for stack in (before, after):
                entries, present = backdrop_audit(stack, self.window.hwnd, instance.pid, regions)
                found = found and present
                above = above and above_backdrop(stack, self.window.hwnd, info.hwnd)
                foreign.update((entry.hwnd, entry) for entry in entries)
            keep_out = [rect_inflate(entry.rect, BACKDROP_EDGE_PX) for stack in (before, after) for entry in stack
                        if entry.shows() and entry.belongs_to(instance.pid)]
            band_stats = backdrop_band(image, keep_out, color, inside=band_regions)
            passed = found and above and not foreign and not band_stats["foreign_pixels"]
            # Only a backdrop that may not have reached the screen yet is worth another look.
            if passed or foreign or not found or not above or time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        check.update({"band": list(probe), "band_regions": [list(piece) for piece in band_regions], **band_stats,
                      "backdrop_in_stack": found, "window_above_backdrop": above, "attempts": attempts,
                      "foreign_windows": [{"hwnd": f"{entry.hwnd:#x}", "class": entry.cls, "pid": entry.pid,
                                           "image": image_name(entry.pid)} for entry in foreign.values()],
                      "status": "pass" if passed else "fail"})
        self.checks.append(check)
        if not passed:
            problems = []
            if foreign:
                problems.append(f"{len(foreign)} window(s) of other processes show there (" + "; ".join(
                    f"{item['class']} pid {item['pid']} {item['image']}" for item in check["foreign_windows"]) + ")")
            if not found:
                problems.append("the backdrop is not in the window stack")
            if not above:
                problems.append(f"the captured window {info.hwnd:#x} is not above the backdrop before and after the "
                                "capture (the image would show the backdrop instead of it)")
            if band_stats["foreign_pixels"]:
                x, y, seen = band_stats["first_foreign"]
                problems.append(f"{band_stats['foreign_pixels']} of {band_stats['checked_pixels']} band pixels are not "
                                f"{self.color} (first {seen} at ({x}, {y}))")
            raise GuiError(f"privacy backdrop check failed for {label}: {'; '.join(problems)}; "
                           "the screenshot was not saved")
        self.fresh = False
        return crop(image, info.rect)

    def drop(self, why: str) -> str | None:
        """Destroy the window if there is one; never raises, the result is recorded and returned."""
        if self.window is None:
            return None
        window, self.window, self.area, self.covers = self.window, None, None, []
        try:
            result = window.close()
        except Exception as exc:  # noqa: BLE001 - cleanup goes on; the failure is evidence
            result = f"failed: {exc}"
        self.events.append({"event": "destroyed", "why": why, "result": result})
        return result

    def teardown_failures(self) -> list[str]:
        """Every destruction that did not succeed: that window may still cover the user's monitors."""
        return [f"{event['why']}: {event['result']}" for event in self.events
                if event.get("event") == "destroyed" and event.get("result") != "destroyed"]

    def finish(self, why: str = "scenario end") -> dict[str, Any]:
        self.drop(why)
        return {"initial": self.initial, "color": self.color, "reason": self.reason, "placements": self.placements,
                "restacks": self.restacks, "events": self.events, "checks": self.checks}


# ---------------------------------------------------------------------------
# One isolated Ghostty instance
# ---------------------------------------------------------------------------


def same_path(a: str | Path, b: str | Path) -> bool:
    return os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))


def input_guard(function):
    """Audit a guard: every refusal, and every pass unless probe=True says that no input follows (a
    passed guard is how quiet-batch tells that the batch injected input)."""
    @functools.wraps(function)
    def checked(self, *args, probe: bool = False, **kwargs):
        try:
            result = function(self, *args, **kwargs)
        except InputBlocked as exc:
            extra = {'probe': True} if probe else {}
            self.record_input('guard', check=function.__name__, status='fail', cause=exc.cause, reason=str(exc),
                              **extra, **exc.details)
            raise
        if not probe:
            self.record_input('guard', check=function.__name__, status='pass')
        return result
    return checked


def image_name(pid: int) -> str | None:
    """Base name of a process image (no path, no window title); None when unreadable."""
    image = win32().process_image(pid) if pid else None
    return Path(image).name if image else None


@dataclass
class Instance:
    pid: int
    exe: str
    env_dir: Path
    creation: int  # FILETIME (100 ns) the process was created at
    launched: int  # FILETIME right before CreateProcess
    simulated_dpi: int | None = None
    children: list[list[Any]] = field(default_factory=list)  # [pid, creation, image name]
    input_events: list[dict] = field(default_factory=list)
    closing: bool = False  # close() started: an ending process is expected from now on
    gone_noted: bool = False  # the unexpected end was already audited once
    restarts: list[dict] = field(default_factory=list)  # restart steps that led to this instance
    original_layout: int | None = None  # the window thread's keyboard layout before the first switch
    loaded_layouts: list[int] = field(default_factory=list)  # layouts allow_load added; unloaded at the end

    def record_input(self, event: str, **data) -> None:
        row = {'schema': 'gx-input-guard-v1', 'event': event, 'time_ns': time.time_ns(),
               'harness_pid': os.getpid(), 'instance_pid': self.pid,
               'batch_id': os.environ.get('GX_PERF_BATCH_ID'), **data}
        self.input_events.append(row)
        if path := os.environ.get('GX_PERF_GUARD_LOG'):
            with Path(path).open('a', encoding='utf-8', newline='\n') as stream:
                stream.write(json.dumps(row, ensure_ascii=False) + '\n')

    def note_gone(self, reason: str) -> None:
        """Audit, once, that the instance ended or changed identity without this tool closing it.
        quiet-batch reads cause instance_gone as a product/driver failure, never as noise."""
        if not (self.closing or self.gone_noted):
            self.gone_noted = True
            self.record_input('instance', status='fail', cause='instance_gone', reason=reason)

    def release_input(self, events, control: str, aborted: bool) -> None:
        # Release only what this operation pressed. Never move the pointer,
        # reactivate a window, or send another down when the guard has failed.
        try:
            win32().send(events)
        except Exception as exc:
            self.record_input('release', control=control, abort_release=aborted, status='fail', reason=str(exc))
            raise
        self.record_input('release', control=control, abort_release=aborted, status='pass')

    # -- persistence for the session commands --------------------------------

    def save(self) -> None:
        data = {"pid": self.pid, "exe": self.exe, "env_dir": str(self.env_dir), "creation": self.creation,
                "launched": self.launched, "simulated_dpi": self.simulated_dpi, "children": self.children,
                "restarts": self.restarts, "original_layout": self.original_layout, "loaded_layouts": self.loaded_layouts}
        (self.env_dir / SESSION_FILE).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load(cls, env_dir: Path) -> "Instance":
        path = env_dir / SESSION_FILE
        if not path.is_file():
            raise UsageError(f"no session in {env_dir}; run: gx_win_gui.py start {env_dir}")
        data = json.loads(path.read_text(encoding="utf-8"))
        return cls(data["pid"], data["exe"], Path(data["env_dir"]), data["creation"], data["launched"],
                   data.get("simulated_dpi"), data.get("children", []), restarts=data.get("restarts", []),
                   original_layout=data.get("original_layout"), loaded_layouts=data.get("loaded_layouts", []))

    # -- process ------------------------------------------------------------

    @property
    def log(self) -> Path:
        return log_path(self.env_dir)

    def owned(self) -> bool:
        """Still the process this tool started: same image path and creation time."""
        w = win32()
        image = w.process_image(self.pid)
        return image is not None and same_path(image, self.exe) and w.process_creation(self.pid) == self.creation

    def alive(self) -> bool:
        return win32().process_alive(self.pid) and self.owned()

    def ensure_owned(self) -> None:
        if not self.alive():
            message = (f"ghostty pid {self.pid} has ended or is no longer the process this tool started; "
                       "no input was sent and no window was touched")
            self.note_gone(message)
            raise InputBlocked(message, cause="instance_gone")

    def remember_children(self) -> None:
        w = win32()
        known = {entry[0] for entry in self.children}
        for pid, name in w.child_processes(self.pid):
            if pid not in known:
                created = w.process_creation(pid)
                if created is not None:
                    self.children.append([pid, created, name])

    def close(self, timeout: float = 5.0, *, force: bool = True) -> str:
        """Close the instance: WM_CLOSE to its windows, then terminate it and its leftover child processes.
        With force=False a process still running after `timeout` is left alone and GuiError raised."""
        w = win32()
        if not self.alive():
            self.note_gone(f"ghostty pid {self.pid} had ended, or was no longer the process this tool started, "
                           "before the close")
            return "not running"
        self.remember_children()
        self.closing = True
        for info in self.windows():
            if info.cls == WINDOW_CLASS:
                w.PostMessageW(info.hwnd, WM_CLOSE, 0, 0)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and w.process_alive(self.pid):
            time.sleep(0.05)
        how = "closed"
        if w.process_alive(self.pid) and not force:
            self.closing = False
            raise GuiError(f"ghostty pid {self.pid} did not exit within {timeout:g}s after WM_CLOSE; not forcing it")
        if w.process_alive(self.pid):
            if not self.owned():
                raise GuiError(f"pid {self.pid} is no longer the instance this tool started; not terminating it")
            w.terminate(self.pid)
            how = "terminated"
        time.sleep(0.5)
        for pid, created, _name in self.children:
            if w.process_alive(pid) and w.process_creation(pid) == created:
                w.terminate(pid)
        return how

    # -- windows ------------------------------------------------------------

    def windows(self) -> list[WindowInfo]:
        self.ensure_owned()
        return win32().top_windows(self.pid)

    def window(self, kind: str = "main", shown: bool = True) -> WindowInfo | None:
        """The main window (GhosttyWindow without WS_EX_TOOLWINDOW) or the quick terminal (with it)."""
        candidates = [info for info in self.windows() if info.cls == WINDOW_CLASS
                      and info.toolwindow == (kind == "quick")
                      and (not shown or (info.visible and not info.cloaked))]
        if not candidates:
            return None
        return max(candidates, key=lambda info: (info.rect[2] - info.rect[0]) * (info.rect[3] - info.rect[1]))

    def require_window(self, kind: str = "main") -> WindowInfo:
        info = self.window(kind)
        if info is None:
            raise GuiError(f"ghostty pid {self.pid} shows no {kind} window")
        return info

    def wait_window(self, timeout: float, kind: str = "main") -> dict[str, float]:
        """Wait until the window is created, visible and uncloaked; milliseconds after launch for each."""
        w = win32()
        marks: dict[str, float] = {}
        deadline = time.monotonic() + timeout
        while True:
            now = w.now_filetime()
            infos = [info for info in self.windows() if info.cls == WINDOW_CLASS and info.toolwindow == (kind == "quick")]
            if infos and "created_ms" not in marks:
                marks["created_ms"] = (now - self.creation) / 10_000
            if any(info.visible for info in infos) and "visible_ms" not in marks:
                marks["visible_ms"] = (now - self.creation) / 10_000
            if any(info.visible and not info.cloaked for info in infos):
                marks["shown_ms"] = (now - self.creation) / 10_000
                return marks
            if not w.process_alive(self.pid):
                raise GuiError(f"ghostty exited before showing a {kind} window; see {self.log}")
            if time.monotonic() > deadline:
                raise GuiError(f"no {kind} window within {timeout:g}s")
            time.sleep(0.001)

    def find_window(self, cls: str | None = None, title: str | None = None, timeout: float = 10.0) -> WindowInfo:
        """A visible top-level window of this instance other than a GhosttyWindow (such as the MessageBox
        or TaskDialog of a start that failed) with class `cls` and a title matching the regex `title`,
        the topmost if several; waits up to `timeout` seconds."""
        if cls is None and title is None:
            raise UsageError("find_window needs a class or a title pattern")
        regex = re.compile(title) if title is not None else None

        def matches() -> list[WindowInfo]:
            return [info for info in self.windows() if info.cls != WINDOW_CLASS and info.visible and not info.cloaked
                    and info.rect[0] < info.rect[2] and info.rect[1] < info.rect[3]
                    and (cls is None or info.cls == cls) and (regex is None or regex.search(info.title))]

        deadline = time.monotonic() + timeout
        while True:
            found = matches()
            if found:
                return found[0]
            if time.monotonic() >= deadline:
                shown = "; ".join(info.describe() for info in self.windows() if info.visible) or "none"
                raise GuiError(f"no window of ghostty pid {self.pid} with class {cls or 'any'} and a title matching "
                               f"{title or 'anything'} within {timeout:g}s; visible: {shown}")
            time.sleep(0.05)

    def terminals(self, window: WindowInfo | None = None) -> list[WindowInfo]:
        window = window or self.require_window()
        found = [info for info in win32().child_windows(window.hwnd, TERMINAL_CLASS) if info.visible]
        return sorted(found, key=lambda info: (info.rect[1], info.rect[0]))

    def popups(self) -> list[WindowInfo]:
        return [info for info in self.windows() if info.visible and not info.cloaked and info.cls != WINDOW_CLASS
                and info.rect[2] > info.rect[0] and info.rect[3] > info.rect[1]]

    def scale(self, window: WindowInfo) -> float:
        return (self.simulated_dpi or win32().dpi(window.hwnd)) / 96

    def anchor(self, spec: str, window: WindowInfo) -> tuple[int, int, int, int]:
        if spec == "client":
            return win32().client_rect(window.hwnd)
        if spec == "window":
            return window.rect
        match = re.fullmatch(r"terminal:(\d+)", spec)
        if match:
            terminals = self.terminals(window)
            index = int(match.group(1))
            if index >= len(terminals):
                raise GuiError(f"there are {len(terminals)} visible terminals, no terminal:{index}")
            return terminals[index].rect
        raise UsageError(f"unknown anchor {spec!r}; use client, window or terminal:N")

    def point(self, x: float | None, y: float | None, anchor: str = "client", kind: str = "main") -> tuple[int, int]:
        window = self.require_window(kind)
        return resolve_point(x, y, self.anchor(anchor, window), self.scale(window))

    # -- guarded input --------------------------------------------------------

    def hang_evidence(self, other_class: str, other_image: str | None) -> str | None:
        """Why another window in the way means the instance hangs or crashed rather than a change of the
        desktop: one of its visible windows is hung (IsHungAppWindow), or the window in the way is a
        Ghost or WerFault window while the instance does not answer WM_NULL within 2 s; None otherwise."""
        w = win32()
        mine = [info for info in w.top_windows(self.pid) if info.visible]
        hung = [info for info in mine if w.hung(info.hwnd)]
        if hung:
            return f"IsHungAppWindow reports its {hung[0].cls} {hung[0].hwnd:#x}"
        if (other_class in HANG_CLASSES or (other_image or "").lower() in CRASH_IMAGES) and mine:
            if w.send_message(mine[0].hwnd, WM_NULL, timeout_ms=2000) is None:
                return f"{other_class} ({other_image}) is in front and its {mine[0].cls} does not answer WM_NULL in 2 s"
        return None

    def blocked(self, what: str, cause: str, pid: int, name: str) -> InputBlocked:
        image = image_name(pid)
        hang = self.hang_evidence(name, image)
        if hang:
            return InputBlocked(f"ghostty pid {self.pid} hangs or crashed ({hang}; {what}); no input was sent",
                                cause="instance_hung", other_pid=pid, other_class=name, other_image=image)
        return InputBlocked(f"{what}, not ghostty pid {self.pid}; no input was sent", cause=cause,
                            other_pid=pid, other_class=name, other_image=image)

    @input_guard
    def ensure_foreground(self) -> None:
        self.ensure_owned()
        w = win32()
        hwnd = w.foreground()
        pid = w.window_pid(hwnd) if hwnd else 0
        if pid != self.pid:
            name = w.class_name(hwnd) if hwnd else "none"
            raise self.blocked(f"the foreground window is {hwnd:#x} ({name}, pid {pid})", "foreground_lost", pid, name)

    @input_guard
    def ensure_point(self, x: int, y: int) -> None:
        self.ensure_owned()
        w = win32()
        hwnd = w.window_at(x, y)
        if not hwnd or (w.window_pid(hwnd) != self.pid and w.root_owner_pid(hwnd) != self.pid):
            pid = w.window_pid(hwnd) if hwnd else 0
            name = w.class_name(hwnd) if hwnd else "none"
            raise self.blocked(f"the window at ({x}, {y}) is {hwnd:#x} ({name}, pid {pid})", "pointer_target_lost",
                               pid, name)

    def activate(self, kind: str = "main") -> None:
        self.ensure_owned()
        if not win32().activate(self.require_window(kind).hwnd):
            raise GuiError("cannot bring the ghostty window to the foreground; click it once, then retry")

    def type_text(self, text: str, delay: float = 0.003) -> None:
        w = win32()
        for char in text:
            if char in "\n\r":
                if char == "\n":
                    self.press("enter")
                continue
            if char == "\t":
                self.press("tab")
                continue
            for unit in utf16_units(char):
                self.ensure_foreground()
                w.send([w.unicode_input(unit, False), w.unicode_input(unit, True)])
            time.sleep(delay)

    def send_or_release(self, events: Sequence[Any], ups: Sequence[Any], control: str) -> None:
        """One SendInput of `events`. When it fails part way, some of its downs may be in the input
        stream: send `ups`, the release of everything the batch presses, then raise (audited as an
        abort release under GX_PERF_GUARD_LOG)."""
        try:
            win32().send(events)
        except GuiError:
            if ups:
                try:
                    self.release_input(ups, control, True)
                except GuiError:
                    pass
            raise

    def press(self, chord: str, repeat: int = 1, delay: float = 0.05) -> None:
        w = win32()
        mods, vk = parse_chord(chord)
        for index in range(repeat):
            self.ensure_foreground()
            events = [w.key_input(mod, False) for mod in mods]
            events += [w.key_input(vk, False), w.key_input(vk, True)]
            events += [w.key_input(mod, True) for mod in reversed(mods)]
            self.send_or_release(events, [w.key_input(vk, True)] + [w.key_input(mod, True) for mod in reversed(mods)],
                                 chord)
            if index + 1 < repeat:
                time.sleep(delay)

    def hold_key(self, key: str, seconds: float = 2, hz: float = 30) -> None:
        """A held key with explicit repeat downs; check ownership before every event."""
        if seconds <= 0 or hz <= 0 or seconds * hz > 10000:
            raise UsageError("invalid hold duration or repeat frequency")
        mods, vk = parse_chord(key)
        if mods:
            raise UsageError("hold_key accepts one unmodified key")
        w = win32()
        start = time.monotonic()
        # A completion flag, not sys.exc_info(): inside a caller's except block
        # exc_info() still reports the caller's exception and would label a
        # normal finish as an abort.
        sent = completed = False
        try:
            for index in range(max(1, round(seconds * hz))):
                self.ensure_foreground()
                w.send([w.key_input(vk, False)])
                sent = True
                time.sleep(max(0, start + (index + 1) / hz - time.monotonic()))
            completed = True
        finally:
            if sent:
                self.release_input([w.key_input(vk, True)], key, not completed)

    def uia_rows(self, hwnd: int) -> list[dict]:
        """Read geometry under an owned HWND; no UIA invocation or desktop search."""
        self.ensure_owned()
        if win32().window_pid(hwnd) != self.pid:
            raise InputBlocked("UIA root no longer belongs to this instance")
        script = ("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference='Stop'; "
                  "Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes; "
                  f"$root=[Windows.Automation.AutomationElement]::FromHandle([IntPtr]{int(hwnd)}); "
                  "$nodes=$root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition); "
                  "@($nodes | ForEach-Object {$c=$_.Current; $r=$c.BoundingRectangle; "
                  "if (!$c.IsOffscreen -and $r.Width -gt 0 -and $r.Height -gt 0) { "
                  "@{name=$c.Name;id=$c.AutomationId;type=$c.ControlType.ProgrammaticName; "
                  "rect=@($r.X,$r.Y,$r.Width,$r.Height)}}}) | ConvertTo-Json -Depth 4 -Compress")
        result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
                                capture_output=True, timeout=20)
        self.ensure_owned()
        if win32().window_pid(hwnd) != self.pid or result.returncode:
            raise GuiError(f"UIA geometry probe failed: {result.stderr.decode('utf-8', errors='replace')}")
        data = json.loads(result.stdout.decode('utf-8-sig'))
        return data if isinstance(data, list) else ([data] if isinstance(data, dict) else [])

    def caption_point(self, window: WindowInfo) -> tuple[int, int]:
        """Find a real HTCAPTION point; do not guess where tabs end."""
        self.ensure_owned()
        w = win32()
        scale = self.scale(window)
        left, top, right, _ = window.rect
        for dy in (16, 24, 32, 10, 6):
            y = round(top + dy * scale)
            for x in range(round(right - 16 * scale), round(left + 16 * scale), -max(1, round(8 * scale))):
                packed = (x & 0xffff) | ((y & 0xffff) << 16)
                if w.send_message(window.hwnd, 0x0084, 0, packed) == 2:  # WM_NCHITTEST / HTCAPTION
                    self.ensure_point(x, y, probe=True)  # nothing is sent yet: the drag checks it again
                    return x, y
        raise GuiError('no visible draggable HTCAPTION point in the owned window')

    def _modifier_events(self, mods: Sequence[str], up: bool) -> list[Any]:
        w = win32()
        vks = [parse_chord(f"{mod}+a")[0][0] for mod in mods]
        return [w.key_input(vk, up) for vk in (reversed(vks) if up else vks)]

    def mouse(self, x: int, y: int, *, button: str = "left", action: str = "click", count: int = 1,
              mods: Sequence[str] = ()) -> None:
        """Move to (x, y) and press/release `button`: action click, down, up or move."""
        w = win32()
        if button not in MOUSE_BUTTONS:
            raise UsageError(f"unknown mouse button {button!r}")
        down, up, data = MOUSE_BUTTONS[button]
        self.ensure_foreground()
        self.ensure_point(x, y)
        events = self._modifier_events(mods, False)
        events.append(w.mouse_input(0x0001 | 0x8000 | 0x4000, x, y))  # MOVE | ABSOLUTE | VIRTUALDESK
        if action == "click":
            for _ in range(count):
                events += [w.mouse_input(down, data=data), w.mouse_input(up, data=data)]
        elif action == "down":
            events.append(w.mouse_input(down, data=data))
        elif action == "up":
            events.append(w.mouse_input(up, data=data))
        elif action != "move":
            raise UsageError(f"unknown mouse action {action!r}")
        events += self._modifier_events(mods, True)
        ups = ([w.mouse_input(up, data=data)] if action in ("click", "down") else []) + self._modifier_events(mods, True)
        self.send_or_release(events, ups, "+".join([*mods, button]))

    def wheel(self, x: int, y: int, delta: int = 120, horizontal: bool = False, count: int = 1,
              mods: Sequence[str] = ()) -> None:
        """Wheel notches at (x, y). With mods those keys are pressed first and released after the notches,
        always and only those, even when a guard or SendInput fails in between (as drag and hold_key)."""
        vks = modifier_vks(mods)  # a usage error before anything else
        w = win32()
        self.ensure_foreground()
        self.ensure_point(x, y)
        events = [w.mouse_input(0x0001 | 0x8000 | 0x4000, x, y)]
        events += [w.mouse_input(0x1000 if horizontal else 0x0800, data=delta) for _ in range(count)]
        if not vks:
            w.send(events)
            return
        # A completion flag rather than sys.exc_info(), as in hold_key.
        pressed = completed = False
        try:
            pressed = True  # from here on some downs may be in the input stream, even if send() fails
            w.send([w.key_input(vk, False) for vk in vks])
            self.ensure_foreground()
            self.ensure_point(x, y)
            w.send(events)
            completed = True
        finally:
            if pressed:
                self.release_input([w.key_input(vk, True) for vk in reversed(vks)],
                                   "+".join(MOD_NAMES[vk] for vk in vks), not completed)

    def drag(self, start: tuple[int, int], end: tuple[int, int], *, steps: int = 12, button: str = "left",
             release: bool = True, step_delay: float = 0.015) -> None:
        self.mouse(*start, button=button, action="down")
        completed = False
        try:
            for index in range(1, steps + 1):
                x = round(start[0] + (end[0] - start[0]) * index / steps)
                y = round(start[1] + (end[1] - start[1]) * index / steps)
                self.ensure_foreground()
                self.ensure_point(x, y)
                win32().send([win32().mouse_input(0x0001 | 0x8000 | 0x4000, x, y)])
                time.sleep(step_delay)
            completed = True
        finally:
            # release=False keeps the button down only after a completed drag.
            if release or not completed:
                self.release_input([win32().mouse_input(MOUSE_BUTTONS[button][1], data=MOUSE_BUTTONS[button][2])],
                                   button, not completed)

    # -- test hooks and probes ------------------------------------------------

    def simulate_dpi(self, dpi: int) -> None:
        window = self.require_window()
        if win32().send_message(window.hwnd, WM_GHOSTTY_SIMULATE_DPI, dpi) is None:
            raise GuiError("the window did not answer WM_GHOSTTY_SIMULATE_DPI")
        self.simulated_dpi = dpi

    def simulate_d2d_failure(self, kind: str = "main") -> int:
        """Test hook WM_GHOSTTY_SIMULATE_D2D_FAILURE: the title bar of this window (only) marks Direct2D
        as failed and queues the fallback to the system caption without tabs. Its caption state after."""
        window = self.require_window(kind)
        w = win32()
        answer = w.send_message(window.hwnd, WM_GHOSTTY_SIMULATE_D2D_FAILURE)
        if answer is None:
            raise GuiError("the window did not answer WM_GHOSTTY_SIMULATE_D2D_FAILURE")
        if answer != 1:
            raise GuiError(f"WM_GHOSTTY_SIMULATE_D2D_FAILURE returned {answer}, not 1: the build lacks the hook")
        state = w.send_message(window.hwnd, WM_GHOSTTY_CAPTION_QUERY)
        if state is None:
            raise GuiError("the window did not answer WM_GHOSTTY_CAPTION_QUERY")
        if not state & CAPTION_DIRECT2D_FAILED:
            raise GuiError(f"the title bar does not report the Direct2D failure (caption state {state:#06b})")
        return state

    def simulate_system_theme(self, scheme: str = "follow", high_contrast: str = "follow") -> int:
        """Test hook WM_GHOSTTY_SIMULATE_SYSTEM_THEME: the app acts as if Windows switched its apps color
        scheme and high contrast (follow: what Windows says). The wparam sent."""
        wparam = system_theme_wparam(scheme, high_contrast)
        answer = win32().send_message(self.require_window().hwnd, WM_GHOSTTY_SIMULATE_SYSTEM_THEME, wparam)
        if answer is None:
            raise GuiError("the window did not answer WM_GHOSTTY_SIMULATE_SYSTEM_THEME")
        if answer != 1:
            raise GuiError(f"WM_GHOSTTY_SIMULATE_SYSTEM_THEME {wparam:#x} returned {answer}, not 1: "
                           "the build rejects the theme or lacks the hook")
        return wparam

    def focused_terminal(self) -> int:
        window = self.require_window()
        focus = win32().focus_window(window.hwnd)
        if win32().class_name(focus) == TERMINAL_CLASS:
            return focus
        terminals = self.terminals(window)
        if not terminals:
            raise GuiError("no visible terminal")
        return terminals[0].hwnd

    def cancel_mode(self, terminal: int | None = None) -> None:
        hwnd = self.focused_terminal() if terminal is None else self.terminals()[terminal].hwnd
        if win32().send_message(hwnd, WM_CANCELMODE) is None:
            raise GuiError("the terminal did not answer WM_CANCELMODE")

    def gpu_reset(self, terminal: int = 0) -> None:
        if win32().send_message(self.terminals()[terminal].hwnd, WM_GHOSTTY_SIMULATE_GPU_RESET) is None:
            raise GuiError("the terminal did not answer WM_GHOSTTY_SIMULATE_GPU_RESET")

    def ime_off(self) -> str:
        """Switch the window's thread to a loaded English (US) layout, so an IME such as Microsoft Pinyin
        does not take the keys of the following steps. Like layout it never loads one (see Keyboard
        layouts); the previous layout is restored at stop or at the end of the scenario."""
        w = win32()
        window = self.require_window()
        if w.keyboard_layout(window.hwnd) & 0xFFFF == 0x0409:
            return "already US"
        us = [hkl for hkl in w.keyboard_layouts() if hkl & 0xFFFF == 0x0409]
        if not us:
            raise Blocked("no English (US) keyboard layout is loaded for this user (GetKeyboardLayoutList); "
                          "ime_off does not load one: add English (US) to the user's languages or run in the VM")
        result = self.switch_layout(hkl_text(us[0]), strict=False)
        return result if result.startswith("layout is still") else f"switched to US ({result})"

    def switch_layout(self, target: str, *, allow_load: bool = False, strict: bool = True) -> str:
        """Switch the window's thread to the keyboard layout `target` (see Keyboard layouts). Only a
        layout GetKeyboardLayoutList reports is used unless allow_load (VM only) may load a KLID; what
        that adds is remembered for unload_layouts. Not strict: a thread that does not switch in time
        is reported instead of failing."""
        w = win32()
        window = self.require_window()
        loaded = w.keyboard_layouts()
        hkl, klid = resolve_layout(target, loaded)
        added = False
        if hkl is None:
            if not allow_load or klid is None:
                hint = ("name an HKL from that list" if klid is None else
                        "pick a loaded one; only inside a VM may --allow-load load it")
                raise Blocked(f"keyboard layout {target} is not loaded for this user (GetKeyboardLayoutList: "
                              f"{', '.join(hkl_text(value) for value in loaded) or 'none'}); {hint}")
            vm_guard(f"loading keyboard layout {klid}")
            hkl = w.load_layout(klid)
            if hkl & 0xFFFFFFFF not in {value & 0xFFFFFFFF for value in loaded}:
                added = True
                self.loaded_layouts.append(hkl)
        before = w.keyboard_layout(window.hwnd)
        if self.original_layout is None:
            self.original_layout = before
        detail = f"keyboard layout {hkl_text(before)} -> {hkl_text(hkl)}" + (f" (loaded {klid})" if added else "")
        if before == hkl & 0xFFFFFFFF:
            return detail + " (already)"
        w.request_layout(window.hwnd, hkl)
        deadline = time.monotonic() + LAYOUT_SWITCH_S
        while (current := w.keyboard_layout(window.hwnd)) != hkl & 0xFFFFFFFF:
            if time.monotonic() >= deadline:
                if strict:
                    raise GuiError(f"the window's thread still uses {hkl_text(current)}, not {hkl_text(hkl)}, "
                                   f"{LAYOUT_SWITCH_S:g}s after WM_INPUTLANGCHANGEREQUEST")
                return f"layout is still {hkl_text(current)}"
            time.sleep(0.02)
        return detail

    def restore_layout(self) -> str | None:
        """Switch the window's thread back to the layout it had before the first switch; never raises."""
        if self.original_layout is None:
            return None
        original = self.original_layout
        try:
            if not self.alive():
                return f"not switched back to {hkl_text(original)}: the instance is gone"
            result = self.switch_layout(hkl_text(original))
            self.original_layout = None
            return f"switched back: {result}"
        except Exception as exc:  # noqa: BLE001 - cleanup goes on; the failure is evidence
            return f"switching back to {hkl_text(original)} failed: {exc}"

    def unload_layouts(self) -> list[str]:
        """Unload the layouts allow_load added; never raises."""
        results = []
        while self.loaded_layouts:
            hkl = self.loaded_layouts.pop()
            try:
                ok = win32().unload_layout(hkl)
                results.append(f"unloaded {hkl_text(hkl)}" if ok else
                               f"UnloadKeyboardLayout {hkl_text(hkl)} failed (error {ctypes.get_last_error()})")
            except Exception as exc:  # noqa: BLE001 - cleanup goes on; the failure is evidence
                results.append(f"unloading {hkl_text(hkl)} failed: {exc}")
        return results

    def responsive(self, timeout: float = 2.0) -> bool:
        window = self.require_window()
        return win32().send_message(window.hwnd, WM_NULL, timeout_ms=int(timeout * 1000)) is not None

    def resize(self, width: int, height: int) -> float:
        """Resize the main window (outer size, physical pixels); milliseconds SetWindowPos took to return."""
        window = self.require_window()
        began = time.perf_counter()
        if not win32().SetWindowPos(window.hwnd, None, 0, 0, width, height, 0x0002 | 0x0004 | 0x0010):
            raise GuiError(f"SetWindowPos failed (error {ctypes.get_last_error()})")
        return (time.perf_counter() - began) * 1000

    # -- capture --------------------------------------------------------------

    def capture_window(self, info: WindowInfo, method: str = "screen", region: Rect | None = None,
                       see_through: Sequence[int] = ()) -> Image:
        """Capture a window; with `region` (screen only) that larger screen area around it. A window in
        `see_through` (the privacy backdrop) showing through a transparent part does not cover it."""
        self.ensure_owned()
        w = win32()
        if method == "print":
            return w.capture_print(info.hwnd)
        if method != "screen":
            raise UsageError(f"unknown capture method {method!r}")
        left, top, right, bottom = info.rect
        for fx, fy in ((0.5, 0.5), (0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)):
            x, y = round(left + (right - left) * fx), round(top + (bottom - top) * fy)
            hwnd = w.window_at(x, y)
            if hwnd and hwnd not in see_through and w.window_pid(hwnd) != self.pid and w.root_owner_pid(hwnd) != self.pid:
                raise GuiError(f"window {info.hwnd:#x} is covered at ({x}, {y}) by {w.class_name(hwnd)} of pid "
                               f"{w.window_pid(hwnd)}; bring it to the front or use --method print")
        return w.capture_screen(region or info.rect)

    # -- log --------------------------------------------------------------------

    def log_text(self) -> str:
        try:
            return self.log.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return ""

    def wait_log(self, pattern: str, timeout: float = 10.0) -> str:
        regex = re.compile(pattern)
        deadline = time.monotonic() + timeout
        while True:
            for line in self.log_text().splitlines():
                if regex.search(line):
                    return line
            if time.monotonic() > deadline:
                raise GuiError(f"no log line matches {pattern!r} within {timeout:g}s ({self.log})")
            time.sleep(0.05)


def remove_tree(path: Path, acl: Callable[[Sequence[str]], tuple[int, str]] | None = None) -> str:
    """shutil.rmtree for a directory this tool wrote. When a deny entry or read-only attribute that an
    aborted run left there (file steps with readonly) refuses it, reset the ACLs below `path` to the
    inherited ones, clear the read-only attributes and try once more; how it went."""
    try:
        shutil.rmtree(path)
        return "removed"
    except PermissionError as exc:
        first = exc
    code, output = (acl or run_icacls)([str(path), "/reset", "/T", "/C", "/Q"])
    for folder, _dirs, files in os.walk(path):
        for name in files:
            try:
                os.chmod(os.path.join(folder, name), stat.S_IREAD | stat.S_IWRITE)
            except OSError:
                pass
    try:
        shutil.rmtree(path)
    except OSError as exc:
        raise GuiError(f"cannot remove {path}: {exc} (first attempt: {first}; icacls /reset exit {code}: "
                       f"{output}); recover by hand: icacls \"{path}\" /reset /T /C /Q, then "
                       f"attrib -R \"{path}\\*\" /S /D") from None
    return f"removed after icacls /reset (exit {code}) and clearing read-only attributes"


def prepare_env_dir(env_dir: Path, fresh: bool) -> None:
    """Create the isolated profile directory; with fresh, empty one this tool made before (never other folders)."""
    if fresh and env_dir.exists():
        if not (env_dir / ENV_MARKER).is_file():
            raise UsageError(f"{env_dir} exists and was not created by this tool; use a new directory")
        remove_tree(env_dir)
    env_dir.mkdir(parents=True, exist_ok=True)
    (env_dir / ENV_MARKER).write_text("isolated LOCALAPPDATA and XDG_CONFIG_HOME of gx_win_gui.py\n", encoding="utf-8")


def launch(exe: Path, env_dir: Path, *, config: str | None = None, env: Mapping[str, str] | None = None,
           args: Sequence[str] = ()) -> Instance:
    # Child cwd is the private profile. Resolve both paths before that change so
    # relative --out cannot turn the isolation variables into nested paths.
    exe = exe.resolve()
    env_dir = env_dir.resolve()
    if not exe.is_file():
        raise UsageError(f"{exe} does not exist; build it first with: just build")
    w = win32()
    if config is not None:
        write_config(env_dir, config)
    environment = isolated_environment(os.environ, env_dir, env)
    launched = w.now_filetime()
    process = subprocess.Popen([str(exe), *args], env=environment, cwd=str(env_dir), stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    creation = w.process_creation(process.pid)
    if creation is None:
        raise GuiError(f"ghostty pid {process.pid} exited right after the start")
    return Instance(process.pid, str(exe.resolve()), env_dir.resolve(), creation, launched)


def run_icacls(args: Sequence[str]) -> tuple[int, str]:
    result = subprocess.run(["icacls", *args], capture_output=True, timeout=60, check=False)
    output = (result.stdout + result.stderr).decode("mbcs" if sys.platform == "win32" else "utf-8", errors="replace")
    return result.returncode, output.strip()


def write_probe(path: Path) -> bool:
    """Whether the current user may write `path`: append to a file (writing nothing), or create and
    delete a probe file in a directory."""
    try:
        if path.is_dir():
            probe = path / f".gx-win-gui-probe-{os.getpid()}-{time.time_ns()}"
            with probe.open("xb"):
                pass
            probe.unlink()
        else:
            with path.open("ab"):
                pass
    except PermissionError:
        return False
    except OSError as exc:
        raise GuiError(f"the write probe of {path} failed: {exc}") from None
    return True


def deletable_entries(path: Path, limit: int = 16) -> tuple[int, list[str]]:
    """How many of the first `limit` entries inside the directory `path` were tried, and the names of
    those the current user could still delete or rename (Win32.can_open_for_delete)."""
    tried, deletable = 0, []
    for entry in sorted(path.iterdir())[:limit]:
        tried += 1
        if win32().can_open_for_delete(entry):
            deletable.append(entry.name)
    return tried, deletable


class ReadOnlyPaths:
    """Files and directories file steps made read-only, released again at the end of the scenario.

    acl runs icacls with arguments and answers (exit code, output); sid gives the current user's SID;
    probe answers whether the current user may write a path; delete_check answers how many entries of a
    directory it tried and which could still be deleted. All four can be replaced for tests."""

    DENY = "(OI)(CI)(DE,WD,AD,WEA,WA,DC)"

    def __init__(self, acl: Callable[[Sequence[str]], tuple[int, str]] | None = None,
                 sid: Callable[[], str] | None = None, probe: Callable[[Path], bool] | None = None,
                 delete_check: Callable[[Path], tuple[int, list[str]]] | None = None) -> None:
        self.acl = acl or run_icacls
        self.sid = sid or (lambda: win32().current_user_sid())
        self.probe = probe or write_probe
        self.delete_check = delete_check or deletable_entries
        self.paths: dict[Path, str] = {}  # path -> "attribute" or "acl", in the order they were protected
        self.events: list[dict[str, Any]] = []

    def _icacls(self, *args: str) -> None:
        code, output = self.acl(list(args))
        if code != 0:
            raise GuiError(f"icacls {' '.join(args)} failed ({code}): {output}")

    def protect(self, path: Path, label: str) -> str:
        if path in self.paths:
            return f"{label} is read-only already"
        if not path.exists():
            raise GuiError(f"{label} does not exist; write it (text) or create it (directory = true) first")
        if path.is_dir():
            method = "acl"
            self._icacls(str(path), "/deny", f"*{self.sid()}:{self.DENY}")
        else:
            method = "attribute"
            try:
                os.chmod(path, stat.S_IREAD)
            except OSError as exc:
                raise GuiError(f"cannot make {label} read-only: {exc}") from None
        self.paths[path] = method
        if self.probe(path):
            self.release(path, label)
            raise GuiError(f"{label} is still writable after making it read-only ({method}); released it again")
        event: dict[str, Any] = {"event": "readonly", "path": label, "method": method, "probe": "write refused"}
        detail = "a write attempt was refused"
        if method == "acl":
            tried, deletable = self.delete_check(path)
            if deletable:
                self.release(path, label)
                raise GuiError(f"{label}: {', '.join(deletable)} could still be deleted after making it read-only; "
                               "released it again")
            event["delete_probe"] = {"entries_tried": tried, "deletable": []}
            detail += (f", DELETE access to its {tried} existing entries too" if tried else
                       ", and it has no entries to try DELETE access on")
        self.events.append(event)
        return f"{label} is read-only ({method}; {detail})"

    def release(self, path: Path, label: str) -> str:
        method = self.paths.pop(path, None) or ("acl" if path.is_dir() else "attribute")
        how = method
        if method == "acl":
            self._icacls(str(path), "/remove:d", f"*{self.sid()}")
            if not self.probe(path):
                self._icacls(str(path), "/reset", "/T", "/C")  # back to the inherited entries only
                how = "acl, reset"
        else:
            try:
                os.chmod(path, stat.S_IREAD | stat.S_IWRITE)
            except OSError as exc:
                self.paths[path] = method
                raise GuiError(f"cannot make {label} writable again: {exc}") from None
        if not self.probe(path):
            self.paths[path] = method
            raise GuiError(f"{label} is still not writable after releasing it ({how})")
        self.events.append({"event": "writable", "path": label, "method": how, "probe": "write allowed"})
        return f"{label} is writable again ({how})"

    def release_all(self, root: Path) -> list[str]:
        """Release every path still protected, newest first; never raises."""
        results = []
        for path in reversed(list(self.paths)):
            label = str(path.relative_to(root)) if root in path.parents else str(path)
            try:
                results.append(self.release(path, label))
            except Exception as exc:  # noqa: BLE001 - cleanup goes on; the failure is evidence
                results.append(f"{label}: release failed: {exc}")
        return results


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

POINT_KEYS = frozenset(("x", "y", "in", "window"))
# action -> (required keys, optional keys)
ACTIONS: dict[str, tuple[frozenset[str], frozenset[str]]] = {
    "wait_window": (frozenset(), frozenset(("timeout", "window"))),
    "activate": (frozenset(), frozenset(("window",))),
    "sleep": (frozenset(("seconds",)), frozenset()),
    "wait_log": (frozenset(("pattern",)), frozenset(("timeout",))),
    "assert_log": (frozenset(("pattern",)), frozenset(("present",))),
    "wait_file": (frozenset(("path", "pattern")), frozenset(("timeout",))),
    "wait_title": (frozenset(("pattern",)), frozenset(("timeout", "window"))),
    "assert_title": (frozenset(("pattern",)), frozenset(("window",))),
    "type": (frozenset(("text",)), frozenset(("delay", "repeat"))),
    "key": (frozenset(("keys",)), frozenset(("repeat", "delay"))),
    "click": (frozenset(), POINT_KEYS | {"button", "count", "mods"}),
    "mouse_down": (frozenset(), POINT_KEYS | {"button", "mods"}),
    "mouse_up": (frozenset(), POINT_KEYS | {"button", "mods"}),
    "move": (frozenset(), POINT_KEYS),
    "drag": (frozenset(("from", "to")), frozenset(("in", "window", "steps", "button"))),
    "drag_divider": (frozenset(("between", "fraction")), frozenset(("steps",))),
    "wheel": (frozenset(), POINT_KEYS | {"delta", "horizontal", "count", "mods"}),
    "capture": (frozenset(("name",)), frozenset(("what", "method"))),
    "pixel": (frozenset(), POINT_KEYS | {"expect", "differs", "tolerance", "method", "label"}),
    "dpi": (frozenset(("value",)), frozenset()),
    "ime_off": (frozenset(), frozenset()),
    "cancel_mode": (frozenset(), frozenset(("terminal",))),
    "gpu_reset": (frozenset(), frozenset(("terminal",))),
    "clipboard": (frozenset(("text",)), frozenset()),
    "assert_responsive": (frozenset(), frozenset(("timeout",))),
    "wait_terminals": (frozenset(("count",)), frozenset(("timeout", "window"))),
    "wait_popup": (frozenset(), frozenset(("cls", "timeout", "present", "new"))),
    "resize": (frozenset(("width", "height")), frozenset()),
    "close": (frozenset(), frozenset(("timeout",))),
    "file": (frozenset(("path",)), frozenset(("text", "directory", "readonly"))),
    "backdrop": (frozenset(), frozenset(("color", "enabled", "reason"))),
    "simulate_d2d_failure": (frozenset(), frozenset(("window",))),
    "simulate_system_theme": (frozenset(), frozenset(("scheme", "high_contrast"))),
    "restart": (frozenset(), frozenset(("timeout", "env", "wait"))),
    "capture_window": (frozenset(("name",)), frozenset(("cls", "title", "timeout", "method"))),
    "layout": (frozenset(("target",)), frozenset()),
}
SCENARIO_KEYS = frozenset(("id", "title", "config", "harness", "env", "args", "requires", "side_effects", "expect",
                           "backdrop", "backdrop_reason", "wait_window", "step"))
CAPTURE_ACTIONS = frozenset(("capture", "capture_window"))
SCENARIO_ID_RE = re.compile(r"^[WG]\d{2}$")
INPUT_ACTIONS = frozenset(("type", "key", "click", "mouse_down", "mouse_up", "move", "drag", "drag_divider", "wheel"))
CAPTURE_WHAT = ("window", "quick", "popups", "all")


@dataclass
class Step:
    action: str
    params: dict[str, Any]

    def describe(self) -> str:
        shown = ", ".join(f"{key}={value!r}" for key, value in self.params.items())
        return f"{self.action}({shown})"


@dataclass
class Scenario:
    path: Path
    id: str
    title: str
    config: str
    steps: list[Step]
    harness: bool = True
    env: dict[str, str] = field(default_factory=dict)
    args: list[str] = field(default_factory=list)
    requires: list[str] = field(default_factory=list)
    side_effects: list[str] = field(default_factory=list)
    expect: list[str] = field(default_factory=list)
    backdrop: str | None = BACKDROP_DEFAULT  # "#rrggbb", None when the scenario turns the backdrop off
    backdrop_reason: str | None = None
    wait_window: bool = True  # wait for the main window before the first step

    def full_config(self) -> str:
        text = self.config if self.config.endswith("\n") or not self.config else self.config + "\n"
        return text + (HARNESS_CONFIG if self.harness else "")


def load_toml(path: Path) -> dict[str, Any]:
    try:
        import tomllib  # type: ignore[import-not-found]
    except ModuleNotFoundError:  # Python 3.10
        try:
            import tomli as tomllib  # type: ignore[import-not-found,no-redef]
        except ModuleNotFoundError:
            raise UsageError("reading scenarios needs Python 3.11+ (tomllib) or the tomli package") from None
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise UsageError(f"{path}: {exc}") from None


def validate_step(where: str, raw: Mapping[str, Any]) -> Step:
    if not isinstance(raw, Mapping) or "action" not in raw:
        raise UsageError(f"{where}: every step needs an action")
    action = raw["action"]
    if action not in ACTIONS:
        raise UsageError(f"{where}: unknown action {action!r}")
    params = {key: value for key, value in raw.items() if key != "action"}
    required, optional = ACTIONS[action]
    missing = sorted(required - params.keys())
    unknown = sorted(params.keys() - required - optional)
    if missing:
        raise UsageError(f"{where}: {action} needs {', '.join(missing)}")
    if unknown:
        raise UsageError(f"{where}: {action} does not take {', '.join(unknown)}")
    if "keys" in params:
        parse_chord(params["keys"])
    if "mods" in params:
        if not isinstance(params["mods"], list):
            raise UsageError(f"{where}: mods must be a list such as [\"ctrl\"]")
        try:
            modifier_vks(params["mods"])
        except UsageError as exc:
            raise UsageError(f"{where}: {exc}") from None
    for key in ("expect", "differs"):
        if key in params:
            for color in params[key] if isinstance(params[key], list) else [params[key]]:
                parse_color(color)
    if action == "capture" and params.get("what", "window") not in CAPTURE_WHAT:
        raise UsageError(f"{where}: capture what must be one of {', '.join(CAPTURE_WHAT)}")
    if "button" in params and params["button"] not in MOUSE_BUTTONS:
        raise UsageError(f"{where}: unknown button {params['button']!r}")
    for key in ("from", "to", "between"):
        if key in params and not (isinstance(params[key], list) and len(params[key]) == 2):
            raise UsageError(f"{where}: {key} must be a list of two numbers")
    if "pattern" in params:
        try:
            re.compile(params["pattern"])
        except re.error as exc:
            raise UsageError(f"{where}: bad pattern {params['pattern']!r}: {exc}") from None
    if action == "wait_file":
        if not isinstance(params["path"], str):
            raise UsageError(f"{where}: wait_file path must be a string")
        expand_path(params["path"], dict.fromkeys(PATH_PLACEHOLDERS, ""), where)  # only the syntax
    if action == "backdrop":
        enabled = params.get("enabled", True)
        if not isinstance(enabled, bool):
            raise UsageError(f"{where}: backdrop enabled must be true or false")
        if not enabled and not (isinstance(params.get("reason"), str) and params["reason"].strip()):
            raise UsageError(f"{where}: backdrop enabled = false needs a reason")
        if enabled and "reason" in params:
            raise UsageError(f"{where}: a backdrop reason only goes with enabled = false")
        if not enabled and "color" in params:
            raise UsageError(f"{where}: a backdrop that is off has no color")
        if "color" in params:
            parse_color(params["color"])
    if action == "file":
        if not params.keys() & {"text", "directory", "readonly"}:
            raise UsageError(f"{where}: file needs text, directory = true or readonly")
        if "text" in params and "directory" in params:
            raise UsageError(f"{where}: file takes text or directory, not both")
        if "directory" in params and params["directory"] is not True:
            raise UsageError(f"{where}: file directory only takes true")
        if "readonly" in params and not isinstance(params["readonly"], bool):
            raise UsageError(f"{where}: file readonly must be true or false")
        if "text" in params and not isinstance(params["text"], str):
            raise UsageError(f"{where}: file text must be a string")
    if action == "layout":
        try:
            resolve_layout(params["target"], [])  # only the syntax; whether it is loaded is known at run time
        except UsageError as exc:
            raise UsageError(f"{where}: {exc}") from None
    if action == "capture_window":
        if "cls" not in params and "title" not in params:
            raise UsageError(f"{where}: capture_window needs cls or title")
        if params.get("method", "print") not in ("print", "screen"):
            raise UsageError(f"{where}: capture_window method must be print or screen")
        timeout = params.get("timeout", 10)
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 0 < timeout <= 120:
            raise UsageError(f"{where}: capture_window timeout must be a number of seconds in (0, 120]")
        if "title" in params:
            try:
                re.compile(params["title"])
            except (re.error, TypeError) as exc:
                raise UsageError(f"{where}: bad title pattern {params['title']!r}: {exc}") from None
    if action == "restart":
        env = params.get("env", {})
        if not isinstance(env, dict) or not all(isinstance(name, str) and ENV_NAME_RE.match(name)
                                                and isinstance(value, str) for name, value in env.items()):
            raise UsageError(f"{where}: restart env must map variable names to strings")
        isolated = sorted(name for name in env if name.upper() in ISOLATED_VARIABLES)
        if isolated:
            raise UsageError(f"{where}: restart env cannot change the isolated paths: {', '.join(isolated)}")
        if "wait" in params and not isinstance(params["wait"], bool):
            raise UsageError(f"{where}: restart wait must be true or false")
        timeout = params.get("timeout", 10)
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 0 < timeout <= 120:
            raise UsageError(f"{where}: restart timeout must be a number of seconds in (0, 120]")
    if action == "simulate_system_theme":
        try:
            system_theme_wparam(params.get("scheme", "follow"), params.get("high_contrast", "follow"))
        except UsageError as exc:
            raise UsageError(f"{where}: {exc}") from None
    return Step(action, params)


def scenario_backdrop(where: str, data: Mapping[str, Any]) -> tuple[str | None, str | None]:
    """The scenario's backdrop color ("#rrggbb", None when off) and why it is off."""
    value, reason = data.get("backdrop", True), data.get("backdrop_reason")
    if value is True:
        color = BACKDROP_DEFAULT
    elif value is False:
        color = None
    elif isinstance(value, str):
        try:
            color = color_hex(parse_color(value))
        except UsageError as exc:
            raise UsageError(f"{where}: backdrop: {exc}") from None
    else:
        raise UsageError(f"{where}: backdrop must be true, false or a #rrggbb color")
    if color is None and not (isinstance(reason, str) and reason.strip()):
        raise UsageError(f"{where}: backdrop = false needs backdrop_reason (why the screenshots must show the desktop)")
    if color is not None and reason is not None:
        raise UsageError(f"{where}: backdrop_reason only goes with backdrop = false")
    return color, reason


def load_scenario(path: Path) -> Scenario:
    data = load_toml(path)
    unknown = sorted(data.keys() - SCENARIO_KEYS)
    if unknown:
        raise UsageError(f"{path}: unknown keys {', '.join(unknown)}")
    for key in ("id", "title", "config"):
        if not isinstance(data.get(key), str):
            raise UsageError(f"{path}: {key} must be a string")
    if not SCENARIO_ID_RE.match(data["id"]):
        raise UsageError(f"{path}: id {data['id']!r} must look like W01")
    if not path.name.startswith(data["id"] + "-"):
        raise UsageError(f"{path}: the file name must start with {data['id']}-")
    steps = [validate_step(f"{path.name} step {index}", raw) for index, raw in enumerate(data.get("step", []), 1)]
    if not steps:
        raise UsageError(f"{path}: no steps")
    if not any(step.action in CAPTURE_ACTIONS for step in steps):
        raise UsageError(f"{path}: a scenario must capture at least one screenshot")
    if not isinstance(data.get("wait_window", True), bool):
        raise UsageError(f"{path}: wait_window must be true or false")
    for requirement in data.get("requires", []):
        if isinstance(requirement, str) and requirement.startswith("file:"):
            expand_path(requirement[5:], {}, f"{path}: requires {requirement!r}")
    env = data.get("env", {})
    if not isinstance(env, dict) or not all(ENV_NAME_RE.match(name) and isinstance(v, str) for name, v in env.items()):
        raise UsageError(f"{path}: env must map variable names to strings")
    backdrop, backdrop_reason = scenario_backdrop(str(path), data)
    return Scenario(path, data["id"], data["title"], data["config"], steps, bool(data.get("harness", True)), dict(env),
                    list(data.get("args", [])), list(data.get("requires", [])), list(data.get("side_effects", [])),
                    list(data.get("expect", [])), backdrop=backdrop, backdrop_reason=backdrop_reason,
                    wait_window=data.get("wait_window", True))


def scenario_paths(selectors: Sequence[str], directory: Path = SCENARIO_DIR) -> list[Path]:
    """Scenario files for ids (W01), file paths or all of `directory` when nothing is selected."""
    available = sorted(directory.glob("*.toml"))
    if not selectors:
        return available
    paths = []
    for selector in selectors:
        path = Path(selector)
        if path.suffix == ".toml" and path.is_file():
            paths.append(path)
            continue
        matches = [candidate for candidate in available if candidate.name.startswith(selector + "-")]
        if len(matches) != 1:
            raise UsageError(f"no single scenario {selector!r} in {directory}")
        paths.extend(matches)
    return paths


def missing_requirement(requirement: str, wsl_distros: Callable[[], list[str]]) -> str | None:
    """Why a `requires` entry is not met, or None."""
    if requirement.startswith("wsl:"):
        distro = requirement[4:]
        return None if distro in wsl_distros() else f"WSL distro {distro} is not installed"
    if requirement.startswith("file:"):
        return None if Path(expand_path(requirement[5:], {}, "requires")).exists() else f"{requirement[5:]} does not exist"
    if requirement.startswith("windows-build:"):
        wanted = int(requirement.split(":", 1)[1])
        build = sys.getwindowsversion().build if sys.platform == "win32" else 0  # type: ignore[attr-defined]
        return None if build >= wanted else f"Windows build {build} is older than {wanted}"
    return f"unknown requirement {requirement!r}"


def installed_wsl_distros() -> list[str]:
    try:
        result = subprocess.run(["wsl.exe", "-l", "-q"], capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return []
    raw = result.stdout
    text = raw.decode("utf-16-le", "replace") if raw[:2] in (b"\xff\xfe",) or b"\x00" in raw[:8] else raw.decode()
    return [line.strip().lstrip("\ufeff") for line in text.splitlines() if line.strip()]


class ScenarioRun:
    """Runs one scenario's steps against a fresh isolated instance."""

    def __init__(self, scenario: Scenario, exe: Path, out_dir: Path, keep_open: bool = False,
                 allow_load_layouts: bool = False) -> None:
        self.scenario = scenario
        self.exe = exe
        self.out_dir = out_dir
        self.keep_open = keep_open
        self.allow_load_layouts = allow_load_layouts  # VM only: the layout step may load a missing KLID
        self.instance: Instance | None = None
        self.captures: list[str] = []
        self.capture_steps = 0
        self.popups_before_input: set[int] = set()
        self.results: list[dict[str, Any]] = []
        self.saved_clipboard: str | None = None
        self.clipboard_changed = False
        self.startup: dict[str, float] = {}
        self.held_buttons: list[str] = []  # pressed by mouse_down, not yet released by mouse_up
        self.backdrop = (Backdrop(scenario.backdrop, scenario.backdrop_reason) if scenario is not None
                         else Backdrop(None, "no scenario"))
        self.readonly = ReadOnlyPaths()
        self.restarts: list[dict[str, Any]] = []

    # -- addressing -----------------------------------------------------------

    @property
    def gui(self) -> Instance:
        assert self.instance is not None
        return self.instance

    def point(self, params: Mapping[str, Any]) -> tuple[int, int]:
        return self.gui.point(params.get("x"), params.get("y"), params.get("in", "client"), params.get("window", "main"))

    def capture(self, info: WindowInfo, method: str, label: str) -> Image:
        """Every scenario screenshot and pixel read goes through the privacy backdrop."""
        return self.backdrop.capture(self.gui, info, method, label)

    def capture_name(self, name: str, step: int | None = None) -> Path:
        """OUT/NN-name.png, NN numbering the capture steps (the popups of one step share it)."""
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
            raise UsageError(f"capture name {name!r} may only contain letters, digits, '.', '_' and '-'")
        return self.out_dir / f"{step or self.capture_steps + 1:02d}-{name}.png"

    # -- steps --------------------------------------------------------------------

    def do_wait_window(self, p):
        marks = self.gui.wait_window(float(p.get("timeout", 20)), p.get("window", "main"))
        return ", ".join(f"{key} {value:.0f}" for key, value in marks.items())

    def do_activate(self, p):
        self.gui.activate(p.get("window", "main"))
        return "foreground"

    def do_sleep(self, p):
        time.sleep(float(p["seconds"]))
        return f"{p['seconds']}s"

    def do_wait_log(self, p):
        return self.gui.wait_log(p["pattern"], float(p.get("timeout", 10)))

    def do_assert_log(self, p):
        regex = re.compile(p["pattern"])
        lines = [line for line in self.gui.log_text().splitlines() if regex.search(line)]
        if bool(lines) != bool(p.get("present", True)):
            raise GuiError(f"log {'lacks' if not lines else 'has'} {p['pattern']!r}" + (f": {lines[0]}" if lines else ""))
        return lines[0] if lines else "absent"

    def path_values(self) -> dict[str, str]:
        """The wait_file placeholders: this scenario's isolated profile and its instance's ghostty.log."""
        env = (self.instance.env_dir if self.instance is not None else self.out_dir / "env").resolve()
        return {"env": str(env), "log": str(log_path(env))}

    def do_wait_file(self, p):
        """Wait until the whole text of a file (such as one a program in the terminal wrote) matches the pattern."""
        path = Path(expand_path(p["path"], self.path_values(), "wait_file"))
        regex = re.compile(p["pattern"])
        timeout = float(p.get("timeout", 5))
        deadline = time.monotonic() + timeout
        while True:
            try:
                text: str | None = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                text = None
            if text is not None and regex.search(text):
                return f"{path.name}: {text[:200]!r}"
            if time.monotonic() > deadline:
                found = "the file is missing" if text is None else f"it holds {text[:300]!r}"
                raise GuiError(f"{path} does not match {p['pattern']!r} within {timeout:g}s: {found}")
            time.sleep(0.05)

    def window_title(self, kind: str) -> str:
        return self.gui.require_window(kind).title

    def do_wait_title(self, p):
        regex = re.compile(p["pattern"])
        deadline = time.monotonic() + float(p.get("timeout", 10))
        while True:
            title = self.window_title(p.get("window", "main"))
            if regex.search(title):
                return title
            if time.monotonic() > deadline:
                raise GuiError(f"window title {title!r} does not match {p['pattern']!r}")
            time.sleep(0.05)

    def do_assert_title(self, p):
        title = self.window_title(p.get("window", "main"))
        if not re.search(p["pattern"], title):
            raise GuiError(f"window title {title!r} does not match {p['pattern']!r}")
        return title

    def do_type(self, p):
        text = p["text"] * int(p.get("repeat", 1))
        self.gui.type_text(text, float(p.get("delay", 0.003)))
        return f"{len(text)} characters"

    def do_key(self, p):
        self.gui.press(p["keys"], int(p.get("repeat", 1)), float(p.get("delay", 0.05)))
        return p["keys"]

    def do_click(self, p):
        x, y = self.point(p)
        self.gui.mouse(x, y, button=p.get("button", "left"), count=int(p.get("count", 1)), mods=p.get("mods", []))
        return f"({x}, {y})"

    def do_mouse_down(self, p):
        x, y = self.point(p)
        button = p.get("button", "left")
        self.gui.mouse(x, y, button=button, action="down", mods=p.get("mods", []))
        self.held_buttons.append(button)
        return f"({x}, {y})"

    def do_mouse_up(self, p):
        x, y = self.point(p)
        button = p.get("button", "left")
        self.gui.mouse(x, y, button=button, action="up", mods=p.get("mods", []))
        if button in self.held_buttons:
            self.held_buttons.remove(button)
        return f"({x}, {y})"

    def release_held_buttons(self, aborted: bool) -> list[str]:
        """Button-ups for presses a mouse_down step left held (e.g. W12 stopped before its
        mouse_up). Like Instance.drag: no pointer move, no activation, no further down."""
        released = []
        while self.held_buttons:
            button = self.held_buttons.pop()
            _, up, data = MOUSE_BUTTONS[button]
            try:
                self.gui.release_input([win32().mouse_input(up, data=data)], button, aborted)
                released.append(button)
            except Exception as exc:  # noqa: BLE001 - keep closing the instance and recording evidence
                released.append(f"{button}: release failed: {exc}")
        return released

    def do_move(self, p):
        x, y = self.point(p)
        self.gui.mouse(x, y, action="move")
        return f"({x}, {y})"

    def do_drag(self, p):
        anchor, kind = p.get("in", "client"), p.get("window", "main")
        start = self.gui.point(p["from"][0], p["from"][1], anchor, kind)
        end = self.gui.point(p["to"][0], p["to"][1], anchor, kind)
        self.gui.drag(start, end, steps=int(p.get("steps", 12)), button=p.get("button", "left"))
        return f"{start} -> {end}"

    def do_drag_divider(self, p):
        terminals = self.gui.terminals()
        first, second = (terminals[int(index)].rect for index in p["between"])
        orientation, position, (span0, span1) = rect_gap(first, second)
        fraction = float(p["fraction"])
        if orientation == "vertical":
            lo, hi = min(first[0], second[0]), max(first[2], second[2])
            start = (position, (span0 + span1) // 2)
            end = (round(lo + (hi - lo) * fraction), start[1])
        else:
            lo, hi = min(first[1], second[1]), max(first[3], second[3])
            start = ((span0 + span1) // 2, position)
            end = (start[0], round(lo + (hi - lo) * fraction))
        self.gui.drag(start, end, steps=int(p.get("steps", 16)))
        return f"{orientation} divider {start} -> {end}"

    def do_wheel(self, p):
        x, y = self.point(p)
        mods = p.get("mods", [])
        self.gui.wheel(x, y, int(p.get("delta", 120)), bool(p.get("horizontal", False)), int(p.get("count", 1)), mods)
        return f"({x}, {y}) delta {p.get('delta', 120)}" + (f" with {'+'.join(mods)}" if mods else "")

    def do_capture(self, p):
        what, method = p.get("what", "window"), p.get("method", "screen")
        step = self.capture_steps + 1
        path = self.capture_name(p["name"], step)
        saved = []
        if what in ("window", "all"):
            image = self.capture(self.gui.require_window("main"), method, path.name)
            saved.append(image.save_png(path))
        if what == "quick":
            image = self.capture(self.gui.require_window("quick"), method, path.name)
            saved.append(image.save_png(path))
        if what in ("popups", "all"):
            popups = self.gui.popups()
            if not popups and what == "popups":
                raise GuiError("no visible popup to capture")
            for index, info in enumerate(popups, 1):
                cls = re.sub(r"[^A-Za-z0-9._-]", lambda match: f"_{ord(match[0]):x}_", info.cls) or "unknown"
                target = self.capture_name(f"{p['name']}-{cls}-{index}", step)
                image = self.capture(info, method, target.name)
                saved.append(image.save_png(target))
        self.capture_steps = step
        for path in saved:
            self.captures.append(path.name)
        return ", ".join(path.name for path in saved)

    def do_capture_window(self, p):
        info = self.gui.find_window(p.get("cls"), p.get("title"), float(p.get("timeout", 10)))
        step = self.capture_steps + 1
        path = self.capture_name(p["name"], step)
        image = self.capture(info, p.get("method", "print"), path.name)
        image.save_png(path)
        self.capture_steps = step
        self.captures.append(path.name)
        left, top, right, bottom = info.rect
        return f"{path.name}: {info.cls} {right - left}x{bottom - top} {info.title!r}"

    def do_pixel(self, p):
        x, y = self.point(p)
        image = self.capture(self.gui.require_window(p.get("window", "main")), p.get("method", "screen"),
                             f"pixel {p.get('label', 'pixel')}")
        color = image.pixel(x, y)
        tolerance = int(p.get("tolerance", 0))
        detail = f"{p.get('label', 'pixel')} at ({x}, {y}) is {color_hex(color)}"
        if "expect" in p:
            wanted = p["expect"] if isinstance(p["expect"], list) else [p["expect"]]
            if not any(color_close(color, parse_color(item), tolerance) for item in wanted):
                raise GuiError(f"{detail}, expected {' or '.join(wanted)} (tolerance {tolerance})")
        if "differs" in p and color_close(color, parse_color(p["differs"]), tolerance):
            raise GuiError(f"{detail}, expected anything but {p['differs']} (tolerance {tolerance})")
        return detail

    def do_dpi(self, p):
        self.gui.simulate_dpi(int(p["value"]))
        return f"simulated {p['value']} dpi"

    def do_ime_off(self, p):
        return self.gui.ime_off()

    def do_layout(self, p):
        return self.gui.switch_layout(p["target"], allow_load=self.allow_load_layouts)

    def do_simulate_system_theme(self, p):
        scheme, high_contrast = p.get("scheme", "follow"), p.get("high_contrast", "follow")
        wparam = self.gui.simulate_system_theme(scheme, high_contrast)
        return f"simulated apps scheme {scheme}, high contrast {high_contrast} (wparam {wparam:#x})"

    def do_simulate_d2d_failure(self, p):
        state = self.gui.simulate_d2d_failure(p.get("window", "main"))
        return f"Direct2D failure simulated; the title bar falls back to the system caption (caption state {state:#06b})"

    def do_cancel_mode(self, p):
        self.gui.cancel_mode(p.get("terminal"))
        return "WM_CANCELMODE sent"

    def do_gpu_reset(self, p):
        self.gui.gpu_reset(int(p.get("terminal", 0)))
        return "WM_GHOSTTY_SIMULATE_GPU_RESET sent"

    def do_clipboard(self, p):
        w = win32()
        if not self.clipboard_changed:
            self.saved_clipboard = w.clipboard_text()
            self.clipboard_changed = True
        w.set_clipboard_text(p["text"])
        return f"{len(p['text'])} characters"

    def do_assert_responsive(self, p):
        if not self.gui.responsive(float(p.get("timeout", 2))):
            raise GuiError("the main window does not answer messages (hung)")
        return "responsive"

    def do_wait_terminals(self, p):
        wanted = int(p["count"])
        deadline = time.monotonic() + float(p.get("timeout", 10))
        while True:
            window = self.gui.window(p.get("window", "main"))
            count = len(self.gui.terminals(window)) if window else 0
            if count == wanted:
                return f"{count} terminals"
            if time.monotonic() > deadline:
                raise GuiError(f"{count} visible terminals, expected {wanted}")
            time.sleep(0.02)

    def do_wait_popup(self, p):
        cls, present, new = p.get("cls"), bool(p.get("present", True)), bool(p.get("new", False))
        deadline = time.monotonic() + float(p.get("timeout", 10))
        while True:
            popups = [info for info in self.gui.popups() if (cls is None or info.cls.startswith(cls))
                      and not (new and info.hwnd in self.popups_before_input)]
            if bool(popups) == present:
                return ", ".join(info.describe() for info in popups) or "none"
            if time.monotonic() > deadline:
                shown = "; ".join(info.describe() for info in popups)
                raise GuiError(f"popup {cls or 'any'} " + (f"is still shown: {shown}" if popups else "did not appear"))
            time.sleep(0.02)

    def do_resize(self, p):
        elapsed = self.gui.resize(int(p["width"]), int(p["height"]))
        return f"SetWindowPos {elapsed:.1f} ms"

    def do_close(self, p):
        return self.gui.close(float(p.get("timeout", 5)))

    def do_restart(self, p):
        if self.held_buttons:
            raise GuiError(f"release the held mouse buttons ({', '.join(self.held_buttons)}) before a restart")
        old = self.gui
        began = time.monotonic()
        closed = old.close(float(p.get("timeout", 10)), force=False)
        if closed != "closed":
            raise GuiError(f"ghostty pid {old.pid} was not running any more ({closed}); nothing to restart")
        overrides = dict(p.get("env", {}))
        new = launch(self.exe, old.env_dir, config=None, env={**self.scenario.env, **overrides}, args=self.scenario.args)
        record: dict[str, Any] = {"old_pid": old.pid, "old_creation_filetime_100ns": str(old.creation),
                                  "closed": closed, "close_seconds": round(time.monotonic() - began, 3),
                                  "new_pid": new.pid, "new_creation_filetime_100ns": str(new.creation),
                                  "env_overrides": overrides, "same_profile": str(old.env_dir)}
        self.restarts.append(record)
        new.restarts = [*old.restarts, record]
        # The keyboard layout to switch back to and what was loaded stay with the run.
        new.original_layout, new.loaded_layouts = old.original_layout, old.loaded_layouts
        self.instance = new
        if p.get("wait", True):
            record["startup_ms"] = new.wait_window(20)
            new.activate()
            self.backdrop.ensure(new)
        return (f"pid {old.pid} {closed}; restarted as pid {new.pid}"
                + (f" with {', '.join(f'{name}={value}' for name, value in overrides.items())}" if overrides else ""))

    def do_file(self, p):
        root = self.gui.env_dir.resolve()
        path = (root / p["path"]).resolve()
        if root not in path.parents:
            raise UsageError(f"file path {p['path']!r} must stay inside the isolated profile")
        label = str(path.relative_to(root))
        done = []
        try:
            if "text" in p:
                if path in self.readonly.paths:
                    raise GuiError(f"{label} is read-only from an earlier step; set readonly = false first")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(p["text"], encoding="utf-8", newline="\n")
                done.append(f"{label} written")
            if p.get("directory"):
                path.mkdir(parents=True, exist_ok=True)
                done.append(f"{label} is a directory")
        except OSError as exc:  # for example inside a directory an earlier step made read-only
            raise GuiError(f"cannot write {label}: {exc}") from None
        if "readonly" in p:
            done.append(self.readonly.protect(path, label) if p["readonly"] else self.readonly.release(path, label))
        return "; ".join(done)

    def do_backdrop(self, p):
        if not p.get("enabled", True):
            return self.backdrop.set(None, p["reason"])
        detail = self.backdrop.set(color_hex(parse_color(p.get("color", self.backdrop.color or BACKDROP_DEFAULT))), None)
        self.backdrop.ensure(self.gui)
        return detail

    # -- driver -------------------------------------------------------------------

    def run(self) -> dict[str, Any]:
        scenario = self.scenario
        started = time.monotonic()
        report: dict[str, Any] = {"id": scenario.id, "title": scenario.title, "file": scenario.path.name,
                                  "exe": str(self.exe), "started": _datetime.datetime.now().isoformat(timespec="seconds"),
                                  "expect": scenario.expect, "status": "ok"}
        env_dir = self.out_dir / "env"
        prepare_env_dir(env_dir, fresh=True)
        completed = False
        try:
            self.instance = launch(self.exe, env_dir, config=scenario.full_config(), env=scenario.env, args=scenario.args)
            report["pid"] = self.instance.pid
            report["creation_filetime_100ns"] = str(self.instance.creation)
            if scenario.wait_window:
                self.startup = self.gui.wait_window(20)
                report["startup_ms"] = self.startup
                self.gui.activate()
                self.backdrop.ensure(self.gui)
            else:
                report["wait_window"] = False  # the steps begin right after the launch
            for index, step in enumerate(scenario.steps, 1):
                began = time.monotonic()
                if step.action in INPUT_ACTIONS:
                    self.popups_before_input = {info.hwnd for info in self.gui.popups()}
                try:
                    detail = getattr(self, f"do_{step.action}")(step.params)
                except GuiError as exc:
                    self.results.append({"index": index, "step": step.describe(), "ok": False,
                                         "seconds": round(time.monotonic() - began, 3), "detail": str(exc)})
                    raise
                self.results.append({"index": index, "step": step.describe(), "ok": True,
                                     "seconds": round(time.monotonic() - began, 3), "detail": detail})
                print(f"{TAG} {scenario.id} {index}/{len(scenario.steps)} {step.action}: {detail}", flush=True)
            completed = True
        except Blocked as exc:
            report["status"] = "blocked"
            report["reason"] = str(exc)
            print(f"{TAG} {scenario.id} BLOCKED: {exc}", file=sys.stderr, flush=True)
        except GuiError as exc:
            report["status"] = "failed"
            report["reason"] = str(exc)
            print(f"{TAG} {scenario.id} FAILED: {exc}", file=sys.stderr, flush=True)
            self.capture_failure()
        finally:
            try:
                try:
                    if self.instance is not None and self.held_buttons:
                        report["released_buttons"] = self.release_held_buttons(aborted=not completed)
                    layouts: dict[str, Any] = {}
                    if self.instance is not None and self.instance.original_layout is not None:
                        layouts["switched_back"] = self.instance.restore_layout()  # while the instance still runs
                    if self.instance is not None and not self.keep_open:
                        try:
                            report["closed"] = self.instance.close()
                        except GuiError as exc:
                            report["closed"] = f"failed: {exc}"
                    elif self.instance is not None:
                        self.instance.save()
                        report["closed"] = f"kept open; stop with: gx_win_gui.py stop {env_dir}"
                    if self.instance is not None and self.instance.loaded_layouts and not self.keep_open:
                        layouts["unloaded"] = self.instance.unload_layouts()
                    if layouts:
                        report["layouts"] = layouts
                    if self.clipboard_changed:
                        try:
                            win32().set_clipboard_text(self.saved_clipboard or "")
                        except GuiError:
                            pass
                    if self.instance is not None and self.instance.log.is_file():
                        shutil.copyfile(self.instance.log, self.out_dir / "ghostty.log")
                finally:
                    # After the close, so a shutdown that writes into a read-only path still meets it, and
                    # whatever failed above (a second Ctrl+C, a save that raised), no deny entry stays behind.
                    released = self.readonly.release_all(env_dir.resolve())
                    if self.readonly.events or released:
                        report["readonly"] = {"events": self.readonly.events, "released_at_end": released}
            finally:
                # Whatever failed above, the backdrop never outlives the scenario.
                report["backdrop"] = self.backdrop.finish()
        teardown = self.backdrop.teardown_failures()
        if teardown:
            reason = "the privacy backdrop was not destroyed (" + "; ".join(teardown) + ")"
            report["status"] = "failed"
            report["reason"] = f"{report['reason']}; {reason}" if report.get("reason") else reason
            print(f"{TAG} {scenario.id} FAILED: {reason}", file=sys.stderr, flush=True)
        report["seconds"] = round(time.monotonic() - started, 2)
        report["steps"] = self.results
        report["captures"] = self.captures
        if self.restarts:
            report["restarts"] = self.restarts
        return report

    def capture_failure(self) -> None:
        try:
            window = self.gui.window("main") if self.instance else None
            if window is not None:
                path = self.capture_name("failure")
                self.gui.capture_window(window, "print").save_png(path)
                self.captures.append(path.name)
        except Exception:  # noqa: BLE001 - best effort evidence after a failure
            pass


def wallpaper_material(config: str, args: Sequence[str] = ()) -> str | None:
    """The settings that make DWM sample the desktop wallpaper behind the window (a gx-window-material
    other than solid, background-blur): the privacy backdrop does not cover the wallpaper."""
    settings: dict[str, str] = {}
    for line in config.splitlines():
        if match := re.fullmatch(r"\s*(gx-window-material|background-blur)\s*=\s*(.*?)\s*", line):
            settings[match[1]] = match[2]
    for arg in args:
        if match := re.fullmatch(r"--(gx-window-material|background-blur)=(.*)", arg):
            settings[match[1]] = match[2].strip()
    found = []
    if settings.get("gx-window-material", "solid") not in ("", "solid"):
        found.append(f"gx-window-material = {settings['gx-window-material']}")
    if settings.get("background-blur", "false") not in ("", "false", "0"):
        found.append(f"background-blur = {settings['background-blur']}")
    return ", ".join(found) or None


def notes_text(scenario: Scenario, report: Mapping[str, Any]) -> str:
    backdrop = report.get("backdrop") or {"initial": {"color": scenario.backdrop, "reason": scenario.backdrop_reason}}
    initial = backdrop["initial"]
    shown = (f"backdrop: {initial['color']} under the instance's windows (privacy mask)" if initial["color"]
             else f"backdrop: OFF ({initial['reason']}); screen captures may show the desktop behind the window")
    if any(event.get("event") == "set" for event in backdrop.get("events", [])):
        shown += "; a backdrop step changed it, see run.json"
    if material := wallpaper_material(scenario.full_config(), scenario.args):
        shown += (f"\nwallpaper: {material} makes DWM sample the desktop wallpaper behind the window, which the "
                  "backdrop does not cover: the screenshots may show it")
    lines = [f"{scenario.id} {scenario.title}", f"status: {report['status']}" +
             (f" ({report['reason']})" if report.get("reason") else ""), shown, "",
             "Read every screenshot before recording PASS. Expected:"]
    if report.get("status") == "blocked":
        lines[3:3] = ["BLOCKED: a precondition of this machine is missing; record PENDING with the reason, never PASS"]
    if report.get("allow_load_layouts"):
        lines[3:3] = [f"keyboard layouts: --allow-load-layouts ({report['allow_load_layouts']}); layout steps may "
                      "load missing layouts, unloaded at the end"]
    lines += [f"- {item}" for item in scenario.expect] or ["- (no expectations listed)"]
    lines += ["", "screenshots:"] + [f"- {name}" for name in report.get("captures", [])]
    return "\n".join(lines) + "\n"


def run_scenarios(paths: Sequence[Path], *, exe: Path, out: Path, allow_side_effects: bool, retries: int,
                  keep_open: bool, allow_load_layouts: bool = False) -> int:
    if not exe.is_file():
        raise UsageError(f"{exe} does not exist; build it first with: just build")
    scenarios = [load_scenario(path) for path in paths]
    vm = vm_guard("--allow-load-layouts") if allow_load_layouts else None
    out.mkdir(parents=True, exist_ok=True)
    distros: list[str] | None = None

    def wsl_distros() -> list[str]:
        nonlocal distros
        if distros is None:
            distros = installed_wsl_distros()
        return distros

    def fresh(out_dir: Path) -> None:
        if out_dir.exists():
            if not (out_dir / "run.json").is_file() and not (out_dir / "env" / ENV_MARKER).is_file():
                raise UsageError(f"{out_dir} exists and was not written by this tool")
            remove_tree(out_dir)
        out_dir.mkdir(parents=True)

    def write_report(scenario: Scenario, out_dir: Path, report: Mapping[str, Any]) -> None:
        (out_dir / "run.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        (out_dir / "notes.txt").write_text(notes_text(scenario, report), encoding="utf-8")

    summary = []
    failed = blocked = 0
    for scenario in scenarios:
        out_dir = out / f"{scenario.id}"
        reasons = [reason for requirement in scenario.requires
                   if (reason := missing_requirement(requirement, wsl_distros))]
        if not reasons and scenario.side_effects and not allow_side_effects:
            reasons = [f"side effects ({'; '.join(scenario.side_effects)}); pass --allow-side-effects"]
        if reasons:
            summary.append(f"{scenario.id} SKIPPED {scenario.title}: {'; '.join(reasons)}")
            print(f"{TAG} {scenario.id} skipped: {'; '.join(reasons)}", flush=True)
            continue
        blockers = (layout_blockers(scenario.steps, win32().keyboard_layouts(), allow_load_layouts)
                    if any(step.action in ("ime_off", "layout") for step in scenario.steps) else [])
        if blockers:
            fresh(out_dir)
            report = {"id": scenario.id, "title": scenario.title, "file": scenario.path.name, "exe": str(exe),
                      "started": _datetime.datetime.now().isoformat(timespec="seconds"), "status": "blocked",
                      "reason": "; ".join(blockers), "blockers": blockers, "expect": scenario.expect}
            write_report(scenario, out_dir, report)
            summary.append(f"{scenario.id} BLOCKED {scenario.title}: {report['reason']}")
            print(f"{TAG} {scenario.id} BLOCKED before the start: {report['reason']}", file=sys.stderr, flush=True)
            blocked += 1
            continue
        report: dict[str, Any] = {}
        for attempt in range(retries + 1):
            fresh(out_dir)
            print(f"{TAG} {scenario.id} {scenario.title} (attempt {attempt + 1})", flush=True)
            report = ScenarioRun(scenario, exe, out_dir, keep_open, allow_load_layouts).run()
            report["attempt"] = attempt + 1
            if vm is not None:
                report["allow_load_layouts"] = vm
            write_report(scenario, out_dir, report)
            if report["status"] in ("ok", "blocked"):
                break
        status = report["status"].upper()
        blocked += status == "BLOCKED"
        failed += status not in ("OK", "BLOCKED")
        summary.append(f"{scenario.id} {status} {scenario.title}: {len(report.get('captures', []))} screenshots, "
                       f"{report.get('seconds', 0)}s" + (f" ({report.get('reason')})" if report.get("reason") else ""))
    text = "\n".join(summary) + "\n\nScreenshots prove nothing until they are read; see <id>/notes.txt.\n"
    if blocked:
        text += ("BLOCKED scenarios did not run on this machine (a missing precondition such as a keyboard "
                 "layout): record them PENDING with the reason, never PASS.\n")
    (out / "SUMMARY.txt").write_text(text, encoding="utf-8")
    print(text, end="")
    print(f"{TAG} evidence: {out}")
    return 1 if failed else 3 if blocked else 0


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def number(text: str) -> float:
    try:
        return float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {text}") from None


def coordinate(text: str) -> float | str:
    """A DIP offset, or a percentage of the anchor such as 25%."""
    return text if re.fullmatch(r"\d+(?:\.\d+)?%", text) else number(text)


def build_parser() -> argparse.ArgumentParser:
    doc = __doc__ or ""
    parser = argparse.ArgumentParser(prog="gx_win_gui.py", description=doc.splitlines()[0],
                                     epilog=doc.split("\n", 2)[2], formatter_class=argparse.RawDescriptionHelpFormatter,
                                     allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    listing = commands.add_parser("list", allow_abbrev=False, help="list scenarios")
    listing.add_argument("scenarios", nargs="*", metavar="SCENARIO")

    run = commands.add_parser("run", allow_abbrev=False, help="run scenarios")
    run.add_argument("--out", type=Path, help="evidence directory (default .local/evidence/win-gui/<time>)")
    run.add_argument("--exe", type=Path, default=DEFAULT_EXE, help=f"ghostty.exe to test (default {DEFAULT_EXE})")
    run.add_argument("--allow-side-effects", action="store_true", help="also run scenarios with side effects")
    run.add_argument("--retries", type=int, default=0, help="rerun a failed scenario this many times")
    run.add_argument("--keep-open", action="store_true", help="leave the last instance running for inspection")
    run.add_argument("--allow-load-layouts", action="store_true",
                     help="VM only: let layout steps load keyboard layouts that are not loaded (unloaded at the end)")
    run.add_argument("scenarios", nargs="*", metavar="SCENARIO", help="ids such as W01 or .toml files (default all)")

    def session(name: str, help_text: str) -> argparse.ArgumentParser:
        sub = commands.add_parser(name, allow_abbrev=False, help=help_text)
        sub.add_argument("env_dir", type=Path, metavar="ENV_DIR")
        return sub

    start = session("start", "start an isolated instance")
    start.add_argument("--exe", type=Path, default=DEFAULT_EXE)
    start.add_argument("--config", type=Path, help="config.ghostty to copy into the profile")
    start.add_argument("--env", action="append", default=[], metavar="NAME=VALUE")
    start.add_argument("--timeout", type=number, default=20.0)
    start.add_argument("ghostty_args", nargs="*", metavar="GHOSTTY_ARG")
    session("stop", "close the instance")
    session("windows", "list the instance's windows")
    session("activate", "bring the main window to the front")
    capture = session("capture", "save a screenshot")
    capture.add_argument("out", type=Path, metavar="OUT.png")
    capture.add_argument("--popups", action="store_true", help="capture each visible popup instead")
    capture.add_argument("--quick", action="store_true", help="capture the quick terminal")
    capture.add_argument("--method", choices=("screen", "print"), default="screen")

    def backdrop_options(sub: argparse.ArgumentParser) -> None:
        group = sub.add_mutually_exclusive_group()
        group.add_argument("--backdrop", default=BACKDROP_DEFAULT, metavar="#RRGGBB",
                           help=f"privacy backdrop color of a screen capture (default {BACKDROP_DEFAULT})")
        group.add_argument("--no-backdrop", metavar="REASON",
                           help="screen capture without the privacy backdrop, for the given reason (warns)")

    backdrop_options(capture)

    def pointer(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("x", type=coordinate)
        sub.add_argument("y", type=coordinate)
        sub.add_argument("--in", dest="anchor", default="client", help="client, window or terminal:N")

    pixel = session("pixel", "print the color at a point")
    pointer(pixel)
    pixel.add_argument("--method", choices=("screen", "print"), default="screen")
    backdrop_options(pixel)
    typing = session("type", "type text")
    typing.add_argument("text")
    key = session("key", "press a key chord")
    key.add_argument("chord")
    key.add_argument("--repeat", type=int, default=1)
    click = session("click", "click a point")
    pointer(click)
    click.add_argument("--button", choices=sorted(MOUSE_BUTTONS), default="left")
    click.add_argument("--count", type=int, default=1)
    click.add_argument("--mods", default="", help="comma separated modifiers held during the click")
    wheel = session("wheel", "scroll at a point")
    pointer(wheel)
    wheel.add_argument("--delta", type=int, default=120)
    wheel.add_argument("--horizontal", action="store_true")
    wheel.add_argument("--count", type=int, default=1, help="notches to send")
    wheel.add_argument("--mods", default="", help="comma separated modifiers held during the notches")
    drag = session("drag", "drag from one point to another")
    drag.add_argument("x1", type=coordinate)
    drag.add_argument("y1", type=coordinate)
    drag.add_argument("x2", type=coordinate)
    drag.add_argument("y2", type=coordinate)
    drag.add_argument("--in", dest="anchor", default="client")
    drag.add_argument("--steps", type=int, default=12)
    drag.add_argument("--button", choices=sorted(MOUSE_BUTTONS), default="left")
    wait_log = session("wait-log", "wait for a log line")
    wait_log.add_argument("pattern")
    wait_log.add_argument("--timeout", type=number, default=10.0)
    dpi = session("dpi", "simulate a DPI change")
    dpi.add_argument("dpi", type=int)
    d2d = session("d2d-failure", "simulate a Direct2D failure of the title bar")
    d2d.add_argument("--quick", action="store_true", help="the quick terminal's window instead of the main one")
    theme = session("system-theme", "simulate a Windows color scheme or high contrast change")
    theme.add_argument("--scheme", choices=tuple(SYSTEM_THEME_SCHEMES), default="follow")
    theme.add_argument("--high-contrast", choices=tuple(SYSTEM_THEME_HIGH_CONTRAST), default="follow")
    session("ime-off", "switch the window's thread to the US keyboard layout")
    layout = session("layout", "switch the window's thread to a keyboard layout, or list the loaded ones")
    layout.add_argument("target", nargs="?", metavar="HKL|KLID", help="such as 0x08040804 or 00000407")
    layout.add_argument("--allow-load", action="store_true",
                        help="VM only: load a KLID that is not loaded; unloaded again by stop")
    layout.add_argument("--list", action="store_true", help="print the loaded layouts and the current one")
    session("cancel-mode", "send WM_CANCELMODE to the focused terminal")
    return parser


def print_windows(instance: Instance) -> None:
    for info in instance.windows():
        print(info.describe())
        if info.cls == WINDOW_CLASS:
            for terminal in instance.terminals(info) if info.visible else []:
                print("  " + terminal.describe())


def session_capture(instance: Instance, args: argparse.Namespace) -> int:
    """capture and pixel: a screen capture goes through a privacy backdrop of its own, destroyed before
    the command returns, unless --no-backdrop gives the reason (then a warning)."""
    if args.no_backdrop is not None:
        if not args.no_backdrop.strip():
            raise UsageError("--no-backdrop needs the reason why the image may show the desktop")
        backdrop = Backdrop(None, args.no_backdrop)
        if args.method == "screen":
            print(f"{TAG} warning: screen capture without the privacy backdrop ({args.no_backdrop}); the desktop "
                  "and windows behind or over the window may be in the image", file=sys.stderr, flush=True)
    else:
        backdrop = Backdrop(color_hex(parse_color(args.backdrop)))
    teardown: list[str] = []
    try:
        if args.command == "capture":
            if args.popups:
                targets = [(info, args.out.with_name(f"{args.out.stem}-{info.cls}-{index}{args.out.suffix}"))
                           for index, info in enumerate(instance.popups(), 1)]
            else:
                targets = [(instance.require_window("quick" if args.quick else "main"), args.out)]
            for info, path in targets:
                print(backdrop.capture(instance, info, args.method, path.name).save_png(path))
        else:
            x, y = instance.point(args.x, args.y, args.anchor)
            image = backdrop.capture(instance, instance.require_window(), args.method, "pixel")
            print(f"({x}, {y}) {color_hex(image.pixel(x, y))}")
    finally:
        backdrop.finish("command end")
        teardown = backdrop.teardown_failures()
        if teardown:
            print(f"{TAG} error: the privacy backdrop was not destroyed ({'; '.join(teardown)})", file=sys.stderr,
                  flush=True)
        elif backdrop.checks:
            passed = sum(check["status"] == "pass" for check in backdrop.checks)
            print(f"{TAG} privacy backdrop {backdrop.color}: {passed} of {len(backdrop.checks)} checks passed; "
                  "destroyed", file=sys.stderr, flush=True)
    instance.save()
    return 1 if teardown else 0


def session_command(args: argparse.Namespace) -> int:
    env_dir: Path = args.env_dir
    if args.command == "layout" and args.allow_load:
        print(vm_guard("layout --allow-load"))  # before anything else: on the host nothing may be loaded
    if args.command == "start":
        if (env_dir / SESSION_FILE).is_file():
            previous = Instance.load(env_dir)
            if previous.alive():
                raise UsageError(f"{env_dir} already has a running instance (pid {previous.pid}); stop it first")
        prepare_env_dir(env_dir, fresh=False)
        config = args.config.read_text(encoding="utf-8") if args.config else None
        instance = launch(args.exe, env_dir, config=config, env=env_assignments(args.env), args=args.ghostty_args)
        instance.save()
        marks = instance.wait_window(args.timeout)
        print(f"pid={instance.pid} " + " ".join(f"{key}={value:.0f}" for key, value in marks.items())
              + f" log={instance.log}")
        return 0
    instance = Instance.load(env_dir)
    if args.command == "stop":
        if instance.original_layout is not None:
            print(instance.restore_layout())
        print(instance.close())
        for line in instance.unload_layouts():
            print(line)
        instance.original_layout = None
        instance.save()
        return 0
    if not instance.alive():
        raise GuiError(f"the instance in {env_dir} (pid {instance.pid}) is not running")
    if args.command == "windows":
        print_windows(instance)
    elif args.command == "activate":
        instance.activate()
    elif args.command in ("capture", "pixel"):
        return session_capture(instance, args)
    elif args.command == "type":
        instance.type_text(args.text.replace("\\n", "\n"))
    elif args.command == "key":
        instance.press(args.chord, args.repeat)
    elif args.command == "click":
        x, y = instance.point(args.x, args.y, args.anchor)
        mods = [mod for mod in args.mods.split(",") if mod]
        instance.mouse(x, y, button=args.button, count=args.count, mods=mods)
    elif args.command == "wheel":
        x, y = instance.point(args.x, args.y, args.anchor)
        instance.wheel(x, y, args.delta, args.horizontal, max(1, args.count), [mod for mod in args.mods.split(",") if mod])
    elif args.command == "drag":
        start = instance.point(args.x1, args.y1, args.anchor)
        end = instance.point(args.x2, args.y2, args.anchor)
        instance.drag(start, end, steps=args.steps, button=args.button)
    elif args.command == "wait-log":
        print(instance.wait_log(args.pattern, args.timeout))
    elif args.command == "dpi":
        instance.simulate_dpi(args.dpi)
    elif args.command == "d2d-failure":
        print(f"caption state {instance.simulate_d2d_failure('quick' if args.quick else 'main'):#06b}")
    elif args.command == "system-theme":
        print(f"wparam {instance.simulate_system_theme(args.scheme, args.high_contrast):#x}")
    elif args.command == "ime-off":
        print(instance.ime_off())
    elif args.command == "layout":
        if args.list or args.target is None:
            current = win32().keyboard_layout(instance.require_window().hwnd)
            for hkl in win32().keyboard_layouts():
                marks = [mark for mark, on in (("current", hkl & 0xFFFFFFFF == current),
                                               ("loaded by this session", hkl in instance.loaded_layouts)) if on]
                print(hkl_text(hkl) + (f"  ({', '.join(marks)})" if marks else ""))
        else:
            print(instance.switch_layout(args.target, allow_load=args.allow_load))
    elif args.command == "cancel-mode":
        instance.cancel_mode()
    instance.save()
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (OSError, ValueError):
                pass
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    try:
        if args.command == "list":
            for path in scenario_paths(args.scenarios):
                scenario = load_scenario(path)
                extra = [f"requires {', '.join(scenario.requires)}"] if scenario.requires else []
                extra += [f"side effects: {'; '.join(scenario.side_effects)}"] if scenario.side_effects else []
                print(f"{scenario.id}  {scenario.title}" + (f"  ({'; '.join(extra)})" if extra else ""))
            return 0
        if args.command == "run":
            stamp = _datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            return run_scenarios(scenario_paths(args.scenarios), exe=args.exe, out=args.out or EVIDENCE_ROOT / stamp,
                                 allow_side_effects=args.allow_side_effects, retries=max(0, args.retries),
                                 keep_open=args.keep_open, allow_load_layouts=args.allow_load_layouts)
        return session_command(args)
    except UsageError as exc:
        print(f"{TAG} error: {exc}", file=sys.stderr)
        return 2
    except Blocked as exc:
        print(f"{TAG} BLOCKED: {exc}", file=sys.stderr)
        return 3
    except GuiError as exc:
        print(f"{TAG} error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
