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
    "close" action rechecks the exact folder, so no other window is touched."""
    closed, errors = [], []
    candidates = set() if owned is None else {owned}
    deadline = time.monotonic() + settle
    while True:
        try:
            candidates |= set(shell_windows("list", directory)) - prior
        except gui.InputBlocked as error:
            errors.append(str(error))
        for hwnd in sorted(candidates - set(closed)):
            try:
                shell_windows("close", directory, hwnd=hwnd)
                closed.append(hwnd)
            except gui.InputBlocked as error:
                errors.append(f"{hwnd:#x}: {error}")
        # Without an attributed window, keep watching briefly for a late one.
        if owned is not None or time.monotonic() > deadline:
            return closed, errors
        time.sleep(0.5)


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


def lifecycle(fixture, instance, first, destination):
    if fixture.args.ole_source is None:
        raise PeerInterfaceUnavailable("build the owned gx_ole_source and provide --ole-source")
    source = fixture.args.ole_source.resolve(strict=True)
    before = first.tree()
    leaf = next(n["leaf"] for n in before["nodes"] if "leaf" in n and n["leaf"]["core"] == before["active_core"])
    terminal = gui.win32().info(leaf["hwnd"])
    work = fixture.out / "ole-source"
    work.mkdir()
    command = [str(source), "--run", "--source-window", f"--hwnd={terminal.hwnd}", f"--pid={instance.pid}",
               f"--birth={instance.creation}", f"--exe={instance.exe}", f"--sha256={fixture.report['app_sha256']}",
               f"--work-dir={work}", "--case=unicode", "--timeout-ms=20000"]
    button = False
    with (work / "stdout.txt").open("wb") as stdout, (work / "stderr.txt").open("wb") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
        birth = gui.win32().process_creation(process.pid)
        try:
            ready = wait(lambda: next(work.glob(f"gx-ole-{process.pid}-*/ready.json"), None))
            facts = json.loads(ready.read_text(encoding="utf-8"))
            assert facts["source_pid"] == process.pid and facts["target_hwnd"] == terminal.hwnd
            drag = OwnedDrag(instance, fixture.exe, fixture.report["app_sha256"], source, sha256(source), process, birth, facts["source_hwnd"], terminal)
            drag.target_hwnd = first.hwnd
            drag.activate_source()
            start = drag.start_point()
            end = terminal.rect[2] - 60, terminal.rect[1] + 140
            drag.mouse(*start, action="down")
            button = True
            for step in range(1, 17):
                drag.mouse(round(start[0] + (end[0] - start[0]) * step / 16), round(start[1] + (end[1] - start[1]) * step / 16))
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
            if process.poll() is None and gui.win32().IsWindow(facts["source_hwnd"]):
                api = gui.win32()
                if api.window_pid(api.foreground()) == process.pid and api.process_creation(process.pid) == birth:
                    api.send([api.key_input(0x1b, False), api.key_input(0x1b, True),
                              api.mouse_input(gui.MOUSE_BUTTONS["left"][1])])
                else:
                    release_on_owned_app(instance)
                button = False
            code = process.wait(timeout=10)
            if button:
                release_on_owned_app(instance)
                button = False
            evidence = json.loads((ready.parent / "evidence.json").read_text(encoding="utf-8"))
            assert code in (3, 4) and evidence["effect"] == 0 and evidence["get_data"] == evidence["medium_releases"]
            assert destination.query(201) == queued, "lifecycle cancellation pasted into a replacement target"
            fixture.check("real-OLE-lifecycle", before=before, native=evidence, source_pid=process.pid, source_birth=birth,
                          after=destination.tree() if fixture.case_id == "OLE-08" else first.tree())
            fixture.capture_native(instance, destination if fixture.case_id == "OLE-08" else first, "OLE-lifecycle-after")
        finally:
            try:
                if button:
                    release_on_owned_app(instance)
            finally:
                if process.poll() is None:
                    if gui.win32().process_creation(process.pid) != birth:
                        raise gui.InputBlocked("OLE source PID reused; refusing cleanup")
                    process.terminate()
                    process.wait(timeout=5)


def run(fixture):
    instance, first, _, second = fixture.stage()
    if fixture.case_id == "OLE-07":
        explorer(fixture, instance, first)
    else:
        lifecycle(fixture, instance, first, second)
