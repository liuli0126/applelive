#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD/.build/uvc-service"
uvc="$PWD/.build/ios-uvc"
sdk="${THEOS:?}/sdks/iPhoneOS16.5.sdk"
mkdir -p "$root/objects" "$root/bin" "$root/package/DEBIAN"
for arch in arm64 arm64e; do
  mkdir -p "$root/objects/$arch"
  common=(-arch "$arch" -isysroot "$sdk" -miphoneos-version-min=15.0 -fobjc-arc -O2
          -Iios-injector -Iios-uvc-service -I"$uvc/include")
  for file in ios-uvc-service/main.m ios-uvc-service/ALUVCHostServer.m ios-injector/ALExternalCamera.m ios-injector/ALUVCFrame.m ios-injector/ALUVCWire.m; do
    xcrun clang "${common[@]}" -c "$file" -o "$root/objects/$arch/$(basename "${file%.m}").o"
  done
  xcrun clang "${common[@]}" "$root/objects/$arch/"*.o -L"$uvc/lib" -luvc -lusb-1.0 \
    -framework Foundation -framework CoreVideo -framework CoreGraphics -framework ImageIO -framework IOKit -framework Security \
    -o "$root/bin/host-$arch"
  xcrun clang "${common[@]}" ios-uvc-service/ServiceApp.m -framework UIKit -framework Foundation -o "$root/bin/setup-$arch"
done
xcrun lipo -create "$root/bin/host-arm64" "$root/bin/host-arm64e" -output "$root/bin/AppleLiveUVCHost"
xcrun lipo -create "$root/bin/setup-arm64" "$root/bin/setup-arm64e" -output "$root/bin/AppleLiveUSB"
ldid -Sios-uvc-service/USBHost.entitlements "$root/bin/AppleLiveUVCHost"
ldid -Sios-uvc-service/Setup.entitlements "$root/bin/AppleLiveUSB"
for binary in AppleLiveUVCHost AppleLiveUSB; do
  entitlement=USBHost
  if [ "$binary" = AppleLiveUSB ]; then entitlement=Setup; fi
  for arch in arm64 arm64e; do
    # ldid -e on a fat binary concatenates XML documents; validate each slice.
    xcrun lipo "$root/bin/$binary" -thin "$arch" -output "$root/bin/check-$binary-$arch"
    ldid -e "$root/bin/check-$binary-$arch" > "$root/$binary-$arch-entitlements.plist"
    python3 - "$root/$binary-$arch-entitlements.plist" "ios-uvc-service/$entitlement.entitlements" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: actual=plistlib.load(f)
with open(sys.argv[2],'rb') as f: expected=plistlib.load(f)
assert actual == expected, 'Signed executable entitlements differ'
print('Verified signed entitlements:', sys.argv[1])
PY
  done
done
package="$root/package"
mkdir -p "$package/var/jb/usr/libexec" "$package/var/jb/Applications/AppleLiveUSB.app" \
  "$package/var/jb/Library/LaunchDaemons" "$package/var/jb/Library/AppleLive"
cp "$root/bin/AppleLiveUVCHost" "$package/var/jb/usr/libexec/"
cp "$root/bin/AppleLiveUSB" "$package/var/jb/Applications/AppleLiveUSB.app/"
cp injector-artifact/AppleLive.dylib "$package/var/jb/Library/AppleLive/"
cp ios-uvc-service/com.applelive.uvchost.plist "$package/var/jb/Library/LaunchDaemons/"
cp ios-uvc-service/control ios-uvc-service/postinst ios-uvc-service/prerm ios-uvc-service/postrm "$package/DEBIAN/"
mkdir -p "$package/var/jb/usr/share/doc/com.applelive.uvchost"
cp injector-artifact/*-LICENSE.txt injector-artifact/USBHost-NOTICE.txt "$package/var/jb/usr/share/doc/com.applelive.uvchost/"
cat > "$package/var/jb/usr/share/doc/com.applelive.uvchost/SOURCE.txt" <<'EOF'
AppleLive sources: https://github.com/liuli0126/applelive
The matching complete sources, LGPL relink objects and relink scripts are distributed
alongside this package as AppleLive-relink.tar.gz in the phone open-source components folder.
Keep that archive and the license notices when redistributing this package.
EOF
python3 - "$package/var/jb/Applications/AppleLiveUSB.app/Info.plist" <<'PY'
import plistlib,sys
info={'CFBundleIdentifier':'com.applelive.usbsetup','CFBundleExecutable':'AppleLiveUSB',
      'CFBundleName':'AppleLive USB','CFBundleDisplayName':'AppleLive USB',
      'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1.0',
      'MinimumOSVersion':'15.0','LSRequiresIPhoneOS':True,'UIDeviceFamily':[1,2],
      'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait',
      'UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']}
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
PY
find "$package" -type d -exec chmod 755 '{}' \;
find "$package" -type f -exec chmod 644 '{}' \;
chmod 755 "$package/DEBIAN/postinst" "$package/DEBIAN/prerm" "$package/DEBIAN/postrm" \
  "$package/var/jb/usr/libexec/AppleLiveUVCHost" "$package/var/jb/Applications/AppleLiveUSB.app/AppleLiveUSB"
dpkg-deb --root-owner-group --build "$package" injector-artifact/AppleLive-UVC-Service-rootless.deb
mkdir -p relink/uvc-service
cp -R "$root/objects" relink/uvc-service/
cp ios-uvc-service/USBHost.entitlements relink/uvc-service/
cp scripts/relink-uvc-service.sh relink/uvc-service/
(cd relink/uvc-service && bash relink-uvc-service.sh)
tar -czf injector-artifact/AppleLive-relink.tar.gz relink
