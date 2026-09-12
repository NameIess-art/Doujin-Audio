# Doujin Audio 0.22.2 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 关于页面与反馈通道

- **关于页面新增反馈入口**：在“关于”页面新增用户反馈选项，支持一键调起邮件客户端发送反馈；完善 Android 与 Windows 原生层对 `mailto:` 协议的校验与拉起支持。

## 媒体库扫描与刷新机制加固

- **Android 目录扫描容错升级**：重构 Android 文档树遍历逻辑，加固游标读取与权限异常保护；遇到局部异常时准确保留已发现音轨并记录未完成状态。
- **媒体库刷新状态感知优化**：媒体库刷新遇到部分失败时精确记录失败信息，并向用户展示明确的失败反馈提示。

## 播放状态恢复协调

- **原生播放恢复流程加固**：优化 Android 端音频会话恢复协调器的状态管理与生命周期处理，提升应用在异常重建后的播放恢复稳定性。

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
