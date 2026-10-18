"""Offline contracts of the UIA-01 dynamic focus plans; no window is created."""
import base64
import json
from pathlib import Path
import sys
import tempfile
import unittest

import gx_popup_uia_fixture as popup

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import gx_win_uia as worker  # noqa: E402


def node(name, automation_id, **patterns):
    return {"name": name, "automation_id": automation_id, "enabled": True, "focusable": True,
            "patterns": {key: True for key, on in patterns.items() if on}}


class FocusPlanTests(unittest.TestCase):
    def valid(self, rows):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "plan.json"
            path.write_text(json.dumps(rows), encoding="utf-8")
            return worker.read_plan(path)

    def test_palette_focuses_search_then_sets_its_value_on_the_same_element(self):
        nodes = [node("Command Palette", "gx-1", window=True) | {"focusable": False}, node("Search", "gx-2", value=True)]
        rows = popup.palette_focus_rows(nodes, "font")
        self.assertEqual(rows, self.valid(rows))
        self.assertEqual([("element", "set_focus"), ("value", "set")], [(r["pattern"], r["operation"]) for r in rows])
        self.assertEqual({"gx-2"}, {r["automation_id"] for r in rows})
        self.assertTrue(rows[0]["expect_focused_element"])

    def test_menu_invokes_new_tab_held_from_before_the_focus_moves(self):
        nodes = [node("New Tab", "gx-2", invoke=True), node("New Window", "gx-3", invoke=True),
                 node("Split", "gx-5", expand_collapse=True), node("Quit", "gx-13", invoke=True)]
        rows = popup.menu_focus_rows(nodes)
        self.assertEqual(rows, self.valid(rows))
        self.assertEqual(["gx-2", "gx-5", "gx-2", "gx-2"], [r["automation_id"] for r in rows])
        self.assertEqual(("invoke", "invoke"), (rows[-1]["pattern"], rows[-1]["operation"]))
        self.assertFalse(rows[2]["expect_focus"])
        self.assertNotIn("gx-13", {r["automation_id"] for r in rows})
        with self.assertRaises(AssertionError):
            popup.menu_focus_rows([n for n in nodes if n["name"] != "Split"])

    def test_dialog_never_allows_and_toggles_the_check_box_held_from_before(self):
        nodes = [node("Authorize Clipboard Access", "gx-1", window=True) | {"focusable": False},
                 node("Remember choice for this split", "gx-3", toggle=True),
                 node("Allow", "gx-4", invoke=True), node("Deny", "gx-5", invoke=True)]
        rows = popup.dialog_focus_rows(nodes)
        self.assertEqual(rows, self.valid(rows))
        self.assertNotIn("gx-4", {r["automation_id"] for r in rows})
        self.assertFalse(any(r["pattern"] == "invoke" for r in rows))
        self.assertEqual(("gx-3", "toggle"), (rows[-1]["automation_id"], rows[-1]["operation"]))
        moved = rows[1]
        self.assertTrue(moved["expect_focus"] and moved["expect_focused_element"] and moved["expect_focus_event"])

    def test_the_dialog_prompt_asks_to_write_the_marker_and_nothing_reads(self):
        line = next(l for l in popup.DIALOG_CONFIG.splitlines() if l.startswith("command = "))
        encoded = line.split("52;c;", 1)[1].split("$E", 1)[0]
        self.assertEqual(popup.CLIPBOARD_MARKER, base64.b64decode(encoded).decode())
        self.assertTrue(line.endswith("$E\\$G$S"))
        self.assertIn("clipboard-write = ask", popup.DIALOG_CONFIG)
        self.assertNotIn("clipboard-read", popup.DIALOG_CONFIG)


if __name__ == "__main__":
    unittest.main()
