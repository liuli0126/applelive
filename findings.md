# Findings

## 2026-10-05 current USB direct-mode gap
- The no-SSH transport already exists: `desktop_sender/usb_direct.py` discovers trusted USB devices with `pymobiledevice3`, connects through usbmux to phone TCP 8766, checks `ALUSB1\r\n`, and sends length-prefixed legacy media packets.
- `ios-injector/ALUSBReceiver.m` already listens only on phone loopback TCP 8766 and parses those framed packets. This avoids OpenSSH and an exposed LAN listener.
- The current OBS dock controls only OBS RTMP publishing and MediaMTX. Its installer removes `AppleLiveSender.exe` and `usb_forward.ps1`, so a fresh/current installation cannot start the retained USB transport.
- `ALMigrateMediaSource` currently converts a saved `usb` source to `network`, and the current phone panel exposes only RTMP/RTSP Detection. USB must be restored as a distinct source and must not require a stream URL.
- USB should use the existing raw H.264/float32 PCM packet protocol and sender rather than tunnel RTMP/RTSP. LAN remains RTMP/RTSP through MediaMTX.
- Selected desktop architecture: in USB mode OBS publishes its normal H.264/AAC program output to MediaMTX on `127.0.0.1`; the packaged sender reads that local stream, copies Annex-B H.264, decodes AAC to float PCM, and forwards packets over usbmux. The phone never uses Wi-Fi for this mode.
- This local-stream bridge preserves OBS mixed audio and avoids requiring OBS Virtual Camera, VB-CABLE, OpenSSH or a user-selected audio device.
- The dock can infer configured mode from the OBS stream server: loopback means USB, a selected non-loopback address means LAN. Runtime USB status comes from the sender status file and reports cable discovery separately from frame production.

## 2026-10-04 飞书教程事实基线
- 电脑端当前交付版本为 v0.2.5，局域网链路为 OBS -> RTMP 发布 -> 内置 MediaMTX 1.18.1 -> 手机 RTMP/RTSP 拉流。
- 默认完整地址为 `rtmp://电脑IP:1935/live/applelive` 与 `rtsp://电脑IP:8554/live/applelive`；`127.0.0.1:18765` 仅为电脑本机 OBS 停靠窗口。
- 当前独立 `AppleLive.dylib` 的 arm64 slice 最低 iOS 14，arm64e slice 最低 iOS 15；不能用于 iOS 13.3。
- iOS 13.3 / unc0ver + Substitute 使用专用 rootful v0.1.11 deb，走旧的 8765 WebSocket 通道，不能与当前只使用 RTMP/RTSP 的独立 dylib 流程混写。
- 文档需要区分“已实机验证”“构建/自动测试通过”“待实机验证”，避免承诺所有 iOS/机型可用。

## OBS local RTMP publish and phone RTSP pull (2026-10-03)
- The new desktop workflow does not use OBS Virtual Camera or the old WebSocket sender. OBS publishes `rtmp://<computer LAN IP>:1935/live` with key `applelive`; MediaMTX exposes the same stream to the phone at `rtsp://<computer LAN IP>:8554/live/applelive`.
- The dock controls OBS through its bundled WebSocket 5 server; it reads local port/password configuration and authenticates without asking users to type a password. Another computer needs Windows x64 OBS 28+ with the server enabled, the complete ZIP, and firewall permission for TCP 1935/8554.
- Desktop FFprobe confirmed H.264 1080x1920 and AAC over the exact LAN RTSP address. This does not establish real iPhone app playback or latency; those require device testing.
- OBS custom build crashed in Lua timer/frontend access during development. The final Lua script only launches the helper, and the tested OBS process remains running with no active stream.

