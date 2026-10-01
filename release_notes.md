# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 封面加载调度与滚动流畅度优化

- 引入视口中心优先的封面加载调度算法（Center-weighted cover scheduling），视口可见卡片与屏幕中心封面优先加载，离开视口的待处理任务在快速滚动时自动降级或让位。
- 引入最大滚动速度限制（MaxScrollVelocityPhysics），防止列表极速滑动物理动量过大导致瞬间涌入过多图片解码与视图构建。
- 优化点击底部导航栏回到顶部的响应速度与交互体验。

## 页面过渡与加载体验

- 新增平滑的滑动页面过渡动画（Sliding Page Transitions），改善页面间层级导航动效。
- 优化作品详情加载流程，在获取最新远程详情时优先展示本地已有数据与缓存，消除等待空白。
- 播放胶囊（Playback Capsule）进场采用固定尺寸平滑滑入动效。

## Windows 桌面端与播放核心

- 优化 Windows 桌面端集成、系统媒体控制（SMTC）响应与音量控制协同。
- 统一 ASMR 封面在多处播放面板（MiniPlayer、播放胶囊与详情页）的缓存复用与状态同步。
- 简化媒体库、播放会话与平台桥接状态流，提升跨端运行稳定性。

## 媒体库管理与声优标签国际化

- 作品元数据卡片支持声优（Voice Actor）标签多语言本地化显示（支持中、英、日三语）。
- 重构媒体库编辑树与 DLsite 批量元数据审查相关页面结构，提升代码可维护性与交互响应。

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
