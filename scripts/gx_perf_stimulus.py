#!/usr/bin/env python3
"""Owned C7 console stimulus and PDH thread sampling; no desktop work at import time.

The console subprocess is launched by Ghostty, not detached by the collector.
Its receipts prove console writes/committed input, not successful rendering or
the internal preedit state. Screenshots and the post-window IME commit remain
separate evidence. No keyboard layout is loaded, selected or changed here.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid


CASES = ('visible', 'unfocused', 'minimized', 'blink-off', 'ime-preedit', 'output-wakeup')
ANIMATION_CASES = ('kitty-animation', 'custom-shader')
ANIMATION_SHADER = '''void mainImage(out vec4 color, in vec2 coord) {
    vec4 terminal = texture(iChannel0, coord / iResolution.xy);
    float wave = 0.5 + 0.5 * sin(iTime * 6.2831853);
    color = vec4(mix(terminal.rgb, vec3(wave, 0.2, 1.0 - wave), 0.5), terminal.a);
}
'''
PDH_PATHS = {name: rf'\Thread(*)\{counter}' for name, counter in (
    ('pid', 'ID Process'), ('tid', 'ID Thread'), ('birth', 'Elapsed Time'),
    ('switches', 'Context Switches/sec'))}


class EnvironmentUnavailable(RuntimeError):
    """A probed OS prerequisite is absent, not an unimplemented tool feature."""


class StrictFrameError(RuntimeError):
    """P7 failed closed; the caller must persist the supplied raw evidence."""


P7_MAGIC = 0x47585037
P7_QUERY = 0x450
P7_UNSUPPORTED = {2: 'size_unsupported', 3: 'no_local_surface',
                  4: 'lifetime_invalidated', 5: 'publication_disabled'}
P7_LIMITS = {'frame_match_seconds': 2.0, 'round_seconds': 120.0,
             'warmup_seconds': 60.0, 'termination_seconds': 5.0}


def durable_json(path: Path, value: dict) -> None:
    """Atomic checkpoint; the enclosing worker deadline also covers disk I/O."""
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('w', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def p7_input_epoch(expected, actual, report, stage) -> bool:
    """Audit the inherited input epoch without declaring new SendInput activity."""
    row = {'schema': 'gx-input-guard-v1', 'event': 'guard', 'check': 'p7_worker_epoch',
           'stage': stage, 'time_ns': time.time_ns(), 'harness_pid': os.getpid(),
           'instance_pid': report.get('pid'), 'batch_id': os.environ.get('GX_PERF_BATCH_ID'),
           'before_tick': expected, 'after_tick': actual,
           'status': 'pass' if expected == actual else 'fail'}
    if expected != actual:
        row.update(cause='foreign_input', reason='input arrived across P7 worker boundary')
    report.setdefault('worker_input_checks', []).append(row)
    if path := os.environ.get('GX_PERF_GUARD_LOG'):
        append_json(Path(path), row)
    return expected == actual


class WindowsJob:
    """An unnamed, non-inheritable job containing only this gated worker tree."""
    class BasicLimit(ctypes.Structure):
        _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                    ('flags', ctypes.c_uint32), ('min_ws', ctypes.c_size_t),
                    ('max_ws', ctypes.c_size_t), ('active_limit', ctypes.c_uint32),
                    ('affinity', ctypes.c_size_t), ('priority', ctypes.c_uint32),
                    ('scheduling', ctypes.c_uint32)]

    class Accounting(ctypes.Structure):
        _fields_ = [(name, ctypes.c_int64) for name in ('user', 'kernel', 'period_user', 'period_kernel')] + [
            (name, ctypes.c_uint32) for name in ('faults', 'total', 'active', 'terminated')]

    def __init__(self):
        if sys.platform != 'win32':
            raise StrictFrameError('P7 process supervision requires Windows Jobs')
        class ExtendedLimit(ctypes.Structure):
            _fields_ = [('basic', WindowsJob.BasicLimit), ('io', ctypes.c_uint64 * 6)] + [
                (name, ctypes.c_size_t) for name in ('process_memory', 'job_memory', 'peak_process', 'peak_job')]
        self.dll = ctypes.WinDLL('kernel32', use_last_error=True)
        for name, args, result in (
            ('CreateJobObjectW', [ctypes.c_void_p, ctypes.c_wchar_p], ctypes.c_void_p),
            ('SetInformationJobObject', [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32], ctypes.c_int),
            ('AssignProcessToJobObject', [ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int),
            ('QueryInformationJobObject', [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p], ctypes.c_int),
            ('TerminateJobObject', [ctypes.c_void_p, ctypes.c_uint32], ctypes.c_int),
            ('CloseHandle', [ctypes.c_void_p], ctypes.c_int),
        ):
            function = getattr(self.dll, name)
            function.argtypes, function.restype = args, result
        self.handle = self.dll.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimit()
        limits.basic.flags = 0x2000  # KILL_ON_JOB_CLOSE; no breakaway permissions.
        if not self.dll.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def assign(self, process):
        # Popen retains this exact process handle: no reopening a possibly reused PID.
        if not self.dll.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())

    def active(self):
        value = self.Accounting()
        if not self.dll.QueryInformationJobObject(self.handle, 1, ctypes.byref(value), ctypes.sizeof(value), None):
            raise ctypes.WinError(ctypes.get_last_error())
        return value.active

    def terminate(self):
        if not self.dll.TerminateJobObject(self.handle, 1):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle:
            if not self.dll.CloseHandle(self.handle):
                raise ctypes.WinError(ctypes.get_last_error())
            self.handle = None


def supervise_p7(command, directory: Path, *, timeout=P7_LIMITS['round_seconds'],
                 cleanup_timeout=P7_LIMITS['termination_seconds'], environment=None) -> dict:
    """Bound one round, not one frame. No capture/input thread runs in the parent.

    Only the test API accepts shortened limits; production callers use P7_LIMITS.
    Workers MUST read P7_GO before importing/starting any GUI or child operation.
    """
    if not all(math.isfinite(n) and n > 0 for n in (timeout, cleanup_timeout)):
        raise StrictFrameError('P7 requires finite positive worker limits')
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'supervisor.json'
    raw = {'status': 'running', 'limits': dict(P7_LIMITS), 'execution_seconds': timeout,
           'termination_seconds': cleanup_timeout, 'gate_released': False,
           'begin_qpc_ns': time.perf_counter_ns(), 'command': list(command)}
    durable_json(path, raw)
    began = time.monotonic()
    job = process = None
    assigned = False
    error = None
    try:
        job = WindowsJob()
        with (directory / 'worker.log').open('wb') as log:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT,
                                       env=environment, creationflags=subprocess.CREATE_NO_WINDOW,
                                       close_fds=True)
            raw['worker_pid'] = process.pid
            job.assign(process)
            assigned = True
            raw['job_assigned_qpc_ns'] = time.perf_counter_ns()
            durable_json(path, raw)
            if time.monotonic() - began >= timeout:
                raise TimeoutError('P7 worker timeout before gate')
            process.stdin.write(b'P7_GO\n')
            process.stdin.flush()
            process.stdin.close()
            raw['gate_released'] = True
            durable_json(path, raw)
            raw['worker_exit'] = process.wait(timeout=max(0, timeout - (time.monotonic() - began)))
            if raw['worker_exit'] != 0:
                raise StrictFrameError(f'P7 worker abnormal exit {raw["worker_exit"]}')
            while job.active():
                if time.monotonic() - began >= timeout:
                    raise TimeoutError('P7 worker timeout waiting for owned descendants')
                time.sleep(min(0.01, max(0, timeout - (time.monotonic() - began))))
    except (Exception, KeyboardInterrupt) as exc:
        error = f'{type(exc).__name__}: {exc}'
        if isinstance(exc, (subprocess.TimeoutExpired, TimeoutError)):
            error = 'P7 worker timeout: ' + error
    finally:
        raw.update(status='FAIL' if error else 'PASS', error=error,
                   execution_end_qpc_ns=time.perf_counter_ns())
        # Keep the timeout record before invoking termination; partial query
        # checkpoints were written by the worker before every blocking boundary.
        try:
            durable_json(path, raw)
        finally:
            deadline = time.monotonic() + cleanup_timeout
            cleanup = raw['cleanup'] = {'tree_exited': False, 'active_processes': None, 'errors': []}
            try:
                if assigned:
                    if job.active():
                        job.terminate()
                elif process is not None and process.poll() is None:
                    # Assignment failed: the unopened gate guarantees no children.
                    process.kill()
                while True:
                    active = job.active() if job else 0
                    exited = process is None or process.poll() is not None
                    cleanup.update(active_processes=active, tree_exited=exited and active == 0)
                    if cleanup['tree_exited']:
                        break
                    if time.monotonic() >= deadline:
                        raise StrictFrameError('P7 owned tree termination confirmation timeout')
                    time.sleep(min(0.01, max(0, deadline - time.monotonic())))
            except Exception as exc:
                cleanup['errors'].append(f'{type(exc).__name__}: {exc}')
            finally:
                if process is not None and process.stdin and not process.stdin.closed:
                    process.stdin.close()
                if job:
                    try:
                        job.close()
                    except Exception as exc:
                        cleanup['errors'].append(f'job close: {exc}')
            if not cleanup['tree_exited'] or cleanup['errors']:
                raw['status'] = 'FAIL'
                raw['error'] = (error or '') + '; owned tree cleanup failed: ' + repr(cleanup)
            raw['end_qpc_ns'] = time.perf_counter_ns()
            durable_json(path, raw)
    if raw['status'] != 'PASS':
        raise StrictFrameError(raw['error'])
    return raw


def p7_worker_main(request_path: Path) -> int:
    # This must precede module loading, HWNDs, threads and all child creation.
    if sys.stdin.buffer.readline() != b'P7_GO\n':
        return 2
    request = json.loads(request_path.read_text(encoding='utf-8'))
    sys.path.insert(0, request['scripts'])
    spec = importlib.util.spec_from_file_location('gx_perf_p7_worker', request['collector'])
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module.SCRIPTS = Path(request['scripts'])
    import gx_win_gui as gui
    report = request['report']
    result = {'status': 'FAIL', 'report': report}
    try:
        if not p7_input_epoch(report['worker_entry_input_tick'], module.last_input_ticks()[0], report, 'gate'):
            raise module.PerfError('input arrived across P7 worker gate', cause='foreign_input')
        result['lines'] = module.measure_win32(gui, Path(request['exe']), Path(request['env_dir']),
            request['config'], request['resizes'], request['env'], report)
        result['status'] = 'PASS'
    except Exception as exc:
        result.update(error=f'{type(exc).__name__}: {exc}', failure_cause=getattr(exc, 'cause', None))
        if getattr(exc, 'instance_pid', None) is not None:
            report['pid'] = exc.instance_pid
    finally:
        durable_json(request_path.with_name('worker-result.json'), result)
    return 0 if result['status'] == 'PASS' else 1


def close_p7_instance(gui, instance, timeout=5.0):
    """Graceful close only. Forced termination belongs solely to the parent Job."""
    instance.ensure_owned()
    instance.closing = True
    for info in instance.windows():
        if info.cls == gui.WINDOW_CLASS:
            gui.win32().PostMessageW(info.hwnd, gui.WM_CLOSE, 0, 0)
    deadline = time.monotonic() + timeout
    while instance.alive():
        if time.monotonic() >= deadline:
            raise StrictFrameError('P7 graceful instance cleanup timed out')
        time.sleep(0.01)


def present_frame(word: int) -> dict:
    word &= (1 << 64) - 1  # LRESULT is signed; the wire word is not.
    return {'word': word, 'sequence': word >> 32,
            'size': [word & 0xffff, (word >> 16) & 0xffff],
            'size_supported': (word & 0xffffffff) != 0xffff0000}


def present_advanced(before: int, after: int) -> bool:
    # RFC1982-style half-range ordering; reset/backwards/ambiguous is never progress.
    return 0 < ((after - before) & 0xffffffff) < 0x80000000


class PresentQuery:
    """GUI messages only. No renderer lock, GL, WM_NULL or log-derived frame ACK."""
    def __init__(self, gui, instance, raw: dict):
        self.gui, self.instance, self.raw = gui, instance, raw
        self.w = gui.win32()
        self.hwnd = instance.require_window().hwnd
        self.pid, self.birth = instance.pid, instance.creation
        raw.update(protocol='GXP7/v1', queries=[], snapshots=[])

    def query(self, selector, argument, deadline):
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            raise StrictFrameError('strict_final_frame_timeout')
        answer = self.w.send_message(self.hwnd, P7_QUERY, selector, argument,
                                     timeout_ms=max(1, math.ceil(remaining * 1000)))
        self.raw['queries'].append({'selector': selector, 'argument': argument,
                                    'answer': answer, 'qpc_ns': time.perf_counter_ns()})
        if answer is None:
            raise StrictFrameError('P7 query did not respond')
        if time.perf_counter() >= deadline:
            raise StrictFrameError('strict_final_frame_timeout')
        return answer & ((1 << 64) - 1)

    def owned_geometry(self):
        self.instance.ensure_owned()
        if (self.instance.pid != self.pid or self.instance.creation != self.birth or
                self.w.process_creation(self.pid) != self.birth or
                self.instance.require_window().hwnd != self.hwnd or
                self.w.window_pid(self.hwnd) != self.pid):
            raise StrictFrameError('P7 PID birth or top HWND changed')
        terminals = []
        for terminal in self.instance.terminals(self.instance.require_window()):
            if self.w.window_pid(terminal.hwnd) != self.pid:
                raise StrictFrameError('P7 foreign terminal HWND')
            rect = self.w.RECT()
            if not self.w.GetClientRect(terminal.hwnd, ctypes.byref(rect)):
                raise StrictFrameError('P7 GetClientRect failed')
            terminals.append({'hwnd': terminal.hwnd,
                              'rect': list(self.w.raw_window_rect(terminal.hwnd)),
                              'client': [rect.right - rect.left, rect.bottom - rect.top]})
        return {'pid': self.pid, 'birth': self.birth, 'hwnd': self.hwnd,
                'outer': list(self.w.raw_window_rect(self.hwnd)),
                'terminals': sorted(terminals, key=lambda item: item['hwnd'])}

    def snapshot(self, stage, deadline):
        sample = {'stage': stage, 'qpc_ns': time.perf_counter_ns(), 'leaves': []}
        self.raw['snapshots'].append(sample)  # Keep partial replies on every failure.
        sample['geometry'] = self.owned_geometry()
        descriptor = self.query(19, 0, deadline)
        sample['descriptor'] = descriptor
        if descriptor == 0:
            sample.update(supported=False, reason='query_absent_or_gate_disabled')
        elif descriptor >> 32 != P7_MAGIC or (descriptor >> 16) & 0xffff != 1:
            sample.update(supported=False, reason='protocol_version_unsupported')
        else:
            count = self.query(13, 0, deadline)
            if not 1 <= count <= 64 or count != len(sample['geometry']['terminals']):
                raise StrictFrameError('P7 visible leaf topology mismatch')
            sample['supported'] = True
            for index in range(1, count + 1):
                def metadata():
                    return [self.query(19, (index << 8) | field, deadline) for field in range(8)]
                meta = metadata()
                leaf = {'index': index, 'metadata': meta}
                sample['leaves'].append(leaf)
                leaf['frame'] = present_frame(self.query(17, index, deadline))
                target = self.query(18, index, deadline)
                leaf['target'] = [target & 0xffffffff, target >> 32]
                if metadata() != meta or self.query(18, index, deadline) != target:
                    raise StrictFrameError('P7 leaf identity/geometry changed during query')
                status = meta[0] & 0xffff
                if meta[0] >> 32 != P7_MAGIC or (meta[0] >> 16) & 0xffff != 1 or status != 1:
                    sample.update(supported=False, reason=P7_UNSUPPORTED.get(status, 'protocol_unsupported'))
                    continue
                if not all(meta[2:]):
                    raise StrictFrameError('P7 missing surface lifetime/attachment identity')
                client = [meta[1] & 0xffffffff, meta[1] >> 32]
                terminal = next((t for t in sample['geometry']['terminals'] if t['hwnd'] == meta[7]), None)
                if terminal is None or client != terminal['client']:
                    raise StrictFrameError('P7 GUI client does not match GetClientRect')
                if (not leaf['frame']['size_supported'] or
                        any(n <= 0 or n > 65535 for n in leaf['target'] + client)):
                    sample.update(supported=False, reason='size_unsupported')
            if self.query(13, 0, deadline) != count:
                raise StrictFrameError('P7 leaf count changed during query')
            if sample['supported'] and len({leaf['metadata'][7] for leaf in sample['leaves']}) != count:
                raise StrictFrameError('P7 duplicate terminal identity')
        if self.owned_geometry() != sample['geometry']:
            raise StrictFrameError('P7 geometry changed during query')
        if time.perf_counter() >= deadline:
            raise StrictFrameError('strict_final_frame_timeout')
        return sample


def _present_identity(sample):
    geometry = sample['geometry']
    return ([geometry[key] for key in ('pid', 'birth', 'hwnd')],
            [terminal['hwnd'] for terminal in geometry['terminals']],
            [(leaf['index'], leaf['metadata'][2:]) for leaf in sample['leaves']])


def _present_matches(baseline, target, sample):
    if not sample['supported'] or _present_identity(sample) != _present_identity(baseline):
        raise StrictFrameError('P7 surface lifetime/attachment or support changed')
    if (sample['geometry'] != target['geometry'] or
            [leaf['target'] for leaf in sample['leaves']] != [leaf['target'] for leaf in target['leaves']]):
        raise StrictFrameError('P7 final target geometry changed')
    return all(present_advanced(old['frame']['sequence'], new['frame']['sequence']) and
               new['frame']['size'] == new['target']
               for old, new in zip(baseline['leaves'], sample['leaves']))


def _present_not_regressed(previous, current):
    for old, new in zip(previous['leaves'], current['leaves']):
        a, b = old['frame']['sequence'], new['frame']['sequence']
        if a != b and not present_advanced(a, b):
            raise StrictFrameError('P7 frame sequence reset/backwards')


def dwm_flush() -> None:
    dll = ctypes.WinDLL('dwmapi', use_last_error=True)
    dll.DwmFlush.argtypes = []
    dll.DwmFlush.restype = ctypes.c_long
    result = dll.DwmFlush()
    if result != 0:
        raise StrictFrameError(f'DwmFlush failed: {result & 0xffffffff:#x}')


def strict_resize_capture(gui, instance, width: int, height: int, png: Path,
                          backdrop, raw: dict, timeout: float = 2.0, *, round_deadline=None) -> float:
    """All visible leaves, sampled BEFORE SetWindowPos. Raw survives raised errors.

    A legacy/disabled baseline is PENDING, with a protected diagnostic image;
    it never acquires strict proof by waiting. timeout is ONLY the post-resize
    frame-match query budget. The supervised worker bounds the entire round,
    including synchronous DwmFlush/capture/save and cleanup. No first-frame claim.
    """
    raw.update(status='running', strict_final_frame=False, visual_review='PENDING',
               requested_outer_px=[width, height], limits=dict(P7_LIMITS))
    png.parent.mkdir(parents=True, exist_ok=True)
    def checkpoint(stage):
        raw['checkpoint_stage'] = stage
        durable_json(png.with_name(f'{png.stem}.{stage}.query.json'), raw)
    if round_deadline is None:
        round_deadline = time.perf_counter() + P7_LIMITS['round_seconds']
    raw['round_deadline_qpc'] = round_deadline
    try:
        if (not math.isfinite(timeout) or timeout <= 0 or not math.isfinite(round_deadline) or
                backdrop is None or backdrop.color is None):
            raise StrictFrameError('P7 requires a finite deadline and privacy backdrop')
        instance.ensure_foreground()
        probe = PresentQuery(gui, instance, raw)
        baseline = probe.snapshot('before_setwindowpos', min(round_deadline, time.perf_counter() + timeout))
        raw['baseline_qpc_ns'] = time.perf_counter_ns()
        checkpoint('before_setwindowpos')
        elapsed = instance.resize(width, height)
        raw.update(setwindowpos_ms=elapsed, setwindowpos_return_qpc_ns=time.perf_counter_ns())
        deadline = min(round_deadline, time.perf_counter() + timeout)
        raw['frame_match_deadline_qpc'] = deadline
        target = probe.snapshot('after_setwindowpos', deadline)
        rect = target['geometry']['outer']
        if [rect[2] - rect[0], rect[3] - rect[1]] != [width, height]:
            raise StrictFrameError('P7 SetWindowPos target size not reached')
        if _present_identity(baseline) != _present_identity(target):
            raise StrictFrameError('P7 identity changed across SetWindowPos')
        supported = baseline['supported'] and target['supported']
        if baseline['supported'] and not target['supported']:
            raise StrictFrameError('P7 query support lost after SetWindowPos')
        sample = target
        if supported:
            _present_not_regressed(baseline, target)
            while not _present_matches(baseline, target, sample):
                if time.perf_counter() >= deadline:
                    raise StrictFrameError('strict_final_frame_timeout')
                time.sleep(min(0.001, max(0, deadline - time.perf_counter())))
                previous = sample
                sample = probe.snapshot('poll', deadline)
                _present_not_regressed(previous, sample)
            raw['matched'] = sample
        else:
            raw.update(status='PENDING', reason=baseline.get('reason') or target.get('reason'))
        checkpoint('before_dwm_flush')
        dwm_flush()
        raw['dwm_flush_qpc_ns'] = time.perf_counter_ns()
        before = probe.snapshot('before_capture', round_deadline)
        if supported:
            _present_not_regressed(sample, before)
            if not _present_matches(baseline, target, before):
                raise StrictFrameError('P7 frame no longer matches before capture')
        elif before['geometry'] != target['geometry'] or _present_identity(before) != _present_identity(target):
            raise StrictFrameError('P7 diagnostic geometry/identity changed before capture')
        png.parent.mkdir(parents=True, exist_ok=True)
        raw['capture_begin_qpc_ns'] = time.perf_counter_ns()
        checkpoint('before_capture')
        backdrop.capture(instance, instance.require_window(), 'screen', png.name).save_png(png)
        raw.update(capture_end_qpc_ns=time.perf_counter_ns(), screenshot=str(png),
                   screenshot_sha256=hashlib.sha256(png.read_bytes()).hexdigest())
        after = probe.snapshot('after_capture', round_deadline)
        if supported:
            _present_not_regressed(before, after)
            if not _present_matches(baseline, target, after):
                raise StrictFrameError('P7 frame no longer matches after capture')
            raw.update(status='PASS', strict_final_frame=True)
        elif after['geometry'] != before['geometry'] or _present_identity(after) != _present_identity(before):
            raise StrictFrameError('P7 diagnostic geometry/identity changed during capture')
        return elapsed
    except Exception as exc:
        raw.update(status='FAIL', strict_final_frame=False, error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        raw['end_qpc_ns'] = time.perf_counter_ns()
        checkpoint('final')


def append_json(path: Path, row: dict) -> None:
    with path.open('a', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(row, ensure_ascii=False) + '\n')


def read_rows(path: Path) -> list[dict]:
    if not path.exists():
        return []
    # A writer may be between write and flush. Never parse an incomplete record.
    data = path.read_bytes()
    return [json.loads(line) for line in data[:data.rfind(b'\n') + 1].splitlines()]


def output_payload(command: dict) -> bytes:
    size = command['bytes']
    if not isinstance(size, int) or isinstance(size, bool) or not 64 <= size <= 1048576:
        raise ValueError('invalid stimulus byte count')
    prefix = ('GX-C7-' + command['id'] + ' ').encode('ascii')
    return (prefix * (size // len(prefix) + 1))[:size - 2] + b'\r\n'


def kitty_animation_payload() -> bytes:
    # graphics_exec.zig's tested 1x1 RGB red/blue animation, displayed at 8x4 cells.
    # q=2 suppresses protocol replies; no console output is needed after setup.
    commands = ('a=T,f=24,s=1,v=1,i=7,c=8,r=4,q=2;/wAA',
                'a=f,i=7,f=24,s=1,v=1,z=250,q=2;AAD/',
                'a=a,i=7,r=1,z=250,s=3,v=1,q=2')  # v=1 encodes infinite loops.
    return b''.join(b'\x1b_G' + cmd.encode('ascii') + b'\x1b\\' for cmd in commands)


def current_python_image() -> str:
    """Resolve this running interpreter, never a PATH search or a base-path hint."""
    path = sys.executable
    if sys.platform == 'win32':
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        filename = kernel.GetModuleFileNameW
        filename.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32]
        filename.restype = ctypes.c_uint32
        buffer = ctypes.create_unicode_buffer(32768)
        length = filename(None, buffer, len(buffer))
        # GetModuleFileNameW counts UTF-16 code units, not Python code points.
        units = len(buffer.value.encode('utf-16-le')) // 2
        if not 0 < length < len(buffer) or length != units:
            raise ValueError('cannot resolve current Python process image')
        path = buffer.value
    if not path or not Path(path).is_absolute():
        raise ValueError('current Python process image path is empty or relative')
    image = Path(path).resolve(strict=True)
    if not image.is_file():
        raise ValueError('current Python process image is not a file')
    return str(image)


def python_identity() -> dict:
    image = current_python_image()
    return dict(executable=image, executable_sha256=hashlib.sha256(Path(image).read_bytes()).hexdigest(),
                launcher=sys.executable,
                launcher_sha256=hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest())


def console_output_utf8() -> dict:
    """Set only this helper's attached console output code page, before output."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetStdHandle.argtypes, kernel.GetStdHandle.restype = [ctypes.c_uint32], ctypes.c_void_p
    kernel.GetConsoleMode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    kernel.GetConsoleMode.restype = ctypes.c_int
    kernel.GetConsoleOutputCP.argtypes, kernel.GetConsoleOutputCP.restype = [], ctypes.c_uint32
    kernel.SetConsoleOutputCP.argtypes, kernel.SetConsoleOutputCP.restype = [ctypes.c_uint32], ctypes.c_int
    handle = kernel.GetStdHandle(0xfffffff5)  # STD_OUTPUT_HANDLE
    mode = ctypes.c_uint32()
    if not handle or handle == ctypes.c_void_p(-1).value or not kernel.GetConsoleMode(handle, ctypes.byref(mode)):
        raise OSError('stimulus stdout is not an attached console')
    before = kernel.GetConsoleOutputCP()
    if not before:
        raise OSError('GetConsoleOutputCP failed before UTF-8 setup')
    if not kernel.SetConsoleOutputCP(65001):
        raise OSError(f'SetConsoleOutputCP(65001) failed; before={before}')
    after = kernel.GetConsoleOutputCP()
    if after != 65001:
        raise OSError(f'console output UTF-8 readback mismatch: before={before}, after={after}')
    return dict(before=before, after=after, set_success=True, stdout_mode=mode.value)