## Single-screen mobile panel (2026-10-03)
- User requested three UI changes: remove the Preview button, show the whole panel without vertical scrolling, and keep only Internal Audio without a Mute switch.
- `9b8874a` removes the preview action and preview controller, removes the Mute control, forces standalone saved mute state to `NO`, removes the `UIScrollView`, and compresses the sections into one panel. The successful CI run `37089891485` passed the existing source, media, RTMP/RTSP, architecture and dependency checks.
- `3b1f6fa` further places Restore Camera beside Pause and places the time readout beside the timeline. Its CI run `37090276595` and one retry were not started because GitHub reports failed account payments/spending limit. The delivery therefore uses the last successful `9b8874a` artifact, which already contains the three requested removals and single-screen layout; the source has the additional pending spacing refinement.
- The only phone binary in `交付文件` is now the successful artifact SHA256 `3CA99F68D7705BFB7539DC3FF15398143DD90779897F42179AAC4365ADD08604`. Binary scan confirms no Preview, Mute or UIScrollView strings. Delivery and ZIP timestamps were set to local `2026-10-03 10:40:31` so Explorer shows the replacement time.

## Mandatory local video looping (2026-10-02)
- User requested removing the loop switch entirely: videos imported through Album or Files must always repeat. Local images remain still; network streaming, USB, pause and seeking keep their existing behavior.
- `586e9b1` removes the loop UI, mutable player flag and camera setter. The player now always rewinds local videos at EOF, reopening on seek failure. Migration drops obsolete loop preferences, including saved `NO` values.
- CI `37003673977` passed both device architectures, old-settings migration, repeated automatic EOF wraps with continuing frame output, pause/seek/cancellation/PCM and RTMP/RTSP integration. The existing HTML preview and PNG were updated in place. Physical phone validation remains outstanding.

## Mobile UI and LAN source correction (2026-10-02)
- User clarified the phone dylib must also remove the old Computer connection UI. Standalone LAN now uses Detection URLs only; RTSP and USB remain supported. Legacy deb behavior is outside this change.
- Applied ui-ux-pro-max guidance to a native UIKit black/red theme: restrained cut-corner edges, consistent SF Symbols, 48pt buttons, readable dark text colors and a circular transparent launcher with circular hit testing.
- Injector CI `37000248401` at `286bcef` passed source migration, no legacy LAN addresses, playback/pause/seek/loop/PCM, RTMP (8 frames / 31744 audio samples), RTSP (6 frames / 38912 audio samples), arm64/arm64e builds and dependency/relink checks. Actual phone appearance and injected-app compatibility remain untested for this revision.

## OBS address display clarification (2026-10-02)
- Delivery folder originally mixed two extracted directories, old and RTMP-only ZIPs, and an obsolete phone dylib. The only validated ZIP has SHA256 `54ECDBBB4CAB4576DB90F5F7D0CB2DE6BC428B602FE02302922BAF8CD5E667E8`.
- Latest screenshot singles out the dock card labeled `手机连接地址 · WebSocket` with `192.168.1.45:8765`.
- User wants only that card removed. RTMP, RTSP, and transport behavior must remain as in `0a7ecca`; `b4676db` is an over-broad transport change to reverse.
- UI skill's focused search found no directly applicable rule for duplicate connection-address display, so preserve the existing layout and controls apart from the requested card.
- The installed custom OBS directory had the exact `0a7ecca` dock files and `rtsp: true`; only its `index.html` and `app.js` were patched. The active loopback dock endpoint still serves the stale `交付文件/AppleLive-OBS-Windows` page despite those installed files, so visible confirmation requires the user's normal OBS/old-helper restart rather than force-stopping their processes.

## Tested reference feature scope (2026-10-01)
- Vacm SHA256d718f235c05b50aae52218959c8e0946c1cc9213caf5e33bd26d833add1f0b7c. Defines avformat_open_input, av_read_frame, avcodec_send_packet, avcodec_receive_frame, swr_convert, sws_scale and RTMP protocol objects; also has VideoToolbox imports. Local media, preview and audio features are supported by concrete selectors and linked AV classes.
- Key extra hooks: vcam_startRunning/stopRunning/addInput, vcam_addSublayer, vcam_setSession, vcam_installOverlayIfNeeded, vcam_setSampleBufferDelegate, vcam_setAudioSampleBufferDelegate and vcam_jpegStillImageNSDataRepresentation. Partial class/string obfuscation prevents exact UI text recovery, so user screenshots are requested.
- Build FFmpeg from an official pinned release in CI, static linking to avoid extra phone files. Preserve public source/license and relinking material. No third-party plugin implementation is copied or loaded during analysis.

