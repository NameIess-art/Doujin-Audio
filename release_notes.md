# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新精简「我的」页面架构，移除冗余的离线推荐旧实现与死代码，专注于收听统计、播放历史与多维偏好管理；深度重构应用生命周期与运行时依赖图，优化冷启动调度；同时增强 ASMR 下载任务管理与中断恢复机制，并优化列表惯性滚动与定时器界面的交互表现。

## 架构精简与代码清理

- **精简偏好与历史展示**：清理「我的」页面冗余的离线推荐旧实现，保持页面结构聚焦于收听时长统计、播放历史以及标签／声优／社团的偏好与排除管理。
- **清理失效状态与死代码**：彻底清理被替代的推荐模型、过时业务逻辑与对应测试支持，大幅降低状态耦合与维护开销。

## 启动与生命周期优化

- **应用运行时调度重构**：重构 AppLifecycleBinding 与 AppRuntimeGraph 启动调度逻辑，前后台切换与运行时依赖绑定更加平稳，加快冷启动响应速度。
- **资源回收与前后台协同**：完善后台播放、网络恢复与应用暂停期间的生命周期状态流转，杜绝状态脱节与资源泄露。

## 下载管理与传输稳定性

- **下载任务状态与清理强化**：重构 ASMR 下载管理器与任务持久化调度，提升任务断点续传、失败重试与取消清理的原子性。
- **并发传输与异常隔离**：强化分片传输执行器的异常拦截与重试逻辑，保障大容量音频文件与网络波动环境下的下载可靠性。

## 界面交互与动效流畅度

- **大列表惯性滚动优化**：优化浏览页面的滚动监听与位置锚定，减少滑动过程中的无意义重建。
- **助眠画板与定时器响应**：改进助眠画板（BedtimeCanvas）与定时器 Tab（TimerTab）倒计时控件的视觉状态更新与交互触控反馈。

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
