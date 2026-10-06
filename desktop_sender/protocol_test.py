import asyncio
import struct
from argparse import Namespace
from pathlib import Path
from tempfile import TemporaryDirectory
import json
import os

from sender import AnnexBParser, AUDIO_HEADER, VIDEO_HEADER, Broadcaster, audio_command, capture_audio, video_command, write_status


def test_annexb_parser_handles_split_chunks():
    parser = AnnexBParser()
    stream = b"\x00\x00\x00\x01\x67\x64\x00\x1f\x00\x00\x01\x68\xee\x3c\x80"
    output = []
    for byte in stream:
        output.extend(parser.feed(bytes([byte])))
    assert output == [
        b"\x00\x00\x00\x01\x67\x64\x00\x1f",
    ]
    assert parser.flush() == b"\x00\x00\x01\x68\xee\x3c\x80"


def test_headers_are_little_endian_and_ascii_typed():
    video = VIDEO_HEADER.pack(b"fram", 4, 1, 1280, 720)
    assert video[:4] == b"fram"
    assert struct.unpack("<IIII", video[4:]) == (4, 1, 1280, 720)
    audio = AUDIO_HEADER.pack(b"audi", 48000, 2)
    assert audio == b"audi" + struct.pack("<II", 48000, 2)


def test_annexb_large_frames_and_every_start_code_boundary():
    # Large IDR frames arrive in many pipe chunks. Include 3/4-byte markers,
    # escape sequences inside payload, leading noise, and tiny valid NALs.
    nals = [b"\x00\x00\x00\x01\x65" + b"\x12\x00\x00\x03\x01" * 50000,
            b"\x00\x00\x01\x68", b"\x00\x00\x00\x01\x67\x64",
            b"\x00\x00\x01\x41" + b"\x37" * 100000]
    stream = b"leading noise" + b"".join(nals)
    for size in (1, 3, 1024, 4093, 65536, len(stream)):
        parser = AnnexBParser()
        actual = []
        for offset in range(0, len(stream), size):
            actual.extend(parser.feed(stream[offset:offset + size]))
        final = parser.flush()
        if final: actual.append(final)
        assert actual == nals, size


def test_obs_video_command_uses_virtual_camera():
    args = Namespace(ffmpeg="ffmpeg", fps=30, width=1280, height=720,
                     video_device="OBS Virtual Camera", bitrate_kbps=5000,
                     encoder_preset="veryfast", encoder="x264")
    command = video_command(args)
    assert "gdigrab" not in command
    assert "video=OBS Virtual Camera" in command
    assert any(part.startswith("scale=1280:720:force_original_aspect_ratio=decrease") for part in command)
    assert command[command.index("-b:v") + 1] == "5000k"
    assert command[command.index("-preset") + 1] == "veryfast"
    assert any(part.startswith("repeat-headers=1") for part in command)

    args.encoder = "nvenc"
    command = video_command(args)
    assert "h264_nvenc" in command
    assert command[command.index("-tune") + 1] == "ull"
    assert command[command.index("-profile:v") + 1] == "baseline"
    assert command[command.index("-coder:v") + 1] == "cavlc"
    assert command[command.index("-aud") + 1] == "1"


def test_local_obs_stream_is_copied_to_usb_packets():
    args = Namespace(ffmpeg="ffmpeg", fps=30, width=1920, height=1080,
                     video_device=None, audio_device=None, bitrate_kbps=5000,
                     encoder_preset="veryfast", encoder="auto", rtmp_url=None,
                     input_url="rtmp://127.0.0.1:1935/live/applelive",
                     channels=2, sample_rate=48000)
    video = video_command(args)
    audio = audio_command(args)
    self_copy = video[video.index("-c:v"):video.index("-c:v") + 2]
    assert self_copy == ["-c:v", "copy"]
    assert "h264_mp4toannexb,h264_metadata=aud=insert" in video
    assert "0:v:0" in video
    assert audio is not None and "0:a:0" in audio
    assert "f32le" in audio and "dshow" not in audio


