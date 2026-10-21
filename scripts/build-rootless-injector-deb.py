"""Package the standalone AppleLive dylib as a Dopamine rootless Debian tweak.

This keeps the already-built standalone injector binary and adds the rootless
ElleKit filter/package metadata. It deliberately filters only target apps; the
standalone binary contains UIKit/app UI code and must not be loaded into
mediaserverd.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import io
import plistlib
import tarfile
import tempfile
from pathlib import Path

PACKAGE = "com.applelive.injector"
VERSION = "0.1.14"
ARCHITECTURE = "iphoneos-arm64"

PLIST = plistlib.dumps({"Filter": {"Bundles": [
    "com.apple.camera", "com.ss.iphone.ugc.Aweme",
    "com.zhiliaoapp.musically", "com.tencent.xin",
]}}, fmt=plistlib.FMT_XML)

CONTROL_TEMPLATE = """Package: {package}
Name: 福煋推流插件
Version: {version}
Architecture: {architecture}
Description: Fuxing camera and audio source with continuous video during USB recovery, for Dopamine rootless
Maintainer: AppleLive
Section: Tweaks
Depends: firmware (>= 15.0), mobilesubstrate | ellekit | libhooker | substitute
Conflicts: com.applelive.tweak, com.applelive.full
Replaces: com.applelive.tweak, com.applelive.full
"""


def tar_gz(files: list[tuple[str, bytes, int]]) -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for name, payload, mode in files:
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mode = mode
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "wheel"
            info.mtime = 0
            archive.addfile(info, io.BytesIO(payload))
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
    if len(payload) % 2:
        result += b"\n"
    return result


def load_verifier(path: Path):
    verifier = path.with_name("verify-injector-dylib.py")
    spec = importlib.util.spec_from_file_location("verify_injector_dylib", verifier)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load verify-injector-dylib.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build(source: Path, destination: Path) -> None:
    source = source.resolve()
    destination = destination.resolve()
    if not source.is_file():
        raise FileNotFoundError(source)
    if source.suffix != ".dylib":
        raise ValueError(f"expected a .dylib input, got {source.name}")

    verifier = load_verifier(Path(__file__))
    verifier.verify(source)

    control = CONTROL_TEMPLATE.format(
        package=PACKAGE, version=VERSION, architecture=ARCHITECTURE
    ).encode("utf-8")
    control_tar = tar_gz([("control", control, 0o644)])
    data_tar = tar_gz(
        [
            (
                "var/jb/Library/MobileSubstrate/DynamicLibraries/AppleLive.dylib",
                source.read_bytes(),
                0o644,
            ),
            (
                "var/jb/Library/MobileSubstrate/DynamicLibraries/AppleLive.plist",
                PLIST,
                0o644,
            ),
        ]
    )

    destination.parent.mkdir(parents=True, exist_ok=True)
    # Only publish after inspecting the actual archive, including an exact
    # binary comparison and a check that both slices contain the continuity fix.
    spec = importlib.util.spec_from_file_location(
        "verify_rootless_deb", Path(__file__).with_name("verify-rootless-injector-deb.py")
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load rootless DEB verifier")
    package_verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package_verifier)
    with tempfile.NamedTemporaryFile(mode="wb", prefix="applelive-", suffix=".deb",
                                     dir=destination.parent, delete=False) as output:
        pending = Path(output.name)
    try:
        with pending.open("wb") as output:
            output.write(b"!<arch>\n")
            output.write(ar_member("debian-binary", b"2.0\n"))
            output.write(ar_member("control.tar.gz", control_tar))
            output.write(ar_member("data.tar.gz", data_tar))
        package_verifier.verify(pending, source)
        pending.replace(destination)
    finally:
        pending.unlink(missing_ok=True)
    print(f"Created {destination}")
    print(f"Source SHA256: {hashlib.sha256(source.read_bytes()).hexdigest()}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    build(args.source, args.destination)


if __name__ == "__main__":
    main()