def shell_main(directory: Path, token: str) -> int:
    """Polling affects this owned helper, not the measured Ghostty CPU counter."""
    import msvcrt
    msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)  # Byte receipts must include exactly the bytes emitted.
    output_cp = console_output_utf8()
    pid = os.getpid()
    receipt = directory / f'shell-{pid}.jsonl'
    def record(event, **fields):
        append_json(receipt, dict(event=event, pid=pid, token=token,
                                 time_ns=time.time_ns(), qpc_ns=time.perf_counter_ns(), **fields))
    os.write(sys.stdout.fileno(), b'GX C7 owned console\r\n')
    record('ready', console_output_cp=output_cp, **python_identity())
    seen = set()
    while True:
        while msvcrt.kbhit():
            record('input', text=msvcrt.getwch())
        for path in sorted(directory.glob('command-*.json')):
            if path.name in seen:
                continue
            command = json.loads(path.read_text(encoding='utf-8'))
            if command['token'] != token:
                raise ValueError('foreign stimulus token')
            seen.add(path.name)
            if command['action'] == 'stop':
                record('stopped')
                return 0
            if command['action'] not in ('output', 'kitty-animation'):
                raise ValueError('unknown stimulus action')
            payload = output_payload(command) if command['action'] == 'output' else kitty_animation_payload()
            began = time.perf_counter_ns()
            offset = 0
            while offset < len(payload):
                written = os.write(sys.stdout.fileno(), payload[offset:])
                if written <= 0:
                    raise OSError('console write made no progress')
                offset += written
            record(command['action'], id=command['id'], requested_bytes=len(payload), written_bytes=offset,
                   write_begin_qpc_ns=began, sha256=hashlib.sha256(payload).hexdigest())
        time.sleep(0.05)


