#!/usr/bin/env python3
"""C8 CLI/MDX full-text contract, independent of any historical evidence folder.

Never builds or opens a terminal window. Runs exactly the twelve reviewed CLI
commands with private config/state/cache/home directories, capturing 24 streams.
Requires externally supplied SHA256 pins for the executable, build receipt and
source manifest. A dirty build is allowed only when all manifest bytes match.
The receipt must bind source-manifest bytes or the canonical files-map digest;
matching Git IDs and paths alone is not provenance for a dirty build.
Base C8 checks all config doc blocks/order and the source-derived tail, not
every runtime default value. OPTIONAL --defaults-contract adds full VALUE byte
checks using an independently source-reviewed, platform-specific contract pinned
by the build receipt. Base and enhancement have separate status/coverage; a bad
requested enhancement returns failure but does not suppress base capture.
This tool never creates an oracle from measured CLI output. Source-content
binding is mandatory even without the enhancement: missing provenance fails.
Current Git HEAD may advance for docs/tools: build source identity remains the
explicit --source-head/--source-tree pair. Receipt version output is mandatory.

The source-text helpers below are promoted from the reviewed C8 verify_webdata
implementation: helpgen common-indent docs, config callouts/grouped keys, binding
action buffered docs and CLI action examples. They do not invoke Zig or import
an evidence-local module. This is not a general Zig parser; unsupported source
shapes fail the contract rather than reduce its coverage.

Run only when scheduled by root, under the shared heavy slot. Default operation
creates a NEW --out directory, raw streams, isolated profile and report.json.
On failure preserve that directory; never reuse it for a retry.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

KEYWORDS = set("""addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const
continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque
or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var
volatile while""".split())
IDENT = re.compile(r'@"([^"]*)"|([A-Za-z_][A-Za-z0-9_]*)')


def doc_map(text):
    """name -> doc lines (text after ///) for the first identifier token preceded by a doc comment."""
    result, pending = {}, []
    for line in text.splitlines():
        s = line.lstrip(" \t")
        if s.startswith("///") and not s.startswith("////"):
            pending.append(s[3:])
            continue
        if s == "":
            continue
        if s.startswith("//"):
            if s.startswith("//!"):
                pending = []
            continue
        m = IDENT.match(s)
        if pending and m:
            name = m.group(1) if m.group(1) is not None else m.group(2)
            if m.group(2) is None or m.group(2) not in KEYWORDS:
                result.setdefault(name, pending)
        pending = []
    return result


def help_string(lines):
    prefix = min([len(l) - len(l.lstrip(" ")) for l in lines if l.strip(" ") != ""] or [10**9])
    return "\n".join(l[min(prefix, len(l)):] for l in lines)


def multiline_after(text, anchor):
    idx = text.index(anchor)
    out, started = [], False
    for line in text[idx:].splitlines()[1:]:
        s = line.lstrip(" \t")
        if s.startswith("\\\\"):
            out.append(s[2:])
            started = True
        elif started:
            break
    return "\n".join(out)


def top_fields(text):
    fields = []
    for line in text.splitlines():
        if line[:1] in (" ", "\t", "") or line.startswith("//"):
            continue
        m = re.match(r'(@"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)\s*:', line)
        if m:
            tok = m.group(1)
            if tok.startswith("@"):
                fields.append(tok[2:-1])
            elif tok not in KEYWORDS:
                fields.append(tok)
    return fields


def container_fields(text, opener):
    lines = text.splitlines()
    start = next(i for i, l in enumerate(lines) if l.strip().startswith(opener))
    fields = []
    for line in lines[start + 1:]:
        if line.startswith("};"):
            break
        if not line.startswith("    ") or line.startswith("     "):
            continue
        s = line[4:]
        if s.startswith("//"):
            continue
        m = re.match(r'(@"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)\s*[:,]', s)
        if m:
            tok = m.group(1)
            name = tok[2:-1] if tok.startswith("@") else tok
            if tok.startswith("@") or tok not in KEYWORDS:
                fields.append(name)
                continue
        if fields and IDENT.match(s) and IDENT.match(s).group(2) in KEYWORDS:
            break
    return fields


def end_block(block):
    return {None: "", "text": "", "code": "```\n", "note": "</Note>\n", "warning": "</Warning>\n"}[block]


def config_body(help):
    out, block = [], None
    for s in help.split("\n"):
        if s == "":
            out.append(end_block(block)); block = None; out.append("\n"); continue
        first = block is None
        if block is None:
            if s.startswith("    "):
                block = "code"; out.append("```\n")
            elif s.lower().startswith("note:"):
                block = "note"; out.append("<Note>\n")
            elif s.lower().startswith("warning:"):
                block = "warning"; out.append("<Warning>\n")
            else:
                block = "text"
        if block == "text":
            out.append(s)
        elif block == "note":
            out.append(s[5:] if first else s)
        elif block == "warning":
            out.append(s[8:] if first else s)
        else:
            out.append(s[4:] if s.startswith("    ") else s)
        out.append("\n")
    out.append(end_block(block)); out.append("\n")
    return "".join(out)


def expect_config(root):
    src = (root / "src/config/Config.zig").read_text(encoding="utf-8")
    gen = (root / "src/build/webgen/main_config.zig").read_text(encoding="utf-8")
    docs = doc_map(src)
    fields = top_fields(src)
    out = [multiline_after(gen, "// Write the header")]
    sections = []
    for i, f in enumerate(fields):
        if f.startswith("_") or f not in docs:
            continue
        heads = [f]
        for nxt in fields[i + 1:]:
            if nxt.startswith("_") or nxt in docs:
                break
            heads.append(nxt)
        body = config_body(help_string(docs[f]))
        text = "".join("## `" + h + "`\n" for h in heads) + "\n" + body
        sections.append({"key": f, "grouped": heads[1:], "text": text, "doc": help_string(docs[f])})
        out.append(text)
    return "".join(out), sections, fields


def expect_actions(root):
    src = (root / "src/input/Binding.zig").read_text(encoding="utf-8")
    gen = (root / "src/input/helpgen_actions.zig").read_text(encoding="utf-8")
    docs = doc_map(src)
    fields = container_fields(src, "pub const Action = union(enum) {")
    out = [multiline_after(gen, ".markdown =>")]
    stream, sections = "", []
    for f in fields:
        if f.startswith("_"):
            continue
        has = f in docs
        if has:
            out.append(stream + "\n"); stream = ""
        out.append("## `" + f + "`\n")
        if has:
            lines = help_string(docs[f]).split("\n")
            text = ""
            for idx, s in enumerate(lines):
                if idx == len(lines) - 1 and s == "":
                    continue
                text += s + "\n"
            stream += text
            sections.append({"key": f, "doc": help_string(docs[f]), "text": "## `" + f + "`\n" + text})
        elif sections:
            sections[-1].setdefault("grouped", []).append(f)
    if stream:
        out.append(stream)
    return "".join(out), sections, fields


def run_doc(path):
    pending = []
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.lstrip(" \t")
        if s.startswith("///") and not s.startswith("////"):
            pending.append(s[3:]); continue
        if s == "" or (s.startswith("//") and not s.startswith("//!")):
            continue
        if re.match(r"pub\s+fn\s+run\b", s):
            if not pending:
                raise ValueError(f"{path}: run without doc comment")
            return pending
        if re.match(r"fn\s+run\b", s):
            raise ValueError(f"{path}: private run")
        pending = []
    raise ValueError(f"{path}: no run")


def expect_commands(root):
    src = (root / "src/cli/ghostty.zig").read_text(encoding="utf-8")
    gen = (root / "src/build/webgen/main_commands.zig").read_text(encoding="utf-8")
    fields = container_fields(src, "pub const Action = enum {")
    out = [multiline_after(gen, "// Write the header")]
    sections = []
    for f in fields:
        doc = help_string(run_doc(root / "src/cli" / (f.replace("-", "_") + ".zig")))
        text = "## " + f + "\n" + "".join(s + "\n" for s in doc.split("\n"))
        text += "\n```\n" + ("ghostty --" if f in ("help", "version") else "ghostty +") + f + "\n```\n\n"
        sections.append({"key": f, "doc": doc, "text": text})
        out.append(text)
    return "".join(out), sections, fields


CASES = (
    ('version', ('+version',), 0),
    ('help', ('+help',), 0),
    ('show-config-default-docs', ('+show-config', '--default', '--docs'), 0),
    ('explain-config-window-vsync', ('+explain-config', 'window-vsync'), 0),
    ('explain-config-gx-ctrl-scroll-zoom', ('+explain-config', 'gx-ctrl-scroll-zoom'), 0),
    ('explain-config-gx-prompt-cursor', ('+explain-config', 'gx-prompt-cursor'), 0),
    ('list-actions', ('+list-actions',), 0),
    ('list-actions-docs', ('+list-actions', '--docs'), 0),
    ('toggle-quick-terminal-help', ('+toggle-quick-terminal', '--help'), 0),
    ('show-config-help', ('+show-config', '--help'), 0),
    ('explain-config-unknown', ('+explain-config', 'gx-no-such-key'), 1),
    ('explain-config-missing', ('+explain-config',), 1),
)
TEXT_INPUTS = (
    'build.zig', 'build.zig.zon', 'src/helpgen.zig', 'src/config/Config.zig',
    'src/config/key.zig', 'src/config/formatter.zig', 'src/config/formatter_file.zig', 'src/config.zig',
    'src/gx/config_types.zig', 'src/input/Binding.zig', 'src/input/helpgen_actions.zig',
    'src/build/webgen/main_config.zig', 'src/build/webgen/main_actions.zig',
    'src/build/webgen/main_commands.zig', 'src/build/HelpStrings.zig',
    'src/build/GhosttyWebdata.zig',
)


class Rejected(Exception):
    def __init__(self, code, detail):
        self.code = code
        super().__init__(detail)


def require(condition, code, detail):
    if not condition:
        raise Rejected(code, detail)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def files_digest(files):
    """v2 source_files_sha256: sorted compact JSON, ensure_ascii=True."""
    return digest(json.dumps(files, sort_keys=True, separators=(',', ':')).encode('utf-8'))


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def unique_keys(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'DUPLICATE_JSON_KEY', key)
        value[key] = item
    return value


def pinned_json(path, expected):
    raw = path.read_bytes()
    require(digest(raw) == expected, 'IDENTITY_PIN', str(path))
    return json.loads(raw, object_pairs_hook=unique_keys)


def relative_source(root, name):
    require(isinstance(name, str) and name and '\\' not in name,
            'SOURCE_PATH', repr(name))
    p = Path(name)
    require(not p.is_absolute() and '..' not in p.parts and ':' not in name,
            'SOURCE_PATH', name)
    path = root / p
    require(path.resolve().is_relative_to(root), 'SOURCE_PATH', name)
    return path


def verify_identity(args):
    root, exe = args.source_root, args.exe
    receipt = pinned_json(args.build_receipt, args.build_receipt_sha256)
    manifest = pinned_json(args.source_manifest, args.source_manifest_sha256)
    require(isinstance(receipt, dict) and isinstance(manifest, dict), 'IDENTITY_SCHEMA', 'JSON objects required')
    require(receipt.get('source_head') == manifest.get('head') == args.source_head
            and receipt.get('source_tree') == manifest.get('tree') == args.source_tree,
            'SOURCE_IDENTITY', 'receipt/manifest do not match requested build source head/tree')
    require(type(receipt.get('build_exit')) is int and receipt['build_exit'] == 0
            and type(receipt.get('version_exit')) is int and receipt['version_exit'] == 0,
            'BUILD_RECEIPT', 'build and version must have succeeded')
    require(receipt.get('exe_sha256') == args.exe_sha256 and sha256(exe) == args.exe_sha256,
            'EXE_HASH', 'actual executable differs from requested/receipt hash')
    require(isinstance(receipt.get('version'), str) and receipt['version'].startswith('Ghostty '),
            'RECEIPT_VERSION', 'build receipt must contain full version output')
    # A relocated byte-identical exe is allowed; preserve both paths in evidence.
    # The receipt MUST identify the selected source manifest (relative or absolute).
    manifest_ref = receipt.get('manifest', receipt.get('source_manifest'))
    require(isinstance(manifest_ref, str) and bool(manifest_ref), 'MANIFEST_BINDING', 'receipt lacks manifest reference')
    manifest_path = Path(manifest_ref)
    if not manifest_path.is_absolute():
        manifest_path = args.build_receipt.parent / manifest_path
    require(manifest_path.resolve() == args.source_manifest, 'MANIFEST_BINDING', str(manifest_path))
    files = manifest.get('files')
    require(isinstance(files, dict) and files, 'SOURCE_MANIFEST', 'nonempty files map required')
    map_digest = files_digest(files)
    bindings = {'source_manifest_sha256': args.source_manifest_sha256, 'source_files_sha256': map_digest}
    present = [key for key in bindings if key in receipt]
    require(present, 'RECEIPT_SOURCE_BINDING_MISSING',
            'receipt must bind manifest bytes or canonical files map; matching head/tree/path is insufficient')
    for key in present:
        require(receipt[key] == bindings[key], 'RECEIPT_SOURCE_BINDING', key)
    if 'files_sha256' in manifest:
        require(manifest['files_sha256'] == map_digest, 'SOURCE_MAP_DIGEST', 'manifest files digest differs')
    target = receipt.get('target')
    commands = receipt.get('command', receipt.get('build_argv', []))
    if target is None and isinstance(commands, list):
        targets = [x.split('=', 1)[1] for x in commands if isinstance(x, str) and x.startswith('-Dtarget=')]
        target = targets[0] if len(targets) == 1 else None
    # Check every recorded file, not just documentation. Changed unrelated native
    # inputs cannot quietly inherit the executable's source identity.
    for name, entry in files.items():
        path = relative_source(root, name)
        require(isinstance(entry, dict) and isinstance(entry.get('sha256'), str)
                and re.fullmatch('[0-9a-f]{64}', entry['sha256'])
                and type(entry.get('bytes')) is int and entry['bytes'] >= 0,
                'SOURCE_ENTRY', name)
        require(path.is_file() and path.stat().st_size == entry['bytes']
                and sha256(path) == entry['sha256'], 'SOURCE_HASH', name)
    required = set(TEXT_INPUTS)
    required.update(path.relative_to(root).as_posix() for path in (root / 'src/cli').rglob('*.zig'))
    require(required <= files.keys(), 'SOURCE_COVERAGE', repr(sorted(required - files.keys())))
    for name in ('src/cli/ghostty.zig', 'src/cli/help.zig', 'src/cli/show_config.zig',
                 'src/cli/explain_config.zig', 'src/cli/version.zig',
                 'src/cli/list_actions.zig', 'src/cli/toggle_quick_terminal.zig'):
        require(name in files, 'SOURCE_COVERAGE', name)
    return {'source_head': args.source_head, 'source_tree': args.source_tree,
            'source_dirty': receipt.get('source_dirty', 'unknown'),
            'source_root': str(root), 'exe': str(exe), 'receipt_exe': receipt.get('exe'),
            'exe_sha256': args.exe_sha256, 'build_receipt_sha256': args.build_receipt_sha256,
            'source_manifest_sha256': args.source_manifest_sha256,
            'source_files_sha256': map_digest, 'target': target,
            'receipt_defaults_contract_sha256': receipt.get('defaults_contract_sha256'),
            'source_file_count': len(files), 'version': receipt['version']}


def multiline_strings(source):
    chunks, lines = [], []
    for line in source.splitlines():
        stripped = line.lstrip(' \t')
        if stripped.startswith('\\\\'):
            lines.append(stripped[2:])
        elif lines:
            chunks.append('\n'.join(lines)); lines = []
    if lines:
        chunks.append('\n'.join(lines))
    return chunks


def expected_text(root):
    mdx = {}
    sections = {}
    for name, fn in (('config', expect_config), ('actions', expect_actions), ('commands', expect_commands)):
        text, rows, fields = fn(root)
        require(rows and fields and len(fields) == len(set(fields)), 'SOURCE_SHAPE', name)
        mdx[name] = text.encode('utf-8')
        sections[name] = rows
    src = (root / 'src/config/Config.zig').read_text(encoding='utf-8')
    docs = doc_map(src)
    fields = top_fields(src)
    documented = [key for key in fields if not key.startswith('_') and key in docs]
    last = documented[-1]
    # Same simple-enum tail contract as v2, also allowing a simple bool tail.
    matches = re.findall(r'^@"' + re.escape(last) + r'": ([\w.]+) = (\.[A-Za-z_]\w*|true|false),$', src, re.M)
    require(len(matches) == 1, 'TAIL_SOURCE_SHAPE', last)
    field_type, default = matches[0]
    if default.startswith('.'):
        require(field_type.startswith('gx_config_types.'), 'TAIL_TYPE', field_type)
        enum_src = (root / 'src/gx/config_types.zig').read_text(encoding='utf-8')
        choices = container_fields(enum_src, 'pub const ' + field_type.split('.')[1] + ' = enum {')
        default = default[1:]
        require(default in choices, 'TAIL_DEFAULT', default)
    else:
        require(field_type == 'bool', 'TAIL_TYPE', field_type)
    exact = {}
    for key in ('window-vsync', 'gx-ctrl-scroll-zoom', 'gx-prompt-cursor'):
        require(key in docs and key in fields, 'EXPLAIN_SOURCE', key)
        exact['explain-config-' + key] = (help_string(docs[key]) + '\n').encode('utf-8')
    for name, filename in (('toggle-quick-terminal-help', 'toggle_quick_terminal.zig'),
                           ('show-config-help', 'show_config.zig')):
        exact[name] = (help_string(run_doc(root / 'src/cli' / filename)) + '\n').encode('utf-8')
    binding_src = (root / 'src/input/Binding.zig').read_text(encoding='utf-8')
    binding_docs = doc_map(binding_src)
    binding_fields = [x for x in container_fields(binding_src, 'pub const Action = union(enum) {') if not x.startswith('_')]
    require(binding_fields, 'BINDING_SOURCE', 'no actions')
    exact['list-actions'] = ''.join(x + '\n' for x in binding_fields).encode('utf-8')
    parts, stream = [], ''
    for name in binding_fields:
        if name in binding_docs:
            parts.append(stream + '\n'); stream = ''
        parts.append(name + ':\n')
        if name in binding_docs:
            lines = help_string(binding_docs[name]).split('\n')
            stream = ''.join('  ' + line + '\n' for i, line in enumerate(lines)
                             if not (i == len(lines) - 1 and line == ''))
    exact['list-actions-docs'] = ''.join([*parts, stream]).encode('utf-8')
    actions = container_fields((root / 'src/cli/ghostty.zig').read_text(encoding='utf-8'), 'pub const Action = enum {')
    chunks = multiline_strings((root / 'src/cli/help.zig').read_text(encoding='utf-8'))
    require(len(chunks) == 2 and actions, 'HELP_SOURCE_SHAPE', 'expected header/list/suffix')
    exact['help'] = (chunks[0] + ''.join('  +' + action + '\n' for action in actions) + chunks[1]).encode('utf-8')
    exact['explain-config-unknown'] = b"Unknown: 'gx-no-such-key'.\n"
    exact['explain-config-missing'] = b''
    return {'mdx': mdx, 'sections': sections, 'exact': exact, 'config_fields': fields,
            'docs': {key: help_string(docs[key]) for key in documented},
            'tail': (last + ' = ' + default + '\n\n').encode('utf-8'),
            'last': last, 'binding_actions': len(binding_fields), 'cli_actions': len(actions)}


def bind_default_values(args, identity, model):
    """Assemble FileFormatter output from source docs + independent value blocks.

    The pinned contract has one ordered entry per public Config field:
    {key, text, source_refs}. text is exactly formatEntry output (zero or more
    'key = value\n' lines), not the doc or separator. Empty optional values are
    'key = \n'; custom formatters may emit no lines or repeated key lines.
    A source-audit record is an external reviewed input, not a proof invented by
    this script. No CLI capture, equality with another CLI, or report can create
    that trust anchor. Primitive literal declarations are checked independently.
    """
    require(args.defaults_contract is not None and args.defaults_contract_sha256 is not None,
            'DEFAULTS_ARGUMENTS', 'requested enhancement needs both contract and full SHA256 pin')
    require(identity.get('receipt_defaults_contract_sha256') == args.defaults_contract_sha256,
            'DEFAULTS_RECEIPT_BINDING', 'receipt must pin the independently source-reviewed value contract')
    require(isinstance(identity.get('target'), str) and bool(identity['target']),
            'DEFAULTS_TARGET', 'enhancement needs an explicit target in the receipt')
    data = pinned_json(args.defaults_contract, args.defaults_contract_sha256)
    require(isinstance(data, dict) and data.get('schema') == 'gx-default-values-v1',
            'DEFAULTS_SCHEMA', 'gx-default-values-v1 required')
    require(data.get('source_files_sha256') == identity['source_files_sha256']
            and data.get('target') == identity['target'], 'DEFAULTS_SOURCE_PLATFORM',
            'value contract must bind the same canonical files map and target')
    review = data.get('review')
    require(isinstance(review, dict) and review.get('method') == 'source-audit'
            and isinstance(review.get('reviewed_by'), str) and bool(review['reviewed_by'].strip()),
            'DEFAULTS_REVIEW', 'independent source-audit provenance required, never CLI-derived equality')
    rows = data.get('fields')
    fields = [key for key in model['config_fields'] if not key.startswith('_')]
    require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows)
            and [row.get('key') for row in rows] == fields,
            'DEFAULTS_FIELD_ORDER', 'exactly one ordered contract entry for every public field')
    manifest = pinned_json(args.source_manifest, args.source_manifest_sha256)
    source = (args.source_root / 'src/config/Config.zig').read_text(encoding='utf-8')
    out = []
    literal_checks = []
    for row in rows:
        key, text = row['key'], row.get('text')
        require(isinstance(text, str) and (not text or text.endswith('\n')) and '\r' not in text,
                'DEFAULTS_VALUE_BYTES', key)
        require(all(line.startswith(key + ' = ') for line in text.splitlines()), 'DEFAULTS_VALUE_KEY', key)
        refs = row.get('source_refs')
        require(isinstance(refs, list) and refs and all(isinstance(ref, str) and '::' in ref
                and ref.split('::', 1)[0] in manifest['files'] and ref.split('::', 1)[1] for ref in refs),
                'DEFAULTS_SOURCE_REFS', key)
        # Config.default only initializes keybind/command-palette-entry/link;
        # all remaining simple literals have the generic formatter's spelling.
        declaration = re.findall(r'^(?:@"' + re.escape(key) + r'"|' + re.escape(key)
                                 + r'): ([^\n=]+) = ([^\n]+),$', source, re.M)
        if len(declaration) == 1 and key not in ('keybind', 'command-palette-entry', 'link'):
            field_type, value = (part.strip() for part in declaration[0])
            literal = None
            if field_type == 'bool' and value in ('true', 'false'):
                literal = value
            elif re.fullmatch('[ui][0-9]+', field_type) and re.fullmatch('-?[0-9]+', value):
                literal = str(int(value))
            elif field_type.startswith('?') and value == 'null':
                literal = ''
            if literal is not None:
                require(text == key + ' = ' + literal + '\n', 'DEFAULTS_SOURCE_LITERAL', key)
                literal_checks.append(key)
        if key in model['docs']:
            out.append(''.join('# ' + line + '\n' for line in model['docs'][key].split('\n')))
        out.append(text)
        if key in model['docs']:
            out.append('\n')
    expected = ''.join(out).encode('utf-8')
    require(expected.endswith(model['tail']), 'DEFAULTS_TAIL', model['last'])
    details = {'sha256': args.defaults_contract_sha256, 'source_files_sha256': identity['source_files_sha256'],
            'target': identity['target'], 'fields': len(rows), 'source_literal_checks': literal_checks,
            'review': review, 'expected_show_config_sha256': digest(expected)}
    return details, expected


