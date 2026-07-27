# Nameless Audio 0.16.1 Release Notes

> **升级前必读：**从不兼容的旧版本升级到本 Release 时，必须先卸载旧版本再重新安装。卸载会清除应用数据，建议先在“数据支持”中导出 `.nalbackup` 备份。具体兼容范围以本次发布说明为准。

## ASMR.ONE 下载

- 单个文件遇到网络超时、连接中断、响应截断、HTTP 408/429 或服务端 5xx 错误时，会自动重试最多 5 次；其他文件继续并发下载，不会重跑整部作品。
- 自动重试会保留 `.part` 临时文件并优先通过 Range 断点续传；服务器不接受断点时才重新下载该文件。
- 下载任务卡与文件详情会显示“正在重试（当前次数/5）”；暂停、取消或退出任务后不会继续发起新的重试。
- 401/403/404、无效下载地址以及本地写入失败不会进行无效的网络重试；重试耗尽后仍只计为一个文件失败。

## 界面、动效与主题

- 统一应用页面、共享轴、淡入淡出、对话框和底部面板的切换动效；减少动画设置会同步关闭非必要移动与反馈。
- 统一确认、危险操作和选择类对话框，规范体育场形按钮、间距、触摸区域及窄屏布局。
- 启动图标与 Android 12+ 启动画面会在应用进程启动前按系统明暗主题选择；播放通知图标继续同步当前主题与应用配色。
- 优化播放列表卡片、滑动操作背景和颜色展示，确保自定义颜色在列表与操作状态中保持可见。
- 调整索引页面的方向滑动和返回动效，移除导航切换时多余的水波纹与震动反馈。

## 稳定性与验证

- 扩充页面动效、对话框、播放列表拖动、主题启动和 ASMR.ONE 下载回归测试。
- 下载测试覆盖并发文件、断点续传、永久性 HTTP 错误、重试耗尽以及退避期间暂停等场景。

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
