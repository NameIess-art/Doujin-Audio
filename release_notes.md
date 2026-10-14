# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新重点优化封面图像解码与列表滚动性能，引入封面保留重用与像素级缩略图下采样，改进媒体库持久化协调与字幕查找，优化 ASMR 下载路径处理与账号凭证同步，并完善页面路由动效与搜索状态保持。

## 封面加载与滚动性能优化

- **封面保留重用**：引入封面保留与导航重用机制（Cover Image Retention），页面切换与返回时复用已解码的封面内存缓存，避免重复加载与视觉闪烁。
- **像素级下采样解码**：封面缩略图严格按实际渲染物理像素进行缩放解码，大幅降低大尺寸图源对内存和主线程的开销。
- **滑动解码调度**：优化冷封面与延迟加载调度逻辑，列表快速滑动期间按需延缓冷封面解码并在滑动平稳时顺畅加载，显著提升页面滚动跟手度。
- **边缘渐变与列表渲染**：优化横向边缘渐变淡入淡出及媒体卡片更新范围，减少非必要组件重绘。

## 媒体库、持久化与字幕

- **列表更新优化**：精简播放列表与分类媒体列表的状态传递与依赖更新，减少界面冗余重建。
- **媒体库持久化协调**：完善媒体库目录写入协调器与封面艺术图持久化存储，保障数据写入与索引稳定性。
- **字幕查找与 SAF 修复**：增强本地多格式字幕关联与时间轴匹配，修复 Android SAF 文档创建与文件替换边界事务。

## ASMR.ONE 与下载管理

- **下载路径处理**：修复 Windows 环境下特殊目录结构的下载目标路径拼接与文件定位问题。
- **凭证同步与任务调度**：增强 ASMR.ONE 账户认证凭证持久化与状态同步，优化下载规划器与取消清理流程。
- **排版优化**：下载任务与文件选择列表支持长标题自动折行至最多两行，提升长作品与多轨曲目的阅读体验。

## 播放调度与路由体验

- **Windows 播放桥接**：优化 Windows 原生播放桥接命令分发与媒体标识映射，提升桌面端播放会话同步稳定性。
- **定时与权限控制**：完善定时停止运行时状态绑定，规范权限请求控制器的生命周期流转。
- **平滑切页与搜索记忆**：统一页面路由过渡动画规范，切页更连贯；保留搜索页面输入内容与全部检索结果，返回时无缝恢复上下文。

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
