# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 并发播放与作品显示

- 支持并发播放会话（Concurrent Sessions），多个音频会话可同时独立播放并维护各自的生命周期与队列协调。
- 新增作品显示名称配置项，支持在媒体库、作品详情及图片浏览等处自由切换展示作品标题或原始文件夹名，并提供多语言文案支持。
- 优化标题跑马灯（MarqueeText）测量与滚动表现，改善文件夹封面选择等交互细节。

## 流式 CTC 字幕对齐

- 日语台本对齐引入流式 CTC 对齐（Streaming CTC Alignment），优化语音流与台本句子的实时匹配精度，时间轴对齐更加稳定精确。
- 优化字幕菜单交互，任务取消或异常中断时安全保留已有字幕轨道与状态。

## 滚动与下拉刷新交互

- 优化下拉刷新（GlassRefreshIndicator），刷新激活期间锁定滚动内容，避免下拉与滑动产生冲突或页面跳动。
- 改进媒体库树状列表和 ASMR 浏览界面的数据加载与下拉刷新平滑过渡。

## 双端稳定性与 CI 验证

- 清理冗余测试依赖导入，确保持续集成（CI）跨平台构建与自动化回归测试稳定通过。
- 完善并发会话状态管理、字幕对齐和下拉刷新的回归测试覆盖。

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
