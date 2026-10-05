# AppleLive single-file injector

The standalone library is imported into each target application with the user's injector. It links only Apple system frameworks; FFmpeg and fishhook are statically included. Install only one camera replacement in a target app at a time. An app update can require importing the library again.

## Sources and controls

- Album and Files import an image or video into the target app's own storage. Images retain a static frame; local videos always loop and support play/pause. There is no loop switch, and an old saved loop-off setting is discarded on upgrade.
- Detection is the LAN network entry. Paste a full RTMP or RTSP URL, for example `rtmp://192.168.1.45:1935/live/applelive`; the phone and computer must be on the same Wi-Fi.
- USB Direct is a separate entry. Select `USB 直连` in the phone panel, select `USB 数据线` in the OBS dock, connect and trust the iPhone, then start OBS. USB Direct uses the phone's loopback listener over usbmux and does not use Wi-Fi, OpenSSH, or the LAN RTMP/RTSP address.
- Existing `computer` sources migrate to Detection. Existing `usb` sources remain USB Direct so an update does not silently change the transport.
- Internal audio replaces microphone input with source sound. Silence is used when the source has no audio or the audio buffer underflows. Mute silences the injected audio. Turning off internal audio restores the app's microphone path.
- Mirror, rotation, fit/fill and Restore Camera apply to the selected source. The compact panel shows all controls on one screen without vertical scrolling. Internal audio is the only audio option; it replaces the microphone when enabled.

The phone panel uses an ice white/blue theme with soft rounded borders, native controls and a circular floating launcher. The `替换画面` switch applies to RTMP/RTSP streams, Album and Files. The launcher is transparent outside its disc, clips to a circle and only accepts touches inside that circle.

## Build And Relink

The arm64 slice targets iOS 14; the modern arm64e slice targets iOS 15. These are deployment targets, not a promise that every iOS release has a working injection environment. Each OS/app combination needs a device test.

FFmpeg n6.1.2 commit b1a4534186ca51b0457579fc05a5739eb2cc45cd is built without GPL or nonfree components. fishhook commit aadc161ac3b80db07a9908851839a17ba63a9eb1 is used under its BSD license. Their licenses accompany the binary.

The CI artifact includes `AppleLive-relink.tar.gz`: application object files for each architecture, FFmpeg static libraries and headers, corresponding FFmpeg source, fishhook source, this project's source and a relink script. This allows replacing the LGPL media libraries and producing a modified dylib. On a Mac with an iPhoneOS SDK and ldid, unpack it, replace the libraries in `lib`, then run `bash relink-injector.sh`. To rebuild the media libraries, use the included source and build script. The ordinary phone user only imports `AppleLive.dylib`.

## Verification

CI runs source migration, RTMP/RTSP video and audio, playback, pause, seeking, looping, cancellation, PCM layout and microphone-underflow silence tests, then verifies architectures, deployment versions and absence of external injection framework dependencies. Real-device video and audio results are recorded separately; a compiled binary does not demonstrate app compatibility.
