from pathlib import Path
import argparse
import hashlib
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
GROUPS = {
    "source/ios-tweak": ROOT / "ios-tweak",
    "source/ios-injector": ROOT / "ios-injector",
    "source/ios-uvc-service": ROOT / "ios-uvc-service",
}
SCRIPTS = [
    "scripts/build-rootless-injector-deb.py",
    "scripts/build-full-rootless-deb.py",
    "scripts/build-uvc-service.sh",
    "scripts/build-ios-uvc.sh",
    "scripts/build-ios-ffmpeg.sh",
    "scripts/relink-injector.sh",
    "scripts/relink-uvc-service.sh",
    "scripts/verify-injector-dylib.py",
    "scripts/verify-rootless-injector-deb.py",
    "scripts/verify-uvc-service.py",
]
EXTRA = [
    "docs/handoff/04-DEB插件源码说明.md",
    "obs-plugin/phone-plugin/AppleLive-relink.tar.gz",
    "obs-plugin/phone-plugin/FFmpeg-LICENSE.txt",
    "obs-plugin/phone-plugin/FFmpeg-SOURCE.txt",
    "obs-plugin/phone-plugin/fishhook-LICENSE.txt",
    "obs-plugin/phone-plugin/libusb-LICENSE.txt",
    "obs-plugin/phone-plugin/libuvc-LICENSE.txt",
    "obs-plugin/phone-plugin/USBHost-NOTICE.txt",
]
SECRET = re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)")

def files():
    result = {}
    for prefix, directory in GROUPS.items():
        for p in directory.rglob("*"):
            if not p.is_file() or p.is_symlink() or "__pycache__" in p.parts:
                continue
            result[(Path(prefix) / p.relative_to(directory)).as_posix()] = p
    for name in SCRIPTS + EXTRA:
        p = ROOT / name
        if not p.is_file():
            raise FileNotFoundError(p)
        result[name] = p
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prefix = "福煋DEB插件源码-" + args.date.replace("-", "")
    payload = files()
    manifest = {"date": args.date, "scope": "DEB package source and build inputs", "files": []}
    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for name, p in sorted(payload.items()):
            data = p.read_bytes()
            if SECRET.search(data):
                raise RuntimeError("Credential marker found in " + name)
            z.writestr(prefix + "/" + name, data)
            manifest["files"].append({"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        z.writestr(prefix + "/DEB-SOURCE-MANIFEST.json", json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8"))
        z.writestr(prefix + "/DEB-SOURCE-SHA256SUMS.txt", "\n".join(x["sha256"] + "  " + x["path"] for x in manifest["files"]) + "\n")
    with zipfile.ZipFile(args.output) as z:
        assert z.testzip() is None
        for x in manifest["files"]:
            assert hashlib.sha256(z.read(prefix + "/" + x["path"])).hexdigest() == x["sha256"]
    digest = hashlib.file_digest(args.output.open("rb"), "sha256").hexdigest()
    print(json.dumps({"output": str(args.output.resolve()), "files": len(manifest["files"]), "bytes": args.output.stat().st_size, "sha256": digest}, ensure_ascii=False))

if __name__ == "__main__":
    main()
