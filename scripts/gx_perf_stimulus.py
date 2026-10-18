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
import json
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


def shell_main(directory: Path, token: str) -> int:
    """Polling affects this owned helper, not the measured Ghostty CPU counter."""
    import msvcrt
    msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)  # Byte receipts must include exactly the bytes emitted.
    pid = os.getpid()
    receipt = directory / f'shell-{pid}.jsonl'
    def record(event, **fields):
        append_json(receipt, dict(event=event, pid=pid, token=token,
                                 time_ns=time.time_ns(), qpc_ns=time.perf_counter_ns(), **fields))
    os.write(sys.stdout.fileno(), b'GX C7 owned console\r\n')
    record('ready', executable=sys.executable)
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
        self.directory = directory
        directory.mkdir()
        self.token = uuid.uuid4().hex
        self.identities = {}

    def config(self) -> str:
        # Exec.execCommand parses Windows shell-form argv without cmd.exe /c.
        # direct: naively splits spaces, so cannot represent these quoted paths.
        argv = [sys.executable, str(Path(__file__).resolve()), '--shell',
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
            if not instance.contains_pid(pid) or birth is None or not gui.same_path(w.process_image(pid) or '', sys.executable):
                raise ValueError('stimulus shell identity is not an owned Python descendant')
            self.identities[pid] = birth
        return True

    def verify(self, gui, instance):
        for pid, birth in self.identities.items():
            if (not instance.contains_pid(pid) or gui.win32().process_creation(pid) != birth):
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shell', type=Path, required=True)
    parser.add_argument('--token', required=True)
    options = parser.parse_args()
    raise SystemExit(shell_main(options.shell, options.token))
