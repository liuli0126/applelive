"""usbmux transport for the injected app's loopback listener. No SSH."""
from __future__ import annotations

import asyncio
import contextlib
import socket
import struct
import logging
from pymobiledevice3.exceptions import PyMobileDevice3Exception

LOG = logging.getLogger("applelive.usb")
MAGIC = b"ALUSB1\r\n"
MAX_PACKET = 8 * 1024 * 1024


def frame_packet(payload: bytes) -> bytes:
    if not 4 <= len(payload) <= MAX_PACKET:
        raise ValueError("Invalid USB media packet size")
    return struct.pack(">I", len(payload)) + payload


async def receive_exact(loop, connection: socket.socket, size: int) -> bytes:
    output = bytearray()
    while len(output) < size:
        chunk = await loop.sock_recv(connection, size - len(output))
        if not chunk:
            raise ConnectionError("USB receiver closed")
        output.extend(chunk)
    return bytes(output)


class USBConnection:
    remote_address = ("127.0.0.1", 8766)

    def __init__(self, loop, connection):
        self.loop = loop
        self.connection = connection

    async def send(self, payload):
        if isinstance(payload, bytes):
            await self.loop.sock_sendall(self.connection, frame_packet(payload))

    async def close(self):
        with contextlib.suppress(OSError):
            self.connection.shutdown(socket.SHUT_RDWR)


async def usb_route(device, broadcaster):
    connection = None
    client = None
    try:
        connection = await asyncio.wait_for(device.connect(8766), 3)
        connection.setblocking(False)
        loop = asyncio.get_running_loop()
        handshake = await asyncio.wait_for(receive_exact(loop, connection, len(MAGIC)), 3)
        if handshake != MAGIC:
            raise ValueError("USB app handshake mismatch")
        client = await broadcaster.add(USBConnection(loop, connection))
        LOG.info("USB app connected")
        await loop.sock_recv(connection, 1)
    except (OSError, ValueError, TimeoutError, PyMobileDevice3Exception):
        pass
    finally:
        if client:
            await broadcaster.remove(client)
        if connection:
            connection.close()


async def watch_usb(broadcaster):
    from pymobiledevice3.usbmux import list_devices

    tasks = {}
    try:
        while True:
            try:
                devices = await asyncio.wait_for(list_devices(), 3)
            except (OSError, TimeoutError, PyMobileDevice3Exception):
                devices = []
            for serial, task in tuple(tasks.items()):
                if task.done():
                    task.result()
                    del tasks[serial]
            for device in devices:
                if device.is_usb and device.serial not in tasks:
                    tasks[device.serial] = asyncio.create_task(usb_route(device, broadcaster))
            await asyncio.sleep(1)
    finally:
        for task in tasks.values():
            task.cancel()
        await asyncio.gather(*tasks.values(), return_exceptions=True)
