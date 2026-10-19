#!/usr/bin/env python3
"""GTK P2/P4 drivers, called by gx_perf gtk (never the standard load schema).

Only gx_wsl's public smoke/scenario interfaces are used. The generated scenario
runs outside the measured checkout; it verifies the normal install receipt itself.
No build, source edits, measurement retries, or Windows input occur here.
"""
from __future__ import annotations

import hashlib
import inspect
import json
from pathlib import Path
import statistics

import gx_perf as perf
import gx_wsl


def idle_ticks(clock, sleep):
    """Sixty absolute deadlines; probe cost never accumulates into sleep time."""
    started = clock()
    for index in range(60):
        sleep(max(0, started + index + 1 - clock()))
        yield index


# AT-SPI is an OS runtime prerequisite, accessed through the standard library.
# An unavailable bridge or ambiguous widget state is an error, never a delay-based success.
def accessibility_snapshot(pid):
    import json
    import ctypes
    lib = ctypes.CDLL("libatspi.so.0")
    glib = ctypes.CDLL("libglib-2.0.so.0")
    obj = ctypes.CDLL("libgobject-2.0.so.0")
    ptr, integer = ctypes.c_void_p, ctypes.c_int
    def bind(name, restype, args):
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = restype, args
        return fn
    desktop = bind("atspi_get_desktop", ptr, [integer])
    children = bind("atspi_accessible_get_child_count", integer, [ptr, ptr])
    child = bind("atspi_accessible_get_child_at_index", ptr, [ptr, integer, ptr])
    process = bind("atspi_accessible_get_process_id", ctypes.c_uint, [ptr, ptr])
    name = bind("atspi_accessible_get_name", ptr, [ptr, ptr])
    role = bind("atspi_accessible_get_role_name", ptr, [ptr, ptr])
    states = bind("atspi_accessible_get_state_set", ptr, [ptr])
    contains = bind("atspi_state_set_contains", integer, [ptr, integer])
    obj.g_object_unref.argtypes = [ptr]
    glib.g_free.argtypes = [ptr]
    glib.g_error_free.argtypes = [ptr]
    if bind("atspi_init", integer, [])() not in (0, 1):
        raise ValueError("AT-SPI initialization failed")
    bind("atspi_set_timeout", None, [integer, integer])(1500, 3000)

    def checked(fn, *args, release=None):
        error = ptr()
        value = fn(*args, ctypes.byref(error))
        if error.value:
            glib.g_error_free(error)
            if value and release:
                release(value)
            raise ValueError("AT-SPI query failed: " + fn.__name__)
        return value

    def count_children(node):
        count = checked(children, node)
        if count < 0:
            raise ValueError("negative AT-SPI child count")
        return count

    def get_child(node, index):
        value = checked(child, node, index, release=obj.g_object_unref)
        if not value:
            raise ValueError("null AT-SPI child")
        return value

    def string(fn, node):
        value = checked(fn, node, release=glib.g_free)
        if not value:
            raise ValueError("null AT-SPI string")
        try:
            return ctypes.string_at(value).decode("utf-8", errors="strict")
        finally:
            glib.g_free(value)

    rows = []
    def read():
        count = 0
        def visit(node, depth, path):
            nonlocal count
            if not node:
                raise ValueError("null AT-SPI node")
            try:
                count += 1
                if depth > 40 or count > 4000:
                    raise ValueError("accessibility tree exceeds bounded traversal")
                state = states(node)
                try:
                    if not state or contains(state, 6):  # ATSPI_STATE_DEFUNCT
                        raise ValueError("unknown AT-SPI node state")
                    showing = bool(contains(state, 25))  # ATSPI_STATE_SHOWING
                finally:
                    if state:
                        obj.g_object_unref(state)
                if showing:
                    # Snapshot-local child indices, not persistent object identities.
                    # Keep hidden ancestors in the path without promoting their names.
                    rows.append({"name": string(name, node), "role": string(role, node),
                                 "path": path, "parent": path[:-1] if depth else None})
                for index in range(count_children(node)):
                    visit(get_child(node, index), depth + 1, [*path, index])
            finally:
                obj.g_object_unref(node)
        top = desktop(0)
        if not top:
            raise ValueError("AT-SPI desktop unavailable")
        try:
            for index in range(count_children(top)):
                app = get_child(top, index)
                try:
                    owner = checked(process, app)
                except BaseException:
                    obj.g_object_unref(app)
                    raise
                if not owner:
                    obj.g_object_unref(app)
                    raise ValueError("unknown AT-SPI application PID")
                if owner == pid:
                    visit(app, 0, [index])
                else:
                    obj.g_object_unref(app)
        finally:
            obj.g_object_unref(top)
        if not rows:
            raise ValueError("no showing AT-SPI nodes for measured PID")
        return rows
    try:
        return read()
    except ValueError as exc:
        raise ValueError(json.dumps({"error": str(exc), "partial_nodes": rows})) from exc


