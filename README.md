# Nameless Audio

Nameless Audio 是一款面向 ASMR、语音作品和本地媒体库的跨平台播放器，使用 Flutter、Android 原生 Media3 / ExoPlayer 与 Windows libmpv 混合实现。

当前版本：`0.13.0+1300`

发布页：[v0.13.0](https://github.com/NameIess-art/nameless-audio/releases/tag/v0.13.0)

[MIT License](LICENSE) · [隐私说明](PRIVACY.md) · [发行质量说明](docs/release-quality.md)

## 下载

| 平台 | 发布资产 | 说明 |
|---|---|---|
| Android arm64-v8a | `NamelessAudio-android-arm64-v0.13.0.apk` | 适用于大多数 64 位 Android 手机 |
| Windows x64 | `NamelessAudio-windows-x64-v0.13.0.zip` | 解压完整 ZIP 后运行 `nameless_audio.exe` |

Windows ZIP 包含完整 Flutter 运行时、`libmpv-2.dll`、FFmpeg 和 FFprobe。不要只复制 EXE。

## 主要功能

### 播放与控制台

- 多会话播放：同时保留多个独立播放会话，分别控制曲目、进度、音量、循环、字幕、队列和音效。
- 播放范围：支持单曲循环、当前文件夹顺序/随机、跨文件夹顺序/随机播放。
- 传输控制：播放/暂停、上一首/下一首、快退/快进、进度拖动、播放失败重试。
- 加载中或播放错误时，播放按钮显示暂停图标；点击可立即重试。
- 控制台功能栏：均衡器、功能、播放速度、标签、声道平衡都可在播放详情页直接打开。
- 均衡器：支持设备频段、自带预设、自定义频段增益和持久化。
- 功能面板：支持跳过空白、轻度降噪、音量平衡、左右声道调换。
- 播放速度：提供固定速度刻度，Windows 鼠标滚轮每次只切换一个刻度。
- 声道平衡：支持左右声道平移，适合单耳或声场偏移内容。
- 标签面板：支持时间段标签、颜色、起止时间和片段循环播放。
- 功能状态图标：字幕、速度、均衡器、跳过空白、降噪、音量平衡、声道平衡和左右声道互换会显示在播放详情页右上角、播放列表卡片和底部播放卡片的播放按钮下方。

### 字幕

- 支持 `.srt`、`.ass`、`.ssa`、`.vtt`、`.lrc` 字幕。
- 会话详情、播放卡片和全局悬浮窗口同步当前字幕。
- 当音频加载失败时，会在详情页字幕区域以红字提示报错信息。
- 当音频仍在加载时，详情页字幕区域会显示“加载中”。
- Android 使用系统悬浮窗；Windows 使用可重复开启、拖动和交互的原生桌面字幕窗口。
- 字幕悬浮窗支持字体、字号、文字颜色、背景颜色、背景透明度和边框深度设置，并提供实时预览。

### 本地媒体库

- 支持导入文件夹、曲库和单独文件；Android 优先使用 SAF 并持久化目录授权。
- 根据文件树构建层级媒体库，支持自然排序、搜索、刷新扫描、排除目录和手动拖动排序。
- 支持封面发现、单独视频帧封面提取、作品详情编辑、封面候选选择、标题重命名和引用同步。
- 卡片实际使用的封面文件位置会保存到数据库和目录内 `nameless-audio.json`，再次打开曲库时优先校验并复用该索引。
- 可按分类、声优、社团、标签、RJ 号、发售日等信息整理本地作品。

### ASMR.ONE 与 DLsite

- 浏览、搜索、登录、收藏、历史、分类和个性化推荐。
- 在线读取作品文件树，将单文件或文件夹加入播放会话。
- 可选 ASMR.ONE 播放后缓存，播放过的在线音频可进入本地缓存。
- 支持选择作品文件或目录下载到本地，保留目录结构并生成元数据。
- ASMR.ONE 下载任务支持暂停和继续。
- 支持按 RJ 号、文件名或作品标题读取 DLsite 元数据，并可批量匹配和写入。

### 后台播放与计时

- Android 使用原生 `MediaSessionService`、Media3 / ExoPlayer、媒体前台服务和锁屏控制。
- 支持 CPU WakeLock、Wi-Fi Lock、服务恢复和息屏播放状态保护。
- 睡眠计时器支持立即倒计时或播放后开始、结束淡出、暂停会话和指定时间自动恢复。
- 开机、应用更新后可恢复计时状态。

### 设置、数据与更新

- 主题支持跟随系统、浅色和深色；界面支持中文、日文和英文。
- 支持 `.nalbackup` 数据备份、验证、恢复和失败回滚。
- 缓存管理覆盖封面、ASMR.ONE 播放缓存、视频帧、更新包和下载临时文件。
- 应用内更新从 GitHub Release 检查、下载、SHA-256 校验并安装。
- 点击更新后，下载进度会在页面最上方持续显示；下载失败时会保留错误信息，Windows 可直接打开更新日志。

## 应用内自动更新

每个更新资产必须同时发布同名 `.sha256` 校验文件：

```text
NamelessAudio-android-arm64-v0.13.0.apk
NamelessAudio-android-arm64-v0.13.0.apk.sha256
NamelessAudio-windows-x64-v0.13.0.zip
NamelessAudio-windows-x64-v0.13.0.zip.sha256
```

Android 下载 APK 并交给系统安装器。Windows 下载 ZIP 后启动独立更新器，更新器会验证 ZIP、等待应用退出、切换安装目录并重启新版本。

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
| `MANAGE_EXTERNAL_STORAGE` | 可选完整文件系统扫描；使用 SAF 时不需要 |
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
dart run tool/verify_release.dart --tag v0.13.0
```

### Android Release

Release 构建必须配置正式签名。缺少 `android/key.properties` 或对应 keystore 时构建会失败，不会回退到 debug 签名。

```powershell
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

### Windows Release

构建前确保 `assets/ffmpeg/ffmpeg.exe` 和 `assets/ffmpeg/ffprobe.exe` 存在。

```powershell
flutter build windows --release
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath dist\NamelessAudio-windows-x64-v0.13.0.zip -Force
```

## 发布流程

推送与 `pubspec.yaml` 版本一致的标签会触发 GitHub Actions：

1. 执行静态分析、Flutter 测试、Android JVM 测试和 Debug APK 构建。
2. 使用仓库 Secrets 中的正式签名构建 Android arm64 APK。
3. 下载并校验 FFmpeg，构建包含完整 libmpv 的 Windows ZIP。
4. 为两端资产生成 `.sha256` 并上传到同一个 GitHub Release。

```powershell
dart run tool/verify_release.dart --tag v0.13.0
git tag v0.13.0
git push origin main v0.13.0
```

完整变更见 [release_notes.md](release_notes.md)。
