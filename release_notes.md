# Doujin Audio 0.25.1 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 界面交互与导航性能

- 优化主界面底部导航栏与侧边栏的交互响应，消费长按手势防止误触发页面切换，并缓存侧栏图标布局位置消除折叠动画时的重排与抖动。
- 细化主界面顶层覆盖层（`MainOverlayUiState`）与导航状态的监听粒度，解耦全局字幕状态，减少无谓的页面级 rebuild。
- 完善动态主题切换与背景平滑过渡体验，提升页面切换的流畅度。

## 播放列表与队列体验

- 优化播放列表条目的视觉呈现与阴影层级，统一临时会话的悬浮视觉与撤销移除（Undoable Removal）动画。
- 调整会话置顶（Pinned）指示器视觉位置，播放控制按钮增加弹性过渡动效与防抖反馈。
- 优化播放列表排序交互、多会话选择与字幕时间轴同步。

## 媒体库与 ASMR 浏览

- 优化媒体库分类排序与筛选逻辑，提升大规模作品与音轨列表下的滚动与加载性能。
- 改进 ASMR 搜索与分类列表在快速输入与切换时的异步状态调度与缓存处理。

## Windows 与 Android 核心

- 修复 Windows 平台在视频 Surface 挂载后的自动播放与播放器状态恢复逻辑，防止视频黑屏或空转。
- 完善 Android 平台发布构建、签名校验与设备测试流程的稳定性。

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
