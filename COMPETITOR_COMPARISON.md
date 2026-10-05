# Portable OBS comparison

The supplied reference tree is a portable OBS distribution. Its important behavior comes from how the media path is built, not from the folder name:

| Area | Reference distribution | AppleLive before this change | Effect |
|---|---|---|---|
| OBS integration | Native DLLs are loaded from `obs-plugins/64bit`. The USB DLL imports OBS output/encoder APIs and registers an OBS dock. | Lua + browser dock + separate `AppleLiveDock.exe` and `AppleLiveSender.exe`. | More startup dependencies and more places for state to get out of sync. |
| USB video/audio | OBS encodes H.264/AAC directly. A non-blocking native output feeds a small relay process. Strings in the DLL explicitly mention keyframe gating, queue overflow handling, and keeping OBS capture alive when the relay stalls. | The USB path now reads OBS's loopback RTMP output through MediaMTX, FFmpeg remuxes/decodes it, and Python forwards packets through usbmux. | This removes virtual camera/audio device discovery and should eliminate that class of flowered frames; it still has an FFmpeg/Python hop and is not yet identical to the native output path. |
| USB relay | Native `VcamTang_OBS_USB_Relay_Douyin.exe`, with fixed per-app local ports in `vcamtang-direct-ports.ini` (`28765` for Douyin). | PyInstaller/Python sender plus `pymobiledevice3`. | The reference has fewer runtime components and no Python startup/import path in the hot media loop. |
| LAN server | SRS/MediaMTX binaries are inside the OBS tree and started by an OBS plugin. | MediaMTX is bundled beside the helper and started by the Python control service. USB now also uses it on loopback so OBS has one encoded source for both modes. | The reference controls port ownership from inside OBS; AppleLive still has one helper process to coordinate. |
| Drivers | Apple Mobile Device Support/filter and optional VB-Cable installers are included with explicit admin BAT/PowerShell setup. | AppleLive expects an already working Apple/usbmux driver; audio capture is discovered at runtime. | A clean customer PC can fail before the plugin code is reached. |
| Delivery | One extracted OBS directory with portable mode, prebuilt configuration, servers, relays and drivers. | A plugin ZIP that is installed into an existing OBS directory. | Users can accidentally mix old binaries, old config and new helpers. |

The reference tree also contains licensing/launcher code and several unrelated AI plugins. Those binaries are not copied or reused. The observations above come from PE imports, exported OBS module entry points, bundled configuration and installer scripts.

## Changes made

`scripts/build-portable-obs.ps1` now creates a clean full-folder package from an operator-provided OBS root. It copies OBS into a staging directory, embeds the current AppleLive package under `data/obs-plugins/AppleLive`, writes `portable_mode.txt`, registers the dock/WebSocket configuration and creates `AppleLive-Launcher.cmd`. The source OBS installation is never modified.

`obs-plugin/install_or_update.ps1` now has an `-Embedded` mode and recognizes custom renamed OBS launchers. Runtime logs and stale USB flags are removed from an embedded update.

## Remaining architecture gap

The portable package and loopback bridge fix delivery, version mixing, and the virtual-device dependency. AppleLive still differs from the reference in one architectural point: the reference uses a native OBS output module and relay, while AppleLive's USB path has an FFmpeg/Python hop. To reach the same stability, the next USB implementation must be a native OBS output module that consumes OBS encoded packets, queues only complete H.264/AAC access units, gates a new client on a keyframe, and hands packets to a small native usbmux relay.

## Static evidence from the supplied reference

- `obs-plugins/64bit/64bit/vcamtang-obs-usb.dll` imports `obs_output_create`, `obs_output_begin_data_capture`, `obs_video_encoder_create`, `obs_audio_encoder_create`, `obs_encoder_packet_release`, and `obs_parse_avc_packet`; it also imports Winsock `listen/accept/send` and Qt `QProcess`.
- Its embedded log strings say `non-blocking output active`, `clean H.264 keyframe queued`, `USB queue overflow`, and `USB relay stalled or disconnected; OBS capture kept running`. These mechanisms prevent a slow phone from blocking OBS or joining in the middle of a GOP.
- `bin/vcamtang-usb/VcamTang_OBS_USB_Relay_Douyin.exe` imports Winsock client calls and contains the Apple usbmux `ListDevices`/`Connect` plist, with `ConnectionType=USB`. The DLL listens on loopback and the relay connects to its configured port (`28765` for Douyin in `vcamtang-direct-ports.ini`).
- `tools/driver-installer/install.ps1` installs or repairs Apple Mobile Device Support, binds the signed Apple USB INF with `pnputil`, restarts Apple Mobile Device Service, verifies usbmux port `27015`, then installs the optional HD Camera and VB-Cable packages. The drivers are setup dependencies; they are not in the media hot path.
- The reference bundles both MediaMTX and SRS, but its MediaMTX runtime config enables RTMP on `:1935`, RTSP/TCP on `:8554`, and a local API. This is the standard LAN path. SRS is an additional server option rather than evidence that USB uses RTSP.
