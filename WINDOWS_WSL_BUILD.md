# 没有 Mac 和 GitHub 账号时的构建方法

可以在 Windows 上使用 WSL2 Ubuntu 编译 rootless `.deb`。这条路线不需要 Apple 账号，也不需要 GitHub 账号；公开的 Theos 和 SDK 仓库可以直接克隆。

## 1. 安装 WSL2

用管理员 PowerShell 执行：

```powershell
wsl --install -d Ubuntu-22.04
```

重启电脑后打开 Ubuntu，创建 Linux 用户和密码。

## 2. 进入项目

当前项目位于 `E:\1\applelive` 时，在 Ubuntu 中运行：

```bash
cd /mnt/e/1/applelive
chmod +x scripts/build-wsl.sh
```

## 3. 编译

```bash
./scripts/build-wsl.sh
```

第一次会下载 Theos 和公开 SDK，耗时较长。脚本完成后，包在：

```text
ios-tweak/packages/*.deb
```

如果提示 `ldid is missing`，需要安装 Linux 版 `ldid` 并放进 `PATH`。`ldid` 只负责越狱包签名，不需要 Apple 开发者证书。

## 4. 安装到手机

构建出来的 deb 可以通过 Sileo/Zebra 安装。没有 Sileo/Zebra 时，需要先安装一个包管理器，或者通过 OpenSSH 复制到手机后使用对应的 rootless `dpkg` 路径安装。

## 注意

- WSL 可以编译，但不能替代真实 iPhone 测试。
- iOS 私有相机 hook 必须在你的 iPhone 11 / iOS 15.6 上安装后验证。
- 当前 USB 监听器仍需完成；LAN 发送端可以先测试。