class OwnedShells:
    def __init__(self, directory: Path):
        self.python_identity = python_identity()
        self.directory = directory
        directory.mkdir()
        self.token = uuid.uuid4().hex
        self.identities = {}

    def config(self) -> str:
        # Exec.execCommand parses Windows shell-form argv without cmd.exe /c.
        # direct: naively splits spaces, so cannot represent these quoted paths.
        argv = [self.python_identity['executable'], str(Path(__file__).resolve()), '--shell',
                str(self.directory.resolve()), '--token', self.token]
        return 'command = ' + subprocess.list2cmdline(argv) + '\n'

    def rows(self) -> list[dict]:
        rows = [row for path in sorted(self.directory.glob('shell-*.jsonl')) for row in read_rows(path)]
        if any(row.get('token') != self.token for row in rows):
            raise ValueError('foreign shell receipt token')
        return rows

    def ready(self, gui, instance, expected: int) -> bool:
        ready = [row for row in self.rows() if row['event'] == 'ready']
        if len(ready) != expected:
            return False
        w = gui.win32()
        for row in ready:
            pid = row['pid']
            birth = w.process_creation(pid)
            image = self.python_identity['executable']
            if (not instance.contains_pid(pid) or birth is None or
                    not gui.same_path(w.process_image(pid) or '', image) or
                    not gui.same_path(row.get('executable') or '', image) or
                    row.get('executable_sha256') != self.python_identity['executable_sha256']):
                raise ValueError('stimulus shell identity is not an owned Python descendant')
            self.identities[pid] = birth
        return True

    def verify(self, gui, instance):
        for pid, birth in self.identities.items():
            if (not instance.contains_pid(pid) or gui.win32().process_creation(pid) != birth or
                    not gui.same_path(gui.win32().process_image(pid) or '', self.python_identity['executable'])):
                raise ValueError('stimulus shell ended or changed identity')

    def command(self, action: str, **fields) -> dict:
        command = dict(action=action, token=self.token, id=uuid.uuid4().hex,
                       time_ns=time.time_ns(), qpc_ns=time.perf_counter_ns(), **fields)
        path = self.directory / ('command-' + command['id'] + '.json')
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(command), encoding='utf-8', newline='\n')
        temporary.replace(path)
        return command

    def output_receipts(self, command: dict, end_qpc_ns: int | None = None) -> list[dict]:
        rows = [row for row in self.rows() if row['event'] == 'output' and row['id'] == command['id']]
        if len({row['pid'] for row in rows}) != len(rows):
            raise ValueError('duplicate output receipt')
        for row in rows:
            if row['pid'] not in self.identities or row['written_bytes'] != command['bytes']:
                raise ValueError('wrong output writer or byte count')
            if (row['requested_bytes'] != command['bytes'] or
                    row['sha256'] != hashlib.sha256(output_payload(command)).hexdigest()):
                raise ValueError('output payload digest differs from requested bytes')
            if not command['qpc_ns'] <= row['write_begin_qpc_ns'] <= row['qpc_ns']:
                raise ValueError('output receipt predates command or write')
            if end_qpc_ns is not None and row['qpc_ns'] > end_qpc_ns:
                raise ValueError('output receipt falls outside measurement window')
        return rows


