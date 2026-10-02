"""Check downloadable byte integrity and the separation from the video tunnel."""
import asyncio
import http.client
import socket
import tempfile
from pathlib import Path
import unittest

from websockets.asyncio.server import serve
from phone_plugin import download_name, download_url, plugin_path
from sender import connection_filter


class PhonePluginTests(unittest.IsolatedAsyncioTestCase):
    def test_profile_name_validation(self):
        self.assertEqual(download_name("192.168.1.45", 8765), "AppleLive-192.168.1.45-8765.dylib")
        self.assertEqual(download_url("192.168.1.45", 8765), "http://192.168.1.45:8765/phone-plugin")
        for host, port in [("127.0.0.1", 8765), ("0.0.0.0", 8765), ("224.1.1.1", 8765),
                           ("::1", 8765), ("192.168.1.45", 0), ("192.168.1.45", 65536)]:
            with self.assertRaises(ValueError):
                download_name(host, port)

    async def test_http_download_preserves_signed_bytes_and_usb_stays_restricted(self):
        hosts = {item[4][0] for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)}
        host = next((item for item in hosts if not item.startswith("127.")), None)
        if not host:
            self.skipTest("No LAN IPv4 interface")

        def get(port):
            client = http.client.HTTPConnection(host, port, timeout=3)
            client.request("GET", "/phone-plugin")
            response = client.getresponse()
            result = response.status, response.getheader("Content-Disposition"), response.read()
            client.close()
            return result

        async def handler(_ws):
            self.fail("A plugin download must never upgrade to a video connection")

        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            path = plugin_path(directory)
            path.parent.mkdir()
            original = b"\xca\xfe\xba\xbe\x00\xffsigned-mach-o-fixture"
            path.write_bytes(original)
            for mode, expected in [("lan", 200), ("usb", 403)]:
                async with serve(handler, "0.0.0.0", 0, process_request=connection_filter(mode, directory)) as server:
                    port = server.sockets[0].getsockname()[1]
                    status, disposition, body = await asyncio.to_thread(get, port)
                    self.assertEqual(status, expected)
                    if expected == 200:
                        self.assertEqual(body, original)
                        self.assertIn(download_name(host, 1935), disposition)
                        path.unlink()
                        self.assertEqual((await asyncio.to_thread(get, port))[0], 404)


if __name__ == "__main__":
    unittest.main()
