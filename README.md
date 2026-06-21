# Nameless Audio

Nameless Audio 是一款面向 ASMR、语音作品和大体量本地媒体库的跨平台播放器，使用 Flutter、Android 原生 Media3 / ExoPlayer 与 Windows libmpv 混合实现。

当前版本：`0.11.0+1100`

最新发布页：[v0.11.0](https://github.com/NameIess-art/nameless-audio/releases/tag/v0.11.0)

[MIT License](LICENSE) · [隐私说明](PRIVACY.md) · [发行质量说明](docs/release-quality.md)

## 下载

| 平台 | 发布资产 | 说明 |
|---|---|---|
| Android arm64-v8a | `NamelessAudio-android-arm64-v0.11.0.apk` | 适用于大多数 64 位 Android 手机 |
| Windows x64 | `NamelessAudio-windows-x64-v0.11.0.zip` | 解压完整 ZIP 后运行 `nameless_audio.exe` |

Windows ZIP 包含应用运行所需的完整 Flutter 运行时、`libmpv-2.dll`、FFmpeg 和 FFprobe。不要只复制 EXE。

> Android 自 `v0.8.0` 起使用 `com.nameless.audio`。更早版本无法直接覆盖安装，升级前请先导出 `.nalbackup`。

## 主要功能

### 播放与音效

- 多会话播放：可同时保留多个独立播放会话，分别控制曲目、进度、音量、循环、字幕和音效。
- 多种队列范围：支持单曲循环、当前文件夹顺序/随机、跨文件夹顺序/随机播放。
- 播放速度：固定刻度选择；Windows 鼠标滚轮每次只切换一个刻度。
- 会话音效：跳过静音、降噪、音量平衡、声道平衡、左右声道调换和超过 100% 的音量增益。
- 均衡器：支持设备频段、自带预设、自定义预设与频段增益持久化。
- 时间段标签：为音轨保存命名区间、颜色和起止时间，并可循环播放选中区间。
- 播放状态恢复：保存会话顺序、队列、播放位置、速度、循环方式、收藏与音效设置。

### Android 后台播放与计时

- 原生 `MediaSessionService`、Media3 / ExoPlayer、媒体前台服务与锁屏控制。
- ExoPlayer WakeMode、CPU WakeLock、Wi-Fi Lock、前台状态看护和服务重启恢复。
- 正确区分永久失焦、短暂失焦与可降低音量的焦点变化，避免熄屏后误暂停。
- 睡眠计时器支持立即倒计时或播放后开始、结束淡出、暂停会话和指定时间自动恢复。
- 精确闹钟、开机/更新后状态恢复和原生计时执行，降低息屏与应用退出对定时任务的影响。

### 本地媒体库

- 支持导入文件夹、曲库和单独文件；Android 优先使用 SAF 并持久化目录授权。
- 根据文件树构建层级媒体库，支持自然排序、搜索、刷新扫描、排除目录与手动拖动排序。
- 大目录扫描、去重与数据转换在后台执行，并显示扫描进度和失败统计。
- 单独视频文件可提取视频帧封面；Android 与 Windows 会跳过纯黑、纯白或低内容帧。
- 自动发现常见封面文件，并支持作品详情编辑、封面候选选择、标题重命名和引用同步。

### ASMR.ONE 与 DLsite

- 浏览、搜索、登录、收藏、历史、分类和个性化推荐。
- 在线读取作品文件树，将单文件或文件夹加入播放会话。
- 选择作品文件或目录下载到本地，保留目录结构并生成 `nameless-audio.json` 元数据。
- 按 RJ 号、文件名或作品标题读取 DLsite 元数据，支持多站点和 HTML 回退解析。
- 支持批量元数据匹配、确认写入、详情备份和数据库恢复。

### 字幕与控制台

- 支持 `.srt`、`.ass`、`.ssa`、`.vtt`、`.lrc` 字幕。
- 会话详情、播放卡片和全局悬浮窗同步当前字幕。
- Android 使用系统悬浮窗；Windows 使用可重复开启、拖动和交互的原生桌面字幕窗口。
- 字幕悬浮窗支持字体、字号、文字颜色、背景颜色、背景透明度和边框设置，并提供实时预览。
- Windows 与移动端横屏控制台使用适配布局、圆角菜单和稳定的滚动边界。

### 视频转音频

- 支持输出 `mp3`、`aac`、`ogg`、`wav`、`flac`。
- MP3 / AAC / OGG 可设置码率，支持实时进度、取消与输出文件防覆盖。
- Android 使用随应用打包的 FFmpeg 能力；Windows 使用 ZIP 内的 `ffmpeg.exe` 和 `ffprobe.exe`。

### 设置、数据与可靠性

- 主题颜色支持跟随系统、浅色和深色；界面支持中文、日文和英文。
- 所有下拉选择框复用统一的不透明样式。
- 权限与后台运行中心集中检查通知、后台运行、精确定时、悬浮窗、文件管理和安装更新权限。
- 支持 `.nalbackup` 数据备份、验证、恢复与失败回滚。
- 支持导出脱敏诊断 ZIP；日志会清理凭据、授权头和 URL 查询参数。
- 缓存管理支持封面、视频帧、更新包和下载临时文件，并可设置缓存上限。
- 支持减少动态效果、键盘/横竖屏恢复、Windows 自定义标题栏与桌面窗口适配。

## 应用内自动更新

应用从 GitHub 最新 Release 选择当前平台的发布资产：

- Android 选择文件名包含 `arm64` 的 APK，校验 SHA-256 后打开系统安装器。
- Windows 选择文件名包含 `windows` 和 `x64` 的 ZIP，校验 SHA-256 后启动独立更新器。
- Windows 更新器验证 ZIP、等待应用退出、覆盖安装目录、必要时请求管理员权限并自动重启。
- GitHub API 不可用或匿名限流时，会回退到 Release 页面读取版本与资产。

每个更新资产必须同时发布同名校验文件：

```text
NamelessAudio-android-arm64-v0.11.0.apk
NamelessAudio-android-arm64-v0.11.0.apk.sha256
NamelessAudio-windows-x64-v0.11.0.zip
NamelessAudio-windows-x64-v0.11.0.zip.sha256
```

## 支持格式

| 类型 | 格式 |
|---|---|
| 音频 | `flac`、`wav`、`mp3`、`m4a`、`aac`、`ogg`、`opus`、`3gp` |
| 视频 | `mp4`、`mkv`、`webm`、`mov`、`m4v`、`avi`、`3gp` |
| 字幕 | `.srt`、`.ass`、`.ssa`、`.vtt`、`.lrc` |

## Android 权限

| 权限 | 用途 |
|---|---|
| `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE` | 兼容直接文件系统扫描与旧式文件选择 |
| `MANAGE_EXTERNAL_STORAGE` | 可选的完整文件系统扫描；使用 SAF 时不需要 |
| `POST_NOTIFICATIONS` | 播放通知、后台控制和状态提示 |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK` | 后台与息屏播放 |
| `SYSTEM_ALERT_WINDOW` | 在其他应用上方显示全局字幕 |
| `SCHEDULE_EXACT_ALARM` / `RECEIVE_BOOT_COMPLETED` | 定时暂停、自动恢复和重启后恢复计时 |
| `REQUEST_INSTALL_PACKAGES` | 安装用户主动下载的应用内更新 |
| `INTERNET` | ASMR.ONE、DLsite 和 GitHub Release 更新 |

## 开发与验证

```bash
flutter pub get
flutter analyze
flutter test
dart run tool/verify_release.dart
```

### Android arm64 Release

Release 构建必须配置正式签名。缺少 `android/key.properties` 或对应 keystore 时构建会直接失败，不会回退到 debug 签名。

```powershell
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

产物：

```text
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

### Windows x64 Release

构建前确保 `assets/ffmpeg/ffmpeg.exe` 和 `assets/ffmpeg/ffprobe.exe` 存在。CMake 会下载完整 libmpv，并把 MPV、FFmpeg、FFprobe 和 Flutter 运行时复制到 Release 目录。

```powershell
flutter build windows --release
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath dist\NamelessAudio-windows-x64-v0.11.0.zip -Force
```

## 发布流程

推送与 `pubspec.yaml` 版本一致的标签会触发 GitHub Actions：

1. 执行静态分析、Flutter 测试、Android JVM 测试和 Debug APK 构建。
2. 使用仓库 Secrets 中的正式签名构建 Android arm64 APK。
3. 下载固定版本且校验过的 FFmpeg，构建包含完整 libmpv 的 Windows ZIP。
4. 为两端资产生成 `.sha256` 并上传到同一个 GitHub Release。

```powershell
dart run tool/verify_release.dart --tag v0.11.0
git tag v0.11.0
git push origin main v0.11.0
```

## v0.11.0 重点变更

- 优化播放详细页下滑与系统级交互响应，减少重 UI 对通知栏下拉、后台切换等操作的影响。
- 统一 ASMR.ONE、本地音频库和播放列表的作品卡片节奏，优化封面、标题、信息栏、标签行和底部留白。
- Android 列表文字保持静态以降低动画负载，Windows 保留必要的焦点跑马灯体验。
- 完善导入、扫描、元数据、下载、更新、备份和权限相关失败反馈，提供更明确的下一步操作。
- 建立体验质量基线测试与文档规范，覆盖卡片回归、文档编码、动效可访问性和手动性能验收流程。

完整内容见 [release_notes.md](release_notes.md).
