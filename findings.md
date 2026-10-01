# Findings

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
