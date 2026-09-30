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

USB 需要 iPhone 安装 OpenSSH。电脑已有 `pymobiledevice3` 和 Windows `ssh.exe` 时，先启动 OBS 发送器，再运行：

```powershell
.\usb_forward.ps1
```

脚本通过 usbmux 连接 iPhone SSH，再建立从手机 `127.0.0.1:8765` 到电脑发送器的反向隧道。保持窗口开启。当前目标手机 SSH 22 端口未开放，因此 USB 尚未完成实机验证。
