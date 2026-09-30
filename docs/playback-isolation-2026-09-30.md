# 播放与队列的会话隔离

## 状态与组装边界

`PlaybackSessionService` 保持唯一可写会话集合，`PlaybackFacade` 发布三个粒度的数据：

- `states`：会话数、播放数、音频播放/保活状态、焦点和初始化状态。
- `catalogStates`：目录排序所需的结构快照及播放浮层成员。成员、曲目、队列结构、时间字段变化时更新。
- `sessionStates(sessionId)`：目标会话的传输、参数、加载和错误状态。进度继续通过该会话已有的 position/duration/buffered streams 发布。

普通播放事件只计算目标快照及该会话的聚合贡献。音量、倍速、音效和进度不展开其他会话队列。完整 `state` 是显式读取视图，用于批量操作和纯视图模型转换，不用于周期广播。封面 generation 由媒体库封面服务独立发布。

`PlaybackCommandCoordinator` 及其 parts、`PlaybackQueueCoordinator` 位于 `features/player/application`。应用组装负责注入媒体库查询、轨道源/缓存、设置读取、音频激活和生命周期；平台实现继续通过 `NativePlaybackRepository` 选择。ASMR 启动继续使用 `PlaybackSessionLauncher`。

页面的目录、卡片、详情和传输分别订阅相应 Provider。字幕和进度组件直接订阅目标会话。主界面仅消费轻量聚合及浮层成员，不重建完整播放状态。

## 命令、队列与资源

准备任务按 `sessionId` 排队。每个会话继续使用 preparation generation、transport command ID 和实例身份检查；暂停、删除、替换队列和重命名立即使旧准备失效。重命名仅等待受影响会话的本次准备和队列更新，保留播放意图并重新解析新路径；冷暂停会话只更新配置。异步完成后再次检查版本，迟到结果不能重新播放旧请求或重建已删除会话。

队列路径范围和 native descriptor 按结构版本缓存，纯 descriptor 编码使用 `compute`。独立的 `updateQueue` 协议承载结构编辑；只改变循环/随机参数且范围未变时使用参数命令。运行时队列索引保持重复曲目的独立 occurrence，结构重排按 entry ID 及 entry 内偏移映射当前索引。

移除已加载当前项时，运行时保留一个 detached 当前项直到推进；即使下一 occurrence 使用相同 URI，也按索引清理保留项。保留项沿用现有 custom queue 记录保存，冷恢复仍能识别独立 occurrence；推进后的结构写入清除保留记录。未加载的暂停会话直接修改配置和选择，不准备媒体源。

缓存资源租约按会话维护，删除释放目标租约；相同路径集合不重复登记。Windows 视频借用该会话唯一 Player，并以可见表面租约保留播放器。

## 增量持久化

保留现有 schema 和旧记录读取。SQLite adapter 将 domain record 映射为数据库 record，常规操作使用目标会话的 `upsertSession`、`upsertSessionPlaybackState`、`deleteSessions` 和顺序更新。

定义写入比较上次成功记录：队列版本未变时不编码/写入 queue，音效未变时不编码/写入 effects。结构写入的 record 转换、队列行展开及远程 metadata JSON 编码通过 `compute` 执行，再提交目标会话的原子 batch。进度只保存目标 playback state。删除只删除目标 ID，普通操作不调用 `saveAllSessions` 删除并重写全部表。中央数据库保留显式数据替换和旧记录读取能力。

定义、进度和顺序写入进入同一持久化尾链。失败保留待写 ID/顺序，后续 flush 重试。退出、后台切换及备份等待已开始和待写入的变更；退出写入失败仍完成资源释放，并向调用方报告错误。

Android 恢复文件的结构记录复用，进度单独更新；编码及比较在后台执行。

## 平台运行时

Android 仅为有播放意图的会话安排进度 heartbeat，全部暂停时取消调度。队列解析、MediaItem 构造、SAF 可访问性检查和恢复文件读写在后台执行，提交前检查目标版本；同轮状态事件合并并抑制等值发布，EQ 能力按能力变化刷新。

原生定时恢复通过已有命令交付路径的完成回调报告结果，异步读取和准备提交后才确认执行。取消、后台读取失败及服务关闭都会结束交付，避免过早清除 Dart 定时状态或遗留待完成调用。

