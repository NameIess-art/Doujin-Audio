# Nameless Audio Release Notes

> **升级前必读：**从不兼容的旧版本升级到本 Release 时，必须先卸载旧版本再重新安装。卸载会清除应用数据，建议先在“数据支持”中导出 `.nalbackup` 备份。具体兼容范围以本次发布说明为准。

## 播放、队列与无障碍

- 优化播放列表、播放详情和活动会话卡片的层级、导航反馈、动态尺寸适配和空状态。
- 改进多会话播放、队列顺序、单独导入媒体的上一首/下一首切换、通知栏控制和播放意图同步。
- 新增或完善时间轴字幕、均衡器、声道平衡、跳过空白、轻度降噪、音量平衡、播放速度和时间段循环控制。
- 支持减少动画和键盘/屏幕尺寸变化下的页面状态保持，补充语义标签、触控反馈和回归测试。
- 完善音频焦点、后台服务、睡眠计时器、字幕悬浮窗、网络错误恢复和进程恢复行为。

## 本地媒体库与 ASMR.ONE

- 优化大型媒体库启动、扫描、搜索、自然排序、时长解析、封面候选和封面缓存；重命名时同步更新封面索引。
- 支持批量补全作品详情、按缺失字段筛选、封面/视频帧恢复和 DLsite 元数据批量匹配。
- 增加 ASMR.ONE API 多域名故障切换，改进收藏、历史、推荐、播放缓存和在线媒体地址兼容性。
- 同一作品支持有界并发下载、暂停/继续、连接复用、本地原子临时文件和可配置的下载目录/命名字段。
- 新增视频转音频工具，可选择 MP3、AAC、OGG、WAV 或 FLAC、码率和输出目录，并支持进度展示与取消。

## 数据、权限与更新

- Android 文件夹扫描支持增量批次、及时取消、generation 隔离和不完整扫描删除保护。
- 加强数据库维护锁、备份恢复回滚、SQLite 大批量删除和 ASMR outbox 原子保存。
- “数据与支持”支持 `.nalbackup` 导出/验证/恢复、失败回滚和脱敏诊断报告；恢复备份后会重新载入应用状态。
- 权限中心集中展示通知、后台运行、精确定时、文件管理、悬浮窗和更新安装权限，并在相关功能触发时再请求。
- 应用内更新继续从 GitHub Release 检查、下载、SHA-256 校验并交给系统安装器，不引入应用商店渠道。

## 架构与质量

- 播放会话运行时已移出 domain，domain 不再依赖 Flutter、播放器 SDK 或上层模块。
- 更新安装与字幕悬浮窗平台调用统一进入可注入的 `core/platform` 网关，保持原有 Channel 协议不变。
- 覆盖率校验按目录聚合，并在配置路径无覆盖数据、LCOV 为空或低于门槛时失败。
- 清理旧的扁平目录、重复运行时和无用兼容代码；平台通道、播放、扫描、存储、字幕和更新按职责归位。
- 新增架构边界、平台畸形 envelope、播放恢复、队列交互和设置页回归测试；升级相关依赖的兼容 patch 版本。

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
```

普通 Android 用户建议下载 universal APK。现代手机可选择 arm64，旧款 32 位 ARM 设备选择 armv7，x86_64 仅用于对应设备或模拟器。
