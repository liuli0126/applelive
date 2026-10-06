#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sdk="${IPHONEOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
mkdir -p output
for arch in arm64 arm64e; do
  xcrun clang -arch "$arch" -isysroot "$sdk" -miphoneos-version-min=15.0 objects/"$arch"/*.o \
    -L../lib -luvc -lusb-1.0 -framework Foundation -framework CoreVideo -framework CoreGraphics \
    -framework ImageIO -framework IOKit -framework Security -o "output/host-$arch"
done
xcrun lipo -create output/host-arm64 output/host-arm64e -output output/AppleLiveUVCHost
ldid -SUSBHost.entitlements output/AppleLiveUVCHost