def accessibility_reader(pid):
    def read(timeout):
        import json
        import subprocess
        import sys
        try:
            result = subprocess.run([sys.executable, "-c", ACCESS_PROGRAM, str(pid)],
                                    capture_output=True, text=True, timeout=timeout, check=True)
            rows = json.loads(result.stdout)
            if not isinstance(rows, list) or not rows:
                raise ValueError("empty AT-SPI snapshot")
            return rows
        except (subprocess.SubprocessError, ValueError) as exc:
            raise ValueError(f"AT-SPI snapshot unknown: {exc}; stdout={getattr(exc, 'stdout', None)!r}; "
                             f"stderr={getattr(exc, 'stderr', None)!r}") from exc
    return read


ACCESS_PROGRAM = (inspect.getsource(accessibility_snapshot) +
                  "\nimport json, sys\nprint(json.dumps(accessibility_snapshot(int(sys.argv[1]))))\n")


def x11_ping(window, token):
    """Wait for the client's EWMH reply, not an X server property roundtrip.

    Runs in a disposable process: the parent bounds even blocking Xlib calls.
    The request goes to the client window; only the reply goes to the root.
    """
    import ctypes as c
    import json
    lib = c.CDLL("libX11.so.6")
    ptr, ulong, integer = c.c_void_p, c.c_ulong, c.c_int

    class Data(c.Union):
        _fields_ = [("b", c.c_char * 20), ("s", c.c_short * 10), ("l", c.c_long * 5)]

    class Message(c.Structure):
        _fields_ = [("type", integer), ("serial", ulong), ("send_event", integer),
                    ("display", ptr), ("window", ulong), ("message_type", ulong),
                    ("format", integer), ("data", Data)]

    class Event(c.Union):
        _fields_ = [("client", Message), ("pad", c.c_long * 24)]

    def bind(name, result, args):
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = result, args
        return fn

    open_display = bind("XOpenDisplay", ptr, [c.c_char_p])
    close = bind("XCloseDisplay", integer, [ptr])
    root_window = bind("XDefaultRootWindow", ulong, [ptr])
    atom = bind("XInternAtom", ulong, [ptr, c.c_char_p, integer])
    protocols = bind("XGetWMProtocols", integer, [ptr, ulong, c.POINTER(c.POINTER(ulong)), c.POINTER(integer)])
    free = bind("XFree", integer, [ptr])
    select = bind("XSelectInput", integer, [ptr, ulong, c.c_long])
    send = bind("XSendEvent", integer, [ptr, ulong, integer, c.c_long, c.POINTER(Event)])
    flush = bind("XFlush", integer, [ptr])
    next_event = bind("XNextEvent", integer, [ptr, c.POINTER(Event)])
    display = open_display(None)
    if not display:
        raise ValueError("X11 display unavailable")
    try:
        root = root_window(display)
        wm = atom(display, b"WM_PROTOCOLS", 0)
        ping = atom(display, b"_NET_WM_PING", 0)
        supported, count = c.POINTER(ulong)(), integer()
        try:
            if not protocols(display, window, c.byref(supported), c.byref(count)) or \
                    ping not in [supported[i] for i in range(count.value)]:
                raise ValueError("client does not advertise _NET_WM_PING")
        finally:
            if supported:
                free(supported)
        select(display, root, 1 << 19)  # SubstructureNotifyMask, not WM ownership.
        event = Event()
        event.client.type, event.client.window = 33, window
        event.client.message_type, event.client.format = wm, 32
        event.client.data.l[0:3] = (ping, token, window)
        if not send(display, window, 0, 0, c.byref(event)):
            raise ValueError("X11 ping send failed")
        flush(display)
        while True:
            next_event(display, c.byref(event))
            reply = event.client
            if reply.type == 33 and reply.send_event and reply.window == root and \
                    reply.message_type == wm and reply.format == 32 and \
                    tuple(v & 0xffffffff for v in reply.data.l[:3]) == (ping, token, window):
                print(json.dumps({"protocol": "_NET_WM_PING", "window": str(window), "token": token}))
                return
    finally:
        close(display)


