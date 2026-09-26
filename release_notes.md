# Doujin Audio 0.25.2 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 播放详情页与控制菜单

- 优化播放详细页控制菜单（功能面板）交互，将面板退出折叠按钮调整至左上角，更符合单手与常规返回操作习惯。
- 优化控制菜单中的操作按钮样式（“恢复默认”、“恢复1.0X”、“重置”、“保存预设”），增加上下触控高度，排版加粗，提升点击舒适度与视觉层次。
- 扩展均衡器增益调节范围，完善预设重置与自定义预设保存流程。

## 封面缓存与加载体验

- 优化已解码封面图片的内存缓存与复用策略，显著减少卡片与详情页切换时的重复解码。
- 完善媒体库、播放列表与推荐流封面图片的占位与渐变过渡，消除刷新或切歌时的闪烁。

## 架构收敛与 Windows 桌面适配

- 将外观设置 Provider 统一梳理至核心 UI 层级，降低跨组件状态耦合。
- 修复 Windows 桌面环境下菜单折叠收起交互，并持续提升桌面端播放与音频桥接稳定性。

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
