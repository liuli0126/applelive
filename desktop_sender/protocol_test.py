import struct

from sender import AnnexBParser, AUDIO_HEADER, VIDEO_HEADER


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


if __name__ == "__main__":
    test_annexb_parser_handles_split_chunks()
    test_headers_are_little_endian_and_ascii_typed()
    print("protocol self-test passed")