def gui_roundtrip(window):
    import json
    import secrets
    import subprocess
    import sys
    import time
    token = secrets.randbelow(0xffffffff) + 1
    started = time.monotonic_ns()
    try:
        result = subprocess.run([sys.executable, "-c", PING_PROGRAM, str(window), str(token)],
                                capture_output=True, text=True, timeout=1, check=True)
    except subprocess.SubprocessError as exc:
        raise ValueError(f"GUI response failed: window={window}, token={token}, sent_ns={started}, "
                         f"deadline_ns={started + 1_000_000_000}; {exc}; "
                         f"stdout={getattr(exc, 'stdout', None)!r}; stderr={getattr(exc, 'stderr', None)!r}") from exc
    ended = time.monotonic_ns()
    reply = json.loads(result.stdout)
    if reply != {"protocol": "_NET_WM_PING", "window": str(window), "token": token} or \
            not 0 < ended - started <= 1_000_000_000:
        raise ValueError("missing, mismatched or late GUI response")
    return {**reply, "sent_ns": started, "received_ns": ended, "deadline_ns": started + 1_000_000_000}


PING_PROGRAM = inspect.getsource(x11_ping) + "\nimport sys\nx11_ping(int(sys.argv[1]), int(sys.argv[2]))\n"


def await_tree(read, predicate, record, clock, sleep):
    """Unknown snapshots cannot prove absence; preserve every failed attempt."""
    deadline = clock() + 5
    while True:
        try:
            rows = read(max(0.001, deadline - clock()))
        except ValueError as exc:
            record({"complete": False, "error": str(exc)})
        else:
            within_deadline = clock() < deadline
            matched = predicate(rows)
            if within_deadline and matched:
                return rows
            record({"complete": True, "nodes": rows, "matched": matched,
                    "within_deadline": within_deadline})
        if clock() >= deadline:
            raise ValueError("AT-SPI state unknown or did not reach requested state before deadline")
        sleep(0.05)


