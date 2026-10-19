"""Real Explorer drag and owned DoDragDrop lifecycle controllers.

Explorer ownership is a newly opened HWND displaying the exact private folder,
not ownership of the shared explorer.exe process. Only that HWND is closed.
"""
import base64
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback

from gx_boundary_controller import Native, ROOT, assert_continuity, PeerInterfaceUnavailable, EnvironmentUnavailable
from gx_fixture_evidence import process_identity, sha256, native_snapshot
from gx_session_ipc_fixture import wait
from gx_ole_fixture import OwnedDrag
import gx_win_gui as gui


def shell_windows(action, directory, *, hwnd=0, name=""):
    script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$shell = New-Object -ComObject Shell.Application
$windows = @($shell.Windows())
if ($env:GX_A3_SHELL_ACTION -eq 'list') {
    ConvertTo-Json -Compress -InputObject @($windows | ForEach-Object { [long]$_.HWND })
    exit 0
}
$match = @($windows | Where-Object { [long]$_.HWND -eq [long]$env:GX_A3_SHELL_HWND })
if ($match.Count -ne 1) { throw 'owned Explorer HWND is gone or ambiguous' }
$window = $match[0]
$actual = [IO.Path]::GetFullPath([string]$window.Document.Folder.Self.Path)
$expected = [IO.Path]::GetFullPath($env:GX_A3_SHELL_FOLDER)
if (-not [string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)) { throw 'Explorer navigated away; no action permitted' }
if ($env:GX_A3_SHELL_ACTION -eq 'select') {
    $item = $window.Document.Folder.ParseName($env:GX_A3_SHELL_ITEM)
    if ($null -eq $item) { throw 'private source item not found' }
    $window.Document.SelectItem($item, 29)
}
if ($env:GX_A3_SHELL_ACTION -eq 'close') { $window.Quit() }
@{hwnd=[long]$env:GX_A3_SHELL_HWND;folder=$actual;action=$env:GX_A3_SHELL_ACTION} | ConvertTo-Json -Compress
'''
    env = dict(os.environ, GX_A3_SHELL_ACTION=action, GX_A3_SHELL_FOLDER=str(directory),
               GX_A3_SHELL_HWND=str(hwnd), GX_A3_SHELL_ITEM=name)
    command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand",
               base64.b64encode(script.encode("utf-16-le")).decode("ascii")]
    result = subprocess.run(command, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace",
                            timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode:
        raise gui.InputBlocked("owned Explorer Shell validation failed: " + result.stderr[-1200:])
    return json.loads(result.stdout.lstrip("\ufeff"))


def close_private_explorer(directory, prior, owned, settle=5.0):
    """Quit every Shell window opened since `prior` that still shows exactly the
    private fixture folder, including a late or unattributed one. The Shell
    "close" action rechecks the exact folder, so no other window is touched.
    Each new HWND is attempted at most once, including rejected windows."""
    closed, errors = [], []
    attempted = set()
    candidates = set() if owned is None else {owned}
    deadline = time.monotonic() + settle
    while True:
        try:
            candidates |= set(shell_windows("list", directory)) - prior
        except gui.InputBlocked as error:
            errors.append(str(error))
        for hwnd in sorted(candidates - prior - attempted):
            # A rejection can mean navigation away or lost ownership. Never
            # retry that HWND, even if a later enumeration still includes it.
            attempted.add(hwnd)
            try:
                shell_windows("close", directory, hwnd=hwnd)
                closed.append(hwnd)
            except gui.InputBlocked as error:
                errors.append(f"{hwnd:#x}: {error}")
        # Without an attributed window, keep watching briefly for a late one.
        remaining = deadline - time.monotonic()
        if owned is not None or remaining <= 0:
            return closed, errors
        time.sleep(min(0.5, remaining))


class ExplorerDrag:
    def __init__(self, target, hwnd, directory):
        self.target, self.hwnd, self.directory = target, hwnd, directory
        self.identity = process_identity(gui.win32(), gui.win32().window_pid(hwnd))
        if Path(self.identity["exe"]).name.casefold() != "explorer.exe":
            raise gui.InputBlocked("new Shell window is not Explorer")

    def guard(self):
        self.target.ensure_owned()
        api = gui.win32()
        if process_identity(api, self.identity["pid"]) != self.identity:
            raise gui.InputBlocked("Explorer PID/birth/image changed")
        if not api.IsWindow(self.hwnd) or api.window_pid(self.hwnd) != self.identity["pid"] or api.class_name(self.hwnd) != "CabinetWClass":
            raise gui.InputBlocked("owned Explorer window changed")

    def mouse(self, x, y, action="move"):
        self.guard()
        api = gui.win32()
        foreground = api.foreground()
        if api.GetAncestor(foreground, 2) != self.hwnd and api.window_pid(foreground) != self.target.pid:
            raise gui.InputBlocked("foreground left the owned Explorer/target windows")
        hit = api.window_at(x, y)
        if api.GetAncestor(hit, 2) != self.hwnd and api.window_pid(hit) != self.target.pid:
            raise gui.InputBlocked("drag pointer left the two owned windows")
        flags = {"move": None, "down": 2, "up": 4}[action]
        events = [api.mouse_input(0x0001 | 0x8000 | 0x4000, x, y)]
        if flags:
            events.append(api.mouse_input(flags))
        api.send(events)


def explorer_drag_start(nodes, index, window):
    """Physical point where the owned Explorer drag begins: the center of the
    item's name cell (Details view: a descendant with automation id
    System.ItemNameDisplay), else of the item itself, clipped to the owned
    window rectangle. A details row can be wider than the window; its center
    then lies over another window (round3-batch-20261018-105235 pressed on the
    target terminal and selected text instead of starting an OLE drag)."""
    item = nodes[index]
    rect = item["bounds"]
    for node in nodes[index + 1:]:
        if node["depth"] <= item["depth"]:
            break
        if node.get("automation_id") == "System.ItemNameDisplay" and node.get("bounds") and node["bounds"][2] > 0:
            rect = node["bounds"]
            break
    left, top = max(rect[0], window[0]), max(rect[1], window[1])
    right, bottom = min(rect[0] + rect[2], window[2]), min(rect[1] + rect[3], window[3])
    if right - left < 2 or bottom - top < 2:
        raise gui.InputBlocked(f"Explorer source item {rect} is not inside the owned window {window}")
    return round((left + right) / 2), round((top + bottom) / 2)


def explorer(fixture, instance, native):
    directory = fixture.out / "Explorer-private-source"
    directory.mkdir()
    file = directory / "GX_A3_Explorer_中文_🧪.txt"
    file.write_text("Only this fixture created this file.\n", encoding="utf-8")
    original = sha256(file)
    prior = set(shell_windows("list", directory))
    # /n requests a new window. It may use the shared Explorer process; the
    # coordinator explicitly authorizes only our new private-folder window.
    launcher = subprocess.Popen([str(Path(os.environ['WINDIR']) / 'explorer.exe'), '/n,/separate,', str(directory)])
    owned = None
    button = False
    failure = None
    try:
        created = wait(lambda: set(shell_windows("list", directory)) - prior, 15)
        if len(created) != 1:
            raise gui.InputBlocked("Explorer did not create exactly one new attributable HWND")
        owned = created.pop()
        shell_windows("select", directory, hwnd=owned, name=file.name)
        drag = ExplorerDrag(instance, owned, directory)
        from gx_drop_broker_fixture import token
        source_token, target_token = token(drag.identity["pid"]), token(instance.pid)
        if source_token["integrity"] != target_token["integrity"]:
            raise EnvironmentUnavailable("host Explorer and target have different integrity; run the split-token broker matrix in VM")
        left, top, right, bottom = gui.win32().window_rect(native.hwnd)
        gui.win32().SetWindowPos(owned, None, left + 30, top + 80, 720, 480, 0x0014)
        if not gui.win32().activate(owned):
            raise gui.InputBlocked("cannot activate the newly opened Explorer window")
        command = [sys.executable, str(ROOT / "scripts/gx_win_uia.py"), "--worker", "--framework", "Win32",
                   "--pid", str(drag.identity["pid"]), "--birth", str(drag.identity["birth"]),
                   "--exe", drag.identity["exe"], "--sha256", drag.identity["sha256"], "--hwnd", str(owned),
                   "--max-nodes", "512", "--max-depth", "16"]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=20)
        (fixture.out / "explorer-uia.json").write_text(result.stdout, encoding="utf-8")
        assert result.returncode == 0, result.stdout
        nodes = json.loads(result.stdout)["nodes"]
        # Explorer may hide the extension. Both exact spellings identify only
        # the uniquely named file we just created, never another directory item.
        candidates = [i for i, n in enumerate(nodes) if n["name"] in (file.name, file.stem) and n.get("bounds") and n["bounds"][2] > 0]
        assert candidates, "private Explorer source item has no bounded UIA rectangle"
        index = min(candidates, key=lambda i: nodes[i]["bounds"][2] * nodes[i]["bounds"][3])
        start = explorer_drag_start(nodes, index, gui.win32().window_rect(owned))
        # The press must land on the owned Explorer, not on the target behind it.
        if gui.win32().GetAncestor(gui.win32().window_at(*start), 2) != owned:
            raise gui.InputBlocked(f"drag start {start} is not on the owned Explorer window")
        tree = native.tree()
        leaf = next(n["leaf"] for n in tree["nodes"] if "leaf" in n and n["leaf"]["core"] == tree["active_core"])
        terminal = gui.win32().window_rect(leaf["hwnd"])
        end = terminal[2] - 70, terminal[1] + (terminal[3] - terminal[1]) // 2
        if gui.win32().GetAncestor(gui.win32().window_at(*end), 2) != native.hwnd:
            raise gui.InputBlocked(f"drop point {end} is not on the target window")
        before = native.query(200), native.query(201)
        drag.guard()
        source_rect = gui.win32().window_rect(owned)
        for fx, fy in ((0.5, 0.5), (0.1, 0.1), (0.9, 0.9)):
            hit = gui.win32().window_at(round(source_rect[0] + (source_rect[2] - source_rect[0]) * fx),
                                      round(source_rect[1] + (source_rect[3] - source_rect[1]) * fy))
            if gui.win32().GetAncestor(hit, 2) != owned:
                raise gui.InputBlocked("owned Explorer capture is occluded by another window")
        gui.win32().capture_screen(source_rect).save_png(fixture.out / "explorer-owned-source.png")
        fixture.report["captures"].append({"file": "explorer-owned-source.png", "method": "screen", "review": "PENDING_REVIEW", "identity": drag.identity})
        shell_windows("check", directory, hwnd=owned)
        drag.mouse(*start, "down")
        button = True
        for step in range(1, 21):
            drag.mouse(round(start[0] + (end[0] - start[0]) * step / 20), round(start[1] + (end[1] - start[1]) * step / 20))
            time.sleep(0.04)
        drag.mouse(*end, "up")
        button = False
        wait(lambda: native.query(200) == before[0] + 1 and native.query(201) == before[1] + 1)
        assert sha256(file) == original
        fixture.check("Explorer-real-OLE-source", explorer=drag.identity, source_hwnd=owned, folder=str(directory), drag_start=start,
                      file_hash=original, before=before, after=(native.query(200), native.query(201)), clipboard_access=False, enter_injected=False)
        gui.win32().activate(native.hwnd)
        fixture.capture_native(instance, native, "explorer-dropped-no-enter")
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            if button:
                # Never steal focus back after a guard failure. Cancellation is
                # allowed only while one of the two owned windows is foreground.
                drag.guard()
                api = gui.win32()
                if api.GetAncestor(api.foreground(), 2) == owned:
                    api.send([api.key_input(0x1b, False), api.key_input(0x1b, True),
                              api.mouse_input(gui.MOUSE_BUTTONS["left"][1])])
                else:
                    release_on_owned_app(instance)
        finally:
            # Also on failure: every new window showing the private folder is
            # quit. Never terminate explorer.exe, including a shared shell process.
            closed, errors = close_private_explorer(directory, prior, owned)
            fixture.check("Explorer-cleanup", owned_hwnd=owned, closed_hwnds=closed, cleanup_errors=errors,
                          launcher_pid=launcher.pid, process_terminated=False)
            if failure is None and owned is not None and owned not in closed:
                raise AssertionError("the fixture's own Explorer window could not be closed")


def release_on_owned_app(instance):
    instance.ensure_foreground()
    api = gui.win32()
    # Escape cancels the owned drag before releasing; do not move the pointer
    # or activate a window as a workaround for a lost foreground guard.
    api.send([api.key_input(0x1b, False), api.key_input(0x1b, True),
              api.mouse_input(gui.MOUSE_BUTTONS["left"][1])])


def require_left_button_up():
    query = gui.win32().user32.GetAsyncKeyState
    query.argtypes, query.restype = [ctypes.c_int], ctypes.c_short
    if query(1) & 0x8000:
        raise gui.InputBlocked("left button is already down; refusing to take ownership or send input")


def lifecycle_drag_layout(target, source, terminal):
    """Place the unchanged source size inside the target client, clear of the endpoint."""
    left, top, right, bottom = target
    width, height = source[2] - source[0], source[3] - source[1]
    if (width <= 0 or height <= 0 or width + 32 > right - left or height + 32 > bottom - top
            or terminal[2] - terminal[0] < 2 or terminal[3] - terminal[1] < 2
            or not (left <= terminal[0] < terminal[2] <= right and top <= terminal[1] < terminal[3] <= bottom)):
        raise gui.InputBlocked("owned source/terminal cannot fit inside the target client")
    end = (terminal[2] - min(60, (terminal[2] - terminal[0]) // 2), (terminal[1] + terminal[3]) // 2)
    for x, y in ((left + 16, top + 16), (left + 16, bottom - height - 16),
                 (right - width - 16, top + 16), (right - width - 16, bottom - height - 16)):
        if not (x <= end[0] < x + width and y <= end[1] < y + height):
            return (x, y, width, height), end
    raise gui.InputBlocked("owned source would obscure the terminal endpoint")


def preflight_lifecycle_path(drag, points):
    """Read-only hit tests for every planned point and every pixel between them."""
    drag.check_foreground()
    api = gui.win32()
    if len(points) < 2:
        raise gui.InputBlocked("owned drag path is empty")

    def check(point):
        hit = api.window_at(*point)
        root = api.GetAncestor(hit, 2) if hit else 0
        pid = api.window_pid(hit) if hit else 0
        if not ((root == drag.source_hwnd and pid == drag.process.pid)
                or (root == drag.target_hwnd and pid == drag.instance.pid)):
            raise gui.InputBlocked(f"drag preflight point {point} is outside both owned windows; no input sent")
        return hit, root

    if check(points[0])[1] != drag.source_hwnd:
        raise gui.InputBlocked("drag preflight start is not on the owned source")
    remaining = 8192
    for start, end in zip(points, points[1:]):
        steps = max(abs(end[0] - start[0]), abs(end[1] - start[1]), 1)
        remaining -= steps
        if remaining < 0:
            raise gui.InputBlocked("owned drag path exceeds the bounded preflight")
        for step in range(1, steps + 1):
            check((round(start[0] + (end[0] - start[0]) * step / steps),
                   round(start[1] + (end[1] - start[1]) * step / steps)))
    if check(points[-1])[0] != drag.terminal.hwnd:
        raise gui.InputBlocked("drag preflight endpoint is not the verified terminal HWND")
    drag.check_foreground()


def prepare_lifecycle_drag(drag, facts=None):
    facts = {} if facts is None else facts
    facts["preflight"] = "PENDING"
    drag.check_identity()
    api = gui.win32()
    target = api.client_rect(drag.target_hwnd)
    source, terminal = api.raw_window_rect(drag.source_hwnd), api.client_rect(drag.terminal.hwnd)
    facts.update(target_client=target, source_before=source, terminal_client=terminal)
    placement, end = lifecycle_drag_layout(target, source, terminal)
    facts.update(placement=placement, end=end)
    drag.check_identity()
    if not api.SetWindowPos(drag.source_hwnd, None, *placement, 0x0014):  # NOZORDER | NOACTIVATE
        raise gui.InputBlocked("cannot place owned source inside the target")
    drag.check_identity()
    actual = api.raw_window_rect(drag.source_hwnd)
    facts["source_after"] = actual
    if not (target[0] <= actual[0] < actual[2] <= target[2]
            and target[1] <= actual[1] < actual[3] <= target[3]):
        raise gui.InputBlocked("owned source placement escaped the target client")
    drag.activate_source()
    start = drag.start_point()
    points = [(round(start[0] + (end[0] - start[0]) * step / 16),
               round(start[1] + (end[1] - start[1]) * step / 16)) for step in range(17)]
    facts["points"] = points
    preflight_lifecycle_path(drag, points)
    facts["preflight"] = "PASS"
    return points


def verify_lifecycle_source(source, source_hash, process, birth):
    api = gui.win32()
    if (not birth or process.poll() is not None or api.process_creation(process.pid) != birth
            or not gui.same_path(api.process_image(process.pid) or "", source)
            or sha256(source) != source_hash):
        raise gui.InputBlocked("OLE source PID/birth/image changed; refusing cleanup")


def release_lifecycle_button(instance, source, source_hash, process, birth, source_hwnd):
    api = gui.win32()
    foreground = api.foreground()
    if source_hwnd and foreground and api.GetAncestor(foreground, 3) == source_hwnd:
        verify_lifecycle_source(source, source_hash, process, birth)
        if (not api.IsWindow(source_hwnd) or api.window_pid(source_hwnd) != process.pid
                or api.class_name(source_hwnd) != "GxOwnedOleDragSource"):
            raise gui.InputBlocked("owned OLE source HWND changed; no cleanup input sent")
        foreground = api.foreground()  # Recheck after image hashing; never activate.
        if (not foreground or api.GetAncestor(foreground, 3) != source_hwnd
                or api.window_pid(foreground) != process.pid or api.process_creation(process.pid) != birth):
            raise gui.InputBlocked("foreground left owned OLE source; no cleanup input sent")
        api.send([api.key_input(0x1b, False), api.key_input(0x1b, True),
                  api.mouse_input(gui.MOUSE_BUTTONS["left"][1])])
    else:
        release_on_owned_app(instance)


def cleanup_lifecycle(report, instance, source, source_hash, process, birth, source_hwnd, button, failure):
    errors, interruption = [], None
    try:
        if button:
            release_lifecycle_button(instance, source, source_hash, process, birth, source_hwnd)
            button = False
    except BaseException as error:
        errors.append({"phase": "button_release", "type": type(error).__name__, "error": str(error)})
        if not isinstance(error, Exception):
            interruption = error
    try:
        if process.poll() is None:
            if not birth:
                raise gui.InputBlocked("OLE source birth unavailable; refusing cleanup")
            verify_lifecycle_source(source, source_hash, process, birth)
            process.terminate()
            process.wait(timeout=5)
    except BaseException as error:
        errors.append({"phase": "source_exit", "type": type(error).__name__, "error": str(error)})
        if interruption is None and not isinstance(error, Exception):
            interruption = error
    report["ole_lifecycle_cleanup"] = {"button_release_pending": button, "errors": errors}
    # Finish both phases and record them before propagating an interruption.
    # A pending primary exception always takes precedence over cleanup errors.
    if failure is None:
        if interruption is not None:
            report.update(status="FAIL", reason=str(interruption), interruption_type=type(interruption).__name__)
            raise interruption
        if errors:
            raise RuntimeError("OLE lifecycle cleanup failed: " + "; ".join(item["error"] for item in errors))


def lifecycle(fixture, instance, first, destination):
    require_left_button_up()
    if fixture.args.ole_source is None:
        raise PeerInterfaceUnavailable("build the owned gx_ole_source and provide --ole-source")
    source = fixture.args.ole_source.resolve(strict=True)
    source_hash = sha256(source)
    before = first.tree()
    leaf = next(n["leaf"] for n in before["nodes"] if "leaf" in n and n["leaf"]["core"] == before["active_core"])
    terminal = gui.win32().info(leaf["hwnd"])
    work = fixture.out / "ole-source"
    work.mkdir()
    command = [str(source), "--run", "--source-window", f"--hwnd={terminal.hwnd}", f"--pid={instance.pid}",
               f"--birth={instance.creation}", f"--exe={instance.exe}", f"--sha256={fixture.report['app_sha256']}",
               f"--work-dir={work}", "--case=unicode", "--timeout-ms=20000"]
    button, failure, source_hwnd = False, None, None
    with (work / "stdout.txt").open("wb") as stdout, (work / "stderr.txt").open("wb") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
        birth = None
        try:
            birth = gui.win32().process_creation(process.pid)
            if not birth:
                raise gui.InputBlocked("OLE source birth unavailable; no input sent")
            ready = wait(lambda: next(work.glob(f"gx-ole-{process.pid}-*/ready.json"), None))
            facts = json.loads(ready.read_text(encoding="utf-8"))
            assert (facts["source_pid"] == process.pid and facts["target_pid"] == instance.pid
                    and facts["target_birth"] == instance.creation and facts["target_hwnd"] == terminal.hwnd
                    and facts["app_sha256"].lower() == fixture.report["app_sha256"].lower())
            source_hwnd = facts["source_hwnd"]
            drag = OwnedDrag(instance, fixture.exe, fixture.report["app_sha256"], source, source_hash, process, birth, source_hwnd, terminal)
            if drag.target_hwnd != first.hwnd:
                raise gui.InputBlocked("terminal belongs to another target window")
            plan = fixture.report["ole_lifecycle_drag"] = {}
            points = prepare_lifecycle_drag(drag, plan)
            fixture.check("OLE-drag-preflight", source_pid=process.pid, source_birth=birth,
                          source_hwnd=source_hwnd, target_hwnd=drag.target_hwnd, points=points)
            require_left_button_up()
            # A partial SendInput can press the button and still raise. From
            # this attempt onward, only a successful release clears the flag.
            button = True
            drag.mouse(*points[0], action="down")
            for index, point in enumerate(points[1:], 1):
                drag.mouse(*point, target_only=index == len(points) - 1)
                time.sleep(0.03)
            trace = ready.parent / "trace.jsonl"
            wait(lambda: trace.exists() and 'continue' in trace.read_text(encoding="utf-8"))
            queued = first.query(201)
            if fixture.case_id == "OLE-08":
                assert first.control(3, destination.hwnd) == 1
                assert_continuity(before, destination.tree())
            else:
                assert first.control(8) == 1
                wait(lambda: not gui.win32().IsWindow(terminal.hwnd))
            # Cancel the in-flight real OLE operation through the owned source
            # if still alive, otherwise release onto the surviving owned app.
            release_lifecycle_button(instance, source, source_hash, process, birth, source_hwnd)
            button = False
            code = process.wait(timeout=10)
            evidence = json.loads((ready.parent / "evidence.json").read_text(encoding="utf-8"))
            assert code in (3, 4) and evidence["effect"] == 0 and evidence["get_data"] == evidence["medium_releases"]
            assert destination.query(201) == queued, "lifecycle cancellation pasted into a replacement target"
            fixture.check("real-OLE-lifecycle", before=before, native=evidence, source_pid=process.pid, source_birth=birth,
                          after=destination.tree() if fixture.case_id == "OLE-08" else first.tree())
            fixture.capture_native(instance, destination if fixture.case_id == "OLE-08" else first, "OLE-lifecycle-after")
        except BaseException as error:
            failure = error
            fixture.report["ole_lifecycle_failure"] = {"type": type(error).__name__, "reason": str(error),
                                                       "traceback": traceback.format_exc()}
            raise
        finally:
            cleanup_lifecycle(fixture.report, instance, source, source_hash, process, birth, source_hwnd, button, failure)


def run(fixture):
    if fixture.case_id != "OLE-07":
        require_left_button_up()
    instance, first, _, second = fixture.stage()
    if fixture.case_id == "OLE-07":
        explorer(fixture, instance, first)
    else:
        lifecycle(fixture, instance, first, second)
