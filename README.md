# AudioPlayer

基于 Flutter 的 Android 本地音频播放器，专为同人音声/ASMR 音频库场景设计。支持多会话并行播放、通知栏分组控制、封面递归发现、睡眠计时器、视频转音频等能力。

## 功能亮点

- **多会话播放** — 多个音频会话并行播放，每个独立控制，支持播放/暂停/切歌/进度/音量
- **通知栏控制** — 分组摘要通知 + 子会话通知，支持 Android 13+ 前台服务
- **智能扫描** — 递归发现文件夹中的音频文件和封面图，实时显示扫描进度
- **播放策略** — 单曲循环、随机播放、列表循环、跨文件夹顺序播放
- **睡眠计时器** — 手动启动或播放时自动触发，支持淡出效果
- **视频转音频** — 基于 ffmpeg 提取视频中的音频轨道
- **封面发现** — 支持 `cover.jpg/png` 和 `content://` 来源的封面图
- **搜索过滤** — 胶囊搜索栏，页面向下滚动时自动隐藏
- **多语言** — 支持简体中文、日本語、English
- **主题切换** — Material 3 浅色/深色模式
- **版本更新** — 自动检测 GitHub Release 最新版本

## 当前版本

- 版本号：`1.1.0+6100`
- GitHub Release：[v1.1.0](https://github.com/NameIess-art/AudioPlayer/releases/tag/v1.1.0)

## 技术栈

- Flutter `3.41.x` / Dart `3.11.x`
- `just_audio` — 音频播放引擎
- `audio_service` — Android 前台服务与通知集成（`third_party/` 下维护定制版本）
- `provider` — 状态管理
- `sqflite` — 播放会话持久化
- `ffmpeg_kit_flutter_new_audio` — 视频音频提取
- `shared_preferences` — 用户偏好存储
- `google_fonts` — 字体

## 项目结构

```text
lib/
  main.dart                        # 应用入口
  i18n/                            # 国际化 (zh/ja/en)
  models/                          # 数据模型
  providers/                       # Provider 状态管理
  screens/                         # 页面 (library/playlist/timer/video/settings)
  services/                        # 业务服务 (通知/持久化/更新检查)
  theme/                           # 主题管理
  widgets/                         # 通用组件

android/
  app/src/main/kotlin/             # Kotlin 原生代码 (MainActivity, 通知服务等)

third_party/
  audio_service/                   # 定制版 audio_service
```

## 快速开始

```bash
flutter pub get
flutter run
```

指定设备：

```bash
flutter devices
flutter run -d <device-id>
```

## 构建

调试包：

```bash
flutter build apk --debug
```

发布包（arm64）：

```bash
flutter build apk --release --target-platform android-arm64
```

多架构发布包：

```bash
flutter build apk --release --target-platform android-arm64 --target-platform android-arm --target-platform android-x64
```

## 主要页面

| 页面 | 说明 |
|---|---|
| 音频库 | 浏览已导入的本地音频，支持搜索、排序和扫描进度反馈 |
| 播放列表 | 管理活跃播放会话，支持滑动关闭和快速控制 |
| 计时器 | 配置睡眠计时器时间和触发方式 |
| 视频转换 | 从视频文件中提取音频 |
| 设置 | 主题/播放/通知偏好，缓存清理，版本信息 |

## 说明

- 当前主要在 Android 平台验证使用
- `third_party/audio_service` 为定制版本，针对通知栏行为和 Android 播放链路做了修改
- 视频转换依赖设备上的 ffmpeg 运行时，失败时请检查存储权限和源文件可读性
- 自动更新检查通过 GitHub Release Tag（`v` + 版本号）判断是否有新版本
