"""Check the injector artifact's architecture, deployment target and imports."""

import struct
import sys
from pathlib import Path


def verify(path: Path) -> None:
    data = path.read_bytes()
    magic, count = struct.unpack_from(">II", data)
    if magic != 0xCAFEBABE or not 1 <= count <= 8:
        raise ValueError("Expected a universal iOS device dylib")
    found = set()
    for index in range(count):
        cpu, subtype, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + index * 20)
        if cpu != 0x0100000C or offset + size > len(data):
            raise ValueError("Invalid iOS device slice")
        found.add(subtype)
        header = struct.unpack_from("<IIIIIIII", data, offset)
        if header[:3] != (0xFEEDFACF, cpu, subtype) or header[3] != 6:
            raise ValueError("Expected a 64-bit Mach-O dylib")
        cursor = offset + 32
        minimum = None
        imports = []
        for _ in range(header[4]):
            command, length = struct.unpack_from("<II", data, cursor)
            if length < 8 or cursor + length > offset + size:
                raise ValueError("Invalid Mach-O load command")
            if command == 0x25:
                minimum = struct.unpack_from("<I", data, cursor + 8)[0]
            elif command == 0x32:
                platform, minimum = struct.unpack_from("<II", data, cursor + 8)
                if platform != 2:
                    raise ValueError("Expected the iOS device platform")
            elif command in (0xC, 0x80000018, 0x8000001F):
                name_offset = struct.unpack_from("<I", data, cursor + 8)[0]
                dependency = data[cursor + name_offset:cursor + length].split(b"\0", 1)[0].decode()
                if not dependency.startswith(("/System/Library/", "/usr/lib/")):
                    raise ValueError(f"External dependency: {dependency}")
                if any(name in dependency.lower() for name in ("substrate", "ellekit", "libhooker")):
                    raise ValueError(f"Injection framework dependency: {dependency}")
                imports.append(dependency)
            cursor += length
        expected = 0x000E0000 if subtype == 0 else 0x000F0000
        if minimum != expected:
            raise ValueError(f"Unexpected deployment target for subtype {subtype:#x}")
        print(f"Verified {subtype:#x}, iOS {minimum >> 16}.0, {len(imports)} system imports")
    if found != {0, 0x80000002}:
        raise ValueError("Expected arm64 and modern arm64e")
    if b"ALInjectedVirtualCamera" not in data:
        raise ValueError("Injector class namespace is missing")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]))
    except (IndexError, OSError, ValueError, struct.error) as error:
        sys.exit(str(error))
