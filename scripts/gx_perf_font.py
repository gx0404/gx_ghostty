"""C6 owned console and evidence checks, sharing gx_perf's AB/BA lifecycle.

GX-0056 measures ordinary fallback through uncached raster plus atlas availability.
The discovery timer remains a separate diagnostic. Completion requires the fixed
single-codepoint stimulus, source receipts and a complete ordered identity chain.
GPU upload/present and the default mapped-family user path are outside this scope.
"""
from __future__ import annotations

import hashlib
import json
import os
import math
import re
import statistics
from pathlib import Path
import subprocess
import sys
import time

if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_perf_stimulus as stimulus

READY = b'GX C6 ASCII READY\r\n'
# Put the only CJK codepoint at column zero of its own row: no preceding
# Latin run may resolve it speculatively while finding its font boundary.
PAYLOAD = 'GX C6 CJK:\r\n中\r\n'.encode('utf-8')
SOURCE = 'src/font/directwrite/discovery.zig'
SCOPE = 'c6-ordinary-fallback-raster-ready-v1'
PREFIX = 'font.first_cjk_fallback.'
METRIC = PREFIX + 'raster_ready'
EVENTS = ('started', 'codepoint', 'request', 'grid', 'font_index', 'glyph',
          'bound', 'raster_ready', 'completed')
STARTUP_FILE = 'startup-observation.json'


def reject(message, cause='c6_evidence_unproved'):
    from gx_perf import PerfError
    raise PerfError(message, cause=cause)


def validate_source_delta(warm: str, cold: str) -> None:
    needle = '    pub fn warmup() void {'
    if warm.count(needle) != 1 or cold != warm.replace(needle, '    fn warmup() void {', 1):
        reject('C6 source must differ only by pub fn warmup -> fn warmup')


def validate_manifest(args, exes, labels) -> dict:
    """Check Git objects and root's build attestations, never infer source from exe names."""
    if (args.runs != 10 or labels != ['warmup', 'no-warmup'] or len(exes) != 2 or
            args.config or args.env or args.label_env or args.diagnostic or args.uninstrumented):
        reject('C6 requires ten pairs, labels warmup/no-warmup, fixed config/environment, both instrumented')
    data = json.loads(args.font_manifest.read_text(encoding='utf-8'))
    if data.get('schema') != 'gx-c6-builds-v2' or set(data.get('arms', {})) != set(labels):
        reject('C6 requires gx-c6-builds-v2 with both arms')
    if data.get('scope') != SCOPE:
        reject('C6 manifest must explicitly bind scope ' + SCOPE)
    repo = Path(data['repository']).resolve()
    def git(*argv):
        return subprocess.check_output(['git', '-C', str(repo), *argv]).decode('utf-8', errors='strict')
    sources = []
    commits = []
    for label, exe in zip(labels, exes):
        arm = data['arms'][label]
        commit = arm['source_commit']
        if len(commit) != 40 or any(c not in '0123456789abcdef' for c in commit):
            reject('C6 source_commit must be a full Git SHA')
        if (arm.get('optimize') != 'ReleaseFast' or arm.get('source_clean') is not True or
                arm.get('exe_sha256') != hashlib.sha256(exe.read_bytes()).hexdigest() or
                not arm.get('build_command') or not arm.get('build_log') or
                arm.get('source_exe_attested_by') != 'root'):
            reject('C6 requires root-attested clean ReleaseFast source/exe build receipts')
        log = Path(arm['build_log'])
        if not log.is_file() or hashlib.sha256(log.read_bytes()).hexdigest() != arm.get('build_log_sha256'):
            reject('C6 build log missing or hash mismatch')
        sources.append(git('show', f'{commit}:{SOURCE}'))
        commits.append(commit)
    if data.get('reference_commit') != commits[0] or data.get('instrumentation') != 'GX-0056':
        reject('C6 requires warmup arm at the root reference commit with GX-0056')
    changed = git('diff', '--name-only', commits[0], commits[1]).splitlines()
    if changed != [SOURCE]:
        reject('C6 whole-tree comparison contains changes other than warmup')
    validate_source_delta(*sources)
    build_options = [data['arms'][label].get('build_options') for label in labels]
    if (not isinstance(build_options[0], list) or build_options[0] != build_options[1] or
            '-Doptimize=ReleaseFast' not in build_options[0] or
            '-Dtarget=x86_64-windows-gnu' not in build_options[0]):
        reject('C6 requires identical ReleaseFast Windows build_options (exclude output prefix)')
    data['verified_source_diff'] = git('diff', commits[0], commits[1], '--', SOURCE)
    data['source_exe_binding'] = 'root build attestation; binary hash checked, not inferred from version'
    return data