## Single-file connection profile and OBS download (2026-10-01)
- Preserve the signed Mach-O bytes and encode IPv4/port in the exported filename. Standalone initialization locates its own image with dladdr using a data anchor; accepts Safari numeric duplicate suffixes and validates the address with the existing parser. A changed exported profile updates app-owned defaults; the same profile retains manual settings.
- Standalone connection controls now notify inside the target app instead of depending on mediaserverd. LAN HTTP downloads share the sender's port but remain separate from video handshakes; USB mode rejects the download endpoint. The dock's control API remains loopback-only with its existing Origin/token checks.
- QR generation uses qrcode/Pillow in the CI-built executable. Local protocol, ten dock tests, three transport handshakes and two phone-download tests passed. Positive QR rendering is deferred to CI because qrcode is not installed locally.
- Installed CI executable verified positive QR rendering and scanning without adding local development dependencies. Actual LAN library download and browser save match the signed artifact hash; narrower280px and normal560px layouts have no horizontal overflow. Existing OBS settings were preserved during the update.

## Injector delivery target (2026-10-01)
- User explicitly wants a single dylib imported through the existing injector for deployment across many phones. Actual app: wiki.qaq.TrollFools / version9.999 / build42, display name "虚拟相机注入器"; bundle at /var/containers/Bundle/Application/FF09809E-E662-441D-9BA7-FA1FF24A5FE8/TrollFools.app. It includes CydiaSubstrate.framework.zip and document types for Mach-O/ZIP/deb; UIFileSharingEnabled is true.
- The existing phone's Douyin contains Vacm_afasds_v10(1).dylib. Do not overwrite or eject that plugin without a concrete need and user authorization. Running two camera replacement plugins can affect the verification result.
- Public Lessica/TrollFools main supports preprocess of .dylib/.framework/.bundle and archives, and an inject CLI using a bundle ID and --path. The installed9.999 fork is not assumed to have the same CLI until confirmed. Reference: https://github.com/Lessica/TrollFools/blob/main/TrollFools/CLI/CmdInject.swift .
- Standalone delivery must avoid @rpath/CydiaSubstrate hard dependencies and mediaserverd-only status. A successful Dopamine package test is not proof of standalone app injection compatibility.

## Verified iOS15.6 environment and setup limitation (2026-10-01)
- Actual device: iPhone12,1 / iOS15.6 /19G71, /var/jb -> Dopamine preboot procursus, dpkg iphoneos-arm64. Initially no ElleKit; installed official ElleKit1.2 (331444bytes, SHA256e21dc91bdc1be193dc915daecfff45256239b4fe583a36861e662ab1f43906dc) and AppleLive0.1.12. The rootless framework compatibility symlink now resolves to /var/jb/usr/lib/libellekit.dylib.
- Rootless SSH users' home directories are under /var/jb/var/, so keys placed in /var/mobile or /var/root do not authenticate. Dedicated key/pin applelive-ssh-f6d0b440ebedafe9 works for both mobile and root using the correct account homes.
- Official Dopamine2.x DOEnvironmentManager rebootUserspace invokes /var/jb/basebin/jbctl reboot_userspace. Verified process restart and key reconnection after using that command.
- mediaserverd persisted AppleLive.Connection.v1 with host0.0.0.0 after install, proving constructor/connection code runs, but direct legacy preference import failed in its sandbox. App/service notifications take priority over the legacy file. Updating raw prefs alone therefore does not reliably fix active connections; publish through ALConnection's existing notification path instead.
- Downloaded and structurally parsed installed filter and Douyin Info.plist: filter is correct; app bundle is com.ss.iphone.ugc.Aweme, version39.9.0. Desktop's sole current client is192.168.1.53; cannot claim the new phone192.168.1.28 connected yet.

