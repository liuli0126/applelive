# 桌面发送端

## 安装

需要 Python 3.10 或更新版本。

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

同时安装 FFmpeg，并确保 `ffmpeg.exe` 在 `PATH` 中。独立发送器默认采集整个桌面，输出 1920x1080/30fps H.264；有 NVIDIA NVENC 时自动使用硬件编码，否则用 CPU `veryfast`。默认 5 Mbps，可用 `--bitrate-kbps`、`--encoder` 和 `--encoder-preset` 调整。OBS 插件默认 720x1280/30fps、5 Mbps，竖屏源不会被拉伸。

协议单测无需 pytest：

```powershell
python protocol_test.py
```

## 局域网

```powershell
python sender.py --host 0.0.0.0 --port 8765 --audio-device "CABLE Output"
```

在 iPhone tweak 设置中填入电脑局域网地址，例如 `192.168.1.20:8765`。Windows 防火墙需要允许 TCP 8765 入站。

音频设备名可以用下面的 FFmpeg 命令查看：

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

系统声音通常需要 VB-CABLE、Voicemeeter 或声卡的 Stereo Mix 作为 dshow 设备。

## OBS 视频源

使用 OBS 脚本插件时，不需要手动输入下面的命令。独立运行发送器可指定 OBS 虚拟摄像头；这台定制版 OBS 的设备名为 `HD Camera`：

```powershell
python sender.py --video-device "HD Camera" --width 720 --height 1280 --bitrate-kbps 5000 --audio-device "CABLE Output (VB-Audio Virtual Cable)"
```

OBS 脚本及可执行文件的使用说明见 `../obs-plugin/README.md`。

## USB

OBS 插件的 USB 数据线模式不需要 OpenSSH、Filza、虚拟摄像头或额外音频驱动。OBS 输出先进入本机 MediaMTX 的 H.264/AAC 流，发送器从 loopback RTMP 读取后再通过 `pymobiledevice3` 的 usbmux 发送到手机插件的 `127.0.0.1:8766`。这比 DirectShow 读取 OBS Virtual Camera 稳定，但仍比同行的原生 OBS output DLL 多一个 FFmpeg/Python 转发层。

Windows 必须能识别 iPhone 的 Apple Mobile Device/usbmux 驱动；安装 Apple Devices、iTunes 或爱思中的任意一种驱动即可。

USB 模式由 OBS 停靠窗口控制：选择“USB 数据线”，点击“准备 USB 直连”，再点击“开播”。手机端打开 AppleLive 面板并点击“USB 直连”，用数据线连接并信任电脑即可。下播或切回局域网时，USB 发送器会自动停止。

`usb_forward.ps1` 是旧的 OpenSSH 隧道方案，不再用于当前 USB 直连模式。