def capture_session(api, identity, spec):
    """Self-contained Linux scenario; source is copied into the evidence script."""
    import ctypes
    import hashlib
    import json
    import os
    from pathlib import Path
    import subprocess
    import time

    root = api["evidence"]
    log = root / "perf.log"
    report = {"schema": "gx-gtk-action-capture-v1", "case": spec["case"],
              "tabs": spec["tabs"], "status": "ERROR", "intervals": [], "observations": [],
              "actions": [], "identity": {}, "capabilities": spec["capabilities"]}

    def persist():
        (root / "capture.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    def action(*args):
        report["actions"].append({"sequence": len(report["actions"]), "monotonic_ns": time.monotonic_ns(),
                                  "xdotool": list(args)})
        persist()
        return api["xdo"](*args)

    def live():
        pid = api["pid"]()
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] in ("Z", "X"):
            raise ValueError("measured process exited")
        result = {"pid": pid, "birth": int(fields[19])}
        if report["identity"] and result != report["identity"]:
            raise ValueError("process identity changed")
        return result

    def mark():
        live()
        stat = log.stat()
        data = log.read_bytes()
        if not data or not data.endswith(b"\n"):
            raise ValueError("missing/empty/incomplete log at interval boundary")
        return {"offset": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                "device": stat.st_dev, "inode": stat.st_ino, "ns": time.monotonic_ns(), "live": live()}

    def terminal_state(label):
        live()
        windows = api["xdo"]("search", "--onlyvisible", "--pid", api["pid"]()).splitlines()
        if windows != [str(api["window"]())]:
            raise ValueError("expected exactly one visible owned main window")
        if api["xdo"]("getwindowfocus") != str(api["window"]()):
            raise ValueError("main window lost focus")
        rows = api["processes"](label)
        shells = [r for r in rows if r["exe"].endswith("/bash") and r["fd0"].startswith("/dev/pts/")]
        if len(shells) != spec["tabs"] or len({r["fd0"] for r in shells}) != spec["tabs"]:
            raise ValueError("terminal PTY/shell population differs from requested tabs")
        response = gui_roundtrip(api["window"]()) if spec["case"] == "p2" else None
        state = {"response": response, "live": live(), "windows": windows, "shells": shells, "ns": time.monotonic_ns()}
        report["observations"].append(state)
        persist()
        return state

    def widget_state(rows, kind):
        if kind == "settings":
            return any(r["role"] == "dialog" and r["name"] == "Settings" for r in rows)
        # GX menu is a GTK popover; GTK versions differ in its accessible role.
        names = {r["name"].replace("_", "").rstrip(".…") for r in rows}
        return "New Tab" in names and "Quit" in names and "Keyboard Shortcuts" in names

    def await_widget(kind, opened):
        def unknown(attempt):
            # Rejected complete trees are diagnostics, never successful transitions.
            target = report.setdefault("widget_attempts", []) if attempt["complete"] else report["observations"]
            target.append({**attempt, "widget": kind, "requested_opened": opened,
                           "ns": time.monotonic_ns(), "live": live()})
            persist()
        live()
        rows = await_tree(read_widgets, lambda rows: widget_state(rows, kind) == opened,
                          unknown, time.monotonic, time.sleep)
        report["observations"].append({"widget": kind, "opened": opened, "complete": True,
                                        "ns": time.monotonic_ns(), "nodes": rows, "live": live()})
        persist()

    persist()
    try:
        report["identity"] = live()
        receipt_path = identity["BUILD_RECEIPT"]
        if (receipt_path.parent / "build.lock").exists():
            raise ValueError("build in progress")
        receipt_raw = receipt_path.read_bytes()
        receipt = json.loads(receipt_raw)
        source = identity["source_identity"]()
        exe_path = str(Path("zig-out/bin/ghostty").resolve())
        actual = identity["image_info"](f"/proc/{api['pid']()}/exe", True)
        executable = {"path": exe_path, **actual}
        if identity["image_info"](exe_path, True) != actual:
            raise ValueError("running image differs from normal install")
        version = subprocess.run([f"/proc/{api['pid']()}/exe", "+version"], capture_output=True,
                                 text=True, timeout=30, check=False)
        identity["validate_receipt"](receipt, source, executable, version.stdout, version.returncode)
        if receipt.get("perf_eligible") is not True or os.environ.get("GHOSTTY_GX_PERF") != "1" or \
                os.environ.get("GHOSTTY_LOG") != "stderr":
            raise ValueError("receipt not perf eligible or instrumentation disabled")
        capabilities = spec["capabilities"]
        if capabilities and (capabilities.get("exe_sha256") != actual["sha256"] or
                             capabilities.get("source") != source):
            raise ValueError("capability declaration does not bind actual source and executable")
        report.update(source=source, executable=executable, version=version.stdout,
                      receipt_sha256=hashlib.sha256(receipt_raw).hexdigest(), perf_enabled=True,
                      effective_env={key: os.environ.get(key) for key in
                                     ("GHOSTTY_GX_PERF", "GHOSTTY_LOG", "GDK_BACKEND", "DISPLAY", "XDG_CONFIG_HOME",
                                      "XDG_STATE_HOME", "GSK_RENDERER", "GSK_GPU_DISABLE", "LIBGL_ALWAYS_SOFTWARE",
                                      "NO_AT_BRIDGE", "GTK_A11Y")})
        (root / "receipt.json").write_bytes(receipt_raw)
        (root / "version.txt").write_text(version.stdout + version.stderr, encoding="utf-8")
        action("windowfocus", "--sync", api["window"]())
        for _ in range(spec["tabs"] - 1):
            action("key", "--clearmodifiers", "ctrl+shift+t")
            time.sleep(0.4)
        time.sleep(3)
        state = terminal_state("entry")
        api["capture"]("entry")
        if spec["case"] == "p2":
            interval = {"name": "idle", "before": mark(), "states": [state]}
            report["intervals"].append(interval)
            persist()
            for index in idle_ticks(time.monotonic, time.sleep):
                observed = terminal_state(f"idle-{index:03d}")
                if observed["shells"] != state["shells"]:
                    raise ValueError("terminal identity changed while idle")
                interval["states"].append(observed)
            interval["after"] = mark()
            interval["end_state"] = terminal_state("idle-end-response")
            api["capture"]("idle-end")
        else:
            read_widgets = accessibility_reader(api["pid"]())
            kinds = ["menu", "settings"] if spec["run"] % 2 else ["settings", "menu"]
            for kind in kinds:
                await_widget(kind, False)
                for index in range(4):
                    interval = {"name": kind, "open": index, "phase": "warmup" if index == 0 else "hot",
                                "before": mark()}
                    report["intervals"].append(interval)
                    persist()
                    action("key", "--clearmodifiers", "ctrl+shift+m" if kind == "menu" else "ctrl+comma")
                    await_widget(kind, True)
                    time.sleep(0.25)
                    api["capture"](f"{kind}-{index}-open")
                    interval["opened_at"] = mark()
                    action("key", "--clearmodifiers", "Escape")
                    await_widget(kind, False)
                    time.sleep(0.25)
                    api["capture"](f"{kind}-{index}-closed")
                    interval["after"] = mark()
                    persist()
        report["source_end"] = identity["source_identity"]()
        if receipt_path.read_bytes() != receipt_raw or (receipt_path.parent / "build.lock").exists():
            raise ValueError("receipt changed or build started during capture")
        if identity["image_info"](exe_path, True) != actual or identity["image_info"](f"/proc/{api['pid']()}/exe", True) != actual:
            raise ValueError("image changed during capture")
        identity["validate_receipt"](receipt, report["source_end"], executable, version.stdout, version.returncode)
        live()
        report["status"] = "CAPTURED"
    except BaseException as exc:
        report["error"] = str(exc)
        raise
    finally:
        persist()