def validate_discovery(before: str, after: str) -> float:
    from gx_perf import parse_text
    prior, current = parse_text(before), parse_text(after)
    timer, cp = 'font.first_fallback', 'font.first_fallback.codepoint'
    success = 'font.first_fallback.success'
    if any(prior.values.get(name) for name in (timer, cp, success)):
        reject('first fallback consumed before the explicit CJK trigger', 'c6_early_fallback')
    values = current.values.get(timer, [])
    if len(values) != 1:
        reject('first_fallback missing or duplicated', 'c6_fallback_count')
    if current.values.get(cp) != [ord('中')] or current.units.get(cp) != '':
        reject('first_fallback codepoint unproved: root must add claimed descriptor codepoint instrumentation',
               'c6_codepoint_unproved')
    if current.units.get(timer) != 'ms' or values[0] < 0:
        reject('first_fallback duration/unit invalid')
    if current.values.get(success) != [1] or current.units.get(success) != '':
        reject('first_fallback success missing, failed or duplicated', 'c6_discovery_not_completed')
    return values[0]


def target_events(text: str) -> list[tuple[str, str, str]]:
    """Strictly parse every formal line; malformed/unknown evidence cannot vanish."""
    result = []
    count = re.compile(r'(?:.*?\(gx_perf\):\s+)?metric ' + re.escape(PREFIX) + r'([a-z_]+) ([0-9]+)(?: (us|ms))?')
    timer = re.compile(r'.*?\(gx_perf\):\s+' + re.escape(PREFIX) + r'(raster_ready) ([0-9]+)(us|ms)')
    for line in text.splitlines():
        if PREFIX not in line:
            continue
        match = count.fullmatch(line.strip()) or timer.fullmatch(line.strip())
        if not match:
            reject('malformed formal C6 event', 'c6_target_malformed')
        name, value, unit = match.groups()
        result.append((name, value, unit or ''))
    return result


def validate_target(before: str, after: str) -> dict:
    if not after.startswith(before):
        reject('C6 log truncated or replaced')
    if target_events(before):
        reject('formal C6 claim consumed before trigger', 'c6_early_fallback')
    events = target_events(after)
    if any(name == 'rejected' for name, _, _ in events):
        reject('formal C6 request rejected: ' + repr(events), 'c6_target_rejected')
    if [name for name, _, _ in events] != list(EVENTS):
        reject('formal C6 chain missing, duplicated or out of order', 'c6_target_incomplete')
    values = {name: int(value) for name, value, _ in events}
    for name, _, unit in events:
        if (name == 'raster_ready' and unit not in ('us', 'ms')) or (name != 'raster_ready' and unit):
            reject('formal C6 time/count unit mismatch')
    if any(values[name] != 1 for name in ('started', 'request', 'grid', 'bound', 'completed')):
        reject('formal C6 process-once/grid identity invalid')
    if values['codepoint'] != ord('中') or not 0 <= values['font_index'] < 65536 or not 0 < values['glyph'] < 2**32:
        reject('formal C6 codepoint/font/glyph identity invalid', 'c6_codepoint_unproved')
    values['duration_ms'] = values['raster_ready'] / (1000 if events[-2][2] == 'us' else 1)
    if not math.isfinite(values['duration_ms']):
        reject('formal C6 nonfinite duration')
    return values


def validate_fallback(before: str, after: str) -> float:
    """Final-log hook used by gx_perf; discovery-only logs are rejected."""
    return validate_target(before, after)['duration_ms']


def distributions(values: list[float]) -> dict:
    ordered = sorted(values)
    if len(ordered) != 10 or any(not math.isfinite(x) for x in ordered):
        reject('C6 requires ten finite samples per arm')
    quartiles = statistics.quantiles(ordered, n=4, method='inclusive')
    return dict(n=10, median=statistics.median(ordered), p90=ordered[8],
                q1=quartiles[0], q3=quartiles[2], iqr=quartiles[2] - quartiles[0],
                quantiles='p90 nearest rank; quartiles inclusive linear interpolation')



def validate_arm(report: dict, manifest: dict) -> None:
    """Bind every checkpoint to the fixed, initially verified arm attestation."""
    arm = manifest['arms'][report['label']]
    if (report['font_build'] != arm or report['exe_sha256'] != arm['exe_sha256'] or
            hashlib.sha256(Path(report['exe']).read_bytes()).hexdigest() != arm['exe_sha256'] or
            hashlib.sha256(Path(arm['build_log']).read_bytes()).hexdigest() != arm['build_log_sha256']):
        reject('C6 executable/source/build receipt differs from fixed manifest arm')
    if 'c6' in report and report['c6']['source'] != arm:
        reject('C6 collected source differs from fixed manifest arm')


