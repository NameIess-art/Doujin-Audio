# Doujin Audio 0.18.0 Release Notes

> **升级前必读：**本版本使用新的 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。应用仅接受由本版本创建的 `.dabackup` 备份，不提供旧数据或旧备份格式的自动迁移。

## Doujin Audio 品牌与应用身份

- 应用展示名称、Dart 包名、Android 包名、平台通道、原生视频 View Type、缓存与诊断文件统一迁移为 Doujin Audio 标识。
- GitHub 仓库、更新地址、发布文档和自动更新资产统一迁移到 `NameIess-art/Doujin-Audio`。
- Android 应用 ID 更新为 `com.doujin.audio`；此版本与更名前应用完全隔离，不提供旧私有数据、备份或发布资产的兼容路径。

## 数据备份与存储空间

- 新增 `.dabackup` 完整备份，可导出数据库、设置、播放记录和 ASMR.ONE 账号；备份包含敏感账号信息，导出前会明确提示风险。
- 恢复前会验证清单、校验和、数据库 schema 与文件内容，在下次启动时应用；失败时自动回滚，避免当前数据被部分覆盖。
- 新增存储空间统计，分别展示本地音频库、应用缓存、其他占用和剩余空间，并支持读取失败后重试。
- 完善备份暂存、恢复日志、生命周期协调及回归测试，避免播放运行时与数据库恢复互相竞争。

## 播放、视频与后台稳定性

- 新增“允许播放视频”设置，可关闭视频画面并仅播放音频，同时保留现有会话、进度、队列和通知栏控制。
- 重构 Flutter 与 Android 原生播放协调路径，改进会话切换、播放位置更新、字幕状态、通知路由及后台恢复。
- 修复搜索加载状态、字幕控制、视频视图约束、横屏视频控制和播放列表卡片交互问题。
- 加强应用生命周期、原生播放恢复、MediaSession、通知、定时器与前台服务的测试覆盖。

## 媒体库、缓存与排序

- 媒体库支持按名称、声优、时长、发售时间或添加时间排序，播放列表支持按名称、时长或添加时间排序。
- 缓存已排序的媒体库树，减少重复计算；扫描和目录状态继续由既有协调器统一维护。
- 嵌入式封面按内容哈希去重，降低重复封面缓存占用，并保留原有封面发现与恢复行为。
- 修复资料库搜索加载、存储占用刷新和多处播放/媒体库状态同步问题。

## 界面与交互

- 优化主页面、资料库、ASMR.ONE、播放列表和播放详情的窄屏、横屏及动态尺寸布局。
- 统一对话框、底部面板、页面切换和减少动画行为，清理旧的重复排序与滚动实现。
- 改进播放详情会话切换、次级操作栏、列表卡片、空状态和无障碍动画。
- “关于”页面改为应用图标独占一行、应用名称显示在下方，并放大图标以提升品牌辨识度。

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
