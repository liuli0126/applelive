#!/bin/bash
# Build LGPL libusb and BSD libuvc from pinned upstream sources. The driver
# still requires the host process to have access to Apple's USB user clients.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD/.build/ios-uvc"
usb_rev=fcc81364ba41ccbd1cc220810071c80548a308b5
uvc_rev=047920bcdfb1dac42424c90de5cc77dfc9fba04d
mkdir -p "$root/source" "$root/include/IOKit/usb" "$root/include/libuvc" "$root/lib"
for entry in "libusb/libusb:$usb_rev:libusb" "libuvc/libuvc:$uvc_rev:libuvc"; do
  IFS=: read -r repository revision name <<< "$entry"
  if [ ! -f "$root/source/$name/.applelive-revision" ]; then
    curl --retry 3 -fsSL "https://api.github.com/repos/$repository/tarball/$revision" -o "$root/$name.tar.gz"
    mkdir -p "$root/source/$name"
    tar -xzf "$root/$name.tar.gz" --strip-components=1 -C "$root/source/$name"
    echo "$revision" > "$root/source/$name/.applelive-revision"
  fi
  test "$(cat "$root/source/$name/.applelive-revision")" = "$revision"
done
mac_headers="$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/IOKit.framework/Headers"
cp "$mac_headers/IOCFPlugIn.h" "$mac_headers/IOCFBundle.h" "$root/include/IOKit/"
cp "$mac_headers"/usb/*.h "$root/include/IOKit/usb/"
# iOS has no macOS authorization dialog. Never reset/capture another driver's
# device or detach its audio interface as part of video acquisition.
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
usb = root / 'source/libusb/libusb/os/darwin_usb.c'
s = usb.read_text()
s = s.replace('kresult = IOServiceAuthorize (dpriv->service, kIOServiceInteractionAllowed);',
              'kresult = kIOReturnUnsupported; /* AppleLive: no authorization dialog on iOS. */')
usb.write_text(s)
init = root / 'source/libuvc/src/init.c'
s = init.read_text()
if 'applelive_uvc_usb_context' not in s:
    s += '''
/* AppleLive diagnostic accessor. The context remains owned by libuvc. */
struct libusb_context *applelive_uvc_usb_context(uvc_context_t *ctx) {
  return ctx ? ctx->usb_ctx : NULL;
}
'''
init.write_text(s)
uvc = root / 'source/libuvc/src/device.c'
s = uvc.read_text().replace('ret = libusb_detach_kernel_driver(devh->usb_devh, idx);',
                           'ret = LIBUSB_ERROR_NOT_SUPPORTED; /* AppleLive: preserve iOS drivers. */')
s = s.replace('ret = libusb_attach_kernel_driver(devh->usb_devh, idx);',
              'ret = LIBUSB_SUCCESS; /* AppleLive: no driver was detached. */')
uvc.write_text(s)
PY
cat > "$root/include/config.h" <<'EOF'
#include <AvailabilityMacros.h>
#define DEFAULT_VISIBILITY __attribute__((visibility("hidden")))
#define ENABLE_LOGGING 1
#define HAVE_PTHREAD_THREADID_NP 1
#define HAVE_NFDS_T 1
#define HAVE_SYS_TIME_H 1
#define PLATFORM_POSIX 1
#define PRINTF_FORMAT(a,b) __attribute__((__format__(__printf__,a,b)))
#define _GNU_SOURCE 1
EOF
echo '#define LIBUSB_DESCRIBE "AppleLive iOS USB Host experiment"' > "$root/include/version_describe.h"
cat > "$root/include/libuvc/libuvc_config.h" <<'EOF'
#pragma once
#define LIBUVC_VERSION_MAJOR 0
#define LIBUVC_VERSION_MINOR 0
#define LIBUVC_VERSION_PATCH 7
#define LIBUVC_VERSION_STR "0.0.7"
#define LIBUVC_VERSION_INT 7
#define LIBUVC_VERSION_GTE(a,b,c) (LIBUVC_VERSION_INT >= (((a)<<16)|((b)<<8)|(c)))
/* AppleLive uses ImageIO for MJPEG decoding. */
EOF
cp "$root/source/libuvc/include/libuvc/libuvc.h" "$root/include/libuvc/"
cp "$root/source/libusb/libusb/libusb.h" "$root/include/"
sdk="${THEOS:?}/sdks/iPhoneOS16.5.sdk"
for arch in arm64 arm64e; do
  minimum=14.0
  if [ "$arch" = arm64e ]; then minimum=15.0; fi
  object_dir="$root/obj/$arch"
  mkdir -p "$object_dir/usb" "$object_dir/uvc"
  common=(-arch "$arch" -isysroot "$sdk" -miphoneos-version-min="$minimum" -O2 -fvisibility=hidden
          -include TargetConditionals.h -Wno-deprecated-declarations -Wno-nullability-completeness
          -I"$root/include" -I"$root/source/libusb/libusb" -I"$root/source/libuvc/include")
  for file in core descriptor hotplug io strerror sync os/darwin_usb os/events_posix os/threads_posix; do
    xcrun clang "${common[@]}" -c "$root/source/libusb/libusb/$file.c" -o "$object_dir/usb/$(basename "$file").o"
  done
  for file in ctrl ctrl-gen device diag frame init stream misc; do
    xcrun clang "${common[@]}" -c "$root/source/libuvc/src/$file.c" -o "$object_dir/uvc/$file.o"
  done
  xcrun ar rcs "$root/lib/libusb-$arch.a" "$object_dir/usb/"*.o
  xcrun ar rcs "$root/lib/libuvc-$arch.a" "$object_dir/uvc/"*.o
done
xcrun lipo -create "$root/lib/libusb-arm64.a" "$root/lib/libusb-arm64e.a" -output "$root/lib/libusb-1.0.a"
xcrun lipo -create "$root/lib/libuvc-arm64.a" "$root/lib/libuvc-arm64e.a" -output "$root/lib/libuvc.a"
cp "$root/source/libusb/COPYING" "$root/libusb-LICENSE.txt"
cp "$root/source/libuvc/LICENSE.txt" "$root/libuvc-LICENSE.txt"
printf 'libusb %s (LGPL-2.1-or-later)\nlibuvc %s (BSD-3-Clause)\nModified for iOS; source and relink objects included.\n' "$usb_rev" "$uvc_rev" > "$root/USBHost-NOTICE.txt"
