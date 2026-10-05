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
import ipaddress
from http import HTTPStatus
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
from websockets.asyncio.server import ServerConnection, serve
from websockets.datastructures import Headers
from websockets.http11 import Response
from phone_plugin import download_name, plugin_directory, plugin_path
from stream_server import StreamServer, RTMP_URL
from usb_direct import watch_usb

LOG = logging.getLogger("applelive.sender")
VIDEO_HEADER = struct.Struct("<4sIIII")
AUDIO_HEADER = struct.Struct("<4sII")
MAX_CLIENT_QUEUE = 24


def video_nal_type(payload: bytes) -> int:
    if not payload.startswith(b"fram") or len(payload) < VIDEO_HEADER.size + 4:
        return 0
    start = VIDEO_HEADER.size
    if payload[start:start + 4] == b"\x00\x00\x00\x01":
        offset = start + 4
    elif payload[start:start + 3] == b"\x00\x00\x01":
        offset = start + 3
    else:
        return 0
    return payload[offset] & 0x1F if len(payload) > offset else 0


class AnnexBParser:
    """Extract complete Annex-B NAL units from arbitrary pipe chunks."""

    def __init__(self) -> None:
        self._buffer = bytearray()
        self._scan = 0
        self._has_start = False

    def feed(self, chunk: bytes) -> Iterable[bytes]:
        self._buffer.extend(chunk)
        starts = [0] if self._has_start else []
        cursor = self._scan
        while True:
            # Native byte search, resuming at the previous chunk boundary. The
            # old Python byte loop repeatedly rescanned growing IDR frames and
            # saturated a CPU core, backing up FFmpeg's capture pipe.
            found = self._buffer.find(b"\x00\x00\x01", cursor)
            if found < 0:
                break
            start = found - 1 if found > 0 and self._buffer[found - 1] == 0 else found
            starts.append(start)
            cursor = found + 3
        output: list[bytes] = []
        for index, start in enumerate(starts[:-1]):
            nal = bytes(self._buffer[start:starts[index + 1]])
            prefix_length = 4 if nal.startswith(b"\x00\x00\x00\x01") else 3
            if len(nal) > prefix_length:
                output.append(nal)
        if starts:
            retained = starts[-1]
            if retained:
                del self._buffer[:retained]
            self._has_start = True
            self._scan = max(cursor - retained, len(self._buffer) - 2)
        else:
            self._buffer = self._buffer[-3:]
            self._scan = 0
        return output

    def flush(self) -> bytes | None:
        prefix_length = 4 if self._buffer.startswith(b"\x00\x00\x00\x01") else 3
        if self._has_start and len(self._buffer) > prefix_length:
            result = bytes(self._buffer)
            self._buffer.clear()
            self._scan = 0
            self._has_start = False
            return result
        return None


