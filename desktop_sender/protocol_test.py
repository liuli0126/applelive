import struct
from argparse import Namespace
from pathlib import Path
from tempfile import TemporaryDirectory
import json

from sender import AnnexBParser, AUDIO_HEADER, VIDEO_HEADER, video_command, write_status


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
                     video_device="OBS Virtual Camera")
    command = video_command(args)
    assert "gdigrab" not in command
    assert "video=OBS Virtual Camera" in command
    assert "scale=1280:720" in command


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
    test_status_file_is_atomic_and_readable()
    print("protocol self-test passed")
