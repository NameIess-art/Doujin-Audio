# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点优化浏览页面滚动锚定与快速滑动时的封面冷加载节流，避免滑动卡顿；同时增强路由重建隔离，加快选择反馈并稳定作品标题的排版缩放。

## 浏览与滚动流畅度

- **滚动锚定与回弹修复**：修复浏览页面滚动时的定位与锚定异常，保证快速滑动与切页时列表滚动位置准确稳定。
- **滑动封面冷加载节流**：在列表持续滚动期间智能节流未缓存封面的异步加载与解码，大幅降低快速滑动时的瞬间 I/O 与渲染负载。

## 交互响应与排版稳定

- **选择态操作反馈提速**：优化多选与卡片选中交互的响应链路，提供更迅速的即时视觉反馈。
- **标题文本缩放稳定**：重构作品详情页标题布局测量，稳定字体缩放排版，消除动态缩放计算中的抖动与尺寸跳变。

## 路由隔离与控件精简

- **路由重建深度隔离**：优化播放列表与设置页的路由订阅机制，切页时杜绝外层页面与列表组件的无意义重绘。
- **统一弹窗与下拉菜单优化**：重构并精简 UnifiedDropdown 与 UnifiedPopupMenu 表面渲染逻辑，移除废弃逻辑并统一视觉层级。

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
