# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点修复 ASMR.ONE 远程作品子目录下的播放队列范围识别，确保单文件夹循环与切歌行为精确限定在当前子目录；同时完善播放加载与异常恢复指示，优化各端播放卡片与控制面板的加载动画交互。

## ASMR 远程队列与目录作用域

- **子目录层级识别**：针对包含多个子文件夹的 ASMR 作品，通过音轨目录元数据与相对路径精确解析所属目录，解决跨子目录误播与播放队列范围漂移问题。
- **循环与切歌范围**：单文件夹循环与上一曲/下一曲切换准确遵循当前子目录范围，自定义队列与跨文件夹循环逻辑保持清晰隔离。

## 播放加载与状态交互

- **加载状态精确同步**：优化会话卡片、播放列表项与详情控制面板中的加载状态，解耦播放请求与加载中的单一绑定，首播与缓冲期间均能即时展示旋转动画。
- **错误恢复交互**：音轨加载失败或网络中断时保留可交互的重试指示器，点击即可重新发起准备与播放，提升弱网环境下的恢复体验。
- **跨平台一致性**：统一 Android 与 Windows 双端在多会话卡片、轮播及详情页的播放状态指示逻辑。

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
