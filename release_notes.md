# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新主要增强作品详情条目的媒体信息展示（文件大小、时长与格式扩展名），优化作品详情页折叠头部与标题跑马灯排版，改进页面通用头部与滚动交互体验，并优化音轨切换面板。

## 媒体详情与条目呈现

- 作品详情条目增强展示：音频、文本等媒体条目现已展示文件大小、时长及文件扩展名标签，便于快速识别音质与文件格式。
- 优化 Android 原生文本台本与封面资源解析调度，提升多级目录下的文件读取与缓存检索稳定性。
- 完善媒体缓存服务对多样化文件路径与元数据的提取与一致性处理。

## 界面排版与交互体验

- 优化作品详情页可折叠头部布局与收起过渡，动态计算标题尺寸，改进长标题跑马灯滚动与交互响应。
- 改进通用顶部页面头部（Top Page Header）结构，微调操作胶囊与按钮边距，增强各端布局适配性。
- 改进横向滚动边缘渐变淡入淡出与滚动活动门控调度，减少非必要重绘，操作更跟手。
- 改进会话音轨切换面板（Session Track Switcher Sheet）选中指示与交互反馈。

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
