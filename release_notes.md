# Nameless Audio v0.13.0

## 播放与错误恢复

- 修复 Windows 开启“跳过空白”后进度条不更新的问题。
- 音频加载中时，播放详情页字幕区域显示“加载中”。
- 音频加载中或播放错误时，播放按钮显示暂停图标；点击错误状态按钮可立即重试。
- 优化播放进度条、播放速度滚轮和播放详情页交互状态。

## 本地媒体库与封面

- 从作品详情获取信息并保存封面后，详情页和无封面的文件夹卡片会立即刷新。
- 卡片实际使用的封面文件位置写入数据库和目录内 `nameless-audio.json`；再次加载时优先校验并复用索引，减少目录扫描和封面提取。
- 文件夹或单文件重命名时同步更新封面索引，失效路径会回退到现有封面发现流程。

## ASMR.ONE 与稳定性

- ASMR.ONE 下载任务新增暂停和继续操作。
- 改进加载错误、重试提示、缓存复用和后台封面预热稳定性。
- 修复 CI 中 Windows 缺少 FFmpeg 及并行 Flutter 测试共享状态导致的错误失败。

## 发布资产

```text
NamelessAudio-android-arm64-v0.13.0.apk
NamelessAudio-android-arm64-v0.13.0.apk.sha256
NamelessAudio-windows-x64-v0.13.0.zip
NamelessAudio-windows-x64-v0.13.0.zip.sha256
```
