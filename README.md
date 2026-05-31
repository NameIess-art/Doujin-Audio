# Nameless Audio

Nameless Audio 是一个 Flutter + Android 原生 + Windows 桌面混合实现的本地音频播放器，面向 ASMR、语音作品和大体量本地音频库。它同时支持 ASMR.ONE 在线浏览与下载、本地曲库管理、多会话播放、字幕、睡眠计时器、DLsite 元数据、视频转音频和应用内更新。

当前版本：`0.9.9+990`

最新发布页：[v0.9.9](https://github.com/NameIess-art/nameless-audio/releases/tag/v0.9.9)

许可证：[MIT](LICENSE)

隐私说明：[PRIVACY.md](PRIVACY.md)

> 注意：自 `v0.8.0` 起，Android `applicationId` 已从 `com.example.music_player` 改为 `com.nameless.audio`。旧包名版本不能直接覆盖安装到新版本上，升级前请先备份数据并重新安装。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android arm64-v8a | 主要发布目标 | 使用原生 Media3 / ExoPlayer、MediaSession、前台服务、通知、WakeLock 和精确定时闹钟 |
| Windows x64 | 桌面发布目标 | 使用 media_kit + 完整 libmpv，ZIP 包内包含 `libmpv-2.dll`、FFmpeg、FFprobe 和 Flutter 运行时 |

## 下载

从 [GitHub Release v0.9.9](https://github.com/NameIess-art/nameless-audio/releases/tag/v0.9.9) 下载：

| 文件 | 适用设备 |
|---|---|
| `app-arm64-v8a-release.apk` | 大多数 64 位 Android 手机，优先推荐 |
| `NamelessAudio-windows-x64-v0.9.9.zip` | Windows x64 桌面环境 |

Windows 版请解压整个 ZIP 后运行 `nameless_audio.exe`。不要只复制 exe，播放器、视频转音频和字幕窗口依赖同目录 DLL、`data/` 目录、MPV 与 FFmpeg 文件。

## 主要功能

### 播放与后台稳定性

- 多会话播放：可同时创建多个独立播放会话，每个会话单独控制播放、暂停、进度、循环、音量、字幕和左右声道调换。
- Android 原生播放核心：实际播放由 `NativePlaybackService`、Media3 / ExoPlayer、MediaSession、前台服务和 WakeLock 承载。
- Windows 桌面播放核心：使用 media_kit 与完整 libmpv，支持桌面音频播放、字幕同步和 Windows 自定义标题栏。
- 原生播放队列：非单曲循环时会把当前文件夹或跨文件夹队列下沉到 ExoPlayer，息屏后仍能继续上一首、下一首、顺序和随机播放。
- 多线程播放状态修正：以用户意图、`playWhenReady`、原生快照和 Dart 状态共同归一化播放按钮，减少播放/暂停 UI 回退。
- 音量增益：每个会话独立音量，支持超过 100% 的增益；Android 使用 `LoudnessEnhancer` 放大。
- 左右声道调换：按会话开启，Android 走原生声道映射，Windows 走 mpv 音频滤镜。
- 播放状态持久化：本地曲目的播放位置、收藏状态、会话顺序和队列会保存，重启后可恢复。
- 横竖屏恢复：Android 在横屏与竖屏切换后会重新测量底部导航、恢复当前页面并重新调度 UI warmup，减少空白或错位。
- 息屏后台播放增强：通过 `foregroundServiceType` 与唤醒锁机制保障息屏状态下的长时间稳定播放，不再受休眠超时打断。

### ASMR.ONE 在线播放与下载

- 分类浏览：支持收录、推荐、销量、评分、发售、收藏和历史分类。
- 分类显示设置：可按偏好选择 ASMR.ONE 首页展示入口，隐藏不常用分类，分类选择浮层采用双列网格排布。
- 个性化推荐：综合本地曲库、ASMR.ONE 收藏与播放历史，按标签、声优、社团、作品质量、新鲜度和小众匹配权重排序。
- 推荐刷新探索：刷新时基于随机种子调整完整候选顺序，避免内容固定。
- 搜索：支持作品名、标签、声优、社团和 RJ 号，多关键词分隔。
- 登录与收藏：可登录 ASMR.ONE，读取收藏列表，并添加或取消收藏作品。采用防丢策略存储凭证，避开系统 Keystore 漏洞。
- 作品详情：展示 RJ 号、社团、标签、声优、发售日、时长、销量、评分、评论数、年龄分级、语言版本和简介。
- 在线添加播放：读取作品音频树，把单个文件或文件夹节点加入播放队列。
- 字幕匹配：远端字幕会匹配到对应音频，支持标题缺少后缀、双扩展名等常见命名。
- 下载作品：可选择作品文件树中的文件或文件夹，保留目录结构下载到本地。
- 下载任务管理：显示准备、下载、完成、失败、跳过、失败数量、总大小和实时进度，支持取消并清理已下载内容。
- 元数据备份：下载作品时生成 `nameless-audio.json`，导入本地曲库后可恢复作品信息。

### 本地音频库

- 三种导入方式：导入文件夹、导入曲库、导入独立文件。
- Android SAF 优先：优先使用系统文档选择器导入 `content://` 资源并持久化授权，降低对完整文件管理权限的依赖。
- 层级媒体库：根据文件树生成层级节点，适合管理大量子文件夹。
- 后台扫描：大目录解析、路径去重和文件系统扫描 payload 处理会放到 Isolate 执行。
- 扫描进度：显示当前文件夹、已发现数量、重复数量和失败数量。
- 刷新监听目录：下拉刷新会重新扫描已导入目录，补齐新增文件并移除磁盘中已删除条目。
- 搜索与高亮：按名称搜索并显示匹配数量。
- 自然排序与手动排序：文件和文件夹按自然顺序排列，根目录支持拖拽排序。
- 曲库编辑：查看已导入曲库结构，排除或恢复文件夹和单曲，并把排除状态持久化到 SQLite。
- 临时文件导入：单独导入的文件不绑定监听目录，直到手动移除。

### 作品信息、DLsite 与封面

- 作品详情编辑：可编辑文件或文件夹名称、RJ 号、作品标题、社团、声优和标签。
- DLsite 元数据：优先按 RJ 号获取作品信息，RJ 缺失时按文件名、文件夹名或作品标题相似匹配，确认后写入。
- DLsite 多站点兜底：按语言请求 `maniax`、`home`、`girls`、`bl`、`books`、`pro` 等站点 JSON，失败时回退日文、HTML 解析和标题搜索。
- 元数据备份与恢复：详细信息自动备份到同目录 `nameless-audio.json`，数据库丢失时可恢复。
- 按标题重命名：可用作品标题重命名单个文件或文件夹，并同步曲库、封面、备份和播放会话引用。
- 自动 RJ 预填：导入文件夹时尝试从名称中提取 RJ 号。
- 自动封面发现：优先查找 `cover`、`folder`、`front`、`album`、`artwork`、`poster` 等常见图片。
- 视频帧封面：视频媒体可提取视频帧作为封面候选。
- 文件夹封面选择：详情页可左右滑动候选图片，停留后自动应用并全局同步。
- 封面预热：切换会话详情时预热相邻封面，减少闪烁。
- 加载状态统一：本地库、播放列表、播放卡片、ASMR.ONE 和 DLsite 网络封面加载时统一显示转圈或 shimmer。

### 播放列表、会话详情与字幕

- 会话列表：支持拖拽排序、左滑移除，并通过统一“更多”菜单支持暂停全部和清空全部。
- 底部播放卡片：可选常驻底部卡片，同步封面、进度、字幕和播放状态。
- 会话详情页：以封面作为模糊背景，提供进度条、快进快退、循环模式、音量、计时器、字幕和声道控制。
- 轨道切换：在会话详情页直接切换当前文件夹或分组内的其他音轨，无需新建会话。
- 字幕格式：支持 `.srt`、`.ass`、`.ssa`、`.vtt`、`.lrc`。
- 会话内字幕：会话详情页和播放卡片可显示当前字幕文本。
- 全局悬浮字幕：Android 使用系统悬浮窗服务，Windows 使用独立桌面子窗口；可跨页面或后台显示字幕。
- 字幕悬浮窗样式：支持字体、字号、文字颜色、背景颜色、背景透明度、背景模糊和边框深度，并提供实时预览。
- 字幕位置持久化：全局悬浮字幕位置按会话保存。

### 睡眠计时器

- 两种启动模式：立即开始倒计时，或等待播放开始后触发倒计时。
- 到点暂停：倒计时结束后通过 Android 原生链路暂停相关会话。
- 自动恢复：可在指定本地时间恢复被计时器暂停的会话。
- 秒级 UI 刷新：倒计时显示按可见秒数变化刷新，减少高频 Provider 通知。
- 原生闹钟与恢复：使用精确定时能力提升长时间后台、息屏和应用重启后的可靠性。
- 可靠性检查：计时器页检查通知权限、精确定时权限和后台运行条件，并提供跳转修复入口。

### 通知、权限与应用设置

- 统一播放通知：支持单会话和多会话通知样式，提供播放、暂停、上一首、下一首、恢复通知和清空通知。
- 富通知开关：关闭的是富播放通知样式，播放中仍保留系统前台通知以保证后台稳定。
- 后台运行引导：可跳转系统电池优化、后台运行、通知、悬浮窗、精确定时和未知来源安装设置。
- 沉浸式动效：主页面切换采用快速淡入淡出动效，不相邻页面切换直接跨级不渲染中间层。
- 设置页防卡顿：重构顶层架构，主题切换、开关选项触发均采用最小化局部渲染，保障交互顺滑。
- 深色模式：支持跟随系统或手动切换。
- 多语言：支持中文、日文和英文界面。
- 多线程播放开关：可控制是否允许多个活跃播放会话同时存在。
- 添加后自动播放：从音频库添加音频时可立即以播放状态创建会话。
- 缓存管理：可清理封面、视频帧、更新包和下载临时文件，并设置最大缓存上限。
- 应用内更新：Android 自动检测 GitHub Release 的 APK 并触发系统安装；Windows 自动检测 ZIP，下载后关闭当前程序、覆盖安装目录并重启。
- 自动检查更新：可选择每次打开应用时静默检查更新，仅发现新版本时弹窗提示。
- Tab 回顶：点击当前激活的 Tab 图标时，列表自动滚回顶部。

### 视频转音频

- 支持格式：输出 `mp3`、`aac`、`ogg`、`wav`、`flac`。
- 编码设置：MP3 / AAC / OGG 可设置码率；WAV / FLAC 使用格式内置编码参数。
- Windows FFmpeg：Windows 版使用随 ZIP 打包的 `ffmpeg.exe` 和 `ffprobe.exe`。
- 转换进度：显示实时进度，支持转换中取消。
- 输出防覆盖：自动避开与现有文件重名的输出路径。

## 支持的媒体格式

| 类型 | 格式 |
|---|---|
| 音频 | `flac`、`wav`、`mp3`、`m4a`、`aac`、`ogg`、`opus`、`3gp` |
| 视频，可播放或转音频 | `mp4`、`mkv`、`webm`、`mov`、`m4v`、`avi`、`3gp` |
| 字幕 | `.srt`、`.ass`、`.ssa`、`.vtt`、`.lrc` |

## Android 权限说明

| 权限 | 是否必须 | 用途 |
|---|---|---|
| `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE` | 视机型而定 | 兼容直接文件系统扫描与旧式文件选择流程 |
| `MANAGE_EXTERNAL_STORAGE` | 否 | 仅用于需要完整文件系统访问的机型或路径，不是 SAF 导入的前提 |
| `POST_NOTIFICATIONS` | 推荐 | 播放通知、后台控制和状态提示 |
| `SYSTEM_ALERT_WINDOW` | 仅全局字幕需要 | 允许悬浮字幕跨页面或后台显示 |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | 是 | 后台与息屏播放 |
| `WAKE_LOCK` | 是 | 降低息屏后 CPU 过早休眠导致播放中断的概率 |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | 推荐 | 引导用户允许后台运行或忽略电池优化 |
| `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` | 推荐 | 提升定时暂停和自动恢复可靠性 |
| `RECEIVE_BOOT_COMPLETED` | 推荐 | 系统重启或应用更新后恢复计时器状态 |
| `REQUEST_INSTALL_PACKAGES` | 仅应用内更新需要 | 下载新 APK 后触发系统安装流程 |
| `INTERNET` | 在线功能需要 | ASMR.ONE、DLsite、GitHub Releases 检查更新和下载 |

## 项目结构

```text
lib/
  i18n/                         中文、日文、英文文案
  models/                       曲目、曲库节点、播放会话、ASMR 和 DLsite 模型
  providers/                    AudioProvider 门面与功能拆分
  screens/                      ASMR.ONE、本地库、播放列表、计时器、设置、视频转音频
  services/                     SQLite、Native 桥接、更新、字幕、通知、权限、DLsite、ASMR 下载
  theme/                        主题与深色模式
  widgets/                      通用组件与业务组件
android/app/src/main/kotlin/    原生播放、通知、文件访问、计时器闹钟、保活服务、字幕悬浮窗
windows/                        Windows runner、完整 libmpv 下载与桌面打包配置
third_party/audio_service/      项目内维护的 audio_service fork
test/                           数据库、Provider、通知、计时器、播放桥接、ASMR 下载等测试
```

## 本地开发

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

### Android Release 构建

Release 构建需要签名密钥。仓库保留了本地验证用的回退逻辑：未配置 `android/key.properties` 时，会使用 debug signing 生成 release 模式 APK；正式发布前建议配置 release keystore。

```bash
flutter build apk --release --target-platform android-arm64
```

生成文件：

```text
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

### Windows Release 构建

Windows 构建会下载完整 libmpv，并把 `assets/ffmpeg/ffmpeg.exe`、`assets/ffmpeg/ffprobe.exe` 复制进构建产物。正式 ZIP 应压缩整个 Release 目录：

```powershell
flutter build windows --release
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath dist\NamelessAudio-windows-x64-v0.9.9.zip -Force
```

## audio_service fork notes

- 项目当前通过 `dependency_overrides` 指向 `third_party/audio_service`。
- Fork 相关定制说明位于 `third_party/audio_service/CUSTOMIZATION.md`。
- 后续同步上游时，请同时更新该说明文件中的来源版本、改动文件和保留原因。

## 发行说明 v0.9.9

- 修复了息屏长时间播放后由于 Android 保活机制打断导致的暂停问题。
- 重构页面切换动效，增加快速淡入淡出动画，且非相邻页面切换时不渲染中间层，提升切换跟手感。
- 修复 ASMR.ONE 账号在 Android 端因 Keystore 数据丢失导致登录信息重置的问题，使用本地防丢存储策略平滑迁移凭证。
- 修复设置页面大面积 Widget 重绘引起的明显卡顿，采用粒度化 `Consumer` 和状态分离以保证流畅度。
- 将播放列表中的“暂停全部”和“移除全部”合并进右上角的统一“更多”菜单中。
- 修复播放列表为空时，提示文案布局溢出顶部头界面的错位问题。
- ASMR.ONE 分类选择弹窗调整为更高效紧凑的两列竖排网格。
- 移除了单独视频卡片整片点击播放事件，优化了一轮封面图片的加载速度。
- 发布 Android arm64-v8a APK 与 Windows x64 ZIP，Windows ZIP 继续包含完整 libmpv、FFmpeg 和 FFprobe。

## 发行说明 v0.9.8

- 修复 Windows 应用内更新下载完成后只退出、不覆盖更新的问题；更新脚本会等待主进程退出，必要时请求管理员权限，失败时写入日志并显示提示。
- 修复 GitHub API 匿名限流导致“检查更新失败”的问题；API 失败时会回退到 GitHub Release 页面解析最新版本和下载资产。
- 修复 Windows 拉伸窗口大小时主页面 PageView 反复重建，导致音频库页面跳转和明显卡顿的问题。
- 发布 Android arm64-v8a APK 与 Windows x64 ZIP；Windows ZIP 继续包含完整 libmpv、FFmpeg 和 FFprobe。

## 发行说明 v0.9.71

- 修复 Android 点击搜索框时页面抽搐、焦点不稳定导致无法搜索的问题；键盘弹出不再触发横竖屏恢复用的页面重建。
- 修复“编辑曲库”菜单错误显示曲库根目录下子文件夹的问题；菜单只显示曲库根文件夹和真正独立导入的文件夹。
- 发布 Android arm64-v8a APK 与 Windows x64 ZIP，Windows ZIP 继续包含完整 libmpv、FFmpeg 和 FFprobe。

## 发行说明 v0.9.7

- 新增 Windows 应用内 ZIP 更新：Windows 会自动选择 GitHub Release 中的 ZIP，下载后关闭当前进程、解压覆盖安装目录并重启。
- 保持 Android 应用内更新原流程：Android 继续检测并下载 APK，仍通过系统安装器完成升级。
- 修复 Windows 左右声道调换无效问题，Windows 播放链路使用 mpv 音频滤镜，Android 继续使用原生声道映射。
- 修复全局字幕悬浮窗不显示的问题，恢复 Android 悬浮窗服务和 Windows 独立字幕窗口刷新。
- 优化横竖屏切换恢复，重新测量底部导航和当前页面，减少旋转后空白或布局错位。
- Windows Release ZIP 明确包含完整 libmpv、FFmpeg 和 FFprobe，确保播放与视频转音频功能可用。
- README 按当前代码重新梳理，补充 Windows 桌面、ZIP 更新、悬浮字幕、横竖屏恢复、FFmpeg 打包等未充分说明的功能。
- 清理仓库中的非项目必要文件：移除本地代理说明文件的 Git 跟踪，并删除临时 mpv 验证脚本。

## 近期重要变更

- `v0.9.9`：大幅优化后台稳定性、UI页面过渡动效、设置页面性能以及解决账户状态丢失的严重缺陷。
- `v0.9.8`：修复 Windows 应用内 ZIP 更新、GitHub API 限流导致检查更新失败、Windows 拉伸窗口时页面跳转卡顿；发布 Android arm64 与 Windows x64 ZIP。
- `v0.9.71`：修复 Android 搜索框点击后页面抽搐；修复编辑曲库菜单显示曲库根下子文件夹；发布 Android arm64 与 Windows x64 ZIP。
- `v0.9.7`：新增 Windows ZIP 自更新；修复 Windows 声道调换、全局悬浮字幕和横竖屏切换恢复；发布 Android arm64 与 Windows x64 ZIP。
- `v0.9.6`：修复多线程播放按钮回退；优化封面加载转圈、ASMR.ONE 封面主动加载、列表滚动性能、封面解析和 Warmup 调度；更新 README。
- `v0.9.5`：优化曲库扫描性能和扫描进度；改进 ASMR.ONE 推荐页刷新、算法和加载行为；更新 README；清理非必要文件。
- `v0.9.4`：持久化播放位置与收藏状态，优化重启后的曲库和会话恢复体验。
- `v0.9.3`：优化 ASMR.ONE 推荐算法，综合本地曲库、收藏和历史画像，提高稀有标签、声优、社团的小众作品召回。
- `v0.9.2`：修复外部删除文件夹后的曲库编辑残留、视频文件封面缺失和日语长文本截断，并增强 DLsite 多站点与 HTML 兜底读取。
- `v0.9.1`：新增 DLsite 数据读取语言设置，设置页“播放”分区更名为“功能”，同步更新版本号与发布包。
- `v0.9.0`：修复息屏临时音频焦点暂停后恢复不及时的问题，更新发布文档。
