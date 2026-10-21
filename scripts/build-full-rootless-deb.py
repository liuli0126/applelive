"""Build one Dopamine rootless package containing AppleLive app injection and USB service."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import io
import tarfile
from pathlib import Path

PACKAGE = "com.applelive.full"
VERSION = "0.1.13-usb2"
ARCHITECTURE = "iphoneos-arm64"

PLIST = """{\n    Filter = {\n        Bundles = (\"com.apple.camera\", \"com.ss.iphone.ugc.Aweme\", \"com.zhiliaoapp.musically\", \"com.tencent.xin\");\n    };\n}\n"""

CONTROL = f"""Package: {PACKAGE}
Name: AppleLive USB + App Injection (Dopamine)
Version: {VERSION}
Architecture: {ARCHITECTURE}
Description: AppleLive USB capture service and camera replacement for Dopamine rootless
Maintainer: AppleLive
Author: AppleLive
Section: Multimedia
Depends: firmware (>= 15.0), mobilesubstrate | ellekit | libhooker | substitute
Conflicts: com.applelive.tweak, com.applelive.injector, com.applelive.uvchost
Replaces: com.applelive.tweak, com.applelive.injector, com.applelive.uvchost
""".encode("utf-8")


def load_standalone_builder():
    path = Path(__file__).with_name("build-rootless-injector-deb.py")
    spec = importlib.util.spec_from_file_location("standalone_builder", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load standalone package helpers")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ar_members(data: bytes) -> dict[str, bytes]:
    if data[:8] != b"!<arch>\n":
        raise ValueError("not a Debian ar archive")
    cursor = 8
    result: dict[str, bytes] = {}
    while cursor < len(data):
        header = data[cursor:cursor + 60]
        if len(header) != 60 or header[-2:] != b"`\n":
            raise ValueError("invalid ar member header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58])
        cursor += 60
        result[name] = data[cursor:cursor + size]
        cursor += size + (size & 1)
    if cursor != len(data):
        raise ValueError("trailing bytes in Debian archive")
    return result


def tar_members(data: bytes) -> dict[str, tuple[tarfile.TarInfo, bytes | None]]:
    result = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        for member in archive.getmembers():
            name = member.name.removeprefix("./").rstrip("/")
            if not name:
                continue
            if name.startswith("/") or ".." in name.split("/"):
                raise ValueError(f"unsafe package path: {name}")
            if not (member.isdir() or member.isfile()):
                raise ValueError(f"unexpected package entry: {name}")
            payload = archive.extractfile(member).read() if member.isfile() else None
            result[name] = (member, payload)
    return result


def tar_gz(entries: list[tuple[str, bytes | None, int]]) -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for name, payload, mode in entries:
            info = tarfile.TarInfo(name)
            info.size = len(payload) if payload is not None else 0
            info.mode = mode
            info.uid = info.gid = 0
            info.uname = "root"
            info.gname = "wheel"
            info.mtime = 0
            info.type = tarfile.DIRTYPE if payload is None else tarfile.REGTYPE
            archive.addfile(info, io.BytesIO(payload) if payload is not None else None)
    return gzip.compress(raw.getvalue(), compresslevel=9, mtime=0)


def ar_member(name: str, payload: bytes) -> bytes:
    if len(name) > 15:
        raise ValueError(f"ar member name is too long: {name}")
    header = (
        f"{name}/".ljust(16)
        + "0".rjust(12)
        + "0".rjust(6)
        + "0".rjust(6)
        + "100644".rjust(8)
        + str(len(payload)).rjust(10)
        + "`\n"
    ).encode("ascii")
    result = header + payload
    return result + (b"\n" if len(payload) & 1 else b"")


def build(plugin: Path, service: Path, destination: Path) -> None:
    plugin = plugin.resolve()
    service = service.resolve()
    destination = destination.resolve()
    if not plugin.is_file() or plugin.suffix != ".dylib":
        raise ValueError(f"invalid standalone plugin: {plugin}")
    if not service.is_file() or service.suffix != ".deb":
        raise ValueError(f"invalid USB service package: {service}")

    verifier = load_standalone_builder().load_verifier(Path(__file__))
    verifier.verify(plugin)
    service_archive = ar_members(service.read_bytes())
    if service_archive.get("debian-binary") != b"2.0\n":
        raise ValueError("USB service package is not Debian format 2.0")
    service_data_member = next((v for k, v in service_archive.items() if k.startswith("data.tar")), None)
    service_control_member = next((v for k, v in service_archive.items() if k.startswith("control.tar")), None)
    if service_data_member is None or service_control_member is None:
        raise ValueError("USB service package is missing control/data archives")
    service_data = tar_members(service_data_member)
    service_control = tar_members(service_control_member)

    embedded = service_data["var/jb/Library/AppleLive/AppleLive.dylib"][1]
    if embedded != plugin.read_bytes():
        raise ValueError("standalone plugin and USB service package do not match")

    # Keep the service package's signed binaries, launch daemon, app and lifecycle
    # scripts, then add the ElleKit dynamic-library path and filter.
    data_entries: list[tuple[str, bytes | None, int]] = []
    for name, (member, payload) in service_data.items():
        data_entries.append((name, payload, member.mode))
    data_entries.extend([
        (
            "var/jb/Library/MobileSubstrate/DynamicLibraries/AppleLive.dylib",
            plugin.read_bytes(),
            0o644,
        ),
        (
            "var/jb/Library/MobileSubstrate/DynamicLibraries/AppleLive.plist",
            PLIST.encode("utf-8"),
            0o644,
        ),
    ])

    scripts = {}
    for name in ("postinst", "prerm", "postrm"):
        if name not in service_control:
            raise ValueError(f"USB service package is missing {name}")
        scripts[name] = service_control[name][1]
    control_entries = [("control", CONTROL, 0o644)] + [(name, body, 0o755) for name, body in scripts.items()]
    control_tar = tar_gz(control_entries)
    data_tar = tar_gz(data_entries)

    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as output:
        output.write(b"!<arch>\n")
        output.write(ar_member("debian-binary", b"2.0\n"))
        output.write(ar_member("control.tar.gz", control_tar))
        output.write(ar_member("data.tar.gz", data_tar))
    print(f"Created {destination}")
    print(f"Plugin SHA256: {hashlib.sha256(plugin.read_bytes()).hexdigest()}")
    print(f"Package SHA256: {hashlib.sha256(destination.read_bytes()).hexdigest()}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("plugin", type=Path)
    parser.add_argument("service", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    build(args.plugin, args.service, args.destination)


if __name__ == "__main__":
    main()
