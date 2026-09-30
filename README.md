# AppleLive 越狱虚拟摄像头

这是一个面向越狱 iPhone 的桌面画面/声音输入方案：Windows 端用 FFmpeg 采集桌面并编码为 H.264，iOS tweak 通过 WebSocket 接收，在 VideoToolbox 解码后替换相机帧；音频使用 float32 PCM ring buffer 替换音频采集帧。

完整下载和环境准备清单见 [DOWNLOADS.md](E:\1\applelive\DOWNLOADS.md)。

## 当前目录

- `desktop_sender/`：Windows 发送端和局域网/USB 端口转发脚本。
- `obs-plugin/`：OBS 脚本控制面板与 Windows 发送器，安装见 [OBS 插件说明](obs-plugin/README.md)。
- `ios-tweak/`：Theos + CydiaSubstrate/ElleKit tweak 源码。
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

安装后创建 `/var/mobile/Library/Preferences/com.applelive.tweak.plist`（rootless 设备也可放在 `/var/jb/var/mobile/Library/Preferences/`）：

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

当前版本只支持 LAN。USB 需要手机端监听服务或越狱侧反向 TCP 隧道，目前两者尚未接入；`desktop_sender/usb_forward.ps1` 只会提示这一限制，不会虚报 USB 已连接。

## 限制

- 本版只实现 H.264 Annex-B；不接收 H.265。
- `BWNodeOutput` 是 Apple 私有类，不同 iOS 版本可能改名或改变方法签名；未找到该类时会自动保留原始相机帧。
- `AppleLive.plist` 的 UIKit bundle 过滤器用于让 delegate 回退 hook 有机会进入直播 App，但具体 Substrate 版本对 bundle 过滤的匹配方式需要在目标设备验证。
- 音频替换走 `AVCaptureAudioDataOutput` delegate 回退入口；不同直播 App 可能使用私有音频管线，需要按目标 App 增加对应 hook。
- 这是越狱系统级注入，建议先在备用设备、测试直播 App 和局域网环境验证，不要直接在主力设备上升级系统后盲装。
