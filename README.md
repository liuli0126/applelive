# AppleLive 越狱虚拟摄像头

这是一个面向越狱 iPhone 的桌面画面/声音输入方案：Windows 端用 FFmpeg 采集桌面并编码为 H.264，iOS tweak 通过 WebSocket 接收，在 VideoToolbox 解码后替换相机帧；音频使用 float32 PCM ring buffer 替换音频采集帧。

完整下载和环境准备清单见 [DOWNLOADS.md](E:\1\applelive\DOWNLOADS.md)。

## 当前目录

- `desktop_sender/`：Windows 发送端和局域网/USB 端口转发脚本。
- `obs-plugin/`：OBS 浏览器停靠面板、Lua 控制桥接与 Windows 发送器，安装见 [OBS 插件说明](obs-plugin/README.md)。
- `ios-tweak/`：Theos + CydiaSubstrate/ElleKit tweak 源码。
- `ios-injector/`：单文件 App 注入库，不链接外部注入框架，使用说明见 [注入器交付](ios-injector/README.md)。
- `findings.md`：协议和越狱注入点记录。

## 运行链路

```text
OBS program or Windows desktop + audio device
          |
          | FFmpeg H.264 / float32 PCM
          v
   WebSocket :8765
       | LAN
       v
iOS tweak -> VideoToolbox -> latest CVPixelBuffer
       |                         |
       +-> mediaserverd BWNodeOutput hook
       +-> AVCapture delegate fallback
```

## 构建 iOS tweak

批量手机优先使用 OBS 导出的 `.dylib`：在「安装手机插件」中扫码或下载，通过手机已有注入器导入目标 App。文件带上电脑地址，首次打开时自动保存到该 App。局域网使用不需要 SSH，也无需安装我们的 deb。独立注入的实际兼容范围见 [注入器交付](ios-injector/README.md)，不能根据最低构建版本推断所有新 iOS 均支持。

在 macOS/Linux 安装 Theos 和 iPhoneOS SDK 后：

```sh
cd ios-tweak
make package FINALPACKAGE=1
```

生成的 deb 需要通过 Sileo、Zebra 或 `dpkg -i` 安装。`control` 声明了 rootless/rootful 常见的注入依赖；实际设备还需要对应的 Substrate 兼容层（ElleKit、libhooker 或 Substitute）。

没有 Mac 时，可以把项目上传到 GitHub，运行 `.github/workflows/build-ios-tweak.yml`，从 Actions artifact 下载 rootless `.deb`。这个方式适合第一次构建；真实设备上的相机私有 API 调试仍需要反复安装和查看日志。

没有 GitHub 账号时，使用 [WINDOWS_WSL_BUILD.md](E:\1\applelive\WINDOWS_WSL_BUILD.md) 在 Windows WSL2 Ubuntu 中本地编译。

有 GitHub 账号时，直接按 [GITHUB_BUILD.md](E:\1\applelive\GITHUB_BUILD.md) 上传项目并运行 Actions，无需 Mac。

## iOS 13.3 / unc0ver

iPhone 11 / iOS 13.3 / unc0ver + Substitute 使用单独的 rootful 包，不能安装上面的 rootless `.deb`。构建与安装步骤见 [IOS13_ROOTFUL.md](IOS13_ROOTFUL.md)。

0.1.13 起，安装包包含 `AppleLiveSetup` 配置工具。电脑完成 SSH 配对后，可直接设置局域网地址；手机相机服务会接收通知并保存，无需手动编辑文件。rootless 示例：

```sh
/var/jb/usr/bin/AppleLiveSetup 192.168.1.45:8765
```

rootful 使用 `/usr/bin/AppleLiveSetup`。这只更新电脑地址并恢复接收，连接方式仍由 OBS 选择。工具执行成功不代表目标 App 的画面替换已验证。

旧版本使用 `/var/mobile/Library/Preferences/com.applelive.tweak.plist`（rootless 也可放在 `/var/jb/var/mobile/Library/Preferences/`），但相机服务可能无法直接读取这些文件。iOS 13 rootful 一体包内置了默认地址：

```plist
{
    enabled = 1;
    server = "192.168.1.20:8765";
    audioEnabled = 1;
}
```

然后重启 `mediaserverd` 或重启设备，让注入器重新加载配置。

## 局域网测试

```powershell
cd desktop_sender
python -m pip install -r requirements.txt
python sender.py --host 0.0.0.0 --port 8765 --audio-device "CABLE Output"
```

`--audio-device` 是 FFmpeg dshow 设备名。系统声音通常需要 VB-CABLE、Voicemeeter 或声卡 Stereo Mix；不传该参数时，视频仍传输，但 tweak 保留手机原始麦克风。

## USB 状态

USB 通过 `pymobiledevice3` 正向转发至 iPhone OpenSSH，再由 SSH 建立反向隧道，让手机从 `127.0.0.1:8765` 连接电脑发送器。测试手机已完成 OpenSSH 和密钥配对，USB 视频替换与 LAN 接收均已实测。0.1.9 起连接方式只在 OBS 停靠面板选择：USB 模式只监听回环，LAN 模式在握手时拒绝回环连接；手机自动跟随，浮窗显示实际通道。声音、TikTok 与其他 iOS 版本仍需独立实测。

## 限制

- 本版只实现 H.264 Annex-B；不接收 H.265。
- `BWNodeOutput` 是 Apple 私有类，不同 iOS 版本可能改名或改变方法签名；未找到该类时会自动保留原始相机帧。
- `AppleLive.plist` 的 UIKit bundle 过滤器用于让 delegate 回退 hook 有机会进入直播 App，但具体 Substrate 版本对 bundle 过滤的匹配方式需要在目标设备验证。
- 音频替换走 `AVCaptureAudioDataOutput` delegate 回退入口；不同直播 App 可能使用私有音频管线，需要按目标 App 增加对应 hook。
- 这是越狱系统级注入，建议先在备用设备、测试直播 App 和局域网环境验证，不要直接在主力设备上升级系统后盲装。
