"""Offline rejection and scheduling tests; no WSL, GUI, build, or real timing."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_perf as perf
import gx_perf_gtk as gtk


def write(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = {"commit": "a" * 40, "tree": "b" * 40, "dirty": False, "dirty_paths": ""}
        self.exe = {"path": "/clone/zig-out/bin/ghostty", "sha256": "c" * 64,
                    "size": 1000, "inode": 123, "device": 1, "mtime_ns": 9}
        self.cap = {"exe_sha256": self.exe["sha256"], "source": self.source,
                    "metrics": {"proc.snapshot": "", "profiles.path_scan": "",
                                "menu.open.total": "ms", "settings.open.total": "ms"}}
        self.spec = {"case": "p4", "tabs": 1, "run": 1, "capabilities": self.cap}
        self.receipt = {"schema": "gx-gtk-build-v1", "producer": "gx_wsl.py build", "build_exit": 0,
                        "build_argv": ["python3", "scripts/zigw.py", "build", "-Dapp-runtime=gtk", "-Doptimize=fast"],
                        "source_before": self.source, "source_after": self.source, "executable": self.exe,
                        "version": "Ghostty 0.0.3+aaaaaaaaa\nbuild mode: fast\n", "version_exit": 0,
                        "perf_eligible": True}
        self.capture = {"schema": "gx-gtk-action-capture-v1", "case": "p4", "tabs": 1,
                        "status": "CAPTURED", "capabilities": self.cap, "source": self.source,
                        "source_end": self.source, "executable": self.exe, "version": self.receipt["version"],
                        "perf_enabled": True, "intervals": [], "observations": [],
                        "effective_env": {"GHOSTTY_GX_PERF": "1", "GHOSTTY_LOG": "stderr", "GDK_BACKEND": "x11", "DISPLAY": ":99",
                                          "XDG_CONFIG_HOME": "/tmp/config", "XDG_STATE_HOME": "/tmp/state"}}
        self.log = b"startup evidence\ninfo(gx_perf): startup.shown 100us\n"
        for kind in ("menu", "settings"):
            for index in range(4):
                before = self.mark(len(self.log) * 1_000_000)
                self.log += f"info(gx_perf): {kind}.open.total {10000 if index == 0 else [0, 1000, 5000, 9000][index]}us\r\n".encode()
                after = self.mark(len(self.log) * 1_000_000)
                self.capture["intervals"].append({"name": kind, "open": index,
                    "phase": "warmup" if index == 0 else "hot", "before": before, "after": after})
                self.capture["observations"] += [
                    {"widget": kind, "opened": opened, "complete": True, "live": before["live"], "nodes": [{"role": "dialog"}],
                     "ns": before["ns"] + offset} for opened, offset in ((True, 1), (False, 2))]
        self.save()

    def mark(self, ns):
        return {"offset": len(self.log), "sha256": hashlib.sha256(self.log).hexdigest(), "ns": ns,
                "device": 1, "inode": 2, "live": {"pid": 100, "birth": 200}}

    def save(self):
        write(self.root / "receipt.json", self.receipt)
        self.capture["receipt_sha256"] = hashlib.sha256((self.root / "receipt.json").read_bytes()).hexdigest()
        write(self.root / "capture.json", self.capture)
        (self.root / "perf.log").write_bytes(self.log)
        (self.root / "version.txt").write_text(self.receipt["version"], encoding="utf-8")
        write(self.root / "perf-meta.json", {"valid": True, "exit": 0, "identity": {"sha256": self.exe["sha256"]},
              "artifact_sha256": {name: hashlib.sha256((self.root / name).read_bytes()).hexdigest()
                                  for name in ("capture.json", "receipt.json", "perf.log", "version.txt")}})

    def reduce(self):
        return gtk.reduce_capture(self.root, self.spec)

    def test_three_hot_values_median_and_units(self):
        result = self.reduce()
        self.assertEqual(result["values"]["menu.open.total"], 5)
        self.assertEqual(result["values"]["settings.profiles.path_scan"], 0)
        self.assertEqual(result["units"]["menu.open.total"], "ms")
        self.assertEqual(result["units"]["settings.profiles.path_scan"], "")
        self.assertEqual(result["intervals"][0]["parsed"]["open_ms"], 10)

    def test_missing_receipt(self):
        (self.root / "receipt.json").unlink()
        with self.assertRaises(OSError):
            self.reduce()

    def test_debug_rejected_even_with_eligible_flag(self):
        self.receipt["version"] = self.capture["version"] = self.receipt["version"].replace("fast", "Debug")
        self.save()
        with self.assertRaises(ValueError):
            self.reduce()

    def test_dirty_or_changed_source_rejected(self):
        self.capture["source_end"] = {**self.source, "dirty": True}
        self.save()
        with self.assertRaises(perf.PerfError):
            self.reduce()

    def test_missing_and_truncated_log(self):
        for raw in (b"", self.log[:-1], self.log.replace(b"startup", b"changed")):
            with self.subTest(raw=raw[:10]):
                (self.root / "perf.log").write_bytes(raw)
                with self.assertRaises(perf.PerfError):
                    self.reduce()
        (self.root / "perf.log").unlink()
        with self.assertRaises(OSError):
            self.reduce()

    def test_incomplete_three_hot_samples_rejected(self):
        self.capture["intervals"].pop()
        self.save()
        with self.assertRaisesRegex(perf.PerfError, "three hot"):
            self.reduce()

    def test_failed_smoke_not_accepted(self):
        write(self.root / "perf-meta.json", {"valid": False, "exit": 1})
        with self.assertRaises(perf.PerfError):
            self.reduce()

    def test_missing_instrumentation_unknown_not_zero(self):
        self.cap["metrics"].clear()
        self.save()
        self.assertIsNone(self.reduce()["values"]["menu.profiles.path_scan"])
        self.assertIsNone(gtk.metric(b"", "proc.snapshot", "", {}))

    def test_wrong_capability_hash_rejected(self):
        self.cap["exe_sha256"] = "0" * 64
        self.save()
        with self.assertRaisesRegex(perf.PerfError, "unbound"):
            self.reduce()

    def test_p2_zero_requires_identity_and_full_duration(self):
        self.spec["case"] = self.capture["case"] = "p2"
        before = self.mark(1_000_000_000)
        after = self.mark(61_100_000_000)
        states = [{"ns": i * 1_000_000_000, "live": before["live"], "windows": ["99"],
                   "shells": [{"exe": "/bin/bash", "fd0": "/dev/pts/1"}]} for i in range(1, 62)]
        self.capture["intervals"] = [{"name": "idle", "before": before, "after": after, "states": states}]
        for state in states:
            state["response"] = self.response(state["ns"])
        self.capture["intervals"][0]["end_state"] = {
            **states[-1], "ns": 61_200_000_000, "response": self.response(61_200_000_000)}
        self.save()
        self.assertEqual(self.reduce()["values"]["proc.snapshot"], 0)
        self.capture["intervals"][0]["after"]["live"] = {"pid": 101, "birth": 200}
        self.save()
        with self.assertRaisesRegex(perf.PerfError, "identity"):
            self.reduce()

    @staticmethod
    def response(ns):
        return {"protocol": "_NET_WM_PING", "window": "99", "token": ns % 0xffffffff + 1,
                "sent_ns": ns - 2, "received_ns": ns - 1, "deadline_ns": ns - 2 + 1_000_000_000}

    def test_p2_rejects_missing_middle_late_and_missing_end_response(self):
        self.test_p2_zero_requires_identity_and_full_duration()
        item = self.capture["intervals"][0]
        item["after"]["live"] = item["before"]["live"]
        original = copy.deepcopy(item)
        for failure in ("middle", "late", "end", "reused"):
            with self.subTest(failure=failure):
                item = copy.deepcopy(original)
                if failure == "middle":
                    item["states"][30].pop("response")
                elif failure == "late":
                    item["states"][30]["response"]["received_ns"] += 2_000_000_000
                elif failure == "end":
                    item.pop("end_state")
                else:
                    item["states"][30]["response"] = item["states"][29]["response"]
                self.capture["intervals"] = [item]
                self.save()
                with self.assertRaisesRegex(perf.PerfError, "GUI response"):
                    self.reduce()

    def test_time_count_conflict_and_negative_count(self):
        for raw in (b"info(gx_perf): proc.snapshot 1us\n", b"info(gx_perf): metric proc.snapshot -1\n",
                    b"info(gx_perf): metric proc.snapshot 1.5\n", b"info(gx_perf): proc.snapshot bad\n"):
            with self.subTest(raw=raw), self.assertRaises(perf.PerfError):
                gtk.metric(raw, "proc.snapshot", "", self.cap)

    def test_missing_widget_state_is_not_timing_success(self):
        self.capture["observations"].pop()
        self.save()
        with self.assertRaisesRegex(perf.PerfError, "state observations"):
            self.reduce()

    def test_partial_last_close_rejected_and_originals_retained(self):
        self.capture["observations"][-1]["complete"] = False
        self.save()
        originals = {p: p.read_bytes() for p in self.root.iterdir()}
        with self.assertRaises(perf.PerfError):
            self.reduce()
        self.assertEqual(originals, {p: p.read_bytes() for p in self.root.iterdir()})

    def test_p2_without_gui_response_cannot_reduce_to_zero(self):
        self.spec["case"] = self.capture["case"] = "p2"
        before, after = self.mark(1_000_000_000), self.mark(61_100_000_000)
        states = [{"ns": i * 1_000_000_000, "live": before["live"], "windows": ["99"],
                   "shells": [{"exe": "/bin/bash", "fd0": "/dev/pts/1"}]} for i in range(1, 62)]
        self.capture["intervals"] = [{"name": "idle", "before": before, "after": after, "states": states}]
        self.save()
        with self.assertRaises(perf.PerfError):
            self.reduce()

    def test_time_metric_never_synthesizes_zero(self):
        item = self.capture["intervals"][1]
        item["after"] = {**item["before"], "ns": item["after"]["ns"]}
        self.save()
        with self.assertRaisesRegex(perf.PerfError, "exactly one"):
            self.reduce()

    def test_receipt_ineligible(self):
        self.receipt["perf_eligible"] = False
        self.save()
        with self.assertRaisesRegex(perf.PerfError, "eligible"):
            self.reduce()

    def test_disabled_log_rejected(self):
        self.capture["effective_env"]["GHOSTTY_LOG"] = "false"
        self.save()
        with self.assertRaisesRegex(perf.PerfError, "environment"):
            self.reduce()

    def test_only_gtk_warning_is_not_counter_channel(self):
        raw = b"Gtk-WARNING: no session manager\n"
        self.assertFalse(gtk.log_channel(raw))
        self.assertIsNone(gtk.metric(raw, "proc.snapshot", "", self.cap, gtk.log_channel(raw)))
        self.assertEqual(gtk.metric(b"", "proc.snapshot", "", self.cap, True), [])


class ProbeTests(unittest.TestCase):
    def test_x11_requires_advertised_ping_and_matching_root_reply(self):
        import ctypes as c
        import contextlib
        import io
        for supported in (False, True):
            lib = Mock()
            lib.XOpenDisplay.return_value = 1
            lib.XDefaultRootWindow.return_value = 10
            lib.XInternAtom.side_effect = [20, 30]
            atoms = (c.c_ulong * 1)(30 if supported else 40)
            def protocols(display, window, ptr, count):
                c.cast(ptr, c.POINTER(c.POINTER(c.c_ulong)))[0] = c.cast(atoms, c.POINTER(c.c_ulong))
                c.cast(count, c.POINTER(c.c_int))[0] = 1
                return 1
            lib.XGetWMProtocols.side_effect = protocols
            def send(display, window, propagate, mask, ptr):
                event = c.cast(ptr, lib.XSendEvent.argtypes[-1]).contents.client
                self.assertEqual((window, event.window, event.type, event.format), (99, 99, 33, 32))
                self.assertEqual(list(event.data.l[:3]), [30, 8, 99])
                return 1
            lib.XSendEvent.side_effect = send
            replies = [(99, 8, 99), (10, 7, 99), (10, 8, 100), (10, 8, 99)]
            def next_event(display, ptr):
                root, token, target = replies.pop(0)
                event = c.cast(ptr, lib.XNextEvent.argtypes[-1]).contents.client
                event.type, event.send_event, event.window = 33, 1, root
                event.message_type, event.format = 20, 32
                event.data.l[:3] = (30, token, target)
                return 0
            lib.XNextEvent.side_effect = next_event
            output = io.StringIO()
            with patch("ctypes.CDLL", return_value=lib), contextlib.redirect_stdout(output):
                if supported:
                    gtk.x11_ping(99, 8)
                    self.assertEqual(json.loads(output.getvalue())["token"], 8)
                    self.assertEqual(lib.XNextEvent.call_count, 4)
                else:
                    with self.assertRaisesRegex(ValueError, "advertise"):
                        gtk.x11_ping(99, 8)
                    lib.XSendEvent.assert_not_called()
            lib.XCloseDisplay.assert_called_once_with(1)

    def test_ping_success_timeout_wrong_reply_and_late_response(self):
        import subprocess
        reply = {"protocol": "_NET_WM_PING", "window": "99", "token": 8}
        with patch("secrets.randbelow", return_value=7), patch("subprocess.run") as run:
            run.return_value = Mock(stdout=json.dumps(reply))
            with patch("time.monotonic_ns", side_effect=[100, 200]):
                self.assertEqual(gtk.gui_roundtrip(99)["token"], 8)
            self.assertEqual(run.call_args.kwargs["timeout"], 1)
            run.side_effect = subprocess.TimeoutExpired("ping", 1)
            with self.assertRaisesRegex(ValueError, "GUI response failed"):
                gtk.gui_roundtrip(99)
            run.side_effect = None
            for changed in ({**reply, "token": 9}, {**reply, "window": "100"}, {}):
                run.return_value = Mock(stdout=json.dumps(changed))
                with patch("time.monotonic_ns", side_effect=[100, 200]), self.assertRaises(ValueError):
                    gtk.gui_roundtrip(99)
            run.return_value = Mock(stdout=json.dumps(reply))
            with patch("time.monotonic_ns", side_effect=[100, 1_000_000_101]), self.assertRaises(ValueError):
                gtk.gui_roundtrip(99)

    def test_partial_retry_success_and_deadline_failure(self):
        now, attempts = [0.0], []
        def sleep(delay):
            now[0] += delay
        rows = [{"name": "main", "role": "frame"}]
        read = Mock(side_effect=[ValueError("partial"), rows])
        self.assertEqual(gtk.await_tree(read, lambda r: r == rows, attempts.append,
                                        lambda: now[0], sleep), rows)
        self.assertEqual(attempts, [{"complete": False, "error": "partial"}])
        read = Mock(side_effect=ValueError("partial"))
        with self.assertRaisesRegex(ValueError, "deadline"):
            gtk.await_tree(read, lambda r: True, attempts.append, lambda: now[0], sleep)
        self.assertTrue(all(not a["complete"] for a in attempts))
        self.assertLess(now[0], 5.2)

    def test_snapshot_subprocess_is_bounded_and_preserves_stderr(self):
        import subprocess
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(
                1, "snapshot", output="partial raw", stderr="GError raw")) as run:
            with self.assertRaisesRegex(ValueError, "GError raw"):
                gtk.accessibility_reader(100)(0.25)
            self.assertEqual(run.call_args.kwargs["timeout"], 0.25)

    def test_complete_mismatch_retained_before_unknown_deadline(self):
        now, attempts = [0.0], []
        rows = [{"name": "Main Menu", "role": "toggle button"}]
        def read(timeout):
            if not attempts:
                now[0] = 4.8
                return rows
            now[0] += timeout
            raise ValueError("snapshot timed out")
        def sleep(delay):
            now[0] += delay
        with self.assertRaisesRegex(ValueError, "deadline"):
            gtk.await_tree(read, lambda r: False, attempts.append, lambda: now[0], sleep)
        self.assertEqual(attempts, [
            {"complete": True, "nodes": rows, "matched": False, "within_deadline": True},
            {"complete": False, "error": "snapshot timed out"}])

    def test_matching_tree_after_deadline_retained_but_rejected(self):
        now, attempts = [0.0], []
        rows = [{"name": "Settings", "role": "dialog"}]
        def read(timeout):
            now[0] = 5.0
            return rows
        with self.assertRaisesRegex(ValueError, "deadline"):
            gtk.await_tree(read, lambda r: True, attempts.append, lambda: now[0], Mock())
        self.assertEqual(attempts, [
            {"complete": True, "nodes": rows, "matched": True, "within_deadline": False}])

    def test_atspi_complete_or_partial_and_gerror(self):
        import ctypes
        for failure in (None, "count", "child", "error", "state", "name", "pid"):
            with self.subTest(failure=failure):
                lib, glib, obj = Mock(), Mock(), Mock()
                buffers = [ctypes.create_string_buffer(b"main"), ctypes.create_string_buffer(b"frame")]
                lib.atspi_init.return_value = 0
                lib.atspi_get_desktop.return_value = 1
                lib.atspi_accessible_get_child_count.side_effect = lambda node, err: (1 if node == 1 else
                    -1 if failure == "count" else 1 if failure == "child" else 0)
                lib.atspi_accessible_get_child_at_index.side_effect = lambda node, index, err: 2 if node == 1 else None
                lib.atspi_accessible_get_process_id.return_value = 0 if failure == "pid" else 100
                lib.atspi_accessible_get_state_set.return_value = None if failure == "state" else 3
                lib.atspi_state_set_contains.side_effect = lambda state, flag: flag == 25
                lib.atspi_accessible_get_name.return_value = None if failure == "name" else ctypes.addressof(buffers[0])
                lib.atspi_accessible_get_role_name.return_value = ctypes.addressof(buffers[1])
                if failure == "error":
                    def fail(node, err):
                        ctypes.cast(err, ctypes.POINTER(ctypes.c_void_p))[0] = 42
                        return 0
                    lib.atspi_accessible_get_child_count.side_effect = fail
                    lib.atspi_accessible_get_child_count.__name__ = "child_count"
                with patch("ctypes.CDLL", side_effect=[lib, glib, obj]):
                    if failure:
                        with self.assertRaisesRegex(ValueError, "partial_nodes"):
                            gtk.accessibility_snapshot(100)
                    else:
                        self.assertEqual(gtk.accessibility_snapshot(100), [
                            {"name": "main", "role": "frame", "path": [0], "parent": None}])
                if failure == "error":
                    glib.g_error_free.assert_called_once()
                obj.g_object_unref.assert_any_call(1)

    def test_snapshot_paths_keep_hidden_parent_and_release_on_failure(self):
        import ctypes
        # Desktop -> app -> hidden container -> two visible menu items.
        tree = {1: [2], 2: [3], 3: [4, 5], 4: [], 5: []}
        for failure in (False, True):
            with self.subTest(failure=failure):
                lib, glib, obj = Mock(), Mock(), Mock()
                empty = ctypes.create_string_buffer(b"")
                role = ctypes.create_string_buffer(b"menu item")
                lib.atspi_init.return_value = 0
                lib.atspi_get_desktop.return_value = 1
                lib.atspi_accessible_get_child_count.side_effect = lambda n, e: len(tree[n])
                lib.atspi_accessible_get_child_at_index.side_effect = lambda n, i, e: tree[n][i]
                lib.atspi_accessible_get_process_id.return_value = 100
                lib.atspi_accessible_get_state_set.side_effect = lambda n: n + 10
                lib.atspi_state_set_contains.side_effect = lambda s, f: f == 25 and s in (14, 15)
                def get_name(n, e):
                    if failure and n == 5:
                        ctypes.cast(e, ctypes.POINTER(ctypes.c_void_p))[0] = 42
                    return ctypes.addressof(empty)
                lib.atspi_accessible_get_name.side_effect = get_name
                lib.atspi_accessible_get_name.__name__ = "get_name"
                lib.atspi_accessible_get_role_name.return_value = ctypes.addressof(role)
                expected = [{"name": "", "role": "menu item", "path": [0, 0, i],
                             "parent": [0, 0]} for i in range(2)]
                with patch("ctypes.CDLL", side_effect=[lib, glib, obj]):
                    if failure:
                        with self.assertRaises(ValueError) as raised:
                            gtk.accessibility_snapshot(100)
                        detail = json.loads(str(raised.exception))
                        self.assertEqual(detail["partial_nodes"], expected[:1])
                        self.assertIn("get_name", detail["error"])
                        glib.g_error_free.assert_called_once()
                    else:
                        self.assertEqual(gtk.accessibility_snapshot(100), expected)
                self.assertEqual([call.args[0] for call in lib.atspi_accessible_get_name.call_args_list], [4, 5])
                self.assertCountEqual([call.args[0] for call in obj.g_object_unref.call_args_list],
                                      [1, 2, 3, 4, 5, 12, 13, 14, 15])
                self.assertEqual(glib.g_free.call_count, 3 if failure else 4)


class WidgetStateTests(unittest.TestCase):
    @staticmethod
    def embedded_settings():
        return ([{"role": "panel", "name": "Settings", "path": [0, 3]}] +
                [{"role": "page tab", "name": name, "path": [0, 3, 1, i]}
                 for i, name in enumerate(("Language", "Appearance", "Font", "Interaction", "Shell", "About"))] +
                [{"role": "push button", "name": "Close", "path": [0, 3, 2]}])

    def test_gtk_414_embedded_settings_panel(self):
        # Adw 1.5 exposes the in-window Settings dialog as a panel. The six
        # page tabs and its own Close button identify that panel's subtree.
        self.assertTrue(gtk.widget_state(self.embedded_settings(), "settings"))

    def test_settings_panel_incomplete_or_foreign_subtree_is_unknown(self):
        for change in (lambda rows: rows.pop(), lambda rows: rows.pop(1),
                       lambda rows: rows[-1].update(path=[0, 4, 2]),
                       lambda rows: rows[1].update(path=[0, 4, 1, 0])):
            rows = self.embedded_settings()
            change(rows)
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                gtk.widget_state(rows, "settings")

    def test_settings_panel_requires_snapshot_local_paths(self):
        for path in (None, [], "0/3", [0, -3], [False, 3]):
            rows = self.embedded_settings()
            rows[0]["path"] = path
            with self.subTest(path=path), self.assertRaises(ValueError):
                gtk.widget_state(rows, "settings")

    def test_settings_multiple_representations_are_ambiguous(self):
        rows = self.embedded_settings() + [{"role": "dialog", "name": "Settings"}]
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            gtk.widget_state(rows, "settings")

    def test_gtk_414_main_menu_without_gmenu_item_labels(self):
        # Observed in the complete p4-gtk-r7-20261019-03 AT-SPI snapshots:
        # GMenu item labels are absent, but the showing menu object is named.
        rows = [{"role": "frame", "name": "terminal"},
                {"role": "toggle button", "name": "Main Menu"},
                {"role": "menu", "name": "Main Menu"},
                {"role": "push button", "name": "Reset Zoom"},
                {"role": "push button", "name": "Find…"}]
        self.assertTrue(gtk.widget_state(rows, "menu"))

    def test_header_button_does_not_prove_open_menu(self):
        self.assertFalse(gtk.widget_state([
            {"role": "toggle button", "name": "Main Menu"},
            {"role": "push button", "name": "Main Menu"}], "menu"))

    def test_unrelated_labels_do_not_prove_open_menu(self):
        self.assertFalse(gtk.widget_state([
            {"role": "label", "name": name}
            for name in ("New Tab", "Quit", "Keyboard Shortcuts")], "menu"))

    def test_other_menu_does_not_prove_main_menu(self):
        self.assertFalse(gtk.widget_state([
            {"role": "menu", "name": "Launch Profiles and Splits"}], "menu"))

    def test_ambiguous_widgets_are_unknown_not_closed(self):
        for kind, role, name in (("menu", "menu", "Main Menu"),
                                 ("settings", "dialog", "Settings")):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "ambiguous"):
                gtk.widget_state([{"role": role, "name": name}] * 2, kind)

    def test_settings_requires_dialog_and_unknown_kind_rejected(self):
        self.assertTrue(gtk.widget_state([{"role": "dialog", "name": "Settings"}], "settings"))
        self.assertFalse(gtk.widget_state([{"role": "push button", "name": "Settings"}], "settings"))
        with self.assertRaises(ValueError):
            gtk.widget_state([], "unknown")


class DriverTests(unittest.TestCase):
    def test_probe_cost_does_not_accumulate(self):
        now = [100.0]
        def sleep(seconds):
            now[0] += seconds
        observed = []
        for index in gtk.idle_ticks(lambda: now[0], sleep):
            observed.append(now[0])
            now[0] += 0.1  # Non-zero process/hash probe cost.
        self.assertEqual(len(observed), 60)
        self.assertEqual(observed, [101.0 + i for i in range(60)])
        self.assertAlmostEqual(now[0], 160.1)

    def test_nonstandard_run_count_rejected_before_wsl(self):
        args = argparse.Namespace(clone=["/new"], label=[], case="p4", runs=9)
        with patch.object(gtk.gx_wsl, "main") as call, self.assertRaises(ValueError):
            gtk.run(args)
        call.assert_not_called()

    def test_abba_and_cross_tab_order(self):
        rows = gtk.planned(["old", "new"], 10, "p2")
        self.assertEqual([(r["label"], r["tabs"]) for r in rows[:8]],
                         [("old", 1), ("old", 11), ("new", 1), ("new", 11),
                          ("new", 11), ("new", 1), ("old", 11), ("old", 1)])
        self.assertEqual(len({r["path"] for r in rows}), 40)

    def test_script_compiles_uses_public_scope_and_not_load(self):
        script = gtk.scenario({"case": "p4", "tabs": 1, "run": 1, "capabilities": {}})
        compile(script, "scenario", "exec")
        self.assertTrue(script.startswith("# gx-scenario-python-v1\n"))
        self.assertNotIn("3000000", script)
        self.assertNotIn("zigw.py build", script)

    def test_first_failure_stops_without_retry_retains_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = argparse.Namespace(clone=["/old", "/new"], label=[], case="p2", runs=10,
                                      env=[], label_env=[], capabilities=[], out=Path(tmp), distro=None, json=None)
            with patch.object(gtk.gx_wsl, "main", return_value=1) as call:
                self.assertEqual(gtk.run(args), 2)
                self.assertEqual(call.call_count, 1)
                argv = call.call_args.args[0]
                self.assertNotIn("--perf", argv)
                self.assertIn("smoke", argv)
            plan = json.loads((Path(tmp) / "plan.json").read_text())
            self.assertEqual(len(plan["runs"]), 40)
            self.assertEqual(plan["runs"][0]["status"], "ERROR")
            self.assertTrue(all(r["status"] == "pending" for r in plan["runs"][1:]))
            self.assertTrue((Path(tmp) / "old/run-01/tabs-1/driver.py").exists())

    def test_gate_every_round_not_batch_median(self):
        with tempfile.TemporaryDirectory() as tmp:
            batch = {"case": "p4", "labels": ["new"], "errors": [], "runs": gtk.planned(["new"], 10, "p4")}
            for row in batch["runs"]:
                row.update(status="captured", measurement={"source": {"commit": "a"}, "exe_sha256": "b",
                           "effective_env": {},
                           "values": {"menu.open.total": 7 if row["run"] == 10 else 1,
                                      "menu.profiles.path_scan": 0, "settings.open.total": 2,
                                      "settings.profiles.path_scan": 0}})
            self.assertEqual(gtk.finish(Path(tmp), batch), 4)
            result = json.loads((Path(tmp) / "RESULT.json").read_text())
            self.assertEqual(result["absolute_gates"]["new"], "FAIL")
            self.assertEqual(result["metrics"]["new"]["tabs-1.menu.open.total"]["n"], 10)
            self.assertEqual(result["metrics"]["new"]["tabs-1.menu.open.total"]["unit"], "ms")


if __name__ == "__main__":
    unittest.main()
