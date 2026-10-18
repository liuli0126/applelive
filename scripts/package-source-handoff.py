"""Package current working-tree sources and current build prerequisites."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = [".github", "assets", "desktop_sender", "ios-injector", "ios-tweak", "ios-uvc-service", "native-obs-usb", "obs-plugin", "scripts", "docs"]
ROOT_FILES = [".gitignore", "README.md", "COMPATIBILITY.md", "GITHUB_BUILD.md", "IOS13_ROOTFUL.md", "VERSION_SUPPORT.md", "WINDOWS_WSL_BUILD.md"]
EXCLUDE_DIRS = {"__pycache__", ".theos", ".git", "build", "packages", ".venv", "node_modules"}
EXCLUDE_NAMES = {"_shutdown_baseline.py", ".env", "unicode-launch.json", "lan-access.ok"}
SECRET = re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)")
VERIFY_SCRIPT = r'''from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parent
manifest = json.loads((root / "SOURCE-MANIFEST.json").read_text(encoding="utf-8"))
errors = []
for entry in manifest["files"]:
    relative = Path(entry["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit("Unsafe manifest path")
    p = root / relative
    if not p.is_file():
        errors.append(entry["path"] + ": missing")
        continue
    with p.open("rb") as f:
        digest = hashlib.file_digest(f, "sha256").hexdigest()
    if digest != entry["sha256"] or p.stat().st_size != entry["bytes"]:
        errors.append(entry["path"] + ": mismatch")
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print("PASS: verified", len(manifest["files"]), "files")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        parser.error("date must be YYYY-MM-DD")
    prefix = "福煋项目源码交接-" + args.date.replace("-", "")
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    files = {}
    for dirname in SOURCE_DIRS:
        for p in (ROOT / dirname).rglob("*"):
            rel = p.relative_to(ROOT)
            if not p.is_file() or p.is_symlink() or any(part in EXCLUDE_DIRS for part in rel.parts):
                continue
            if p.name in EXCLUDE_NAMES or p.suffix in [".pyc", ".log", ".tmp", ".flag"]:
                continue
            if dirname == "obs-plugin" and p.name.startswith("applelive-") and p.suffix == ".json":
                continue
            files[rel.as_posix()] = p
    for name in ROOT_FILES:
        files[name] = ROOT / name
    generated = {
        "00-先读我.md": (ROOT / "docs/handoff/00-交接总览.md").read_bytes(),
        "verify-handoff.py": VERIFY_SCRIPT.encode("utf-8"),
    }
    manifest = {"date": args.date, "source": "current working tree including uncommitted files", "files": []}
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for rel in sorted(set(files) | set(generated)):
            data = generated[rel] if rel in generated else files[rel].read_bytes()
            if Path(rel).suffix.lower() in [".py", ".ps1", ".yml", ".yaml", ".json", ".md", ".txt", ".js", ".sh", ".cmd", ".h", ".m", ".xm", ".cpp"] and SECRET.search(data):
                raise RuntimeError("Credential marker found in " + rel)
            z.writestr(prefix + "/" + rel, data)
            manifest["files"].append({"path": rel, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        raw = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        z.writestr(prefix + "/SOURCE-MANIFEST.json", raw)
        sums = [entry["sha256"] + "  " + entry["path"] for entry in manifest["files"]]
        sums.append(hashlib.sha256(raw).hexdigest() + "  SOURCE-MANIFEST.json")
        z.writestr(prefix + "/SHA256SUMS.txt", "\n".join(sums) + "\n")
    with zipfile.ZipFile(output) as z:
        assert z.testzip() is None
        for entry in manifest["files"]:
            assert hashlib.sha256(z.read(prefix + "/" + entry["path"])).hexdigest() == entry["sha256"]
    with output.open("rb") as f:
        digest = hashlib.file_digest(f, "sha256").hexdigest()
    print(json.dumps({"output": str(output), "files": len(manifest["files"]), "bytes": output.stat().st_size, "sha256": digest}, ensure_ascii=False))


if __name__ == "__main__":
    main()
