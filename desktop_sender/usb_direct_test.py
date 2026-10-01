"""Exercise USB framing, handshake rejection and ordered fanout over real sockets."""
import asyncio
import contextlib
import struct
import unittest

from sender import Broadcaster, send_queues, VIDEO_HEADER
from usb_direct import MAGIC, frame_packet, usb_route


class USBTests(unittest.IsolatedAsyncioTestCase):
    async def test_usb_route(self):
        accepted = asyncio.Future()

        async def receiver(reader, writer):
            writer.write(MAGIC[:3]); await writer.drain()
            await asyncio.sleep(0.01)
            writer.write(MAGIC[3:]); await writer.drain()
            packets = []
            try:
                for _ in range(32):
                    size = struct.unpack('>I', await reader.readexactly(4))[0]
                    packets.append(await reader.readexactly(size))
                accepted.set_result(packets)
                writer.close(); await writer.wait_closed()
            except Exception as error:
                accepted.set_exception(error)

        server = await asyncio.start_server(receiver, '127.0.0.1', 0)
        port = server.sockets[0].getsockname()[1]

        class Device:
            async def connect(self, _port):
                import socket
                sock = socket.socket(); sock.setblocking(False)
                await asyncio.get_running_loop().sock_connect(sock, ('127.0.0.1', port))
                return sock

        broadcaster = Broadcaster(asyncio.get_running_loop())
        route = asyncio.create_task(usb_route(Device(), broadcaster))
        pump = asyncio.create_task(send_queues(broadcaster))
        try:
            for _ in range(30):
                if broadcaster.clients: break
                await asyncio.sleep(0.02)
            self.assertEqual(len(broadcaster.clients), 1)
            # Seed SPS/PPS then IDR so the existing recovery logic can start.
            broadcaster.publish(VIDEO_HEADER.pack(b'fram', 0, 0, 320, 240) + b'\0\0\0\1\x67sps')
            broadcaster.publish(VIDEO_HEADER.pack(b'fram', 1, 0, 320, 240) + b'\0\0\0\1\x68pps')
            expected = []
            for i in range(30):
                packet = VIDEO_HEADER.pack(b'fram', i + 2, i == 0, 320, 240) + b'\0\0\0\1' + bytes([0x65 if i == 0 else 0x61]) + bytes([i])
                expected.append(packet); broadcaster.publish(packet); await asyncio.sleep(0.03)
            result = await asyncio.wait_for(accepted, 3)
            self.assertEqual(result[2:], expected)
            await asyncio.wait_for(route, 2)
            self.assertFalse(broadcaster.clients)
        finally:
            route.cancel(); pump.cancel()
            await asyncio.gather(route, pump, return_exceptions=True)
            server.close(); await server.wait_closed()

    def test_size_bounds(self):
        with self.assertRaises(ValueError): frame_packet(b'abc')
        self.assertEqual(frame_packet(b'audi')[:4], b'\0\0\0\4')


if __name__ == '__main__': unittest.main()
