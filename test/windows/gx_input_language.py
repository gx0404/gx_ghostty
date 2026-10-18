"""Keyboard layout switching for owned GUI threads that never loads a layout on the host.

Only input locales GetKeyboardLayoutList already reports for this user are used:
WM_INPUTLANGCHANGEREQUEST goes to the owned window's focus with the exact loaded
HKL, sign-extended to pointer size. LoadKeyboardLayoutW would add a layout to
the user's session list until logoff, so it runs only with allow_load, which the
fixture CLIs expose as the VM-only --allow-load-layouts; whatever it adds is
returned in `added` for unload_layouts. Same semantics as scripts/gx_win_gui.py
layout/ime_off (A2 round 6), without depending on that unmerged version.
"""
from __future__ import annotations

import ctypes
import time

WM_INPUTLANGCHANGEREQUEST = 0x0050
KLF_NOTELLSHELL = 0x00000080
US_LANGID = 0x0409
US_KLID = "00000409"


class LayoutUnavailable(RuntimeError):
    """The wanted layout is not loaded for this user and loading is not allowed."""


def full_hkl(value):
    """A 32-bit HKL value as the pointer-sized, sign-extended handle."""
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value & 0x80000000 else value


def hkl_text(value):
    return f"0x{value & 0xFFFFFFFF:08x}"


def _user32():
    from ctypes import wintypes as W
    user = ctypes.WinDLL("user32", use_last_error=True)
    user.GetKeyboardLayoutList.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    user.GetKeyboardLayoutList.restype = ctypes.c_int
    user.LoadKeyboardLayoutW.argtypes = [W.LPCWSTR, W.UINT]
    user.LoadKeyboardLayoutW.restype = ctypes.c_void_p
    user.UnloadKeyboardLayout.argtypes = [ctypes.c_void_p]
    user.UnloadKeyboardLayout.restype = W.BOOL
    return user


def loaded_layouts(user=None):
    """GetKeyboardLayoutList: the input locales loaded for this user, as 32-bit values."""
    user = user or _user32()
    count = user.GetKeyboardLayoutList(0, None)
    if count <= 0:
        return []
    buffer = (ctypes.c_void_p * count)()
    count = user.GetKeyboardLayoutList(count, buffer)
    return [(buffer[index] or 0) & 0xFFFFFFFF for index in range(max(0, count))]


def pick_us(loaded):
    """The loaded English (US) locale: plain 0x04090409 first, then any 0x....0409 variant."""
    us = [value for value in loaded if value & 0xFFFF == US_LANGID]
    return 0x04090409 if 0x04090409 in us else (us[0] if us else None)


def switch_to(api, hwnd, value, timeout=3.0):
    """Ask hwnd's thread to use the loaded layout `value`; True once GetKeyboardLayout agrees."""
    value &= 0xFFFFFFFF
    if api.keyboard_layout(hwnd) == value:
        return True
    api.PostMessageW(api.focus_window(hwnd), WM_INPUTLANGCHANGEREQUEST, 0, full_hkl(value))
    deadline = time.monotonic() + timeout
    while api.keyboard_layout(hwnd) != value:
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)
    return True


def switch_to_us(api, hwnd, *, added, allow_load=False, user=None, timeout=3.0):
    """Switch hwnd's (owned) thread to a loaded English (US) layout.

    Raises LayoutUnavailable when none is loaded and allow_load is false; the
    host never loads one. With allow_load (VM only) a missing US layout is
    loaded without activation and appended to `added` for unload_layouts."""
    before = api.keyboard_layout(hwnd)
    if before & 0xFFFF == US_LANGID:
        return {"before": hkl_text(before), "method": "already", "layout": hkl_text(before),
                "switched": True, "current": hkl_text(before)}
    user = user or _user32()
    loaded = loaded_layouts(user)
    target, method = pick_us(loaded), "loaded-list"
    if target is None:
        if not allow_load:
            raise LayoutUnavailable(
                "no English (US) layout is loaded for this user (GetKeyboardLayoutList: "
                + (", ".join(hkl_text(value) for value in loaded) or "none")
                + "); the host never loads one: add it to the user's languages, or run in the VM "
                "with --allow-load-layouts")
        handle = user.LoadKeyboardLayoutW(US_KLID, KLF_NOTELLSHELL)
        if not handle:
            raise LayoutUnavailable(f"LoadKeyboardLayoutW({US_KLID}) failed (error {ctypes.get_last_error()})")
        target, method = handle & 0xFFFFFFFF, "loaded-by-fixture (VM --allow-load-layouts)"
        if target not in loaded:
            added.append(handle)
    switched = switch_to(api, hwnd, target, timeout)
    return {"before": hkl_text(before), "method": method, "layout": hkl_text(target),
            "switched": switched, "current": hkl_text(api.keyboard_layout(hwnd))}


def unload_layouts(added, user=None):
    """Unload the layouts allow_load added (after the thread switched back); never raises."""
    results = []
    while added:
        handle = added.pop()
        try:
            ok = bool((user or _user32()).UnloadKeyboardLayout(handle))
            results.append({"layout": hkl_text(handle), "unloaded": ok})
        except Exception as error:  # noqa: BLE001 - cleanup goes on; recorded as evidence
            results.append({"layout": hkl_text(handle), "unloaded": False, "error": str(error)})
    return results
