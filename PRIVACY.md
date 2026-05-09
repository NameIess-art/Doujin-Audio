# 隐私说明

**Nameless Audio** 是一款完全离线的本地音频播放器。我们高度重视您的隐私。

## 数据收集

**Nameless Audio 不收集、不上传、不分享任何个人数据或使用数据。** 应用没有集成任何第三方分析、统计、广告或遥测 SDK。

## 本地存储的数据

以下数据仅存储在您的设备本地，不会以任何形式传输至外部：

| 数据类型 | 存储位置 | 用途 |
|---|---|---|
| 音频文件路径与元数据 | SQLite 数据库（`audio_player.db`） | 曲库管理与播放 |
| 播放会话状态（进度、音量、循环模式等） | SQLite 数据库 / SharedPreferences | 恢复播放状态 |
| 自定义封面路径 | SQLite 数据库 | 封面图片关联 |
| 字幕文件路径与缓存 | 本地文件系统 | 字幕解析与显示 |
| 应用设置（语言、主题、播放偏好等） | SharedPreferences | 用户偏好持久化 |
| 计时器状态 | SharedPreferences / Native Alarm | 睡眠计时器功能 |

## 权限使用说明

| 权限 | 用途 | 是否必需 |
|---|---|---|
| `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE` | 扫描和播放您选择的本地音频文件 | 是 |
| `MANAGE_EXTERNAL_STORAGE` | 完整本地音频库扫描 | 可选 |
| `POST_NOTIFICATIONS` | 显示播放控制通知（Android 13+） | 是 |
| `FOREGROUND_SERVICE` | 后台与息屏稳定播放 | 是 |
| `WAKE_LOCK` | 防止息屏后 CPU 过早休眠 | 是 |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | 引导允许后台运行 | 可选 |
| `SCHEDULE_EXACT_ALARM` | 睡眠计时器到点暂停与自动恢复 | 可选 |
| `REQUEST_INSTALL_PACKAGES` | 应用内下载新版本 APK 后触发安装 | 可选 |
| `INTERNET` | 检查 GitHub Release 更新、下载 FFmpeg 组件 | 可选 |

## 第三方服务

- **GitHub Release API**：当您主动检查更新时，应用会通过 HTTPS 请求 GitHub API 获取最新版本信息。此过程不包含任何个人数据。
- **FFmpeg Kit**：视频转音频功能使用开源的 FFmpeg Kit 库，所有处理均在设备本地完成。

## 数据安全

- 所有数据仅存储在您的设备本地文件系统中。
- 应用不包含任何网络请求（除上述更新检查和 FFmpeg 组件下载外）。
- 您可以通过系统设置或卸载应用完全清除所有本地数据。

## 儿童隐私

本应用不面向 13 岁以下儿童，不会有意收集儿童的个人信息。

## 变更

本隐私说明可能随应用更新而调整。重大变更将在应用更新说明中告知。

## 联系

如有隐私相关问题，请通过 GitHub Issues 联系我们：[github.com/NameIess-art/nameless-audio/issues](https://github.com/NameIess-art/nameless-audio/issues)

---

*最后更新：2026 年 5 月 9 日*