ExoPlayer、MediaSession 和 PlayerView 绑定仍访问所属 applicationLooper。当前 PlayerView 要求主线程访问播放器，参见 [Media3 线程约束](https://developer.android.com/media/media3/exoplayer/hello-world)。

Windows 用每会话独立命令链替代全局串行链。结构编辑采用最小 remove/add/move，并保留当前解码器；中途失败保留已成功编辑的实际列表，后续重试使用实际索引。重排使旧源重试失效。迟到 seek/video 恢复同样检查播放器实例、generation 和播放意图。

全局字幕浮窗按 catalog 成员和候选会话的播放/加载/曲目字段选择目标，直接订阅该会话的 position stream 与字幕内容变动。删除原 500 ms 周期扫描；暂停保留最后字幕，目标切换和关闭取消旧订阅，音量及其他会话进度不刷新主界面。

首次登记及暂停恢复只建立会话数据。播放或可见视频需要时才创建播放器；焦点暂停播放器及视频租约按生命周期保留，其余空闲播放器释放。通知与 Windows 系统媒体控制按变化更新，非焦点参数/进度不重复设置焦点元数据、封面和按钮。

本次新增代码超过 300 行，已复查组装边界、唯一状态源和旧流程清理：应用层原播放命令及队列实现迁入 player 后删除原文件；domain 与 SQLite adapter 的全量会话保存端口已删除；常规 UI 的全量状态转换、Windows 全局命令串行链及字幕周期扫描已移除。新增媒体库和缓存 ports 仅用于注入已有实现；继续使用 Riverpod、Media3 和 media_kit，没有增加第二套播放器或可写会话存储。原有定时任务倒计时/渐入和显式字幕生成任务的工作计时器继续按任务生命周期运行。

## 回归与性能验证

共享回归覆盖 blocked preparation/remove/queue 时另一会话控制、暂停/删除后的迟到结果、重复项及移除当前项推进、cold 配置、增量数据库写入/失败重试、字幕和独立音效。`playback_event_isolation_test.dart` 使用实际 EventChannel bridge → runtime → facade → Provider，统计目标/其他组件重建、快照读取和写入；空闲会话测试推进 60 秒测试时钟。

`android_native_smoke_test.dart`、`windows_platform_test.dart` 覆盖真实运行时及 60 秒空闲事件观察；Windows 视频测试覆盖所属 Player 的表面租约。

`PERF_SCENARIO=playback` 使用真实本地 WAV、Media3/libmpv 和实际播放浮层，覆盖 0/1/5/50 个暂停会话、两个同时播放会话、1000 项队列。测试绑定使用 `benchmarkLive` 保留实际框架动画帧；每阶段两次暖场后进行三轮共同导航/滚动采样。保留 callback 额外两秒接收批量帧报告，按 frame buildStart 的 wall-clock 时间过滤采样窗口，等待期不进入统计。播放/详情单独采样，下一帧通过实际 `endOfFrame` 检查意图反馈，原生实际播放另行确认。报告在断言前保存，失败时 driver 也保留 JSON。

先前使用默认 `fadePointers` 和 100 ms 回调等待的 Windows 报告存在动画帧抑制与批次截断，保留为调查记录，不作为性能验收结果。

当前 0 会话场景是同次运行的比较基线；没有重构前同机 Profile，不能据此宣称已测得旧版本提升。该播放性能 fixture 使用独立临时文件 SQLite 和生产增量写入；网络、真实视频和 CPU/内存证据需要相应原生采样。

验收门槛为 60 Hz 下 UI/Raster P95 ≤ 16.67 ms、超预算帧 ≤ 1%，1/5 暂停会话相对同轮 0 会话 UI/Raster P95 增量 ≤ 1 ms。基线自身超预算、会话增量回归、意图反馈失败、原生空闲事件分别报告。

本轮验证记录：

| 检查 | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | 无问题 |
| `flutter test --no-pub --concurrency=4` | 1,921 项通过 |
| Android JVM | 346 项通过，0 失败/错误/跳过 |
| Windows 原生集成 | 2 项通过，包含实际 libmpv 视频表面切换 |
| Windows Release 构建 | 成功 |
| Windows Profile | 完整 18 轮；下一帧意图反馈和 60 秒空闲事件检查通过，帧预算与暂停会话增量门槛未全部通过 |
| Android 构建 | Debug APK 和 native smoke Profile APK 构建成功 |
| Android `.perf` native smoke | 并发播放通过；两个暂停会话 60,919 ms 内 0 结构/进度事件 |
| Android 真机性能 | 用户明确取消后停止，不作为完成门槛或性能达标证据 |

Windows 完整 Profile 原始报告见 [playback-profile-windows-2026-09-30.json](playback-profile-windows-2026-09-30.json)。共同导航/滚动三轮结果如下；范围为各轮最小值到最大值，单位为 ms：

| 场景 | UI P95 | Raster P95 | 超预算帧比例 |
| --- | --- | --- | --- |
| 0 个暂停会话 | 4.629–7.012 | 5.649–6.189 | 0.75%–1.74% |
| 1 个暂停会话 | 9.361–9.617 | 5.481–5.821 | 1.30%–2.24% |
| 5 个暂停会话 | 6.989–10.268 | 4.632–4.969 | 0.84%–2.18% |
| 50 个暂停会话 | 6.630–8.057 | 4.878–4.995 | 0.85%–1.20% |
| 2 个同时播放会话 | 4.068–4.459 | 4.973–5.177 | 0.46%–0.47% |
| 千项队列、2 个同时播放会话 | 3.981–4.459 | 4.969–5.237 | 0.45%–0.47% |

所有场景的 UI/Raster P95 均低于 16.67 ms，但 1/5 暂停会话的 UI P95 同轮增量分别为 2.522–4.749 ms 和 1.145–3.429 ms，超过 1 ms。0 会话第一轮本身存在 1.74% 超预算帧；播放按钮及详情操作的部分轮次也超过 1%。因此整体性能验收未通过，不能将卡顿宣称为已经完全解决，也不能把基线问题记作重构带来的改进。

50 个真实加载后暂停的会话在 60,364 ms 内产生 0 结构事件和 0 进度事件，仅保留 1 个焦点播放器。1/5/50 暂停场景的三轮导航均没有原生结构或进度事件；15 次播放按钮操作全部在下一帧呈现播放/加载意图。双会话播放和千项队列的导航三轮均达到帧预算；会话控制与详情的各轮结果独立保留在报告中。

用户再次要求不再实机测试后，停止了后续 Windows CPU/时间线调查，并确认测试进程已经退出；不再启动 Android 或 Windows 实机 Profile。已有报告保留原门槛和失败结果，后续调查未完成的数据不作为验收证据。

Android 首次 `flutter test -d` 安装发现设备主包 versionCode 4612 高于当前 2610，Flutter 自动卸载主包后安装测试包，并在结束时卸载测试包。未在安装前确认版本和备份原数据；不能证明旧数据已保留或恢复。之后验证使用独立 `.perf` 包，用户取消真机测试后停止测试并恢复原屏幕刷新率和保持唤醒设置。
