"""Production-pipe controllers, including a bounded native endpoint impostor."""
import ctypes as C
from ctypes import wintypes as W
import os
import re
import struct
import threading
import time

from gx_boundary_controller import Native, EnvironmentUnavailable
from gx_fixture_evidence import native_snapshot, process_identity
from gx_session_ipc_fixture import CONFIG, PipeApi, pipe_names, wait
import gx_win_gui as gui


def forged_hello(original, pid, birth):
    if len(original) != 164 or original[:4] != b"GXIH" or original[6:8] != b"\0\0" or not any(original[8:24]):
        raise ValueError("not a complete native host hello")
    if pid <= 0 or birth <= 0:
        raise ValueError("native impostor identity required")
    result = bytearray(original)
    struct.pack_into("<IQ", result, 24, pid, birth)
    return bytes(result)


def replay_rows(text, pid, birth):
    """Outcomes of the gated CLI replay logged by exactly this launcher PID/birth."""
    return [outcome for source, created, outcome in re.findall(r"fixture_ipc_replay pid=(\d+) birth=(\d+) outcome=(\w+)", text)
            if int(source) == pid and int(created) == birth]


class FakeEndpoint(PipeApi):
    """Only a FIRST_PIPE_INSTANCE of the just-closed fixture host's namespace."""
    class Overlapped(C.Structure):
        _fields_ = [("internal", C.c_size_t), ("internal_high", C.c_size_t),
                    ("offset", W.DWORD), ("offset_high", W.DWORD), ("event", W.HANDLE)]

    def __init__(self, name, hello):
        super().__init__()
        for name_api, result, arguments in (
            ("CreateEventW", W.HANDLE, [C.c_void_p, W.BOOL, W.BOOL, W.LPCWSTR]),
            ("ConnectNamedPipe", W.BOOL, [W.HANDLE, C.POINTER(self.Overlapped)]),
            ("WriteFile", W.BOOL, [W.HANDLE, C.c_void_p, W.DWORD, C.POINTER(W.DWORD), C.POINTER(self.Overlapped)]),
            ("GetOverlappedResult", W.BOOL, [W.HANDLE, C.POINTER(self.Overlapped), C.POINTER(W.DWORD), W.BOOL]),
            ("WaitForSingleObject", W.DWORD, [W.HANDLE, W.DWORD]),
            ("CancelIoEx", W.BOOL, [W.HANDLE, C.c_void_p]),
        ):
            fn = getattr(self.api, name_api)
            fn.restype, fn.argtypes = result, arguments
        self.handle, self.hello = self.occupy(name), hello
        self.error, self.sent = None, False
        self.thread = threading.Thread(target=self.serve, name="A3-owned-pipe")
        self.thread.start()

    def operation(self, call, allow_connected=False):
        event = self.api.CreateEventW(None, True, False, None)
        if not event:
            raise OSError("CreateEventW failed")
        overlapped = self.Overlapped(event=event)
        try:
            ok = call(overlapped)
            error = C.get_last_error()
            if not ok and allow_connected and error == 535:
                return
            if not ok and error != 997:
                raise OSError(error, "owned pipe operation failed")
            if not ok:
                if self.api.WaitForSingleObject(event, 10000) != 0:
                    self.api.CancelIoEx(self.handle, C.byref(overlapped))
                    # Drain the exact cancelled OVERLAPPED before releasing its storage.
                    count = W.DWORD()
                    self.api.GetOverlappedResult(self.handle, C.byref(overlapped), C.byref(count), True)
                    raise TimeoutError("owned fake endpoint timed out")
                count = W.DWORD()
                if not self.api.GetOverlappedResult(self.handle, C.byref(overlapped), C.byref(count), False):
                    raise OSError(C.get_last_error(), "owned pipe completion failed")
        finally:
            self.close(event)

    def serve(self):
        try:
            self.operation(lambda ov: self.api.ConnectNamedPipe(self.handle, C.byref(ov)), True)
            buffer = C.create_string_buffer(self.hello)
            self.operation(lambda ov: self.api.WriteFile(self.handle, buffer, len(self.hello), None, C.byref(ov)))
            self.sent = True
        except Exception as error:
            self.error = str(error)

    def finish(self):
        self.api.CancelIoEx(self.handle, None)
        self.thread.join(timeout=12)
        if self.thread.is_alive():
            raise AssertionError("owned fake endpoint worker did not stop")
        self.close(self.handle)


