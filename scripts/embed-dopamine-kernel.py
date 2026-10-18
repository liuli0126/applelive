"""Embed matched local firmware images in an official Dopamine IPA for offline use.

The images are extracted from a local IPSW/OTA or an official Apple OTA URL. This
invalidates the IPA signature: sideload the resulting IPA with a tool that
signs it again. Never publish an IPA containing Apple's firmware images.
"""

from __future__ import annotations

import argparse
from contextlib import ExitStack
import hashlib
import io
import plistlib
import re
import posixpath
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

MAX_IMAGE_BYTES = 512 * 1024 * 1024
EXTRA_IMAGES = {
    "Ap,SecurePageTableMonitor": "sptm.img4",
    "Ap,TrustedExecutionMonitor": "txm.img4",
}


class AppleRangeFile(io.RawIOBase):
    """Seekable reader for Apple's OTA ZIP, fetching only requested byte ranges."""

    def __init__(self, url: str):
        if urlsplit(url).scheme != "https" or urlsplit(url).hostname != "updates.cdn-apple.com":
            raise ValueError("Firmware URL must point to Apple's HTTPS update CDN")
        try:
            import requests
        except ImportError as exc:
            raise RuntimeError("Remote OTA support requires the requests Python package") from exc
        super().__init__()
        self.session = requests.Session()
        self.url = url
        self.position = 0
        self.cached_start = -1
        self.cached = b""
        try:
            response = self.session.get(url, headers={"Range": "bytes=0-0"}, timeout=60, stream=True)
            with response:
                length = re.fullmatch(r"bytes 0-0/(\d+)", response.headers.get("Content-Range", ""))
                if response.status_code != 206 or not length or response.content != b"P":
                    raise ValueError("Apple OTA server did not provide a valid ranged ZIP response")
                self.length = int(length.group(1))
        except BaseException:
            self.session.close()
            raise

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=io.SEEK_SET):
        if whence == io.SEEK_SET:
            target = offset
        elif whence == io.SEEK_CUR:
            target = self.position + offset
        elif whence == io.SEEK_END:
            target = self.length + offset
        else:
            raise ValueError("Invalid seek mode")
        if not 0 <= target <= self.length:
            raise ValueError("Seek outside OTA archive")
        self.position = target
        return target

    def read(self, count=-1):
        if count < 0:
            count = self.length - self.position
        count = min(count, self.length - self.position)
        if count == 0:
            return b""
        if count > 64 * 1024 * 1024:
            raise ValueError("Excessive single OTA range request")
        if self.cached_start <= self.position and self.position + count <= self.cached_start + len(self.cached):
            offset = self.position - self.cached_start
            self.position += count
            return self.cached[offset:offset + count]
        start = self.position
        end = min(self.length - 1, start + max(count, 256 * 1024) - 1)
        response = self.session.get(self.url, headers={"Range": f"bytes={start}-{end}"},
                                    timeout=60, stream=True)
        with response:
            expected = f"bytes {start}-{end}/{self.length}"
            if response.status_code != 206 or response.headers.get("Content-Range") != expected:
                raise ValueError(f"OTA server returned an invalid response for bytes {start}-{end}")
            if response.headers.get("Content-Length") != str(end - start + 1):
                raise ValueError("OTA server returned an unexpected range length")
            data = b"".join(response.iter_content(chunk_size=1024 * 1024))
        if len(data) != end - start + 1:
            raise ValueError("OTA server returned incomplete data")
        self.cached_start, self.cached = start, data
        self.position += count
        return data[:count]

    def close(self):
        self.session.close()
        super().close()


def firmware_member(prefix: str, name: str) -> str:
    if not isinstance(name, str) or not name or name.startswith("/") or "\\" in name:
        raise ValueError(f"Invalid firmware path: {name!r}")
    normalized = posixpath.normpath(name)
    if normalized.startswith("../") or normalized in (".", ".."):
        raise ValueError(f"Unsafe firmware path: {name!r}")
    return prefix + normalized


def extract_image(archive: zipfile.ZipFile, member: str) -> bytes:
    info = archive.getinfo(member)
    if info.file_size == 0 or info.file_size > MAX_IMAGE_BYTES:
        raise ValueError(f"Unexpected image size for {member}: {info.file_size}")
    image = archive.read(member)
    if len(image) != info.file_size:
        raise ValueError(f"Incomplete firmware image: {member}")
    return image


