"""Exercise the HTTP boundary and OBS command handoff without launching OBS."""
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock

from dock_server import DockServer, local_addresses
from phone_plugin import plugin_path


class FakeOBS:
    def __init__(self):
        self.calls = []

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass

    def stream_state(self):
        return {"stream_active": False, "stream_configured": False, "stream_server": ""}

    def configure(self, host):
        self.calls.append(("configure", host))

    def start(self):
        self.calls.append(("start",))

    def stop(self):
        self.calls.append(("stop",))


class DockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.server = DockServer(self.path, 0)
        self.server.addresses = ["192.168.1.45"]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.obs = FakeOBS()
        self.patch = mock.patch("dock_server.OBSClient", return_value=self.obs)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, value, **headers):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        base = {"Origin": self.server.origin, "X-AppleLive-Token": self.server.token}
        base.update(headers)
        connection.request("POST", "/api/command", json.dumps(value), base)
        response = connection.getresponse()
        code = response.status
        result = json.loads(response.read())
        connection.close()
        return code, result

    def test_configure_uses_selected_computer_address(self):
        for host in ("127.0.0.1", "192.168.1.99", "example.com"):
            self.assertEqual(self.request({"action": "configure_stream", "host": host})[0], 400)
        with mock.patch.object(self.server, "ensure_stream_server"):
            code, result = self.request({"action": "configure_stream", "host": "192.168.1.45"})
        self.assertEqual(code, 202)
        self.assertEqual(self.obs.calls, [("configure", "192.168.1.45")])
        self.assertEqual(self.server.status()["bridge"]["last_command"], result["id"])

    def test_configure_starts_and_stop_closes_media_server(self):
        with mock.patch.object(self.server, "ensure_stream_server") as start, \
                mock.patch.object(self.server, "stop_stream_server") as stop:
            self.assertEqual(self.request({"action": "configure_stream", "host": "192.168.1.45"})[0], 202)
            self.assertEqual(self.request({"action": "stop_stream"})[0], 202)
        start.assert_called_once_with()
        stop.assert_called_once_with()

    def test_start_requires_media_server(self):
        with mock.patch.object(self.server, "ensure_stream_server", side_effect=OSError("MediaMTX missing")):
            code, result = self.request({"action": "start_stream"})
        self.assertEqual(code, 503)
        self.assertIn("MediaMTX", result["error"])
        self.assertFalse(self.obs.calls)

    def test_stop_does_not_require_media_server(self):
        self.assertEqual(self.request({"action": "stop_stream"})[0], 202)
        self.assertEqual(self.obs.calls, [("stop",)])

    def test_reject_foreign_pages_and_invalid_actions(self):
        for headers in ({"Origin": "https://example.com"}, {"X-AppleLive-Token": "wrong"}, {"Host": "attacker.test"}):
            self.assertEqual(self.request({"action": "stop_stream"}, **headers)[0], 403)
        for value in ({"action": "start"}, {"action": "settings", "quality": "high"}, {"action": "start_stream", "host": "192.168.1.45"}):
            self.assertEqual(self.request(value)[0], 400)
        self.assertFalse(self.obs.calls)

    def test_status_and_phone_download(self):
        self.assertTrue(self.server.status()["ready"])
        self.assertFalse(self.server.status()["firewall_pending"])
        with mock.patch.object(self.server.stream_server, "path_status", return_value={
            "ready": True, "readers": 1, "tracks": ["H264", "MPEG-4 Audio"]}):
            self.assertEqual(self.server.status()["stream_path"], {
                "ready": True, "readers": 1, "tracks": ["H264", "MPEG-4 Audio"]})
        path = plugin_path(self.path)
        path.parent.mkdir()
        path.write_bytes(b"signed-library")
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request("GET", "/api/phone-plugin")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertIn("AppleLive.dylib", response.getheader("Content-Disposition"))
        self.assertEqual(response.read(), b"signed-library")
        connection.close()

    def test_local_addresses_filter_unusable_interfaces(self):
        probe = mock.Mock()
        probe.getsockname.return_value = ("192.168.8.20", 54321)
        with mock.patch("dock_server.socket.getaddrinfo", return_value=[
            (2, 1, 6, "", ("127.0.0.1", 0)),
            (2, 1, 6, "", ("169.254.10.5", 0)),
            (2, 1, 6, "", ("10.0.0.4", 0)),
        ]), mock.patch("dock_server.socket.socket", return_value=probe):
            self.assertEqual(local_addresses(), ["192.168.8.20", "10.0.0.4"])

    def test_firewall_script_allows_any_remote_address(self):
        script = (Path(__file__).parent / "setup_lan.ps1").read_text(encoding="utf-8")
        self.assertIn("-RemoteAddress Any", script)
        self.assertNotIn("LocalSubnet", script)
        self.assertIn("AppleLiveLAN2:$machineGuid", script)

    def test_firewall_marker_is_bound_to_this_computer(self):
        marker = self.path / "lan-access.ok"
        with mock.patch("dock_server.machine_id", return_value="computer-a"):
            marker.write_text("AppleLiveLAN2:computer-b", encoding="ascii")
            self.assertFalse(self.server.firewall_access_enabled())
            marker.write_text("AppleLiveLAN2:computer-a", encoding="ascii")
            self.assertTrue(self.server.firewall_access_enabled())

    def test_firewall_elevation_runs_in_background(self):
        (self.path / "setup_lan.ps1").write_text("", encoding="utf-8")
        started = threading.Event()
        release = threading.Event()

        def elevate(_script):
            started.set()
            release.wait(2)

        with mock.patch("dock_server.os.name", "nt"), \
                mock.patch.object(self.server, "_run_firewall_setup", side_effect=elevate), \
                mock.patch.object(self.server, "firewall_access_enabled", return_value=True):
            self.server.request_firewall_access()
            self.assertTrue(started.wait(1))
            self.assertTrue(self.server.firewall_pending)
            release.set()
            for _ in range(100):
                if not self.server.firewall_pending:
                    break
                threading.Event().wait(0.01)
            self.assertFalse(self.server.firewall_pending)


if __name__ == "__main__":
    unittest.main()
