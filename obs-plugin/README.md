# AppleLive OBS 控制插件 (Windows)

这是通过 OBS **工具 → 脚本**加载的 Lua 插件，不是放入 `obs-plugins` 目录的 DLL。它控制同目录下的 `AppleLiveSender.exe`。OBS 的画布就是预览，发送源是 OBS 虚拟摄像头的节目画面；场景切换、文字、摄像头和媒体源都会进入 iPhone 画面。

## 准备

1. 使用现有 OBS 和 FFmpeg。把 `ffmpeg.exe` 加入 PATH，或在脚本面板填写完整路径。
2. 解压 `AppleLive-OBS-Windows.zip`，将 `AppleLive.lua`、`AppleLiveSender.exe` 和 `usb_forward.ps1` 保持在同一个可写目录，例如用户的文档目录。
3. 在 OBS 中打开 **工具 → 脚本**，点击 `+`，选择 `AppleLive.lua`。
4. 在脚本面板选择 **画质** 和 **连接方式**，点击 **启动**。脚本会自动启动 OBS 虚拟摄像头。连接后，面板显示手机连接数和 USB 连接数；点击 **停止**结束发送。视频设备、码率等参数放在 **高级设置**，普通使用无需调整。

这台定制 OBS 的虚拟摄像头在 Windows 中注册为 `HD Camera`，默认值已对应它，源格式为 1080×1920/30 fps。其他 OBS 安装通常使用 `OBS Virtual Camera`；可用 `ffmpeg -list_devices true -f dshow -i dummy` 核对精确名称。默认输出为 720×1280/30 fps、5 Mbps，自动优先 NVIDIA NVENC，硬件不可用时使用 CPU `veryfast`。约每半秒发送关键帧。网络稳定且编码器跟得上时，可将码率调到 8 Mbps 或分辨率调到 1080×1920；若 OBS 出现渲染丢帧，应先降低场景负载或帧率。

当前构建的可执行文件在本项目 `obs-plugin/AppleLiveSender.exe`；重新构建用：

```powershell
python -m pip install -r desktop_sender/requirements.txt pyinstaller
.\scripts\build-obs-plugin.ps1
```

## OBS 节目音频

OBS 虚拟摄像头只有视频。要把 OBS 的节目声音也送到 iPhone：

1. 安装 [VB-CABLE](https://vb-audio.com/Cable/)。
2. OBS **设置 → 音频 → 高级 → 监听设备** 选择 `CABLE Input (VB-Audio Virtual Cable)`。
3. 在 OBS 混音器的 **高级音频属性** 中，把需要发送的源设为 **监听并输出**。
4. 在 AppleLive 脚本的音频设备填写 `CABLE Output (VB-Audio Virtual Cable)`。

FFmpeg 可以列出设备精确名称：

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

不填写音频设备时，只传 OBS 画面，iPhone 仍使用手机麦克风。

## iPhone 连接

LAN 模式下，iPhone 越狱插件配置中的 `server` 填电脑的局域网 IPv4 地址和端口，例如 `192.168.1.20:8765`。Windows 防火墙需要允许 AppleLiveSender 的入站连接。OBS 脚本面板的“状态”显示发送器状态和 iPhone 连接数；更详细的错误在同目录的 `applelive-sender.log`。

USB 模式需先在 iPhone 的 Cydia 安装并启动 OpenSSH。OBS 面板选择 **USB 数据线** 后点击 **启动**，会自动打开连接窗口；在该窗口输入 SSH 密码，并在使用时保持窗口开启。iOS 13 一体包优先连接 USB，USB 不可用时回退到 LAN；已经连上 LAN 时也会自动探测并切换到 USB。当前手机的 22 端口未开放，因此 USB 链路还不能完成实机验证；抖音和 TikTok 的相机替换也仍需实测。
