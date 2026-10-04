# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 列表动态重排与视觉过渡优化

- 引入平滑的列表动态重排动画（Animated Reorder），优化播放列表会话与媒体库条目在置顶、取消置顶与拖拽排序时的视觉连续性。
- 优化播放列表置顶指示器与批量多选指示器的对齐精度、边框色彩与图层层级。
- 优化多封面播放卡片的封面分割线与占位渲染表现。

## 媒体库与 ASMR 搜索状态保持

- 本地媒体库与 ASMR 搜索分类切换采用懒加载视图栈，在不同分类之间切换时保持展开状态、已选筛选标签和列表滚动位置，避免重复重置。
- 搜索结果过滤与卡片快照解耦，提升分类列表切换与搜索关键字输入时的响应速度。
- 优化作品详情加载流程，进入与返回时保持过渡帧稳定并及时释放中间资源。

## 播放控制与跨端运行稳定性

- 优化进度条跳转与定位时的缓冲状态反馈，拖拽进度时更快呈现加载指示器。
- 增强 Windows 桌面端播放核心、系统媒体控制（SMTC）与定时任务调度协同。
- 规范全平台播放会话与队列管理流程，优化资源释放与后台生命周期处理。

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
