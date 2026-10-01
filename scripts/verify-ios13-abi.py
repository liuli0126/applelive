"""Reject an iOS 13 package built with the incompatible modern arm64e ABI."""
import struct
import sys
from pathlib import Path


def verify(path: Path) -> None:
    data = path.read_bytes()
    magic, count = struct.unpack_from(">II", data)
    if magic != 0xCAFEBABE or not 1 <= count <= 8:
        raise ValueError("Expected a universal Mach-O with arm64 and legacy arm64e")
    found = set()
    for index in range(count):
        cpu, subtype, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + index * 20)
        if offset + size > len(data):
            raise ValueError("Truncated Mach-O slice")
        if cpu != 0x0100000C:
            continue
        if subtype & 0x00FFFFFF == 2 and subtype != 2:
            raise ValueError(f"arm64e subtype {subtype:#x} requires iOS 14+; rebuild with clang 10/Xcode 11")
        found.add(subtype)
        header = struct.unpack_from("<IIIIIIII", data, offset)
        if header[0] != 0xFEEDFACF or header[1:3] != (cpu, subtype):
            raise ValueError("Invalid 64-bit Mach-O slice header")
        cursor = offset + 32
        minimum = None
        for _ in range(header[4]):
            command, length = struct.unpack_from("<II", data, cursor)
            if length < 8 or cursor + length > offset + size:
                raise ValueError("Invalid Mach-O load command")
            if command == 0x25:  # LC_VERSION_MIN_IPHONEOS
                minimum = struct.unpack_from("<I", data, cursor + 8)[0]
            elif command == 0x32:  # LC_BUILD_VERSION
                platform, minimum = struct.unpack_from("<II", data, cursor + 8)
                if platform != 2:
                    raise ValueError("Expected the iOS device platform")
            cursor += length
        if minimum is None or minimum > 0x000D0000:
            raise ValueError("Every slice must have an iOS deployment target of 13.0 or earlier")
        print(f"Verified CPU subtype {subtype:#x}, minimum iOS {minimum >> 16}.{minimum >> 8 & 255}")
    if not {0, 2}.issubset(found):
        raise ValueError("Both arm64 and legacy arm64e slices are required")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]))
    except (IndexError, OSError, ValueError, struct.error) as error:
        sys.exit(str(error))