def video_command(args: argparse.Namespace) -> list[str]:
    if getattr(args, "input_url", None):
        return [
            args.ffmpeg, "-hide_banner", "-loglevel", "warning",
            "-fflags", "nobuffer", "-flags", "low_delay",
            "-analyzeduration", "1000000", "-probesize", "1000000",
            "-i", args.input_url,
            "-map", "0:v:0", "-an", "-c:v", "copy",
            "-bsf:v", "h264_mp4toannexb", "-f", "h264", "pipe:1",
        ]
    gop_frames = max(args.fps // 2, 1)
    command = [args.ffmpeg, "-hide_banner", "-loglevel", "warning"]
    if args.video_device:
        command += [
            "-f", "dshow", "-rtbufsize", "16M", "-framerate", str(args.fps),
            "-i", f"video={args.video_device}",
        ]
    else:
        command += [
            "-f", "gdigrab", "-framerate", str(args.fps), "-draw_mouse", "1",
            "-i", "desktop",
        ]
    rtmp_url = getattr(args, "rtmp_url", None)
    if rtmp_url and args.audio_device:
        command += ["-f", "dshow", "-i", f"audio={args.audio_device}"]
    command += [
        "-vf", (f"scale={args.width}:{args.height}:force_original_aspect_ratio=decrease:"
                f"force_divisible_by=2,pad={args.width}:{args.height}:(ow-iw)/2:(oh-ih)/2"),
    ]
    command += ["-map", "0:v:0"]
    if rtmp_url and args.audio_device:
        command += ["-map", "1:a:0", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]
    else:
        command += ["-an"]
    if args.encoder == "nvenc":
        command += [
            "-c:v", "h264_nvenc", "-preset", "p4", "-tune", "ull",
            "-rc", "vbr", "-zerolatency", "1", "-delay", "0",
            "-forced-idr", "1",
        ]
    else:
        command += [
            "-c:v", "libx264", "-preset", args.encoder_preset,
            "-tune", "zerolatency", "-sc_threshold", "0",
            "-keyint_min", str(gop_frames),
            "-x264-params", "repeat-headers=1",
        ]
    command += [
        "-pix_fmt", "yuv420p",
        "-b:v", f"{args.bitrate_kbps}k", "-maxrate", f"{args.bitrate_kbps}k",
        "-bufsize", f"{max(args.bitrate_kbps // 2, 500)}k",
        "-g", str(gop_frames), "-bf", "0",
    ]
    if rtmp_url:
        command += ["-flags:v", "+global_header"]
        command += ["-f", "tee", "-use_fifo", "1", "-fifo_options", "attempt_recovery=1:recover_any_error=1:recovery_wait_time=1",
                    f"[select=v:bsfs/v=h264_mp4toannexb,dump_extra=freq=keyframe:f=h264]pipe:1|[onfail=ignore:f=flv:flush_packets=1:flvflags=no_duration_filesize]{rtmp_url}"]
    else:
        command += ["-f", "h264", "pipe:1"]
    return command


def audio_command(args: argparse.Namespace) -> list[str] | None:
    command = [args.ffmpeg, "-hide_banner", "-loglevel", "warning"]
    if getattr(args, "input_url", None):
        command += [
            "-fflags", "nobuffer", "-flags", "low_delay",
            "-analyzeduration", "1000000", "-probesize", "1000000",
            "-i", args.input_url, "-map", "0:a:0",
        ]
    elif args.audio_device:
        command += ["-f", "dshow", "-i", f"audio={args.audio_device}"]
    else:
        return None
    command += [
        "-vn", "-ac", str(args.channels), "-ar", str(args.sample_rate),
        "-f", "f32le", "pipe:1",
    ]
    return command


def select_encoder(ffmpeg: str, requested: str) -> str:
    if requested == "x264":
        return requested
    probe = [ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
             "-i", "color=s=256x256:r=1", "-frames:v", "1", "-c:v", "h264_nvenc",
             "-f", "null", "-"]
    try:
        available = subprocess.run(probe, capture_output=True, timeout=6, check=False).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        available = False
    if available:
        return "nvenc"
    if requested == "nvenc":
        raise RuntimeError("NVIDIA NVENC is unavailable; select x264 or auto")
    return "x264"


def write_status(path: str | None, state: str, client_count: int = 0,
                 error: str | None = None, usb_clients: int = 0,
                 connection_mode: str = "auto", rtmp_enabled: bool = False, rtmp_readers: int = 0) -> None:
    if not path:
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    pending = target.with_name(target.name + f".{os.getpid()}.tmp")
    payload = json.dumps({
        "state": state,
        "clients": client_count,
        "usb_clients": usb_clients,
        "connection_mode": connection_mode,
        "rtmp_enabled": rtmp_enabled,
        "rtmp_readers": rtmp_readers,
        "pid": os.getpid(),
        "updated_at": int(time.time()),
        "error": error,
    })
    try:
        pending.write_text(payload, encoding="utf-8")
        # Lua and antivirus readers may briefly open the destination without
        # Windows FILE_SHARE_DELETE. A status refresh must never stop capture.
        for attempt in range(6):
            try:
                os.replace(pending, target)
                return
            except PermissionError:
                if attempt == 5:
                    raise
                time.sleep(0.015)
    except OSError as error:
        LOG.warning("Could not refresh status; capture continues: %s", error)
        with contextlib.suppress(OSError):
            pending.unlink()


@dataclass(eq=False)
class Client:
    websocket: ServerConnection
    queue: asyncio.Queue[bytes] = field(
        default_factory=lambda: asyncio.Queue(MAX_CLIENT_QUEUE)
    )
    waiting_for_keyframe: bool = True


class Broadcaster:
    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.clients: set[Client] = set()
        self._lock = threading.Lock()
        self.sequence = 0
        self._sps: bytes | None = None
        self._pps: bytes | None = None
        self.last_video_frame_at = 0.0

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
        nal_type = video_nal_type(payload)
        if nal_type in (1, 5):
            self.last_video_frame_at = time.monotonic()

        def enqueue() -> None:
            if nal_type == 7:
                self._sps = payload
            elif nal_type == 8:
                self._pps = payload
            with self._lock:
                clients = tuple(self.clients)
            for client in clients:
                if client.queue.full():
                    # A partial inter-frame GOP is unusable after packet loss.
                    while not client.queue.empty():
                        client.queue.get_nowait()
                    client.waiting_for_keyframe = True
                if nal_type:
                    if client.waiting_for_keyframe:
                        if nal_type != 5 or not self._sps or not self._pps:
                            continue
                        client.queue.put_nowait(self._sps)
                        client.queue.put_nowait(self._pps)
                        client.waiting_for_keyframe = False
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
            if nal_type in (6, 9, 12):
                continue
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
    read_size = max(sample_rate // 50, 1) * bytes_per_sample  # About 20 ms.
    remainder = b""
    for chunk in iter(lambda: process.stdout.read1(read_size), b""):
        if not chunk:
            break
        chunk = remainder + chunk
        usable = len(chunk) - (len(chunk) % bytes_per_sample)
        if usable:
            broadcaster.publish(AUDIO_HEADER.pack(b"audi", sample_rate, channels) + chunk[:usable])
        remainder = chunk[usable:]


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
            except (websockets.ConnectionClosed, OSError):
                await client.websocket.close()
                await broadcaster.remove(client)
                return

    try:
        while True:
            with broadcaster._lock:
                clients = tuple(broadcaster.clients)
            for client in clients:
                if client not in tasks:
                    tasks[client] = asyncio.create_task(pump(client))
            for client in tuple(tasks):
                if client not in clients:
                    tasks.pop(client).cancel()
            await asyncio.sleep(0.1)
    finally:
        for task in tasks.values():
            task.cancel()
        await asyncio.gather(*tasks.values(), return_exceptions=True)


def connection_filter(mode: str, directory: Path | None = None):
    def check(connection, request):
        if request.path == "/phone-plugin":
            if mode == "usb":
                return connection.respond(HTTPStatus.FORBIDDEN, "Select LAN on the computer to download the phone plugin.\n")
            try:
                host, port = connection.local_address[:2]
                name = download_name(host, port)
                body = plugin_path(directory or plugin_directory()).read_bytes()
            except ValueError:
                return connection.respond(HTTPStatus.FORBIDDEN, "Use the computer's LAN IPv4 address.\n")
            except OSError:
                return connection.respond(HTTPStatus.NOT_FOUND, "Phone plugin is missing from the OBS package.\n")
            return Response(200, "OK", Headers({
                "Content-Type": "application/octet-stream", "Content-Length": str(len(body)),
                "Content-Disposition": f'attachment; filename="{name}"',
                "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            }), body)
        peer = connection.remote_address
        try:
            loopback = bool(peer) and ipaddress.ip_address(peer[0]).is_loopback
        except ValueError:
            loopback = False
        if (mode == "usb" and not loopback) or (mode == "lan" and loopback):
            return connection.respond(HTTPStatus.FORBIDDEN, f"AppleLive is set to {mode}; select the matching mode on your phone.\n")
        return None
    return check


async def main(args: argparse.Namespace) -> None:
    if shutil.which(args.ffmpeg) is None:
        raise RuntimeError(f"FFmpeg not found: {args.ffmpeg}")
    args.encoder = "copy" if args.input_url else select_encoder(args.ffmpeg, args.encoder)
    LOG.info("using %s H.264 encoder", args.encoder)

    loop = asyncio.get_running_loop()
    broadcaster = Broadcaster(loop)
    processes: list[subprocess.Popen[bytes]] = []
    stream_server = StreamServer()
    args.rtmp_url = None
    async def bound_handler(websocket: ServerConnection, path: str | None = None) -> None:
        await client_handler(websocket, broadcaster)

    bind_host = "127.0.0.1" if args.connection_mode == "usb" else args.host
    async with serve(
        bound_handler,
        bind_host,
        args.port,
        max_size=8 * 1024 * 1024,
        ping_interval=5,
        ping_timeout=10,
        compression=None,
        process_request=connection_filter(args.connection_mode),
    ):
        LOG.info("AppleLive %s server listening on ws://%s:%d", args.connection_mode, bind_host, args.port)
        write_status(args.status_file, "starting", connection_mode=args.connection_mode)
        try:
            if args.connection_mode == "lan" and stream_server.start():
                args.rtmp_url = RTMP_URL
            video_process = run_ffmpeg(video_command(args))
            processes.append(video_process)
            threads = [
                threading.Thread(target=drain_stderr, args=(video_process, "video"), daemon=True),
                threading.Thread(target=capture_video,
                                 args=(video_process, broadcaster, args.width, args.height),
                                 daemon=True),
            ]
            audio = audio_command(args)
            if audio:
                audio_process = run_ffmpeg(audio)
                processes.append(audio_process)
                threads.extend([
                    threading.Thread(target=drain_stderr, args=(audio_process, "audio"), daemon=True),
                    threading.Thread(target=capture_audio,
                                     args=(audio_process, broadcaster, args.sample_rate, args.channels),
                                     daemon=True),
                ])
            else:
                LOG.warning("No source audio; phone internal-audio mode will output silence")

            for thread in threads:
                thread.start()
            pump_task = asyncio.create_task(send_queues(broadcaster))
            usb_task = asyncio.create_task(watch_usb(broadcaster)) if args.connection_mode == "usb" else None
            try:
                capture_started_at = time.monotonic()
                while True:
                    if args.stop_file and Path(args.stop_file).exists():
                        LOG.info("Stop requested")
                        break
                    for process in processes:
                        if process.poll() is not None:
                            raise RuntimeError(f"FFmpeg exited unexpectedly (code {process.returncode})")
                    last_video = broadcaster.last_video_frame_at
                    if not last_video and time.monotonic() - capture_started_at > 8:
                        raise RuntimeError("No video frames received from FFmpeg; check the selected video device and OBS Virtual Camera")
                    if last_video and time.monotonic() - last_video > 5:
                        raise RuntimeError("Video capture stalled for more than 5 seconds")
                    state = "running" if last_video else "starting"
                    usb_clients = sum(
                        client.websocket.remote_address
                        and client.websocket.remote_address[0] in ("127.0.0.1", "::1")
                        for client in tuple(broadcaster.clients)
                    )
                    write_status(args.status_file, state, len(broadcaster.clients),
                                 usb_clients=usb_clients, connection_mode=args.connection_mode,
                                 rtmp_enabled=bool(args.rtmp_url), rtmp_readers=stream_server.readers() if args.rtmp_url else 0)
                    await asyncio.sleep(0.5)
            finally:
                pump_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await pump_task
                if usb_task:
                    usb_task.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await usb_task
        finally:
            stream_server.stop()
            for process in processes:
                stop_process_tree(process)
            for process in processes:
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=2)
    write_status(args.status_file, "stopped", connection_mode=args.connection_mode)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="AppleLive PC -> jailbroken iPhone sender")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--connection-mode", choices=("auto", "usb", "lan"), default="auto")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--bitrate-kbps", type=int, default=5000)
    parser.add_argument("--encoder", choices=("auto", "nvenc", "x264"), default="auto")
    parser.add_argument("--encoder-preset", choices=("ultrafast", "superfast", "veryfast", "faster", "fast"), default="veryfast")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--input-url", help="Read OBS H.264/AAC from a local RTMP/RTSP stream")
    parser.add_argument("--video-device", help="Windows dshow video device, e.g. OBS Virtual Camera")
    parser.add_argument("--audio-device", help="Windows dshow audio device, e.g. CABLE Output")
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--channels", type=int, default=2)
    parser.add_argument("--status-file", help="JSON status file for OBS integration")
    parser.add_argument("--stop-file", help="Exit when this file appears")
    parser.add_argument("--log-file", help="Write logs to this file")
    args = parser.parse_args()
    if args.width % 2 or args.height % 2 or args.width < 320 or args.height < 240:
        parser.error("width and height must be even and at least 320x240")
    if not 1 <= args.fps <= 60 or not 500 <= args.bitrate_kbps <= 30000:
        parser.error("fps must be 1-60 and bitrate must be 500-30000 kbps")
    return args


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
        write_status(arguments.status_file, "error", error=str(error), connection_mode=arguments.connection_mode)
        raise SystemExit(1)