## Dopamine package manager recovery (2026-10-01)
- The latest settings screenshot contains Refresh Jailbreak Apps, so the earlier inference of a1.x-only settings menu was incorrect. Official2.x DOPkgManagerPickerViewController calls reinstallPackageManagers and pops back to settings; returning there after Continue alone does not prove success. DOEnvironmentManager refreshJailbreakApps runs rootless uicache -a.
- User confirmed Sileo became searchable and opened after Refresh Jailbreak Apps. The package-manager recovery issue is resolved; new-phone SSH installation and current network address are pending.
- The supplied older-UI screenshot displayed "越狱" and disabled restart actions, so the phone was not actively jailbroken at that moment. After completing the flow the user reported "已越狱" and missing Sileo icon.
- Official tag1.1.11 Dopamine/Dopamine/UI/Views/SettingsView.swift places Reinstall Package Managers under isBootstrapped()/isJailbroken(). PackageManagerSelectionView.swift only changes selectedNames when an icon is selected; the separate Reinstall button invokes dpkg -i on the bundled sileo.deb. The old SettingsView has no Refresh Jailbreak Apps action. Reference: https://github.com/opa334/Dopamine/blob/1.1.11/Dopamine/Dopamine/UI/Views/PackageManagerSelectionView.swift .
- User confirmed the actual Dopamine status button reads "已越狱 / Jailbroken"; the home-screen icon alone was not treated as evidence.
- Official repository opa334/Dopamine branch2.x, Application/Dopamine/UI/Settings/DOSettingsController.m exposes Reinstall Package Managers when envManager.isJailbroken and pushes DOPkgManagerPickerViewController. zh-Hans.lproj/Localizable.strings names it "重新安装包管理器"; the picker recommends Sileo. This is a settings action, not Remove Jailbreak.
- Source references: https://github.com/opa334/Dopamine/blob/2.x/Application/Dopamine/UI/Settings/DOSettingsController.m and https://github.com/opa334/Dopamine/blob/2.x/Application/Dopamine/zh-Hans.lproj/Localizable.strings .

## USB waiting regression (2026-10-01)
- Sender PID31648 running in USB mode on loopback8765, zero clients. USB device still detected as the paired iPhone11/iOS13.3.
- No listener on local2222 and no usbmux forwarder process. Old ssh41848 from an earlier artifact script remained; current usb_forward.ps1 reused it by command-line match alone. SSH diagnostics therefore failed to connect to2222.
- Removed only the verified stale AppleLive SSH process (no established TCP connections), then started the existing installed tunnel to restore service while implementing durable recovery.

## Native dock request (2026-10-01)
- Final installation: `D:/OBS定制款/OBS定制款/obs studio/data/obs-plugins/AppleLive`. Existing browser dock restored automatically after OBS restart; remains a browser dock, not a native Qt DLL.
- Actual OBS LuaJIT `io.open` fails on UTF-8 Chinese paths with Illegal byte sequence; fixed using OBS UTF-8 filesystem functions through FFI and Windows CreateProcessW for process startup. Verified file read/write/rename/remove and launching sender from the Chinese folder.
- OBS frontend virtualcam startup is asynchronous. Immediate active() check produced a false failure after restart. A nonblocking 100ms timer now waits for readiness, with timeout and cancellation on stop/unload. Real dock start button passed from camera-off state.
- User clarified: "我的意思是直接做到obs文件夹里". Scope is now installing the existing working package inside the customized OBS directory, updating autoload paths, and preserving settings/layout. A native Qt rewrite is not required for this clarified task.
- User wants an actual native OBS dock. Existing browser dock does not fulfill that request.
- Installed OBS30.2.3 uses Qt6.6.3; MSVC BuildTools exist locally, but searched locations have no Qt development SDK. Build on GitHub using the official OBS2024-05-08 Qt archive (SHA256 from OBS30.2.3 buildspec: 8f459af5115ce081ae24b108712327e113893f250e14a902b1bd188b43873ed1). No local SDK installation.
- Native UI should use the OBS theme, show USB/LAN as exclusive choices, explain disabled settings during transmission, and register through obs_frontend_add_dock_by_id.

