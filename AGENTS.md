# AGENTS.md

本文件是本仓库的长期开发规则。修改代码前必须阅读并遵守。

## 项目基本原则

本项目是 Flutter + Android 原生混合播放器应用。目标是保持代码清晰、职责单一、可维护，不允许为了完成一个功能不断堆叠新代码。

修改代码时，优先遵守以下原则：

1. 优先修改现有实现，不要轻易新增平行实现。
2. 新增功能前，必须先搜索项目中是否已有相同职责的类、方法、服务、控制器或状态管理逻辑。
3. 移除功能时，必须真正删除相关代码，而不是只隐藏入口。
4. 不允许留下死代码、重复代码、无用方法、无用字段、无用导入、无用文件或大段兼容残留。
5. 不允许为了“保险”添加未经验证的大量兜底逻辑。
6. 不允许在没有必要的情况下新增复杂抽象层、包装层、桥接层。

## 代码减量规则

每次修改完成前，必须检查 diff：

```bash
git diff --stat
git diff --name-only
git status --short
```

如果只是小功能修改，diff 应该尽量小。

如果是移除功能，最终结果应该以删除代码为主。

如果新增代码超过 300 行，必须重新检查是否存在以下问题：

- 是否创建了重复实现
- 是否没有删除旧逻辑
- 是否新增了不必要的 wrapper/helper/manager/controller
- 是否修改了与任务无关的文件
- 是否可以复用已有代码
- 是否可以用更少代码完成同样功能

如果发现无关改动，必须回滚。

## 功能新增规则

新增功能时必须按以下流程执行：

1. 先定位现有相关实现。
2. 判断是否可以在现有类或方法中扩展。
3. 只有在现有结构无法承载时，才允许新增文件或新增类。
4. 新增实现后，删除被替代的旧代码。
5. 更新必要的 UI、状态、文档和测试。
6. 运行项目检查命令。
7. 最后检查 diff，清理无关改动。

禁止为了一个功能创建第二套完整流程。

## 功能移除规则

移除功能时，必须删除所有相关内容，包括但不限于：

- UI 入口
- 设置项
- 状态字段
- 持久化字段
- Dart repository / service / provider 逻辑
- MethodChannel 方法
- Kotlin 原生方法
- Android Service / Receiver / Permission 声明
- 通知栏 action
- 文档说明
- 测试用例
- 无用资源文件

移除功能不是“隐藏按钮”，而是删除完整代码路径。

## 播放架构规则

本项目的真实播放职责必须集中在 Android 原生播放服务中。

### NativePlaybackService

`NativePlaybackService` 是实际播放的唯一核心组件，负责：

- ExoPlayer
- MediaSession
- 实际播放队列
- 播放状态
- 播放前台服务
- 播放通知
- 播放 WakeLock
- 播放中的后台稳定性

播放中不得释放 `MediaSession`。  
播放中不得停止前台播放服务。  
播放中不得因为用户关闭富通知、dismiss 通知或关闭通知样式而停止必要的 foreground service。  
只要存在 active playback，就必须保持最小 foreground playback notification。

### PlaybackKeepAliveService

`PlaybackKeepAliveService` 只能用于：

- 睡眠定时器
- 自动恢复
- 非播放场景的短期保活

`PlaybackKeepAliveService` 不允许参与正在播放的保活。  
`PlaybackKeepAliveService` 不允许抢占 `NativePlaybackService` 的播放通知 ID。  
真实播放时，不能同时让两个 Service 竞争 foreground service 或 notification ownership。

### 通知栏规则

`UnifiedPlaybackNotificationController` 是通知栏控制的统一入口。

不允许新增第二套平行的通知控制器，除非明确是在替换旧实现，并且旧实现会在同一次修改中删除。

应用内“关闭通知”只能表示关闭富通知样式或通知控制偏好，不能表示播放中停止 foreground service。

播放中的最小前台通知不可关闭。

## Dart / Kotlin 状态规则

播放状态以 NativePlaybackService 为准。

不允许同一个播放状态同时存在多套权威来源，例如：

- Dart 一套
- Kotlin 一套
- SharedPreferences 一套
- 通知控制器一套

如果必须缓存状态，必须明确谁是权威来源，谁只是展示或恢复用缓存。

不要依赖 Flutter 定时器完成后台播放关键逻辑。  
下一首、上一首、循环、随机、自动续播、多会话焦点切换等播放核心逻辑应尽量下沉到 NativePlaybackService。

## MethodChannel 规则

不要为每个小功能新增新的 MethodChannel。

优先复用已有 channel：

- native playback 相关逻辑走现有 native playback channel
- 通知相关逻辑走现有 notifications channel
- 权限/电源相关逻辑走现有 power channel
- 文件扫描/缓存相关逻辑走现有 file cache channel

新增 channel 前必须说明原因。

## Android 后台播放规则

后台播放稳定性优先级高于通知样式。

处理后台播放相关问题时，优先保证：

1. MediaSession 稳定存在
2. ExoPlayer 不依赖 Activity 生命周期
3. 播放中 foreground service 不被停止
4. 播放中 WakeLock 不被提前释放
5. 通知 ID 不被多个 Service 抢占
6. 播放队列不依赖 Flutter 进程活跃状态
7. startForeground 失败时有日志或可见错误提示

不能用隐藏通知、停止 foreground service 的方式换取界面简洁。

## 测试与检查命令

修改 Dart / Flutter 代码后，优先运行：

```bash
flutter analyze
```

如果存在测试，运行：

```bash
flutter test
```

修改 Android / Kotlin 代码后，优先运行：

```bash
./gradlew :app:assembleDebug
```

Windows 环境使用：

```powershell
.\gradlew.bat :app:assembleDebug
```

如果因为环境限制无法运行检查，必须在最终说明中明确说明没有运行成功的原因。

## 完成标准

任务完成前必须确认：

- 功能符合用户要求
- 没有新增重复实现
- 被替代的旧代码已经删除
- 没有无关文件改动
- 没有无用导入、无用字段、无用方法
- 没有死代码或注释掉的大段旧代码
- `git diff --stat` 已检查
- 必要的 analyze/build/test 已运行或说明无法运行原因

最终回复必须包含：

1. 修改了哪些文件
2. 新增了什么
3. 删除或清理了什么旧代码
4. 运行了哪些检查
5. 剩余风险或未完成项
6. diff 是否过大，是否已经清理