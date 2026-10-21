"""Offline tests for the on-server collector embedded in vps-proxy/setup-monitor.sh.

Run: python3 -B vps-proxy/tests/test_vps_app.py
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SETUP = HERE.parent / "setup-monitor.sh"


def load_collector():
    source = os.environ.get("LOTUS_COLLECTOR_SOURCE")
    if source:
        text = Path(source).read_text()
    else:
        script = SETUP.read_text()
        m = re.search(r"cat >\"\$tmpapp\" <<'PYEOF'\n(.*?)\nPYEOF\n", script, re.S)
        if not m:
            raise RuntimeError("collector heredoc not found in setup-monitor.sh")
        text = m.group(1)
    path = Path(tempfile.mkdtemp()) / "lotus_vps_app.py"
    path.write_text(text)
    spec = importlib.util.spec_from_file_location("lotus_vps_app", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, text


app, APP_SOURCE = load_collector()

BOOT = 1_760_000_000
T0 = 1_761_000_000  # 2025-10-20 22:40 UTC


def stats(ts, total=100000, idle=90000, tx=10**9, rx=2 * 10**9, boot=BOOT, proxy="running", since=BOOT + 30,
          reboot=False, vn_tx=5 * 10**9, month=None, busy=False):
    if busy:
        return {"schema": 1, "ts": ts, "error": "busy"}
    month = month or __import__("time").strftime("%Y-%m", __import__("time").gmtime(ts))
    return {
        "schema": 1, "ts": ts, "duration_ms": 1010,
        "host": {"ok": True, "hostname": "lotus", "os": "Ubuntu 24.04.3 LTS", "kernel": "6.8.0", "boot_ts": boot,
                 "uptime_s": ts - boot, "interface": "enp1s0", "ipv4": ["144.202.127.142", "10.0.0.1"],
                 "ipv6": ["2001:19f0::1"]},
        "memory": {"ok": True, "total_bytes": 1_000_000_000, "used_bytes": 400_000_000, "available_bytes": 600_000_000,
                   "swap_total_bytes": 0, "swap_used_bytes": 0},
        "disk": {"ok": True, "total_bytes": 25_000_000_000, "used_bytes": 5_000_000_000, "available_bytes": 19_000_000_000},
        "proxy": {"ok": True, "unit": "sing-box", "status": proxy, "since_ts": since if proxy == "running" else None,
                  "restarts": 0, "version": "1.12.0", "port": 443, "listening": proxy == "running", "established": 7},
        "traffic": {"ok": True, "source": "vnstat", "month": month, "rx_bytes": 9 * 10**9, "tx_bytes": vn_tx,
                    "tracking_since": "2025-10-01"},
        "counters": {"ok": True, "interface": "enp1s0", "rx_bytes": rx, "tx_bytes": tx},
        "system": {"ok": True, "reboot_required": reboot},
        "cpu": {"ok": True, "percent": 12.5, "window_s": 1.0, "cores": 1, "load": [0.1, 0.2, 0.3],
                "counters": {"total": total, "idle": idle}},
    }


class Clock:
    def __init__(self, t):
        self.t = t

    def __call__(self):
        return self.t


class CollectorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "state").mkdir()
        (root / "etc").mkdir()
        self.patch = mock.patch.multiple(app, STATE_DIR=str(root / "state"), CONFIG_DIR=str(root / "etc"))
        self.patch.start()
        self.etc = root / "etc"
        self.clock = Clock(T0)
        self.outputs = []

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def runner(self):
        item = self.outputs.pop(0)
        if isinstance(item, tuple):
            return item
        return 0, json.dumps(item) + "\n"

    def collect(self, **kw):
        self.outputs.append(stats(int(self.clock.t), **kw))
        return app.collect(self.clock, self.runner)

    def snap(self):
        return app.snapshot(app.load(), app.settings(), self.clock())

    def test_first_sample_is_online_with_one_second_cpu(self):
        self.assertIsNone(self.collect())
        s = self.snap()
        self.assertEqual(s["state"], "online")
        self.assertEqual(s["overall"], "Healthy")
        self.assertEqual(s["source"], "vps")
        self.assertEqual(s["host"], "144.202.127.142")
        self.assertEqual(s["derived"]["cpu"]["basis"], "One-second sample")
        self.assertEqual(s["next_check_at"], T0 + 300)
        self.assertEqual(s["derived"]["traffic"]["used_bytes"], 5 * 10**9)
        self.assertEqual(s["derived"]["traffic"]["quota_bytes"], 1024 * 10**9)

    def test_second_sample_averages_cpu_and_rates(self):
        self.collect()
        self.clock.t += 300
        self.collect(total=130000, idle=117000, tx=10**9 + 300 * 2000)
        s = self.snap()
        self.assertEqual(s["derived"]["cpu"]["percent"], 10.0)
        self.assertTrue(s["derived"]["cpu"]["basis"].startswith("Average"))
        self.assertEqual(s["series"][-1]["tx_bps"], 2000)
        self.assertEqual(len(s["series"]), 2)

    def test_stale_after_timer_stops(self):
        self.collect()
        self.clock.t += app.STALE_AFTER + 1
        s = self.snap()
        self.assertEqual(s["state"], "stale")
        self.assertEqual(s["overall"], "Unknown")

    def test_gap_and_reboot_are_history(self):
        self.collect()
        self.clock.t += 3600
        self.collect(boot=BOOT + 3500, since=BOOT + 3530)
        types = [e["type"] for e in self.snap()["events"]]
        self.assertIn("Monitoring paused", types)
        self.assertIn("VPS rebooted", types)

    def test_proxy_stop_is_bad_and_recorded(self):
        self.collect()
        self.clock.t += 300
        self.collect(proxy="failed")
        s = self.snap()
        self.assertEqual(s["overall"], "Proxy down")
        self.assertEqual(s["tone"], "bad")
        self.assertEqual(s["events"][0]["type"], "Proxy stopped")

    def test_busy_stats_is_retried(self):
        self.outputs.append(stats(int(self.clock.t), busy=True))
        self.outputs.append(stats(int(self.clock.t)))
        with mock.patch.object(app.time, "sleep"):
            self.assertIsNone(app.collect(self.clock, self.runner))
        self.assertEqual(self.snap()["state"], "online")

    def test_failures_keep_last_known_and_record_once(self):
        self.collect()
        for round_ in range(3):
            self.clock.t += 300
            self.outputs.append((1, ""))
            self.assertEqual(app.collect(self.clock, self.runner), "stats_failed")
            if round_ == 0:
                self.assertEqual(self.snap()["state"], "retrying")
        s = self.snap()
        # Last success 15 minutes ago: no longer current, shown as an error with last-known data.
        self.assertEqual(s["state"], "error")
        self.assertEqual(s["overall"], "Attention")
        self.assertIsNotNone(s["server"])
        self.assertEqual(s["error"]["code"], "stats_failed")
        self.assertEqual([e["type"] for e in s["events"]].count("Sampling failed"), 1)
        self.clock.t += 300
        self.collect()
        self.assertEqual(self.snap()["events"][0]["type"], "Sampling recovered")

    def test_quota_steps_fire_once_per_month(self):
        (self.etc / "config.json").write_text(json.dumps({"label": "Vultr LA", "quota_gb": 10}))
        self.collect(vn_tx=8_500_000_000)
        self.clock.t += 300
        self.collect(vn_tx=8_600_000_000)
        s = self.snap()
        self.assertEqual(s["label"], "Vultr LA")
        self.assertEqual([e["type"] for e in s["events"]], ["Traffic 80%", "Traffic 50%"])
        self.assertEqual(s["overall"], "Attention")

    def test_hostile_stats_are_whitelisted(self):
        raw = stats(int(self.clock.t))
        raw["host"]["os"] = "x" * 500
        raw["host"]["ipv4"] = ["127.0.0.1", "not-an-ip", "144.202.127.142"]
        raw["proxy"]["status"] = "rm -rf"
        raw["secret"] = "/etc/sing-box/config.json"
        self.outputs.append(raw)
        app.collect(self.clock, self.runner)
        text = json.dumps(self.snap())
        self.assertNotIn("secret", text)
        self.assertNotIn("rm -rf", text)
        server = self.snap()["server"]
        self.assertEqual(len(server["host"]["os"]), 64)
        self.assertEqual(server["host"]["ipv4"], ["144.202.127.142"])

    def test_forced_command_vocabulary(self):
        self.collect()
        for command, ok in (("", True), ("snapshot", True), ("cat /etc/passwd", False), ("refresh;id", False)):
            out = io.StringIO()
            with mock.patch.dict(os.environ, {"SSH_ORIGINAL_COMMAND": command}), mock.patch.object(sys, "stdout", out):
                rc = app.main(["lotus-vps-app"], self.clock)
            line = json.loads(out.getvalue().strip().splitlines()[-1])
            self.assertEqual(rc == 0, ok, command)
            self.assertEqual("state" in line, ok, command)
        out = io.StringIO()
        with mock.patch.object(sys, "stdout", out):
            self.assertEqual(app.main(["lotus-vps-app", "--anything"], self.clock), 2)

    def test_refresh_respects_cooldown_then_samples(self):
        self.collect()
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"SSH_ORIGINAL_COMMAND": "refresh"}), mock.patch.object(sys, "stdout", out):
            app.main(["lotus-vps-app"], self.clock)
        reply = json.loads(out.getvalue())
        self.assertFalse(reply["refreshed"])
        self.assertGreater(reply["retry_after_s"], 0)
        self.clock.t += 31
        self.outputs.append(stats(int(self.clock.t)))
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"SSH_ORIGINAL_COMMAND": "refresh"}), mock.patch.object(sys, "stdout", out), \
                mock.patch.object(app, "run_stats", self.runner):
            app.main(["lotus-vps-app"], self.clock)
        reply = json.loads(out.getvalue())
        self.assertTrue(reply["refreshed"])
        self.assertEqual(reply["checked_at"], self.clock.t)

    def test_collect_refuses_root(self):
        with mock.patch.object(app.os, "geteuid", return_value=0), mock.patch.object(sys, "stderr", io.StringIO()):
            self.assertEqual(app.main(["lotus-vps-app", "--collect"], self.clock), 2)

    def test_snapshot_shape_matches_lab_reader(self):
        self.collect()
        s = self.snap()
        for key in ("schema", "configured", "label", "host", "state", "overall", "tone", "reasons", "checked_at",
                    "last_success_at", "data_age_s", "next_check_at", "refreshing", "error", "channel", "server",
                    "derived", "series", "series_started_at", "events"):
            self.assertIn(key, s)
        json.dumps(s)
        self.assertLess(len(json.dumps(s)), 4096)

    def test_week_of_samples_stays_small(self):
        for _ in range(7 * 288 + 10):
            self.collect()
            self.clock.t += 300
        state = app.load()
        self.assertLessEqual(len(state["samples"]), 7 * 288 + 1)
        snap = json.dumps(self.snap(), separators=(",", ":"))
        self.assertLess(len(snap), 64 * 1024)

    def test_vultr_figures_are_sanitised_and_key_stays_private(self):
        key = "A" * 36
        (self.etc / "vultr.key").write_text(key + "\n")
        replies = {
            "/account": {"account": {"name": "n", "email": "e@x", "balance": -12.5, "pending_charges": 3.21,
                                     "acls": ["billing"]}},
            "/account/bandwidth": {"bandwidth": {"current_month_to_date": {
                "timestamp_start": "1759276800", "timestamp_end": "1761000000", "gb_in": 12.3, "gb_out": 45.6,
                "overage": 0, "overage_cost": 0}, "current_month_projected": {"gb_out": 70}}},
        }
        seen = []

        class Reply(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        class Opener:
            def open(self, req, timeout):
                seen.append((req.full_url, req.get_header("Authorization")))
                return Reply(json.dumps(replies[req.full_url[len(app.VULTR_API):]]).encode())

        self.assertTrue(app.vultr_due(app.load(), self.clock()))
        info = app.vultr_fetch(self.clock(), Opener())
        self.assertEqual(info["balance"], -12.5)
        self.assertEqual(info["month"]["gb_out"], 45.6)
        self.assertEqual(info["month"]["start_ts"], 1759276800)
        self.assertEqual(seen[0][1], "Bearer " + key)
        self.outputs.append(stats(int(self.clock.t)))
        app.collect(self.clock, self.runner, vultr=info)
        text = json.dumps(self.snap())
        self.assertNotIn(key, text)
        self.assertNotIn("e@x", text)
        self.assertEqual(self.snap()["vultr"]["pending_charges"], 3.21)
        self.assertFalse(app.vultr_due(app.load(), self.clock() + 60))

    def test_vultr_errors_are_codes(self):
        import urllib.error
        (self.etc / "vultr.key").write_text("B" * 36)

        class Opener:
            def open(self, req, timeout):
                raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", {}, None)

        info = app.vultr_fetch(self.clock(), Opener())
        self.assertEqual(info, {"ok": False, "error": "forbidden", "ts": self.clock()})
        (self.etc / "vultr.key").write_text("not a key; rm -rf /")
        self.assertEqual(app.vultr_fetch(self.clock(), Opener())["error"], "key_invalid")


if __name__ == "__main__":
    unittest.main(verbosity=1)
