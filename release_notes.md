# Doujin Audio 0.24.1 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 播放会话与队列路径重定向

- **重命名与路径变更状态保持**：
  - 完善播放队列重定向（Path Retargeting）协调机制，修复重命名单曲音频文件或作品目录后，会话播放队列（`customQueueTracks` 与 `PlaybackQueueDefinition` 及其 `workRootPath`）中的音轨路径与作品标题未能同步更新的问题。
  - 会话中非当前播放音轨重命名时，仅就地更新底层队列结构，不再触发多余的会话重新初始化或打断当前播放。
  - 重命名当前正在播放的音轨或其所在目录时，会话重新加载新路径时精确保留当前播放进度与播放状态（`playing` 与 `position`），避免从头重播或状态丢失。

## 界面文案与图标规范统一

- **封面显示模式文案校准**：校准中/英/日多语言封面显示模式（中文：“平铺/适应”，英文：“Tile/Fit”，日文：“並べて表示/画面に合わせる”），使文案表达与实际渲染表现完全统一。
- **播放列表与队列管理图标统一**：播放列表、队列编辑与切换音轨等相关操作及引导提示图标统一使用 `Icons.playlist_play_rounded`，提升交互一致性与视觉识别度。

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
