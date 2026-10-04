"""Verify authenticated OBS WebSocket control with a protocol fixture."""
import base64
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from obs_websocket import OBSClient


class SocketFixture:
    def __init__(self, not_ready_once=None):
        self.sent = []
        self.not_ready_once = set(not_ready_once or [])
        self.responses = [{"op": 0, "d": {"authentication": {"salt": "salt", "challenge": "challenge"}}}]

    def send(self, body):
        message = json.loads(body)
        self.sent.append(message)
        if message["op"] == 1:
            self.responses.append({"op": 2, "d": {"negotiatedRpcVersion": 1}})
        elif message["op"] == 6:
            request = message["d"]
            if request["requestType"] in self.not_ready_once:
                self.not_ready_once.remove(request["requestType"])
                self.responses.append({"op": 7, "d": {"requestId": request["requestId"],
                    "requestStatus": {"result": False, "code": 207,
                        "comment": "OBS is not ready to perform the request."}}})
                return
            data = {"outputActive": False} if request["requestType"] == "GetStreamStatus" else {
                "streamServiceType": "rtmp_custom", "streamServiceSettings": {
                    "server": "rtmp://192.168.1.45:1935/live", "key": "applelive"}}
            self.responses.append({"op": 7, "d": {"requestId": request["requestId"],
                "requestStatus": {"result": True}, "responseData": data}})

    def recv(self, timeout=None):
        return json.dumps(self.responses.pop(0))

    def close(self):
        pass


class OBSClientTests(unittest.TestCase):
    @staticmethod
    def config(temp):
        appdata = Path(temp) / "AppData"
        config = appdata / "obs-studio" / "plugin_config" / "obs-websocket" / "config.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"server_enabled": True, "server_port": 4455,
            "auth_required": True, "server_password": "password"}), encoding="utf-8")
        return appdata

    def test_authentication_and_local_stream_commands(self):
        with tempfile.TemporaryDirectory() as temp:
            appdata = self.config(temp)
            socket = SocketFixture()
            with mock.patch.dict(os.environ, {"APPDATA": str(appdata)}), \
                    mock.patch("obs_websocket.connect", return_value=socket):
                with OBSClient(Path(temp) / "plugin") as client:
                    self.assertTrue(client.stream_state()["stream_configured"])
                    client.configure("192.168.1.45")
                    client.start()
                    client.stop()

            secret = base64.b64encode(hashlib.sha256(b"passwordsalt").digest()).decode()
            expected = base64.b64encode(hashlib.sha256((secret + "challenge").encode()).digest()).decode()
            self.assertEqual(socket.sent[0]["d"]["authentication"], expected)
            names = [message["d"]["requestType"] for message in socket.sent[1:]]
            self.assertIn("SetStreamServiceSettings", names)
            self.assertIn("StartStream", names)
            self.assertNotIn("StopStream", names)  # The fixture reports an already stopped stream.

    def test_new_obs_without_stream_service_can_be_configured(self):
        with tempfile.TemporaryDirectory() as temp:
            appdata = self.config(temp)
            socket = SocketFixture({"GetStreamServiceSettings"})
            with mock.patch.dict(os.environ, {"APPDATA": str(appdata)}), \
                    mock.patch("obs_websocket.connect", return_value=socket):
                with OBSClient(Path(temp) / "plugin") as client:
                    state = client.stream_state()
                    self.assertFalse(state["stream_configured"])
                    client.configure("192.168.1.45")
            names = [message["d"]["requestType"] for message in socket.sent if message["op"] == 6]
            self.assertIn("SetStreamServiceSettings", names)


if __name__ == "__main__":
    unittest.main()
