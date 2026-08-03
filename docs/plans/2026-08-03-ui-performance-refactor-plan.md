# 页面交互与切换性能重构验收

## 目标与范围

本次优化覆盖主导航、资料库与 ASMR 切换、长列表滚动、播放进度刷新，以及播放会话详情的打开和关闭。视觉样式、页面状态、Riverpod 架构、现有路由体系及 Android 原生协议保持不变。

自动化场景使用仓库现有运行时测试 fixture，在内存中构造以下稳定数据，不访问网络或真实媒体文件：

- 100 个本地资料库条目
- 100 个 ASMR 条目
- 12 个播放会话

场景文件：`integration_test/ui_performance_test.dart`

## 设备与运行方式

帧耗时只能在物理 Android 设备的 profile 模式下作为验收数据。共享模拟器、Windows 和 debug 模式可用于行为验证，但结果不能与正式基线比较，也不作为 CI 硬门禁。

推荐设备条件：

- 中端 Android 设备，屏幕刷新率固定为 60Hz
- 电量高于 30%，关闭省电模式和系统录屏
- 设备温度稳定，关闭其他前台应用
- 每组基线和改后数据使用同一设备、系统版本、分辨率和显示缩放
- 使用 release 同等资源，运行期间不连接网络数据源

先确认设备：

```powershell
flutter devices
```

执行 profile 场景：

```powershell
flutter test --profile integration_test/ui_performance_test.dart -d <android-device-id>
```

测试先执行一轮着色器、文字和列表组件预热，随后连续记录三轮。完成后输出一条包含三轮结果的 `UI_PERFORMANCE` JSON，并写入 integration test 的 `reportData.uiPerformance`。应保存命令输出，分别标记为“修改前基线”和“修改后结果”。

## 指标与判定

每轮记录：

- `uiP95Us`：UI 构建耗时 P95
- `rasterP95Us`：Raster 耗时 P95
- `overBudgetPercent`：UI 或 Raster 超过 16.67ms 的帧比例
- `maxConsecutiveOverBudgetFrames`：最长连续超预算帧数

三轮均需满足：

- UI P95 不超过 16.67ms
- Raster P95 不超过 16.67ms
- 超预算帧不超过 5%
- 不出现超过 2 帧的连续超预算

此外，修改后三轮的超预算帧总数相对同设备修改前基线至少降低 30%。若设备热降频或系统弹窗打断场景，应丢弃该轮并在设备恢复稳定后重跑整组三轮。

## CI 策略

CI 继续验证转场结构、状态保留、订阅边界、导航观察器和交互锁释放等稳定行为。`ui_performance_test.dart` 不加入共享 Android 模拟器的帧耗时硬阈值；CI 环境的调度和图形后端不足以提供可比较的性能结论。

## 当前执行状态

实施时未检测到已连接的 Android 设备，因此本次提交可完成场景代码、静态分析和行为测试，但物理机三轮 profile 指标及相对基线降幅仍需按上述命令补录。
