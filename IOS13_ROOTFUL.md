# iPhone 11 / iOS 13.3 / unc0ver

This device uses a rootful jailbreak with Substitute and Cydia. Use the
`AppleLive-iOS13-rootful-deb` artifact from the `Build AppleLive iOS 13 rootful deb`
GitHub Actions workflow. The iOS 15 rootless package is not compatible.

1. In Cydia, verify that Substitute is installed and unc0ver reports jailbroken.
2. Transfer the rootful `.deb` to the iPhone and open it with Filza or a local
   package installer. Install the package through Cydia or Filza.
3. Create `/var/mobile/Library/Preferences/com.applelive.tweak.plist` with:

   ```plist
   {
       enabled = 1;
       server = "192.168.1.45:8765";
       audioEnabled = 0;
   }
   ```

   Replace the address with the current LAN IPv4 address of the Windows PC.
4. Start the OBS sender and reboot userspace, or reboot the phone and reapply
   the unc0ver jailbreak. Both devices must be on the same LAN.
5. Check whether the OBS script reports one iPhone connection. Test the Camera
   preview first, then Douyin and TikTok previews. Enable audio only after video
   works and OBS audio monitoring is configured.

This is an experimental build. Compilation and connection do not prove that
the camera hooks work in a particular iOS or live-app version. USB transport
is not implemented yet.
