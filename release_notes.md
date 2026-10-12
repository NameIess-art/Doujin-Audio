# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点改进多平台播放工作流与应用启动调度，重构 Windows 桌面播放桥接与交互体验，优化跨平台媒体库整理工具与快照缓存，并修复下载任务取消清理与状态同步问题。

## 播放与启动性能优化

- 优化应用启动编排（App Bootstrap）与运行时依赖图初始化，减少初始加载开销。
- 引入延迟 Tab 内容加载与交互门控调度机制（Deferred Tab Content & Interaction Gate），在数据就绪前按需延迟渲染，显著提升主界面滑动与页面切换流畅度。
- 增强播放会话启动流与音轨切换逻辑，重构清理 Android 端陈旧播放辅助类与启动偏好写入逻辑，提升前台服务与通知栏控制稳定性。

## 桌面与多平台体验

- 重构 Windows 播放桥接（Windows Playback Bridge）与音效协调，提升桌面多会话控制与音效状态同步稳定性。
- 优化 Windows 桌面导航锁定机制与侧边栏/设置交互，精简桌面端专属设置项。
- 完善跨平台媒体库整理工具（Library Organizer），统一规范各平台路径规则与目录组织逻辑。
- 完善媒体库持久化协调器与快照缓存服务，减少重复扫描与磁盘 I/O 开销。

## 下载管理与问题修复

- 优化 ASMR 下载管理器的任务生命周期调度，修复下载任务在取消与清理边界情况下的状态同步问题。
- 增强下载任务管理页面与详情卡片交互，提供更可靠的重试与任务清理流程。
- 修复并稳定多处 UI 交互状态与自动化测试用例。

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
