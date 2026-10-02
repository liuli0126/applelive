"""Check mode restrictions on real WebSocket handshakes, before any frames."""
import asyncio
import socket
import unittest

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import InvalidStatus
from sender import connection_filter


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def check_mode(self, mode, host, allowed):
        async def handler(ws):
            await ws.send("frame-path-accepted")
        async with serve(handler, "0.0.0.0", 0, process_request=connection_filter(mode)) as server:
            port = server.sockets[0].getsockname()[1]
            if allowed:
                async with connect(f"ws://{host}:{port}", proxy=None) as ws:
                    self.assertEqual(await ws.recv(), "frame-path-accepted")
            else:
                with self.assertRaises(InvalidStatus) as raised:
                    async with connect(f"ws://{host}:{port}", proxy=None):
                        self.fail("Wrong transport was accepted")
                self.assertEqual(raised.exception.response.status_code, 403)

    async def test_usb_accepts_loopback(self):
        await self.check_mode("usb", "127.0.0.1", True)

    async def test_lan_rejects_usb_tunnel_before_upgrade(self):
        await self.check_mode("lan", "127.0.0.1", False)

    async def test_lan_rejects_websocket_video_and_usb_rejects_network(self):
        addresses = {a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)}
        host = next((a for a in addresses if not a.startswith("127.")), None)
        if not host:
            self.skipTest("No non-loopback network interface")
        await self.check_mode("lan", host, False)
        await self.check_mode("usb", host, False)


if __name__ == "__main__":
    unittest.main()
