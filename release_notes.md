# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点优化播放详情与会话切换交互，封面升级解析完成后引入平滑淡入动效，杜绝占位图切换时的突兀跳变；新增并优化各页面平滑回到顶部过渡动效，提升长列表滚动流畅度；完善 Android 原生后台保活定时与异常中断恢复机制；同时重构桌面端主导航布局、统一全应用下拉选择框控件，并对在线分类目录聚合与设置页面进行了全面优化。

## 媒体播放与原生会话

- **封面解析渐变淡入**：优化异步封面加载组件（AsyncCoverImage），在高清或本地解析封面就绪后采用平滑渐变淡入动效替换占位图，消除封面刷新时的硬切与视觉跳变。
- **播放详情与队列交互优化**：重构会话详情脚手架（SessionDetailScaffold）与播放队列排版（PlaylistQueueWidgets），自适应横竖屏切换与不同视口宽度，优化会话切换路由动效与背景渲染层次。
- **Android 后台保活与状态恢复**：完善系统定时保活唤醒机制（PlaybackKeepAliveAlarmScheduler）与原生播放恢复控制器（NativePlaybackRecoveryController），增强息屏、后台低内存及短暂停顿后的状态持久化与通知栏控制连续性。
- **Presentation 状态派发优化**：优化播放器与媒体库 Provider 依赖图及生命周期回收机制，降低非必要重绘与跨层通知开销。

## 界面交互与动效规范

- **平滑回到顶部动效**：引入平滑回到顶部动效（ScrollToTopTransition）与主 Tab 滚动状态协同（MainTabStateMixin），双击或点击 Tab 导航回到顶部时保持丝滑过渡，杜绝瞬间重置与滚动穿透。
- **桌面端主导航重构**：重构 Windows 桌面端主导航容器（DesktopMainNavigation），规范分栏间距、页面层级与自适应宽度响应，优化方向控制器（AppOrientationController）的跨端分流。
- **统一通用下拉选择框**：重构并统一各端下拉组件（UnifiedDropdown），规范基准对齐、阴影与展开浮层布局，统一设置页、音频控制与弹窗内的选项交互。
- **设置页面排版重构**：重构设置面板结构与子分节（SettingsTab），精简组件层级，优化通用设置与网络配置的列表排版与滚动体验。

## 在线作品库与下载服务

- **分类目录聚合优化**：改进 ASMR 在线分类目录聚合服务（AsmrCatalogMerge / AsmrCategoryCatalog），提升分类标签切换与分页请求的稳定性，避免重复加载。
- **下载任务规划优化**：完善 ASMR 下载任务分块规划（AsmrDownloadPlanner）与作品内容映射逻辑，提升网络弱网条件下的容错性。

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
