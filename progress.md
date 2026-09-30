# Progress

## 2026-09-30 low-latency pass

- Simplified the OBS panel to quality, connection mode, audio toggle, and start/stop; technical settings are hidden until Advanced is enabled. USB mode launches the tunnel window.
- Added iOS periodic preferred-USB probe so an active LAN connection can switch to USB without restarting the live app. Awaiting iOS 13 build and device test for this change.
- Converted incoming 48 kHz stereo PC audio to the camera callback's channel count and sample rate, with a bounded 200 ms ring. Device audio output remains to be tested.
- Found the customized OBS virtual camera registered as `HD Camera` at 1080x1920/30 fps; verified FFmpeg captures it. Its inactive state displays the OBS placeholder.
- Added NVENC auto selection, bounded 5 Mbps VBR, a 15-frame GOP at 30 fps, 20 ms audio reads, a 24-packet client queue, and IDR recovery after overload. Kept aspect ratio while scaling to 720x1280.
- Desktop WebSocket smoke test received SPS/PPS plus about 30 fps, with first IDR after 0.34 s. This is not a phone or live-app latency measurement.
- Added USB reverse SSH tunnel script and iOS USB-first/LAN-fallback addresses. Phone USB detection works; its SSH port 22 is closed, so USB streaming remains unverified.

## 2026-09-30
- 检查工作区，确认为空目录。
- 查询公开 LordVCAM 资料，确认是越狱虚拟摄像头 tweak，不是普通 App。
- 读取公开协议线索：WebSocket 8765、H.264 NAL、float32 PCM、mediaserverd 注入。
- 建立任务计划，下一步实现桌面发送端和协议测试。
- 完成桌面发送端、H.264 Annex-B 分帧、float32 PCM 打包、LAN WebSocket 服务和 USB 转发脚本。
- 完成 iOS tweak 的 WebSocket 接收、VideoToolbox 解码、视频帧缓存、音频 ring buffer 和相机 delegate/BWNodeOutput 注入入口。
- 修复 Annex-B 小块读取缓存 bug和音频交错帧计数 bug；Python 协议自测与 WebSocket 握手自测通过。
- FFmpeg 实际桌面采集冒烟测试通过；带 VB-CABLE 音频时同时收到 `fram` 和 `audi` 消息。
- 修复 Windows 结束进程树残留和音频 10ms 队列挤掉视频的问题；确认 AppleLive 的 FFmpeg 子进程无残留。
- 当前机器无 Theos/iPhoneOS SDK，未生成 iOS deb；README 已写明构建命令和验证边界。
- 最终检查通过：Python 协议测试、AST 检查、PowerShell 语法检查；无 AppleLive 测试 FFmpeg 或临时目录残留。
- 新增 `DOWNLOADS.md`，列出 iPhone 越狱依赖、Theos 构建机、Windows 采集端和 USB 反向隧道前置条件，并要求用户提供目标设备参数。
- GitHub Actions rootless 构建成功，产物为 `com.applelive.tweak_0.1.0_iphoneos-arm64.deb`；当前包用于 LAN 第一阶段验证，USB 监听器仍待实现。
- 收到新需求：将电脑端做成 OBS 脚本插件。当前机器未检测到 OBS，计划使用 OBS 内置 Lua 脚本控制打包后的发送器，并采集 OBS Virtual Camera。
- OBS Lua 脚本和 AppleLiveSender.exe 已完成；dshow 摄像头收帧、状态文件、停止清理和 Lua 语法检查通过。正在安装 OBS 进行面板实测。
- `winget` 下载的 OBS 官方安装器缓存 SHA256 与官方值不符，未运行该文件；实际 OBS 面板暂未能在本机验证。Lua 运行时模拟的启动/停止按钮测试通过。
- 为 OBS 脚本增加启动/停止状态保护和心跳超时提示；发送器状态文件加入更新时间。协议自测、Lua 语法检查和本地 ZIP 构建通过，压缩包包含 Lua、exe 与说明。等待 GitHub Actions Windows 构建结果。
- 本地 ZIP 中的无控制台发送器用不存在的视频设备实测：写入 `error` 状态和 FFmpeg 日志后退出，无残留进程；异常不再触发 Windows 错误弹窗。
- GitHub Actions Windows 工作流成功（run 36677356994），已上传 `AppleLive-OBS-Windows` ZIP；本机尚无可运行的 OBS，真实脚本面板与目标 iPhone 的抖音/TikTok 尚未实测。
- 用户照片确认目标手机为 iPhone 11 / iOS 13.3 / unc0ver + Cydia + Substitute。新增 iOS 13.0 最低部署版本的 rootful 构建工作流、rootful 控制文件和测试 App 注入过滤器；需在 CI 生成包并在该设备上验证。
- GitHub Actions rootful 构建成功（run 36684920099）；下载并检查 `com.applelive.tweak_0.1.0_iphoneos-arm.deb`，控制信息为 iphoneos-arm、`mobilesubstrate | com.ex.substitute`，dylib/plist 位于 rootful 的 `/Library/MobileSubstrate/DynamicLibraries/`。同次触发的 rootless 构建也成功，真实手机相机和直播 App 效果未验证。
