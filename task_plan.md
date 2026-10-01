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
| 7. OBS 验证 | complete | 真实 OBS 浏览器停靠面板、启停、设置保存和 USB/LAN 通道切换已验证；本机 Windows ZIP 已构建 |
| 8. iOS 13.3 rootful 适配 | in_progress | 0.1.5 用户确认相机与抖音显示 OBS，抖音方向正确、系统相机倒置；0.1.6 改为分 App 保存方向，声音、TikTok 与延迟仍待实测 |
| 9. 手机悬浮控制面板 | in_progress | 0.1.10 已安装；连接由电脑统一选择，手机自动跟随，真实 USB/LAN 切换通过；已补旧帧过期与断流重连，旋转等交互与声音仍待完整实测 |
| 10. OBS 停靠面板与连接一致性 | complete | 实际 OBS 停靠显示和控制通过；USB 只监听回环，LAN 拒绝 USB 隧道；已实测手机随电脑切换，模式与状态一致 |
| 11. 插件安装到现有 OBS 文件夹 | complete | 已安装到 OBS/data/obs-plugins/AppleLive，迁移加载路径、保留布局和高清/LAN设置；修复中文路径与首次启动虚拟摄像头异步问题，实际按钮一次点击启动并接入手机 |
| 12. USB 断线恢复 | complete | 修复残留进程误判，已恢复USB且用户确认画面；已安装健康检查/自动重试与单实例管理，验证无设备时重试和并发启动复用；实体拔插重连未完整实测 |
| 13. 手机连接按钮与高清卡顿 | complete | 0.1.11已安装，用户确认手机连接/断开按钮正常、画面流畅；电脑分帧优化后高清持续测得30.02fps，保留用户当前LAN/高清设置 |

## Constraints
- 连接方式只在电脑选择，手机自动跟随；手机只保留局域网电脑地址设置，避免两端选择冲突。
- iOS 相机服务是私有实现，不同 iOS 版本需要单独验证类名和方法签名。
- 必须只在越狱设备上测试；桌面端音频采集依赖 FFmpeg 和可用的 WASAPI/dshow 设备。

## Errors Encountered
| Error | Attempt | Resolution |
|---|---|---|
| GitHub clone connection reset | 1 | 改用 GitHub API/raw 读取参考实现，仅提取公开协议和结构，不复制其授权不明源码 |
| iOS toolchain unavailable on Windows | 1 | 完成源码级审查并记录限制；交由 macOS/Linux Theos 环境执行最终 deb 构建 |
