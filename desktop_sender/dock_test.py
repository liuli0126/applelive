"""Exercise the HTTP control boundary without starting OBS or capture."""
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest

from dock_server import DockServer, atomic_json


class DockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        atomic_json(self.path / "applelive-bridge.json", {"updated_at": time.time(), "settings": {}})
        self.server = DockServer(self.path, 0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, value, **headers):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        base = {"Origin": self.server.origin, "X-AppleLive-Token": self.server.token}
        base.update(headers)
        connection.request("POST", "/api/command", json.dumps(value), base)
        response = connection.getresponse()
        result = response.status, json.loads(response.read())
        connection.close()
        return result

    def test_one_command_at_a_time(self):
        code, result = self.request({"action": "settings", "settings": {"quality": "high"}})
        self.assertEqual(code, 202)
        self.assertEqual(json.loads((self.path / "applelive-command.json").read_text())["id"], result["id"])
        self.assertEqual(self.request({"action": "start"})[0], 409)

    def test_reject_foreign_pages_and_invalid_host(self):
        for headers in [{"Origin": "https://example.com"}, {"X-AppleLive-Token": "wrong"}, {"Host": "attacker.test"}]:
            self.assertEqual(self.request({"action": "stop"}, **headers)[0], 403)
        self.assertFalse((self.path / "applelive-command.json").exists())

    def test_reject_unknown_settings(self):
        for settings in [{"ffmpeg_path": "cmd.exe"}, {"quality": "bogus"}, {"computer_audio": "false"}]:
            self.assertEqual(self.request({"action": "settings", "settings": settings})[0], 400)

    def test_running_capture_settings_locked_but_stop_allowed(self):
        atomic_json(self.path / "applelive-status.json", {"state": "running", "updated_at": time.time()})
        self.assertEqual(self.request({"action": "settings", "settings": {"quality": "high"}})[0], 409)
        self.assertEqual(self.request({"action": "stop"})[0], 202)

    def test_missing_obs_is_not_reported_as_ready(self):
        atomic_json(self.path / "applelive-bridge.json", {"updated_at": time.time() - 30})
        self.assertFalse(self.server.status()["ready"])
        self.assertEqual(self.request({"action": "start"})[0], 503)

    def test_bridge_replace_gap_keeps_recent_obs_heartbeat(self):
        self.assertTrue(self.server.status()["ready"])
        (self.path / "applelive-bridge.json").unlink()
        self.assertTrue(self.server.status()["ready"])

    def test_stale_sender_is_stopped(self):
        atomic_json(self.path / "applelive-status.json", {"state": "running", "updated_at": time.time() - 30})
        self.assertEqual(self.server.status()["sender"]["state"], "stopped")

    def test_obs_launch_remains_busy_until_sender_writes_status(self):
        atomic_json(self.path / "applelive-bridge.json", {"updated_at": time.time(), "sender_state": "starting"})
        self.assertEqual(self.server.status()["sender"]["state"], "starting")
        self.assertEqual(self.request({"action": "settings", "settings": {"quality": "high"}})[0], 409)


if __name__ == "__main__":
    unittest.main()