def matched_images(archive: zipfile.ZipFile, board: str, build: str, product: str) -> dict[str, bytes]:
    prefix = "" if "BuildManifest.plist" in archive.namelist() else "AssetData/boot/"
    manifest = plistlib.loads(archive.read(prefix + "BuildManifest.plist"))
    if manifest.get("ProductBuildVersion") != build:
        raise ValueError(f"Firmware build is {manifest.get('ProductBuildVersion')!r}, expected {build!r}")
    if product not in manifest.get("SupportedProductTypes", []):
        raise ValueError(f"Firmware does not list device model {product}")
    candidates = [
        identity for identity in manifest.get("BuildIdentities", [])
        if identity.get("Info", {}).get("DeviceClass", "").casefold() == board.casefold()
        and not identity.get("Info", {}).get("Variant", "").startswith("Research")
    ]
    if not candidates:
        raise ValueError(f"Firmware build {build} does not contain board {board}")
    selected = candidates[0]["Manifest"]
    kernel_path = firmware_member(prefix, selected["KernelCache"]["Info"]["Path"])
    image = extract_image(archive, kernel_path)
    expected_digest = selected["KernelCache"].get("Digest")
    if isinstance(expected_digest, bytes) and len(expected_digest) == 48 and hashlib.sha384(image).digest() != expected_digest:
        raise ValueError("Kernel SHA-384 does not match Apple's BuildManifest")
    images = {"kernelcache": image}
    for key, name in EXTRA_IMAGES.items():
        component = selected.get(key)
        if component is not None:
            image = extract_image(archive, firmware_member(prefix, component["Info"]["Path"]))
            expected_digest = component.get("Digest")
            if isinstance(expected_digest, bytes) and len(expected_digest) == 48 and hashlib.sha384(image).digest() != expected_digest:
                raise ValueError(f"{name} SHA-384 does not match Apple's BuildManifest")
            images[name] = image
    return images


def package(ipa: Path, firmware: Path | str, destination: Path, board: str, build: str, product: str) -> None:
    if not ipa.is_file() or (isinstance(firmware, Path) and not firmware.is_file()):
        raise FileNotFoundError("The official IPA and local IPSW/OTA must both exist")
    if destination.exists() or destination.resolve() == ipa.resolve() or (
        isinstance(firmware, Path) and destination.resolve() == firmware.resolve()
    ):
        raise ValueError("Choose a new output path; inputs and existing files cannot be overwritten")
    with ExitStack() as stack:
        source = stack.enter_context(AppleRangeFile(firmware)) if isinstance(firmware, str) else firmware
        archive = stack.enter_context(zipfile.ZipFile(source))
        images = matched_images(archive, board, build, product)
    with zipfile.ZipFile(ipa) as original:
        apps = [name for name in original.namelist() if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2]
        if len(apps) != 1:
            raise ValueError("Expected exactly one app bundle in the Dopamine IPA")
        app_info = plistlib.loads(original.read(apps[0]))
        bundle = app_info.get("CFBundleIdentifier", "")
        if "dopamine" not in bundle.casefold():
            raise ValueError(f"This IPA does not appear to be Dopamine: {bundle!r}")
        app_dir = apps[0].removesuffix("Info.plist")
        for name in images:
            if app_dir + name in original.namelist():
                raise ValueError(f"IPA already embeds {name}; refusing to overwrite it")
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            with zipfile.ZipFile(destination, "w") as packed:
                for info in original.infolist():
                    packed.writestr(info, original.read(info.filename))
                for name, image in images.items():
                    packed.writestr(app_dir + name, image, compress_type=zipfile.ZIP_DEFLATED)
        except BaseException:
            destination.unlink(missing_ok=True)
            raise
    with zipfile.ZipFile(destination) as result:
        if result.testzip() is not None:
            destination.unlink(missing_ok=True)
            raise ValueError("Output IPA failed archive integrity check")
        for name, image in images.items():
            if result.read(app_dir + name) != image:
                destination.unlink(missing_ok=True)
                raise ValueError(f"Output image was altered: {name}")
    print(f"Offline IPA: {destination}")
    print(f"Matched: {product}, board {board}, build {build}; embedded: {', '.join(images)}")
    print("Re-sign this IPA when installing it; modifying an IPA invalidates its original signature.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True, help="Official Dopamine IPA")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--firmware", type=Path, help="Matching local IPSW or OTA zip")
    source.add_argument("--firmware-url", help="Official Apple OTA ZIP; only required images are downloaded")
    parser.add_argument("--board", required=True, help="Exact device board configuration, e.g. n104ap")
    parser.add_argument("--build", required=True, help="Exact iOS build number shown in Settings")
    parser.add_argument("--product", required=True, help="Exact device identifier, e.g. iPhone12,1")
    parser.add_argument("--output", type=Path, required=True, help="New output IPA path")
    args = parser.parse_args()
    package(args.ipa, args.firmware_url or args.firmware, args.output, args.board, args.build, args.product)


if __name__ == "__main__":
    main()
