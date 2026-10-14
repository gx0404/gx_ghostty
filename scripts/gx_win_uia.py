#!/usr/bin/env python3
"""Bounded MTA UI Automation probe of one explicitly identified owned HWND.

No desktop searches, HWND creation, input, or clipboard access. A parent process
enforces a hard timeout even if the UIA server blocks a COM call. --birth is the
process creation FILETIME (integer); --exe must match the process image exactly.
"""
from __future__ import annotations

import argparse
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
        if hr < 0:
            raise RuntimeError(f"COM failure 0x{hr & 0xffffffff:08x}")

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
    user.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
    user.GetWindowThreadProcessId.restype = W.DWORD
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.OpenProcess.restype = W.HANDLE
    kernel.GetProcessTimes.argtypes = [W.HANDLE, C.POINTER(W.FILETIME), C.POINTER(W.FILETIME), C.POINTER(W.FILETIME), C.POINTER(W.FILETIME)]
    kernel.GetProcessTimes.restype = W.BOOL
    kernel.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]
    kernel.QueryFullProcessImageNameW.restype = W.BOOL
    kernel.CloseHandle.argtypes = [W.HANDLE]

    def verify_identity():
        pid = W.DWORD()
        if not user.GetWindowThreadProcessId(args.hwnd, C.byref(pid)) or pid.value != args.pid:
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
        finally:
            kernel.CloseHandle(handle)

    def property_value(element, property_id):
        value = Variant()
        check(method(element, 10, HRESULT, C.c_int, C.POINTER(Variant))(element, property_id, C.byref(value)))
        try:
            if value.tag == 8 and value.data.pointer:
                return C.wstring_at(value.data.pointer, min(aut.SysStringLen(value.data.pointer), 4096))
            if value.tag == 3:
                return C.c_int(value.data.integer & 0xffffffff).value
            if value.tag == 11:
                return bool(value.data.integer & 0xffff)
            return None
        finally:
            aut.VariantClear(C.byref(value))

    verify_identity()
    check(ole.CoInitializeEx(None, 0))  # COINIT_MULTITHREADED; no window on this thread.
    automation, root, walker, automation5 = pointer(), pointer(), pointer(), pointer()
    pending = []
    registered = False
    events = []
    handler = None
    try:
        clsid = guid("ff48dba4-60ef-4201-aa87-54103eef594e")
        iid = guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee")
        check(ole.CoCreateInstance(C.byref(clsid), None, 1, C.byref(iid), C.byref(automation)))
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
        if args.listen_ms:
            iid5 = guid("25f700c8-d816-4057-a9dc-3cbdee77e256")
            hr = method(automation, 0, HRESULT, C.POINTER(GUID), C.POINTER(pointer))(automation, C.byref(iid5), C.byref(automation5))
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

                class Handler(C.Structure):
                    _fields_ = [("vtable", C.POINTER(pointer))]

                handler = Handler(table)
                _CALLBACK_ANCHORS.append((handler, table, query, add_ref, release_ref, notification))
                check(method(automation5, 68, HRESULT, pointer, C.c_int, pointer, pointer)(automation5, root, 7, None, C.byref(handler)))
                registered = True

        # Retain a separate root reference because the root is also retained for
        # event registration/removal, which occur on this same MTA thread.
        method(root, 1, W.ULONG)(root)
        pending = [(root, 0)]
        nodes = []
        truncated = False
        while pending and len(nodes) < args.max_nodes:
            element, depth = pending.pop()
            try:
                if property_value(element, 30002) != args.pid:
                    continue
                nodes.append({"depth": depth, "name": property_value(element, 30005),
                              "automation_id": property_value(element, 30011),
                              "control_type": property_value(element, 30003),
                              "enabled": property_value(element, 30010),
                              "focused": property_value(element, 30008),
                              "patterns": {name: property_value(element, value) for name, value in {
                                  "invoke": 30031, "selection_item": 30036, "selection": 30037,
                                  "value": 30043, "toggle": 30041, "expand_collapse": 30028, "window": 30044}.items()}})
                if depth >= args.max_depth:
                    truncated = True
                    continue
                child = pointer()
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
        deadline = time.monotonic() + args.listen_ms / 1000
        while time.monotonic() < deadline:
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        verify_identity()
        if args.expect_notification and not events:
            raise RuntimeError("No notification event received within the bounded event window")
        return {"status": "PASS", "pid": args.pid, "hwnd": args.hwnd, "birth": args.birth,
                "apartment": "MTA", "created_hwnd": False, "nodes": nodes,
                "truncated": truncated, "notification_supported": notifications_supported, "events": events}
    finally:
        cleanup_error = None
        if registered:
            # HRESULT failure must not masquerade as successful event cleanup.
            hr = method(automation5, 69, HRESULT, pointer, pointer)(automation5, root, C.byref(handler))
            registered = False
            if hr < 0:
                cleanup_error = f"UIA event unsubscription failed: 0x{hr & 0xffffffff:08x}"
        for element, _ in pending:
            release(element)
        for element in (walker, root, automation5, automation):
            release(element)
        ole.CoUninitialize()
        if cleanup_error:
            raise RuntimeError(cleanup_error)


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
            if process.returncode != 0:
                raise RuntimeError(process.stdout.strip() or process.stderr.strip() or "UIA worker failed")
            result = json.loads(process.stdout)
        print(json.dumps(result, ensure_ascii=True))
        return 0 if result.get("status") == "PASS" else 1
    except (OSError, ValueError, RuntimeError) as exc:
        print(json.dumps({"status": "FAIL", "error": str(exc)}, ensure_ascii=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
