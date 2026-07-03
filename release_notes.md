# Nameless Audio 1.0.0

## 重点变更

- 版本修正为 `1.0.0+1000000`，发布标签使用 `1.0.0`。
- Android 正式包名为 `com.nameless.audio`。
- Windows 程序名为 `nameless_audio.exe`，产品身份为 `NamelessAudio`。
- GitHub Release 资产命名统一为 `NamelessAudio-android-arm64-1.0.0.apk` 与 `NamelessAudio-windows-x64-1.0.0.zip`，并要求同名 `.sha256` 校验文件。
- 应用内更新下载进度会在页面顶部持续显示；下载失败时保留错误信息，Windows 可直接打开更新日志。
- Windows 更新器支持旧程序名到新程序名的迁移，安装后会按 ZIP 内实际可执行文件重启。
- 播放详情页、播放列表卡片和底部播放卡片会显示已启用的字幕、速度、均衡器、跳过空白、降噪、音量平衡、声道平衡和左右声道互换图标。
- Windows 复制入口改为右键复制，不再依赖长按复制。
- `script/` 目录改为本地临时脚本目录，不再作为仓库内容跟踪。

## 发布资产

```text
NamelessAudio-android-arm64-1.0.0.apk
NamelessAudio-android-arm64-1.0.0.apk.sha256
NamelessAudio-windows-x64-1.0.0.zip
NamelessAudio-windows-x64-1.0.0.zip.sha256
```
