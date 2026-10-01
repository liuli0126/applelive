# AppleLive 越狱虚拟摄像头

## Goal
在越狱 iPhone 上提供一个可注入直播 App 的虚拟摄像头/麦克风源，接收 Windows 电脑采集的画面和声音；支持局域网直连，并为 USB 端口转发保留同一协议入口。

## Phases

| Phase | Status | Outcome |
|---|---|---|
| 1. 协议与边界确认 | complete | 固定 WebSocket + H.264 Annex-B + float32 PCM，明确越狱和私有 API 风险 |
| 2. 桌面发送端 | complete | 可运行的 Windows/Python 发送器、LAN/USB 参数、协议测试 |
| 3. iOS 接收与解码 | complete | Theos tweak 接收 WebSocket、VideoToolbox 解码、音频 ring buffer |
| 4. 摄像头注入 | complete | mediaserverd BWNodeOutput hook 和 AVCapture delegate fallback，保留原帧回退 |
| 5. 打包与验证 | complete | Theos Makefile、安装说明、Python AST/协议/WebSocket/FFmpeg 冒烟检查；iOS deb 需在 macOS/Linux + Theos 上构建 |
| 6. OBS 控制插件 | complete | OBS Lua 脚本控制虚拟摄像头、发送器和连接状态；Windows 可执行文件 |
| 7. OBS 验证 | in_progress | dshow 视频传输、启停清理、Lua 语法、本地与 GitHub Actions Windows ZIP 构建通过；真实 OBS 面板和 iPhone 直播 App 待设备实测 |
| 8. iOS 13.3 rootful 适配 | in_progress | 0.1.5 用户确认相机与抖音显示 OBS，抖音方向正确、系统相机倒置；0.1.6 改为分 App 保存方向，声音、TikTok 与延迟仍待实测 |
| 9. 手机悬浮控制面板 | in_progress | 已实现 App 内可拖动按钮、开关、旋转、镜像、适配和声音设置，通过通知实时传给相机服务，待编译及实机验证 |

## Constraints
- 当前扩展：OBS 自定义浏览器停靠控制面板；手机悬浮窗增加自动、USB、局域网及电脑地址设置，构建安装后验证。
- 当前工作区为空，无法复用现成工程。
- iOS 相机服务是私有实现，不同 iOS 版本需要单独验证类名和方法签名。
- 必须只在越狱设备上测试；桌面端音频采集依赖 FFmpeg 和可用的 WASAPI/dshow 设备。

## Errors Encountered
| Error | Attempt | Resolution |
|---|---|---|
| GitHub clone connection reset | 1 | 改用 GitHub API/raw 读取参考实现，仅提取公开协议和结构，不复制其授权不明源码 |
| iOS toolchain unavailable on Windows | 1 | 完成源码级审查并记录限制；交由 macOS/Linux Theos 环境执行最终 deb 构建 |
