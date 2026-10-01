#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sdk="${IPHONEOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
mkdir -p output
frameworks=(Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage CoreGraphics VideoToolbox AudioToolbox QuartzCore Photos PhotosUI UniformTypeIdentifiers Security ImageIO Network)
arguments=()
for framework in "${frameworks[@]}"; do arguments+=(-framework "$framework"); done
for arch in arm64 arm64e; do
  minimum=14.0
  if [ "$arch" = arm64e ]; then minimum=15.0; fi
  xcrun clang -arch "$arch" -isysroot "$sdk" -miphoneos-version-min="$minimum" -dynamiclib \
    -Wl,-install_name,@rpath/AppleLive.dylib objects/"$arch"/*.o -Llib \
    -lavformat -lavcodec -lswresample -lswscale -lavutil -lz -lbz2 -liconv -lobjc \
    "${arguments[@]}" -o "output/AppleLive-$arch.dylib"
done
xcrun lipo -create output/AppleLive-arm64.dylib output/AppleLive-arm64e.dylib -output output/AppleLive.dylib
ldid -S output/AppleLive.dylib