## LordVCAM 参考行为
- 公开仓库显示其客户端连接 `wss://<host>:8765`，USB 模式仍复用 TCP/WebSocket。
- 二进制视频头部为 20 字节：`type, seqnum, flags, width, height`，均为 little-endian；负载为 H.264/H.265 NAL 数据。
- 二进制音频头部至少包含 `type, sampleRate, channels`，负载为 float32 PCM。
- 典型注入点是 `mediaserverd` 的 `BWNodeOutput copyNextSampleBuffer`，另有 App delegate 级别的回退 hook。
- 视频接收端使用 VideoToolbox `VTDecompressionSession`，音频通过 ring buffer 提供给麦克风管线。

## 设计决定
- 本项目先实现 H.264，不先实现 H.265；H.264 在 Windows FFmpeg 和 iOS VideoToolbox 上兼容性最高。
- 保留 LordVCAM 的 20 字节小端头部，便于互操作；消息类型使用 ASCII 四字节常量 `fram`/`audi`。
- WebSocket 使用明文 `ws://`，默认只监听局域网；可在后续版本加入 TLS/认证。设备和电脑应处于可信网络。
- iOS 接收端断流时必须返回原始摄像头帧，避免直播 App 黑屏或崩溃。

## USB 说明
USB 不是 iOS tweak 自己“看到”的串口。电脑端需要 `usbmuxd`/`pymobiledevice3`/`iproxy` 一类端口转发工具，把电脑发送器端口映射到设备侧 `127.0.0.1:8765`；协议层不区分 LAN 和 USB。

## 2026-10-01 iPhone 11 实机诊断

- 设备实际为 iOS 13.3，系统 Camera/mediaserverd 的 CPU subtype 为旧 arm64e `2`；0.1.3 dylib 的 arm64e subtype 为 `0x80000002`。降低 deployment target 不会让新 clang 生成旧 ABI。官方说明：<https://theos.dev/docs/arm64e-deployment>。
- 修复构建使用 sbingner clang 10 v10.0.0-2 与 Theos iPhoneOS13.7 SDK；归档校验脚本拒绝原 0.1.3 的新 ABI，要求 arm64 和旧 arm64e 两个 slice，最低版本不超过 iOS 13.0。
- 当前抖音版本 39.9.0、bundle ID `com.ss.iphone.ugc.Aweme`，主可执行文件为 arm64；系统相机测试与 App delegate 回退路径不能混为同一次验证。
- OpenSSH 8.4-2 已安装；USB 隧道和专用密钥认证实际通过，手机 loopback 8765 的 WebSocket 升级返回 HTTP 101。诊断连接不等于插件连接；尚未验证 OBS 画面替换。
- 手机自带的 `uiopen` 用法是 `uiopen com.apple.camera`，锁屏时系统拒绝打开相机。手机没有 log/netstat/lsof，使用 pymobiledevice3 syslog 获取限定 AppleLive/相机进程的日志。
- 0.1.4 旧 ABI 包已成功构建并通过 USB 直接安装。安装后 mediaserverd 日志确认加载 AppleLive，发送端出现一个持续 USB 客户端，证明先前的加载不兼容已解决；实际画面替换仍待解锁测试。
- 0.1.5 实机确认 `BWNodeOutput` 只有 `emitSampleBuffer:`（void 返回、一个 CMSampleBuffer 指针参数），原来的 copy 方法不存在。成功解码 720x1280 并写入 2304x1296 的 420v 原相机缓冲；用户确认系统相机和抖音出现 OBS 画面。
- 用户确认系统相机显示倒置，但抖音为正向。因此不能全局更改旋转方向：0.1.6 用按 App 的默认方向与持久化设置，并通过 Darwin 通知让前台 App 实时控制 mediaserverd。
- 0.1.6 UIKit 悬浮窗包已构建及安装，USB 视频解码持续正常；悬浮按钮是否可见、通知控制是否实际改变画面仍等用户实机反馈。音频、TikTok 和端到端延迟未完成验证。

