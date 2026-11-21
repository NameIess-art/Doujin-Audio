# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 播放、队列与定时

- 立体声音轨可在声道平衡页调节虚拟前后方位，各会话独立保存设置。
- 临时会话可参与多选，只有已保存的会话可置顶。优化队列编辑与长列表展开，修正移除正在播放的曲目后手动切歌时的条目定位。
- 改进长按快进和快退、切曲与失焦时的控制反馈，以及倒计时到点后的等待状态和自动恢复。

## 媒体库、字幕与界面

- 本地作品库支持仅按时长筛选，改进作品目录展开、批量元数据操作和页面切换反馈。
- 调整「我的」收听统计、历史记录及兴趣管理。恢复备份时保留较新的本地收听数据和兴趣偏好。
- 改进字幕编辑、悬浮字幕与样式预览，统一菜单、弹窗和输入控件的交互反馈。

## Android 与 Windows

- Android 改进息屏播放恢复、保活调度和系统媒体通知控制。
- Windows 改进托盘退出时的保存顺序、系统媒体控制及悬浮字幕布局。

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
