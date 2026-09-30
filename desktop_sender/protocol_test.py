import asyncio
import struct
from argparse import Namespace
from pathlib import Path
from tempfile import TemporaryDirectory
import json

from sender import AnnexBParser, AUDIO_HEADER, VIDEO_HEADER, Broadcaster, capture_audio, video_command, write_status


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
    assert "repeat-headers=1" in command

    args.encoder = "nvenc"
    command = video_command(args)
    assert "h264_nvenc" in command
    assert command[command.index("-tune") + 1] == "ull"


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
        assert result["updated_at"] > 0
        assert not (Path(directory) / "status.json.tmp").exists()


if __name__ == "__main__":
    test_annexb_parser_handles_split_chunks()
    test_headers_are_little_endian_and_ascii_typed()
    test_obs_video_command_uses_virtual_camera()
    test_audio_packets_keep_sample_alignment()
    test_slow_client_resumes_at_keyframe()
    test_status_file_is_atomic_and_readable()
    print("protocol self-test passed")
