# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 作品详情与正文文本翻译

- 本地媒体库与 ASMR.ONE 作品详情页新增右上角页面翻译入口，支持将标题、社团、标签以及目录和文件名翻译为当前应用语言，再次点击即可恢复原文。
- 文本查看器新增 TXT 与 Markdown 正文翻译能力，保留 Markdown 排版结构、超链接与代码块，并可随时切回原文或取消。
- 优化文本与作品详情加载过程中的翻译入口可见性，保证在内容加载期间翻译操作即刻可用。
- 采用轻量且无需配置 API Key 的在线翻译接口，翻译仅改变界面展示，不改写源文件或作品本地元数据。

## 播放交互与底部弹窗规范

- 优化滑动卡片关闭手势（Swipe to Close）动效，确保手势收起动画平滑过渡完成后再执行对应前置操作，避免视觉闪烁。
- 统一标准化全应用底部弹窗交互规范（AppBottomSheet），重构并优化媒体库排序弹窗、播放队列编辑与会话切歌面板。
- 优化播放列表会话条目的置顶动画反馈（Animated Pins），提升排序与状态切换时的视觉连续性。
- 增强 Native 播放恢复控制器（NativePlaybackRecoveryController）与音频生命周期协同，提高异常中断或状态重建时的播放连贯性。

## 性能表现与架构清理

- 移除遗留冗余的旧版定时器与播放流程代码，精简跨端 Bridge 与事件处理链条。
- 优化 ASMR 下载选择树（Download Selection Tree）与媒体库封面提取性能，减少不必要的重构与内存占用。
- 完善多语言文档与发布资产校验规范。

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
DoujinAudio-windows-x64-<tag>-setup.exe
DoujinAudio-windows-x64-<tag>-setup.exe.sha256
```

普通 Android 用户可下载 universal APK。现代手机可选择 arm64，旧款 32 位 ARM 设备选择 armv7，x86_64 仅用于对应设备或模拟器。所有 APK 都附带同名 `.sha256`，并由 GitHub Actions 校验正式签名和 ABI 后发布。

Windows 10/11 x64 用户下载 `setup.exe`，安装包附带同名 `.sha256`，包含运行依赖并按当前用户安装。关闭主窗口后应用留在托盘，使用托盘“退出”结束应用。Android 与 Windows 备份不能跨平台恢复。
