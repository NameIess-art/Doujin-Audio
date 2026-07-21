# Nameless Audio 0.15.1 Release Notes

> **升级前必读：**从不兼容的旧版本升级到本 Release 时，必须先卸载旧版本再重新安装。卸载会清除应用数据，建议先在“数据支持”中导出 `.nalbackup` 备份。具体兼容范围以本次发布说明为准。

## 播放与音频

- 播放选项的顺序按钮新增“顺序播放”状态，可分别用于当前文件夹或跨文件夹范围；播放到范围末尾后保持暂停，手动上一首和下一首仍可正常使用。
- 修复默认双声道映射影响单声道音频播放的问题，左右声道交换与平衡只在立体声输入上启用。
- 播放通知图标会随当前应用主题刷新，锁屏、通知栏和前台播放服务保持一致。

## 本地媒体库与封面

- 作品卡片未手动设置封面时，会优先使用作品目录图片，再从整个作品目录树的音频嵌入封面或视频帧中自动选择，并保存到现有卡片封面索引。
- 媒体库树与分类快照改为按需构建，首次打开、搜索、分类切换和后台刷新会复用同一 revision 的任务，减少启动阶段的无效计算。
- 切换卡片排序模式后保留滚动位置，刷新作品树时保留文件夹展开状态。
- 远程封面完成结果与 Future 会复用；文件时间戳更新增加五分钟节流，减少列表重建和滚动时的文件 I/O。

## 稳定性与数据安全

- 数据库维护、备份恢复和数据库替换增加生命周期 gate：新读写不会在数据库关闭期间注册，已开始的操作会自然完成，维护失败后可恢复并继续排队操作。
- Android 文件选择与导出在 Activity 销毁时按取消完成挂起调用，避免 Flutter Future 永久等待；晚到异步结果不会重复回调。
- 修复媒体库延迟快照在启动刷新、搜索 revision 变化、分类切换、空库和刷新失败场景下的时序问题。

## 主题与图标

- Android 启动图标支持浅色/深色主题和应用主题色组合，切换主题后动态更新。
- 优化不同密度与自适应图标资源，通知图标与启动图标继续使用各自适合系统展示的资源。

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
