# DEB 插件源码交接

这份目录对应 iOS 15+ Dopamine/rootless 和历史 rootful 的 DEB 打包路线。源码包不包含任何 Apple 账号、设备配对数据或私钥。

## 三条构建路线

### 1. 独立注入器 rootless DEB

ios-injector/ 负责构建独立 AppleLive.dylib。它由注入器加载到目标 App，不把 UIKit/App 面板代码注入 mediaserverd。

    python3 scripts/verify-injector-dylib.py path/to/AppleLive.dylib
    python3 scripts/build-rootless-injector-deb.py \
      path/to/AppleLive.dylib \
      output/AppleLive-Dopamine-rootless.deb
    python3 scripts/verify-rootless-injector-deb.py \
      output/AppleLive-Dopamine-rootless.deb path/to/AppleLive.dylib

包装入口：scripts/build-rootless-injector-deb.py。
它生成 com.applelive.injector，把 dylib 和 ElleKit/越狱过滤 plist 放到 /var/jb/Library/MobileSubstrate/DynamicLibraries/。

2026-10-21 的安装包版本为 `0.1.14`，包含 USB 断帧/自动重连时保留上一帧、阻止原始摄像头帧透传及预览保留修复。DEB 直接复用已通过原生回归的独立 dylib，不另外编译一套媒体逻辑；打包后检查两份架构的修复标记及嵌入文件是否逐字节一致，校验失败不会覆盖已存在的成品。

过滤范围是系统相机、抖音、TikTok 和微信，排除 `mediaserverd` 等系统服务。包 ID 保持 `com.applelive.injector`，版本高于旧 `0.1.13-standalone1`；与拥有相同加载路径的 `com.applelive.tweak`、`com.applelive.full` 声明冲突和替换。安装后需要完全退出并重新打开目标 App。若以前用 TrollFools 等工具手动注入过同类 dylib，应先在原工具中撤销该注入，避免与 DEB 重复加载。

主手机构建现在自动生成并校验 `AppleLive-Dopamine-rootless.deb`。若已有成功的手机构建，可运行 **Package verified injector as Dopamine DEB**，把该构建的数字 run ID 填入 `phone_run_id`；它只下载已有二进制并打包，用真实 `dpkg-deb` 验证和解包，不重新编译媒体代码。

交付目录的历史 `万能版本.deb` 实际为 `com.applelive.uvchost` 服务包，不能当作自动注入的 DEB，也不代表支持所有 iOS/越狱。新的手机安装入口为 `福煋推流插件-Dopamine.deb`，仅适用于 iOS 15+ 的兼容 rootless 越狱环境。用户当前使用 Dopamine；iOS 13/rootful 不使用这个包。

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
| scripts/verify-rootless-injector-deb.py | 检查实际注入 DEB 的路径、过滤范围、升级冲突、双架构修复标记及嵌入字节 |
| scripts/verify-uvc-service.py | 检查 DEB 布局、权限、签名、entitlements 和 dylib 是否匹配 |
| scripts/relink-injector.sh | 使用 relink 目录中的对象和静态库重新链接 dylib |
| scripts/relink-uvc-service.sh | 重新链接 UVC 服务二进制 |

## 依赖与限制

obs-plugin/phone-plugin/AppleLive-relink.tar.gz 是当前手机构建配套的对象文件、FFmpeg/UVC 静态库、依赖源码和 relink 脚本。它不替代 macOS、Theos、SDK 和 ldid。

当前手机参考 dylib 为 arm64 + arm64e fat binary，arm64 部署目标 iOS 14，arm64e 部署目标 iOS 15。二进制目标版本不等于每个系统版本都有稳定的越狱和注入环境。

DEB 构建时必须使用同一份 AppleLive.dylib 配套服务包。verify-uvc-service.py 会拒绝嵌入 dylib 与服务包不一致的组合；不要把历史目录中的旧 .deb 与当前 dylib 混用。

当前源码包包含完整自研源码和第三方依赖许可证；FFmpeg、libusb、libuvc、fishhook 的许可证和来源说明随 phone-plugin 目录保留。
