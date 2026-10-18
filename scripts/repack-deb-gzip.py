"""Repack a Debian archive with gzip-compressed control and data members."""

import argparse
import gzip
import io
import tarfile
from pathlib import Path


def ar_members(data):
    if data[:8] != b"!<arch>\n":
        raise ValueError("not a Debian ar archive")
    cursor = 8
    result = []
    while cursor < len(data):
        header = data[cursor:cursor + 60]
        if len(header) != 60 or header[-2:] != b"`\n":
            raise ValueError("invalid ar member header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58])
        cursor += 60
        result.append((name, data[cursor:cursor + size]))
        cursor += size + (size % 2)
    return result


def read_tar(data):
    members = []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        for item in archive.getmembers():
            payload = archive.extractfile(item).read() if item.isfile() else None
            members.append((item, payload))
    return members


def gzip_tar(members):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for item, payload in members:
            cloned = tarfile.TarInfo(item.name)
            cloned.mode = item.mode
            cloned.uid = item.uid
            cloned.gid = item.gid
            cloned.uname = item.uname
            cloned.gname = item.gname
            cloned.mtime = item.mtime
            cloned.type = item.type
            cloned.linkname = item.linkname
            cloned.size = len(payload) if payload is not None else 0
            archive.addfile(cloned, io.BytesIO(payload) if payload is not None else None)
    return gzip.compress(raw.getvalue(), compresslevel=9, mtime=0)


def ar_header(name, data):
    if len(name) > 15:
        raise ValueError(f"ar member name too long: {name}")
    return (
        f"{name}/".ljust(16)
        + "0".rjust(12)
        + "0".rjust(6)
        + "0".rjust(6)
        + "100644".rjust(8)
        + str(len(data)).rjust(10)
        + "`\n"
    ).encode("ascii")


def write_ar(path, members):
    with path.open("wb") as output:
        output.write(b"!<arch>\n")
        for name, data in members:
            output.write(ar_header(name, data))
            output.write(data)
            if len(data) % 2:
                output.write(b"\n")


def repack(source, destination):
    result = []
    for name, data in ar_members(source.read_bytes()):
        if name.startswith("control.tar"):
            result.append(("control.tar.gz", gzip_tar(read_tar(data))))
        elif name.startswith("data.tar"):
            result.append(("data.tar.gz", gzip_tar(read_tar(data))))
        else:
            result.append((name, data))
    destination.parent.mkdir(parents=True, exist_ok=True)
    write_ar(destination, result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    repack(args.source, args.destination)


if __name__ == "__main__":
    main()
