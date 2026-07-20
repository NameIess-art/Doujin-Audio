# Nameless Audio Release Notes

> **升级前必读：**从不兼容的旧版本升级到本 Release 时，必须先卸载旧版本再重新安装。卸载会清除应用数据，建议先在“数据支持”中导出 `.nalbackup` 备份。具体兼容范围以本次发布说明为准。

## 曲库详情与 JSON 备份保护

- 修复重新导入曲库或恢复 `.nalbackup` 后，旧数据库详情、缓存或后台时长回填可能覆盖目录内 `nameless-audio.json`，导致已有作品信息丢失的问题。
- 读取详情时会比较数据库与 JSON 的更新时间，优先保留较新的信息，并从另一侧补齐时长等缺失字段。
- 自动保存前会再次保护较新的 JSON；恢复备份时会清空详情缓存、隔离未完成的旧读取，并终止恢复前启动的时长回填。

## 播放与设置界面

- 单独导入音频文件的播放详情页改为与其他本地音频一致的标准封面布局，不再使用独立样式。
- 简化设置页分组展示，移除额外卡片底色和分组间距，保留原有功能与主题色图标。

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

普通 Android 用户可下载 universal APK。现代手机可选择 arm64，旧款 32 位 ARM 设备选择 armv7，x86_64 仅用于对应设备或模拟器。
