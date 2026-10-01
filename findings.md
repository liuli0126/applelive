# Findings

## Single-file connection profile and OBS download (2026-10-01)
- Preserve the signed Mach-O bytes and encode IPv4/port in the exported filename. Standalone initialization locates its own image with dladdr using a data anchor; accepts Safari numeric duplicate suffixes and validates the address with the existing parser. A changed exported profile updates app-owned defaults; the same profile retains manual settings.
- Standalone connection controls now notify inside the target app instead of depending on mediaserverd. LAN HTTP downloads share the sender's port but remain separate from video handshakes; USB mode rejects the download endpoint. The dock's control API remains loopback-only with its existing Origin/token checks.
- QR generation uses qrcode/Pillow in the CI-built executable. Local protocol, ten dock tests, three transport handshakes and two phone-download tests passed. Positive QR rendering is deferred to CI because qrcode is not installed locally.

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