def ime_state(gui, instance) -> dict:
    """Only inspect the target's existing layout and default IMM window."""
    instance.ensure_foreground()
    w = gui.win32()
    hwnd = instance.focused_terminal()
    layout = w.keyboard_layout(hwnd)
    result = {'terminal_hwnd': hwnd, 'layout': f'0x{layout:08x}',
              'layout_changed': False, 'input_method': 'physical VK letters, never Unicode injection'}
    if layout & 0xffff != 0x0804:
        result.update(status='PENDING', reason='owned target thread is not already using zh-CN; no layout switch permitted')
        return result
    imm = ctypes.WinDLL('imm32')
    fn = imm.ImmGetDefaultIMEWnd
    fn.argtypes, fn.restype = [ctypes.c_void_p], ctypes.c_void_p
    ime = fn(hwnd)
    if not ime or w.window_pid(ime) != instance.pid:
        result.update(status='PENDING', reason='no owned IMM default IME window (TSF-only provider may not expose it)')
        return result
    result.update(ime_hwnd=ime, open=w.send_message(ime, 0x283, 5),
                  conversion=w.send_message(ime, 0x283, 1))  # IMC_GETOPENSTATUS / GETCONVERSIONMODE
    if result['open'] != 1 or result['conversion'] is None or not result['conversion'] & 1:
        result.update(status='PENDING', reason='existing IME is not open in native Chinese mode; tool does not change it')
    else:
        result['status'] = 'ready'
    return result