def verify_webdata(webdata, model):
    result = {}
    for name, expected in model['mdx'].items():
        path = webdata / (name + '.mdx')
        raw = path.read_bytes()
        require(raw == expected, 'MDX_FULL_TEXT', f'{name}: actual={digest(raw)} expected={digest(expected)}')
        last = model['sections'][name][-1]
        result[name] = {'sha256': digest(raw), 'bytes': len(raw), 'identical': True,
                        'documented_sections': len(model['sections'][name]), 'tail': last['key']}
    return result


MISSING_USAGE = (b'Usage: ghostty +explain-config <option>\n'
                 b'       ghostty +explain-config --option=<option>\n'
                 b'       ghostty +explain-config --keybind=<action>\n')


def verify_streams(model, streams, version):
    require(set(streams) == {case[0] for case in CASES}, 'CASE_SET', 'exactly twelve cases required')
    for name, _, expected_exit in CASES:
        code, stdout, stderr = streams[name]
        require(type(code) is int and code == expected_exit, 'CASE_EXIT', f'{name}: {code}, expected {expected_exit}')
        require(stderr == (MISSING_USAGE if name == 'explain-config-missing' else b''), 'STDERR_BYTES', name)
        if name in model['exact']:
            require(stdout == model['exact'][name], 'CLI_FULL_TEXT', name)
    # Receipts captured by text-mode subprocesses may normalize version CRLF.
    # Only version allows this; docs/MDX/raw hashes always compare exact bytes.
    require(streams['version'][1].replace(b'\r\n', b'\n') == version.replace('\r\n', '\n').encode('utf-8'),
            'VERSION_BYTES', 'version differs from pinned successful build receipt')
    show = streams['show-config-default-docs'][1]
    expected_comments = ''.join(''.join('# ' + line + '\n' for line in doc.split('\n'))
                                for doc in model['docs'].values()).encode('utf-8')
    actual_comments = b''.join(line for line in show.splitlines(keepends=True) if line.startswith(b'# '))
    require(actual_comments == expected_comments, 'CONFIG_DOC_BYTES', 'full comments/order differ')
    position, no_value = 0, []
    for key, doc in model['docs'].items():
        block = ''.join('# ' + line + '\n' for line in doc.split('\n')).encode('utf-8')
        found = show.find(block + key.encode('utf-8') + b' =', position)
        if found < 0:
            found = show.find(block + b'\n', position)
            if found >= 0:
                no_value.append(key)
        require(found >= 0, 'CONFIG_DOC_VALUE_ORDER', key)
        position = found + len(block)
    require(no_value == [key for key in ('link', 'quick-terminal-size') if key in model['docs']],
            'CONFIG_MISSING_VALUES', repr(no_value))
    require(all(not line or line.startswith(b'# ') or line.split(b' =', 1)[0].decode('utf-8') in model['config_fields']
                for line in show.splitlines()), 'CONFIG_OUTPUT_LINES', 'unknown output line')
    require(show.endswith(model['tail']), 'CONFIG_TAIL', repr(model['tail']))
    return {'config_documented_keys': len(model['docs']), 'last_config_key': model['last'],
            'config_doc_without_value': no_value, 'all_config_doc_bytes': len(actual_comments),
            'binding_actions': model['binding_actions'], 'cli_actions': model['cli_actions'],
            'exact_explain_and_help': True, 'full_action_docs': True}


