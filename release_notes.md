# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新主要改进播放控制与跨端播放同步、重构作品详情与搜索呈现、增强自然排序与文本浏览体验、优化 ASMR.ONE 账户同步与下载传输，并精简核心体验移除冗余功能。

## 播放与控制

- 优化播放 seek 调度与会话状态同步，统一各端播放器状态存储与生命周期管理。
- 改进切歌面板与会话音轨切换交互，支持分类和目录快速切换与文件夹平滑展开。
- 增强播放列表与队列控制，优化循环模式切换、变速控制、音轨配色与时间区间选择。
- 增强正在播放动态声波指示器与控制反馈，提升视觉与操作响应。
- 清理冗余电源管理与唤醒控制遗留，统一依托前台媒体服务保障后台播放稳定性。

## 媒体库与内容浏览

- 本地媒体库引入自然排序（Natural Sort），数字前缀与曲目编号排序更符合直觉。
- 重构作品详情页与搜索页面渲染，进入页面与切页时即时呈现内容，消除冗余加载过渡与视觉闪烁。
- 优化长文本与 Markdown 台本阅读器，长文档后台切块准备与增量渲染，保留完整排版、代码与语义，翻译切换复用已解析内容。
- 优化目录封面选择与文件树编辑交互，完善媒体库分类与快照缓存管理。
- 移除使用率低且维护成本高的视频转音频功能，精简设置与应用体积，聚焦音频与音声播放核心体验。

## ASMR.ONE 与下载

- 改进 ASMR.ONE 账户同步与凭证持久化，完善 Token 刷新、登出及网络请求超时与取消处理。
- 优化下载文件选择树与批量下载交互，提升大作品文件树加载与选择性能。
- 完善下载传输调度与分块校验，强化播放缓存验证与状态一致性。
- 优化 ASMR.ONE 分类目录与搜索结果分页响应。

## Windows 桌面端

- 优化 Windows 播放桥接（Playback Bridge）与会话生命周期调度，提升切歌与状态通知稳定性。
- 完善 Windows 桌面端快捷键、置顶字幕窗口与托盘退出流程。
- 强化桌面原生能力与集成测试覆盖。

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
