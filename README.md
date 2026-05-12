# Nameless Audio

Nameless Audio 是一个面向 Android 本地音频库、多会话播放、ASMR、长音频和字幕场景的 Flutter 音频播放器。  
界面和业务状态由 Flutter 承载，后台播放、通知控制、息屏保活、定时暂停/自动恢复、文件扫描与系统权限跳转由 Android 原生能力兜底。

当前版本：`0.8.1+801`  
最新发布页：[v0.8.1](https://github.com/NameIess-art/nameless-audio/releases/tag/v0.8.1)  
许可证：[MIT](https://github.com/NameIess-art/nameless-audio/blob/main/LICENSE)  
隐私说明：[PRIVACY.md](https://github.com/NameIess-art/nameless-audio/blob/main/PRIVACY.md)

> 注意：自 `v0.8.0` 起，Android `applicationId` 已从 `com.example.music_player` 变更为 `com.nameless.audio`。旧包名版本无法直接覆盖安装到新版本上，升级前请先备份并重新安装。

## 主要功能

- 多会话播放：可同时创建多个播放会话；每个会话独立控制播放/暂停、进度、音量、循环模式和左右声道互换。
- Android 原生后台保活：通知、前台服务、WakeLock、精确闹钟和原生播放服务协同工作，提升长时间后台与息屏播放稳定性。
- 睡眠计时器：支持手动倒计时、播放触发倒计时、到点暂停，以及暂停后在指定本地时间自动恢复播放。
- 三种音频导入：支持导入单个文件、导入单个文件夹、导入整个资料库（父目录下的多一级子目录）。
- 原生优先导入兼容：Android 上优先使用系统文档选择器（SAF）导入 `content://` 资源，并保留回退路径，降低不同 ROM/文件管理器差异带来的失败率。
- 音频库管理：支持扫描、刷新、去重、搜索、根目录拖拽排序、左滑移除，以及资料库排除/恢复编辑。
- 封面与字幕：支持自动发现封面、手动自定义封面、字幕解析缓存、会话内字幕和通知字幕。
- 跨页面/后台字幕显示：支持全局字幕悬浮窗，并可调整字体、字号、颜色、背景模糊、透明度和边框深度。
- 应用内更新：可检查 GitHub Releases、下载新版 APK，并在需要时提前提示“允许安装未知来源应用”。
- 权限前置提示：涉及通知、未知来源安装、悬浮窗、后台运行等权限的操作，会先提示再跳设置；用户返回应用后会自动续执行原操作。
- 视频转音频：基于 FFmpeg 将视频转换为 `mp3`、`aac`、`ogg`、`wav`、`flac`，支持码率选择与实时进度。

## 三种导入方式有什么不同

在音频库页右下角 `+` 菜单中有三种导入方式：

| 方式 | 适合场景 | 会导入什么 | 后续刷新行为 |
|---|---|---|---|
| 导入文件夹 | 你只想监听一个固定目录 | 扫描该目录及其子目录中的音频文件，并把这个目录加入监听列表 | 下拉刷新时会重新扫描这个目录 |
| 导入曲库 | 你有一个“大目录”，里面每个一级子目录都是一套内容 | 会把所选根目录下的一级子目录分别加入监听；根目录里散落的音频也会一并导入 | 下拉刷新时会重新扫描整套资料库结构，并保留排除规则 |
| 导入文件 | 你只想临时/零散加入几首音频 | 只导入手动选中的音频文件，标记为“单曲”，不绑定到某个监听文件夹 | 不参与文件夹扫描；文件仍保留在库中，直到你手动移除 |

### Android 上的实际导入策略

- 导入文件夹 / 导入资料库：优先使用系统文档树选择器（SAF），拿到持久化读取授权；如果设备 ROM 的文档界面不可用，会回退到旧的文件夹选择流程。
- 导入文件：优先使用系统文档文件选择器（支持多选），直接保留 `content://` 访问授权；部分设备不支持时会回退到旧文件选择流程。
- 这意味着很多机型上即使没有完整文件管理权限，仍然可以成功导入和播放用户明确选择的文件或目录。

## 使用说明

### 音频库

- 下拉刷新会重新扫描当前所有监听目录和资料库。
- 支持搜索高亮、根目录拖拽排序、左滑移除。
- 资料库存在时，可进入“编辑资料库”页面，对文件夹或单曲做排除/恢复。

### 播放列表与详情页

- 从音频库点击文件或文件夹即可创建播放会话。
- 播放列表支持拖拽排序、批量暂停全部、清空全部。
- 详情页支持左右滑动切换相邻会话、下拉关闭详情页。
- 详情页支持 5 秒快进/快退、缓冲进度显示、剩余时间显示、会话独立音量和声道互换。

### 封面

- 自动封面会优先查找常见文件名，如 `cover`、`folder`、`front`、`album`、`artwork`。
- 长按详情页封面可以进入自定义封面选择模式，左右滑动浏览当前音频所在根目录中的图片并确认替换。
- 自定义封面会同步刷新详情页、音频库卡片、播放列表卡片和底部播放卡片。

### 字幕

- 支持解析常见字幕文件，如 `.srt`、`.ass`、`.ssa`、`.vtt`、`.lrc`。
- 可在详情页三点菜单里打开/关闭字幕。
- 启用“字幕全局显示”前，会先提示开启悬浮窗权限；回到应用后会自动继续该操作。
- 字幕悬浮窗样式可在设置页中调整并持久化保存。

### 睡眠计时器

- 支持手动倒计时和播放触发倒计时两种模式。
- 到点后统一走 Android 原生执行链路暂停播放。
- 可选择在指定本地时间自动恢复播放。
- 计时器页和设置页会显示通知权限、精确闹钟、电池优化状态，帮助判断超长后台场景下的可靠性。

### 应用内更新

- 可在设置页检查 GitHub 最新版本。
- 下载更新前会先检查“允许安装未知来源应用”权限。
- 若系统尚未授权，会先弹出提示框，再跳转系统设置；用户返回应用后会自动继续安装流程。

## 权限说明

| 权限 | 是否必须 | 用途 |
|---|---|---|
| `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE` | 视机型而定 | 兼容直接文件系统扫描与旧式文件选择流程 |
| `MANAGE_EXTERNAL_STORAGE` | 否 | 仅用于需要完整直接文件系统访问的机型/路径；不是 SAF 导入的前提 |
| `POST_NOTIFICATIONS` | 推荐 | 播放通知、后台控制、状态提示 |
| `SYSTEM_ALERT_WINDOW` | 仅字幕全局显示需要 | 允许悬浮字幕跨页面/后台显示 |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | 是 | 后台与息屏播放 |
| `WAKE_LOCK` | 是 | 降低息屏后 CPU 过早休眠导致播放中断的概率 |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | 推荐 | 引导用户允许后台运行/忽略电池优化 |
| `SCHEDULE_EXACT_ALARM` | 推荐 | 提升定时暂停和自动恢复在长时间后台场景下的可靠性 |
| `REQUEST_INSTALL_PACKAGES` | 仅应用内更新需要 | 下载新 APK 后触发系统安装流程 |
| `INTERNET` | 仅更新检查需要 | 检查 GitHub Releases 与下载更新 |

## 下载

从 [GitHub Release v0.8.1](https://github.com/NameIess-art/nameless-audio/releases/tag/v0.8.1) 下载适合设备 CPU 架构的 APK：

| 文件 | 适用设备 |
|---|---|
| `app-arm64-v8a-release.apk` | 大多数 64 位 Android 手机，优先推荐 |
| `app-armeabi-v7a-release.apk` | 较老的 32 位 Android 设备 |
| `app-x86_64-release.apk` | x86_64 模拟器或少量 x86 Android 设备 |

如果不确定设备架构，优先尝试 `app-arm64-v8a-release.apk`。

## 项目结构

```text
lib/
  i18n/                         多语言文案
  models/                       MusicTrack、LibraryNode、PlaybackMode
  providers/                    AudioProvider 门面与功能拆分
  screens/                      音频库、播放列表、计时器、设置、视频转音频
  services/                     SQLite、Native 桥接、更新、字幕、通知、权限控制
  widgets/                      通用组件与业务组件

android/app/src/main/kotlin/    原生播放、通知、扫描、计时闹钟、保活服务
third_party/audio_service/      项目内维护的 audio_service fork
test/                           数据库、Provider、通知、计时器等测试
```

## 本地开发

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

### Release 构建

Release 构建需要签名密钥。默认可回退为 debug 签名做本地验证，正式发布前请配置 release keystore。

```bash
flutter build apk --release --split-per-abi
```

该命令会生成三个 APK：

- `app-arm64-v8a-release.apk`
- `app-armeabi-v7a-release.apk`
- `app-x86_64-release.apk`

## audio_service fork notes

- 项目当前通过 `dependency_overrides` 指向 `third_party/audio_service`。
- Fork 相关定制说明位于 `third_party/audio_service/CUSTOMIZATION.md`。
- 若后续同步上游，请同时更新该说明文档中的来源版本、改动文件和保留原因。

## 发行说明 v0.8.1

- 优化主界面切页流畅度，增加主 Tab 常驻、封面/字幕预热和稳定缓存。
- 重构 Android 原生计时器权威链路，提升长时间后台、熄屏、定时暂停与自动恢复的稳定性。
- Android 导入改为原生系统文档选择器优先，提升不同品牌手机上的导入成功率。
- 新增权限前置提示与“返回应用后自动续执行”机制，覆盖更新安装权限与字幕悬浮窗权限等关键场景。
- 设置页和计时器页新增通知权限、精确闹钟和后台运行状态提示。
