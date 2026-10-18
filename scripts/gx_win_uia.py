#!/usr/bin/env python3
"""Bounded MTA UI Automation probe of one explicitly identified owned HWND.

No desktop searches, HWND creation, input, or clipboard access. A parent process
enforces a hard timeout even if the UIA server blocks a COM call. --birth is the
process creation FILETIME (integer); --exe must match the process image exactly.
FocusChanged events are desktop-wide: only the selected process's senders are
recorded; other programs' focus changes are counted, never described, and
GetFocusedElement is only compared with the selected process's own element.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

# A worker serves one probe and exits. Keep native callback storage alive until
# process teardown even if UIA retains an event handler after unsubscription.
_CALLBACK_ANCHORS = []
PATTERNS = {"invoke": (10000, {"invoke": 3}), "selection_item": (10010, {"select": 3, "add": 4, "remove": 5}),
            "value": (10002, {"set": 3}), "toggle": (10015, {"toggle": 3}),
            "expand_collapse": (10005, {"expand": 3, "collapse": 4})}
# IUIAutomationElement methods a plan calls on the element itself, not through a
# control pattern (vtable slot): SetFocus, and a HasKeyboardFocus read only.
ELEMENT_OPERATIONS = {"set_focus": 3, "check_focus": None}
FOCUS_EXPECTATIONS = {"expect_focus": "has_keyboard_focus", "expect_focused_element": "focused_element_same",
                      "expect_focus_event": "focus_event"}


class ProbeFailure(RuntimeError):
    def __init__(self, message, diagnostic):
        super().__init__(message)
        # Freeze before COM cleanup can change stage or release retained refs.
        self.diagnostic = copy.deepcopy(diagnostic)


def automation_clsid(listen_ms):
    # SDK UIAutomationClient.idl: the Win7-compatible class exposes only
    # IUIAutomation; Notification lives on IUIAutomation5/CUIAutomation8.
    return "e22ad333-b25f-460c-83d0-0581107395c9" if listen_ms else "ff48dba4-60ef-4201-aa87-54103eef594e"


def physical_coordinates(user):
    import ctypes
    # A windowless Python client is otherwise DPI-unaware. At 144 DPI its
    # rectangle values are virtualized, unsuitable for guarded SendInput.
    function = user.SetThreadDpiAwarenessContext
    function.argtypes, function.restype = [ctypes.c_void_p], ctypes.c_void_p
    if not function(ctypes.c_void_p(-4)):
        raise RuntimeError("cannot establish per-monitor-v2 UIA client coordinates")


def stale_action_hresult(hr, has_pattern, followup):
    """For an expect_unavailable action: the HRESULT that decides it, or None to
    go on to the action call. A failed GetCurrentPattern decides at once. UIA
    core can answer S_OK with no pattern for a hidden provider's retained element
    (round3-batch-20261018-112356 UIA-02) without surfacing the provider's error;
    then the provider's own answer to a property read (followup) decides."""
    if hr < 0:
        return hr
    if has_pattern:
        return None
    return followup()


def focus_expectations_hold(action, facts):
    """Whether every focus fact the action asks for has its expected value:
    HasKeyboardFocus of its retained element, GetFocusedElement being that
    element, a FocusChanged event from it."""
    return all(facts.get(fact) == action[key] for key, fact in FOCUS_EXPECTATIONS.items() if key in action)


def focus_event_seen(events, start, pid, automation_id):
    """A FocusChanged event from this exact element, after the action began."""
    return any(event.get("pid") == pid and event.get("automation_id") == automation_id for event in events[start:])