## Dock and transport alignment
- OBS30.2.3 custom browser dock uses http://127.0.0.1:18765/. Local HTTP helper talks to Lua via atomic command files; OBS WebSocket is unnecessary. Browser refresh is available from its right-click menu.
- Direct new shared preference-file creation by sandboxed mediaserverd fails; com.apple.mediaserverd NSUserDefaults persists via the preferences daemon.
- Accept-then-close is unsuitable for incompatible transports: iPhone preferred-USB probe would switch at handshake success. Reject incompatible paths with HTTP403 before upgrade, preventing oscillation. PC USB mode binds loopback only.

## 2026-10-05 portable OBS competitor comparison
- The supplied competitor directory is a full portable OBS root under `E:\2\obs-AuxCam\...\obs studio` with `bin`, `data`, `obs-plugins`, `tools`, and bundled driver/server folders.
- Custom plugin DLLs include `obs-ai-apple-stream.dll`, `obs-ai-srs-push.dll`, `obs-ai-live-relay.dll`, `obs-ai-playback-controller.dll`, `obs-ai-video-processor.dll`, `tang-douyin-direct.dll`, and `vcamtang-obs-usb.dll`; the USB DLL imports OBS output/encoder APIs, Qt6, and registers an OBS dock/output. The companion USB relay is `bin\vcamtang-usb\VcamTang_OBS_USB_Relay_Douyin.exe`.
- The package includes MediaMTX, SRS, Apple Mobile Device Support, a virtual microphone driver, portable mode marker, installer BAT/PS1 files, and Chinese usage notes. It is designed so users extract once and launch the bundled OBS wrapper.
- The supplied competitor root has no `obs64.exe` at the inspected top level; `AuxCam.exe` is a license/launcher wrapper whose strings reference a sibling `obs64.exe`. This is useful for packaging pattern, not a complete executable source to reuse.
- Our current package is an external helper + browser dock installed into an OBS root. It already has portable-compatible `install_or_update.ps1`, MediaMTX, USB sender, and phone dylib. The next implementation is a full portable-root overlay builder that copies the current OBS tree and embeds AppleLive files/configuration, so end users receive one archive.

## 2026-10-06 SkyCam static audit and confirmed native USB defects
- Sky.dylib SHA256 4e0cef5f40804e1f95c7bd33b1c9110308112f18d3f1ae54a743967240cedad0: arm64, iOS 14 min, no VideoToolbox imports; UI/control wrapper evidence only.
- Cam.dylib SHA256 0d43b551d427f5873c27bb2f825a3ba241a69c1e652315256340ddcd7c427b76: arm64 iOS14 min; VCamUSBPuller, VCamVTDecoder, VCamAACDecoder, VCamRTSPPuller classes, system VT/AudioConverter imports. USB log strings show sequence gap, keyframe wait, config rejection, session rebuild and memory footprint tracking. Static metadata cannot prove runtime stability or exact code.
- AppleLive native header hand-declares wrong obs_output_info (missing start/stop) and obs_video_info (pointer replaced with int); get_type_data accesses registration data, not instance. Need verified official ABI, module exports and encoder initialization.
- Native relay SENDS ALUSB1, whereas phone SENDS ALUSB1 then expects BE32 length. Deterministic protocol mismatch. USB port swap does not truncate 16 bits. ConnectionType is nested in Properties.
- Native output audio passes keyframe=true, reopening video gate; encoder borrowed packets are released; no reliable reconnect. Shipped phone dylib predates AAC changes. Prior completion claims do not demonstrate end-to-end correctness.
- User confirmed USB-only issue, same iPhone11/iOS15.6/Douyin.

