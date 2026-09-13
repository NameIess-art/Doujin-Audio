# Doujin Audio 0.24.0 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

## 本地媒体库与剧本文档查看

- **作品台本与文档查看器 (`WorkTextViewerPage`)**：
  - 支持在作品详情页自动发现并浏览作品目录内的 `.txt`、`.md`、`.pdf` 格式台本与剧本文档。
  - `.txt` 纯文本支持智能多编码自动探测（UTF-8、GBK、Shift-JIS、EUC-JP 等）与长文本流畅滚动；`.md` 支持原生 Markdown 语法样式排版渲染；`.pdf` 提供分页预览与快速导航跳转。
  - 多文档作品支持底部胶囊快捷横向切换；统一全宽标准浮动顶栏（`TopPageHeader`）与柔和半透明过渡遮罩，Windows 桌面端滚动条规范处于标题栏下方。
- **卡片快捷手势与直达下载**：
  - 移动端作品卡片支持双向滑动手势：向右滑动呼出“详情”与“下载”，向左滑动呼出“置顶”与“移出曲库”；Windows 桌面端提供完整右键上下文菜单对齐所有快捷操作。
  - 带 RJ 编号的本地作品点击下载直达 ASMR.ONE 远程下载页面（骨架屏秒开展示，无需等待远程元数据加载完成），并自动将下载保存路径预设为当前本地作品文件夹。

## 播放控制与字幕系统升级

- **专用字幕控制面板与即时校准**：
  - 播放详情页提供专属字幕抽屉菜单，集成字幕总开关与字幕悬浮窗开关；无有效字幕的音频自动将控制项置灰禁用，避免无效操作。
  - 支持在播放页随时点选本地外部字幕文件（`.srt`、`.vtt`、`.lrc`、`.ass`、`.ssa` 等）直接导入并关联至当前音轨，导入后即刻刷新显示。
  - 提供毫秒级时间轴同步微调控制（支持 `-0.5s`、`-0.1s`、`重置`、`+0.1s`、`+0.5s` 调节），实时校准音画时间轴。
  - 视频横屏全屏模式下字幕可持续居中保持显示；文案统一升级为“字幕悬浮窗”。

## 系统稳定性与视觉体验

- **定时睡眠与定时唤醒**：定时唤醒/恢复播放时音量支持平滑线性淡入（Fade-in），避免突发大音量惊扰。
- **视觉个性化与数据维护**：
  - “ASMR.ONE 独立配色”开关开启后全面深度覆盖顶部标题栏、搜索批量操作栏、分类胶囊激活态及下载/任务详情子页面。
  - 作品时间轴打点标记与片段循环信息支持随 `doujin-audio.json` 导出与 `.dabackup` 备份恢复。
  - 修复多会话卡片组件在注销卸载时访问 Provider 状态导致的异常，加固前台播放容器与后台生命周期稳定性。

## 发布资产

```text
DoujinAudio-android-universal-<tag>.apk
DoujinAudio-android-universal-<tag>.apk.sha256
DoujinAudio-android-arm64-<tag>.apk
DoujinAudio-android-arm64-<tag>.apk.sha256
DoujinAudio-android-armv7-<tag>.apk
DoujinAudio-android-armv7-<tag>.apk.sha256
DoujinAudio-android-x64-<tag>.apk
DoujinAudio-android-x64-<tag>.apk.sha256
DoujinAudio-windows-x64-<tag>-setup.exe
DoujinAudio-windows-x64-<tag>-setup.exe.sha256
```

普通 Android 用户可下载 universal APK。现代手机可选择 arm64，旧款 32 位 ARM 设备选择 armv7，x86_64 仅用于对应设备或模拟器。所有 APK 都附带同名 `.sha256`，并由 GitHub Actions 校验正式签名和 ABI 后发布。

Windows 10/11 x64 用户下载 `setup.exe`，安装包附带同名 `.sha256`，包含运行依赖并按当前用户安装。关闭主窗口后应用留在托盘，使用托盘“退出”结束应用。Android 与 Windows 备份不能跨平台恢复。