class PdhFailure(RuntimeError):
    def __init__(self, operation, status):
        self.operation, self.status = operation, status
        self.unavailable = status in (0x800007D1, 0x800007D5, 0xC0000BB8, 0xC0000BB9)
        super().__init__(f'{operation}: PDH status 0x{status:08x}')


class PdhThreads:
    """One live query, sampled periodically. English counter API is locale independent.

    Raw Context Switches/sec FirstValue is a cumulative per-thread count. PID,
    TID and Elapsed Time's start counter join the samples, never instance name
    alone. Thread churn is retained and makes the interval partial, not zero.
    """
    def __init__(self):
        self.query = ctypes.c_void_p()
        self.counters = {}
        dll = ctypes.WinDLL('pdh')
        dword, handle = ctypes.c_uint32, ctypes.c_void_p
        def bind(name, *args):
            fn = getattr(dll, name)
            fn.argtypes, fn.restype = list(args), dword
            return fn
        self.open = bind('PdhOpenQueryW', ctypes.c_wchar_p, ctypes.c_size_t, ctypes.POINTER(handle))
        self.add = bind('PdhAddEnglishCounterW', handle, ctypes.c_wchar_p, ctypes.c_size_t, ctypes.POINTER(handle))
        self.collect = bind('PdhCollectQueryData', handle)
        self.array = bind('PdhGetRawCounterArrayW', handle, ctypes.POINTER(dword), ctypes.POINTER(dword), ctypes.c_void_p)
        self.close_query = bind('PdhCloseQuery', handle)
        try:
            self.check('PdhOpenQueryW', self.open(None, 0, ctypes.byref(self.query)))
            for name, path in PDH_PATHS.items():
                counter = handle()
                self.check(path, self.add(self.query, path, 0, ctypes.byref(counter)))
                self.counters[name] = counter
        except Exception:
            self.close()
            raise

    @staticmethod
    def check(operation, status):
        if status:
            raise PdhFailure(operation, status)

    def sample(self) -> dict:
        dword = ctypes.c_uint32
        class Raw(ctypes.Structure):
            _fields_ = [('status', dword), ('timestamp', dword * 2), ('first', ctypes.c_int64),
                        ('second', ctypes.c_int64), ('multi', dword)]
        class Item(ctypes.Structure):
            _fields_ = [('name', ctypes.c_wchar_p), ('raw', Raw)]
        result = {'qpc_begin_ns': time.perf_counter_ns(), 'time_ns': time.time_ns(), 'arrays': {}}
        self.check('PdhCollectQueryData', self.collect(self.query))
        for name, counter in self.counters.items():
            for attempt in range(4):
                size, count = dword(), dword()
                status = self.array(counter, ctypes.byref(size), ctypes.byref(count), None)
                if status != 0x800007D2 or not size.value:
                    raise PdhFailure('PdhGetRawCounterArrayW size ' + name, status)
                buffer = ctypes.create_string_buffer(size.value)
                status = self.array(counter, ctypes.byref(size), ctypes.byref(count), buffer)
                if status == 0x800007D2 and attempt < 3:
                    continue
                self.check('PdhGetRawCounterArrayW ' + name, status)
                if count.value == 0:
                    raise PdhFailure('empty PDH array ' + name, 0x800007D1)
                if count.value * ctypes.sizeof(Item) > size.value or size.value > ctypes.sizeof(buffer):
                    raise ValueError('PDH array count exceeds returned buffer')
                result['arrays'][name] = [dict(name=item.name, status=item.raw.status,
                    first=item.raw.first, second=item.raw.second, multi=item.raw.multi,
                    timestamp_100ns=(item.raw.timestamp[1] << 32) | item.raw.timestamp[0])
                    for item in ctypes.cast(buffer, ctypes.POINTER(Item * count.value)).contents]
                break
        result['qpc_end_ns'] = time.perf_counter_ns()
        return result

    def close(self):
        if self.query.value:
            self.close_query(self.query)
            self.query = ctypes.c_void_p()


