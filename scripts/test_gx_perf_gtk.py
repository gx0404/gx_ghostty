"""Offline rejection and scheduling tests; no WSL, GUI, build, or real timing."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

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
                        "build_argv": ["python3", "scripts/zigw.py", "build", "-Dapp-runtime=gtk", "-Doptimize=ReleaseFast"],
                        "source_before": self.source, "source_after": self.source, "executable": self.exe,
                        "version": "Ghostty 0.0.3+aaaaaaaaa\nbuild mode: ReleaseFast\n", "version_exit": 0,
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
                    {"widget": kind, "opened": opened, "live": before["live"], "nodes": [{"role": "dialog"}],
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
        self.receipt["version"] = self.capture["version"] = self.receipt["version"].replace("ReleaseFast", "Debug")
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
        self.save()
        self.assertEqual(self.reduce()["values"]["proc.snapshot"], 0)
        self.capture["intervals"][0]["after"]["live"] = {"pid": 101, "birth": 200}
        self.save()
        with self.assertRaisesRegex(perf.PerfError, "identity"):
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
