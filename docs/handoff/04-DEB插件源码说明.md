# DEB 插件源码交接

这份目录对应 iOS 15+ Dopamine/rootless 和历史 rootful 的 DEB 打包路线。源码包不包含任何 Apple 账号、设备配对数据或私钥。

## 当前使用的“万能版本.deb”更新（2026-10-21）

当前交付是带越狱自动加载的完整安装包：`交付文件/万能版本.deb`，包 ID 为 `com.applelive.full`，版本从原完整包的 `0.1.13-usb1` 升为 `0.1.13-usb2`。安装后由越狱注入环境自动加载到相机、抖音、TikTok 和微信；无需手动导出或使用注入器。覆盖安装完成后完全退出并重新打开目标 App；若包管理器要求重载界面，按提示操作。

两处 dylib 同时更新为已通过 USB 防闪回回归且包含画面监控的构建：`/var/jb/Library/AppleLive/AppleLive.dylib` 和 `/var/jb/Library/MobileSubstrate/DynamicLibraries/AppleLive.dylib`。原服务程序、配套 App、自动加载过滤配置、依赖、冲突/替换声明、启动/卸载脚本、路径和权限逐项保持不变。

    python3 scripts/update-uvc-package-plugin.py \
      path/to/original.deb path/to/fixed/AppleLive.dylib \
      output/万能版本.deb --revision 2 --report output/verification.json
    python3 scripts/verify-uvc-service.py output/万能版本.deb path/to/fixed/AppleLive.dylib \
      --package-id com.applelive.full

修复 dylib 来自 `dc43aa4`、CI `39215618040` 第 2 次成功执行。其 SHA256 为 `8ebd4aa3a6068da282799c373edb31199a621c1684b733a3778ea83a83ae7067`。

更新后的完整 DEB 为 `9,360,374` 字节（约 8.93 MiB），SHA256 为 `24287e287dcfe98e76a895ba70b3369b36714913afe3bab89e2fef510289ed0f`。打包器核对所有 tar 项的内容与权限，只允许 control 的 Version 和两份 dylib 改变。完整包版本与配套服务 App 的 `0.1.1` 版本分别维护。

更新脚本也能维护独立的 `com.applelive.uvchost` 服务包，但该服务包只带导出副本，没有自动加载的 dylib 和过滤配置，不能作为当前完整安装包交付。原约 8.87 MiB 的 `0.1.13-usb1` 完整包才是本次升级的来源。

已验证旧 dylib、未提高版本、缺少自动加载副本、错误目标 App 和仅一份副本更新均会被拒绝，并保留原输出。现有完整包构建器可以重现相同的 DEB 字节。实际手机长时间直播验收仍由用户进行。

## 三条构建路线

### 1. 独立注入器 rootless DEB

ios-injector/ 负责构建独立 AppleLive.dylib。它由注入器加载到目标 App，不把 UIKit/App 面板代码注入 mediaserverd。

    python3 scripts/verify-injector-dylib.py path/to/AppleLive.dylib
    python3 scripts/build-rootless-injector-deb.py \
      path/to/AppleLive.dylib \
      output/AppleLive-Dopamine-rootless.deb

包装入口：scripts/build-rootless-injector-deb.py。
它生成 com.applelive.injector，把 dylib 和 ElleKit/越狱过滤 plist 放到 /var/jb/Library/MobileSubstrate/DynamicLibraries/。

### 2. 完整 rootless DEB（注入器 + 手机 UVC 服务）

ios-uvc-service/ 是手机本地外接 UVC 服务；scripts/build-uvc-service.sh 编译并签名服务，然后 scripts/build-full-rootless-deb.py 把服务和独立 dylib 合并成一个 DEB。

    bash scripts/build-ios-uvc.sh
    bash scripts/build-uvc-service.sh
    python3 scripts/verify-uvc-service.py \
      injector-artifact/AppleLive-UVC-Service-rootless.deb \
      injector-artifact/AppleLive.dylib
    python3 scripts/build-full-rootless-deb.py \
      injector-artifact/AppleLive.dylib \
      injector-artifact/AppleLive-UVC-Service-rootless.deb \
      injector-artifact/AppleLive-Full-rootless.deb
    python3 scripts/verify-uvc-service.py \
      injector-artifact/AppleLive-Full-rootless.deb \
      injector-artifact/AppleLive.dylib --package-id com.applelive.full

这条路线需要 macOS、iPhoneOS SDK、Theos、ldid、dpkg 和已构建的 libusb/libuvc。ios-uvc-service/ 内的 entitlements、LaunchDaemon、安装/卸载脚本都属于 DEB 源码的一部分。

### 3. 历史 tweak 包路线

ios-tweak/Makefile、ios-tweak/control、ios-tweak/postinst.rootless 和 ios-tweak/control.rootful 是旧的越狱 tweak 包入口。它把核心相机替换代码按 Theos tweak 方式编译，rootless 与 iOS 13 rootful 的包元数据不同。

当前交接重点是 iOS 15+ 的独立 dylib/rootless 路线；旧 rootful 文件保留用于维护历史设备，不代表当前成品已经覆盖所有 iOS 13 越狱组合。

## 源码对应关系

| 目录/文件 | 作用 |
|---|---|
| ios-injector/ | 独立 dylib、面板、RTMP/RTSP、USB 接收、内录音频、外接 UVC |
| ios-tweak/ | 共享相机替换、解码、音频环、控制、颜色和鱼眼代码；旧 tweak 入口 |
| ios-uvc-service/ | 手机端 UVC 主机服务、配对 App、LaunchDaemon 和 DEB 控制脚本 |
| scripts/build-rootless-injector-deb.py | 独立注入器 rootless DEB 打包器 |
| scripts/build-full-rootless-deb.py | 合并 UVC 服务和 dylib 的完整 rootless DEB 打包器 |
| scripts/build-uvc-service.sh | 编译、签名并生成 UVC service DEB |
| scripts/verify-injector-dylib.py | 检查 dylib 架构、部署版本和导入依赖 |
| scripts/verify-uvc-service.py | 检查 DEB 布局、权限、签名、entitlements 和 dylib 是否匹配 |
| scripts/update-uvc-package-plugin.py | 在原服务包或完整包内更新所有 dylib 副本，逐项保留其他内容并提高修订号 |
| scripts/relink-injector.sh | 使用 relink 目录中的对象和静态库重新链接 dylib |
| scripts/relink-uvc-service.sh | 重新链接 UVC 服务二进制 |

## 依赖与限制

obs-plugin/phone-plugin/AppleLive-relink.tar.gz 是当前手机构建配套的对象文件、FFmpeg/UVC 静态库、依赖源码和 relink 脚本。它不替代 macOS、Theos、SDK 和 ldid。

当前手机参考 dylib 为 arm64 + arm64e fat binary，arm64 部署目标 iOS 14，arm64e 部署目标 iOS 15。二进制目标版本不等于每个系统版本都有稳定的越狱和注入环境。

DEB 构建时必须使用同一份 AppleLive.dylib 配套服务包。verify-uvc-service.py 会拒绝嵌入 dylib 与服务包不一致的组合；不要把历史目录中的旧 .deb 与当前 dylib 混用。

当前源码包包含完整自研源码和第三方依赖许可证；FFmpeg、libusb、libuvc、fishhook 的许可证和来源说明随 phone-plugin 目录保留。
