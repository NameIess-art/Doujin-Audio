# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点优化 Android 原生媒体会话播放协调机制，系统通知与锁屏控制统一通过会话播放器分发；完善通用对话框的软键盘避让与输入法联动；增强作品详情页封面折叠与元数据操作栏阴影的平滑过渡；同时对播放队列编辑、下载任务卡片响应式排版及元数据批处理交互进行了全方位优化。

## 媒体播放与原生会话

- **媒体会话指令分发优化**：重构 Android 端系统 MediaSession 播放指令处理（NativeMediaSessionCallback 与 NativePlaybackService），系统媒体通知与按键请求统一通过会话播放器进行生命周期调度，规范状态快照与后台保活警报管理，消除前后台切换时的播放状态分歧。
- **播放队列与会话详情微调**：优化播放队列编辑页（PlaybackQueueEditPage）条目重排与选中状态同步，改进会话详情页面（SessionDetailLayout）与时间分段组件的响应体验。

## 界面与交互细节

- **作品详情页阴影联动**：改进作品详情页头部（WorkDetailHeader），元数据操作栏阴影仅在封面完全折叠后显现，封面展开时自然过渡，避免界面提前出现切分硬边。
- **对话框软键盘适配**：通用对话框（AppDialog）全面接入软键盘安全区监听，在输入法呼出时自适应抬升内容区域，杜绝输入框与确认按钮被虚拟键盘遮挡的问题。
- **下载任务响应式布局**：优化 ASMR 下载任务卡片（AsmrDownloadTaskCard）在各端多窗口宽度下的栅格与布局表现，规范各状态文案、进度条与操作按钮的视觉间距。
- **元数据批处理体验**：完善 DLsite 元数据批量设置与审查加载界面的状态派发与视觉稳定性。

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