def read_plan(path):
    if path is None:
        return []
    if path.stat().st_size > 65536:
        raise ValueError("action plan exceeds 64 KiB")
    rows = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(rows, list) or not 1 <= len(rows) <= 32:
        raise ValueError("action plan must contain 1..32 exact-node actions")
    for row in rows:
        if not isinstance(row, dict) or set(row) - {"automation_id", "name", "pattern", "operation", "value", "after_signal",
                                                    "expect_unavailable", *FOCUS_EXPECTATIONS}:
            raise ValueError("invalid action fields")
        if not isinstance(row.get("automation_id", row.get("name")), str):
            raise ValueError("action requires an exact automation_id or unique name")
        pattern = row.get("pattern")
        operations = ELEMENT_OPERATIONS if pattern == "element" else PATTERNS.get(pattern, (None, {}))[1]
        if row.get("operation") not in operations:
            raise ValueError("unsupported pattern operation")
        if any(not isinstance(row[key], bool) for key in FOCUS_EXPECTATIONS if key in row):
            raise ValueError("focus expectations are booleans")
        if row.get("expect_focus_event") is False:
            raise ValueError("an absent event cannot be awaited; expect_focus_event must be true")
        if row.get("operation") == "check_focus" and "expect_focus" not in row:
            raise ValueError("check_focus requires expect_focus")
        if row.get("expect_unavailable") and any(key in row for key in FOCUS_EXPECTATIONS):
            raise ValueError("a stale-provider action has no focus expectation")
        if pattern == "value" and (not isinstance(row.get("value"), str) or len(row["value"]) > 4096):
            raise ValueError("Value.SetValue requires <=4096 characters")
        if row.get("expect_unavailable") and not row.get("after_signal"):
            raise ValueError("stale-provider assertion requires an external transition signal")
    return rows


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--hwnd", type=lambda value: int(value, 0), required=True)
    result.add_argument("--pid", type=int, required=True)
    result.add_argument("--birth", type=int, required=True)
    result.add_argument("--exe", type=Path, required=True)
    result.add_argument("--framework", default="GhosttyGX")
    result.add_argument("--max-depth", type=int, default=8)
    result.add_argument("--max-nodes", type=int, default=128)
    result.add_argument("--timeout", type=float, default=15)
    result.add_argument("--listen-ms", type=int, default=0)
    result.add_argument("--expect-notification", action="store_true")
    result.add_argument("--sha256", help="required for actions; frozen target executable digest")
    result.add_argument("--action-plan", type=Path, help="bounded JSON list of exact-node pattern calls")
    result.add_argument("--ready-file", type=Path, help="new private handshake file after refs/event registration are retained")
    result.add_argument("--continue-file", type=Path, help="private file created by controller after hide/destroy/submenu transition")
    result.add_argument("--query-interval-ms", type=int, default=0, help="repeat root query during event/transition wait")
    result.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    return result


def validate_args(args) -> None:
    if args.hwnd <= 0 or args.pid <= 0 or args.birth <= 0:
        raise ValueError("HWND, PID and process creation FILETIME must be positive")
    if not 0 <= args.max_depth <= 16 or not 1 <= args.max_nodes <= 512:
        raise ValueError("max-depth must be 0..16; max-nodes must be 1..512")
    if not 1 <= args.timeout <= 60 or not 0 <= args.listen_ms <= 30000:
        raise ValueError("timeout must be 1..60 seconds; listen-ms must be 0..30000")
    if args.listen_ms >= (args.timeout - 0.5) * 1000:
        raise ValueError("event window must fit inside the hard timeout")
    if args.expect_notification and not args.listen_ms:
        raise ValueError("expect-notification requires listen-ms")
    if args.action_plan and not args.sha256:
        raise ValueError("actions require the frozen executable SHA-256")
    if args.sha256 and (len(args.sha256) != 64 or any(char not in "0123456789abcdefABCDEF" for char in args.sha256)):
        raise ValueError("invalid SHA-256")
    if args.continue_file and (not args.ready_file or args.continue_file.exists()):
        raise ValueError("continue-file requires a new ready-file and must not already exist")
    if args.ready_file and args.ready_file.exists():
        raise ValueError("ready-file must be unused")
    if not 0 <= args.query_interval_ms <= 1000 or (args.query_interval_ms and args.query_interval_ms < 10):
        raise ValueError("query-interval-ms must be 0 or 10..1000")
    if any(row.get("after_signal") for row in read_plan(args.action_plan)) and not args.continue_file:
        raise ValueError("after_signal actions require continue-file")


