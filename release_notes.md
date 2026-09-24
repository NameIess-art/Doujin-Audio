# Doujin Audio 0.25.0 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 播放与界面

- 调整多会话播放、队列和播放详情页的状态协调，修复快速操作与页面切换时的状态同步问题。
- 优化播放详情页展开、收起及封面背景绘制，减少重复图片解码和不必要的渲染。
- 新增本地作品详情页，支持浏览作品目录中的图片与文本、Markdown、PDF 台本，并完善横屏播放页直达作品详情的入口。
- 改进播放列表、媒体库和 ASMR 卡片布局、页面过渡、字幕时间轴及加载反馈。

## 媒体库与下载

- 完善媒体库扫描和编辑流程、文件夹重命名后的队列路径更新，以及封面缓存与视频帧复用。
- 修复 ASMR 下载任务删除时误清理同一目录中其他任务文件的问题。
- 优化搜索、元数据审查和作品详情页的交互与异步状态处理。

## Windows 与 Android

- Windows 新增键盘快捷键、全局热键和任务栏媒体控制按钮，改善桌面滚动与播放交互。
- 调整 Android 原生播放服务和会话状态处理，完善通知与平台通道行为。

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
