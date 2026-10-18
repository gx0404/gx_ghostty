"""Offline contracts of the UIA-01/05/06 plans and judgments; no window is created."""
import base64
import contextlib
import io
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


class TerminalJudgmentTests(unittest.TestCase):
    """UIA-05 (D-29) judgments over probe nodes."""

    ROOT = {"name": "C:\\Windows\\system32\\cmd.exe", "control_type": 50033, "localized_type": "Terminal",
            "automation_id": "gx-terminal-7", "native_window_handle": 0x40482}

    def test_the_root_must_be_the_named_terminal_pane_of_that_hwnd(self):
        self.assertEqual([], popup.terminal_root_facts(self.ROOT, 0x40482))
        # The r6 VM probe: the anonymous Win32 HWND element.
        anonymous = {"name": "", "control_type": 50033, "localized_type": "pane", "automation_id": "", "native_window_handle": 0x40482}
        self.assertEqual(["named", "localized_type", "automation_id"], popup.terminal_root_facts(anonymous, 0x40482))
        self.assertEqual(["native_window_handle"], popup.terminal_root_facts(self.ROOT, 0x50492))
        # A handle reported as a negative VT_I4 still matches its low 32 bits.
        self.assertEqual([], popup.terminal_root_facts(self.ROOT | {"native_window_handle": -0x7ffbfb7e}, 0x80040482))

    def test_a_window_fragment_twin_of_a_terminal_is_a_duplicate(self):
        window = {"name": self.ROOT["name"], "control_type": 50032, "automation_id": "gx-1"}
        twin = {"name": self.ROOT["name"], "control_type": 50033, "automation_id": "gx-11"}
        self.assertEqual([self.ROOT], popup.terminal_elements([window, self.ROOT]))
        self.assertEqual([], popup.duplicate_panes([window, self.ROOT]))
        self.assertEqual([twin], popup.duplicate_panes([window, self.ROOT, twin]))


class EventJudgmentTests(unittest.TestCase):
    """UIA-06 (D-03 N2-N4): what the keyboard move is expected to report."""

    def test_the_menu_expects_the_item_after_the_focused_one(self):
        items = [{"name": "New Tab", "control_type": 50011, "focusable": True, "focused": True},
                 {"name": "Language", "control_type": 50020, "focusable": False},
                 {"name": "New Window", "control_type": 50011, "focusable": True, "focused": False}]
        before, expected = popup.next_after_focus(items, popup.UIA_MENU_ITEM)
        self.assertEqual(("New Tab", "New Window"), (before["name"], expected["name"]))
        self.assertEqual((None, None), popup.next_after_focus(items[2:], popup.UIA_MENU_ITEM))

    def test_the_palette_expects_the_row_after_the_selected_one(self):
        row = {"control_type": 50007, "patterns": {"selection_item": True}}
        rows = [row | {"name": "Split Right", "selected": True}, row | {"name": "Split Left", "selected": False}]
        before, expected = popup.next_after_selection(rows)
        self.assertEqual(("Split Right", "Split Left"), (before["name"], expected["name"]))
        self.assertEqual((None, None), popup.next_after_selection(rows[:1]))

    def test_only_events_after_the_ready_file_count(self):
        events = [{"name": "New Tab", "after_ready": False}, {"name": "New Window", "after_ready": True}]
        self.assertEqual([events[1]], popup.later_events(events))
        self.assertEqual([], popup.later_events(events, name="New Tab"))

    def test_an_observing_worker_must_be_ready_with_its_subscriptions(self):
        # Review round 4: the controller checks the handshake before any key.
        ready = {"registered": False, "focus_registered": True, "selection_registered": False}
        self.assertEqual([], popup.missing_subscriptions(ready, ["--observe-focus"]))
        self.assertEqual(["selection_registered"], popup.missing_subscriptions(ready, ["--observe-focus", "--observe-selection"]))
        self.assertEqual(["focus_registered"], popup.missing_subscriptions({}, ["--observe-focus"]))
        self.assertEqual([], popup.missing_subscriptions({}, []))

    SEARCH = {"name": "Search", "automation_id": "gx-11", "control_type": 50004, "focused": True}
    LANGUAGE = {"name": "Language", "automation_id": "gx-13", "control_type": 50007, "focused": True}
    THEME = {"name": "", "automation_id": "gx-11", "control_type": 50004, "focused": True}

    def event(self, element, after_ready=True):
        return {key: element[key] for key in ("name", "automation_id", "control_type")} | {"after_ready": after_ready}

    def test_settings_tab_needs_an_initial_focus_and_the_event_of_the_new_one(self):
        # Review round 4 (N4): the event must come from the element that has
        # the focus after Tab, told apart from the one before by type and name
        # too: Settings ids are hit positions (gx-11 before and after).
        heard = [self.event(self.THEME)]
        self.assertEqual([], popup.settings_tab_failures(self.LANGUAGE, self.THEME, heard))
        self.assertEqual([], popup.settings_tab_failures(self.SEARCH, self.THEME, heard))
        self.assertIn("no element had the keyboard focus before Tab", popup.settings_tab_failures(None, self.THEME, heard))
        self.assertIn("Tab left the focus on the same element", popup.settings_tab_failures(self.THEME, dict(self.THEME), heard))
        failures = popup.settings_tab_failures(self.LANGUAGE, None, heard)
        self.assertIn("no element has the keyboard focus after Tab", failures)
        # Another element's event, or the new one's from before ready, is no proof.
        for events in ([self.event(self.SEARCH)], [self.event(self.LANGUAGE)], [self.event(self.THEME, after_ready=False)], []):
            with self.subTest(events=events):
                self.assertEqual(1, len(popup.settings_tab_failures(self.LANGUAGE, self.THEME, events)))

    def test_the_focused_element_is_the_only_one_with_the_keyboard_focus(self):
        other = {"name": "Close", "automation_id": "gx-3", "control_type": 50000, "focused": False}
        self.assertEqual(self.LANGUAGE, popup.focused_element([other, self.LANGUAGE]))
        self.assertIsNone(popup.focused_element([other]))
        self.assertIsNone(popup.focused_element([self.LANGUAGE, self.THEME]))
        rows = popup.check_focus_rows(self.THEME)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "plan.json"
            path.write_text(json.dumps(rows), encoding="utf-8")
            self.assertEqual(rows, worker.read_plan(path))
        self.assertEqual([("gx-11", "check_focus", True, True)],
                         [(r["automation_id"], r["operation"], r["expect_focus"], r["expect_focused_element"]) for r in rows])

    def test_terminal_and_event_checks_run_on_their_own(self):
        base = ["--exe", "ghostty.exe", "--sha256", "a" * 64, "--out", "unused"]
        for extra in (["--terminal-checks", "--actions"], ["--event-checks", "--readonly-root"]):
            with self.subTest(extra=extra), self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                popup.main(base + extra)


if __name__ == "__main__":
    unittest.main()
