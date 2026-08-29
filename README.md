# Doujin Audio

Doujin Audio 是一款面向 ASMR、语音作品和本地媒体库的 Android 播放器，使用 Flutter 与 Android 原生 Media3 / ExoPlayer 实现。

当前版本以 [`pubspec.yaml`](pubspec.yaml) 为唯一来源；正式安装包和更新均来自发布页：[GitHub Latest Release](https://github.com/NameIess-art/Doujin-Audio/releases/latest)。

[GPL-3.0 License](LICENSE) · [隐私说明](PRIVACY.md) · [安全说明](SECURITY.md)

如果 Doujin Audio 对你有帮助，欢迎通过[爱发电](https://ifdian.net/a/nameIess)自愿支持项目的开发与维护。赞助不解锁付费功能，应用主要功能会继续免费提供。

## 下载

> **升级提示：**当前 Doujin Audio 使用新的 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。应用仅接受由当前版本创建的 `.dabackup` 备份，不提供旧数据或旧备份格式的自动迁移。

| 平台 | 发布资产 | 说明 |
|---|---|---|
| Android universal | `DoujinAudio-android-universal-<tag>.apk` | 推荐普通用户下载，兼容 arm64-v8a、armeabi-v7a 和 x86_64 |
| Android arm64-v8a | `DoujinAudio-android-arm64-<tag>.apk` | 适用于大多数现代 64 位 Android 手机，安装包较小 |
| Android armeabi-v7a | `DoujinAudio-android-armv7-<tag>.apk` | 适用于旧款 32 位 ARM Android 设备 |
| Android x86_64 | `DoujinAudio-android-x64-<tag>.apk` | 适用于 x86_64 Android 设备或模拟器 |

本项目仅通过 GitHub Release 正式分发，不提供应用商店 AAB 或 iOS 安装包。

### 第一次使用

1. 下载 universal APK 并安装；如果系统提示来源限制，请在系统设置中允许本应用安装用户主动下载的更新。
2. 在“本地音频库”中通过系统文件夹选择器添加曲库，或直接添加文件/文件夹。
3. 点按作品或音频开始播放；需要在线内容时，再在 ASMR.ONE 页面登录即可。

应用默认本地优先：音频库、设置和播放状态保存在设备上，网络仅用于在线内容、元数据和 GitHub 更新。权限会在使用对应功能时按需请求。

## 主要功能

### 播放与控制台

- 多会话播放：同时保留多个独立播放会话，分别控制曲目、进度、音量、循环、字幕、队列和音效。
- 播放列表支持长按进入批量选择，可批量播放、暂停或移除会话；多选播放会遵循多会话播放设置。
- 播放范围：支持单曲循环、当前文件夹顺序/随机、跨文件夹顺序/随机，以及到期即停的单次播放模式。
- 传输控制：播放/暂停、上一首/下一首、快退/快进、进度拖动、播放失败重试。
- 本地视频播放：视频文件在播放详情页的封面区域直接显示画面，轻触后可进入沉浸式横屏全屏；播放进度、队列、音效和通知栏继续复用同一播放会话，也可在设置中关闭视频画面并仅播放音频。
- ASMR.ONE 音频在准备或缓冲时，播放列表卡片和播放详情页的播放按钮会显示转圈图标，字幕区域同步提示“加载中”；点击转圈按钮可继续切换播放状态，播放错误时仍可直接重试。
- 控制台功能栏：均衡器、功能、播放速度、标签、声道平衡都可在播放详情页直接打开。
- 单独导入的音频文件与其他本地音频共用标准封面和播放详情布局，不再使用独立控制台样式。
- 均衡器：支持设备频段、自带预设、自定义频段增益和持久化。
- 功能面板：支持跳过空白、轻度降噪、音量平衡、左右声道调换。
- 播放速度：支持 0.25x 至 4.0x 范围调节，提供常用快捷倍速预设与平滑微调滑块。
- 声道平衡：支持左右声道平移，适合单耳或声场偏移内容。
- 标签面板：支持时间段标签、颜色、起止时间和片段循环播放。
- 功能状态图标：字幕、速度、均衡器、跳过空白、降噪、音量平衡、声道平衡和左右声道互换会显示在播放详情页右上角、播放列表卡片和底部播放卡片的播放按钮下方。

### 字幕

- 支持 `.srt`、`.ass`、`.ssa`、`.vtt`、`.lrc` 字幕。
- 会话详情、播放卡片和全局悬浮窗口同步当前字幕。
- 当音频加载失败时，会在详情页字幕区域以红字提示报错信息。
- 当音频仍在加载时，详情页字幕区域会以淡入淡出效果显示“加载中”，封面尺寸变化也会平滑过渡；快退、快进或拖动进度后会先等待短暂阈值，避免瞬时缓冲造成界面闪烁。
- Android 使用系统悬浮窗显示全局字幕。
- 字幕悬浮窗支持字体、字号、文字颜色、背景颜色、背景透明度和边框深度设置，并提供实时预览。
- 时间轴字幕支持手动滚动并吸附到最近字幕，停止浏览后自动回到当前播放字幕；点击定位按钮可跳转到所选时间点。

### 本地媒体库

- 支持添加文件夹、曲库和单独音频文件；Android 优先使用 SAF 并持久化目录授权。
- 根据文件树构建层级媒体库，支持按名称、声优、时长、发售时间或添加时间排序，也支持搜索、刷新扫描、排除目录和手动拖动排序。
- 展开的文件夹在刷新子项时保持可见；大型媒体库的文件夹展开、搜索和列表更新按可见范围处理，减少无关重建。
- Android 原生目录扫描支持 chunk 事件回传；添加大型媒体库时按批次合并并提交到现有曲库状态，减少一次性累积大量扫描结果造成的内存峰值。
- 播放详细页进度条精简：播放详细页进度条上下占位高度调整为精简 34px，分段背景与标记图标动态居中对齐；底部导航栏“本地音频库”与“ASMR.ONE”图标支持 350ms 长按快捷切换及左右滑动切换。
- 支持封面发现、单独视频帧封面提取、作品详情编辑、封面候选选择、标题重命名和引用同步。
- 封面显示按 300px、600px、900px、1200px 或原画策略解码；外观设置中新增“优先使用音频内嵌封面”配置选项，未手动设定封面时优先使用音频内嵌图像。
- 已移除目录管理：从媒体库中永久移除的文件夹支持持久化保存，可在单独的“已移除目录”管理界面中随时查看或恢复。
- 文件夹或单文件重命名时会同步更新封面索引，失效路径自动回退到现有发现流程。
- 详情信息以 SQLite 作为运行时数据源，目录内 `doujin-audio.json` 作为可移植导入/导出文档；声优和标签使用有序关系表保存，不再依赖数据库内 JSON 字符串。
- 添加文件、文件夹或曲库、刷新扫描、自动补时长/RJ 和启动维护只读取已有 JSON，不会创建、清空或改写目录中的任何 JSON 文件。
- 只有用户明确保存作品详情或导入 DLsite 资料时才更新应用自有的 `doujin-audio.json`；保存会原子合并已知字段，并保留未知字段及数组中的其他条目。
- 详情页选定的封面会保存到数据库和 `doujin-audio.json`：目录图片记录相对路径，音频内嵌封面和视频帧同时保存可恢复的图片数据，移除后重导入时仍会优先显示该封面。

### ASMR.ONE 与 DLsite

- 浏览、搜索、登录、收藏、历史、分类和个性化推荐。
- 在线读取作品文件树，将单文件或文件夹加入播放会话。
- 可选 ASMR.ONE 播放后缓存，播放过的在线音频可进入本地缓存。
- 支持选择作品文件或目录下载到本地，保留目录结构并生成元数据。
- ASMR.ONE 下载任务支持暂停、继续和失败后重试；应用进入后台或退出时会先安全暂停任务，恢复时可复用已校验的临时文件继续下载。单个文件遇到瞬时网络错误、响应截断或服务端临时错误时默认自动重试 5 次，可在 3–10 次之间调整；同时下载的作品数可在 1–5 之间设置。下载任务页和文件详情会显示当前重试次数，并可将作品封面保存到下载根目录的 `Cover/<RJ号>.<扩展名>`。
- 已选择的 ASMR.ONE 下载目录会持久保留 Android SAF 授权，应用重启后无需重复选择。
- 下载目录中任何已存在的 `.json` 文件都保持原始字节不变，不受跳过、重命名或覆盖策略影响；新 JSON 仅在下载完整、非空且解析有效后创建。
- 支持按 RJ 号、文件名或作品标题读取 DLsite 元数据，并可批量匹配和写入。

### 视频转音频

- 从本地选择视频文件和输出目录，将视频音轨转换为 MP3、AAC、OGG、WAV 或 FLAC。
- MP3、AAC、OGG 可选择输出码率；WAV 和 FLAC 使用格式自身的编码参数。
- 转换过程显示进度，支持取消；完成后直接提示输出文件位置。

### 后台播放与计时

- Android 使用原生 `MediaSessionService`、Media3 / ExoPlayer、媒体前台服务和锁屏控制。
- Android 通知栏媒体控制、锁屏控制和前台媒体服务复用同一套原生 MediaSession 路径，操作顺序与应用内一致并支持中、英、日系统语言。
- 支持 CPU WakeLock、Wi-Fi Lock、服务恢复和息屏播放状态保护。
- 播放遇到临时网络、I/O 或 AudioTrack 错误时，会在 10 分钟恢复窗口内按退避计划重试；网络恢复或亮屏会立即触发一次恢复。
- Android 诊断报告包含最近一次进程退出原因；检测到 vivo/OriginOS 后台清理时会提示打开后台高耗电或自启动设置。系统真正执行“强行停止”后，Android 不允许应用自行重启。
- 睡眠计时器支持立即倒计时或播放后开始、结束淡出、暂停会话和指定时间自动恢复。
- 开机、应用更新后可恢复计时状态。

### 设置、数据与更新

- 主题支持跟随系统、浅色和深色，可选择应用主题颜色；应用启动图标与播放通知图标会同步当前明暗主题和所选主题色。开启“ASMR.ONE 独立配色”后还可单独选择 ASMR.ONE 主题颜色，浅色与深色页面都会随主色融合变化。界面支持中文、日文和英文。
- 可选择启动页（ASMR.ONE、本地音频库或播放列表）、底部导航样式、竖屏锁定、操作震动和减少动画；页面、对话框与底部面板复用统一的方向切换和淡入淡出动效，并遵循减少动画设置。
- 播放详情支持简洁字幕或时间轴字幕；可配置封面清晰度、背景模糊、界面毛玻璃和卡片显示字段。
- Android 可分别设置耳机或蓝牙断开、短暂音频焦点丢失、通话等中断结束后的播放行为，并可选择启动恢复时继续播放或保持暂停。
- Android 音频焦点策略可选“标准”或“与其他应用混音”；混音模式不会抢占其他应用的音频焦点。
- 播放列表支持创建多个命名队列，按名称、时长或添加时间排序，拖动调整顺序，并可编辑队列音频和卡片颜色；默认以作品为单位替换重复会话，也可允许相同作品并存。
- “数据与支持”可导出脱敏诊断报告，并提供隐私摘要，便于反馈问题时控制共享范围。
- “数据与支持”可将数据库、设置、播放记录和 ASMR.ONE 账号流式导出为 `.dabackup`，恢复前会校验内容并在下次启动时原子替换；恢复失败会回滚到原有数据。备份包含敏感账号信息，应妥善保管。
- 存储空间页面会区分本地音频库、应用缓存、其他占用和剩余空间，并支持重新读取统计结果。
- 缓存管理覆盖封面、ASMR.ONE 播放缓存、视频帧、更新包和下载临时文件。
- 应用内更新从 GitHub Release 检查、下载、SHA-256 校验并安装。
- 点击更新后，下载进度会在页面最上方持续显示；下载失败时会保留错误信息。
- 启动自动检查与设置页手动检查复用同一更新流程，权限、下载校验、失败重试和安装反馈保持一致。

## 应用内自动更新

每个更新资产必须同时发布同名 `.sha256` 校验文件：

```text
DoujinAudio-android-universal-<tag>.apk
DoujinAudio-android-universal-<tag>.apk.sha256
DoujinAudio-android-arm64-<tag>.apk
DoujinAudio-android-arm64-<tag>.apk.sha256
DoujinAudio-android-armv7-<tag>.apk
DoujinAudio-android-armv7-<tag>.apk.sha256
DoujinAudio-android-x64-<tag>.apk
DoujinAudio-android-x64-<tag>.apk.sha256
```

Android 应用内自动更新会按设备 ABI 下载对应的 arm64、armv7 或 x64 APK，并校验同名 `.sha256` 后交给系统安装器；无法识别 ABI 时回退到 universal APK。

## 支持格式

| 类型 | 格式 |
|---|---|
| 音频 | `flac`、`wav`、`mp3`、`m4a`、`aac`、`ogg`、`opus`、`3gp` |
| 视频 | `mp4`、`mkv`、`webm`、`mov`、`m4v`、`avi`、`3gp` |
| 字幕 | `.srt`、`.ass`、`.ssa`、`.vtt`、`.lrc` |

## 代码结构

- `lib/app`：应用壳、主页面、本地化、主题和显式运行时装配；Riverpod
  直接投影 Library / Playback / Timer /
  Notification / Settings 五个状态所有者，并由 presentation controller
  管理滚动与轮播定位。
- `lib/core`：错误、日志、平台网关、SQLite 持久化、共享媒体对象和通用组件。
- `lib/features`：library、player、ASMR、settings、data-support 和 video-converter 的 domain/application/presentation 代码。
- Android 原生代码按 `channel`、`scanner`、`storage`、`metadata`、`subtitle`、`update` 和 `player/*` 分包；根包仅保留 `MainActivity`。

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

```powershell
flutter pub get
flutter analyze
flutter test
$tag = dart tool/verify_release.dart --print-tag
dart run tool/verify_release.dart --tag $tag
```

### Android Release

Release 构建必须配置正式签名。缺少 `android/key.properties` 或对应 keystore 时构建会失败，不会回退到 debug 签名。

```powershell
flutter build apk --release
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64,android-x64
```

## 发布流程

推送与 `pubspec.yaml` 版本一致的标签会触发 GitHub Actions：

1. 执行静态分析、Flutter 测试、Android JVM 测试和 Debug APK 构建。
2. 使用仓库 Secrets 中的正式签名构建 Android universal、arm64、armv7 和 x64 APK。
3. 为全部资产生成 `.sha256`，逐个验证签名和 ABI 后暂存为 CI artifacts。
4. Android 构建成功后创建草稿 Release，核对完整资产列表，再公开为 GitHub Latest。

```powershell
$tag = dart tool/verify_release.dart --print-tag
dart run tool/verify_release.dart --tag $tag
git tag $tag
git push origin main $tag
```

完整变更见 [release_notes.md](release_notes.md)。
