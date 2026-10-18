#!/usr/bin/env python3
"""GTK P2/P4 drivers, called by gx_perf gtk (never the standard load schema).

Only gx_wsl's public smoke/scenario interfaces are used. The generated scenario
runs outside the measured checkout; it verifies the normal install receipt itself.
No build, source edits, retries, or Windows input occur here.
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
        state = {"live": live(), "windows": windows, "shells": shells, "ns": time.monotonic_ns()}
        report["observations"].append(state)
        persist()
        return state

    # AT-SPI is an OS runtime prerequisite, accessed through the standard library.
    # An unavailable bridge or ambiguous widget state is an error, never a delay-based success.
    def accessibility_reader():
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
        bind("atspi_init", integer, [])()
        bind("atspi_set_timeout", None, [integer, integer])(1500, 3000)

        def string(fn, node):
            value = fn(node, None)
            if not value:
                return ""
            try:
                return ctypes.string_at(value).decode("utf-8", errors="strict")
            finally:
                glib.g_free(value)

        def read():
            rows = []
            count = 0
            def visit(node, depth):
                nonlocal count
                if not node:
                    return
                try:
                    count += 1
                    if depth > 40 or count > 4000:
                        raise ValueError("accessibility tree exceeds bounded traversal")
                    state = states(node)
                    try:
                        showing = bool(state and contains(state, 25))  # ATSPI_STATE_SHOWING
                    finally:
                        if state:
                            obj.g_object_unref(state)
                    if showing:
                        rows.append({"name": string(name, node), "role": string(role, node)})
                    for index in range(children(node, None)):
                        visit(child(node, index, None), depth + 1)
                finally:
                    obj.g_object_unref(node)
            top = desktop(0)
            if not top:
                raise ValueError("AT-SPI desktop unavailable")
            try:
                for index in range(children(top, None)):
                    app = child(top, index, None)
                    if not app:
                        continue
                    if process(app, None) == api["pid"]():
                        visit(app, 0)
                    else:
                        obj.g_object_unref(app)
            finally:
                obj.g_object_unref(top)
            if not rows:
                raise ValueError("no showing AT-SPI nodes for measured PID")
            return rows
        return read

    def widget_state(rows, kind):
        if kind == "settings":
            return any(r["role"] == "dialog" and r["name"] == "Settings" for r in rows)
        # GX menu is a GTK popover; GTK versions differ in its accessible role.
        names = {r["name"].replace("_", "").rstrip(".…") for r in rows}
        return "New Tab" in names and "Quit" in names and "Keyboard Shortcuts" in names

    def await_widget(kind, opened):
        deadline = time.monotonic() + 5
        while True:
            live()
            rows = read_widgets()
            if widget_state(rows, kind) == opened:
                report["observations"].append({"widget": kind, "opened": opened,
                                                "ns": time.monotonic_ns(), "nodes": rows, "live": live()})
                persist()
                return
            if time.monotonic() >= deadline:
                raise ValueError(f"{kind} did not reach opened={opened}")
            time.sleep(0.05)

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
            api["capture"]("idle-end")
        else:
            read_widgets = accessibility_reader()
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
    return ("# gx-scenario-python-v1\n" + inspect.getsource(idle_ticks) + "\n" + inspect.getsource(capture_session) +
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
        for index, state in enumerate(states):
            shells = state.get("shells", [])
            if state.get("live") != item["before"]["live"] or len(state.get("windows", [])) != 1 or \
                    len(shells) != spec["tabs"] or len({r["fd0"] for r in shells}) != spec["tabs"] or \
                    any(not r["exe"].endswith("/bash") or not r["fd0"].startswith("/dev/pts/") for r in shells) or \
                    shells != states[0]["shells"] or state["windows"] != states[0]["windows"]:
                raise perf.PerfError("idle process/window/terminal state incomplete or changed")
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
            if [o["opened"] for o in observed] != [True, False] or any(
                    o.get("live") != item["before"]["live"] or not o.get("nodes") for o in observed):
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