def startup_guard(run: dict, path: Path, *, collect: bool = False) -> float:
    """Read the GUI observer's independent raw endpoint, never an app metric.

    Pin its bytes at collection and re-read them at cleanup/finalize. The hash
    binds checkpoints, not authenticity: OS calls are the producer, with mocks
    used only in offline tests. P1's wall-clock FILETIME definition stays distinct
    from the native counter/trigger QPC endpoints below.
    """
    import gx_win_gui as gui
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate startup observation key: ' + key)
            result[key] = value
        return result
    try:
        raw = (path / STARTUP_FILE).read_bytes()
        observation = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object)
        shown = gui.startup_shown_ms(observation, pid=run['pid'], creation=run['creation'])
        recorded = run['startup_ms']['shown_ms']
        if type(recorded) not in (int, float) or recorded != shown:
            raise ValueError('startup_ms.shown_ms differs from raw observation')
        reference = dict(path=STARTUP_FILE, schema=gui.STARTUP_OBSERVATION_SCHEMA,
                         sha256=hashlib.sha256(raw).hexdigest())
        if collect:
            if 'startup_observation' in run['c6']:
                raise ValueError('startup observation already collected')
            run['c6']['startup_observation'] = reference
        elif run['c6']['startup_observation'] != reference:
            raise ValueError('startup observation changed since collection')
        return shown
    except (OSError, ValueError, KeyError, TypeError, gui.GuiError) as exc:
        reject('C6 startup observation: ' + str(exc))


def raw_guard_metrics(run: dict, path: Path) -> dict:
    """Derive guards from raw GUI observation and native counter endpoints."""
    shown = startup_guard(run, path)
    if any(type(run[key]) is not int or run[key] <= 0 for key in ('pid', 'creation')):
        reject('C6 launched process identity invalid')
    evidence = run['c6']
    before, after = evidence['commit_before'], evidence['commit_after']
    for endpoint in (before, after):
        for key in ('pid', 'birth', 'begin_ns', 'end_ns', 'private_bytes'):
            if type(endpoint[key]) is not int or endpoint[key] < (0 if key == 'private_bytes' else 1):
                reject('C6 native counter endpoint invalid: ' + key)
        if endpoint.get('error') or endpoint.get('errors'):
            reject('C6 native counter endpoint error')
        if (endpoint['pid'], endpoint['birth']) != (run['pid'], run['creation']):
            reject('C6 native counter PID/birth differs from launched process')
    times = [before['begin_ns'], before['end_ns'], evidence['trigger']['qpc_ns'],
             evidence['actual_output']['write_begin_qpc_ns'], evidence['actual_output']['qpc_ns'],
             after['begin_ns'], after['end_ns']]
    if any(type(t) is not int or t <= 0 for t in times) or times != sorted(times):
        reject('C6 native counter/trigger/output QPC order invalid')
    return {'startup.shown': shown, 'process.commit.before': before['private_bytes'],
            'process.commit.after': after['private_bytes'],
            'process.commit.delta': after['private_bytes'] - before['private_bytes']}


def validate_run_raw(run: dict, path: Path) -> dict:
    """Recheck byte continuity and the complete collected chain after cleanup."""
    before, after, final = [(path / name).read_bytes() for name in
                           ('before-cjk.log', 'after-cjk.log', 'ghostty.log')]
    if not after.startswith(before) or not final.startswith(after):
        reject('C6 raw before/after/final bytes truncated or replaced')
    before_text, after_text, final_text = [raw.decode('utf-8', errors='strict') for raw in (before, after, final)]
    if re.search(r'(?m)^.*\berror\(', final_text):
        reject('C6 final raw log contains an error')
    if 'startup.shown' in final_text:
        reject('C6 startup.shown belongs to GUI observation, not the app log')
    identity = validate_target(before_text, after_text)
    if identity != validate_target(before_text, final_text) or identity != run['c6']['identity']:
        reject('C6 full raw identity differs from collected identity')
    if target_events(after_text) != target_events(final_text):
        reject('C6 final raw event chain changed')
    return {METRIC: identity['duration_ms'], **raw_guard_metrics(run, path)}


