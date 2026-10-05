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

`--audio-device` 是 FFmpeg dshow 设备名。系统声音通常需要 VB-CABLE、Voicemeeter 或声卡 Stereo Mix。独立插件开启「内录」时会替换手机麦克风；不传电脑音频时输出静音。关闭「内录」恢复手机麦克风。

## 标准拉流与本地素材

OBS 局域网模式自动启动随包的 MediaMTX 1.18.1，并将同一次 H.264 编码同时用于旧 WebSocket 通道和标准 RTMP 发布。用户提供的 `E:/服务器` 也是这个服务器。手机悬浮窗的「检测」接受 `rtmp://电脑IP:1935/live/applelive`，也支持 SRS 地址；RTSP 为 `rtsp://电脑IP:8554/live/applelive`。

独立 `.dylib` 静态包含 FFmpeg，提供相册/文件图片与视频、网络拉流、暂停/拖动/循环、内录/静音、镜像/旋转、完整/铺满、独立预览与恢复相机。源码测试和编译检查通过，真实直播 App 的采集、内录及不同系统版本须分别验证。

## USB 状态

新独立插件通过 usbmux 连接目标 App 的回环端口 8766，接收 H.264 和 PCM，不需要手机 OpenSSH 或逐台配对 SSH 密钥。Windows 仍需 Apple USB 驱动、手机信任电脑，并打开已注入的 App。协议分包、握手和清理测试通过，尚需真机 USB 验证。

旧 deb 保留 `pymobiledevice3` 转发到手机 OpenSSH 和 SSH 反向隧道方案，旧 iOS 13.3 测试手机的 USB 视频替换与 LAN 接收已实测。连接方式在 OBS 停靠面板选择，手机显示实际通道。

## 限制

- 电脑直连协议使用 H.264 Annex-B；独立插件的 FFmpeg 媒体引擎还可解码 H.265 文件和网络流。
- `BWNodeOutput` 是 Apple 私有类，不同 iOS 版本可能改名或改变方法签名；未找到该类时会自动保留原始相机帧。
- `AppleLive.plist` 的 UIKit bundle 过滤器用于让 delegate 回退 hook 有机会进入直播 App，但具体 Substrate 版本对 bundle 过滤的匹配方式需要在目标设备验证。
- 独立插件提供 `AVCaptureAudioDataOutput` 和 RemoteIO/VoiceProcessingIO 输入替换；使用其他音频采集管线的 App 仍需要适配。
- 这是越狱系统级注入，建议先在备用设备、测试直播 App 和局域网环境验证，不要直接在主力设备上升级系统后盲装。

## Full portable OBS delivery

To build a single extracted OBS folder with AppleLive already embedded, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-portable-obs.ps1 `
  -ObsRoot 'D:\OBS定制款\OBS定制款\obs studio' `
  -Output .\artifacts\AppleLive-OBS-Portable.zip
```

The builder copies the supplied OBS root, embeds AppleLive below `data\obs-plugins\AppleLive`, writes portable mode, pre-registers the dock and writes `AppleLive-Launcher.cmd`. It does not modify the source OBS folder. See `COMPETITOR_COMPARISON.md` for the reference tree analysis and the remaining native USB output work.
