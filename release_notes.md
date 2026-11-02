# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点优化播放列表与队列新建排序机制，新队列保持首位可见；作品详情页优先复用已缓存或已预热封面，消除页面切换时的闪烁与占位延迟；全面提升封面淡入动效与后台调度协调性能，并完善查看器浮动控制栏与菜单栏毛玻璃主题效果的实时联动。

## 播放列表与队列管理

- **新队列置顶保持**：重构播放列表排序状态管理（PlaylistSortedEntriesNotifier），新建播放列表或会话队列时自动保持在顶部首位可见，排序选项或固定状态变更时即时平滑响应，避免项目顺序意外打乱。
- **列表性能与 Provider 优化**：优化播放列表 Presentation 级状态派发逻辑，避免封面更新等非结构变化导致整表不必要重排与组件重建。

## 封面加载与视觉过渡

- **详情页封面即时复用**：进入作品详情页时优先复用已缓存或已预热的同款封面（本地与远程统一处理），大幅缩短封面渲染延迟，彻底消除白屏或占位图闪烁。
- **淡入动效与调度协同**：优化封面淡入过渡与空闲调度机制（AppTransitions 与 AsyncCoverImage），在动效执行期间妥善保护后台任务与空闲处理流程，提升高刷设备上的视觉平滑度。

## 界面交互与效果联动

- **浮动控制栏毛玻璃适配**：图片查看器（WorkImageViewerPage）与文本查看器（WorkTextViewerPage）的浮动操作按钮与翻页切换器完整响应“菜单栏毛玻璃”设置，开关毛玻璃实时生效。
- **页面标题栏间距统一**：微调顶部标题栏（TopPageHeader）与内容区域的间距配合，提升横竖屏切换与全屏查看时的排版稳定性。
- **收听活动刷新优化**：优化应用生命周期切换时的收听统计刷新逻辑，避免前后台切换时触发不必要的强制深层重载。

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
