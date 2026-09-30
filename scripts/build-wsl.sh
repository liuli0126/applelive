#!/usr/bin/env bash
set -euo pipefail

# Build the rootless deb from WSL2 Ubuntu. Public Theos/SDK repositories do
# not require a GitHub account. Run this script from the repository root.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS_DIR="${THEOS:-$HOME/theos}"

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script must run inside WSL2 Ubuntu or Debian." >&2
  exit 1
fi

if ! command -v clang >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y clang make perl git curl dpkg fakeroot
fi

if [ ! -d "$THEOS_DIR/makefiles" ]; then
  git clone --depth 1 --recursive https://github.com/theos/theos.git "$THEOS_DIR"
fi

if [ ! -d "$THEOS_DIR/sdks" ]; then
  git clone --depth 1 https://github.com/theos/sdks.git "$THEOS_DIR/sdks"
fi

if ! command -v ldid >/dev/null 2>&1 && [ ! -x "$THEOS_DIR/bin/ldid" ]; then
  cat >&2 <<'EOF'
ldid is missing. Install a Linux ldid package or put ldid in PATH, then run again.
Theos uses ldid to sign the rootless dynamic library; no Apple certificate is needed.
EOF
  exit 1
fi

export THEOS="$THEOS_DIR"
cd "$ROOT_DIR"
make -C ios-tweak package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
echo "Build complete. Package files are in ios-tweak/packages/."
