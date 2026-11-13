# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点完善收听时长统计与历史记录的即时刷新机制，重构全应用通用悬浮按钮与作品详情交互细节；在 Android 原生层精细化播放时长账本聚合与无缝过渡，在 Windows 原生层升级独立悬浮字幕 DirectWrite 渲染与字体后备排版；加固媒体库排除文件夹与音轨删除的落盘时序；优化封面缩略图解码调度防饥饿与冷启动会话恢复竞态；并完善标签兴趣偏好与全局搜索建议的动态联动。

## 媒体播放与原生会话

- **收听活动与历史记录即时刷新**：在播放暂停、进度跃迁与多会话切换时即时同步刷新收听活动服务（ListeningActivityService / PlaybackCommandCoordinator），保障“我的”页面与播放历史统计数据的实时性与一致性。
- **Android 原生使用账本与会话无缝过渡**：在 Android 原生层完善播放时长账本（NativePlaybackUsageLedger.kt），精细化统计多会话的播放时长聚合与状态切换，优化会话切换时的无缝过渡（NativePlaybackSession.kt / NativePlaybackService.kt）。
- **封面缩略图调度与会话恢复竞态消除**：优化异步封面加载组件（AsyncCoverImage），完善缩略图解码并发调度，杜绝长列表快速滑动时的解码线程饥饿；同时消除播放会话恢复（PlaybackSessionPersistenceCoordinator / PlaybackQueuePathCoordinator / PlaybackFacade）中的潜在竞态。
- **多会话轮播指示器与队列操作体验**：重构多会话切换轮播指示器（ActiveSessionCarousel / ActiveSessionCarouselWidgets），采用平滑自适应动效提升视觉反馈；优化播放队列音频编辑（PlaybackQueueAudioEditPage）与媒体列表交互。

## 媒体库管理与检索交互

- **音轨移除与排除文件夹落盘时序加固**：媒体库在从内存移除音轨或排除文件夹前，强制等待持久化操作（LibraryMutationCoordinator / LibraryFacade）落盘完成，消除高并发与快速连续操作时的状态不一致与界面残留。
- **标签兴趣偏好与全局搜索建议联动**：完善“我的”页面标签偏好管理（AsmrTagInterest / MyTagManagementPage），并在全局搜索建议（AppSearchSuggestions）中动态关联用户感兴趣的标签与题材，提升检索发现效率。
- **在线分类目录多标签合并与分页优化**：改进 ASMR 在线分类目录（AsmrCategoryCatalog / AsmrRemoteCatalogService），完善多分类标签聚合合并与分页加载容错。
- **封面艺术图缓存与保留策略**：增强封面艺术图缓存服务（CoverArtworkCacheService）与图片保留策略（CoverImageRetention），提高本地与远程封面在多页面流转中的复用效率与内存回收表现。

## 桌面端与界面细节优化

- **Windows 独立悬浮字幕 DirectWrite 渲染与字体后备**：重构 Windows C++ 原生独立悬浮字幕窗口（subtitle_window.cpp），优化 DirectWrite 文本格式化、多语言字体后备（Font Fallback）与高 DPI 文本布局排版性能。
- **通用悬浮按钮控件重构**：引入全应用统一的悬浮图标按钮（AppOverlayIconButton），规范作品详情页返回、编辑、DLsite 以及翻译悬浮按钮（WorkPageTranslationButton / PageTranslationScope）的阴影、高亮水波纹与主题前景色规范。
- **视频视口与详情页关闭路由加固**：完善会话详情脚手架（SessionDetailScaffold）、队列组件（PlaylistQueueWidgets）与视频视口（SessionVideoViewport / PlaylistVideoWidgets）的关闭路由保护，杜绝重复触发关闭操作时的异常路由分发。

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
