# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点改进横屏与桌面端导航过渡动效，增强播放控制响应与原生视频播放组件重用，优化多会话音视频状态同步，并提升界面滚动流畅度与操作反馈。

## 横屏与桌面导航动效

- **侧边栏动效规范**：横屏与桌面模式下的侧边栏导航过渡限制在导航轨区域内，消除页面切换时的全局布局位移，视觉过渡更平滑自然。
- **导航生命周期与快捷键**：增强桌面端主导航的全局快捷键响应，优化从主屏幕进入作品详情与返回时的路由状态保持。
- **布局适配优化**：优化设备方向切换时的布局重绘，减少横竖屏过渡期间的冗余重构。

## 播放响应与视频渲染

- **原生播放响应**：优化 Android 原生播放服务与播放命令快照流转，加快切歌、seek 与播放状态同步的反馈速度。
- **视频播放体验**：重构视频播放组件与视口布局，支持视频播放器跨表面无缝复用，优化播放控制栏淡入淡出动效。
- **Windows 播放桥接**：增强 Windows 原生播放桥接对视频就绪状态与多会话命令的协调同步，提升桌面音视频播放稳定性。
- **控制条与进度交互**：优化播放进度条拖拽与跳转的响应精度，微调播放控制按钮的操作反馈与动效。

## 界面流畅度与排版细节

- **滚动与活动门控**：优化滚动活动门控在快速滑动时的状态同步，精简 ASMR 分类列表键映射，消除列表滚动时的微卡顿。
- **文本跑马灯与通用头部**：优化通用顶部头部结构，改进长标题跑马灯在悬停与不同平台下的暂停逻辑。
- **精简与规范**：清理冗余设置选项与无用本地化字段，保持核心功能精简专注。

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
