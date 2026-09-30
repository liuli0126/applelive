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

## OBS 视频源

使用 OBS 脚本插件时，不需要手动输入下面的命令。独立运行发送器可指定 OBS 虚拟摄像头：

```powershell
python sender.py --video-device "OBS Virtual Camera" --audio-device "CABLE Output (VB-Audio Virtual Cable)"
```

OBS 脚本及可执行文件的使用说明见 `../obs-plugin/README.md`。

## USB

当前版本尚未实现 USB 传输。`usb_forward.ps1` 会解释为什么普通 usbmux 正向转发不能直接用于现有 iPhone 主动连接的 LAN 协议，不会虚报 USB 已连接。
