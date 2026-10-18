#!/usr/bin/python3 -I
# Tests for helper.py, run against tests/fake-incus. Run: python3 -I tests/helper_test.py

import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HELPER = os.path.join(ROOT, "helper.py")
FAKE = os.path.join(HERE, "fake-incus")

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("helper", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class HelperRun(unittest.TestCase):
  def setUp(self):
    self.state = tempfile.mkdtemp(prefix="omacus-test-")
    self.env = dict(os.environ, FAKE_INCUS_STATE=self.state)

  def run_helper(self, *args, incus=FAKE):
    argv = ["/usr/bin/python3", "-I", "-S", HELPER]
    if incus:
      argv += ["--incus", incus]
    proc = subprocess.run(argv + list(args), capture_output=True, env=self.env, timeout=60)
    lines = proc.stdout.decode().strip().splitlines()
    return json.loads(lines[-1]) if lines else None

  def test_probe_reports_the_client(self):
    doc = self.run_helper("probe")
    self.assertEqual(doc["incus"], FAKE)
    self.assertEqual(doc["version"], "7.5")

  def test_probe_without_client(self):
    doc = self.run_helper("probe", incus="/nonexistent/incus")
    self.assertEqual(doc, {"ok": True, "incus": "", "version": ""})

  def test_remotes_skip_image_servers(self):
    doc = self.run_helper("remotes")
    names = [r["name"] for r in doc["remotes"]]
    self.assertEqual(names, ["homelab", "local", "nas"])
    self.assertEqual(doc["default"], "homelab")
    local = [r for r in doc["remotes"] if r["name"] == "local"][0]
    self.assertTrue(local["local"])
    self.assertEqual(local["addr"], "")

  def test_snapshot_shape(self):
    doc = self.run_helper("snapshot", "homelab", "")
    self.assertTrue(doc["ok"])
    self.assertEqual(len(doc["instances"]), 9)
    db = [i for i in doc["instances"] if i["name"] == "db"][0]
    self.assertEqual(db["ipv4"], ["10.10.0.22"])
    self.assertEqual(db["ipv6"], [])  # link-local is dropped
    self.assertEqual(db["snapshots"], 2)
    self.assertEqual(db["memTotal"], 2048 * 1048576)
    win = [i for i in doc["instances"] if i["name"] == "win11"][0]
    self.assertEqual(win["processes"], -1)
    self.assertEqual([p["name"] for p in doc["pools"]], ["default", "fast"])
    self.assertEqual(doc["warningCount"], 1)
    self.assertEqual(doc["host"]["cpuThreads"], 16)

  def test_instances_only_skips_host(self):
    doc = self.run_helper("snapshot", "nas", "", "--instances-only")
    self.assertTrue(doc["ok"])
    self.assertNotIn("pools", doc)

  def test_unreachable_remote(self):
    doc = self.run_helper("snapshot", "elsewhere", "")
    self.assertFalse(doc["ok"])
    self.assertTrue(doc["unreachable"])

  def test_actions_change_state_and_emit_events(self):
    monitor = subprocess.Popen(["/usr/bin/python3", "-I", "-S", HELPER, "--incus", FAKE, "monitor", "homelab"],
                               stdout=subprocess.PIPE, env=self.env)
    try:
      self.assertEqual(json.loads(monitor.stdout.readline()), {"t": "up"})
      time.sleep(0.3)
      self.assertEqual(self.run_helper("action", "stop", "homelab", "default", "web"), {"ok": True})
      event = json.loads(monitor.stdout.readline())
      self.assertEqual((event["t"], event["action"], event["name"]), ("life", "instance-shutdown", "web"))
      doc = self.run_helper("snapshot", "homelab", "", "--instances-only")
      self.assertEqual([i["status"] for i in doc["instances"] if i["name"] == "web"], ["Stopped"])
      children = subprocess.run(["pgrep", "-P", str(monitor.pid)], capture_output=True).stdout.split()
      self.assertEqual(len(children), 1)
    finally:
      monitor.send_signal(signal.SIGTERM)
      monitor.wait(timeout=5)
      monitor.stdout.close()
    # The helper takes its incus child down with it.
    time.sleep(0.2)
    self.assertFalse(os.path.exists("/proc/%s" % children[0].decode()))

  def test_failed_action_reports_the_error(self):
    doc = self.run_helper("action", "start", "homelab", "default", "web")
    self.assertFalse(doc["ok"])
    self.assertIn("already running", doc["error"])

  def test_bad_arguments_are_refused(self):
    for args in (
      ("action", "delete", "homelab", "default", "web"),
      ("action", "stop", "homelab", "default", "-rf"),
      ("action", "stop", "homelab", "..", "web"),
      ("action", "stop", "-x", "default", "web"),
      ("snapshot", "home/lab", ""),
      ("snapshot", "homelab", "", "--extra"),
    ):
      doc = self.run_helper(*args)
      self.assertFalse(doc["ok"], args)


class Compaction(unittest.TestCase):
  def test_hostile_instance_fields_are_dropped_or_cleaned(self):
    self.assertIsNone(helper.compact_instance({"name": "<img src=x>", "project": "default"}))
    self.assertIsNone(helper.compact_instance({"name": "web", "project": "../etc"}))
    item = helper.compact_instance({
      "name": "web",
      "project": "default",
      "description": "line\nbreak‮" + "x" * 1000,
      "state": {
        "memory": {"usage": float("nan"), "total": -5},
        "cpu": {"usage": True},
        "network": {"eth0": {"addresses": [
          {"family": "inet", "address": "10.0.0.1; rm -rf /", "scope": "global"},
          {"family": "inet", "address": "10.0.0.2", "scope": "global"},
        ]}},
      },
    })
    self.assertEqual(item["ipv4"], ["10.0.0.2"])
    self.assertIsNone(item["memUsage"])
    self.assertIsNone(item["memTotal"])
    self.assertIsNone(item["cpuUsage"])
    self.assertNotIn("\n", item["description"])
    self.assertNotIn("‮", item["description"])
    self.assertLessEqual(len(item["description"]), helper.TEXT_CAP)

  def test_instance_count_is_capped(self):
    raw = [{"name": "i%d" % n, "project": "default"} for n in range(helper.MAX_INSTANCES + 50)]
    self.assertEqual(len(helper.instances_from(raw)), helper.MAX_INSTANCES)

  def test_events_are_reduced_to_a_fixed_shape(self):
    event = helper.compact_event({"type": "lifecycle", "project": "default", "metadata": {
      "action": "instance-started", "source": "/1.0/instances/web?project=default",
      "requestor": {"username": "me", "protocol": "tls"}, "context": {"big": "x" * 10000}}})
    self.assertEqual(event, {"t": "life", "action": "instance-started", "name": "web", "project": "default",
                             "user": "me", "protocol": "tls", "location": ""})
    self.assertIsNone(helper.compact_event({"type": "lifecycle", "metadata": {"action": "Bad Action!"}}))
    self.assertIsNone(helper.compact_event({"type": "logging", "metadata": {}}))

  def test_finished_operations_are_reported_as_done(self):
    event = helper.compact_event({"type": "operation", "metadata": {"id": "6916c8a6-9b7d-4abd-90b3-aedfec7ec7da", "status": "Success", "class": "task"}})
    self.assertEqual(event["t"], "opdone")

  def test_run_many_caps_output_and_kills(self):
    [result] = helper.run_many([["/usr/bin/yes"]], 10, cap=1000)
    self.assertTrue(result["over"])
    [result] = helper.run_many([["/usr/bin/sleep", "30"]], 0.5)
    self.assertTrue(result["timeout"])


if __name__ == "__main__":
  helper.load_libc()
  unittest.main(verbosity=1)
