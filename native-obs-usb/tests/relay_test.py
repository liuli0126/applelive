"""Behavioral tests of the compiled relay with a loopback usbmuxd fixture."""
from pathlib import Path
import json
import plistlib
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


def exact(s, count):
    result = b""
    while len(result) < count:
        part = s.recv(count - len(result))
        if not part:
            raise EOFError()
        result += part
    return result


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class RelayTest(unittest.TestCase):
    def exercise(self, fmt, bad_magic=False, missing_result=False):
        received, errors = [], []
        mux = socket.socket()
        mux.bind(("127.0.0.1", 0))
        mux.listen()
        mux.settimeout(6)
        relay_port = port()
        packets = [b"fram" + bytes(range(250)) * 400, b"aacd\x80\xbb\x00\x00\x02\x00\x00\x00\x11\x90"]

        def server():
            try:
                for session in range(2):
                    for kind in ("ListDevices", "Connect"):
                        client, _ = mux.accept()
                        with client:
                            client.settimeout(4)
                            length, version, msg, tag = struct.unpack("<IIII", exact(client, 16))
                            self.assertEqual((version, msg), (1, 8))
                            request = plistlib.loads(exact(client, length - 16))
                            self.assertEqual(request["MessageType"], kind)
                            if kind == "ListDevices":
                                result = {"DeviceList": [
                                    {"DeviceID": 7, "Properties": {"ConnectionType": "Network", "NetworkAddress": b"address"}},
                                    {"DeviceID": 9, "Properties": {"ConnectionType": "USB"}}]}
                            else:
                                self.assertEqual(request["DeviceID"], 9)
                                self.assertEqual(request["PortNumber"], socket.htons(8766))
                                result = {} if missing_result else {"Number": 0}
                            body = plistlib.dumps(result, fmt=fmt)
                            client.sendall(struct.pack("<IIII", len(body) + 16, 1, 8, tag) + body)
                            if kind == "Connect" and not missing_result:
                                for part in (b"BAD" if bad_magic else b"ALU", b"SB1\r\n"):
                                    client.sendall(part)
                                if not bad_magic:
                                    for expected in packets:
                                        count = struct.unpack(">I", exact(client, 4))[0]
                                        self.assertEqual(count, len(expected), "relay sent greeting in the wrong direction")
                                        self.assertEqual(exact(client, count), expected)
                                    received.append(session)
            except BaseException as e:
                errors.append(e)

        worker = threading.Thread(target=server)
        worker.start()
        with tempfile.TemporaryDirectory(prefix="applelive-relay-") as folder:
            status = Path(folder) / "状态.json"
            process = subprocess.Popen([str(ROOT / "obs-plugin/AppleLiveUsbRelay.exe"),
                "--listen", str(relay_port), "--mux-port", str(mux.getsockname()[1]), "--status-file", str(status)],
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            try:
                for session in range(2):
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            client = socket.create_connection(("127.0.0.1", relay_port), 2)
                            break
                        except OSError:
                            if time.monotonic() > deadline:
                                raise
                            time.sleep(.03)
                    with client:
                        if bad_magic or missing_result:
                            self.assertEqual(client.recv(8), b"")
                        else:
                            self.assertEqual(exact(client, 8), b"ALUSB1\r\n")
                            for packet in packets:
                                framed = struct.pack(">I", len(packet)) + packet
                                for offset in range(0, len(framed), 731):
                                    client.sendall(framed[offset:offset+731])
                            self.assertEqual(client.recv(1), b"")
                    time.sleep(.1)
                worker.join(6)
                self.assertFalse(worker.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual(len(received), 0 if bad_magic or missing_result else 2)
                state = json.loads(status.read_text())
                self.assertEqual(state["usb_clients"], 0)
            finally:
                process.terminate()
                process.wait(3)
                mux.close()

    def test_xml_reconnect_and_exact_frames(self):
        self.exercise(plistlib.FMT_XML)

    def test_binary_reconnect_and_network_device_filter(self):
        self.exercise(plistlib.FMT_BINARY)

    def test_bad_handshake_is_rejected(self):
        self.exercise(plistlib.FMT_XML, bad_magic=True)

    def test_missing_mux_result_is_rejected(self):
        self.exercise(plistlib.FMT_BINARY, missing_result=True)


if __name__ == "__main__":
    unittest.main()