def finalize_batch(batch: dict, out: Path) -> None:
    """Root wiring invokes this after all raw run reports and summaries are saved.

    It does not approve a performance change; quiet lease and human screenshot
    review remain separate. Failed/partial runs are never filtered or replaced.
    """
    from gx_perf import alternate
    labels = ['warmup', 'no-warmup']
    planned = [dict(run=n, label=label) for n, label in alternate(labels, 10)]
    summary = batch['c6'] = dict(scope=SCOPE, planned_order=planned,
        measurement_coverage='PENDING', visual_review='PENDING',
        performance_verdict='PENDING: root quiet evidence and screenshot review required')
    if not batch.get('valid'):
        batch['valid'], batch['exit'] = False, 1
        return
    try:
        if batch.get('errors'):
            reject('C6 batch contains errors')
        if [dict(run=r['run'], label=r['label']) for r in batch['runs']] != planned:
            reject('C6 actual AB/BA order or population differs from ten pairs')
        grouped = {label: {name: [] for name in (METRIC, 'startup.shown', 'process.commit.before',
                                                'process.commit.after', 'process.commit.delta')} for label in labels}
        for row in batch['runs']:
            path = (out / row['path']).resolve()
            if not path.is_relative_to(out.resolve()):
                reject('C6 run evidence outside batch directory')
            run = json.loads((path / 'run.json').read_text(encoding='utf-8'))
            if (row.get('errors') or row.get('failure_cause') or row.get('environment_pending') or
                    run.get('errors') or run.get('failure_cause') or run.get('environment_pending')):
                reject('C6 run contains errors')
            validate_arm(run, batch['font_manifest'])
            if (row['status'] != 'completed' or run['status'] != 'completed' or
                    run.get('label') != row['label'] or run.get('run') != row['run'] or
                    run.get('c6', {}).get('scope') != SCOPE or run['c6'].get('coverage') != 'captured'):
                reject('C6 run identity/coverage incomplete')
            raw_values = validate_run_raw(run, path)
            for name, samples in grouped[row['label']].items():
                metric = run['metrics'][name]
                if type(metric['n']) is not int or metric['n'] != 1 or metric['unit'] != ('ms' if name in (METRIC, 'startup.shown') else ''):
                    reject('C6 run metric count or unit invalid')
                if type(metric['median']) not in (int, float) or metric['median'] != raw_values[name]:
                    reject('C6 reduced metric differs from raw evidence: ' + name)
                samples.append(metric['median'])
        summary['distributions'] = {label: {name: distributions(xs) for name, xs in metrics.items()}
                                    for label, metrics in grouped.items()}
        summary['measurement_coverage'] = 'captured'
        summary['units'] = {METRIC: 'ms', 'startup.shown': 'ms', 'process.commit.*': 'bytes'}
    except (KeyError, ValueError, OSError, RuntimeError, TypeError, OverflowError) as exc:
        batch['valid'], batch['exit'] = False, 1
        batch.setdefault('errors', []).append('C6 final evidence: ' + str(exc))
        summary['failure'] = str(exc)


def shell_main(directory: Path, token: str) -> int:
    """No shell profiles, prompt, IME, keyboard echo or non-ASCII startup output."""
    import msvcrt
    msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
    receipt = directory / f'shell-{os.getpid()}.jsonl'
    def emit(event, payload, **fields):
        begin = time.perf_counter_ns()
        offset = 0
        while offset < len(payload):
            count = os.write(sys.stdout.fileno(), payload[offset:])
            if count <= 0:
                raise OSError('console write made no progress')
            offset += count
        stimulus.append_json(receipt, dict(event=event, pid=os.getpid(), token=token,
            qpc_ns=time.perf_counter_ns(), write_begin_qpc_ns=begin,
            written_bytes=offset, payload_hex=payload.hex(), **fields))
    emit('ready', READY, executable=sys.executable)
    seen = set()
    while True:
        for path in sorted(directory.glob('command-*.json')):
            if path.name in seen:
                continue
            command = json.loads(path.read_text(encoding='utf-8'))
            if command.get('token') != token or command.get('action') != 'cjk':
                raise ValueError('foreign or unsupported C6 command')
            if seen:
                raise ValueError('C6 permits exactly one CJK trigger per process')
            seen.add(path.name)
            emit('cjk', PAYLOAD, id=command['id'])
        time.sleep(0.01)