def scenario(spec: dict) -> str:
    receipt_program = gx_wsl.RECEIPT_PROGRAM.split("\ndef build_main(", 1)[0]
    functions = (idle_ticks, accessibility_reader, gui_roundtrip, await_tree, capture_session)
    return ("# gx-scenario-python-v1\nPING_PROGRAM = " + repr(PING_PROGRAM) +
            "\nACCESS_PROGRAM = " + repr(ACCESS_PROGRAM) + "\n" +
            "\n".join(inspect.getsource(fn) for fn in functions) +
            "\n_identity = {}\nexec(" + repr(receipt_program) + ", _identity)\n" +
            "capture_session(globals(), _identity, " + repr(spec) + ")\n")



def interval_bytes(log: bytes, interval: dict) -> bytes:
    before, after = interval["before"], interval["after"]
    if before["live"] != after["live"] or (before["device"], before["inode"]) != (after["device"], after["inode"]):
        raise perf.PerfError("log/process identity changed across interval")
    if not 0 < before["offset"] <= after["offset"] <= len(log) or after["ns"] <= before["ns"]:
        raise perf.PerfError("invalid interval offsets/time or lost log")
    for endpoint in (before, after):
        prefix = log[:endpoint["offset"]]
        if not prefix.endswith(b"\n") or hashlib.sha256(prefix).hexdigest() != endpoint["sha256"]:
            raise perf.PerfError("log prefix changed or incomplete")
    return log[before["offset"]:after["offset"]]


def metric(raw: bytes, name: str, unit: str, capabilities: dict, channel_verified=False):
    samples = perf.Samples()
    for line in raw.decode("utf-8", errors="strict").splitlines():
        match = perf.GX_PERF_RE.search(line) or perf.GX_COUNT_RE.search(line)
        if match and match["name"] == name:
            samples.add(name, float(match["value"]), match.groupdict().get("unit"))
        elif "(gx_perf):" in line and name in line:
            raise perf.PerfError(f"malformed {name} record")
    if name in samples.values:
        if samples.units[name] != unit or any(v < 0 or (unit == "" and not v.is_integer()) for v in samples.values[name]):
            raise perf.PerfError(f"invalid {name} unit/value")
        return samples.values[name]
    if channel_verified and capabilities.get("metrics", {}).get(name) == unit:
        return []  # Bound declaration proves the counter exists; timing still needs a sample.
    return None


def log_channel(raw: bytes) -> bool:
    return any(perf.GX_PERF_RE.search(line) or perf.GX_COUNT_RE.search(line)
               for line in raw.decode("utf-8", errors="strict").splitlines())


