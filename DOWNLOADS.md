# 完整可用版本的准备清单

要生成可安装的 iOS 越狱插件并接入指定直播 App，需要同时准备下面三类环境。下载前先确认 iPhone 的 iOS 版本和越狱类型。

## 1. iPhone

必需：

- 已越狱的 iPhone，记录型号、iOS 小版本、越狱工具名称和版本。
- 与越狱类型匹配的注入框架：ElleKit、Substitute 或 libhooker，通常由 Sileo/Zebra 自动安装。
- Sileo 或 Zebra，用来安装最终的 `.deb`。
- OpenSSH，方便通过 USB/LAN 部署、读取日志和重启 `mediaserverd`。

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

你提供的 iPhone 11 / iOS 15.6 是第一目标。这个组合通常使用 Dopamine 2 rootless，但请先在手机上确认是否已经安装 Sileo/Zebra 和 ElleKit；不要仅凭型号下载越狱包。

LordVCAM 标注的多个系统范围不等于一个 tweak 二进制可以无差别覆盖所有系统。本项目会先完成 iOS 15.6，再为 iOS 17/18 和后续版本增加独立的相机注入适配器。详细策略见 `VERSION_SUPPORT.md`。

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

USB 模式需要把架构切换为“手机端监听 WebSocket，电脑通过 usbmux 正向连接”。这样可以使用 `pymobiledevice3 usbmux forward`，不依赖不确定的反向隧道；当前代码的 LAN 模式是手机主动连接电脑，USB 监听器仍需针对第一目标设备实现和实测。

## 5. 还需要你提供的信息

下载前请回复以下内容，才能把插件编译目标、注入过滤器、部署命令和 USB 方案固定下来：

1. iPhone 型号、iOS 精确版本。
2. 越狱工具和版本，rootless/rootful。
3. 要支持的直播 App 名称和版本（例如抖音、TikTok、快手）。
4. 是否必须 USB；如果 LAN 可先用，优先先完成 LAN 闭环。
5. 目标分辨率和帧率，例如 1920x1080/30fps 或 1280x720/30fps。
