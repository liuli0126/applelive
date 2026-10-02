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
| 14. iOS 15.6 / Dopamine 实机适配 | in_progress | 已确认iPhone11/15.6/19G71，安装0.1.12与ElleKit1.2，完成专用SSH密钥配对；相机服务已加载但无法导入预设地址，0.1.13补充直接配置工具后实测画面 |
| 15. 虚拟相机注入器单文件交付 | in_progress | 独立arm64/arm64e dylib编译和依赖检查通过；补电脑地址自动导入、OBS下载与二维码，再验证修改版注入器实机画面 |
| 16. OBS 手机插件下载与自动地址配置 | complete | 完整包已构建并更新现有OBS；真实二维码解码、LAN下载签名字节一致和280/560px停靠窗口检查通过，原高清LAN设置保留 |
| 17. 对照插件的媒体引擎 | in_progress | FFmpeg双架构编译、媒体与RTMP解码测试通过；标准拉流服务器使用用户现有的MediaMTX1.18.1，手机App兼容待实测 |
| 18. 素材与播放控制 | in_progress | 相册/文件、循环/暂停/进度和内录已交付；播放/拖动/循环/PCM静音测试通过，两路采集使用独立音频缓冲；真机交互及内录待验证 |
| 19. 预览与照片适配 | in_progress | 相机预览层、独立预览和JPEG/AVCapturePhoto替换双架构编译通过，待真机验证 |
| 20. 多版本和USB批量部署 | in_progress | arm64/iOS14与arm64e/iOS15单文件已交付；免SSH USB分包/顺序测试通过，无配对时跳过旧SSH流程；真实USB及其他系统待验证 |
| 21. 构建和完整功能验证 | in_progress | cd13b4b完整CI通过；更新现有OBS并保留LAN/高清/声音，RTMP H264/AAC与旧通道音视频验证、280/560px面板及下载哈希检查通过；真机项目未完成 |
| 22. OBS 地址展示纠正 | in_progress | 已撤销误改的纯 RTMP 传输，仅移除 WebSocket 地址展示；RTMP、RTSP 与原连接逻辑保留，正在独立端口验证和交付 |

## Constraints
- 连接方式只在电脑选择，手机自动跟随；手机只保留局域网电脑地址设置，避免两端选择冲突。
- iOS 相机服务是私有实现，不同 iOS 版本需要单独验证类名和方法签名。
- 必须只在越狱设备上测试；桌面端音频采集依赖 FFmpeg 和可用的 WASAPI/dshow 设备。

## Errors Encountered
| Error | Attempt | Resolution |
|---|---|---|
| RTSP integration timeout with default ports | 1 | 当前用户运行中的 MediaMTX 只监听 1935、未监听 8554；改用独立端口验证，不终止用户进程 |
| Isolated-port smoke command rejected by execution policy | 1 | 命令未执行；保留用户进程，改由 GitHub 干净环境运行现有 RTMP/RTSP 集成测试 |
| ZIP verification script quoting/.NET compatibility | 1-2 | 修正 PowerShell 字面量转义与哈希转换 API，第三次完整检查通过；压缩包无需修改 |
| GitHub clone connection reset | 1 | 改用 GitHub API/raw 读取参考实现，仅提取公开协议和结构，不复制其授权不明源码 |
| iOS toolchain unavailable on Windows | 1 | 完成源码级审查并记录限制；交由 macOS/Linux Theos 环境执行最终 deb 构建 |