def reduce_capture(target: Path, spec: dict) -> dict:
    capture = perf.read_json(target / "capture.json")
    meta = perf.read_json(target / "perf-meta.json")
    if meta.get("valid") is not True or meta.get("exit") != 0 or capture.get("status") != "CAPTURED":
        raise perf.PerfError("failed or incomplete smoke/capture; originals retained")
    if capture.get("schema") != "gx-gtk-action-capture-v1" or any(capture.get(k) != spec[k] for k in ("case", "tabs", "capabilities")):
        raise perf.PerfError("capture does not match planned case")
    for filename in ("capture.json", "receipt.json", "perf.log", "version.txt"):
        if hashlib.sha256((target / filename).read_bytes()).hexdigest() != meta.get("artifact_sha256", {}).get(filename):
            raise perf.PerfError("missing or changed raw artifact: " + filename)
    identity = {}
    exec(gx_wsl.RECEIPT_PROGRAM.split("\ndef build_main(", 1)[0], identity)
    receipt_bytes = (target / "receipt.json").read_bytes()
    receipt = json.loads(receipt_bytes)
    if hashlib.sha256(receipt_bytes).hexdigest() != capture["receipt_sha256"] or not capture.get("perf_enabled"):
        raise perf.PerfError("receipt hash or perf enable evidence missing")
    if receipt.get("perf_eligible") is not True:
        raise perf.PerfError("receipt is not eligible")
    identity["validate_receipt"](receipt, capture["source"], capture["executable"], capture["version"], 0)
    if capture["source_end"] != capture["source"] or meta.get("identity", {}).get("sha256") != capture["executable"]["sha256"]:
        raise perf.PerfError("source/image identity conflict")
    env = capture["effective_env"]
    if env.get("GHOSTTY_GX_PERF") != "1" or env.get("GHOSTTY_LOG") != "stderr" or env.get("GDK_BACKEND") != "x11" or not all(
            env.get(key) for key in ("DISPLAY", "XDG_CONFIG_HOME", "XDG_STATE_HOME")):
        raise perf.PerfError("missing isolated X11/perf environment evidence")
    capabilities = spec["capabilities"]
    if capabilities and (capabilities.get("source") != capture["source"] or capabilities.get("exe_sha256") != capture["executable"]["sha256"]):
        raise perf.PerfError("unbound capability declaration")
    log = (target / "perf.log").read_bytes()
    intervals = capture["intervals"]
    values = {}
    if spec["case"] == "p2":
        if len(intervals) != 1 or intervals[0]["name"] != "idle":
            raise perf.PerfError("expected one idle interval")
        item = intervals[0]
        raw = interval_bytes(log, item)
        duration = (item["after"]["ns"] - item["before"]["ns"]) / 1e9
        if not 60 <= duration <= 62 or len(item["states"]) < 60:
            raise perf.PerfError("incomplete 60 s idle sampling window")
        states = item["states"]
        end_state = item.get("end_state")
        if not end_state:
            raise perf.PerfError("missing end GUI response")
        for state in [*states, end_state]:
            response = state.get("response") or {}
            sent, received = response.get("sent_ns", 0), response.get("received_ns", 0)
            if response.get("protocol") != "_NET_WM_PING" or \
                    response.get("window") not in state.get("windows", []) or \
                    not isinstance(response.get("token"), int) or not 0 < response["token"] <= 0xffffffff or \
                    not 0 < sent < received <= response.get("deadline_ns", 0) == sent + 1_000_000_000 or \
                    not received <= state["ns"] <= received + 1_000_000_000:
                raise perf.PerfError("missing, invalid or late GUI response")
        if end_state["response"]["sent_ns"] < item["after"]["ns"] or \
                end_state["ns"] - item["after"]["ns"] > 2_000_000_000 or \
                any(end_state[k] != states[0][k] for k in ("live", "windows", "shells")):
            raise perf.PerfError("invalid end GUI response/state")
        for index, state in enumerate(states):
            shells = state.get("shells", [])
            if state.get("live") != item["before"]["live"] or len(state.get("windows", [])) != 1 or \
                    len(shells) != spec["tabs"] or len({r["fd0"] for r in shells}) != spec["tabs"] or \
                    any(not r["exe"].endswith("/bash") or not r["fd0"].startswith("/dev/pts/") for r in shells) or \
                    shells != states[0]["shells"] or state["windows"] != states[0]["windows"]:
                raise perf.PerfError("idle process/window/terminal state incomplete or changed")
            if index and state["response"]["sent_ns"] <= states[index - 1]["ns"]:
                raise perf.PerfError("reused GUI response")
            if index and not 0 < state["ns"] - states[index - 1]["ns"] <= 2_000_000_000:
                raise perf.PerfError("idle state observation gap exceeds two seconds")
        if states[0]["ns"] > item["before"]["ns"] or states[-1]["ns"] < item["after"]["ns"] - 2_000_000_000:
            raise perf.PerfError("idle states do not bracket the interval")
        counts = metric(raw, "proc.snapshot", "", capabilities, log_channel(log[:item["before"]["offset"]]))
        values["proc.snapshot"] = None if counts is None else sum(counts)
    else:
        kinds = ["menu", "settings"] if spec["run"] % 2 else ["settings", "menu"]
        expected = [(kind, index, "warmup" if index == 0 else "hot") for kind in kinds for index in range(4)]
        if [(i["name"], i["open"], i["phase"]) for i in intervals] != expected:
            raise perf.PerfError("expected ordered one warmup + three hot opens per widget")
        for item in intervals:
            observed = [o for o in capture["observations"] if o.get("widget") == item["name"] and
                        item["before"]["ns"] <= o["ns"] <= item["after"]["ns"]]
            successful = [o for o in observed if o.get("complete") is True]
            if any(o.get("complete") is not True and (o.get("opened") is not None or not o.get("error"))
                   for o in observed):
                raise perf.PerfError("partial widget state observations cannot prove closure")
            if [o["opened"] for o in successful] != [True, False] or any(
                    o.get("live") != item["before"]["live"] or not o.get("nodes") for o in successful):
                raise perf.PerfError("open/close widget state observations missing")
        for kind in kinds:
            hot, scans = [], []
            for item in [i for i in intervals if i["name"] == kind]:
                raw = interval_bytes(log, item)
                channel = log_channel(log[:item["after"]["offset"]])
                timing = metric(raw, kind + ".open.total", "ms", capabilities, channel)
                if timing is not None and len(timing) != 1:
                    raise perf.PerfError("open requires exactly one timing sample")
                scan = metric(raw, "profiles.path_scan", "", capabilities, channel)
                item["parsed"] = {"open_ms": None if timing is None else timing[0],
                                  "path_scan": None if scan is None else sum(scan)}
                if item["phase"] == "hot":
                    hot.append(item["parsed"]["open_ms"])
                    scans.append(item["parsed"]["path_scan"])
            values[kind + ".open.total"] = None if None in hot else statistics.median(hot)
            values[kind + ".profiles.path_scan"] = None if None in scans else sum(scans)
    return {"values": values, "source": capture["source"], "exe_sha256": capture["executable"]["sha256"],
            "intervals": intervals, "raw_sha256": hashlib.sha256(log).hexdigest(),
            "effective_env": {k: v for k, v in env.items() if k not in ("DISPLAY", "XDG_CONFIG_HOME", "XDG_STATE_HOME")},
            "units": {name: "ms" if name.endswith("open.total") else "" for name in values}}


