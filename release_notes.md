# Doujin Audio 0.20.1 Release Notes

> **升级前必读：**本版本使用 Android 应用 ID `com.doujin.audio`，会作为独立应用安装，不能覆盖更名前版本，也不会继承旧应用私有数据。应用仅接受由本版本创建的 `.dabackup` 备份，不提供旧数据或旧备份格式的自动迁移。

## 播放与控制台增强

- **播放速度范围扩展与微调**：倍速调节支持更宽广的速率范围（0.25x – 4.0x），提供常用倍速快捷预设与平滑调节滑块。
- **循环与单次播放模式细化**：全面细化单曲循环、文件夹顺序/随机、跨文件夹顺序/随机以及单次播放（Once-through）等模式逻辑与状态切换。
- **时间段标签与片段循环体验**：优化时间段标签面板的编辑交互与多语言文案，片段标签起止时间与循环播放更加稳定。
- **目录加载与播放反馈优化**：增强曲库目录加载异常处理，优化加载中与播放错误时的提示条与重试反馈机制。

## 视觉细节与底层加固

- **视频作品封面缓存加固**：稳定本地视频生成封面的缓存键算法，防止重复解析与封面缓存失效。
- **媒体库管理与编辑页面微调**：优化曲库编辑页面的列表边距、卡片圆角与操作按钮色彩，保持视觉一致性。
- **播放与传输组件架构解耦**：重构播放传输控制与音量/计时器组件拆分，提升状态更新效率与响应速度。

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
```

普通 Android 用户可下载 universal APK。现代手机可选择 arm64，旧款 32 位 ARM 设备选择 armv7，x86_64 仅用于对应设备或模拟器。所有 APK 都附带同名 `.sha256`，并由 GitHub Actions 校验正式签名和 ABI 后发布。
