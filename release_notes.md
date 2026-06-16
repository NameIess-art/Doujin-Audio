# Nameless Audio v0.10.3

## 稳定性与修复

- 修复 GitHub 应用内更新被错误拦截为“应用签名不一致”的问题。更新流程不再依赖应用内硬编码证书指纹，下载校验通过后直接交给 Android 系统安装器处理覆盖安装。

## 发布资产

- `NamelessAudio-android-arm64-v0.10.3.apk`
- `NamelessAudio-android-arm64-v0.10.3.apk.sha256`
- `NamelessAudio-windows-x64-v0.10.3.zip`
- `NamelessAudio-windows-x64-v0.10.3.zip.sha256`

# Nameless Audio v0.10.2

## 稳定性与修复

- 恢复备份后会重新加载持久化播放和曲库状态，避免重新导入文件、文件夹或曲库后才能播放音频。
- 改进 Android 部署和发布签名流程，减少签名或安装来源不一致导致的新版本安装失败。

## 发布资产

- `NamelessAudio-android-arm64-v0.10.2.apk`
- `NamelessAudio-android-arm64-v0.10.2.apk.sha256`
- `NamelessAudio-windows-x64-v0.10.2.zip`
- `NamelessAudio-windows-x64-v0.10.2.zip.sha256`

# Nameless Audio v0.10.1

## 稳定性与修复

- 拦截并提示 Android 端因当前安装包签名不匹配导致的应用内更新失败。

## 发布资产

- `NamelessAudio-android-arm64-v0.10.1.apk`
- `NamelessAudio-android-arm64-v0.10.1.apk.sha256`
- `NamelessAudio-windows-x64-v0.10.1.zip`
- `NamelessAudio-windows-x64-v0.10.1.zip.sha256`

Windows ZIP 包含完整 Flutter 运行时、`libmpv-2.dll`、FFmpeg 和 FFprobe。Android 与 Windows 应用内更新均依赖同名 `.sha256` 文件完成下载校验。

# Nameless Audio v0.10.0

## 新功能与体验

- 完善播放控制台：加入播放速度、均衡器预设与自定义频段、跳过静音、降噪、音量平衡、声道平衡和时间段标签循环。
- Windows 全局字幕悬浮窗改为原生桌面窗口，可重复开启、拖动和交互，并遵循字幕悬浮窗中的字体、字号、颜色、背景透明度和边框设置。
- 本地曲库支持单独视频文件封面；Android 与 Windows 都会跳过纯黑、纯白或无内容的视频帧。
- 新增权限与后台运行中心、首次启动说明、数据备份恢复和脱敏诊断报告。
- 统一设置页、均衡器、字幕字体和视频转换器的下拉选择框样式。

## 稳定性与修复

- 修复 Android 熄屏播放期间将可降低音量的音频焦点事件错误处理为暂停的问题，并保留真正短暂失焦后的自动恢复状态。
- 增强 Android Media3 前台播放服务、WakeLock、精确定时暂停和定时自动恢复链路。
- 修复 Windows 全局字幕悬浮窗首次显示异常、黑屏、无法交互、后续无法再次显示和开启时崩溃的问题。
- 修复 Windows 播放速度滚轮一次跨越多个刻度、横屏控制台菜单缺少圆角、本地曲库滚动范围溢出等问题。
- 完善 Windows ZIP 自动更新：校验 SHA-256、解压覆盖安装目录、必要时提权并自动重启。
