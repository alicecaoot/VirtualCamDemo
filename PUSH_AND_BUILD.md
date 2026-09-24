# 用 GitHub Actions 打包 IPA 并下到桌面

当前 Windows 已准备好源码与 workflow，但 **本机未登录 GitHub**（无 `GH_TOKEN` / `gh auth`），无法代替你推送仓库或下载 artifact。

## 1. 登录并创建仓库

```powershell
$gh = "C:\Users\Administrator\AppData\Local\gh\gh.exe"
# 浏览器登录
& $gh auth login

cd C:\Users\Administrator\MyFirstTweak
& $gh repo create VirtualCamDemo --public --source=. --remote=origin --push
```

或已有空仓库：

```powershell
cd C:\Users\Administrator\MyFirstTweak
git remote add origin https://github.com/<你的用户名>/VirtualCamDemo.git
git push -u origin main
```

## 2. 等 CI 跑完

打开：`https://github.com/<你的用户名>/VirtualCamDemo/actions`  
Workflow：`Build VirtualCamDemo IPA`（macos-14 + Theos）

## 3. 下到桌面

```powershell
$env:GH_TOKEN = "你的token"   # 或先 gh auth login
cd C:\Users\Administrator\MyFirstTweak
.\scripts\download_ipa_to_desktop.ps1 -Owner <你的用户名> -Repo VirtualCamDemo
```

桌面得到：`VirtualCamDemo.ipa`

## 4. 安装

- TrollStore / AltStore 等侧载  
- 将 `demo.mp4` 放入：文件 App → 我的 iPhone → VirtualCamDemo  

## 摄像头覆盖

见 `CAMERA_COVERAGE.md`。  
IPA = 演示 App；要 hook 其它自己的 App = 越狱装 tweak deb 并改 Bundle ID。
