# AppleLive 单文件注入版

## 手机安装

1. OBS 选择「同一局域网」，开始传输后点击「安装手机插件」。
2. 手机连接同一路由器，用系统相机扫码，在 Safari 下载文件。
3. 通过已有虚拟相机注入器选择目标 App，导入 `AppleLive-电脑IPv4-端口.dylib`，退出并重新打开目标 App。
4. 在拍摄预览页查看画面和 AppleLive 悬浮按钮。连接方式由电脑选择；手机提供连接、断开、旋转、镜像、比例和声音开关。

同一电脑的文件可复用于多台手机。保持导出文件名，插件会自动读取电脑地址。Safari 下载时附加的 `(1)` 等数字后缀也能识别。导入器若改写文件名，可在悬浮窗设置电脑地址。电脑 IP 改变时也可在悬浮窗更新，或导出新文件并通过注入器替换本库。

局域网模式不需要 Sileo、OpenSSH、ElleKit、Substrate 或单独的配置 plist。手机仍必须具备可用的 App 注入环境，且注入器需要能成功修改、签名和运行目标 App。我们的 dylib 本身不会建立越狱或 TrollStore 环境。

## 当前验证范围

| 设备和环境 | 安装方式 | 当前结果 |
|---|---|---|
| iPhone 11 / iOS 13.3 / unc0ver + Substitute | rootful deb | 用户确认抖音 OBS 视频、USB/LAN 和连接按钮正常，画面流畅 |
| iPhone 11 / iOS 15.6 / Dopamine | rootless deb | 安装和 LAN 服务连接已确认；目标 App 画面未确认 |
| iPhone 11 / iOS 15.6 / 虚拟相机注入器 9.999 | 独立 dylib | 编译、签名、系统库依赖和手机文件传输通过；实际导入、视频和悬浮控制待确认 |
| 其他机型、iOS 16/17/18/26 | 独立 dylib | 未验证，需要确认可用注入环境及目标 App 的采集接口 |

当前库为 arm64 + 现代 arm64e，最低构建版本 iOS 15.0。iOS 13 使用单独的 rootful 包。最低版本只表示链接条件；App 的相机和音频采集实现也会影响兼容性。TikTok、独立注入 USB、电脑音频以及端到端延迟均需实测，不能由画面接收或编译成功推断。

请避免在同一 App 同时加载我们的 deb 和独立库。其他相机插件也可能覆盖同一采集接口；排查时先确认冲突来源，不自动移除已有插件。当前 USB 通道仍使用 OpenSSH 和专用密钥，USB 的免 SSH 批量安装尚未实现。

## 构建

没有 Mac 可运行 GitHub Actions 的 `Build AppleLive injector dylib`，下载 `AppleLive-Injector-iOS15` 产物。OBS Windows workflow 会调用同一构建并把库放入 `phone-plugin/AppleLive.dylib`，无需手工拼装。

本地 Theos 构建：

```sh
make -C ios-injector all FINALPACKAGE=1
ldid -S ios-injector/.theos/obj/AppleLive.dylib
python3 scripts/verify-injector-dylib.py ios-injector/.theos/obj/AppleLive.dylib
```

下载服务保留签名后的二进制字节，只修改导出名称。独立库的连接和画面控制使用 App 内通知与 App 自己的设置，状态来自当前 App 的接收器；不依赖 mediaserverd 的越狱注入。
