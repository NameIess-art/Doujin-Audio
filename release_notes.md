# Doujin Audio Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。`.dabackup` 备份恢复要求平台及备份格式兼容，且备份数据库版本不能高于应用支持的版本；不提供更名前旧数据或旧备份格式的自动迁移。

本次更新主要修复曲终停止、Windows 播放队列与退出流程、媒体库路径处理和 ASMR.ONE 下载重新配置，并改进切歌面板与作品详情交互。

## 播放与定时停止

- 改进 Android 与 Windows 的“播完当前曲目后停止”，在播放器端阻止自动切到下一曲；Windows 开启或取消此功能时保留当前播放进度。
- 多会话曲终停止分别处理各会话的淡出与完成状态；取消定时或手动操作后恢复音量，避免残留的淡出状态影响后续播放。
- 修复 Windows 随机播放下队列重排、重复音频条目与曲终停止取消后的曲目映射，减少队列编辑对当前播放的干扰。

## Windows 启动与退出

- 改进启动期间的托盘退出和系统会话结束处理，等待初始化收尾后释放资源，避免重复退出或清理。
- 初始化失败时不以默认或部分加载状态覆盖已保存数据；保存失败时仍继续释放播放器与运行资源。
- 改进初始化失败后的重试流程，避免重复注册桌面控制。

## 媒体库与 ASMR.ONE

- 修复 Windows 路径大小写和分隔符差异造成的重复索引，扫描更新时保留已有条目的状态。
- 文件或文件夹重命名时拒绝覆盖已存在的目标，同步更新播放队列和受影响的扫描目录；Android SAF 扫描失败、取消或不完整时保留已有媒体库条目。
- 重新提交同一作品的下载时，正确采用新的文件选择、目标目录与下载设置；设置未变的暂停或失败任务仍可继续下载。
- 更换下载配置时等待原任务写入结束，仅清理该任务拥有的临时文件，保留已下载内容与无关文件。
- 修复 ASMR.ONE 账号同步写入失败后的重试与退出登录处理，避免旧账号的延迟失败影响新账号状态。

## 切歌面板与页面交互

- 会话切歌面板新增文件夹展开与收起动画，大目录仍按可见区域构建；开启“减少动画”时立即完成切换。
- 修复从本地媒体库或 ASMR.ONE 搜索结果打开作品详情、返回搜索后的页面可见性与输入状态。
- 调整作品详情的下载、收藏按钮、声优与标签样式，以及播放控制按钮的尺寸和配色。
- 字幕全文时间轴的定位按钮显示当前选中字幕的起始时间，便于确认跳转位置。

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