def planned(labels, runs, case):
    return [{"run": run, "label": label, "tabs": tabs,
             "path": f"{label}/run-{run:02d}/tabs-{tabs}"}
            for run, label in perf.alternate(labels, runs)
            for tabs in (([1, 11] if run % 2 else [11, 1]) if case == "p2" else [1])]


def run(args):
    # gx_perf may be __main__ in the caller. Do not leak the second imported
    # module's distinct PerfError class past the CLI's error boundary.
    try:
        return run_cases(args)
    except (perf.PerfError, gx_wsl.GxWslError) as exc:
        raise ValueError(str(exc)) from exc


def run_cases(args):
    labels = perf.labels_for(len(args.clone), args.label)
    if args.case not in ("p2", "p4") or not 1 <= len(args.clone) <= 2 or args.runs != 10:
        raise perf.PerfError("GTK P2/P4 require one/two clones and exactly 10 runs")
    environments = perf.label_environments(labels, args.env, args.label_env, gx_wsl.env_assignments)
    declarations = {label: {} for label in labels}
    for value in args.capabilities:
        label, separator, path = value.partition(":")
        if not separator or label not in declarations or declarations[label]:
            raise perf.PerfError("capabilities require unique LABEL:JSON_FILE")
        data = perf.read_json(Path(path))
        if not isinstance(data.get("metrics"), dict) or any(v not in ("", "ms") for v in data["metrics"].values()):
            raise perf.PerfError("capability metrics must declare units ms or empty string")
        declarations[label] = data
    for env in environments.values():
        for key, value in {"GHOSTTY_GX_PERF": "1", "GHOSTTY_LOG": "stderr",
                           "NO_AT_BRIDGE": "0", "GTK_A11Y": "atspi"}.items():
            if key in env and env[key] != value:
                raise perf.PerfError(f"{key} must be {value}")
            env[key] = value
    out = Path(args.out).resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        raise perf.PerfError("output must be new/empty; originals are never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    batch = {"schema": "gx-gtk-actions-v1", "case": args.case, "labels": labels, "planned_runs": 10,
             "order": "AB/BA; P2 tabs 1/11 then 11/1; P4 menu/settings then settings/menu",
             "runs": planned(labels, 10, args.case), "environment": environments,
             "visual_review": "PENDING (root)", "errors": []}
    for item in batch["runs"]:
        item["status"] = "pending"
    perf.write_json(out / "plan.json", batch)
    for item in batch["runs"]:
        target = out / item["path"]
        target.mkdir(parents=True)
        spec = {"case": args.case, "run": item["run"], "tabs": item["tabs"],
                "capabilities": declarations[item["label"]]}
        script, config = target / "driver.py", target / "config.ghostty"
        script.write_text(scenario(spec), encoding="utf-8", newline="\n")
        config.write_text("command = direct:/bin/bash --noprofile --norc\nlanguage = en\n"
                          "keybind = ctrl+shift+m=gx:main_menu\nkeybind = ctrl+comma=open_config\n"
                          "gx-open-config-ui = settings\n", encoding="utf-8", newline="\n")
        argv = ["--clone", args.clone[labels.index(item["label"])], "smoke", "--out", str(target),
                "--name", "perf", "--config", str(config), "--xdotool", str(script), "--lang", "en"]
        if args.distro:
            argv[:0] = ["--distro", args.distro]
        for key, value in environments[item["label"]].items():
            argv += ["--env", key + "=" + value]
        item["argv"] = argv
        perf.write_json(out / "plan.json", batch)
        try:
            item["exit"] = gx_wsl.main(argv)
            if item["exit"] != 0:
                raise perf.PerfError("smoke failed; no retry")
            item["measurement"] = reduce_capture(target, spec)
            item["status"] = "captured"
        except (OSError, ValueError, KeyError, perf.PerfError, gx_wsl.GxWslError) as exc:
            item["status"], item["error"] = "ERROR", str(exc)
            batch["errors"].append(f"{item['path']}: {exc}")
        perf.write_json(out / "plan.json", batch)
        if batch["errors"]:
            break  # Failed and unattempted entries stay in the canonical plan.
    return finish(out, batch, args.json)


