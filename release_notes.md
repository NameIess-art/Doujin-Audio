# Nameless Audio Release Notes

> **升级前必读：**从不兼容的旧版本升级到本 Release 时，必须先卸载旧版本再重新安装。卸载会清除应用数据，建议先在“数据支持”中导出 `.nalbackup` 备份。具体兼容范围以本次发布说明为准。

## 自动更新修复

- 修复 arm64、armv7 和 x64 设备使用应用内更新时始终下载 universal APK 的问题。
- Android 原生端现在会报告设备 ABI，现有 GitHub 更新流程据此选择对应 APK 及其同名 `.sha256` 校验文件。
- 无法识别设备 ABI 时仍会安全回退到 universal APK；下载、SHA-256 校验和系统安装器流程保持不变。

> 0.13.0 和 0.14.0 内置的是旧更新逻辑，因此首次升级到本修复版本时仍可能下载 universal APK。安装本修复版本后，后续应用内更新会按设备 ABI 选择安装包。

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
