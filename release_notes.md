# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点重构播放详情页头部控制与多会话交互排版，优化音量、定时器与速度调节组件的响应式布局；引入界面转场期间非核心 UI 刷新延迟机制与共享元素封面过渡动效，消除封面展开与折叠过程中的视觉卡顿与闪烁；重构底部迷你播放栏（Dock）并新增封面环形进度指示器；全面升级高级检索语法、关键词排除、实时搜索建议与多标签管理；增强声优、社团与标签的快捷操作菜单；完善 Android 原生音频焦点抢占与自动恢复；并在 Windows 桌面端重构自定义标题栏系统命中、横向滚轮与多端控件对齐规范。

## 媒体播放与多会话交互

- **播放详情头部重构与响应式排版**：重构播放详情页脚手架（SessionDetailScaffold）与头部控制布局，自适应调整音量滑块、定时关闭与速度调节等组件的栅格排版，在不同视口宽度与横竖屏切换下保持平稳布局，消除内容溢出。
- **转场动效与非核心刷新延迟**：引入转场期间延迟非核心 UI 刷新调度机制，在页面切换与封面展开/折叠动效执行期间妥善调度渲染资源，避免高频状态通知与重量级重绘，大幅提升高刷屏幕上的动画帧率。
- **封面过渡动效与占位优化**：重构封面平滑过渡动效（SessionCoverTransition），妥善处理封面占位图与渐变过渡，消除页面切换与展开过程中的白屏、黑块与闪烁问题。
- **迷你播放栏与多会话切换**：重构底栏悬浮播放胶囊（RoutedPlaybackDockHost / MobileDockCapsuleContent）与多会话轮播控制器，新增封面环形播放进度指示器（SessionCoverProgressRing），支持平滑手势滑动与多会话即时切换。
- **多会话持久化与缓存协调**：重构播放会话持久化协调器（PlaybackSessionPersistenceCoordinator），优化音频详情缓存服务（AudioDetailCacheService）与封面缓存服务（CoverArtworkCacheService），保障前后台切换、会话轮换以及退出恢复的稳定性。
- **Android 原生音频焦点与播放恢复**：完善系统音频焦点监听与丢失恢复逻辑（NativePlaybackFocusRecoveryCoordinator、NativePlaybackService 与 NativeMediaSessionHost），提高闹钟、电话等短暂中断后的自动恢复成功率，统一系统 MediaSession 通知与按键指令分发。
- **时间轴字幕与视频视口优化**：重构时间轴字幕视图（TimelineSubtitleView）与独立字幕面板，优化字幕更新渲染频率与重绘范围；视频视口（SessionVideoViewport）支持内嵌与全屏播放流畅切换。

## 媒体库检索与在线作品库

- **高级检索语法与多标签支持**：重构搜索查询解析逻辑（SearchQueryUtils）与搜索页面（AppSearchPage），支持使用 `-` 前缀排除指定关键词、多标签组合检索（`$tag` / `#tag`）以及声优/社团语法筛选。
- **实时搜索建议与历史管理**：搜索输入时提供即时联想建议推荐与快捷补全，支持单条历史记录滑动删除与一键清空历史，并在设置中提供“记录搜索历史”开关控制。
- **元素快捷操作菜单**：新增声优、社团、标签等元数据胶囊的长按与右键快捷操作菜单（ElementActionMenu），支持一键在线搜索、本地检索与复制文本；优化作品详情页元数据匹配与 DLsite 审查加载体验。
- **在线聚合与分类目录浏览**：优化 ASMR.ONE 与 Japanese ASMR 在线作品库聚合与分类浏览（AsmrCatalogMerge / AsmrRemoteCatalogService），提升分类目录展示性能与作品树加载流畅度。
- **多选与批量操作体验**：作品卡片与播放列表卡片支持长按或右键菜单一键进入“多选”模式，并直接选中当前条目，便于快速执行批量加入列表、下载或移除。

## 桌面端与界面细节规范

- **Windows 自定义标题栏与系统命中优化**：C++ 原生层重构窗口无边框消息处理（`WM_NCHITTEST`），精确区分非客户区拖拽区域与最小化、最大化、关闭按钮热区，修复窗口控制按钮点击判定不准与拖拽分歧。
- **Windows 系统媒体控制与横向滚轮**：优化系统媒体传输控制（SMTC / media_controls）在多会话切换时的元数据与时间轴同步，增加 Windows 平台横向滚轮滚动支持。
- **收听时长统计交互升级**：“我的”页面收听时长图表（ListeningTimeChart）全面支持指针悬停信息提示、日/周/月/季/年周期切换，优化柱状图与方格图的展示与历史统计。
- **界面排版与控件细节对齐**：桌面横屏左侧菜单栏拆分独立的“我的”与“设置”导航项；统一设置面板、音频特效与字幕窗口中的下拉选择框（DropdownButton）基准对齐；规范卡片水波纹（AppEntryInkWell）与各端边框圆角视觉。

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
