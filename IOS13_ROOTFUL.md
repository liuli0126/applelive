# iPhone 11 / iOS 13.3 / unc0ver

This device uses a rootful jailbreak with Substitute and Cydia. Use the
`AppleLive-iOS13-rootful-deb` artifact from the `Build AppleLive iOS 13 rootful deb`
GitHub Actions workflow. The iOS 15 rootless package is not compatible.
AppleLive is a background camera tweak and does not create a Home Screen icon.

1. In Cydia, verify that Substitute is installed and unc0ver reports jailbroken.
2. Transfer version 0.1.1 of the rootful `.deb` to the iPhone and install it
   with Filza. The package includes an enabled video-only configuration for
   `192.168.1.45:8765` and restarts the camera service after installation.
3. Start the OBS sender. The phone and PC must be on the same LAN. Close and
   reopen the Camera or live app after the package finishes installing.
4. Check whether the OBS script reports an iPhone connection. Test the Camera
   preview first, then Douyin and TikTok previews. Enable audio only after video
   works and OBS audio monitoring is configured.

If the PC address changes, edit the installed file at
`/var/mobile/Library/Preferences/com.applelive.tweak.plist`. If the camera
service does not reload automatically, reboot the phone and reapply the
unc0ver jailbreak.

This is an experimental build. Compilation and connection do not prove that
the camera hooks work in a particular iOS or live-app version. USB transport
is not implemented yet.
