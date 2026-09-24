# MyFirstTweak / VirtualCamDemo

视频读帧 → 双缓冲 IOSurface → 单一时钟 hook 相机预览。

## 目录

```text
MyFirstTweak/
├── iosurface_buffer.{h,c}     # IOSurface 工具
├── video_to_iosurface.{h,m}   # 视频逐帧 → IOSurface
├── tweak/                     # 越狱 Tweak（注入你的 App）
│   ├── Tweak.x
│   ├── Makefile
│   ├── control
│   └── MyFirstTweak.plist
├── app/                       # 可打 IPA 的演示 App
│   ├── CameraViewController.m
│   ├── Makefile
│   ├── Info.plist
│   └── entitlements.plist
├── Makefile                   # aggregate: tweak + app
├── build_ipa.sh               # macOS 上一键出 IPA
└── dist/                      # build_ipa.sh 输出
```

## 重要限制（请先读）

1. **Windows 本机无法编译出能在 iPhone 上跑的 IPA**  
   需要 macOS + Xcode iOS SDK + Theos，才能生成 arm64 Mach-O。
2. **Android APK ≠ iOS IPA**  
   `VCAM_GUARD_LD14_FIXED.apk` 不能转换成 iPhone 应用。
3. **Tweak `.deb` 不是 IPA**  
   Tweak 装在越狱系统里注入其它进程；IPA 是独立 App。

本仓库提供：

| 产物 | 命令 | 用途 |
|------|------|------|
| `VirtualCamDemo.ipa` | `./build_ipa.sh`（Mac） | 演示 App，可 TrollStore/侧载 |
| `com.yourname.myfirsttweak_*.deb` | `make package` | 越狱 hook 你自己的 App |

## 在 Mac 上打 IPA

```bash
# 安装 Theos 后：
export THEOS=/opt/theos
cd MyFirstTweak
chmod +x build_ipa.sh
./build_ipa.sh
# 输出: dist/VirtualCamDemo.ipa
```

把 `demo.mp4` 放到：

```text
Files → 我的 iPhone → VirtualCamDemo → demo.mp4
```

（Info.plist 已开 `UIFileSharingEnabled`。）

App 内嵌本地虚拟预览（`kEmbedLocalVirtualPreview=YES`）：  
即使不装 tweak，也会在相机回调里用视频帧盖住预览（单一时钟自测）。

## 越狱 Tweak

```bash
export THEOS=/opt/theos
cd MyFirstTweak/tweak
# 编辑 MyFirstTweak.plist 的 Bundle ID
# 编辑 Makefile 的 INSTALL_TARGET_PROCESSES
make package install
```

Tweak 使用 **Camera 单一时钟**：每帧 `didOutputSampleBuffer` 内  
advance 视频 → 画 SampleBuffer → 同 gen 刷新 Preview overlay。

## 配置

- 视频文件名：`demo.mp4`
- Tweak 时钟：`kMFTClockSource`（默认 `MFTClockSourceCamera`）
- App 本地虚拟：`kEmbedLocalVirtualPreview`
