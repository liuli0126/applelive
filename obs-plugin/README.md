# AppleLive OBS 控制插件 (Windows)

这是通过 OBS **工具 → 脚本**加载的 Lua 插件，不是放入 `obs-plugins` 目录的 DLL。它控制同目录下的 `AppleLiveSender.exe`。OBS 的画布就是预览，发送源是 OBS Virtual Camera 的节目画面；场景切换、文字、摄像头和媒体源都会进入 iPhone 画面。

## 准备

1. 安装 [OBS Studio 30+](https://obsproject.com/download) 和 [FFmpeg Windows 构建](https://www.gyan.dev/ffmpeg/builds/)。把 `ffmpeg.exe` 加入 PATH，或在脚本面板填写完整路径。
2. 解压 `AppleLive-OBS-Windows.zip`，将 `AppleLive.lua` 和 `AppleLiveSender.exe` 保持在同一个可写目录，例如用户的文档目录。
3. 在 OBS 中打开 **工具 → 脚本**，点击 `+`，选择 `AppleLive.lua`。
4. 在脚本面板设置输出宽度、高度、帧率和音频设备，点击 **启动传输**。脚本会自动启动 OBS 虚拟摄像头。iPhone 连接后，重新打开脚本面板可看到连接数。点击 **停止传输**可关闭发送器。

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

当前 OBS 插件使用 LAN。iPhone 越狱插件配置中的 `server` 填电脑的局域网 IPv4 地址和端口，例如 `192.168.1.20:8765`。Windows 防火墙需要允许 AppleLiveSender 的入站连接。OBS 脚本面板的“状态”显示发送器状态和 iPhone 连接数；更详细的错误在同目录的 `applelive-sender.log`。

电脑端安装包现可进行 LAN 链路测试；iPhone 摄像头替换、抖音和 TikTok 的实际效果仍需在目标越狱设备上验证。USB 所需的 iPhone 端监听器和电脑端 usbmux 客户端尚未实现，当前版本不能以 USB 连接使用。
