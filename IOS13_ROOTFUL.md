# iPhone 11 / iOS 13.3 / unc0ver

This device uses a rootful jailbreak with Substitute and Cydia. Use the
`AppleLive-iOS13-rootful-deb` artifact from the `Build AppleLive iOS 13 rootful deb`
GitHub Actions workflow. The iOS 15 rootless package is not compatible.
AppleLive is a background camera tweak and does not create a Home Screen icon.

1. In Cydia, verify that Substitute is installed and unc0ver reports jailbroken.
2. Transfer version 0.1.6 of the rootful `.deb` to the iPhone and install it
   with Filza. The package includes an enabled configuration for
   USB `127.0.0.1:8765` and LAN `192.168.1.45:8765` addresses, and restarts
   the camera service after installation. USB is tried first, then LAN.
3. Start the OBS sender using either the USB tunnel or the same LAN. Close
   and reopen the Camera or live app after the package finishes installing.
4. Check whether the OBS script reports an iPhone connection. Test the Camera
   preview first, then Douyin and TikTok previews. The package accepts PC audio
   when OBS audio monitoring and the VB-CABLE capture device are configured;
   without PC audio packets it leaves the phone microphone in use.

For USB, install OpenSSH from Cydia, select USB in the OBS AppleLive script,
and click Start. A PowerShell window opens for the SSH password and must stay
open while streaming. If LAN was already connected, the tweak checks for USB
every five seconds and switches automatically. A device-specific key at
`%USERPROFILE%\.ssh\applelive-<UDID>` is used automatically after pairing.
On the test iPhone, OpenSSH 8.4-2, USB video reception, decoding and stock Camera
preview replacement have been verified. On 0.1.5, the user confirmed Douyin's
direction was correct while stock Camera was upside down. Version 0.1.6 uses
separate app defaults and adds a floating control button in Camera, Douyin and
TikTok. PC audio, TikTok, other camera orientations and end-to-end latency still
need device tests.

Tap the floating video button to enable/disable replacement, rotate left/right,
mirror, choose fit/fill, or enable PC audio. Drag the button to move it; collapse
the panel to keep using the host app. Controls and button position are saved in
each app's own preferences. The foreground app sends its settings to the camera
service through Darwin notifications, avoiding writes outside the app sandbox.
The status label reports recent video/audio reception from the camera service.
PC audio still requires OBS monitoring and audio sending on the desktop.

The iOS 13 build uses the legacy clang 10 arm64e compiler and iPhoneOS 13.7
SDK on Linux. Newer Xcode compilers emit the iOS 14 arm64e ABI even with a
13.0 deployment target. Version 0.1.3 contained that incompatible slice and
cannot load into the iPhone 11's iOS 13 system camera processes. The workflow
now checks both CPU subtypes and minimum OS versions before uploading a deb.

iOS 13's `BWNodeOutput` uses `emitSampleBuffer:` and does not expose the earlier
assumed `copyNextSampleBuffer` accessor. The push hook validates its runtime
signature and renders into the existing supported video buffer, keeping its
dimensions, timing and attachments. Sampled device logs distinguish received,
decoded and rendered frames from a mere WebSocket connection.

If the PC address changes, edit the installed file at
`/var/mobile/Library/Preferences/com.applelive.tweak.plist`. If the camera
service does not reload automatically, reboot the phone and reapply the
unc0ver jailbreak.

This is an experimental build. Compilation and connection do not prove that
the camera hooks work in a particular iOS or live-app version. Measure latency
and dropped frames on the target phone before using it for a live stream.
