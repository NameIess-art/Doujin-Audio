# Nameless Audio v0.11.1

## Windows 自动更新

- Windows 自动更新改为优先使用目录切换安装：先把新版本复制到同级新目录，主程序退出后备份旧目录，再把新目录切换为正式安装目录。
- 目录切换失败时会回退到原地镜像覆盖，降低旧文件残留和半更新状态的风险。
- 提权更新器改用 PowerShell `EncodedCommand` 启动，减少路径空格、引号和特殊字符导致的参数解析失败。
- 更新脚本会在新版启动后清理旧目录备份，并保留失败日志用于排查。

## 发布资产

- `NamelessAudio-android-arm64-v0.11.1.apk`
- `NamelessAudio-android-arm64-v0.11.1.apk.sha256`
- `NamelessAudio-windows-x64-v0.11.1.zip`
- `NamelessAudio-windows-x64-v0.11.1.zip.sha256`

# Nameless Audio v0.11.0

## 体验与性能

- 优化播放详细页的下滑体验和背景透出效果，降低重 UI 在 Android 系统级交互中的卡顿风险。
- ASMR.ONE、本地音频库和播放列表卡片统一使用更紧凑的共享节奏：封面比例、标题两行、信息栏行高、按钮尺寸和底部留白保持一致。
- Android 列表页禁用大批量滚动文字，播放详细页保留必要的滚动标题；Windows 端保留原有焦点跑马灯。
- 音频卡片标签不再保留空白行，标题最多两行显示，封面与信息栏布局更稳定。

## 反馈与可靠性

- 导入失败、扫描失败、元数据获取失败、ASMR 下载失败、更新校验失败和备份恢复失败会给出更明确的下一步操作。
- 权限中心增加授权、未授权、受限和建议开启等状态导向。
- 更新和备份结果增加确认信息，成功时显示版本、校验或文件位置，失败时可重试或导出诊断。

## 质量基线

- 新增体验质量 widget 回归测试，覆盖卡片尺寸、列表文字静态规则、标签空白行和关键反馈文案。
- 新增 README 与文档 UTF-8 编码回归测试，避免文档乱码回退。
- 扩展体验规范、测试说明和发布质量文档，记录 Android/Windows 手动性能验收流程。

## 发布资产

- `NamelessAudio-android-arm64-v0.11.0.apk`
- `NamelessAudio-android-arm64-v0.11.0.apk.sha256`
- `NamelessAudio-windows-x64-v0.11.0.zip`
- `NamelessAudio-windows-x64-v0.11.0.zip.sha256`

# Nameless Audio v0.10.4

## 稳定性与修复

- 修复通过应用内更新下载的包在 Android 上无法直接覆盖安装，抛出应用签名不一致的错误。

## 发布资产

- `NamelessAudio-android-arm64-v0.10.4.apk`
- `NamelessAudio-android-arm64-v0.10.4.apk.sha256`
- `NamelessAudio-windows-x64-v0.10.4.zip`
- `NamelessAudio-windows-x64-v0.10.4.zip.sha256`

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
