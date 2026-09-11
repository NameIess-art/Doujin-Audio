# Doujin Audio 0.22.0 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## Windows 桌面端与视频播放

- **视频播放视口交互升级**：视频播放器视口引入鼠标悬停感知，在鼠标滑入时自动显示全屏及控制按钮，滑出时平滑隐藏；Windows 平台全屏支持窗口内沉浸式全屏，兼顾多任务与观影体验。
- **Windows 播放桥接加固**：Windows 端复用会话专属 VideoController，加固原生视频与音频渲染通道的生命周期管理。
- **桌面布局与视觉优化**：桌面侧边栏与主界面调整深浅色模式下的边框与阴影层次；主界面导航图标升级为播放列表专属图标；更新 Windows 高清应用图标。

## 睡前模式与定时控制

- **音轨播放完毕后停止**：Android 睡眠定时到期后，各播放会话在当前曲目自然结束时停止；等待相关会话全部停止后，再安排定时自动恢复。
- **睡前画布交互优化**：睡前沉浸画布优化屏幕超时与暗度联动控制，精简手势冲突，收听与锁屏体验更安稳。

## 媒体库与播放列表

- **播放列表撤销与徽标**：播放列表优化状态徽标展示；从列表移除项时支持撤销恢复，防止误触。
- **媒体库多语言与交互微调**：媒体库分类折叠/展开、ASMR 字幕状态标签以及播放列表快捷定时器芯片全面接入多语言国际化（中文/日文/英文）。

## 架构重构与稳定性

- **内存压力管理与活跃缓存保护**：新增内存压力响应策略，自动回收低优先级资源；正在播放与活跃会话的文件受到租约保护，防止长音频播放中途缓存被意外清理。
- **播放核心与命令统一**：精简播放底层状态流，整合播放命令协调与通知栏状态同步流程。
- **动画与过渡性能**：优化底部弹窗（Bottom Sheet）与水波纹遮罩过渡动画，修正相关动画衔接问题。

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
