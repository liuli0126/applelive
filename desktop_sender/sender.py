"""AppleLive desktop capture sender.

FFmpeg captures the Windows desktop or OBS Virtual Camera as low-latency
H.264 Annex-B and, when requested, a dshow audio device as float32 PCM.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import os
from pathlib import Path
import shutil
import struct
import subprocess
import threading
import time
from dataclasses import dataclass, field
from typing import Iterable

import websockets
from websockets.server import ServerConnection

LOG = logging.getLogger("applelive.sender")
VIDEO_HEADER = struct.Struct("<4sIIII")
AUDIO_HEADER = struct.Struct("<4sII")
MAX_CLIENT_QUEUE = 64


class AnnexBParser:
    """Extract complete Annex-B NAL units from arbitrary pipe chunks."""

    def __init__(self) -> None:
        self._buffer = bytearray()

    @staticmethod
    def _start_code_at(buf: bytearray, index: int) -> int:
        if index + 3 <= len(buf) and buf[index:index + 3] == b"\x00\x00\x01":
            return 3
        if index + 4 <= len(buf) and buf[index:index + 4] == b"\x00\x00\x00\x01":
            return 4
        return 0

    def feed(self, chunk: bytes) -> Iterable[bytes]:
        self._buffer.extend(chunk)
        starts: list[tuple[int, int]] = []
        i = 0
        while i < len(self._buffer) - 2:
            size = self._start_code_at(self._buffer, i)
            if size:
                starts.append((i, size))
                i += size
            else:
                i += 1

        if len(starts) < 2:
            # Preserve a possible split start code at the end of the buffer.
            if not starts and len(self._buffer) > 4:
                self._buffer = self._buffer[-4:]
            return ()

        output: list[bytes] = []
        for index, (start, _) in enumerate(starts[:-1]):
            end = starts[index + 1][0]
            nal = bytes(self._buffer[start:end])
            if len(nal) > 4:
                output.append(nal)
        self._buffer = self._buffer[starts[-1][0]:]
        return output

    def flush(self) -> bytes | None:
        if len(self._buffer) > 4:
            result = bytes(self._buffer)
            self._buffer.clear()
            return result
        return None


def video_command(args: argparse.Namespace) -> list[str]:
    command = [args.ffmpeg, "-hide_banner", "-loglevel", "warning"]
    if args.video_device:
        command += [
            "-f", "dshow", "-rtbufsize", "256M", "-framerate", str(args.fps),
            "-i", f"video={args.video_device}",
        ]
    else:
        command += [
            "-f", "gdigrab", "-framerate", str(args.fps), "-draw_mouse", "1",
            "-i", "desktop",
        ]
    command += [
        "-vf", f"scale={args.width}:{args.height}",
        "-an", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-pix_fmt", "yuv420p", "-g", str(args.fps), "-keyint_min", str(args.fps),
        "-f", "h264", "pipe:1",
    ]
    return command


def write_status(path: str | None, state: str, client_count: int = 0,
                 error: str | None = None) -> None:
    if not path:
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    pending = target.with_name(target.name + ".tmp")
    pending.write_text(json.dumps({
        "state": state,
        "clients": client_count,
        "pid": os.getpid(),
        "updated_at": int(time.time()),
        "error": error,
    }), encoding="utf-8")
    os.replace(pending, target)


@dataclass(eq=False)
class Client:
    websocket: ServerConnection
    queue: asyncio.Queue[bytes] = field(
        default_factory=lambda: asyncio.Queue(MAX_CLIENT_QUEUE)
    )


class Broadcaster:
    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.clients: set[Client] = set()
        self._lock = threading.Lock()
        self.sequence = 0

    async def add(self, websocket: ServerConnection) -> Client:
        client = Client(websocket)
        with self._lock:
            self.clients.add(client)
        await websocket.send(json.dumps({
            "type": "hello",
            "protocol": 1,
            "video": {"codec": "h264", "transport": "annexb"},
            "audio": {"codec": "pcm_f32le", "rate": 48000, "channels": 2},
        }))
        LOG.info("client connected: %s", websocket.remote_address)
        return client

    async def remove(self, client: Client) -> None:
        with self._lock:
            self.clients.discard(client)
        LOG.info("client disconnected")

    def publish(self, payload: bytes) -> None:
        """Schedule a non-blocking enqueue on the asyncio thread."""
        def enqueue() -> None:
            with self._lock:
                clients = tuple(self.clients)
            for client in clients:
                if client.queue.full():
                    # Dropping the oldest packet keeps the stream live and bounded.
                    with contextlib.suppress(asyncio.QueueEmpty):
                        client.queue.get_nowait()
                with contextlib.suppress(asyncio.QueueFull):
                    client.queue.put_nowait(payload)

        self.loop.call_soon_threadsafe(enqueue)


def run_ffmpeg(command: list[str]) -> subprocess.Popen[bytes]:
    LOG.info("starting: %s", " ".join(command))
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    if os.name == "nt":
        creationflags |= getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    return subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=creationflags,
    )


def drain_stderr(process: subprocess.Popen[bytes], label: str) -> None:
    assert process.stderr is not None
    for line in iter(process.stderr.readline, b""):
        text = line.decode("utf-8", errors="replace").strip()
        if text:
            LOG.warning("ffmpeg[%s] %s", label, text)


def capture_video(process: subprocess.Popen[bytes], broadcaster: Broadcaster,
                  width: int, height: int) -> None:
    assert process.stdout is not None
    parser = AnnexBParser()
    seq = 0
    # BufferedReader.read(n) waits for n bytes, adding seconds of latency at
    # low bitrates. read1 returns currently available pipe data immediately.
    for chunk in iter(lambda: process.stdout.read1(64 * 1024), b""):
        for nal in parser.feed(chunk):
            payload_offset = 4 if nal.startswith(b"\x00\x00\x00\x01") else 3
            nal_type = nal[payload_offset] & 0x1F if len(nal) > payload_offset else 0
            flags = 1 if nal_type == 5 else 0
            payload = VIDEO_HEADER.pack(b"fram", seq, flags, width, height) + nal
            broadcaster.publish(payload)
            seq += 1
    trailing = parser.flush()
    if trailing:
        broadcaster.publish(VIDEO_HEADER.pack(b"fram", seq, 0, width, height) + trailing)


def capture_audio(process: subprocess.Popen[bytes], broadcaster: Broadcaster,
                  sample_rate: int, channels: int) -> None:
    assert process.stdout is not None
    bytes_per_sample = 4 * channels
    read_size = 4800 * bytes_per_sample  # 100 ms at 48 kHz; avoids starving video NALs
    for chunk in iter(lambda: process.stdout.read(read_size), b""):
        if not chunk:
            break
        usable = len(chunk) - (len(chunk) % bytes_per_sample)
        if usable:
            broadcaster.publish(AUDIO_HEADER.pack(b"audi", sample_rate, channels) + chunk[:usable])


def stop_process_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        # Popen.terminate() only stops the ffmpeg wrapper on Windows; /T also
        # closes the child process that owns the capture device.
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        process.terminate()


async def client_handler(websocket: ServerConnection, broadcaster: Broadcaster) -> None:
    client = await broadcaster.add(websocket)
    try:
        async for message in websocket:
            if isinstance(message, str):
                try:
                    command = json.loads(message)
                except json.JSONDecodeError:
                    continue
                if command.get("type") == "ping":
                    await websocket.send(json.dumps({"type": "pong"}))
            # The sender is one-way; binary messages from a client are ignored.
    except websockets.ConnectionClosed:
        pass
    finally:
        await broadcaster.remove(client)


async def send_queues(broadcaster: Broadcaster) -> None:
    """Fan each client's queue to its WebSocket without blocking capture."""
    tasks: dict[Client, asyncio.Task[None]] = {}

    async def pump(client: Client) -> None:
        while True:
            payload = await client.queue.get()
            try:
                await client.websocket.send(payload)
            except websockets.ConnectionClosed:
                return

    while True:
        with broadcaster._lock:
            clients = tuple(broadcaster.clients)
        for client in clients:
            tasks.setdefault(client, asyncio.create_task(pump(client)))
        for client in tuple(tasks):
            if client not in clients:
                tasks.pop(client).cancel()
        await asyncio.sleep(0.25)


