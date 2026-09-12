# Doujin Audio 0.23.0 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 本地媒体库与音频封面

- **内嵌封面提取与去重**：本地音频库详细信息页支持直接读取音频文件内嵌封面；多个音频包含相同内嵌封面时，自动通过内容哈希去重展示为单一候选封面。
- **优先自身封面与回退修复**：修复开启“音频优先显示自身封面”时，自身无封面的音频无法正确回退到详细信息页已选文件夹封面的问题；支持祖先目录与 Disc 等子目录的层级回退。
- **Android SAF 路径与元数据兼容**：修复 Android 平台 SAF（存储访问框架）合成 URI 模式下的封面解析；新增对 RIFF WAVE（`.wav`）音频末尾 ID3v2 APIC 封面的跨平台与原生提取支持。
- **播放详情页封面联动**：修复在详细信息页更改封面后，全屏播放详情页未即时响应更新的问题。

## 交互界面与播放控制优化

- **播放倍速与字幕面板优化**：重构播放列表倍速控制及字幕面板交互，提高操作精度与反馈流畅度。
- **定时器与界面反馈调优**：优化定时器倒计时卡片与详情页面组件结构；完善全屏及独立页面下的底部抽屉与顶部提示反馈行为。

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
