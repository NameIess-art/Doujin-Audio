# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点优化 ASMR 下载任务管理与 DLsite 元数据展示，支持任务移除撤销与精确传输进度预估；重构媒体库封面加载生命周期与视口渲染门控，大幅降低列表快速滚动时的性能开销；增强播放命令协调与会话异常恢复机制，优化迷你播放底栏路由层级与跨页面协同；持续改进老旧备份数据校验与交互细节体验。

## ASMR 下载与任务管理

- **下载任务删除撤销**：删除下载任务时提供撤销操作（Undo）与平滑手势反馈，修复任务即时移除逻辑并优化列表清空后的退出行为。
- **DLsite 元数据与进度预估**：在下载详情与作品详情中展示更丰富的 DLsite 元数据，重构下载规划器（ASMR Download Planner），提供更准确的文件进度与传输耗时预估。
- **状态联动与重试指引**：统一在线作品库收藏状态与下载任务模型协同，规范网络失败重试提示与缓存作品标识处理。

## 媒体库与封面加载性能

- **封面加载生命周期重构**：引入统一的封面加载控制器（LibraryCoverUiController）与异步图片流管理，滚动时自动挂起非视口请求，显著降低主线程渲染与图像解码负担。
- **作品详情与元数据呈现**：全面增强作品详情页的标签、元数据卡片与多语言显示，优化多层级文件夹浏览与封面来源解析。
- **排序与列表投影优化**：简化媒体库排序计算逻辑，延迟非关键封面查询，提升大型音声库的展开与切换流畅度。

## 播放控制与会话管理

- **播放命令协调与异常恢复**：优化播放会话生命周期与焦点切换策略，增强网络抖动与异常中断后的恢复能力。
- **队列路径同步与校正**：在播放失败重试与进度拖动校正前预先同步播放队列状态，防止并发操作导致状态不一致。
- **迷你底栏路由适配**：优化全局迷你播放底栏（RoutedPlaybackDockHost）的层级关系，确保在覆盖路由与全屏页面下保持正确定位。

## 存储安全与交互细节

- **缓存路径保护与备份校验**：加强内部播放缓存路径安全防护，严格校验历史老旧备份文件有效性与数据库兼容性。
- **排版与点击反馈规范化**：统一顶部导航栏留白与标题间距，规范入口卡片水波纹触感反馈（AppEntryInkWell）。
- **图片查看器手势优化**：缩放交互限制在顶部控制栏下方，确保重试与操作按钮持续可响应。

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