async def main(args: argparse.Namespace) -> None:
    if shutil.which(args.ffmpeg) is None:
        raise RuntimeError(f"FFmpeg not found: {args.ffmpeg}")

    loop = asyncio.get_running_loop()
    broadcaster = Broadcaster(loop)
    processes: list[subprocess.Popen[bytes]] = []
    async def bound_handler(websocket: ServerConnection, path: str | None = None) -> None:
        await client_handler(websocket, broadcaster)

    async with websockets.serve(
        bound_handler,
        args.host,
        args.port,
        max_size=8 * 1024 * 1024,
        ping_interval=5,
        ping_timeout=10,
    ):
        LOG.info("AppleLive server listening on ws://%s:%d", args.host, args.port)
        write_status(args.status_file, "starting")
        try:
            video_process = run_ffmpeg(video_command(args))
            processes.append(video_process)
            threads = [
                threading.Thread(target=drain_stderr, args=(video_process, "video"), daemon=True),
                threading.Thread(target=capture_video,
                                 args=(video_process, broadcaster, args.width, args.height),
                                 daemon=True),
            ]
            if args.audio_device:
                audio_command = [
                    args.ffmpeg, "-hide_banner", "-loglevel", "warning",
                    "-f", "dshow", "-i", f"audio={args.audio_device}",
                    "-ac", str(args.channels), "-ar", str(args.sample_rate),
                    "-f", "f32le", "pipe:1",
                ]
                audio_process = run_ffmpeg(audio_command)
                processes.append(audio_process)
                threads.extend([
                    threading.Thread(target=drain_stderr, args=(audio_process, "audio"), daemon=True),
                    threading.Thread(target=capture_audio,
                                     args=(audio_process, broadcaster, args.sample_rate, args.channels),
                                     daemon=True),
                ])
            else:
                LOG.warning("No audio device selected; iPhone microphone remains active")

            for thread in threads:
                thread.start()
            pump_task = asyncio.create_task(send_queues(broadcaster))
            try:
                while True:
                    if args.stop_file and Path(args.stop_file).exists():
                        LOG.info("Stop requested")
                        break
                    for process in processes:
                        if process.poll() is not None:
                            raise RuntimeError(f"FFmpeg exited unexpectedly (code {process.returncode})")
                    write_status(args.status_file, "running", len(broadcaster.clients))
                    await asyncio.sleep(0.5)
            finally:
                pump_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await pump_task
        finally:
            for process in processes:
                stop_process_tree(process)
            for process in processes:
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=2)
            write_status(args.status_file, "stopped")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="AppleLive PC -> jailbroken iPhone sender")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--video-device", help="Windows dshow video device, e.g. OBS Virtual Camera")
    parser.add_argument("--audio-device", help="Windows dshow audio device, e.g. CABLE Output")
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--channels", type=int, default=2)
    parser.add_argument("--status-file", help="JSON status file for OBS integration")
    parser.add_argument("--stop-file", help="Exit when this file appears")
    parser.add_argument("--log-file", help="Write logs to this file")
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    logging.basicConfig(level=os.environ.get("APPLELIVE_LOG", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s",
                        filename=arguments.log_file, encoding="utf-8")
    try:
        asyncio.run(main(arguments))
    except KeyboardInterrupt:
        pass
    except Exception as error:
        LOG.exception("AppleLive sender failed")
        write_status(arguments.status_file, "error", error=str(error))
        raise SystemExit(1)