def run(fixture):
    config = CONFIG + "command = cmd.exe /d /k prompt $G$S\n"
    if fixture.case_id == "IPC-02h":
        config += "keybind = global:ctrl+alt+shift+f24=toggle_quick_terminal\n"
    path = fixture.environment("ipc", config)
    if fixture.case_id == "IPC-03":
        host = fixture.start(path, env={"GHOSTTY_GX_REMOTE_TEST_HOLD_READY": "1"})
        host.wait_log("fixture_hold_ready", 15)
        assert not fixture.windows(host) and not gui.win32().child_processes(host.pid)
        launcher = fixture.start(path)
        time.sleep(0.3)
        assert not fixture.windows(launcher) and not gui.win32().child_processes(launcher.pid)
        fixture.processes[host.pid].terminate()
        fixture.processes[host.pid].wait(timeout=5)
        code = fixture.processes[launcher.pid].wait(timeout=15)
        assert code != 0
        fixture.check("pre-ready-real-host-exit", host_pid=host.pid, host_birth=host.creation, secondary_exit=code)
        return
    if fixture.case_id == "IPC-02h":
        instances = [fixture.start(path, resume=False) for _ in range(6)]
        for item in instances:
            fixture.resume(item)
        wait(lambda: sum(item.alive() for item in instances) == 1, 30)
        host = next(item for item in instances if item.alive())
        wait(lambda: len(fixture.windows(host)) == 6)
        exits = [fixture.processes[item.pid].wait(timeout=5) for item in instances if item is not host]
        assert exits == [0] * 5
    else:
        before_pipes = pipe_names()
        host = fixture.start(path)
        host.wait_window(20)
    native = Native(host, host.require_window().hwnd)
    if fixture.case_id == "IPC-02h":
        attempts, successes, current = (native.query(field) for field in (100, 101, 105))
        if attempts == 1 and successes == 0:
            raise EnvironmentUnavailable("the fixture's Ctrl+Alt+Shift+F24 global chord is occupied")
        assert (attempts, successes, current) == (1, 1, 1)
        fixture.check("one-persistent-global-hotkey", attempts=attempts, successes=successes, current=current,
                      host=native_snapshot(host), secondary_exits=exits)
    elif fixture.case_id == "IPC-04b":
        names = pipe_names() - before_pipes
        assert len(names) == 1, "owned endpoint namespace is ambiguous"
        name = names.pop()
        verifier = PipeApi()
        handle = verifier.api.CreateFileW("\\\\.\\pipe\\" + name, 0xc0000000, 0, None, 3, 0x40110000, None)
        if handle in (None, C.c_void_p(-1).value):
            raise AssertionError("cannot query the purported owned pipe")
        try:
            server_pid = W.ULONG()
            assert verifier.api.GetNamedPipeServerProcessId(handle, C.byref(server_pid)) and server_pid.value == host.pid
        finally:
            verifier.close(handle)
        line = host.wait_log(r"fixture_hello [0-9a-f]{328}", 10)
        original = bytes.fromhex(re.search(r"fixture_hello ([0-9a-f]{328})", line).group(1))
        fixture.capture(host, "genuine-host-before-squatter")
        fixture.close(host)
        wait(lambda: name not in pipe_names())
        impostor = process_identity(gui.win32(), os.getpid())
        hello = forged_hello(original, impostor["pid"], impostor["birth"])
        server = FakeEndpoint(name, hello)
        try:
            # file_log shares this path and rotates it on the first write of a
            # process; its bracketed identifier is a thread ID, not a PID.
            log_before = host.log.stat()
            bytes_before = host.log.read_bytes()
            launcher = fixture.start(path)
            process = fixture.processes[launcher.pid]
            seen = []
            deadline = time.monotonic() + 15
            while launcher.alive() and time.monotonic() < deadline:
                seen.extend(gui.win32().child_processes(launcher.pid))
                try:
                    assert not fixture.windows(launcher), "impostor connection started a GUI"
                except gui.InputBlocked as exc:
                    # Loss of PID identity alone does not prove our process
                    # exited. Only the retained Popen handle can establish it.
                    if exc.cause != "instance_gone" or process.poll() is None:
                        raise
                    break
                time.sleep(0.02)
            code = process.wait(timeout=2)
            assert code != 0 and not seen and server.sent and server.error is None
            log_after = launcher.log.stat()
            logs = launcher.log.read_bytes()
            if (log_after.st_dev, log_after.st_ino) == (log_before.st_dev, log_before.st_ino):
                assert logs.startswith(bytes_before), "shared log truncated without a bound rotation"
                logs = logs[len(bytes_before):]
            else:
                rotated = launcher.log.with_name(launcher.log.name + ".1").stat()
                assert (rotated.st_dev, rotated.st_ino) == (log_before.st_dev, log_before.st_ino), \
                    "shared log rotation does not belong to this launch"
            assert b"DifferentImage" in logs, "failure was not native image authentication"
            fixture.check("valid-hello-impostor-rejected", endpoint=name, impostor=impostor,
                          hello_sha256=__import__('hashlib').sha256(hello).hexdigest(), exit_code=code,
                          failure="DifferentImage", payload_claims_match_native_impostor=True)
        finally:
            server.finish()
        return
    elif fixture.case_id == "IPC-06":
        before = native_snapshot(host)
        executions = native.query(103)
        assert native.control(20, 1) == 1
        launcher = fixture.start(path)
        code = fixture.processes[launcher.pid].wait(timeout=15)
        assert code != 0 and native.query(104) == 0 and native.query(103) == executions + 1
        after = native_snapshot(host)
        assert before["children"] == after["children"] and len(after["windows"]) == len(before["windows"])
        fixture.check("GUI-failure-not-success-ACK", secondary_exit=code, before=before, after=after)
    elif fixture.case_id == "IPC-07":
        before = native.query(102), native.query(103)
        launcher = fixture.start(path, ("+toggle-quick-terminal",), env={"GHOSTTY_GX_REMOTE_TEST_REPLAY": "1"})
        assert fixture.processes[launcher.pid].wait(timeout=20) == 0
        # The duplicate send must actually have happened (same Attempt/key,
        # same outcome) before "executed once" means anything.
        logs = "".join(item.read_text(encoding="utf-8", errors="replace")
                       for item in (launcher.log, launcher.log.with_name(launcher.log.name + ".1")) if item.exists())
        replays = replay_rows(logs, launcher.pid, launcher.creation)
        if replays != ["completed"]:
            raise AssertionError(f"launcher {launcher.pid} did not replay the authenticated request exactly once: {replays}")
        wait(lambda: native.query(102) == before[0] + 1)
        assert native.query(103) == before[1] + 1
        quick = wait(lambda: next((w for w in host.windows() if w.cls == gui.WINDOW_CLASS and w.toolwindow and w.visible), None))
        fixture.capture(host, "duplicate-toggle-still-visible", quick)
        fixture.check("authenticated-request-replay-executed-once", before=before, replay_outcomes=replays,
                      launcher={"pid": launcher.pid, "birth": launcher.creation},
                      after=(native.query(102), native.query(103)), quick_hwnd=quick.hwnd)
    fixture.capture(host, "ipc-after")