def isolated_environment(profile):
    # Allowlist OS loader essentials only. In particular no inherited GHOSTTY_*,
    # XDG paths, pager/editor, Python hooks, config/resource overrides or logs.
    env = {k: v for k, v in os.environ.items()
           if k.upper() in ('SYSTEMROOT', 'WINDIR', 'COMSPEC', 'PATH', 'PATHEXT', 'SYSTEMDRIVE')}
    paths = {'LOCALAPPDATA': profile, 'APPDATA': profile / 'appdata',
             'XDG_CONFIG_HOME': profile, 'XDG_STATE_HOME': profile / 'state',
             'XDG_CACHE_HOME': profile / 'cache', 'XDG_DATA_HOME': profile / 'data',
             'HOME': profile / 'home', 'USERPROFILE': profile / 'home',
             'TEMP': profile / 'tmp', 'TMP': profile / 'tmp', 'TMPDIR': profile / 'tmp'}
    for name, path in paths.items():
        path.mkdir(parents=True, exist_ok=True)
        env[name] = str(path)
    return env


def write_report(out, report):
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n',
                                   encoding='utf-8', newline='\n')


def run(args, execute=None):
    execute = execute or subprocess.run
    require(not args.out.exists() and not args.out.is_symlink(), 'OUTPUT_EXISTS', str(args.out))
    for key in ('source_root', 'exe', 'webdata', 'out', 'build_receipt', 'source_manifest'):
        setattr(args, key, getattr(args, key).resolve())
    if args.defaults_contract is not None:
        args.defaults_contract = args.defaults_contract.resolve()
    enhanced = args.defaults_contract is not None or args.defaults_contract_sha256 is not None
    out = args.out
    # Atomic fresh reservation; even an existing empty directory is not reusable.
    require(not out.exists(), 'OUTPUT_EXISTS', str(out))
    require(not args.source_root.is_relative_to(out) and not args.webdata.is_relative_to(out)
            and not out.is_relative_to(args.webdata), 'OUTPUT_OVERLAP', str(out))
    for path in (args.exe, args.build_receipt, args.source_manifest):
        require(not path.is_relative_to(out), 'OUTPUT_OVERLAP', str(path))
    if args.defaults_contract is not None:
        require(not args.defaults_contract.is_relative_to(out), 'OUTPUT_OVERLAP', str(args.defaults_contract))
    out.mkdir(parents=False, exist_ok=False)
    report = {'schema': 'gx-cli-contract-v1', 'status': 'RUNNING', 'exit': None,
              'scope': 'C8 CLI and three MDX full-text only; no WGL or performance verdict',
              'planned_cases': [{'name': n, 'args': list(a), 'expected_exit': e} for n, a, e in CASES],
              'cases': [], 'errors': [], 'raw_streams': 0,
              'base': {'status': 'NOT_RUN', 'all_runtime_defaults_verified': False,
                       'coverage': '12 cases/24 streams; config docs/order/tail; other CLI and three MDX full text'},
              'default_values': {'status': 'NOT_RUN' if enhanced else 'NOT_REQUESTED',
                                 'coverage': 'optional full default value bytes, independent source-reviewed oracle',
                                 'errors': []}}
    write_report(out, report)
    initial, model, oracle = None, None, None
    try:
        initial = verify_identity(args)
        report['identity'] = initial
        model = expected_text(args.source_root)
        report['webdata'] = verify_webdata(args.webdata, model)
        if enhanced:
            try:
                oracle = bind_default_values(args, initial, model)
                report['default_values']['contract'] = oracle[0]
            except Exception as exc:
                report['default_values']['status'] = 'FAIL'
                report['default_values']['errors'].append({'code': getattr(exc, 'code', type(exc).__name__), 'detail': str(exc)})
        raw_dir, profile = out / 'raw', out / 'profile'
        raw_dir.mkdir()
        env = isolated_environment(profile)
        streams = {}
        for name, argv, expected_exit in CASES:
            command = [str(args.exe), *argv]
            try:
                result = execute(command, cwd=profile, env=env, stdin=subprocess.DEVNULL,
                                 capture_output=True, timeout=args.timeout, shell=False)
                code, stdout, stderr = result.returncode, result.stdout, result.stderr
                timed_out = False
            except subprocess.TimeoutExpired as exc:
                code, stdout, stderr, timed_out = None, exc.stdout or b'', exc.stderr or b'', True
            require(isinstance(stdout, bytes) and isinstance(stderr, bytes), 'RAW_BYTES', name)
            hashes = {}
            for suffix, raw in (('stdout', stdout), ('stderr', stderr)):
                path = raw_dir / (name + '.' + suffix)
                with path.open('xb') as stream:
                    stream.write(raw)
                hashes[suffix + '_sha256'] = digest(raw)
                report['raw_streams'] += 1
            report['cases'].append({'name': name, 'argv': command, 'exit': code,
                                    'expected_exit': expected_exit, 'timeout': timed_out, **hashes})
            write_report(out, report)
            require(not timed_out, 'CASE_TIMEOUT', name)
            streams[name] = (code, stdout, stderr)
        report['cli'] = verify_streams(model, streams, initial['version'])
        require(report['raw_streams'] == 24, 'STREAM_COUNT', str(report['raw_streams']))
        # Re-read raw evidence: in-memory comparisons alone do not bind stored bytes.
        for row in report['cases']:
            for suffix in ('stdout', 'stderr'):
                require(sha256(raw_dir / (row['name'] + '.' + suffix)) == row[suffix + '_sha256'],
                        'RAW_CHANGED', row['name'] + '.' + suffix)
        report['base']['status'] = 'PASS'
        if oracle is not None:
            if streams['show-config-default-docs'][1] == oracle[1]:
                report['default_values']['status'] = 'PASS'
            else:
                report['default_values']['status'] = 'FAIL'
                report['default_values']['errors'].append({'code': 'DEFAULTS_FULL_TEXT',
                                                           'detail': 'default value bytes differ from pinned enhancement oracle'})
    except Exception as exc:
        report['base']['status'] = 'FAIL'
        report['errors'].append({'code': getattr(exc, 'code', type(exc).__name__), 'detail': str(exc)})
    finally:
        if initial is not None:
            try:
                require(verify_identity(args) == initial, 'IDENTITY_CHANGED', 'identity changed during capture')
                if model is not None and 'webdata' in report:
                    require(verify_webdata(args.webdata, model) == report['webdata'], 'MDX_CHANGED', 'webdata changed')
            except Exception as exc:
                report['base']['status'] = 'FAIL'
                report['errors'].append({'code': getattr(exc, 'code', type(exc).__name__), 'detail': str(exc)})
        if oracle is not None:
            try:
                require(bind_default_values(args, initial, model) == oracle,
                        'DEFAULTS_CHANGED', 'default values contract changed during capture')
            except Exception as exc:
                report['default_values']['status'] = 'FAIL'
                report['default_values']['errors'].append({'code': getattr(exc, 'code', type(exc).__name__), 'detail': str(exc)})
        report['status'] = ('PASS' if report['base']['status'] == 'PASS'
                            and report['default_values']['status'] in ('PASS', 'NOT_REQUESTED') else 'FAIL')
        report['exit'] = 0 if report['status'] == 'PASS' else 1
        report['verifier_sha256'] = sha256(Path(__file__))
        write_report(out, report)
    print(json.dumps({'status': report['status'], 'exit': report['exit'], 'report': str(out / 'report.json')}, ensure_ascii=False))
    return report['exit']


