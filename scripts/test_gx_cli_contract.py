"""Offline C8 contract tests: synthetic sources, byte fixtures and fake CLI runner.

No real executable, GUI, compiler, shell, clipboard or registry is used. All
writes are under TemporaryDirectory; no historical evidence is mutated/read.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_cli_contract as contract


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / 'source'
        self.root.mkdir()
        self.web = self.base / 'webdata'
        self.web.mkdir()
        self.exe = self.base / 'ghostty.exe'
        self.exe.write_bytes(b'not executable: offline fixture')
        self.receipt = self.base / 'receipt.json'
        self.manifest = self.base / 'source.json'
        self.defaults = self.base / 'default-values.json'
        self.actions = ['help', 'version', 'show-config', 'explain-config', 'list-actions', 'toggle-quick-terminal']
        self.docs = {
            'window-vsync': 'Vsync.', 'link': 'Links.', 'quick-terminal-size': 'Quick size.',
            'gx-ctrl-scroll-zoom': 'Zoom.', 'gx-prompt-cursor': 'Cursor.'}
        types = {'window-vsync': 'bool = true', 'link': 'Links = .{}',
                 'quick-terminal-size': 'Size = .{}', 'gx-ctrl-scroll-zoom': 'bool = true',
                 'gx-prompt-cursor': 'gx_config_types.PromptCursor = .config'}
        sources = {name: '// identity fixture\n' for name in contract.TEXT_INPUTS}
        sources['src/config/Config.zig'] = ''.join('/// ' + doc + '\n@"' + key + '": ' + types[key] + ',\n'
                                                 for key, doc in self.docs.items())
        sources['src/gx/config_types.zig'] = 'pub const PromptCursor = enum {\n    config,\n    shell,\n};\n'
        sources['src/input/Binding.zig'] = ('pub const Action = union(enum) {\n'
                                          '    /// Crash.\n    crash: void,\n'
                                          '    /// GX.\n    gx: void,\n};\n')
        def zig_string(*lines):
            return '\n'.join('    ' + chr(92) * 2 + line for line in lines) + '\n'
        sources['src/input/helpgen_actions.zig'] = '.markdown =>\n' + zig_string('ACTIONS', '') + ',\n'
        sources['src/build/webgen/main_config.zig'] = '// Write the header\n' + zig_string('CONFIG', '') + ';\n'
        sources['src/build/webgen/main_commands.zig'] = '// Write the header\n' + zig_string('COMMANDS', '') + ';\n'
        sources['src/cli/ghostty.zig'] = ('pub const Action = enum {\n' +
                                       ''.join('    @"' + action + '",\n' for action in self.actions) + '};\n')
        for action in self.actions:
            sources['src/cli/' + action.replace('-', '_') + '.zig'] = (
                '/// ' + action + ' docs.\npub fn run() void {}\n')
        sources['src/cli/help.zig'] += zig_string('HEAD', '') + ';\n' + zig_string('TAIL', '') + ';\n'
        for name, text in sources.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8', newline='\n')
        # Golden outputs below are independent literal fixtures, not calls into
        # the implementation being verified. Counts follow the entire fixture
        # source, while the executable contract remains exactly 12 cases.
        mdx = {
            'config': 'CONFIG\n' + ''.join('## `' + key + '`\n\n' + doc + '\n\n' for key, doc in self.docs.items()),
            'actions': 'ACTIONS\n\n## `crash`\nCrash.\n\n## `gx`\nGX.\n',
            'commands': 'COMMANDS\n' + ''.join('## ' + action + '\n' + action + ' docs.\n\n```\n'
                                                + ('ghostty --' if action in ('help', 'version') else 'ghostty +')
                                                + action + '\n```\n\n' for action in self.actions)}
        for name, text in mdx.items():
            (self.web / (name + '.mdx')).write_bytes(text.encode('utf-8'))
        self.version = 'Ghostty fixture\nBuild Config\n  - build mode : .fast\n'
        self.raw = {
            'version': self.version,
            'help': 'HEAD\n' + ''.join('  +' + a + '\n' for a in self.actions) + 'TAIL\n',
            'show-config-default-docs': ('# Vsync.\nwindow-vsync = true\n\n# Links.\n\n# Quick size.\n\n'
                                         '# Zoom.\ngx-ctrl-scroll-zoom = true\n\n'
                                         '# Cursor.\ngx-prompt-cursor = config\n\n'),
            'explain-config-window-vsync': 'Vsync.\n',
            'explain-config-gx-ctrl-scroll-zoom': 'Zoom.\n',
            'explain-config-gx-prompt-cursor': 'Cursor.\n',
            'list-actions': 'crash\ngx\n',
            'list-actions-docs': '\ncrash:\n  Crash.\n\ngx:\n  GX.\n',
            'toggle-quick-terminal-help': 'toggle-quick-terminal docs.\n',
            'show-config-help': 'show-config docs.\n',
            'explain-config-unknown': "Unknown: 'gx-no-such-key'.\n",
            'explain-config-missing': ''}
        self.calls = []
        self.pin_sources()

    def pin_sources(self):
        files = {p.relative_to(self.root).as_posix(): {'sha256': contract.sha256(p), 'bytes': p.stat().st_size}
                 for p in self.root.rglob('*') if p.is_file()}
        self.manifest.write_text(json.dumps({'head': 'a' * 40, 'tree': 'b' * 40,
                                            'source_dirty': True, 'files': files}), encoding='utf-8')
        # Independent source-audited fixture values, NOT derived from fake CLI
        # output. Production must supply its own reviewed, pinned contract.
        values = {'window-vsync': 'window-vsync = true\n', 'link': '', 'quick-terminal-size': '',
                  'gx-ctrl-scroll-zoom': 'gx-ctrl-scroll-zoom = true\n',
                  'gx-prompt-cursor': 'gx-prompt-cursor = config\n'}
        self.defaults.write_text(json.dumps({'schema': 'gx-default-values-v1',
            'source_files_sha256': contract.files_digest(files), 'target': 'x86_64-windows-gnu',
            'review': {'method': 'source-audit', 'reviewed_by': 'synthetic test fixture'},
            'fields': [{'key': key, 'text': text, 'source_refs': ['src/config/Config.zig::default']}
                       for key, text in values.items()]}), encoding='utf-8')
        self.receipt.write_text(json.dumps({'source_head': 'a' * 40, 'source_tree': 'b' * 40,
                                           'source_dirty': True, 'build_exit': 0, 'version_exit': 0,
                                           'manifest': self.manifest.name, 'exe': str(self.exe),
                                           'source_files_sha256': contract.files_digest(files),
                                           'target': 'x86_64-windows-gnu',
                                           'defaults_contract_sha256': contract.sha256(self.defaults),
                                           'exe_sha256': contract.sha256(self.exe), 'version': self.version}), encoding='utf-8')

    def args(self, output='out', *, enhanced=False):
        return SimpleNamespace(source_root=self.root, exe=self.exe, webdata=self.web, out=self.base / output,
                               build_receipt=self.receipt, source_manifest=self.manifest,
                               defaults_contract=self.defaults if enhanced else None,
                               defaults_contract_sha256=contract.sha256(self.defaults) if enhanced else None,
                               source_head='a' * 40, source_tree='b' * 40,
                               exe_sha256=contract.sha256(self.exe),
                               build_receipt_sha256=contract.sha256(self.receipt),
                               source_manifest_sha256=contract.sha256(self.manifest), timeout=30)

    def execute(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        name, _, code = next(case for case in contract.CASES if list(case[1]) == argv[1:])
        return SimpleNamespace(returncode=code, stdout=self.raw[name].encode('utf-8'),
                               stderr=contract.MISSING_USAGE if name == 'explain-config-missing' else b'')

    def capture(self, args=None, runner=None):
        args = args or self.args()
        with contextlib.redirect_stdout(io.StringIO()):
            code = contract.run(args, execute=runner or self.execute)
        return code, json.loads((args.out / 'report.json').read_text(encoding='utf-8'))

    def test_positive_twelve_cases_twenty_four_streams_and_no_build(self):
        code, report = self.capture()
        self.assertEqual(0, code, report['errors'])
        self.assertEqual('PASS', report['status'])
        self.assertEqual(12, len(self.calls))
        self.assertEqual(24, report['raw_streams'])
        self.assertEqual(24, len(list((self.base / 'out/raw').iterdir())))
        self.assertEqual(['config', 'actions', 'commands'], list(report['webdata']))
        self.assertEqual([str(self.exe), '+toggle-quick-terminal', '--help'], self.calls[8][0])
        self.assertTrue(all(call[1]['shell'] is False and call[1]['stdin'] == subprocess.DEVNULL for call in self.calls))
        self.assertTrue(report['identity']['source_dirty'])  # Exact files, not a false clean-source claim.
        self.assertEqual('PASS', report['base']['status'])
        self.assertEqual('NOT_REQUESTED', report['default_values']['status'])

    def test_base_without_any_default_oracle_or_target_metadata(self):
        receipt = json.loads(self.receipt.read_text(encoding='utf-8'))
        del receipt['defaults_contract_sha256']
        del receipt['target']
        self.receipt.write_text(json.dumps(receipt), encoding='utf-8')
        self.defaults.unlink()
        code, report = self.capture(self.args('base-only'))
        self.assertEqual(0, code, report['errors'])
        self.assertEqual(24, report['raw_streams'])
        self.assertEqual('PASS', report['base']['status'])
        self.assertFalse(report['base']['all_runtime_defaults_verified'])
        self.assertEqual('NOT_REQUESTED', report['default_values']['status'])

    def test_wrong_non_tail_values_are_only_an_optional_enhancement_failure(self):
        self.raw['show-config-default-docs'] = self.raw['show-config-default-docs'].replace(
            'window-vsync = true', 'window-vsync = ')
        code, report = self.capture(self.args('base-value'))
        self.assertEqual(0, code, report['errors'])
        code, report = self.capture(self.args('enhanced-value', enhanced=True))
        self.assertEqual(1, code)
        self.assertEqual('PASS', report['base']['status'])
        self.assertEqual('FAIL', report['default_values']['status'])
        self.assertEqual(24, report['raw_streams'])

    def test_requested_enhancement_without_pin_fails_without_reducing_base_capture(self):
        args = self.args('no-enhancement-pin', enhanced=True)
        args.defaults_contract_sha256 = None
        code, report = self.capture(args)
        self.assertEqual(1, code)
        self.assertEqual('PASS', report['base']['status'])
        self.assertEqual('FAIL', report['default_values']['status'])
        self.assertEqual(24, report['raw_streams'])

    def test_enhancement_needs_receipt_pin_not_only_cli_pin(self):
        receipt = json.loads(self.receipt.read_text(encoding='utf-8'))
        del receipt['defaults_contract_sha256']
        self.receipt.write_text(json.dumps(receipt), encoding='utf-8')
        code, report = self.capture(self.args('no-receipt-oracle-pin', enhanced=True))
        self.assertEqual(1, code)
        self.assertEqual('PASS', report['base']['status'])
        self.assertEqual('DEFAULTS_RECEIPT_BINDING', report['default_values']['errors'][0]['code'])
        self.assertEqual(24, report['raw_streams'])

    def test_truncated_or_stale_mdx_fails_before_app_and_preserves_input(self):
        for name in ('config', 'actions', 'commands'):
            path = self.web / (name + '.mdx')
            original = path.read_bytes()
            for suffix, broken in (('truncated', original[:-1]), ('stale', b'old header\n' + original)):
                path.write_bytes(broken)
                code, report = self.capture(self.args(name + suffix))
                self.assertEqual(1, code)
                self.assertEqual('MDX_FULL_TEXT', report['errors'][0]['code'])
                self.assertEqual([], self.calls)
                self.assertEqual(broken, path.read_bytes())
            path.write_bytes(original)

    def test_wrong_exe_source_and_pins_prevent_execution(self):
        for defect in ('exe', 'head', 'tree', 'manifest_pin', 'receipt_pin', 'source_bytes'):
            with self.subTest(defect=defect):
                args = self.args(defect)
                original = (self.root / 'src/config/Config.zig').read_bytes()
                if defect == 'exe': args.exe_sha256 = '0' * 64
                elif defect == 'head': args.source_head = '0' * 40
                elif defect == 'tree': args.source_tree = '0' * 40
                elif defect == 'manifest_pin': args.source_manifest_sha256 = '0' * 64
                elif defect == 'receipt_pin': args.build_receipt_sha256 = '0' * 64
                else: (self.root / 'src/config/Config.zig').write_bytes(original + b'// changed\n')
                code, report = self.capture(args)
                self.assertEqual(1, code)
                self.assertEqual([], self.calls)
                self.assertTrue(report['errors'])
                (self.root / 'src/config/Config.zig').write_bytes(original)

    def test_source_coverage_and_duplicate_json_are_rejected(self):
        data = json.loads(self.manifest.read_text(encoding='utf-8'))
        del data['files']['src/helpgen.zig']
        self.manifest.write_text(json.dumps(data), encoding='utf-8')
        self.rebind_fixture_map()
        code, report = self.capture(self.args('coverage'))
        self.assertEqual(1, code)
        self.assertEqual('SOURCE_COVERAGE', report['errors'][0]['code'])
        self.manifest.write_text('{"head":1,"head":2}', encoding='utf-8')
        code, report = self.capture(self.args('duplicate'))
        self.assertEqual('DUPLICATE_JSON_KEY', report['errors'][0]['code'])
        self.assertFalse(self.calls)

    def test_manifest_path_escape_and_wrong_manifest_binding_are_rejected(self):
        data = json.loads(self.manifest.read_text(encoding='utf-8'))
        data['files']['../escape.zig'] = {'sha256': '0' * 64, 'bytes': 0}
        self.manifest.write_text(json.dumps(data), encoding='utf-8')
        self.rebind_fixture_map()
        code, report = self.capture(self.args('escape'))
        self.assertEqual('SOURCE_PATH', report['errors'][0]['code'])
        self.pin_sources()
        receipt = json.loads(self.receipt.read_text(encoding='utf-8'))
        receipt['manifest'] = 'other-source.json'
        self.receipt.write_text(json.dumps(receipt), encoding='utf-8')
        code, report = self.capture(self.args('binding'))
        self.assertEqual('MANIFEST_BINDING', report['errors'][0]['code'])
        self.assertFalse(self.calls)

    def rebind_fixture_map(self):
        data = json.loads(self.manifest.read_text(encoding='utf-8'))
        receipt = json.loads(self.receipt.read_text(encoding='utf-8'))
        receipt['source_files_sha256'] = contract.files_digest(data['files'])
        self.receipt.write_text(json.dumps(receipt), encoding='utf-8')

    def test_dirty_same_git_ids_cannot_rebind_old_exe_to_different_sources(self):
        source = self.root / 'src/config/Config.zig'
        source.write_text(source.read_text(encoding='utf-8') + '// different dirty source\n', encoding='utf-8')
        data = json.loads(self.manifest.read_text(encoding='utf-8'))
        data['files']['src/config/Config.zig'] = {'sha256': contract.sha256(source), 'bytes': source.stat().st_size}
        self.manifest.write_text(json.dumps(data), encoding='utf-8')
        # Exe, receipt, HEAD/tree and path unchanged; caller's new manifest pin
        # is insufficient without the original receipt binding its CONTENTS.
        code, report = self.capture(self.args('dirty-rebind'))
        self.assertEqual('RECEIPT_SOURCE_BINDING', report['errors'][0]['code'])
        self.assertFalse(self.calls)

    def test_receipt_requires_content_binding_and_accepts_explicit_manifest_bytes(self):
        receipt = json.loads(self.receipt.read_text(encoding='utf-8'))
        del receipt['source_files_sha256']
        self.receipt.write_text(json.dumps(receipt), encoding='utf-8')
        code, report = self.capture(self.args('no-binding'))
        self.assertEqual('RECEIPT_SOURCE_BINDING_MISSING', report['errors'][0]['code'])
        self.assertFalse(self.calls)
        receipt['source_manifest_sha256'] = contract.sha256(self.manifest)
        self.receipt.write_text(json.dumps(receipt), encoding='utf-8')
        code, report = self.capture(self.args('byte-binding'))
        self.assertEqual(0, code, report['errors'])

    def test_existing_output_is_never_reused_even_empty(self):
        args = self.args()
        args.out.mkdir()
        with self.assertRaises(contract.Rejected) as raised:
            contract.run(args, execute=self.execute)
        self.assertEqual('OUTPUT_EXISTS', raised.exception.code)
        self.assertEqual([], list(args.out.iterdir()))
        self.assertFalse(self.calls)

    def test_full_text_mutations_not_just_tail_or_length(self):
        for name in self.raw:
            if name == 'version':
                broken = 'Ghostty wrong\n'
            elif name == 'explain-config-missing':
                broken = 'unexpected stdout'
            else:
                # Leave the final tail intact for the config mutation.
                broken = self.raw[name].replace('Vsync.', 'Wrong.', 1) if name == 'show-config-default-docs' else self.raw[name][:-1]
            original = self.raw[name]
            self.raw[name] = broken
            code, report = self.capture(self.args(name))
            self.assertEqual(1, code, name)
            self.assertEqual('FAIL', report['base']['status'])
            self.assertEqual(24, report['raw_streams'])
            self.assertEqual(broken.encode('utf-8'), (self.base / name / 'raw' / (name + '.stdout')).read_bytes())
            self.raw[name] = original

    def test_config_tail_and_empty_default_contract_are_not_relaxed(self):
        original = self.raw['show-config-default-docs']
        for name, changed in (
                ('tail', original[:-1]),
                ('empty-non-tail', original.replace('window-vsync = true', 'window-vsync = ')),
                ('wrong-non-tail', original.replace('window-vsync = true', 'window-vsync = false')),
                ('duplicate-known', original.replace('window-vsync = true\n', 'window-vsync = true\nwindow-vsync = true\n')),
                ('missing-value', original.replace('window-vsync = true\n', '')),
                ('unknown-value', original + 'unrecognized = value\n'),
                ('order', original.replace('# Vsync.\nwindow-vsync = true', 'window-vsync = true\n# Vsync.'))):
            self.raw['show-config-default-docs'] = changed
            code, report = self.capture(self.args(name, enhanced=True))
            self.assertEqual(1, code, report)
        self.raw['show-config-default-docs'] = original

    def test_default_contract_cannot_override_source_literal_or_platform(self):
        original = self.defaults.read_bytes()
        for defect in ('literal', 'platform', 'cli-derived'):
            data = json.loads(original)
            if defect == 'literal': data['fields'][0]['text'] = 'window-vsync = \n'
            elif defect == 'platform': data['target'] = 'aarch64-macos'
            else: data['review']['method'] = 'same-exe-plain-output'
            self.defaults.write_text(json.dumps(data), encoding='utf-8')
            receipt = json.loads(self.receipt.read_text(encoding='utf-8'))
            receipt['defaults_contract_sha256'] = contract.sha256(self.defaults)
            self.receipt.write_text(json.dumps(receipt), encoding='utf-8')
            code, report = self.capture(self.args('contract-' + defect, enhanced=True))
            self.assertEqual(1, code)
            self.assertEqual('PASS', report['base']['status'])
            self.assertIn(report['default_values']['errors'][0]['code'],
                          ('DEFAULTS_SOURCE_LITERAL', 'DEFAULTS_SOURCE_PLATFORM', 'DEFAULTS_REVIEW'))
            self.assertEqual(24, report['raw_streams'])
        self.defaults.write_bytes(original)

    def test_legal_optional_empty_and_explicit_repeatable_entries(self):
        source = self.root / 'src/config/Config.zig'
        prefix = ('/// Optional.\n@"optional-test": ?bool = null,\n'
                  '/// Repeated.\n@"repeat-test": RepeatableString = .{},\n')
        source.write_text(prefix + source.read_text(encoding='utf-8'), encoding='utf-8')
        self.pin_sources()
        values = json.loads(self.defaults.read_text(encoding='utf-8'))
        values['fields'][0:0] = [
            {'key': 'optional-test', 'text': 'optional-test = \n',
             'source_refs': ['src/config/Config.zig::default']},
            {'key': 'repeat-test', 'text': 'repeat-test = one\nrepeat-test = two\n',
             'source_refs': ['src/config/Config.zig::RepeatableString.formatEntry']}]
        self.defaults.write_text(json.dumps(values), encoding='utf-8')
        receipt = json.loads(self.receipt.read_text(encoding='utf-8'))
        receipt['defaults_contract_sha256'] = contract.sha256(self.defaults)
        self.receipt.write_text(json.dumps(receipt), encoding='utf-8')
        config = self.web / 'config.mdx'
        config.write_bytes(config.read_bytes().replace(b'CONFIG\n',
            b'CONFIG\n## `optional-test`\n\nOptional.\n\n## `repeat-test`\n\nRepeated.\n\n', 1))
        self.raw['show-config-default-docs'] = ('# Optional.\noptional-test = \n\n'
            '# Repeated.\nrepeat-test = one\nrepeat-test = two\n\n' + self.raw['show-config-default-docs'])
        code, report = self.capture(self.args(enhanced=True))
        self.assertEqual(0, code, report['errors'])
        self.assertEqual('PASS', report['default_values']['status'])
        self.assertEqual(12, len(self.calls))

    def test_nonzero_exit_and_stderr_cannot_pass_and_all_cases_retained(self):
        def bad_exit(argv, **kwargs):
            r = self.execute(argv, **kwargs)
            if argv[1:] == ['+help']: r.returncode = 9
            return r
        code, report = self.capture(self.args('exit'), bad_exit)
        self.assertEqual(1, code)
        self.assertEqual('CASE_EXIT', report['errors'][0]['code'])
        self.assertEqual(24, report['raw_streams'])
        def bad_stderr(argv, **kwargs):
            r = self.execute(argv, **kwargs)
            if argv[1:] == ['+version']: r.stderr = b'warning'
            return r
        code, report = self.capture(self.args('stderr'), bad_stderr)
        self.assertEqual('STDERR_BYTES', report['errors'][0]['code'])

    def test_timeout_records_partial_raw_and_not_run_remainder(self):
        def timeout(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 30, output=b'partial', stderr=b'hung')
        code, report = self.capture(runner=timeout)
        self.assertEqual(1, code)
        self.assertEqual('CASE_TIMEOUT', report['errors'][0]['code'])
        self.assertEqual(12, len(report['planned_cases']))
        self.assertEqual(1, len(report['cases']))
        self.assertEqual(b'partial', (self.base / 'out/raw/version.stdout').read_bytes())

    def test_end_identity_change_and_raw_tampering_are_detected(self):
        def mutate(argv, **kwargs):
            result = self.execute(argv, **kwargs)
            if len(self.calls) == 12: self.exe.write_bytes(b'changed executable')
            return result
        code, report = self.capture(self.args('changed'), mutate)
        self.assertEqual(1, code)
        self.assertEqual('EXE_HASH', report['errors'][-1]['code'])
        self.exe.write_bytes(b'not executable: offline fixture')
        self.calls.clear()
        def tamper(argv, **kwargs):
            result = self.execute(argv, **kwargs)
            if len(self.calls) == 12:
                (self.base / 'raw-change/raw/version.stdout').write_bytes(b'tampered')
            return result
        code, report = self.capture(self.args('raw-change'), tamper)
        self.assertEqual('RAW_CHANGED', report['errors'][0]['code'])

    def test_environment_is_private_and_original_unchanged(self):
        base = {'SystemRoot': 'C:/Windows', 'PATH': 'loader-path', 'USERPROFILE': 'private-home',
                'LOCALAPPDATA': 'private-local', 'GHOSTTY_RESOURCES_DIR': 'foreign',
                'XDG_CONFIG_HOME': 'private-config', 'PAGER': 'notepad', 'PYTHONPATH': 'foreign'}
        with mock.patch.dict(os.environ, base, clear=True):
            before = dict(os.environ)
            actual = contract.isolated_environment(self.base / 'profile')
            self.assertEqual(before, dict(os.environ))
        self.assertEqual('C:/Windows', {k.upper(): v for k, v in actual.items()}['SYSTEMROOT'])
        for key in ('GHOSTTY_RESOURCES_DIR', 'PAGER', 'PYTHONPATH'):
            self.assertNotIn(key, actual)
        for key in ('USERPROFILE', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'TEMP', 'TMP'):
            self.assertTrue(Path(actual[key]).is_relative_to(self.base / 'profile'))

    def test_parser_requires_full_pins_and_does_not_offer_build_or_case_filter(self):
        for value in ('abcd', 'g' * 64):
            with self.assertRaises(argparse.ArgumentTypeError):
                contract.hash_arg(value)
        flags = {flag for action in contract.parser()._actions for flag in action.option_strings}
        self.assertNotIn('--case', flags)
        self.assertNotIn('--build', flags)
        self.assertEqual(12, len(contract.CASES))
        for action in contract.parser()._actions:
            if action.dest in ('defaults_contract', 'defaults_contract_sha256'):
                self.assertFalse(action.required)


class SourceFormattingTests(unittest.TestCase):
    def test_doc_indent_first_identifier_and_crlf(self):
        text = '///   first\r\n///     code\r\n@"key": bool = true,\r\n/// second\r\n@"key": bool = false,\r\n'
        self.assertEqual('first\n  code', contract.help_string(contract.doc_map(text)['key']))

    def test_config_callout_code_and_terminal_suffix(self):
        self.assertEqual('<Note>\n hello\n</Note>\n\n```\ncode\n```\n\n',
                         contract.config_body('Note: hello\n\n    code'))

    def test_private_or_undocumented_run_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'action.zig'
            for source in ('/// doc\nfn run() void {}\n', 'pub fn run() void {}\n'):
                p.write_text(source, encoding='utf-8')
                with self.assertRaises(ValueError):
                    contract.run_doc(p)


if __name__ == '__main__':
    unittest.main()
