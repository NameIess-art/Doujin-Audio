# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新支持社团偏好与排除管理，聚合标签、声优与社团的多维推荐与个性化过滤；支持 DLsite、ASMR.ONE 与 Japanese ASMR 多数据源元数据刮削与审查；整合「我的／设置」导航与操作反馈，并大幅优化大列表滑动、封面冷加载与播放切换的响应表现。

## 偏好管理与智能推荐

- **社团偏好与排除支持**：「我的」页面兴趣卡片新增「社团」选项卡，自动统计常听贡献前 20 个社团并支持手动选择补充；新增不感兴趣社团与声优排除过滤，屏蔽命中作品。
- **统一偏好管理页**：重构标签、声优与社团偏好及排除选择界面，支持搜索过滤、即时统计与批量原子保存，支持操作撤销与重试。
- **多维推荐评分引擎**：每日推荐与在线推荐引擎深度融合标签、声优与社团多维偏好权重，兼顾探索性与相似度，严格执行排除规则。

## 元数据检索与媒体库

- **多数据源元数据刮削**：媒体库支持通过 RJ 编号、标题或文件名在 DLsite、ASMR.ONE 与 Japanese ASMR 中并发检索与补全缺失元数据。
- **元数据审查体验**：支持批量审查与编辑元数据，增加 DLsite 区域访问限制说明与引导，修复数据源切换与重试进度反馈。
- **列表复用与状态保持**：优化分类筛选与搜索切页时的作品列表复用逻辑，保持浏览位置与已加载状态，杜绝冗余请求。

## 浏览流畅度与性能优化

- **滑动封面冷加载节流**：优化大列表快速滑动时的卡片渲染，推迟屏幕外封面的异步探测与解码，显著降低 I/O 和主线程压力。
- **音轨与播放响应提速**：将复杂音轨解析、章节映射与耗时计算移至后台 Isolate 执行，加快切歌与会话初始化响应。
- **导航层级整合与精简**：整合「我的」与「设置」导航入口，精简播放会话卡片与操作菜单，统一撤销反馈与交互过渡。

## 桌面与平台能力

- **Windows 依赖与缓存修复**：修复 Windows 打包与运行时的 libmpv 第三方依赖下载与校验缓存机制。
- **双端交互一致性**：优化桌面端右键操作菜单与移动端滑动反馈，保证多会话播放与悬浮字幕窗口生命周期的平稳流转。

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
