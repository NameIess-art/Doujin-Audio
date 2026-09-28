# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 字幕识别、翻译与编辑

- 可为本地及 ASMR.ONE 音频手动选择日语 `.txt` 或 `.md` 台本，后台匹配语音并生成带时间轴的字幕。含有效时间轴的 `.txt` 可直接导入。
- 日语字幕支持翻译为中文或英文，并将原文与译文保存为独立的 SRT。首次使用会下载并校验本地模型；模型下载和字幕处理可查看进度，任务中断后可从分段进度续接。32 位 Android 暂不支持模型处理。
- 新增逐条字幕编辑，可调整文本与起止时间、增加或删除条目；编辑结果保存为独立的 SRT，保留原字幕文件。Android 使用滑动操作，Windows 使用右键菜单。
- 本地音频的识别字幕写入音频目录；ASMR.ONE 在线音频的字幕保存在应用数据目录，并在播放时重新加载。

## 媒体库、ASMR.ONE 与播放队列

- 改进本地作品详情和媒体库操作，并完善 ASMR.ONE 在线播放、下载与缓存衔接。
- 优化 ASMR.ONE 推荐结果与远程目录加载，改善推荐内容及分页状态的处理。
- 调整播放队列的路径协调和会话启动，完善队列曲目切换与时间段控制。

## 双端稳定性

- 整理共享播放命令、状态与平台桥接的调用链，完善 Android 原生播放命令处理及 Windows 桌面集成。
- 改进多语言文案、页面布局和错误反馈，并补充字幕、播放和平台行为的回归验证。

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
