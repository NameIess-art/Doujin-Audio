# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点优化本地媒体库管理与扫描流程，支持扫描后自动清理无效空目录，重构树形列表投影与节点计数性能；增强网络连接韧性，引入多源 DNS 递归与并发备用解析；深度优化 Windows 独立字幕窗口的布局渲染与文本排版，并改进播放列表清理与会话恢复机制；全面优化滚动动画与指示器性能，提升交互流畅度与稳定性。

## 媒体库管理与存储扫描

- **空目录自动修剪**：磁盘扫描完成后自动清理并移除已删除音频后遗留的无效空工作目录，保持媒体库层级清晰干净。
- **树形列表投影与计数重构**：重构媒体库编辑树投影模型与项目计数计算机制，提升大型多层级作品库的加载与展开性能。
- **封面批处理与检索优化**：改进封面图片存储（CoverArtworkStore）与 Android SAF 路径解析，提升多端媒体元数据与缩略图的加载效率。

## 网络与传输韧性

- **自定义 DNS 递归解析**：新增多服务商 DNS 递归与并发解析支持（DnsServerResolver），在异常网络环境下提供自动备用回退与故障转移，增强 ASMR 在线资源与元数据检索可靠性。

## 播放控制与 Windows 桌面增强

- **悬浮字幕窗口布局优化**：全面优化 Windows 独立悬浮字幕窗口（SubtitleWindow）的文字测量、双缓冲渲染与 DPI 自适应排版，提高字幕呈现的美观度与响应性能。
- **播放队列协调与清理强化**：优化 WindowsPlaybackBridge 播放列表销毁与清理逻辑，增强随机播放恢复稳定性与跨会话切换的流畅度。

## 界面交互与动效表现

- **滚动性能与动画门控**：引入滚动活动门控（ScrollActivityGate）与优化的音波指示器（PlayingSoundWaveIndicator），在列表高速惯性滚动时自动暂停不必要的重绘开销。
- **回顶动效与导航体验**：增加 ScrollToTop 交互动效，改进多标签页切换状态保留（MainTabStateMixin）与跑马灯文字（MarqueeText）平滑渲染。

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
