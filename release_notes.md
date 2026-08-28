# Doujin Audio 0.20.0 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。应用仅接受由本版本创建的 `.dabackup` 备份，不提供旧数据或旧备份格式的自动迁移。

## 下载与数据管理

- **下载并发与重试配置**：设置页面新增 ASMR.ONE 下载配置，支持设置同时下载作品数（1–5）以及单文件失败自动重试次数（3–10）。
- **作品封面下载保存**：ASMR.ONE 下载任务会自动将作品封面持久化保存到下载根目录的 `Cover/<RJ号>.<扩展名>`。
- **重试状态与续传加固**：重试前重置文件单次重试计数，安全校验临时文件响应头，避免网络抖动导致任务异常中断。
- **封面缓存生命周期**：远程作品封面跨缓存清理周期持久保留，修正存储空间占用统计与失效索引清理。

## 播放列表与交互体验

- **播放列表批量管理**：增强多选模式，支持一键全选、反选、多选会话批量播放、批量暂停与批量移除。
- **目录树平滑过渡动画**：本地媒体库与分类列表中的文件夹展开/折叠增加平滑高度与透明度过渡动画，大型目录浏览更自然流畅。
- **导航板块手势切换**：底部导航栏与侧边 Navigation Rail 支持快捷手势与长按切换媒体库板块。
- **启动与主题底色优化**：优化主题引导底色计算（Accent-aware bootstrap surfaces），减少应用冷启动与页面切换时的闪烁。

## 架构重构与稳定性

- **原生播放体系拆分**：Android 原生播放服务解耦为独立策略层 (`NativePlaybackPolicies`)、恢复协调器 (`NativePlaybackRestoreCoordinator`) 与 Session Host，状态发布与生命周期更清晰。
- **Flutter 领域协调器解耦**：将 `PlaybackFacade`、`LibraryFacade` 及 `AsmrDownloadManager` 深度拆分为元数据、变更、传输、任务存储等单一职责协调器，降低内存开销与跨模块耦合。
- **生命周期资源回收**：强化应用退出与页面销毁阶段的资源释放，杜绝后台死锁与异步任务遗留。

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
