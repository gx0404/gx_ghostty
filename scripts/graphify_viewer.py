#!/usr/bin/env python3
"""Build/check the offline GX atlas from the pinned Graphify graph (stdlib only).

Owns only graphify-out/framework/. Checks reconstruct in memory and never write.
The manifest is written last; interrupted builds are detectable, not transactional.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import html
import json
from pathlib import Path, PurePosixPath
import re
import sys
from urllib.parse import quote

import graphify_fingerprint as fp

ROOT = Path(__file__).resolve().parents[1]
OUT = "graphify-out/framework"
ASSETS = "scripts/graphify_viewer_assets"
MANIFEST = "manifest.json"
SCHEMA = 1
SHARD_BYTES = 512 * 1024
HTML_BYTES = 8 * 1024 * 1024
TOTAL_BYTES = 128 * 1024 * 1024
RELATION_PAGE = 100
NODE_FIELDS = ["id", "label", "file", "start", "end", "module", "kind", "community", "external", "locators", "degree"]
FILE_FIELDS = ["path", "sha256", "href"]
EDGE_FIELDS = ["edge", "other", "source", "target", "relation", "confidence", "confidenceScore", "file", "start", "end", "context"]
VENDOR_BUILD_ASSETS = (
    "vendor/build/package.json", "vendor/build/package-lock.json",
    "vendor/build/vendor-entry.mjs", "vendor/build/build_vendor.mjs",
)
REQUIRED_ASSETS = (
    "template.html", "viewer.css", "scene.js", "app.js", "vendor/three.bundle.js",
    "vendor/LICENSE.txt", "vendor/manifest.json", *VENDOR_BUILD_ASSETS,
)


class ViewerError(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_text(value: object) -> str:
    # Safe inside a script element and as an external classic script.
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


def safe_path(root: Path, relative: str) -> Path:
    """Refuse traversal, drive paths, symlinks and Windows junctions."""
    if not isinstance(relative, str) or not relative or "\\" in relative or ":" in relative:
        raise ViewerError(f"Invalid relative path: {relative!r}")
    parts = PurePosixPath(relative).parts
    if relative.startswith("/") or any(p in (".", "..") for p in parts) or "/".join(parts) != relative:
        raise ViewerError(f"Invalid relative path: {relative!r}")
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink() or (hasattr(current, "is_junction") and current.is_junction()):
            raise ViewerError(f"Linked path is not allowed: {relative}")
    try:
        current.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise ViewerError(f"Path escapes repository: {relative}") from exc
    return current


def text_bytes(path: Path) -> bytes:
    raw = path.read_bytes()
    if b"\0" in raw:
        raise ViewerError(f"Binary input: {path.name}")
    try:
        return raw.decode("utf-8-sig").replace("\r\n", "\n").encode("utf-8")
    except UnicodeDecodeError as exc:
        raise ViewerError(f"Non-UTF-8 input: {path.name}") from exc


def location(value: object, line_count: int) -> tuple[int, int]:
    if not value:
        return 0, 0
    match = re.fullmatch(r"L?(\d+)(?:[-:]L?(\d+))?", str(value))
    if not match:
        raise ViewerError(f"Unsupported source location: {value!r}")
    start = int(match[1])
    end = int(match[2] or start)
    if not 1 <= start <= end <= line_count:
        raise ViewerError(f"Source location out of range: {value!r} ({line_count} lines)")
    return start, end


def module_name(path: str) -> str:
    if not path:
        return "External / unknown"
    parts = path.split("/")
    if len(parts) == 1:
        return "Repository root"
    if parts[:2] in (["src", "apprt"], ["macos", "Sources"]):
        return "/".join(parts[:3]) if len(parts) > 3 else "/".join(parts[:2])
    return "/".join(parts[:2]) if len(parts) > 2 else parts[0]


def source_html(path: str, source: bytes) -> bytes:
    title = html.escape(path)
    original = "../../../" + quote(path, safe="/")
    lines = source.decode("utf-8").splitlines()
    body = "\n".join(f'<span id="L{i}"><a href="#L{i}" aria-label="Line {i}">{i}</a> {html.escape(line)}</span>' for i, line in enumerate(lines, 1))
    return (f'<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>{title}</title>'
            '<style>body{background:#101827;color:#e2e8f0;font:14px/1.65 monospace;margin:24px}a{color:#7dd3fc}pre{white-space:pre-wrap;overflow-wrap:anywhere}span:target{background:#30456a}span>a{display:inline-block;min-width:4em;text-align:right;margin-right:1em}</style>'
            f'<h1>{title}</h1><p>SHA256 (UTF-8, LF): {digest(source)}</p><a href="../overview.html">Atlas</a> · <a href="{original}">Repository file</a><pre>{body}</pre></html>\n').encode("utf-8")


def load_assets(root: Path) -> tuple[dict[str, bytes], dict[str, str]]:
    directory = safe_path(root, ASSETS)
    if not directory.is_dir():
        raise ViewerError(f"Missing assets: {ASSETS}")
    assets = {}
    hashes = {}
    # Only runtime assets and their explicit build inputs belong to this pipeline.
    # In particular, never traverse a maintainer's vendor/build/node_modules/.
    for name in REQUIRED_ASSETS:
        rel = ASSETS + "/" + name
        path = safe_path(root, rel)
        if path.is_file():
            raw = text_bytes(path)
            assets[name] = raw
            hashes[rel] = digest(raw)
    missing = set(REQUIRED_ASSETS) - assets.keys()
    if missing:
        raise ViewerError(f"Missing viewer assets: {sorted(missing)}")
    try:
        vendor = json.loads(assets["vendor/manifest.json"])
        if vendor["schema"] != 1 or vendor["library"]["version"] != "0.186.1" or vendor["builder"]["version"] != "0.28.2":
            raise ValueError("unsupported vendor lock")
        expected_inputs = {ASSETS + "/" + name: digest(assets[name]) for name in VENDOR_BUILD_ASSETS}
        if vendor["inputs"] != expected_inputs:
            raise ValueError("vendor build input digest mismatch")
        for name in ("three.bundle.js", "LICENSE.txt"):
            if vendor["outputs"][name] != digest(assets["vendor/" + name]):
                raise ValueError(f"vendor digest mismatch: {name}")
    except (KeyError, TypeError, ValueError) as exc:
        raise ViewerError(f"Invalid viewer vendor manifest: {exc}") from exc
    for name in ("scene.js", "app.js", "vendor/three.bundle.js"):
        if re.search(br"</script", assets[name], re.I):
            raise ViewerError(f"Unsafe inline script terminator in {name}")
    if re.search(br"</style", assets["viewer.css"], re.I):
        raise ViewerError("Unsafe inline style terminator")
    hashes["scripts/graphify_viewer.py"] = digest(text_bytes(Path(__file__)))
    return assets, hashes


def render_page(template: str, view: str, catalog: dict, assets: dict[str, bytes]) -> bytes:
    replacements = {
        "@@VIEW@@": view, "@@DATA@@": json_text(catalog),
        "@@CSS@@": assets["viewer.css"].decode("utf-8"),
        "@@VENDOR_JS@@": assets["vendor/three.bundle.js"].decode("utf-8"),
        "@@SCENE_JS@@": assets["scene.js"].decode("utf-8"),
        "@@APP_JS@@": assets["app.js"].decode("utf-8"),
    }
    for token in replacements:
        if template.count(token) != 1:
            raise ViewerError(f"Template must contain {token} exactly once")
    # One substitution pass: asset/user text cannot introduce another token.
    return re.sub(r"@@(?:VIEW|DATA|CSS|VENDOR_JS|SCENE_JS|APP_JS)@@", lambda m: replacements[m[0]], template).encode("utf-8")


def build_outputs(root: Path, *, verify_graph: bool = True) -> dict[str, bytes]:
    root = root.resolve()
    if verify_graph:
        try:
            fp.check_fingerprint(root)
        except fp.FingerprintError as exc:
            raise ViewerError(str(exc)) from exc
    graph_path = safe_path(root, "graphify-out/graph.json")
    if not graph_path.is_file():
        raise ViewerError("Missing graphify-out/graph.json; run just graph")
    raw = graph_path.read_bytes()
    graph_hash = digest(raw)
    try:
        graph = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ViewerError("Invalid graph JSON") from exc
    if not isinstance(graph, dict) or not isinstance(graph.get("nodes"), list) or not isinstance(graph.get("links"), list):
        raise ViewerError("Expected Graphify nodes/links schema")
    nodes, edges = graph["nodes"], graph["links"]
    if not nodes:
        raise ViewerError("Refusing empty graph")
    if any(not isinstance(n, dict) or not isinstance(n.get("id"), str) or not n["id"] for n in nodes):
        raise ViewerError("Invalid node ID")
    nodes = sorted(nodes, key=lambda n: n["id"])
    node_index = {n["id"]: i for i, n in enumerate(nodes)}
    if len(node_index) != len(nodes):
        raise ViewerError("Duplicate node ID")
    for edge in edges:
        if not isinstance(edge, dict) or not isinstance(edge.get("source"), str) or not isinstance(edge.get("target"), str) or edge["source"] not in node_index or edge["target"] not in node_index:
            raise ViewerError("Dangling edge endpoint")
    edges = sorted(edges, key=json_text)
    assets, pipeline = load_assets(root)
    sources = sorted({str(item.get("source_file") or "") for item in [*nodes, *edges]} - {""})
    visible = set(fp.git_visible_files(root))
    files, source_lines, outputs = [], {}, {}
    for path in sources:
        source_path = safe_path(root, path)
        if path not in visible or not source_path.is_file():
            raise ViewerError(f"Source outside Git-visible corpus: {path}")
        content = text_bytes(source_path)
        href = "sources/" + digest(path.encode("utf-8")) + ".html"
        files.append([path, digest(content), href])
        source_lines[path] = len(content.decode("utf-8").splitlines())
        outputs[href] = source_html(path, content)
    file_index = {row[0]: i for i, row in enumerate(files)}
    modules = sorted({module_name(str(n.get("source_file") or "")) for n in nodes})
    communities = sorted({str(n.get("community_name") or ("Community " + str(n.get("community", "unknown")))) for n in nodes})
    module_index = {name: i for i, name in enumerate(modules)}
    community_index = {name: i for i, name in enumerate(communities)}

    def source_info(item: dict) -> tuple[int, int, int]:
        path = str(item.get("source_file") or "")
        if not path:
            return -1, 0, 0
        start, end = location(item.get("source_location"), source_lines[path])
        return file_index[path], start, end

    rows = []
    for node in nodes:
        file_id, start, end = source_info(node)
        path = str(node.get("source_file") or "")
        label = str(node.get("label") or node["id"])
        kind = "class" if node.get("_callable_class") else "function" if node.get("_callable") else "file" if path and label == PurePosixPath(path).name else "symbol"
        community = str(node.get("community_name") or ("Community " + str(node.get("community", "unknown"))))
        rows.append([node["id"], label, file_id, start, end, module_index[module_name(path)], kind, community_index[community], bool(node.get("external") or not path), [], 0])
    adjacency = defaultdict(list)
    evidence = Counter()
    module_edges = defaultdict(lambda: [0, 0])
    self_loops = 0
    for edge_id, edge in enumerate(edges):
        source, target = node_index[edge["source"]], node_index[edge["target"]]
        file_id, start, end = source_info(edge)
        confidence = str(edge.get("confidence") or "AMBIGUOUS")
        score = edge.get("confidence_score", 0)
        if not isinstance(score, (int, float)) or not 0 <= score <= 1:
            raise ViewerError("Invalid confidence_score")
        evidence[confidence] += 1
        if source == target:
            self_loops += 1
        for node_id, other in [(source, target)] + ([(target, source)] if target != source else []):
            adjacency[node_id].append([edge_id, other, source, target, str(edge.get("relation") or "related"), confidence, score, file_id, start, end, str(edge.get("context") or "")])
        a, b = sorted((rows[source][5], rows[target][5]))
        if a != b:
            module_edges[a, b][0] += 1
            module_edges[a, b][1] += confidence != "EXTRACTED"
    fingerprint_path = safe_path(root, "graphify-out/source-fingerprint.json")
    source_fingerprint_hash = digest(text_bytes(fingerprint_path)) if fingerprint_path.is_file() else None
    provenance = {"schema": SCHEMA, "sourceGraphSha256": graph_hash, "sourceFingerprintSha256": source_fingerprint_hash, "pipeline": pipeline, "sources": [[x[0], x[1]] for x in files], "limits": [SHARD_BYTES, HTML_BYTES, RELATION_PAGE]}
    fingerprint = digest(json_text(provenance).encode("utf-8"))
    shards = []
    records = []
    records_size = 0

    def shard_data(items: list, shard_id: int) -> bytes:
        return ("GXAtlas.register(" + json_text(fingerprint) + "," + str(shard_id) + "," + json_text(items) + ");\n").encode("utf-8")

    def flush() -> None:
        nonlocal records_size
        if not records:
            return
        name = f"data/relations-{len(shards):04d}.js"
        outputs[name] = shard_data(records, len(shards))
        shards.append(name)
        records.clear()
        records_size = 0

    for node_id in range(len(rows)):
        incident = adjacency[node_id]
        rows[node_id][10] = len(incident)
        for offset in range(0, len(incident), RELATION_PAGE):
            page = offset // RELATION_PAGE
            record = [node_id, page, incident[offset:offset + RELATION_PAGE]]
            record_size = len(json_text(record).encode("utf-8"))
            overhead = len(shard_data([], len(shards)))
            if record_size + overhead > SHARD_BYTES:
                raise ViewerError("Relation page exceeds shard byte budget")
            if records and overhead + records_size + record_size + 1 > SHARD_BYTES:
                flush()
            rows[node_id][9].append([len(shards), page])
            records_size += record_size + bool(records)
            records.append(record)
    flush()
    stats = {"nodes": len(rows), "edges": len(edges), "files": len(files), "modules": len(modules), "communities": len(communities), "selfLoops": self_loops, "unknownSources": sum(row[2] == -1 for row in rows), "evidence": dict(sorted(evidence.items()))}
    catalog = {"schema": SCHEMA, "fingerprint": fingerprint, "sourceGraphSha256": graph_hash, "nodes": rows, "nodeFields": NODE_FIELDS, "files": files, "fileFields": FILE_FIELDS, "edgeFields": EDGE_FIELDS, "modules": modules, "communities": communities, "shards": shards, "moduleRelations": [[a, b, *counts] for (a, b), counts in sorted(module_edges.items())], "stats": stats, "limits": {"relationPage": RELATION_PAGE, "shardBytes": SHARD_BYTES, "htmlBytes": HTML_BYTES}, "limitations": ["Product-source AST scope; scripts and build directories are excluded.", "EXTRACTED and INFERRED describe extraction evidence, not runtime execution.", "External/unknown nodes have no source snapshot; empty locations have no line anchor.", "Edge source/target preserve Graphify's extracted direction; this is not a complete call graph."]}
    template = assets["template.html"].decode("utf-8")
    for view in ("overview", "detail"):
        outputs[view + ".html"] = render_page(template, view, catalog, assets)
    outputs["REPORT.md"] = ("# GX offline atlas\n\n" + "\n".join(f"- {key}: {json_text(value)}" for key, value in stats.items()) + f"\n- source graph SHA256: {graph_hash}\n- content fingerprint: {fingerprint}\n- mode: offline product-source AST view (Graphify 0.9.73)\n\n" + "\n".join("- " + note for note in catalog["limitations"]) + "\n\nGenerated with `just graph-view`; validate with `just graph-view-check`.\n").encode("utf-8")
    for name, content in outputs.items():
        limit = HTML_BYTES if name.endswith(".html") else SHARD_BYTES if name.endswith(".js") else TOTAL_BYTES
        if len(content) > limit:
            raise ViewerError(f"Byte budget exceeded: {name} ({len(content)} > {limit})")
    manifest = {**provenance, "fingerprint": fingerprint, "stats": stats, "outputs": {name: digest(data) for name, data in sorted(outputs.items())}}
    manifest["manifestSha256"] = digest(json_text(manifest).encode("utf-8"))
    outputs[MANIFEST] = (json_text(manifest) + "\n").encode("utf-8")
    total = sum(map(len, outputs.values()))
    if total > TOTAL_BYTES:
        raise ViewerError(f"Total viewer byte budget exceeded ({total} > {TOTAL_BYTES})")
    return outputs


def existing_outputs(root: Path) -> tuple[Path, dict[str, bytes]]:
    directory = safe_path(root, OUT)
    if not directory.exists():
        return directory, {}
    if not directory.is_dir():
        raise ViewerError(f"Output is not a directory: {OUT}")
    existing = {}
    for path in sorted(directory.rglob("*")):
        safe_path(root, path.relative_to(root).as_posix())
        if path.is_file():
            existing[path.relative_to(directory).as_posix()] = path.read_bytes()
    return directory, existing


def validate_ownership(existing: dict[str, bytes]) -> dict[str, str]:
    if not existing:
        return {}
    if MANIFEST not in existing:
        raise ViewerError("Existing viewer directory has no ownership manifest")
    try:
        manifest = json.loads(existing[MANIFEST])
        claimed_hash = manifest.pop("manifestSha256")
        if digest(json_text(manifest).encode("utf-8")) != claimed_hash:
            raise ValueError("manifest was edited")
        owned = manifest["outputs"]
        if manifest["schema"] != SCHEMA or not isinstance(owned, dict):
            raise ValueError("schema")
    except (ValueError, TypeError, KeyError) as exc:
        raise ViewerError("Invalid viewer ownership manifest") from exc
    if set(existing) != {*owned, MANIFEST}:
        raise ViewerError("Unknown or missing files in viewer output directory")
    for name, expected in owned.items():
        if digest(existing[name]) != expected:
            raise ViewerError(f"Generated file was edited; preserve it before rebuilding: {name}")
    return owned


def run(root: Path, mode: str) -> dict:
    directory, existing = existing_outputs(root)
    # Check never repairs; build never overwrites unknown or modified outputs.
    if mode == "build":
        owned = validate_ownership(existing)
    outputs = build_outputs(root)
    if mode == "check":
        if existing != outputs:
            changed = sorted(name for name in set(existing) | set(outputs) if existing.get(name) != outputs.get(name))
            raise ViewerError("Viewer missing or stale: " + ", ".join(changed[:8]) + "; run just graph-view")
    else:
        # Recheck ownership after expensive generation before any mutation.
        _, latest = existing_outputs(root)
        if latest != existing:
            raise ViewerError("Viewer outputs changed during generation")
        import build_agent_kb
        for name, data in sorted(outputs.items()):
            if name == MANIFEST:
                continue
            target = safe_path(directory, name)
            if existing.get(name) != data:
                build_agent_kb.write_atomic(target, data.decode("utf-8"))
        for name in sorted(set(owned) - outputs.keys()):
            safe_path(directory, name).unlink()
        build_agent_kb.write_atomic(directory / MANIFEST, outputs[MANIFEST].decode("utf-8"))
    return json.loads(outputs[MANIFEST])["stats"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("build", "check"))
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        stats = run(args.root.resolve(), args.mode)
        print(f"OK: viewer {args.mode}: {stats['nodes']} nodes, {stats['edges']} edges")
    except (ViewerError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