def run_worker(args) -> dict:
    if os.name != "nt":
        raise RuntimeError("Windows UI Automation is unavailable on this host")
    import ctypes as C
    from ctypes import wintypes as W

    HRESULT = C.c_long
    pointer = C.c_void_p
    ole = C.WinDLL("ole32", use_last_error=True)
    aut = C.WinDLL("oleaut32", use_last_error=True)
    kernel = C.WinDLL("kernel32", use_last_error=True)
    user = C.WinDLL("user32", use_last_error=True)
    physical_coordinates(user)
    diagnostic = {"stage": "initialization", "node_id": None, "pattern_id": None,
                  "call": None, "hresult": None, "action_results": []}

    def stage(name, call, **facts):
        diagnostic.update(stage=name, call=call, hresult=None, **facts)

    class GUID(C.Structure):
        _fields_ = [("bytes", C.c_ubyte * 16)]

    def guid(text):
        return GUID((C.c_ubyte * 16).from_buffer_copy(uuid.UUID(text).bytes_le))

    class Value(C.Union):
        _fields_ = [("integer", C.c_longlong), ("real", C.c_double), ("pointer", pointer), ("record", C.c_size_t * 2)]

    class Variant(C.Structure):
        _fields_ = [("tag", C.c_ushort), ("r1", C.c_ushort), ("r2", C.c_ushort), ("r3", C.c_ushort), ("data", Value)]

    def method(obj, index, result, *types):
        table = C.cast(obj, C.POINTER(C.POINTER(pointer))).contents
        return C.WINFUNCTYPE(result, pointer, *types)(table[index])

    def check(hr):
        diagnostic["hresult"] = f"0x{hr & 0xffffffff:08x}"
        if hr < 0:
            raise ProbeFailure(f"COM failure 0x{hr & 0xffffffff:08x}", diagnostic)

    def release(obj):
        if obj:
            method(obj, 2, W.ULONG)(obj)

    ole.CoInitializeEx.argtypes = [pointer, W.DWORD]
    ole.CoInitializeEx.restype = HRESULT
    ole.CoCreateInstance.argtypes = [C.POINTER(GUID), pointer, W.DWORD, C.POINTER(GUID), C.POINTER(pointer)]
    ole.CoCreateInstance.restype = HRESULT
    ole.CoUninitialize.argtypes = []
    aut.VariantClear.argtypes = [C.POINTER(Variant)]
    aut.VariantClear.restype = HRESULT
    aut.SysStringLen.argtypes = [pointer]
    aut.SysStringLen.restype = W.UINT
    aut.SafeArrayGetDim.argtypes, aut.SafeArrayGetDim.restype = [pointer], W.UINT
    aut.SafeArrayGetLBound.argtypes = [pointer, W.UINT, C.POINTER(C.c_long)]
    aut.SafeArrayGetUBound.argtypes = [pointer, W.UINT, C.POINTER(C.c_long)]
    aut.SafeArrayAccessData.argtypes = [pointer, C.POINTER(pointer)]
    aut.SafeArrayUnaccessData.argtypes = [pointer]
    user.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
    user.GetWindowThreadProcessId.restype = W.DWORD
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.OpenProcess.restype = W.HANDLE
    kernel.GetProcessTimes.argtypes = [W.HANDLE, C.POINTER(W.FILETIME), C.POINTER(W.FILETIME), C.POINTER(W.FILETIME), C.POINTER(W.FILETIME)]
    kernel.GetProcessTimes.restype = W.BOOL
    kernel.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]
    kernel.QueryFullProcessImageNameW.restype = W.BOOL
    kernel.CloseHandle.argtypes = [W.HANDLE]

    def verify_identity(*, require_hwnd=True):
        pid = W.DWORD()
        if require_hwnd and (not user.GetWindowThreadProcessId(args.hwnd, C.byref(pid)) or pid.value != args.pid):
            raise RuntimeError("HWND no longer belongs to the expected PID")
        handle = kernel.OpenProcess(0x1000, False, args.pid)
        if not handle:
            raise RuntimeError("Cannot query the explicitly selected process")
        try:
            creation, exit_time, system_time, user_time = (W.FILETIME() for _ in range(4))
            if not kernel.GetProcessTimes(handle, C.byref(creation), C.byref(exit_time), C.byref(system_time), C.byref(user_time)):
                raise RuntimeError("Cannot verify process birth")
            birth = (creation.dwHighDateTime << 32) | creation.dwLowDateTime
            if birth != args.birth:
                raise RuntimeError("Process birth changed; refusing a reused PID")
            path = C.create_unicode_buffer(32768)
            length = W.DWORD(len(path))
            if not kernel.QueryFullProcessImageNameW(handle, 0, path, C.byref(length)):
                raise RuntimeError("Cannot verify process image")
            if os.path.normcase(os.path.abspath(path.value)) != os.path.normcase(os.path.abspath(args.exe)):
                raise RuntimeError("Process image differs from the explicitly selected executable")
            if args.sha256:
                digest = hashlib.sha256()
                with Path(path.value).open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                if digest.hexdigest() != args.sha256.lower():
                    raise RuntimeError("process executable digest changed")
        finally:
            kernel.CloseHandle(handle)

    def raw_property_hresult(element, property_id):
        """GetCurrentPropertyValue's own HRESULT, without raising (stale checks)."""
        value = Variant()
        stage("action.stale_property", "IUIAutomationElement.GetCurrentPropertyValue", property_id=property_id)
        hr = method(element, 10, HRESULT, C.c_int, C.POINTER(Variant))(element, property_id, C.byref(value))
        aut.VariantClear(C.byref(value))
        diagnostic["hresult"] = f"0x{hr & 0xffffffff:08x}"
        return hr

    def property_value(element, property_id, stage_name="enumerate.properties"):
        value = Variant()
        stage(stage_name, "IUIAutomationElement.GetCurrentPropertyValue", property_id=property_id)
        check(method(element, 10, HRESULT, C.c_int, C.POINTER(Variant))(element, property_id, C.byref(value)))
        try:
            if value.tag == 8 and value.data.pointer:
                text = C.wstring_at(value.data.pointer, min(aut.SysStringLen(value.data.pointer), 4096))
                if property_id == 30011:
                    diagnostic["node_id"] = text
                return text
            if value.tag == 3:
                return C.c_int(value.data.integer & 0xffffffff).value
            if value.tag == 11:
                return bool(value.data.integer & 0xffff)
            if value.tag == 0x2005 and value.data.pointer and property_id == 30001:
                array = value.data.pointer
                lower, upper = C.c_long(), C.c_long()
                if aut.SafeArrayGetDim(array) != 1:
                    raise RuntimeError("invalid UIA bounding rectangle dimension")
                check(aut.SafeArrayGetLBound(array, 1, C.byref(lower)))
                check(aut.SafeArrayGetUBound(array, 1, C.byref(upper)))
                if upper.value - lower.value != 3:
                    raise RuntimeError("invalid UIA bounding rectangle length")
                values = pointer()
                check(aut.SafeArrayAccessData(array, C.byref(values)))
                try:
                    return list(C.cast(values, C.POINTER(C.c_double * 4)).contents)
                finally:
                    check(aut.SafeArrayUnaccessData(array))
            return None
        finally:
            aut.VariantClear(C.byref(value))

    def callback_property(element, property_id):
        """An event callback's property read: no shared diagnostic, never raises."""
        value = Variant()
        hr = method(element, 10, HRESULT, C.c_int, C.POINTER(Variant))(element, property_id, C.byref(value))
        try:
            if hr < 0:
                return f"0x{hr & 0xffffffff:08x}"
            if value.tag == 8 and value.data.pointer:
                return C.wstring_at(value.data.pointer, min(aut.SysStringLen(value.data.pointer), 4096))
            if value.tag == 3:
                return C.c_int(value.data.integer & 0xffffffff).value
            if value.tag == 11:
                return bool(value.data.integer & 0xffff)
            return None
        finally:
            aut.VariantClear(C.byref(value))

    class Handler(C.Structure):
        _fields_ = [("vtable", C.POINTER(pointer))]

    verify_identity()
    stage("connect", "CoInitializeEx")
    check(ole.CoInitializeEx(None, 0))  # COINIT_MULTITHREADED; no window on this thread.
    automation, root, walker, automation5 = pointer(), pointer(), pointer(), pointer()
    pending = []
    registered = False
    events = []
    handler = None
    focus_events, focus_counts = [], {"foreign": 0, "callback_errors": 0}
    focus_handler = None
    focus_registered = False
    plan = read_plan(args.action_plan)
    retained = [[] for _ in plan]
    retained_ids = [[] for _ in plan]
    action_results = diagnostic["action_results"]
    owner_thread = kernel.GetCurrentThreadId()
    lifecycle = {"query_thread": owner_thread, "registration_thread": None, "removal_thread": None,
                 "focus_registration_thread": None, "focus_removal_thread": None}
    try:
        clsid = guid(automation_clsid(args.listen_ms))
        iid = guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee")
        stage("connect", "CoCreateInstance")
        check(ole.CoCreateInstance(C.byref(clsid), None, 1, C.byref(iid), C.byref(automation)))
        stage("connect", "IUIAutomation.ElementFromHandle")
        check(method(automation, 6, HRESULT, W.HWND, C.POINTER(pointer))(automation, args.hwnd, C.byref(root)))
        if not root:
            raise RuntimeError("UIA returned no element for the selected HWND")
        if property_value(root, 30002) != args.pid:
            raise RuntimeError("UIA root process does not match the selected process")
        if property_value(root, 30024) != args.framework:
            raise RuntimeError("Selected HWND did not expose the expected custom UIA provider")
        check(method(automation, 16, HRESULT, C.POINTER(pointer))(automation, C.byref(walker)))
        if not walker:
            raise RuntimeError("UIA raw view walker unavailable")
        notifications_supported = False
        notification_interface_hr = None
        if args.listen_ms:
            iid5 = guid("25f700c8-d816-4057-a9dc-3cbdee77e256")
            stage("notification.query_interface", "IUnknown.QueryInterface(IUIAutomation5)")
            hr = method(automation, 0, HRESULT, C.POINTER(GUID), C.POINTER(pointer))(automation, C.byref(iid5), C.byref(automation5))
            notification_interface_hr = f"0x{hr & 0xffffffff:08x}"
            notifications_supported = hr >= 0 and bool(automation5)
            if notifications_supported:
                handler_iid = uuid.UUID("c7cb2637-e6c2-4d0c-85de-4948c02175c7").bytes_le
                unknown_iid = uuid.UUID("00000000-0000-0000-c000-000000000046").bytes_le
                refs_count = [1]
                Query = C.WINFUNCTYPE(HRESULT, pointer, C.POINTER(GUID), C.POINTER(pointer))
                Ref = C.WINFUNCTYPE(W.ULONG, pointer)
                Event = C.WINFUNCTYPE(HRESULT, pointer, pointer, C.c_int, C.c_int, pointer, pointer)

                @Query
                def query(this, requested, out):
                    out[0] = None
                    if bytes(requested.contents.bytes) not in (handler_iid, unknown_iid):
                        return -2147467262
                    refs_count[0] += 1
                    out[0] = this
                    return 0

                @Ref
                def add_ref(_):
                    refs_count[0] += 1
                    return refs_count[0]

                @Ref
                def release_ref(_):
                    refs_count[0] -= 1
                    return refs_count[0]

                @Event
                def notification(_, sender, kind, processing, message, activity):
                    if len(events) < 64:
                        events.append({"kind": kind, "processing": processing,
                                       "message": C.wstring_at(message, min(aut.SysStringLen(message), 4096)) if message else ""})
                    return 0

                table = (pointer * 4)(*[C.cast(fn, pointer) for fn in (query, add_ref, release_ref, notification)])
                handler = Handler(table)
                _CALLBACK_ANCHORS.append((handler, table, query, add_ref, release_ref, notification))
                stage("notification.register", "IUIAutomation5.AddNotificationEventHandler")
                check(method(automation5, 68, HRESULT, pointer, C.c_int, pointer, pointer)(automation5, root, 7, None, C.byref(handler)))
                registered = True
                lifecycle["registration_thread"] = kernel.GetCurrentThreadId()

        if any(action.get("expect_focus_event") for action in plan):
            focus_iid = uuid.UUID("c270f6b5-5c69-4290-9745-7a7f97169468").bytes_le
            unknown_iid = uuid.UUID("00000000-0000-0000-c000-000000000046").bytes_le
            focus_refs = [1]
            FocusQuery = C.WINFUNCTYPE(HRESULT, pointer, C.POINTER(GUID), C.POINTER(pointer))
            FocusRef = C.WINFUNCTYPE(W.ULONG, pointer)
            FocusEvent = C.WINFUNCTYPE(HRESULT, pointer, pointer)

            @FocusQuery
            def focus_query(this, requested, out):
                out[0] = None
                if bytes(requested.contents.bytes) not in (focus_iid, unknown_iid):
                    return -2147467262
                focus_refs[0] += 1
                out[0] = this
                return 0

            @FocusRef
            def focus_add_ref(_):
                focus_refs[0] += 1
                return focus_refs[0]

            @FocusRef
            def focus_release(_):
                focus_refs[0] -= 1
                return focus_refs[0]

            @FocusEvent
            def focus_changed(_, sender):
                # On a UIA MTA thread. Desktop-wide: other programs' senders are
                # only counted. An error never crosses back into UIA.
                try:
                    if not sender or callback_property(sender, 30002) != args.pid:
                        focus_counts["foreign"] += 1
                    elif len(focus_events) < 64:
                        focus_events.append({"pid": args.pid, "automation_id": callback_property(sender, 30011),
                                             "name": callback_property(sender, 30005),
                                             "has_keyboard_focus": callback_property(sender, 30008),
                                             "thread": kernel.GetCurrentThreadId()})
                except Exception:
                    focus_counts["callback_errors"] += 1
                return 0

            focus_table = (pointer * 4)(*[C.cast(fn, pointer) for fn in (focus_query, focus_add_ref, focus_release, focus_changed)])
            focus_handler = Handler(focus_table)
            _CALLBACK_ANCHORS.append((focus_handler, focus_table, focus_query, focus_add_ref, focus_release, focus_changed))
            stage("focus.register", "IUIAutomation.AddFocusChangedEventHandler")
            check(method(automation, 39, HRESULT, pointer, pointer)(automation, None, C.byref(focus_handler)))
            focus_registered = True
            lifecycle["focus_registration_thread"] = kernel.GetCurrentThreadId()

        # Retain a separate root reference because the root is also retained for
        # event registration/removal, which occur on this same MTA thread.
        method(root, 1, W.ULONG)(root)
        pending = [(root, 0)]
        nodes = []
        truncated = False
        while pending and len(nodes) < args.max_nodes:
            element, depth = pending.pop()
            try:
                diagnostic.update(node_id=None, node_index=len(nodes), depth=depth, pattern_id=None)
                if property_value(element, 30002) != args.pid:
                    continue
                nodes.append({"depth": depth, "name": property_value(element, 30005),
                              "automation_id": property_value(element, 30011),
                              "bounds": property_value(element, 30001),
                              "control_type": property_value(element, 30003),
                              "enabled": property_value(element, 30010),
                              "focused": property_value(element, 30008),
                              "focusable": property_value(element, 30009),
                              "value": property_value(element, 30045),
                              "toggle_state": property_value(element, 30086),
                              "expand_state": property_value(element, 30070),
                              "selected": property_value(element, 30079),
                              "patterns": {name: property_value(element, value) for name, value in {
                                  "invoke": 30031, "selection_item": 30036, "selection": 30037,
                                  "value": 30043, "toggle": 30041, "expand_collapse": 30028, "window": 30044}.items()}})
                descriptor = nodes[-1]
                for index, action in enumerate(plan):
                    target = (descriptor["focusable"] if action["pattern"] == "element"
                              else descriptor["patterns"].get(action["pattern"]))
                    if (("automation_id" not in action or action["automation_id"] == descriptor["automation_id"])
                            and ("name" not in action or action["name"] == descriptor["name"])
                            and target is True):
                        method(element, 1, W.ULONG)(element)
                        retained[index].append(element)
                        retained_ids[index].append(descriptor["automation_id"])
                if depth >= args.max_depth:
                    truncated = True
                    continue
                child = pointer()
                stage("enumerate.navigation", "IUIAutomationTreeWalker.GetFirstChildElement")
                check(method(walker, 4, HRESULT, pointer, C.POINTER(pointer))(walker, element, C.byref(child)))
                siblings = []
                try:
                    while child:
                        if len(nodes) + len(pending) + len(siblings) >= args.max_nodes:
                            release(child)
                            child = pointer()
                            truncated = True
                            break
                        siblings.append((child, depth + 1))
                        following = pointer()
                        stage("enumerate.navigation", "IUIAutomationTreeWalker.GetNextSiblingElement")
                        check(method(walker, 6, HRESULT, pointer, C.POINTER(pointer))(walker, child, C.byref(following)))
                        child = following
                    pending.extend(reversed(siblings))
                    siblings.clear()
                finally:
                    for sibling, _ in siblings:
                        release(sibling)
            finally:
                release(element)
        truncated |= bool(pending)
        for element, _ in pending:
            release(element)
        pending.clear()
        for action, elements in zip(plan, retained):
            if len(elements) != 1:
                raise RuntimeError(f"action target is missing or ambiguous ({len(elements)}): {action}")

        def focus_facts(action, element, node_id, events_start):
            facts = {}
            if "expect_focus" in action:
                facts["has_keyboard_focus"] = property_value(element, 30008, "action.focus")
            if "expect_focused_element" in action:
                focused, same = pointer(), W.BOOL()
                stage("action.focus", "IUIAutomation.GetFocusedElement")
                check(method(automation, 8, HRESULT, C.POINTER(pointer))(automation, C.byref(focused)))
                try:
                    if focused:
                        stage("action.focus", "IUIAutomation.CompareElements")
                        check(method(automation, 3, HRESULT, pointer, pointer, C.POINTER(W.BOOL))(automation, focused, element, C.byref(same)))
                    facts["focused_element_same"] = bool(same.value)
                finally:
                    release(focused)
            if "expect_focus_event" in action:
                facts["focus_event"] = focus_event_seen(focus_events, events_start, args.pid, node_id)
            return facts

        def await_focus(action, element, node_id, events_start):
            """The focus moves on the GUI thread after the call: poll, bounded."""
            if not any(key in action for key in FOCUS_EXPECTATIONS):
                return {}
            deadline = time.monotonic() + 3
            polls = 0
            while True:
                facts = focus_facts(action, element, node_id, events_start)
                polls += 1
                if focus_expectations_hold(action, facts) or time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            facts["polls"] = polls
            if not focus_expectations_hold(action, facts):
                diagnostic.update(stage="action.focus", call="focus expectations", focus=facts)
                raise ProbeFailure(f"focus expectations not met within 3 s: {facts}", diagnostic)
            return {"focus": facts}

        def execute_actions(after_signal):
            for action, elements, node_ids in zip(plan, retained, retained_ids):
                if bool(action.get("after_signal")) != after_signal:
                    continue
                verify_identity(require_hwnd=not after_signal)
                events_start = len(focus_events)
                if action["pattern"] == "element":
                    operation = action["operation"]
                    stage("action.invoke", "IUIAutomationElement.SetFocus" if operation == "set_focus" else "HasKeyboardFocus",
                          node_id=node_ids[0], pattern_id=None, action_index=len(action_results), property_id=None)
                    hr = method(elements[0], ELEMENT_OPERATIONS[operation], HRESULT)(elements[0]) if operation == "set_focus" else 0
                    result = {"action": action, "hresult": f"0x{hr & 0xffffffff:08x}", "thread": kernel.GetCurrentThreadId(),
                              "stage": diagnostic["stage"], "call": diagnostic["call"], "node_id": diagnostic["node_id"], "pattern_id": None}
                    diagnostic["hresult"] = result["hresult"]
                    action_results.append(result)
                    if action.get("expect_unavailable"):
                        if hr & 0xffffffff != 0x80040201:
                            raise ProbeFailure(f"stale provider did not return UIA_E_ELEMENTNOTAVAILABLE: {result}", diagnostic)
                        continue
                    check(hr)
                    result.update(await_focus(action, elements[0], node_ids[0], events_start))
                    continue
                pattern_id, operations = PATTERNS[action["pattern"]]
                pattern = pointer()
                stage("action.pattern", "IUIAutomationElement.GetCurrentPattern", node_id=node_ids[0],
                      pattern_id=pattern_id, action_index=len(action_results), property_id=None)
                hr = method(elements[0], 16, HRESULT, C.c_int, C.POINTER(pointer))(elements[0], pattern_id, C.byref(pattern))
                diagnostic["hresult"] = f"0x{hr & 0xffffffff:08x}"
                lookup = {"pattern_hresult": diagnostic["hresult"], "pattern_returned": bool(pattern)}
                try:
                    decided = None
                    if action.get("expect_unavailable"):
                        decided = stale_action_hresult(hr, bool(pattern), lambda: raw_property_hresult(elements[0], 30005))
                    if decided is not None:
                        hr, lookup["decided_by"] = decided, diagnostic["call"]
                    elif hr >= 0 and pattern:
                        operation = operations[action["operation"]]
                        call_name = {"invoke": "Invoke", "select": "Select", "add": "AddToSelection", "remove": "RemoveFromSelection",
                                     "set": "SetValue", "toggle": "Toggle", "expand": "Expand", "collapse": "Collapse"}[action["operation"]]
                        stage("action.invoke", call_name)
                        if action["pattern"] == "value":
                            hr = method(pattern, operation, HRESULT, W.LPCWSTR)(pattern, action["value"])
                        else:
                            hr = method(pattern, operation, HRESULT)(pattern)
                    elif hr >= 0:
                        raise RuntimeError("pattern disappeared without an unavailable HRESULT")
                    result = {"action": action, "hresult": f"0x{hr & 0xffffffff:08x}", "thread": kernel.GetCurrentThreadId(),
                              "stage": diagnostic["stage"], "call": diagnostic["call"], "node_id": diagnostic["node_id"], "pattern_id": pattern_id,
                              **lookup}
                    diagnostic["hresult"] = result["hresult"]
                    action_results.append(result)
                    if action.get("expect_unavailable"):
                        if hr & 0xffffffff != 0x80040201:
                            raise ProbeFailure(f"stale provider did not return UIA_E_ELEMENTNOTAVAILABLE: {result}", diagnostic)
                    else:
                        check(hr)
                        result.update(await_focus(action, elements[0], node_ids[0], events_start))
                finally:
                    release(pattern)

        execute_actions(False)
        if args.ready_file:
            with args.ready_file.open("x", encoding="utf-8") as stream:
                json.dump({"pid": args.pid, "birth": args.birth, "hwnd": args.hwnd,
                           "registered": registered, "focus_registered": focus_registered, "retained_actions": len(plan), "thread": owner_thread,
                           "automation_clsid": automation_clsid(args.listen_ms), "notification_interface_hr": notification_interface_hr}, stream)
        deadline = time.monotonic() + args.listen_ms / 1000
        queries = 0
        unavailable_queries = 0
        next_query = time.monotonic()
        while time.monotonic() < deadline:
            if args.continue_file and args.continue_file.exists():
                break
            if args.query_interval_ms and time.monotonic() >= next_query:
                # A semantic focus/tab update legitimately replaces the root
                # epoch. Stress reacquires through the SAME owned HWND; stale
                # action tests above intentionally keep their original refs.
                current = pointer()
                hr = method(automation, 6, HRESULT, W.HWND, C.POINTER(pointer))(automation, args.hwnd, C.byref(current))
                try:
                    if hr & 0xffffffff == 0x80040201:
                        unavailable_queries += 1
                    else:
                        check(hr)
                        try:
                            if property_value(current, 30002) != args.pid:
                                raise RuntimeError("stress root owner changed")
                            property_value(current, 30005)
                        except RuntimeError as error:
                            if "0x80040201" not in str(error):
                                raise
                            unavailable_queries += 1
                finally:
                    release(current)
                queries += 1
                next_query += args.query_interval_ms / 1000
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        if args.continue_file:
            if not args.continue_file.exists():
                raise RuntimeError("controller transition signal timed out")
            execute_actions(True)
        # Invoke may legitimately destroy its own HWND. The retained native
        # process identity still must match; never follow a replacement window.
        verify_identity(require_hwnd=not bool(args.continue_file or plan))
        if args.expect_notification and not events:
            raise RuntimeError("No notification event received within the bounded event window")
        return {"status": "PASS", "pid": args.pid, "hwnd": args.hwnd, "birth": args.birth,
                "apartment": "MTA", "created_hwnd": False, "nodes": nodes,
                "coordinate_space": "physical-pixels-per-monitor-v2",
                "truncated": truncated, "notification_supported": notifications_supported, "events": events,
                "automation_clsid": automation_clsid(args.listen_ms), "notification_interface_hr": notification_interface_hr,
                "actions": action_results, "queries_during_wait": queries, "unavailable_queries": unavailable_queries,
                "focus_handler_registered": focus_handler is not None, "focus_events": focus_events,
                "foreign_focus_events": focus_counts["foreign"], "focus_callback_errors": focus_counts["callback_errors"],
                "threads": lifecycle}
    except Exception as error:
        if isinstance(error, ProbeFailure):
            raise
        raise ProbeFailure(str(error), diagnostic) from error
    finally:
        original_failure = sys.exc_info()[1]
        cleanup_error = None
        if registered:
            # HRESULT failure must not masquerade as successful event cleanup.
            hr = method(automation5, 69, HRESULT, pointer, pointer)(automation5, root, C.byref(handler))
            lifecycle["removal_thread"] = kernel.GetCurrentThreadId()
            registered = False
            if hr < 0:
                cleanup_error = f"UIA event unsubscription failed: 0x{hr & 0xffffffff:08x}"
        if focus_registered:
            hr = method(automation, 40, HRESULT, pointer)(automation, C.byref(focus_handler))
            lifecycle["focus_removal_thread"] = kernel.GetCurrentThreadId()
            focus_registered = False
            if hr < 0:
                failure = f"UIA focus event unsubscription failed: 0x{hr & 0xffffffff:08x}"
                cleanup_error = f"{cleanup_error}; {failure}" if cleanup_error else failure
        for element, _ in pending:
            release(element)
        for elements in retained:
            for element in elements:
                release(element)
        for element in (walker, root, automation5, automation):
            release(element)
        ole.CoUninitialize()
        if cleanup_error:
            if isinstance(original_failure, ProbeFailure):
                original_failure.diagnostic["cleanup_error"] = cleanup_error
            else:
                raise ProbeFailure(cleanup_error, diagnostic)


def main(argv=None) -> int:
    cli = parser()
    args = cli.parse_args(argv)
    try:
        validate_args(args)
        if args.worker:
            result = run_worker(args)
        else:
            command = [sys.executable, str(Path(__file__).resolve()), *(sys.argv[1:] if argv is None else argv), "--worker"]
            try:
                process = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=args.timeout)
            except subprocess.TimeoutExpired:
                raise RuntimeError("UIA probe exceeded the hard timeout; owned worker terminated") from None
            try:
                result = json.loads(process.stdout)
            except json.JSONDecodeError:
                raise RuntimeError(process.stdout.strip() or process.stderr.strip() or "UIA worker failed") from None
            if process.returncode != 0:
                result.update(status="FAIL", worker_exit_code=process.returncode)
        print(json.dumps(result, ensure_ascii=True))
        return 0 if result.get("status") == "PASS" else 1
    except (OSError, ValueError, RuntimeError) as exc:
        result = {"status": "FAIL", "error": str(exc)}
        if isinstance(exc, ProbeFailure):
            result.update(exc.diagnostic)
        print(json.dumps(result, ensure_ascii=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
