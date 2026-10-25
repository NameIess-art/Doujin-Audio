# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点修复快速滑动时封面队列的清理调度逻辑，避免排队中的有效封面被误丢弃；新增菜单栏毛玻璃效果开关并重构顶部导航与底部面板的毛玻璃过渡；同时优化作品详情页卡片与大列表的渲染响应，提升整体交互流畅度。

## 封面加载与列表渲染

- **封面加载调度修复**：修复大列表快速滑动清理延期查找时误丢弃排队中封面请求的问题，确保滑动停止后视口内的可见封面能够完整平滑加载。
- **异步封面框架统一**：统一单曲与作品卡片的异步封面加载与占位绘制框架，优化不同尺寸封面的缩放与加载过渡。

## 界面交互与毛玻璃质感

- **菜单栏毛玻璃开关**：外观设置中新增「菜单栏毛玻璃」开关，可按需启用或关闭顶部栏与底部面板的背景虚化模糊效果。
- **顶部与底部面板过渡**：重构 TopPageHeader 与 AppDockPanel 的背景图层及半透明过渡，在路由切换与页面滚动时提供更连贯的视觉表现。
- **卡片渲染与滚动优化**：精简作品详情头部与播放列表卡片的层级开销，消除快速滑动和切页时的卡顿。

## 目录检索与推荐优化

- **远程目录与推荐响应**：优化 ASMR 远程目录与推荐评分引擎的数据组织逻辑，加快兴趣标签匹配与分类列表解析响应。
- **状态同步稳定性**：优化会话轮播与收听活动状态更新链路，防止高频状态同步引发的无意义重绘。

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
