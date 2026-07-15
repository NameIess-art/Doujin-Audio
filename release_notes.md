# Nameless Audio Release Notes

> **升级前必读：**从不兼容的旧版本升级到本 Release 时，必须先卸载旧版本再重新安装。卸载会清除应用数据，建议先在“数据支持”中导出 `.nalbackup` 备份。具体兼容范围以本次发布说明为准。

## 播放与队列

- 修复播放队列中单独导入的音频或视频不能正确切换音频、上一首或下一首的问题。
- 播放队列按用户排列顺序前进，重复添加同一路径时也会切换到正确的队列索引。
- 改进多会话播放、通知栏控制、Windows SMTC、播放意图同步和网络错误恢复。
- 完善音频焦点、后台服务、睡眠计时器、字幕悬浮窗和进程恢复行为。

## ASMR.ONE

- 增加 ASMR.ONE API 多域名故障切换，修复网关拒绝、封面加载和在线媒体地址兼容问题。
- 同一作品支持有界并发下载、连接复用和本地原子临时文件写入，减少重复连接和磁盘复制。
- 改进收藏、历史、推荐、播放缓存、下载暂停/继续和错误恢复。

## 媒体库、数据与性能

- Android 文件夹扫描支持增量批次、及时取消、generation 隔离和不完整扫描删除保护。
- 优化大型媒体库树、搜索、封面缓存、列表重建和播放进度更新性能。
- 加强数据库维护锁、备份恢复回滚、SQLite 大批量删除和 ASMR outbox 原子保存。
- 修复封面作用域、Windows 回到顶部、视频转换取消和多处生命周期资源清理问题。

## 架构与质量

- 播放会话运行时已移出 domain，domain 不再依赖 Flutter、播放器 SDK 或上层模块。
- 更新安装与字幕悬浮窗平台调用统一进入可注入的 `core/platform` 网关，保持原有 Channel 协议不变。
- 覆盖率校验改为按目录聚合，并在配置路径无覆盖数据、LCOV 为空或低于门槛时失败。
- 新增架构边界和平台畸形 envelope 回归测试；升级 `audio_session`、`just_audio` 与 `path_provider` 的兼容 patch 版本。

## 发布资产

```text
NamelessAudio-android-universal-<tag>.apk
NamelessAudio-android-universal-<tag>.apk.sha256
NamelessAudio-android-arm64-<tag>.apk
NamelessAudio-android-arm64-<tag>.apk.sha256
NamelessAudio-android-armv7-<tag>.apk
NamelessAudio-android-armv7-<tag>.apk.sha256
NamelessAudio-android-x64-<tag>.apk
NamelessAudio-android-x64-<tag>.apk.sha256
NamelessAudio-windows-x64-<tag>.zip
NamelessAudio-windows-x64-<tag>.zip.sha256
```

普通 Android 用户建议下载 universal APK。现代手机可选择 arm64，旧款 32 位 ARM 设备选择 armv7，x86_64 仅用于对应设备或模拟器。Windows ZIP 必须完整解压后运行。