def pdh_owned(sample: dict, pid: int) -> dict:
    arrays = {}
    for counter in PDH_PATHS:
        rows = sample['arrays'][counter]
        arrays[counter] = {row['name']: row for row in rows}
        if len(arrays[counter]) != len(rows):
            raise ValueError('duplicate PDH instance name')
    result = {}
    for name, row in arrays['pid'].items():
        if row['status'] not in (0, 1):
            raise ValueError('PDH ID Process unavailable; ownership cannot be determined')
        if row['first'] != pid:
            continue
        fields = [arrays[key].get(name) for key in PDH_PATHS]
        if any(item is None or item['status'] not in (0, 1) for item in fields):
            raise ValueError('owned PDH counter missing or invalid')
        identity = (arrays['tid'][name]['first'], arrays['birth'][name]['first'])
        if identity in result or identity[0] <= 0:
            raise ValueError('invalid or duplicate PDH thread identity')
        result[identity] = arrays['switches'][name]
    if not result:
        raise ValueError('no PDH thread counters for owned PID')
    return result


def pdh_summary(samples: list[dict], pid: int) -> dict:
    result = {'status': 'PENDING', 'n': 0, 'unit': '', 'intervals': [],
              'source': PDH_PATHS, 'pid': pid,
              'scope': 'periodic PDH thread counters; sub-sample thread lifetimes remain unobservable'}
    try:
        if len(samples) < 2:
            raise ValueError('PDH requires at least two samples')
        previous = pdh_owned(samples[0], pid)
        total = 0
        for sample in samples[1:]:
            current = pdh_owned(sample, pid)
            matched = previous.keys() & current.keys()
            deltas = []
            for key in matched:
                old, new = previous[key], current[key]
                delta = new['first'] - old['first']
                if delta < 0 or new['timestamp_100ns'] <= old['timestamp_100ns']:
                    raise ValueError('PDH counter regressed or timestamp did not advance')
                deltas.append(delta)
            result['intervals'].append({'matched_switches': sum(deltas), 'matched_threads': len(matched),
                'added': sorted(current.keys() - previous.keys()), 'removed': sorted(previous.keys() - current.keys())})
            total += sum(deltas)
            previous = current
        if any(row['added'] or row['removed'] for row in result['intervals']):
            raise ValueError('PDH thread set changed; complete process switch count unavailable')
        result.update(status='sampled', n=1, switches=total, sample_count=len(samples))
    except (KeyError, ValueError) as exc:
        result['reason'] = str(exc)
    return result


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--p7-worker':
        raise SystemExit(p7_worker_main(Path(sys.argv[2])))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shell', type=Path, required=True)
    parser.add_argument('--token', required=True)
    options = parser.parse_args()
    raise SystemExit(shell_main(options.shell, options.token))
