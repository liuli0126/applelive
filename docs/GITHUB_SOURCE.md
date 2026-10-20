# GitHub 源码交接（2026-10-18）

仓库：`liuli0126/applelive`，公开（2026-10-20 按用户要求调整），交接入口为 `main` 分支。
仓库收录当前电脑端和手机端的项目源码、品牌资源、测试及构建脚本。

## 代码目录

| 目录 | 内容 |
| --- | --- |
| `native-obs-usb/` | OBS 原生音视频输出、USB 中继、福煋 OBS 启动器 |
| `desktop_sender/` | 停靠面板服务、OBS 控制、局域网及 USB 连接管理 |
| `obs-plugin/` | Lua 加载器、停靠窗口页面、安装更新脚本、MediaMTX 配置 |
| `ios-injector/` | 手机独立 dylib：悬浮窗、媒体接收、内录和账号监控 |
| `ios-tweak/` | 手机共享解码与画面替换代码、传统 rootless/rootful DEB 入口 |
| `ios-uvc-service/` | 旧外接相机实验服务源码；当前面板的外接相机入口已移除 |
| `scripts/` | 编译、DEB 打包、整包生成、回归验证和交接脚本 |
| `.github/workflows/` | Windows、iOS dylib 和 DEB 云端构建流程 |
| `assets/brand/` | 福煋图标资源 |

手机账号监控包含账号安全验证、直播间违规整改、主播暂时离开提醒，支持修改手机名称和直播账号。构建配置保存在仓库 Actions Secret `APPLELIVE_MOBILE_ALERT_URL` 中；不把真实地址或令牌写进源码。本地编译时需在本地生成忽略文件 `ios-injector/ALMonitorConfig.h`，格式参照手机构建工作流。

## 从源码构建

1. 在 GitHub **Actions** 运行 **Build AppleLive injector dylib**，选择 `main`，下载 `AppleLive-Injector-iOS14` 产物。该产物名沿用历史名称，兼容范围见 `COMPATIBILITY.md` 和 `VERSION_SUPPORT.md`。
2. 电脑插件运行 **Build AppleLive OBS plugin**；可填写同一仓库成功的手机构建 `phone_run_id`，留空则先构建手机端。组合流程会继承仓库的监控 Secret。
3. 包含 OBS 本体的客户整包需准备 OBS 宿主，再使用 `scripts/build-portable-obs.ps1`。原生模块当前以 OBS 30.2.3 x64 为 ABI 基线。
4. DEB 安装包的不同构建路线见 [DEB 插件源码说明](handoff/04-DEB插件源码说明.md)；完整编译步骤见 [编译与出包](handoff/02-编译与出包.md)。

仓库不保存运行包、第三方 OBS 本体、驱动安装器、编译产物、个人运行配置或本机工作目录。FFmpeg、MediaMTX、Theos、SDK 等依赖由构建流程获取或按编译说明准备。媒体测试样本和品牌图片属于源码测试/资源的一部分，随仓库保存。

`docs/handoff/` 中标注 2026-10-13 的文档和哈希是当时离线交接包的记录；其“已随源码包提供”的二进制依赖不包含在这个 Git 仓库中。当前手机源码已包含 2026-10-18 的监控功能，先前成品哈希不代表当前源码重新编译的产物。
