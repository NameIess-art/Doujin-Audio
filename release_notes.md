# Nameless Audio 0.15.0 Release Notes

> **升级前必读：**从不兼容的旧版本升级到本 Release 时，必须先卸载旧版本再重新安装。卸载会清除应用数据，建议先在“数据支持”中导出 `.nalbackup` 备份。具体兼容范围以本次发布说明为准。

## 本地媒体库与封面

- 详情页手动选定的封面会持久化到作品根目录的 `nameless-audio.json`。文件夹图片仅记录可迁移路径；音频内嵌封面和视频帧保存可恢复的图片数据，移除作品后重新导入仍会显示原封面。
- 只在导入作品的根目录读取和保存详情 JSON，不再读取或写入子目录中的同名文件。
- 修复数据库详情、旧缓存或后台时长回填覆盖较新 JSON 的问题；读取时按更新时间合并缺失字段，手动保存与重新导入不会丢失封面及作品信息。
- 改进 ASMR.ONE 下载恢复和本地封面发现，下载任务支持可靠地暂停与继续。
- 封面清晰度新增 1200px，并统一为 300px、600px、900px、1200px、原画五档。

## 备份与恢复

- `.nalbackup` 中的本地媒体库改为只保存导入的文件夹、文件和曲库路径，不再恢复扫描结果、详情缓存和播放队列等派生脏数据。
- 恢复时按备份路径重新导入媒体源；仅在 Android 存储权限失效时请求重新授权，修复连续弹出文件夹/文件选择器以及取消后误报备份损坏的问题。
- 保留恢复前验证、失败回滚和敏感登录凭据排除机制。

## 播放与界面

- 关闭“同时播放多首音频”后仍显示播放列表中的全部音频，播放卡片逻辑与开启时保持一致。
- 优化播放卡片出现或消失时的底部安全间距更新，页面内容会立即避让播放卡片或菜单栏。
- 单独导入的本地音频使用统一播放详情布局；本地音频不再误用 ASMR.ONE 蓝色配色。
- 详情页操作按钮统一为更符合应用风格的玫红色，并优化设置页条目密度、对齐与分组布局。

## 主题与外观

- 新增应用主题颜色选择；开启“ASMR.ONE 独立配色”后可再单独选择 ASMR.ONE 页面主题颜色。
- 颜色选择改为页面中央弹出菜单，并修复选择结果与实际显示颜色不一致的问题。
- 主题色会参与整个页面的色彩融合，浅色和深色模式均使用对应转换后的完整配色方案。

## 更新与发布

- 应用内更新支持识别稳定版主版本升级，并继续从 GitHub Release 下载、校验同名 SHA-256 后交给系统安装器。
- tag 发布流程新增 Android 模拟器冒烟测试门禁；正式发布资产继续覆盖 universal、arm64、armv7 和 x86_64。
- 项目许可证已更新为 GNU GPLv3。

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
