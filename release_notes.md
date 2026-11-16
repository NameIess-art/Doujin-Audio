# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新全面焕新应用内导航、交互控件与动效反馈，拆分「我的」与「设置」独立入口并支持自定义显示；重构播放队列持久化与大队列摘要索引机制；将 Android 原生播放恢复状态迁移至 SQLite 分块存储并完善定时「会话播完后暂停」流程；同时优化作品详情、桌面端字幕窗口与整体滑动性能。

## 导航结构与界面交互

- **「我的」与「设置」入口拆分**：底部菜单与横屏侧栏统一提供独立的「我的」和「设置」入口，并在「设置 → 通用 → 页面显示」支持隐藏「我的」，两者均可设为启动页面。
- **统一按钮、高亮与动效系统**：重构通用按钮（`AppButtons`）、按压高亮（`AppTapHighlight`）、滑动指示条（`SlidingSelectionIndicator`）与转场动画（`AppTransitions`），统一顶部标题栏（`TopPageHeader`）、下拉菜单（`UnifiedDropdown`）与弹出菜单（`UnifiedPopupMenu`）视觉与反馈体验。
- **「我的」统计图表与标签管理优化**：优化收听时长柱状图最小列宽与布局自适应（`ListeningTimeChart`），延迟加载标签目录数据并改进搜索建议联动（`MyTagManagementPage` / `AppSearchSuggestions`），减少页面切换卡顿。
- **桌面端与多端交互细节**：Windows 端「关于」页意见反馈改为直达 GitHub Issues 页面；统一本地与在线作品详情脚手架（`AsmrWorkDetailSheet` / `WorkDetailPage`），优化树状目录、面包屑与横屏导航体验。

## 播放列表、定时器与持久化

- **大队列摘要与按需路径加载**：数据库升级至 Schema v16，为播放队列新增条目与音轨计数摘要，优化队列音轨加载与编辑页（`PlaybackQueueAudioEditPage` / `PlaylistTab` / `PlaylistListView`）在长队列场景下的渲染与操作流畅度。
- **定时「会话播完后暂停」与恢复加固**：明确倒计时结束后各播放会话在当前音轨播完后暂停的语义与等待状态提示，优化 `TimerFacade` 与 Android `PlaybackTimerAlarmReceiver` 并发恢复协调。
- **Android 原生播放恢复迁移 SQLite**：新增 `NativePlaybackRecoveryDatabase` 与 `NativePlaybackRecoveryCodec`，以分块 BLOB 与独立保留 URI 表取代原 SharedPreferences 恢复存储，消除大队列下的存储与游标读取限制。
- **Android 与 Windows 字幕层稳定性**：优化 Android 悬浮字幕（`SubtitleOverlayService`）在文本与可见性未变化时的无效布局刷新；为 Windows 悬浮字幕窗口（`subtitle_window.cpp`）补充文本测量重入保护并复用渲染表面容量。

## 媒体库与性能

- **滚动与卡片渲染降耗**：优化媒体库快照缓存（`LibrarySnapshotCacheService`）、列表项复用、Marquee 滚动作用域与延迟流订阅（`interactionDeferredListenableStream`），降低快速滑动与会话切换时的重建开销。
- **自然排序与本地媒体兼容**：改进自然排序（`NaturalSort`）与音频详情持久化读写一致性，确保列表排序与历史/标记恢复准确稳定。

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
