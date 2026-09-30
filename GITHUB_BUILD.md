# GitHub Actions 构建步骤

## 1. 创建空仓库

在 GitHub 新建一个仓库，例如 `applelive`。可以设为 Private，不要勾选自动生成 README、`.gitignore` 或 License。

## 2. 从 Windows 上传当前项目

先安装 Git for Windows：<https://git-scm.com/download/win>

在 PowerShell 执行：

```powershell
cd E:\1\applelive
git init
git add .
git commit -m "Initial AppleLive tweak and desktop sender"
git branch -M main
git remote add origin https://github.com/你的用户名/applelive.git
git push -u origin main
```

GitHub 要求登录时，使用浏览器登录或 Personal Access Token，不要把密码写进命令行。

## 3. 启动构建

打开仓库的 **Actions** 页面，选择 **Build AppleLive rootless deb**，点击 **Run workflow**。构建完成后打开成功的运行记录，在 **Artifacts** 下载 `AppleLive-rootless-deb`。

## 4. 安装到 Dopamine iPhone

当前目标是 iPhone 11 / iOS 15.6 / Dopamine rootless。需要手机中有 Sileo 或 Zebra，并安装 ElleKit。拿到 `.deb` 后，可以通过 OpenSSH 复制到手机，再用 Sileo 安装；安装后重启 SpringBoard 和 `mediaserverd`。

## 5. 首次配置

在手机创建：

```text
/var/jb/var/mobile/Library/Preferences/com.applelive.tweak.plist
```

内容：

```plist
{
    enabled = 1;
    server = "电脑局域网IP:8765";
    audioEnabled = 1;
}
```

第一次建议先走 LAN 验证画面和音频。USB 监听器还需要完成后再切换 USB，避免把传输和注入问题混在一起排查。
