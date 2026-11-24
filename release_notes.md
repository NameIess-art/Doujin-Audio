# Doujin Audio 更新说明

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本说明涵盖 v0.36.0 之后的变更。数据库结构沿用上一版本。

## 播放与字幕

- 改进播放详情中的进度拖动、时间显示、倍速、循环区间和切曲操作，调整视频控件及字幕菜单的反馈。
- 优化全文字幕时间轴的滚动和当前条目高亮，并改进字幕编辑、悬浮字幕样式预览与 Windows 悬浮字幕的阴影绘制。
- Android 改进息屏时本地和网络音轨的持续播放及故障恢复。恢复播放器时保留系统媒体会话，修正播放恢复期间通知栏播放和暂停按钮的状态。视频保持亮屏仅在画面可见且正在播放时生效。

## 媒体库、界面与设置

- TXT 和 Markdown 查看页将文件列表、字号、编码和复制全文集中到右上角的更多菜单，便于阅读时切换和调整。
- 统一按钮按压、页面转场、操作面板和撤销提示的反馈，调整外观和网络设置页的布局，以及在线作品库的页头和下载卡片。
- Windows 改进滚轮滚动和滚动条的悬停、拖动反馈。「我的」收听柱状图在滚动结束后更新纵轴范围，减少滚动中的刻度跳动。

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
