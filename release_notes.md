# Doujin Audio 0.18.2 Release Notes

> **升级前必读：**本版本使用新的 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。应用仅接受由本版本创建的 `.dabackup` 备份，不提供旧数据或旧备份格式的自动迁移。

## 播放与界面体验优化

- **精简进度条布局**：播放详细页进度条上下占位高度由 52px 缩减至 34px，提升整体界面视觉比例与紧凑度。
- **动态居中绘制**：播放进度条分段背景颜色与标记图标改用动态高度中心点，精准兼容多屏幕尺寸与不同进度条高度。
- **导航栏长按响应优化**：底部导航栏“本地音频库”与“ASMR.ONE”图标的长按触发切换延迟由 1000ms 缩短为 350ms，长按切换更加快捷灵敏。

## 外观设置与媒体库增强

- **音频内嵌封面优先**：外观设置中新增“优先使用音频内嵌封面”选项；开启后在未手动设定封面时，将优先提取并使用音频文件自带的内嵌封面。
- **移除目录持久化**：本地音频库已移除文件夹记录支持持久化存储，可在单独视图中随时查看已移除路径或选择一键恢复。

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
