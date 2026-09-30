# 桌面发送端

## 安装

需要 Python 3.10 或更新版本。

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

同时安装 FFmpeg，并确保 `ffmpeg.exe` 在 `PATH` 中。视频默认采集整个桌面，输出 1920x1080/30fps H.264 低延迟流。

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

## USB

USB 仍然使用 WebSocket。先在电脑侧运行 `sender.py --host 127.0.0.1`，再运行 `usb_forward.ps1` 建立端口转发，tweak 地址填写 `127.0.0.1:8765`。端口转发命令因 iOS/越狱环境而异，脚本会直接调用已安装的 `pymobiledevice3`，不会伪造 USB 已连接状态。
