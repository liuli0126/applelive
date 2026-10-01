# AppleLive OBS 停靠面板（Windows）

AppleLive 把 OBS 节目画面发送到越狱 iPhone。控制面板可固定在 OBS 侧边，也可拖出成为独立窗口。场景切换、文字、摄像头和媒体源都会进入手机画面。

## 首次安装

1. 使用现有 OBS 和 FFmpeg。将 FFmpeg 加入 PATH，或在高级设置填写完整路径。
2. 完整解压 ZIP 到 OBS 安装目录下的 `data/obs-plugins/AppleLive` 文件夹，保留 AppleLive.lua、AppleLiveSender.exe、AppleLiveDock.exe、usb_forward.ps1 和 dock 文件夹。该目录需要可写；支持中文路径。
3. 在 OBS「工具 → 脚本」点击 +，加载 AppleLive.lua。只加载一份，旧版重复项可移除。
4. 打开「停靠窗口 → 自定义浏览器停靠窗口」，名称填 AppleLive，URL 填 `http://127.0.0.1:18765/`，点击应用。
5. 拖动 AppleLive 标题栏固定在 OBS 侧边。选择连接方式和画质，点击「开始传输」。

只需添加一次，OBS 会保存布局。脚本随 OBS 启动本地面板服务。如启动时网页尚未加载，右键面板选择刷新。面板只监听本机，不需要配置 OBS WebSocket。

插件文件安装在 OBS 文件夹内；当前面板使用 OBS 的浏览器停靠功能，尚不是 Qt 原生 DLL。脚本加载记录和窗口布局由 OBS 保存，复制到另一台电脑后仍需完成上述首次加载步骤。

## 连接方式只在电脑选择

手机安装 0.1.9 或更新版本后自动跟随电脑，手机浮窗显示实际连接方式，不再提供第二套连接选择。

- **USB 数据线**：发送器只允许 USB 隧道接入，不接受局域网连接。连接数据线并信任电脑；手机浮窗显示「USB 数据线」。
- **同一局域网**：发送器只允许网络连接，不接受 USB 隧道接入。手机与电脑连接同一路由器，首次在手机浮窗「电脑局域网地址」中填写电脑面板显示的地址，如 `192.168.1.45:8765`。以后自动记住。

要切换方式：在电脑点击「停止传输」→ 选择方式 →「开始传输」。手机会重新连接，无需再次选模式。即使数据线仍插着，选择局域网后也只走局域网。连接数表示接收进程数，不等于手机台数。

USB 需要手机 OpenSSH、Windows Apple 驱动、Python、pymobiledevice3 和 Windows OpenSSH 客户端。首次按 USB 窗口提示输入手机 SSH 密码；已完成专用密钥配对时自动连接。已有的 AppleLive 隧道会复用。停止视频会保留隧道以便再次启动；关闭原 USB 窗口可结束隧道。LAN 不需要 SSH，Windows 防火墙需允许视频端口入站。

## 画质与声音

默认标准画质：720×1280、30 fps、5 Mbps；流畅为 540×960，高清为 1080×1920。优先使用 NVIDIA NVENC，硬件不可用时使用 CPU x264。画质等高级参数可在「工具 → 脚本 → AppleLive」中设置。

这台定制 OBS 的虚拟摄像头叫 `HD Camera`，默认已对应它。普通 OBS 通常叫 `OBS Virtual Camera`，需在高级设置调整。启动时会自动开启 OBS 虚拟摄像头。

OBS 虚拟摄像头只有视频。电脑声音需要：

1. 安装 VB-CABLE。
2. OBS「设置 → 音频 → 高级 → 监听设备」选择 CABLE Input。
3. 混音器「高级音频属性」中，将需要发送的源设为「监听并输出」。
4. 在电脑面板打开「传输电脑声音」，手机悬浮窗打开「电脑声音」。

默认关闭电脑声音，使用手机麦克风。声音端到端仍需真实直播 App 验证。

## 构建与诊断

```powershell
python -m pip install -r desktop_sender/requirements.txt pyinstaller
.\scripts\build-obs-plugin.ps1
```

输出为 `artifacts/AppleLive-OBS-Windows.zip`。协议、控制接口和 USB/LAN 隔离检查在 GitHub Actions 中执行。运行状态及错误日志位于插件目录的 applelive-status.json、applelive-bridge.json、applelive-sender.log。

已在 iPhone 11 / iOS 13.3 上验证 USB 视频替换，用户也已确认 LAN 连接成功。TikTok、其他机型系统、声音和端到端延迟需分别实测，不由编译通过推断兼容。
