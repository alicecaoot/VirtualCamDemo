# iOS 摄像头替换覆盖评估（打包前确认）

## 一句话结论

| 场景 | 能否替换 |
|------|----------|
| 已注入的目标 App 内：`AVCaptureVideoPreviewLayer` 预览 | **能** |
| 已注入的目标 App 内：`AVCaptureVideoDataOutput` 实时帧 | **能** |
| 已注入的目标 App 内：`AVCapturePhotoOutput` / `StillImageOutput` 拍照 | **能（常规路径）** |
| 未越狱、仅安装 VirtualCamDemo.ipa | **仅本 App 内嵌虚拟预览**，不改其它 App |
| 系统「相机」App / 微信等未在 Filter 中的进程 | **默认不能**（需写 Bundle ID 并越狱注入） |
| 全局所有 App 的摄像头（系统级） | **不能**（本项目不做内核/mediad 替换） |

本方案是 **进程内 AVFoundation hook + 视频 IOSurface**，不是 Android 那种系统 Camera HAL 替换。

## 已实现 Hook

1. **预览** `AVCaptureVideoPreviewLayer`  
   overlay `CALayer.contents = IOSurface`
2. **实时帧** `AVCaptureVideoDataOutput`  
   shim delegate，改 `CMSampleBuffer` 像素
3. **会话** `AVCaptureSession` start/stop  
   控制推流
4. **拍照** `AVCapturePhotoOutput` + `AVCaptureStillImageOutput`  
   处理结果前写入虚拟帧
5. **单一时钟**  
   有 DataOutput 时：一帧 sample = 一帧视频 + 同步预览  
6. **双缓冲**  
   防撕裂

## 有限 / 未覆盖

- `AVCaptureMovieFileOutput` 直接录像封装  
- ReplayKit、部分 WebRTC、自研 Metal 读 camera texture  
- `UIImagePickerController` 系统 UI（可能在别的进程）  
- 未列出 Bundle 的第三方 App  
- 非越狱设备上的任意 App 注入  

## 视频文件查找顺序

1. `NSUserDefaults` key `MFTVideoPath`  
2. `Documents/demo.mp4`、`Documents/virtual.mp4`  
3. Caches / tmp  
4. App Bundle 内 `demo.mp4`  
5. `/var/mobile/Media/Downloads/demo.mp4`（越狱且有权限时）

## 与「全面替换」的关系

- **全面（目标 App 内 AVFoundation 主路径）**：预览 + 帧回调 + 拍照 → 已接。  
- **全面（整机所有 App）**：需要 Filter 扩大 + 越狱，且系统相机仍可能走不到这些 hook → **不承诺**。  
- **VirtualCamDemo.ipa**：用于验证链路；真正 hook 你自己的 App 用 **tweak deb** 并改 plist Bundle ID。
