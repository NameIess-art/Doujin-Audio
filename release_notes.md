# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点重构播放详情页头部与多会话交互排版，优化音量与定时器等控制组件的响应式布局；引入界面转场期间非核心 UI 刷新延迟机制，消除封面展开与折叠过程中的视觉卡顿与闪烁；增强 Windows 桌面端自定义标题栏窗口控制、热区交互与横屏操作菜单；全面升级多标签检索、关键词排除与搜索建议推荐，并优化在线作品库分类与聚合展示体验。

## 媒体播放与会话交互

- **播放详情头部重构**：重构播放详情页脚手架（SessionDetailScaffold）与头部控制布局，自适应调整音量滑块、定时关闭与速度调节等组件的栅格排版，提升不同视口宽度与横竖屏切换下的交互体验。
- **转场动效与非核心刷新延迟**：引入转场期间延迟非核心 UI 刷新机制，在页面切换与封面展开/折叠动效执行期间妥善调度渲染资源，大幅降低转场卡顿并消除占位图切换闪烁。
- **多会话持久化与缓存优化**：优化播放会话持久化协调器（PlaybackSessionPersistenceCoordinator）与封面及音频详情缓存服务（CoverArtworkCacheService / AudioDetailCacheService），提升前后台切换与会话轮换时的稳定性。

## 桌面端与多端交互规范

- **Windows 自定义标题栏完善**：重构 Windows 标题栏控制区域（WindowsWindowTitleBar），解决窗口最小化、最大化及关闭按钮的热区命中与非客户区拖拽分歧，规范窗口交互体验。
- **横屏主导航与快捷菜单**：优化桌面横屏主导航（DesktopMainNavigation）与快捷操作菜单（ElementActionMenu），规范右键菜单与长按操作逻辑，统一各端视觉边框与圆角规范。
- **控件排版微调**：统一设置面板、音频特效与字幕窗口中的下拉选择框（DropdownButton）基准对齐，优化图片与文本查看器的浮动胶囊毛玻璃质感。

## 媒体库检索与在线作品库

- **检索语法与多标签支持**：重构搜索查询解析逻辑（SearchQueryUtils）与搜索页面（AppSearchPage），支持使用 `-` 前缀排除指定关键词、多标签组合检索以及实时热门建议推荐。
- **在线聚合与分类目录**：优化 ASMR.ONE 与 Japanese ASMR 在线作品库聚合与分类浏览（AsmrCatalogMerge），改善分类目录展示性能与作品树加载流畅度。
- **本地作品与元数据审查**：增强作品详情页 DLsite 元数据匹配、审查加载与多语言展示联动，优化大型音频列表展开与分类检索体验。

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
