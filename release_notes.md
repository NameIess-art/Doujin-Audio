# Doujin Audio 0.20.2 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。应用仅接受由本版本创建的 `.dabackup` 备份，不提供旧数据或旧备份格式的自动迁移。

## 服务与稳定性加固

- **前台播放服务生命周期与恢复**：加固 Android 原生播放服务的前台启动与崩溃恢复机制，确保通知栏与音频会话状态在后台切换时更稳定。
- **界面语言选择器宽度适配**：优化设置页面界面语言下拉菜单的最大宽度约束，避免不同屏幕尺寸下的排版拉伸。

## 交互体验与细节微调

- **媒体库编辑项尺寸与触控区域**：优化本地媒体库编辑与整理界面的列表项高度与点击热区，提升触控操作的舒适度与精准度。
- **卡片圆角与手势交互微调**：细化媒体库作品卡片与弹窗界面的圆角过渡，提升手势滑动与交互响应体验。
- **骨架屏占位布局精准对齐**：对齐媒体库骨架屏占位元素与真实卡片操作按钮位置，消除数据加载完成时的视觉跳动。

## 发布资产

```text
DoujinAudio-android-universal-<tag>.apk
DoujinAudio-android-universal-<tag>.apk.sha256
DoujinAudio-android-arm64-<tag>.apk
DoujinAudio-android-arm64-<tag>.apk.sha256
DoujinAudio-android-armv7-<tag>.apk
DoujinAudio-android-armv7-<tag>.apk.sha256
DoujinAudio-android-x64-<tag>.apk
DoujinAudio-android-x64-<tag>.apk.sha256
```

普通 Android 用户可下载 universal APK。现代手机可选择 arm64，旧款 32 位 ARM 设备选择 armv7，x86_64 仅用于对应设备或模拟器。所有 APK 都附带同名 `.sha256`，并由 GitHub Actions 校验正式签名和 ABI 后发布。