class OwnedFontShell(stimulus.OwnedShells):
    def config(self) -> str:
        argv = [sys.executable, '-I', str(Path(__file__).resolve()), '--shell',
                str(self.directory.resolve()), '--token', self.token]
        # -I excludes the script directory from imports; shell bootstrap below restores it.
        return ('command = ' + subprocess.list2cmdline(argv) + '\n'
                'shell-integration = none\nfont-family = JetBrains Mono\nfont-codepoint-map =\n')

    def receipt(self, command):
        rows = [row for row in self.rows() if row['event'] == 'cjk']
        if not rows:
            return None
        if len(rows) != 1:
            reject('duplicate CJK output receipt')
        row = rows[0]
        if (row['pid'] not in self.identities or row.get('id') != command['id'] or
                row.get('payload_hex') != PAYLOAD.hex() or row.get('written_bytes') != len(PAYLOAD) or
                not command['qpc_ns'] <= row['write_begin_qpc_ns'] <= row['qpc_ns']):
            reject('CJK output receipt identity/bytes/order mismatch')
        return row


def measure(gui, instance, capture, args, counters, shell):
    import gx_perf as perf
    report = capture.report
    evidence = report['c6'] = dict(scope=SCOPE, character='中', codepoint=ord('中'), payload_hex=PAYLOAD.hex(),
        original_target='ordinary fallback start through first uncached successful raster and atlas availability',
        default_user_path='not measured: GX CJK codepoint overrides explicitly reset in both arms',
        visual_review='PENDING', cache_scope='fresh process; OS font cache uncontrolled, AB/BA alternation',
        source=report['font_build'], shell_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        python_sha256=hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest(),
        commit_source='native GetProcessMemoryInfo PROCESS_MEMORY_COUNTERS_EX.PrivateUsage')
    startup_guard(report, capture.target, collect=True)
    perf.wait_until(lambda: shell.ready(gui, instance, 1), 'C6 owned ASCII shell ready')
    evidence['shell_identities'] = shell.identities.copy()
    ready = [row for row in shell.rows() if row['event'] == 'ready']
    if len(ready) != 1 or ready[0].get('payload_hex') != READY.hex() or ready[0].get('written_bytes') != len(READY):
        reject('ASCII readiness receipt mismatch')
    tick = perf.last_input_ticks()[0]
    def guard():
        perf.c7_input_check(gui, instance, args, tick)
        shell.verify(gui, instance)
    def pause(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            guard()
            time.sleep(0.05)
    pause(0.5)
    capture.screenshot('01-ascii-ready')
    before = capture.mark()
    (capture.target / 'before-cjk.log').write_bytes(before)
    evidence['commit_before'] = counters.sample(instance)
    if target_events(before.decode('utf-8')):
        reject('first fallback consumed during ASCII startup', 'c6_early_fallback')
    guard()
    evidence['trigger'] = command = shell.command('cjk')
    deadline = time.monotonic() + 10
    while not shell.receipt(command):
        guard()
        if time.monotonic() >= deadline:
            reject('CJK output receipt timeout', 'c6_output_timeout')
        time.sleep(0.05)
    evidence['actual_output'] = shell.receipt(command)
    deadline = time.monotonic() + 10
    while True:
        guard()
        raw = capture.mark().decode('utf-8', errors='strict')
        # Only parse settled complete lines while the producer can still write.
        events = target_events(raw[:raw.rfind('\n') + 1])
        if any(name in ('completed', 'rejected') for name, _, _ in events):
            validate_target(before.decode('utf-8'), raw)
            break
        if time.monotonic() >= deadline:
            reject('C6 claim did not finish raster/atlas; missing or unfinished chain', 'c6_target_incomplete')
        time.sleep(0.05)
    pause(0.5)
    evidence['commit_after'] = counters.sample(instance)
    guard()
    capture.screenshot('02-cjk-output')
    after = capture.mark()
    (capture.target / 'after-cjk.log').write_bytes(after)
    if not after.startswith(before):
        reject('C6 log truncated or replaced')
    evidence['generic_fallback_diagnostic'] = perf.parse_text(after.decode('utf-8')).values.get('font.first_fallback', [])
    if b'startup.shown' in after:
        reject('C6 startup.shown belongs to GUI observation, not the app log')
    for name, value in raw_guard_metrics(report, capture.target).items():
        if name == 'startup.shown':
            capture.add(name, value, 'ms')
        else:
            capture.add(name, value)
    evidence['identity'] = validate_target(before.decode('utf-8'), after.decode('utf-8'))
    capture.add(METRIC, evidence['identity']['duration_ms'], 'ms')
    evidence['coverage'] = 'captured'
    evidence['exclusions'] = ['GPU upload', 'present', 'default mapped-family user path']


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--shell', type=Path, required=True)
    parser.add_argument('--token', required=True)
    options = parser.parse_args()
    raise SystemExit(shell_main(options.shell, options.token))
