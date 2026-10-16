# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点重构横屏播放会话详情的左右双栏布局对齐，确保封面进度与控制详情基准线严格一致；同时深度优化 Android 与 Windows 双端视频播放的生命周期、早期暂停源保留与全屏交互，增强全局多会话暂停的状态快照一致性。

## 横屏播放详情布局对齐

- **左右双栏基线精确对齐**：使用专用布局委托统一测量并排布左侧封面/进度条与右侧标题/字幕/控制栏，彻底消除左右两列底部高低不一与垂直对齐漂移。
- **分段面板与安全边距**：重构横屏分段与歌词面板的定位逻辑，统一遵循状态栏与顶部安全间距，杜绝内容展开时的垂直溢出与下边界裁切。

## 视频播放与原生生命周期

- **早期暂停源状态保留**：修复视频音轨在未完成轨道解析或表面未就绪阶段触发暂停时原生播放器过早释放的问题，确保首帧渲染与后续恢复播放无缝衔接。
- **Windows 画面通道重置**：优化 Windows 端在上下文切换与无视频表面过渡期间的 libmpv 视频轨道重置流程，避免视频通道被静默关闭导致画面无法渲染。
- **Android 原生渲染清理**：精简 Android 原生视频平台视图的多余刷新监听与重复重绑逻辑，提升视频表面附着与横竖屏切换的稳定性。
- **全屏交互与状态读取**：优化全屏视频控制条进场自动隐藏定时器调度，统一双击播放/暂停直接读取播放会话最新请求状态。

## 多会话控制与快照同步

- **全部暂停快照对齐**：优化 PlaybackFacade 在执行全部会话暂停后的原生快照状态回填，保持各会话 loadedPath 与处理状态的准确同步。

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
