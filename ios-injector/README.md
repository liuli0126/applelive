# AppleLive single-file injector

The standalone library is imported into each target application with the user's injector. It links only Apple system frameworks; FFmpeg and fishhook are statically included. Install only one camera replacement in a target app at a time. An app update can require importing the library again.

## Sources and controls

- Album and Files import an image or video into the target app's own storage. Images retain a static frame; videos support play/pause, seek and looping.
- Detection opens the standard network stream address. RTMP/RTMPS, RTSP over TCP and HTTP/HTTPS media/HLS inputs are supported by the configured media engine. It accepts SRS and MediaMTX stream URLs.
- Computer connects the existing AppleLive LAN sender or the USB app listener. The OBS side chooses LAN or USB; the phone displays the actual transport.
- Internal audio replaces microphone input with source sound. Silence is used when the source has no audio or the audio buffer underflows. Mute silences the injected audio. Turning off internal audio restores the app's microphone path.
- Mirror, rotation, fit/fill, independent preview and Restore Camera apply to the selected source. Settings belong to the injected app.

USB requires the Apple USB device driver and device trust on Windows. The standalone app listener uses usbmux port 8766 and does not require OpenSSH. The legacy deb's SSH route remains available for older deployments.

## Build And Relink

The arm64 slice targets iOS 14; the modern arm64e slice targets iOS 15. These are deployment targets, not a promise that every iOS release has a working injection environment. Each OS/app combination needs a device test.

FFmpeg n6.1.2 commit b1a4534186ca51b0457579fc05a5739eb2cc45cd is built without GPL or nonfree components. fishhook commit aadc161ac3b80db07a9908851839a17ba63a9eb1 is used under its BSD license. Their licenses accompany the binary.

The CI artifact includes `AppleLive-relink.tar.gz`: application object files for each architecture, FFmpeg static libraries and headers, corresponding FFmpeg source, fishhook source, this project's source and a relink script. This allows replacing the LGPL media libraries and producing a modified dylib. On a Mac with an iPhoneOS SDK and ldid, unpack it, replace the libraries in `lib`, then run `bash relink-injector.sh`. To rebuild the media libraries, use the included source and build script. The ordinary phone user only imports `AppleLive.dylib`.

## Verification

CI runs playback, pause, seeking, looping, cancellation, PCM layout and microphone-underflow silence tests, then verifies architectures, deployment versions and absence of external injection framework dependencies. Real-device video, audio, preview and USB results are recorded separately; a compiled binary does not demonstrate app compatibility.
