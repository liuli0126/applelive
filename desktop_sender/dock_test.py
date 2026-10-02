"""Exercise the HTTP control boundary without starting OBS or capture."""
import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest import mock

from dock_server import DockServer, atomic_json, local_addresses
from phone_plugin import plugin_path


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

    def test_local_addresses_include_route_probe_and_ignore_unusable_interfaces(self):
        probe = mock.Mock()
        probe.getsockname.return_value = ("192.168.8.20", 54321)
        with mock.patch("dock_server.socket.getaddrinfo", return_value=[
                (2, 1, 6, "", ("127.0.0.1", 0)),
                (2, 1, 6, "", ("169.254.10.5", 0)),
                (2, 1, 6, "", ("10.0.0.4", 0)),
             ]), mock.patch("dock_server.socket.socket", return_value=probe):
            self.assertEqual(local_addresses(), ["10.0.0.4", "192.168.8.20"])
        probe.connect.assert_called_once_with(("192.0.2.1", 9))
        probe.close.assert_called_once_with()

    def test_reject_foreign_pages_and_invalid_host(self):
        for headers in [{"Origin": "https://example.com"}, {"X-AppleLive-Token": "wrong"}, {"Host": "attacker.test"}]:
            self.assertEqual(self.request({"action": "stop"}, **headers)[0], 403)
        self.assertFalse((self.path / "applelive-command.json").exists())

    def test_firewall_endpoint_requires_local_authenticated_page(self):
        for headers in [{"Origin": "https://example.com"}, {"X-AppleLive-Token": "wrong"}, {"Host": "attacker.test"}]:
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
            base = {"Origin": self.server.origin, "X-AppleLive-Token": self.server.token}
            base.update(headers)
            connection.request("POST", "/api/firewall", headers=base)
            response = connection.getresponse()
            self.assertEqual(response.status, 403)
            response.read(); connection.close()

    def test_firewall_endpoint_requests_elevation(self):
        with mock.patch.object(self.server, "request_firewall_access") as request:
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
            connection.request("POST", "/api/firewall", headers={
                "Host": f"127.0.0.1:{self.server.server_port}",
                "Origin": self.server.origin,
                "X-AppleLive-Token": self.server.token,
            })
            response = connection.getresponse()
            self.assertEqual(response.status, 202)
            response.read(); connection.close()
            request.assert_called_once_with()

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

    def test_plugin_download_requires_local_address_and_preserves_bytes(self):
        self.server.addresses = ["192.168.1.45"]
        path = plugin_path(self.path)
        path.parent.mkdir()
        body = b"\xca\xfe\xba\xbebinary-signature-fixture"
        path.write_bytes(body)
        for host, expected in [("attacker.test", 400), ("127.0.0.1", 400), ("192.168.1.45", 200)]:
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
            connection.request("GET", "/api/phone-plugin?host=" + host)
            response = connection.getresponse()
            self.assertEqual(response.status, expected)
            if expected == 200:
                self.assertIn("AppleLive-192.168.1.45-1935.dylib", response.getheader("Content-Disposition"))
                self.assertEqual(response.read(), body)
            else:
                response.read()
            connection.close()

    def test_qr_is_unavailable_until_lan_sender_is_running(self):
        self.server.addresses = ["192.168.1.45"]
        path = plugin_path(self.path)
        path.parent.mkdir()
        path.write_bytes(b"library")
        for mode in ("usb", "lan"):
            atomic_json(self.path / "applelive-status.json", {
                "state": "stopped" if mode == "lan" else "running",
                "connection_mode": mode, "updated_at": time.time()})
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
            connection.request("GET", "/api/phone-qr?host=192.168.1.45")
            response = connection.getresponse()
            self.assertEqual(response.status, 409)
            response.read()
            connection.close()

    @unittest.skipUnless(importlib.util.find_spec("qrcode"), "QR rendering dependency is installed by CI")
    def test_running_lan_renders_png_qr(self):
        self.server.addresses = ["192.168.1.45"]
        path = plugin_path(self.path)
        path.parent.mkdir()
        path.write_bytes(b"library")
        atomic_json(self.path / "applelive-status.json", {
            "state": "running", "connection_mode": "lan", "rtmp_enabled": True, "updated_at": time.time()})
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        connection.request("GET", "/api/phone-qr?host=192.168.1.45")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Type"), "image/png")
        self.assertTrue(response.read().startswith(b"\x89PNG\r\n\x1a\n"))
        connection.close()

    def test_obs_launch_remains_busy_until_sender_writes_status(self):
        atomic_json(self.path / "applelive-bridge.json", {"updated_at": time.time(), "sender_state": "starting"})
        self.assertEqual(self.server.status()["sender"]["state"], "starting")
        self.assertEqual(self.request({"action": "settings", "settings": {"quality": "high"}})[0], 409)


if __name__ == "__main__":
    unittest.main()
