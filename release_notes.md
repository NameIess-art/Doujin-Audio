# Doujin Audio 0.18.1 Release Notes

> **升级前必读：**本版本使用新的 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。应用仅接受由本版本创建的 `.dabackup` 备份，不提供旧数据或旧备份格式的自动迁移。

## Doujin Audio 品牌与应用身份

- 应用展示名称、Dart 包名、Android 包名、平台通道、原生视频 View Type、缓存与诊断文件统一迁移为 Doujin Audio 标识。
- GitHub 仓库、更新地址、发布文档和自动更新资产统一迁移到 `NameIess-art/Doujin-Audio`。
- Android 应用 ID 更新为 `com.doujin.audio`；此版本与更名前应用完全隔离，不提供旧私有数据、备份或发布资产的兼容路径。

## 播放、视频与后台稳定性

- 优化 Android 原生播放服务 (`NativePlaybackService`) 生命周期管理与前台服务启动策略。
- 强化 Flutter 与 Android 原生播放状态存储 (`NativePlaybackStateStore`) 恢复逻辑与通知响应机制。
- 改进视频帧缓存管理，规范化 ASMR 异常范围与错误提示。

## 媒体库、SAF 存储与排序

- 引入 SAF (Storage Access Framework) 持久化 URI 权限管理协调器，提升媒体库文件读取与存储授权稳定性。
- 增强文件缓存与文档存储的媒体扫描协调器 (`FileCacheMediaScanOrchestrator`)，提高大型媒体库扫描健壮性。
- 优化“排序依据”菜单中文字符：“正序”更名为“升序”，“曲库区分”更名为“曲库分组”。

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