def test_audio_packets_keep_sample_alignment():
    class SplitPipe:
        def __init__(self):
            self.chunks = iter((b"\x01\x02\x03", b"\x04\x05\x06\x07\x08\x09", b"\x0a\x0b\x0c\x0d\x0e\x0f\x10", b""))

        def read1(self, size):
            return next(self.chunks)

    class Collector:
        def __init__(self):
            self.packets = []

        def publish(self, packet):
            self.packets.append(packet)

    collector = Collector()
    capture_audio(Namespace(stdout=SplitPipe()), collector, 48000, 2)
    assert b"".join(packet[AUDIO_HEADER.size:] for packet in collector.packets) == bytes(range(1, 17))
    assert all((len(packet) - AUDIO_HEADER.size) % 8 == 0 for packet in collector.packets)


def test_slow_client_resumes_at_keyframe():
    async def exercise():
        class Socket:
            remote_address = ("127.0.0.1", 0)

            async def send(self, message):
                pass

        broadcaster = Broadcaster(asyncio.get_running_loop())
        client = await broadcaster.add(Socket())

        def nal(sequence, kind):
            return VIDEO_HEADER.pack(b"fram", sequence, int(kind == 5), 1280, 720) + b"\x00\x00\x00\x01" + bytes([kind])

        broadcaster.publish(nal(0, 7))
        broadcaster.publish(nal(1, 8))
        broadcaster.publish(nal(2, 1))
        await asyncio.sleep(0)
        assert client.queue.empty()
        broadcaster.publish(nal(3, 5))
        await asyncio.sleep(0)
        assert [item[-1] for item in tuple(client.queue._queue)] == [7, 8, 5]
        for _ in range(25):
            broadcaster.publish(AUDIO_HEADER.pack(b"audi", 48000, 2) + b"\x00" * 8)
        await asyncio.sleep(0)
        assert client.waiting_for_keyframe
        broadcaster.publish(nal(4, 1))
        broadcaster.publish(nal(5, 5))
        await asyncio.sleep(0)
        assert [item[-1] for item in tuple(client.queue._queue)[-3:]] == [7, 8, 5]

    asyncio.run(exercise())


def test_status_file_is_atomic_and_readable():
    with TemporaryDirectory() as directory:
        status_file = Path(directory) / "status.json"
        write_status(str(status_file), "running", 1)
        result = json.loads(status_file.read_text(encoding="utf-8"))
        assert result["state"] == "running"
        assert result["clients"] == 1
        assert result["usb_clients"] == 0
        assert result["updated_at"] > 0
        assert not (Path(directory) / "status.json.tmp").exists()


def test_status_reader_lock_does_not_stop_capture():
    if os.name != "nt":
        return
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                   wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    with TemporaryDirectory() as directory:
        target = Path(directory) / "status.json"
        write_status(str(target), "running", 1)
        handle = kernel.CreateFileW(str(target), 0x80000000, 3, None, 3, 0, None)
        assert handle != wintypes.HANDLE(-1).value
        try:
            write_status(str(target), "running", 2)
            assert json.loads(target.read_text())["clients"] == 1
            assert not list(Path(directory).glob("*.tmp"))
        finally:
            kernel.CloseHandle(handle)
        write_status(str(target), "running", 2)
        assert json.loads(target.read_text())["clients"] == 2


if __name__ == "__main__":
    test_annexb_parser_handles_split_chunks()
    test_annexb_large_frames_and_every_start_code_boundary()
    test_headers_are_little_endian_and_ascii_typed()
    test_obs_video_command_uses_virtual_camera()
    test_audio_packets_keep_sample_alignment()
    test_slow_client_resumes_at_keyframe()
    test_status_file_is_atomic_and_readable()
    test_status_reader_lock_does_not_stop_capture()
    print("protocol self-test passed")