## 2026-10-06 USB color follow-up
- User confirms USB video/audio now work, but phone picture looks washed out compared with OBS. Preview location clarification pending.
- Active OBS profile/log confirms NV12, Rec.709, Partial; native x264 uses this output without an override.
- ALRenderVideoImage unconditionally overwrites target primaries, transfer and matrix with 709. ALVirtualCamera mutates the original camera pixel buffer while returning the same CMSampleBuffer, whose immutable format description still describes the original camera. This can disagree with full-range/601/BGRA camera contracts.
- Existing color test covers only 420v -> 420v neutral 64/192, missing full-range destinations, saturated colors, BGRA and immutable sample metadata. Need measured regression coverage before claiming a fix for this user's visual observation.
- macOS run 37406249875 reproduces immutable-format mismatch for a full-range 601 camera target. Limited -> full 709 patches already pass (black 16 -> 0, gray 126 -> 128, white 235 -> 255), so a blanket range expansion is not warranted. The new render keeps camera attachments and derives source/output color spaces from their actual metadata; own BGRA previews are tagged sRGB before sample creation.

## 2026-10-06 fisheye feature
- User requests one switch that turns the injected picture into a fisheye picture. Existing mobile ALMediaPanel uses persistent ALControls and shares renderVideoIntoSample across USB/LAN/local sources and preview.
- Use a default-off native UISwitch in picture controls with an accessibility label. Relevant ui-ux-pro-max result: active states should provide immediate feedback; native switch and next-frame application fit this requirement.
- Use an equidistant radial warp with fixed 120-degree diagonal projection, normalized by half the image diagonal (same scale on both axes). This gives barrel curvature without manufacturing new field of view or stretching portrait/landscape differently. Cache the Core Image kernel, keep the original image when off, and preserve the existing color-render path.
- Actual rendered comparison exposed geometry outside the declared extent during composition. An equal-extent crop did not fix it (37408681764); the final sampled-color kernel checks destination bounds and explicitly returns transparent pixels in the margins. This remains one cached GPU kernel.

## 2026-10-06 adjustable fisheye
- User clarified that Douyin preview distortion is too subtle and explicitly wants adjustable strength. This is a visual effect request.
- Slider 0–100%, default 75% exactly preserves the previous 60-degree half-angle. Maximum 100% uses an 80-degree half-angle for stronger curvature while staying below the projection's 90-degree singularity. Zero and switch-off bypass the kernel.
- Publish rounded slider values immediately, save after release or a short idle interval (including accessibility adjustment). Keep the value when toggled off. Hide strength controls while the effect is off.

