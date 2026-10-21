"""Verify the actual app-injection DEB, its scope and the embedded fixed binary."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import struct


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify(package: Path, plugin: Path) -> dict:
    parser = load_module("deb_archive", "verify-uvc-service.py")
    load_module("injector_binary", "verify-injector-dylib.py").verify(plugin)
    binary = plugin.read_bytes()
    archive = parser.ar_members(package.read_bytes())
    require(set(archive) == {"debian-binary", "control.tar.gz", "data.tar.gz"},
            "Expected a Debian gzip package with control and data archives")
    require(archive["debian-binary"] == b"2.0\n", "Unexpected Debian format")
    control = parser.tar_members(archive["control.tar.gz"])
    payload = parser.tar_members(archive["data.tar.gz"])
    require(set(control) == {"control"}, "Unexpected package maintainer script or control file")
    info, raw_control = control["control"]
    require(info.isfile() and info.mode == 0o644, "Invalid control permissions")
    metadata = {}
    for line in raw_control.decode("utf-8").splitlines():
        key, separator, value = line.partition(": ")
        require(bool(separator) and key not in metadata, "Invalid or repeated control field")
        metadata[key] = value
    require(metadata.get("Package") == "com.applelive.injector", "Wrong package identity")
    require(metadata.get("Version") == "0.1.14", "Unexpected DEB release version")
    require(metadata.get("Architecture") == "iphoneos-arm64", "Expected the rootless package architecture")
    require(metadata.get("Depends") == "firmware (>= 15.0), mobilesubstrate | ellekit | libhooker | substitute",
            "Missing OS/injection-loader dependency")
    for key in ("Conflicts", "Replaces"):
        require(set(metadata.get(key, "").split(", ")) == {"com.applelive.tweak", "com.applelive.full"},
                "Packages owning the same injected library must be replaced, not loaded together")
    directory = "var/jb/Library/MobileSubstrate/DynamicLibraries/"
    require(set(payload) == {directory + "AppleLive.dylib", directory + "AppleLive.plist"},
            "Unexpected app-injection payload or rootful path")
    for name, (member, data) in payload.items():
        require(member.isfile() and member.mode == 0o644 and bool(data), f"Invalid payload file: {name}")
    embedded = payload[directory + "AppleLive.dylib"][1]
    require(embedded == binary, "DEB contains a different or stale dylib")
    filter_plist = plistlib.loads(payload[directory + "AppleLive.plist"][1])
    require(set(filter_plist) == {"Filter"} and set(filter_plist["Filter"]) == {"Bundles"},
            "Filter must target app bundles only; no system daemon injection")
    bundles = filter_plist["Filter"]["Bundles"]
    require(isinstance(bundles, list) and len(bundles) == 4 and set(bundles) == {
        "com.apple.camera", "com.ss.iphone.ugc.Aweme", "com.zhiliaoapp.musically", "com.tencent.xin",
    }, "Unexpected target app filter")
    # This gate rejects older, otherwise valid dylibs accidentally repackaged for
    # the new release. The media behavior itself is tested by the native CI suite.
    for index in range(struct.unpack_from(">I", binary, 4)[0]):
        _, subtype, offset, size, _ = struct.unpack_from(">IIIII", binary, 8 + index * 20)
        body = binary[offset:offset + size]
        for marker in (b"hasFrameReceivedWithin:", b"markInterrupted", b"isVideoReplacementActive",
                       b"renderVideoIntoSample:pixelBuffer:",
                       b"retaining last video frame during transport recovery"):
            require(marker in body, f"Missing video-continuity implementation in slice {subtype:#x}")
    result = {
        "package": metadata["Package"], "version": metadata["Version"],
        "architecture": metadata["Architecture"], "target_bundles": bundles,
        "dylib_sha256": hashlib.sha256(binary).hexdigest(),
        "deb_sha256": hashlib.sha256(package.read_bytes()).hexdigest(),
        "deb_bytes": package.stat().st_size,
    }
    print("Verified rootless app filter, permissions, upgrade conflicts and exact fixed dylib")
    return result


if __name__ == "__main__":
    import json
    arguments = argparse.ArgumentParser()
    arguments.add_argument("package", type=Path)
    arguments.add_argument("plugin", type=Path)
    args = arguments.parse_args()
    print(json.dumps(verify(args.package, args.plugin), ensure_ascii=False, indent=2))
