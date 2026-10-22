#!/usr/bin/env python3
"""Offline atlas contract tests, isolated from the repository's generated graph."""
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import graphify_viewer as viewer
from test_graphify_fingerprint import git_init, write


def graph_fixture() -> dict:
    return {"nodes": [
        {"id": "b", "label": "Beta", "source_file": "macos/B.swift", "source_location": "L2", "community": 1, "_callable_class": True},
        {"id": "a", "label": "<Alpha>", "source_file": "src/a.zig", "source_location": "L1-L2", "community": 0, "_callable": True},
        {"id": "external", "label": "External", "source_file": "", "community": 0},
    ], "links": [
        {"source": "a", "target": "b", "relation": "calls", "confidence": "INFERRED", "confidence_score": 0.8, "source_file": "src/a.zig", "source_location": "L2"},
        {"source": "a", "target": "a", "relation": "contains", "confidence": "EXTRACTED", "confidence_score": 1.0, "source_file": "src/a.zig", "source_location": "L1"},
    ]}


def seed_assets(root: Path) -> None:
    for name in viewer.REQUIRED_ASSETS:
        value = "/* offline asset */"
        if name == "template.html":
            value = '<html data-view="@@VIEW@@"><style>@@CSS@@</style><script id="data" type="application/json">@@DATA@@</script><script>@@VENDOR_JS@@</script><script>@@SCENE_JS@@</script><script>@@APP_JS@@</script></html>'
        write(root, viewer.ASSETS + "/" + name, value)
    vendor = root / viewer.ASSETS / "vendor"
    lock = {
        "schema": 1, "library": {"version": "0.186.1"}, "builder": {"version": "0.28.2"},
        "inputs": {viewer.ASSETS + "/" + name: viewer.digest((root / viewer.ASSETS / name).read_bytes()) for name in viewer.VENDOR_BUILD_ASSETS},
        "outputs": {name: viewer.digest((vendor / name).read_bytes()) for name in ("three.bundle.js", "LICENSE.txt")},
    }
    write(root, viewer.ASSETS + "/vendor/manifest.json", json.dumps(lock))


def catalog(outputs: dict[str, bytes]) -> dict:
    page = outputs["overview.html"].decode("utf-8")
    return json.loads(page.split('type="application/json">')[1].split("</script>")[0])


def records(outputs: dict[str, bytes]) -> list:
    result = []
    for name in sorted(outputs):
        if name.endswith(".js"):
            args = json.loads("[" + outputs[name].decode("utf-8").removeprefix("GXAtlas.register(").removesuffix(");\n") + "]")
            result.extend(args[2])
    return result


class ViewerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        git_init(self.root)
        write(self.root, ".gitignore", "graphify-out/\n")
        write(self.root, "src/a.zig", "pub fn alpha() void {\n// </script> & <unsafe>\n}\n")
        write(self.root, "macos/B.swift", "// Beta\nclass Beta {}\n")
        seed_assets(self.root)
        self.graph = graph_fixture()
        self.save_graph()
        patcher = mock.patch.object(viewer.fp, "check_fingerprint", return_value=[])
        patcher.start()
        self.addCleanup(patcher.stop)

    def save_graph(self) -> None:
        write(self.root, "graphify-out/graph.json", json.dumps(self.graph))

    def build(self) -> dict[str, bytes]:
        return viewer.build_outputs(self.root)

    def snapshot(self) -> dict:
        out = self.root / viewer.OUT
        return {p.relative_to(out).as_posix(): (p.read_bytes(), p.stat().st_mtime_ns) for p in out.rglob("*") if p.is_file()}

    def test_catalog_neighbors_and_unknown_sources(self) -> None:
        outputs = self.build()
        data = catalog(outputs)
        self.assertEqual(data["stats"]["nodes"], 3)
        self.assertEqual(data["stats"]["selfLoops"], 1)
        self.assertEqual(data["stats"]["unknownSources"], 1)
        self.assertEqual(data["nodeFields"], viewer.NODE_FIELDS)
        self.assertEqual(data["nodes"][2][2:5], [-1, 0, 0])
        self.assertEqual(data["nodes"][2][9], [])
        self.assertEqual(len(data["files"]), 2)
        self.assertEqual([n[10] for n in data["nodes"]], [2, 1, 0])
        incident = {r[0]: r[2] for r in records(outputs)}
        self.assertEqual(len(incident[0]), 2)
        self.assertEqual(len(incident[1]), 1)
        # The same cross-file edge is reachable from both endpoints.
        self.assertIn(incident[1][0][0], [e[0] for e in incident[0]])
        self.assertEqual(len(data["moduleRelations"]), 1)
        self.assertEqual(data["moduleRelations"][0][2:], [1, 1])
        self.assertNotIn(b"<Alpha>", outputs["overview.html"])
        source = next(v for k, v in outputs.items() if k.startswith("sources/") and b"unsafe" in v)
        self.assertIn(b"&lt;/script&gt;", source)
        self.assertIn(b'id="L2"', source)
        self.assertIn(b'href="../../../src/a.zig"', source)
        self.assertNotIn(self.root.as_posix().encode(), b"".join(outputs.values()))

    def test_deterministic_and_check_preserves_bytes_and_mtime(self) -> None:
        first = self.build()
        self.assertEqual(first, self.build())
        self.graph["nodes"].reverse()
        self.graph["links"].reverse()
        # Byte identity of graph input intentionally participates in provenance.
        self.save_graph()
        second = self.build()
        self.assertEqual(catalog(first)["nodes"], catalog(second)["nodes"])
        viewer.run(self.root, "build")
        before = self.snapshot()
        viewer.run(self.root, "check")
        self.assertEqual(self.snapshot(), before)
        write(self.root, viewer.ASSETS + "/viewer.css", "body{color:red}")
        with self.assertRaisesRegex(viewer.ViewerError, "stale"):
            viewer.run(self.root, "check")
        self.assertEqual(self.snapshot(), before)

    def test_unknown_and_edited_outputs_are_preserved(self) -> None:
        write(self.root, viewer.OUT + "/notes.txt", "user notes")
        with self.assertRaisesRegex(viewer.ViewerError, "manifest"):
            viewer.run(self.root, "build")
        (self.root / viewer.OUT / "notes.txt").unlink()
        viewer.run(self.root, "build")
        target = self.root / viewer.OUT / "overview.html"
        target.write_text("user edit", encoding="utf-8")
        before = self.snapshot()
        with self.assertRaisesRegex(viewer.ViewerError, "edited"):
            viewer.run(self.root, "build")
        self.assertEqual(self.snapshot(), before)

    def test_deleted_source_removes_only_previous_owned_snapshot(self) -> None:
        viewer.run(self.root, "build")
        old = set(self.snapshot())
        self.graph["nodes"] = [n for n in self.graph["nodes"] if n["id"] != "b"]
        self.graph["links"] = [e for e in self.graph["links"] if e["target"] != "b"]
        self.save_graph()
        (self.root / "macos/B.swift").unlink()
        viewer.run(self.root, "build")
        removed = old - set(self.snapshot())
        self.assertEqual(len(removed), 1)
        self.assertTrue(next(iter(removed)).startswith("sources/"))

    def test_invalid_graph_and_source_evidence_fail_before_write(self) -> None:
        cases = [
            ({"nodes": [], "links": []}, "empty"),
            ({"nodes": [self.graph["nodes"][0]] * 2, "links": []}, "Duplicate"),
            ({"nodes": self.graph["nodes"], "links": [{"source": "a", "target": "missing"}]}, "Dangling"),
        ]
        for graph, message in cases:
            self.graph = graph
            self.save_graph()
            with self.assertRaisesRegex(viewer.ViewerError, message):
                viewer.run(self.root, "build")
            self.assertFalse((self.root / viewer.OUT).exists())
        for path in ("../outside.py", "/absolute.py", "C:/secret.py", "missing.py"):
            self.graph = graph_fixture()
            self.graph["nodes"][0]["source_file"] = path
            self.save_graph()
            with self.assertRaises(viewer.ViewerError):
                self.build()
        self.graph = graph_fixture()
        self.graph["nodes"][0]["source_location"] = "L9999"
        self.save_graph()
        with self.assertRaisesRegex(viewer.ViewerError, "range"):
            self.build()

    def test_budget_validation_is_prewrite(self) -> None:
        for limit, value in (("HTML_BYTES", 64), ("TOTAL_BYTES", 64), ("SHARD_BYTES", 64)):
            with mock.patch.object(viewer, limit, value), self.assertRaisesRegex(viewer.ViewerError, "budget"):
                viewer.run(self.root, "build")
            self.assertFalse((self.root / viewer.OUT).exists())

    def test_total_budget_includes_manifest_and_accepts_exact_boundary(self) -> None:
        outputs = self.build()
        total = sum(map(len, outputs.values()))
        without_manifest = total - len(outputs[viewer.MANIFEST])
        self.assertGreater(total, without_manifest)
        with mock.patch.object(viewer, "TOTAL_BYTES", without_manifest):
            with self.assertRaisesRegex(viewer.ViewerError, "Total viewer byte budget exceeded"):
                viewer.run(self.root, "build")
        self.assertFalse((self.root / viewer.OUT).exists())

        with mock.patch.object(viewer, "TOTAL_BYTES", total):
            self.assertEqual(self.build(), outputs)
            viewer.run(self.root, "build")
            viewer.run(self.root, "check")
        before = self.snapshot()
        self.assertEqual(sum(len(content) for content, _ in before.values()), total)
        with mock.patch.object(viewer, "TOTAL_BYTES", total - 1):
            for mode in ("build", "check"):
                with self.assertRaisesRegex(viewer.ViewerError, rf"{total} > {total - 1}"):
                    viewer.run(self.root, mode)
        self.assertEqual(self.snapshot(), before)

    def test_full_adjacency_paging_and_shard_byte_limit(self) -> None:
        self.graph["links"] = [dict(self.graph["links"][0], context=str(i)) for i in range(245)]
        self.save_graph()
        with mock.patch.object(viewer, "SHARD_BYTES", 12000):
            outputs = self.build()
        data = catalog(outputs)
        self.assertEqual(data["nodes"][0][10], 245)
        self.assertEqual(len(data["nodes"][0][9]), 3)
        self.assertTrue(all(len(value) <= 12000 for name, value in outputs.items() if name.endswith(".js")))
        self.assertEqual(sum(len(r[2]) for r in records(outputs)), 490)
        self.assertTrue(all(len(r[2]) <= 100 for r in records(outputs)))

    def test_asset_inline_escape_and_template_contract(self) -> None:
        write(self.root, viewer.ASSETS + "/app.js", "</SCRIPT><script>bad")
        with self.assertRaisesRegex(viewer.ViewerError, "Unsafe"):
            self.build()
        seed_assets(self.root)
        write(self.root, viewer.ASSETS + "/template.html", "@@DATA@@@@DATA@@")
        with self.assertRaisesRegex(viewer.ViewerError, "exactly once"):
            self.build()

    def test_vendor_integrity_and_unknown_files_are_checked(self) -> None:
        write(self.root, viewer.ASSETS + "/vendor/three.bundle.js", "tampered")
        with self.assertRaisesRegex(viewer.ViewerError, "vendor digest"):
            self.build()
        seed_assets(self.root)
        viewer.run(self.root, "build")
        write(self.root, viewer.OUT + "/user.txt", "must survive")
        before = self.snapshot()
        for mode in ("build", "check"):
            with self.assertRaises(viewer.ViewerError):
                viewer.run(self.root, mode)
        self.assertEqual(self.snapshot(), before)

    def test_vendor_inputs_are_verified_without_scanning_node_modules(self) -> None:
        expected = self.build()
        write(self.root, viewer.ASSETS + "/vendor/build/node_modules/native/binary.node", b"\0\xffbinary")
        self.assertEqual(self.build(), expected)
        write(self.root, viewer.ASSETS + "/vendor/build/package-lock.json", "modified lock")
        with self.assertRaisesRegex(viewer.ViewerError, "build input digest"):
            self.build()

    def test_modified_ownership_manifest_is_preserved(self) -> None:
        viewer.run(self.root, "build")
        target = self.root / viewer.OUT / viewer.MANIFEST
        manifest = json.loads(target.read_bytes())
        manifest["stats"]["nodes"] = 1000
        target.write_text(json.dumps(manifest), encoding="utf-8")
        before = self.snapshot()
        with self.assertRaisesRegex(viewer.ViewerError, "ownership manifest"):
            viewer.run(self.root, "build")
        self.assertEqual(self.snapshot(), before)

    def test_source_change_invalidates_snapshot_without_line_offset_change(self) -> None:
        viewer.run(self.root, "build")
        before = self.snapshot()
        write(self.root, "src/a.zig", "pub fn beta() void {\n// changed\n}\n")
        with self.assertRaisesRegex(viewer.ViewerError, "stale"):
            viewer.run(self.root, "check")
        self.assertEqual(self.snapshot(), before)

    def test_source_fingerprint_is_bound_and_line_endings_are_normalized(self) -> None:
        write(self.root, "graphify-out/source-fingerprint.json", '{"source":"one"}\n')
        first = self.build()
        manifest = json.loads(first[viewer.MANIFEST])
        self.assertEqual(manifest["sourceFingerprintSha256"], viewer.digest(b'{"source":"one"}\n'))
        write(self.root, "graphify-out/source-fingerprint.json", '{"source":"one"}\r\n')
        self.assertEqual(first, self.build())
        write(self.root, "graphify-out/source-fingerprint.json", '{"source":"two"}\n')
        self.assertNotEqual(catalog(first)["fingerprint"], catalog(self.build())["fingerprint"])

    def test_graph_freshness_failure_propagates(self) -> None:
        with mock.patch.object(viewer.fp, "check_fingerprint", side_effect=viewer.fp.FingerprintError("stale graph")):
            with self.assertRaisesRegex(viewer.ViewerError, "stale graph"):
                self.build()

    def test_symlink_source_is_rejected(self) -> None:
        target = self.root / "src/link.zig"
        target.symlink_to(self.root / "src/a.zig")
        self.graph["nodes"][0]["source_file"] = "src/link.zig"
        self.save_graph()
        with self.assertRaisesRegex(viewer.ViewerError, "Linked"):
            self.build()


if __name__ == "__main__":
    unittest.main()
