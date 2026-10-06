# Native USB output

This module registers an independent encoded output with OBS 30.2.3. Preparing
USB starts H.264 baseline / AAC-LC encoders using the current OBS composition and
audio mix. OBS's streaming service is not started or reconfigured.

The output connects to the local relay on 28765. The relay asks the Apple Mobile
Device service on 27015 for a USB device and tunnels to the phone's listener on
8766. The phone sends `ALUSB1\r\n`; only after receiving this greeting does the
relay acknowledge the output. Video starts on an SPS/PPS + IDR access unit.

Each packet has a big-endian uint32 payload length. Video payloads contain
`fram`, four little-endian uint32 fields (sequence, flags, width, height), and
one Annex-B access unit. Flag 1 is IDR; flag 2 promises complete access units and
one sequence increment per video frame. AAC config (`aacd`) and AAC packets
(`aaca`) contain little-endian sample-rate/channel-count fields followed by the
ASC or raw AAC packet. Audio packets cannot open the video keyframe gate.

Queue overflow drops the pending queue, resets audio configuration, and waits
for another keyframe. The socket worker owns its socket and retries connection;
encoder callbacks copy borrowed packet data without blocking on network I/O.
The receiver rebuilds VideoToolbox after sequence gaps, parameter changes, or
decode errors. AAC decoder lifetime is serialized with stream teardown.

`applelive_obs_api.h` is a minimal ABI declaration pinned to the official
`libobs/obs.h`, `obs-output.h`, `obs-encoder.h`, `obs-module.h`, and `obs-config.h`
at OBS Studio tag **30.2.3**. The output module exports that API version. Do not
assume arbitrary OBS versions are compatible merely because imports resolve.

## Validation

Build in Visual Studio Developer PowerShell:

```powershell
./scripts/build-native-windows.ps1 -ObsRoot 'PATH_TO_OBS'
python native-obs-usb/tests/relay_test.py
python native-obs-usb/tests/obs_host.py 'PATH_TO_OBS' '.build/usb-regression'
```

The relay test executes the actual EXE against XML and binary usbmux fixtures,
verifies byte-exact forwarding, USB device selection, handshake rejection,
connection-result rejection, Unicode status paths, and reconnects. The host
test loads the actual DLL in real libobs, renders a video/audio fixture, checks
three reconnects and start/stop, and records the resulting packets. It uses
separate loopback ports and does not manipulate an existing OBS process.

The iOS injector workflow decodes recorded native output and multi-slice H.264
through the shared phone decoder on macOS. It tests sequence gaps, concurrent
AAC teardown, malformed short packets, and reconnects. A successful host test
does not establish stability inside a particular iOS app: iPhone 11 / iOS 15.6
/ Douyin remains the physical-device acceptance target.
