# AppleLive OBS plugin (Windows desktop v0.4.2)

LAN mode uses the bundled MediaMTX RTMP/RTSP server. USB mode uses the same OBS encoded output through a loopback RTMP path, then sends H.264/AAC through usbmux. It does not capture OBS Virtual Camera, DirectShow, or a VB-Cable device.

## 安装

1. 将 ZIP 解压到 OBS 目录以外的任意文件夹，双击 `安装或更新AppleLive.cmd`。安装程序会定位并关闭 OBS、替换旧版文件、自动添加 Lua 脚本和 AppleLive 停靠窗口、启用 OBS WebSocket，然后重新打开 OBS。
2. In the dock, choose LAN or USB. LAN keeps the existing Get Stream Key / Start workflow. USB only needs Prepare USB Direct; it starts a loopback MediaMTX input and the OBS local output automatically, with no user OBS Start Streaming click.
3. 局域网模式需要把面板显示的 RTMP 或 RTSP 地址填进手机插件的「检测」入口；USB 模式需要在手机插件里点击「USB 直连」。

`127.0.0.1:18765` 只供 OBS 本机停靠面板使用，不是手机拉流地址。

## USB 数据线

USB mode requires the iPhone to trust this computer and the latest `AppleLive.dylib`. The media path is `OBS encoder -> 127.0.0.1:1935 MediaMTX -> FFmpeg remux/decode -> usbmux -> AppleLive.dylib`; it does not use OBS Virtual Camera, DirectShow, VB-Cable, Wi-Fi, RTSP, or OpenSSH. Windows must have Apple Mobile Device/usbmux drivers (Apple Devices, iTunes, or 3uTools drivers).

The reference package goes one step further: its native OBS C++ output DLL owns the H.264/AAC encoder packets and a non-blocking queue, then a small native relay talks to usbmux. That is the remaining difference for matching its failure boundaries exactly; the portable package now removes the virtual-device dependency and keeps one OBS folder for delivery.

## 地址

假设电脑 IP 为 `192.168.1.45`：

| 用途 | 地址 |
| --- | --- |
| OBS 推流服务器 | `rtmp://192.168.1.45:1935/live` |
| OBS 推流密钥 | `applelive` |
| 完整 RTMP 流 | `rtmp://192.168.1.45:1935/live/applelive` |
| 手机 RTSP 拉流 | `rtsp://192.168.1.45:8554/live/applelive` |

IP 由面板读取当前电脑网卡，并优先选择默认联网网卡。不要在手机填写 `127.0.0.1`。电脑和手机须在同一局域网，且网络允许设备互相访问。每台新电脑都要单独完成一次 Windows 授权；授权状态与电脑绑定，不会随插件文件复制到另一台电脑。换电脑或电脑 IP 改变后，重新点击「获取推流码」。手机插件仍需具备可用的注入环境；手机 RTSP 实机画质、音频和各直播 App 兼容性应单独验证。

OBS 应使用 H.264 视频和 AAC 音频输出，避免手机解码器不支持其他编码。推流经过 MediaMTX，不需要 SRS。当前 ZIP 是 Windows x64 版本；安装器会为普通版或便携版 OBS 自动配置脚本、停靠窗口和 WebSocket。每台电脑首次获取推流码时仍需确认一次 Windows 防火墙授权。手机插件文件包含在 ZIP 中，但不会自动安装到手机。OBS 开播按钮只控制这条本地流，不会替手机直播 App 自动点击开播。

## 构建

```powershell
python -m pip install -r desktop_sender/requirements.txt pyinstaller
./scripts/build-obs-plugin.ps1
```

构建脚本使用 `obs-plugin/phone-plugin/AppleLive.dylib`、`obs-plugin/server/mediamtx.exe` 和本机 FFmpeg，输出 `artifacts/AppleLive-OBS-Windows.zip`。控制服务只监听电脑本机回环地址，通过本机 OBS WebSocket 执行按钮命令；Lua 脚本只负责随 OBS 启动停靠服务。运行日志写入 `%LOCALAPPDATA%\AppleLive`，不要求 OBS 安装目录可写。
