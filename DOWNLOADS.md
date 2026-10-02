# 完整可用版本的准备清单

要生成可安装的 iOS 越狱插件并接入指定直播 App，需要同时准备下面三类环境。下载前先确认 iPhone 的 iOS 版本和越狱类型。

## 1. iPhone

必需：

- 已越狱的 iPhone，记录型号、iOS 小版本、越狱工具名称和版本。
- 与越狱类型匹配的注入框架：ElleKit、Substitute 或 libhooker，通常由 Sileo/Zebra 自动安装。
- Cydia、Sileo 或 Zebra，用来安装最终的 `.deb`。
- 仅 USB 模式需要 OpenSSH。目标 iPhone 当前没有开放 SSH 22 端口，需从 Cydia 安装并启动。

建议：

- NewTerm 3 或 Filza，用来查看 `/var/mobile/Library/Preferences/` 和 tweak 日志。
- PreferenceLoader，后续可以把 server 地址和开关放进系统设置。

需要确认的设备字段：

```text
机型：
iOS 版本：
越狱工具和版本：
rootless 还是 rootful：
目标直播 App 和版本：
```

## 2. iOS 插件构建机

推荐使用 macOS（Intel 或 Apple Silicon）：

- Xcode Command Line Tools。
- 与目标部署版本兼容的 iPhoneOS SDK。当前 Makefile 使用 iOS 15.0 作为最低部署版本；如果设备低于 iOS 15，需要调整目标版本。
- Theos：<https://github.com/theos/theos>
- `ldid`、`make`、`dpkg`、`perl`。Homebrew 可以安装这些工具。

示例：

```bash
git clone --recursive https://github.com/theos/theos.git "$HOME/theos"
brew install ldid make dpkg perl
export THEOS="$HOME/theos"
cd ios-tweak
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

Windows 只能用于桌面发送端。你没有 Mac 时，不需要购买 Mac：项目已经提供 GitHub Actions 工作流，会使用 GitHub 的 macOS runner 编译 rootless `.deb`。需要一个 GitHub 账号，并把项目上传到自己的仓库后，在 Actions 页面手动运行 `Build AppleLive rootless deb`，完成后下载构建产物。

本地 Mac 仍然是调试私有相机 hook 最方便的方式，但不是生成第一版包的硬性条件。

## 目标设备说明

目前展示的设备是 iPhone 11 / iOS 13.3 / unc0ver + Substitute，应使用独立的 rootful 包；此前按 iOS 15.6 / Dopamine rootless 构建的包不能安装到这台设备。见 `IOS13_ROOTFUL.md`。该包已内置连接地址，不需单独传配置文件。

LordVCAM 标注的多个系统范围不等于一个 tweak 二进制可以无差别覆盖所有系统。本项目当前优先验证 iOS 13.3；其他版本需要分别编译和测试相机注入点。详细策略见 `VERSION_SUPPORT.md`。

## 3. Windows 桌面发送端

必需：

- Python 3.10 或更新版本。
- FFmpeg Windows full build，要求包含 `gdigrab` 和 `dshow`。
- Windows 防火墙允许 TCP 8765 入站（LAN 模式）。

安装命令：

```powershell
cd desktop_sender
py -3 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python protocol_test.py
```

电脑系统声音需要额外安装一个虚拟音频设备，推荐 VB-CABLE 或 Voicemeeter。然后用下面的命令查看 dshow 设备名：

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

## 4. 连接方式

LAN 模式现在可以直接使用：

```powershell
python sender.py --host 0.0.0.0 --port 8765 --audio-device "CABLE Output (VB-Audio Virtual Cable)"
```

USB 模式复用 LAN WebSocket 协议，电脑通过 `pymobiledevice3 usbmux forward` 连手机 OpenSSH，再通过 SSH `-R` 将手机的 `127.0.0.1:8765` 接回电脑发送器。电脑已有 `pymobiledevice3` 和 `ssh.exe`；手机需安装 OpenSSH。运行 `desktop_sender/usb_forward.ps1` 后保持窗口开启。当前手机 SSH 22 端口未开放，USB 尚未完成实机验证。

## 5. 还需要你提供的信息

其他设备或直播 App 适配时，请提供以下信息：

1. iPhone 型号、iOS 精确版本。
2. 越狱工具和版本，rootless/rootful。
3. 要支持的直播 App 名称和版本（例如抖音、TikTok、快手）。
4. 是否必须 USB；如果 LAN 可先用，优先先完成 LAN 闭环。
5. 目标分辨率和帧率，例如 1920x1080/30fps 或 1280x720/30fps。