def finish(out, batch, json_path=None):
    summaries, gates = {}, {}
    expected_plan = planned(batch["labels"], 10, batch["case"])
    if [{k: row[k] for k in ("run", "label", "tabs", "path")} for row in batch["runs"]] != expected_plan:
        batch["errors"].append("canonical AB/BA plan changed")
    for label in batch["labels"]:
        rows = [r for r in batch["runs"] if r["label"] == label and r["status"] == "captured"]
        identities = {(json.dumps(r["measurement"]["source"], sort_keys=True), r["measurement"]["exe_sha256"],
                       json.dumps(r["measurement"]["effective_env"], sort_keys=True)) for r in rows}
        if len(identities) > 1:
            batch["errors"].append(label + ": identity changed between runs")
        samples = {}
        verdicts = []
        for row in rows:
            required = {"proc.snapshot"} if batch["case"] == "p2" else {
                "menu.open.total", "menu.profiles.path_scan", "settings.open.total", "settings.profiles.path_scan"}
            if set(row["measurement"]["values"]) != required:
                batch["errors"].append(row["path"] + ": incomplete metric set")
            for name, value in row["measurement"]["values"].items():
                key = f"tabs-{row['tabs']}.{name}"
                samples.setdefault(key, []).append(value)
                verdicts.append(None if value is None else value <= (6.25 if name.endswith("open.total") else
                                                                    30 if name == "proc.snapshot" else 0))
        if batch["case"] == "p2":
            for run in range(1, 11):
                pair = [r["measurement"]["values"]["proc.snapshot"] for r in rows if r["run"] == run]
                verdicts.append(None if len(pair) != 2 or None in pair else abs(pair[0] - pair[1]) <= 1)
        expected = 20 if batch["case"] == "p2" else 10
        gates[label] = ("INCOMPLETE" if len(rows) != expected else "FAIL" if False in verdicts else
                        "UNKNOWN" if None in verdicts else "PASS")
        summaries[label] = {key: {"unknown_n": values.count(None), "planned_n": 10,
                                  "unit": "ms" if key.endswith("open.total") else "",
                                  **(perf.stats([v for v in values if v is not None],
                                                "ms" if key.endswith("open.total") else "")
                                     if any(v is not None for v in values) else {"n": 0,
                                         "unit": "ms" if key.endswith("open.total") else ""})}
                            for key, values in samples.items()}
    new = batch["labels"][-1]
    status = "ERROR" if batch["errors"] else gates[new]
    result = {"schema": "gx-gtk-actions-result-v1", "status": status, "absolute_gates": gates,
              "metrics": summaries, "errors": batch["errors"], "visual_review": "PENDING (root)",
              "comparison": "unavailable" if any(v != "PASS" for v in gates.values()) else "absolute gates only"}
    perf.write_json(out / "RESULT.json", result)
    perf.write_json(json_path, result)
    (out / "SUMMARY.txt").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 4 if status == "FAIL" else 0 if status == "PASS" else 2
