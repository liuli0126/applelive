# iPhone 11 / iOS 13.3 / unc0ver

This device uses a rootful jailbreak with Substitute and Cydia. Use the
`AppleLive-iOS13-rootful-deb` artifact from the `Build AppleLive iOS 13 rootful deb`
GitHub Actions workflow. The iOS 15 rootless package is not compatible.
AppleLive is a background camera tweak and does not create a Home Screen icon.

1. In Cydia, verify that Substitute is installed and unc0ver reports jailbroken.
2. Transfer version 0.1.4 of the rootful `.deb` to the iPhone and install it
   with Filza. The package includes an enabled configuration for
   USB `127.0.0.1:8765` and LAN `192.168.1.45:8765` addresses, and restarts
   the camera service after installation. USB is tried first, then LAN.
3. Start the OBS sender. The phone and PC must be on the same LAN. Close and
   reopen the Camera or live app after the package finishes installing.
4. Check whether the OBS script reports an iPhone connection. Test the Camera
   preview first, then Douyin and TikTok previews. The package accepts PC audio
   when OBS audio monitoring and the VB-CABLE capture device are configured;
   without PC audio packets it leaves the phone microphone in use.

For USB, install OpenSSH from Cydia, select USB in the OBS AppleLive script,
and click Start. A PowerShell window opens for the SSH password and must stay
open while streaming. If LAN was already connected, the tweak checks for USB
every five seconds and switches automatically. A device-specific key at
`%USERPROFILE%\.ssh\applelive-<UDID>` is used automatically after pairing.
On the test iPhone, OpenSSH 8.4-2 and USB WebSocket handshaking have been
verified. Camera replacement and audio still require a successful device test.

The iOS 13 build uses the legacy clang 10 arm64e compiler and iPhoneOS 13.7
SDK on Linux. Newer Xcode compilers emit the iOS 14 arm64e ABI even with a
13.0 deployment target. Version 0.1.3 contained that incompatible slice and
cannot load into the iPhone 11's iOS 13 system camera processes. The workflow
now checks both CPU subtypes and minimum OS versions before uploading a deb.

If the PC address changes, edit the installed file at
`/var/mobile/Library/Preferences/com.applelive.tweak.plist`. If the camera
service does not reload automatically, reboot the phone and reapply the
unc0ver jailbreak.

This is an experimental build. Compilation and connection do not prove that
the camera hooks work in a particular iOS or live-app version. Measure latency
and dropped frames on the target phone before using it for a live stream.