def hash_arg(value):
    if not re.fullmatch('[0-9a-fA-F]{64}', value):
        raise argparse.ArgumentTypeError('full SHA256 required')
    return value.lower()


def git_id(value):
    if not re.fullmatch('[0-9a-fA-F]{40}', value):
        raise argparse.ArgumentTypeError('full 40-digit Git object ID required')
    return value.lower()


def timeout_arg(value):
    number = float(value)
    if not 0 < number <= 300:
        raise argparse.ArgumentTypeError('timeout must be >0 and <=300 seconds')
    return number


def parser():
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    for name in ('exe', 'webdata', 'out', 'source-root', 'build-receipt', 'source-manifest'):
        p.add_argument('--' + name, type=Path, required=True)
    for name in ('exe-sha256', 'build-receipt-sha256', 'source-manifest-sha256'):
        p.add_argument('--' + name, type=hash_arg, required=True)
    for name in ('source-head', 'source-tree'):
        p.add_argument('--' + name, type=git_id, required=True)
    p.add_argument('--timeout', type=timeout_arg, default=30)
    p.add_argument('--defaults-contract', type=Path, help='optional independent full-default-value enhancement')
    p.add_argument('--defaults-contract-sha256', type=hash_arg, help='required when requesting defaults-contract enhancement')
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        return run(args)
    except (Rejected, OSError) as exc:
        print(f'gx-cli-contract: {getattr(exc, "code", type(exc).__name__)}: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