## 2026-10-06 external capture feasibility
- User requests a new source using a camera/capture card physically attached to the phone. This differs from the existing USB mode, where the phone is a device receiving encoded video from a Windows USB host through usbmux.
- Current standalone source types are network, local and usb. ALVirtualCamera hooks all AVCaptureVideoDataOutput delegates and some BWNodeOutput paths. An in-process external AVCaptureSession would need a proven hook bypass to avoid feeding replacement frames back into the acquisition source, plus verified coexistence with the target App's camera session.
- Apple external device API documentation: https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/external . Introduced at iOS/iPadOS 17; Discussion specifies UVC devices on iPad. Apple WWDC23 session https://developer.apple.com/videos/play/wwdc2023/10106/ is explicitly about external cameras in iPadOS apps. Neither establishes a generic UVC acquisition path for iPhone 11 / iOS 15.6.
- Requested exact phone/OS, accessory model/adapter, and an App already showing its video. Do not equate jailbreak or an external device constant's SDK availability with an installed UVC driver. A specialized MFi accessory or jailbreak driver must be identified before selecting an implementation.
- User confirms iPhone 11 / iOS 15.6 and wants multiple brands; no specific device/adapter/receiving App identified. The WWDC transcript explicitly says only iPad supports external cameras, while iPhone can use the preferred-camera storage API. Upstream libusb README does not list an iOS backend. Repository discovery did not establish a tested generic iOS15 UVC driver; custom driver feasibility remains unverified.
- Follow-up USB Host research found https://github.com/jamesy0ung/UVCDisplay : an iOS <=16/TrollStore/jailbreak experiment using libusb's Darwin backend and libuvc; its own bridge is MS2130 VID/PID-specific and YUY2-only, and its build targets iOS16. This is new evidence of an implementation path, not proof of iPhone11/iOS15/Douyin compatibility. Its wrapper has no declared license and is not incorporated. AppleLive implements its own wrapper with pinned, licensed upstream libusb/libuvc.
- Theos iOS15.6 SDK exports IOCFPlugIn USB access functions in IOKit, so an arm64 userspace backend can be built. Access still depends on the HOST EXECUTABLE's sandbox/entitlements. Dylib signing cannot grant com.apple.security.exception.iokit-user-client-class (AppleUSBHostDeviceUserClient / AppleUSBHostInterfaceUserClient) or com.apple.system.diagnostics.iokit-properties. If in-process access fails, a separately entitled acquisition service is necessary; no automatic permission bypass is implemented.
- Experimental scope: discover UVC devices without a VID/PID whitelist; bounded MJPEG/YUY2/UYVY modes (prefer 720p MJPEG, cap raw bandwidth); owned BGRA frames; stop/retry and no-frame timeout; native UI diagnostic report. External UAC audio is not implemented and current microphone/inner-audio settings are preserved.

## 2026-10-06 external camera phone diagnostic
- User screenshot d3ed488569055d155dd92d943da33e41.jpg reports com.ss.iphone.ugc.Aweme, iOS15.4.1 build19E258 (different from earlier 15.6 description). Both USB entitlement keys are undeclared. IOService matching returned success 0x0 with zero visible IOUSBHostDevice entries and no UVC devices. This does not independently prove whether the missing device is caused by sandbox filtering, OTG/power/hardware, or both.
- Move USB acquisition into an independently signed, uncontainerized mobile-user launchd service for rootless iOS15+. The target App receives raw UVC frames over 127.0.0.1:8767, with no additional encode cycle. Per-install random pairing token, no public listening interface, no acquisition before authenticated start, one pending latest frame and receiver credit; release device on disconnect.
- Setup app copies the token and exports the bundled matching dylib. It uses its own no-container/no-sandbox entitlement declarations (consistent with the established TrollStore root-helper keys), without changing Douyin entitlements. A physical service launch/USB access test is still required; signing declarations is not proof of runtime grants.
- Follow-up screenshot e04a3c486c817880bd7faed50d207686.jpg confirms AppleLiveUVCHost actually launched on iOS15.4.1 and returned diagnostics through the paired client. Both requested USB entitlement values are present, but IOUSBHostDevice count remains zero; UVC returns -4 (no device), before negotiation/decoding. User confirms a Lightning USB camera adapter with its independent power port connected. Exact adapter/capture model and host-mode recognition remain unknown. Do not assert missing power or proven permission success.
- The read-only inventory queries IOUSBHostDevice; pinned libusb Darwin queries IOUSBDevice. This is a diagnostic coverage gap, not evidence that changing the backend class fixes this phone: neither class's actual device tree is available yet. Upstream UVCDisplay uses the same combination, so its README does not resolve this device's enumeration failure.
- User confirms the pictured powered adapter carries audio/video and identifies the camera brand as Logitech. The phrase "other device interface" is not an identified protocol; no working App name or camera model was supplied. Logitech USB webcams often expose UVC, so do not infer MFi or a proprietary driver solely from that reply. Focus on software discovery and preserve the existing physical setup.
- Pinned libuvc's discovery silently skips devices when configuration/device descriptors cannot be read, then returns an empty success list. Current wrapper turns that into a generic no-device error, losing the distinction between no USB nodes and descriptor access failures. The next service update must expose raw USB descriptors/errors and both IOKit matching classes before interpreting UVC results.
