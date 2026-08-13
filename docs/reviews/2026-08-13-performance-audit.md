# Doujin-Audio Performance Audit

日期：2026-08-13

## 1. 结论与边界

本轮完成了四个仍有明确源码证据的热点：本地搜索大结果树、ASMR 作品目录树、ASMR 推荐排序、备份与恢复压缩/解压。修改均沿用现有 controller、service、缓存和备份格式，没有新增平行数据流，也没有通过降低图片质量、删除动画或关闭 Blur 制造“假优化”。

自动化验证可以证明：大树的 Widget 创建已经按视口虚拟化，搜索失败可以重试且旧异步结果不能覆盖新请求，推荐同步/异步排序一致，备份格式和错误校验兼容。它不能替代真实 Android 设备的 UI/Raster P95、RSS、GC、图片解码或原生线程采样。

当前没有获得目标设备授权，因此没有安装性能包、没有执行 `adb`、没有触碰正式包 `com.doujin.audio`。本文中的真机指标统一标记为“待验证”，不宣称达到 60/120/165 Hz 门槛。

## 2. 当前评分

以下是源码结构、自动化覆盖和已有保护机制的工程评分，不是实机跑分。

| 维度 | 评分 | 依据与剩余风险 |
| --- | ---: | --- |
| 启动性能 | 8/10 | 已有首帧后初始化基线；仍需 profile startup trace |
| 页面切换 | 8/10 | 集成脚本覆盖主页面、ASMR、详情返回；高刷设备待测 |
| 滚动性能 | 8/10 | 本地库、搜索、ASMR 树均使用 builder 虚拟化；图片/Raster 待测 |
| 点击响应 | 8/10 | 播放命令已有乐观反馈与校正；连续点击真机采样待测 |
| 数据加载 | 8/10 | 扫描、缓存、搜索和推荐均有异步/防旧结果机制 |
| 图片加载 | 7/10 | 已有 `cacheWidth` 与 ImageCache 策略；500–5,000 封面压力测试待测 |
| Riverpod 状态效率 | 8/10 | 已有细粒度 select/受控订阅；需 DevTools rebuild stats 复核 |
| SQLite | 8/10 | 已有 batch/transaction 和大查询基线优化；真机 I/O 仍需采样 |
| Native Bridge | 8/10 | 播放位置已节流；EventChannel burst 仍需 trace 验证 |
| 内存控制 | 7/10 | 树缓存会按 revision 清理，备份临时目录有 finally 清理；RSS 长跑待测 |

## 3. 卡顿热点 TOP 10

1. `PERF-021 P1` 本地搜索命中树曾通过内联 children 一次创建大量行；本轮已修复。
2. `PERF-022 P1` ASMR 作品及目录曾递归创建全部后代 Widget；本轮已修复。
3. 本地媒体库 20,000 项及深层目录首次展示；既有懒加载方案已补竞态、content URI 和展开回归。
4. `PERF-023 P2` 推荐算法最多遍历、过滤并排序 20,000 条本地音频；本轮已移出主 isolate。
5. `PERF-024 P2` 备份 ZIP、SHA-256、JSON 和解压曾占用主 isolate；本轮已移入 worker isolate。
6. 大量高分辨率封面快速滚动的 decode、ImageCache 和 GC 压力；当前仅有策略证据，真机待测。
7. 播放期间扫描、下载、FFmpeg 和备份的 CPU/I/O 竞争；现有并发限制可见，仍需 Perfetto/CPU profile。
8. 多层 Blur、BottomSheet 和页面 transition 的 Raster 压力；没有确定性源码缺陷，真机待测。
9. 原生扫描与 metadata/video frame 工作线程调度；已有 executor，需 Android trace 复核。
10. 120/165 Hz 下的页面切换、Slider 和持续播放动画；需要目标高刷设备验证。

## 4. 已修复问题

### PERF-021：本地搜索结果虚拟化与失败恢复

- 严重程度：P1
- 用户场景：在 20,000 条本地音频中输入高命中率查询、展开/折叠目录、快速更换查询。
- 原行为：过滤树返回后，UI 递归扫描匹配目录，并由 `ExpansionTile.children` 内联创建命中后代；异步失败可能留下 pending 状态或形成未处理 Future。
- 调用链：搜索输入 → debounce → 快照搜索 → 过滤树 → 递归匹配/内联 children → 大量 Widget。
- 修改：`FilteredLibraryTreeResult` 在搜索计算阶段同时返回结果树、命中数和自动展开祖先路径；页面缓存受控展开路径和扁平可见行，唯一 `ListView.builder` 构建视口内容，树行使用 `renderChildrenInline: false`。Future 明确区分成功、失败和过期请求；无旧内容时显示可重试错误，有旧内容时保留列表并显示非阻塞错误。
- 源码证据：`lib/features/library/presentation/library_view_models.dart`、`lib/features/library/presentation/library_search_page.dart`、`lib/features/library/application/library_snapshot_cache_service.dart`。
- Before/After 自动化证据：2,000 个直接命中项现在首帧构建行数小于 100，末项滚动到目标位置后才创建；失败注入后可以重试恢复；过期结果测试不覆盖新 revision。
- 风险：扁平可见项计算仍是 O(n) 引用遍历，但不创建 O(n) Widget；20,000 条真机 CPU 时间仍需采样。

### PERF-022：ASMR 展开树虚拟化

- 严重程度：P1
- 用户场景：展开包含数千文件的作品或深层目录。
- 原行为：作品根卡和嵌套目录使用递归 `ExpansionTile.children`，展开会一次创建全部后代 Widget。
- 调用链：作品展开 → track tree state → 递归目录 Widget → 全量 build/layout。
- 修改：展开状态上移至 `_AsmrCategoryListState`，作品使用 work ID，目录使用 work ID + relative path；作品、加载、错误、空状态、目录和音频统一转换成扁平可见项，并由原有外层 `ListView.builder` 构建。根卡仅负责绘制和受控展开，目录行不再递归创建后代。
- 源码证据：`lib/features/asmr/presentation/asmr_tab_category_list.dart`、`lib/features/asmr/presentation/asmr_tab_work_tree.dart`。
- Before/After 自动化证据：2,000 个直接音频展开后首帧构建行数小于 100，滚动后末项才出现；嵌套目录仍保持播放、折叠和重新展开行为。
- 风险：加载状态和目录引用仍需 O(n) 扁平化；封面 decode 与滑动操作的 Raster 成本需真机验证。

### PERF-023：推荐计算移出主 isolate

- 严重程度：P2
- 用户场景：本地音频、收藏和历史较多时刷新 ASMR 推荐。
- 原行为：候选与本地音频读取完成后，在主 isolate 完成拥有作品集合构建、过滤、打分和排序。
- 调用链：catalog refresh → fetch candidates/local tracks → `rank` → sort → controller stale-token commit。
- 修改：保留同步纯算法 `rank`；新增 `rankAsync`，总输入小于 1,000 时直接执行，达到阈值后通过顶层纯函数和 `compute` 执行。catalog service 记录输入数量、是否使用后台 isolate 和耗时，不记录用户内容。
- 源码证据：`lib/features/asmr/application/asmr_recommendation_engine.dart`、`lib/features/asmr/application/asmr_remote_catalog_service.dart`。
- Before/After 自动化证据：大输入同步与异步结果顺序、去重、已拥有过滤和 refresh seed 完全一致；小输入确认不启用后台 isolate。
- 风险：1,000 阈值是基于隔离开销的保守初值，仍需在低端与高端设备分别测量后调整。

### PERF-024：备份与恢复 worker isolate

- 严重程度：P2
- 用户场景：导出、检查或恢复大备份，同时继续播放和切换页面。
- 原行为：JSON 编码、大小检查、SHA-256、ZIP 编码/预检/解压/校验及 JSON 解析在主 isolate 执行。
- 调用链：DataBackupService → snapshot/preferences/account → JSON/hash/ZIP → atomic rename；restore → ZIP preflight/decode/hash/JSON → database validation/commit。
- 修改：公开 API、格式版本、文件名、entry 顺序和压缩策略不变；CPU 密集工作通过顶层 worker 和 `Isolate.run` 执行。主服务仍负责数据库快照、迁移校验、journal、原子 rename、提交和 rollback。isolate 仅传路径、限制及普通 Map/List。
- 源码证据：`lib/features/data_support/application/data_backup_service.dart`。
- Before/After 自动化证据：现有备份导出、旧格式恢复、重复 entry、路径穿越、大小限制、preferences/account 和恢复提交测试全部通过；失败路径断言 `.part` 与 worker 目录被清理。
- 风险：128 MiB 连续三轮的 RSS 与播放帧预算必须在授权真机上验证；当前不宣称无 OOM 或达到内存门槛。

## 5. 二十场景验证矩阵

| # | 场景 | 当前证据 | 状态 |
| ---: | --- | --- | --- |
| 1 | 本地媒体库首次打开 | 快照缓存、懒树和 integration 场景入口 | 自动化通过；真机待测 |
| 2 | 大型媒体库滚动 | 2,000 Widget 回归；`library-large` 默认 20,000 | 自动化通过；真机待测 |
| 3 | 作品 → 作品详情 | 详情先展示再加载的现有实现 | 源码验证；真机待测 |
| 4 | 作品详情 → 播放详情 | integration core 路径和现有 session flow | 真机待测 |
| 5 | 播放详情持续播放 | position 节流与 session 状态回归 | 自动化通过；真机待测 |
| 6 | 播放中切换页面 | integration core 三轮入口 | 脚本就绪；真机待测 |
| 7 | 播放/暂停/下一首 | 乐观反馈与 native 校正基线 | 自动化通过；真机待测 |
| 8 | 快速切歌 | `playback_facade_session_state_test.dart` | 自动化验证 |
| 9 | 添加文件夹 | SAF/scan coordinator 现有流程 | 真机待测 |
| 10 | 扫描大型曲库 | native executor、chunk merge、并发限制 | 源码验证；真机待测 |
| 11 | 刷新媒体库 | revision 与旧异步结果竞态测试 | 自动化通过 |
| 12 | 搜索 | PERF-021、2,000 命中、错误重试 | 自动化通过；真机待测 |
| 13 | 排序 | derived state 现有缓存 | 源码验证；真机待测 |
| 14 | 分类 | builder 与 category state | 源码验证；真机待测 |
| 15 | 播放列表 | integration core 滚动入口 | 脚本就绪；真机待测 |
| 16 | ASMR.ONE 列表/树 | PERF-022、`asmr-large` 场景 | 自动化通过；真机待测 |
| 17 | ASMR.ONE 详情 | 先开 Sheet 后异步加载 | 源码验证；真机待测 |
| 18 | 下载页面 | 3 任务、每任务 3 文件限制 | 源码验证；真机待测 |
| 19 | 设置页面 | 细粒度 `select` | 源码验证；真机待测 |
| 20 | 数据备份恢复 | PERF-024、`backup` 导出场景 | 自动化通过；128 MiB 真机待测 |

## 6. 性能场景与验收方式

`integration_test/ui_performance_test.dart` 读取以下 `dart-define`：

- `PERF_SCENARIO=core|library-large|asmr-large|backup`
- `PERF_LIBRARY_ITEMS`：覆盖本地音频数量。
- `PERF_ASMR_ITEMS`：覆盖 ASMR 作品数量。
- `PERF_ASMR_TRACKS`：覆盖首个作品的音频数量。
- `PERF_BACKUP_BYTES`：覆盖备份测试数据库中的零填充 payload；`backup` 默认 128 MiB。

默认 `core` 仍使用 100 条本地音频、100 个作品和 12 个播放会话。`backup` 在性能包临时目录创建独立数据库，连续执行真实 export/inspect，测试结束后删除数据库、备份和 staged restore，不读写正式包数据。每个场景先预热一轮，再采集三轮 UI/Raster timing，并输出 P95、超预算比例和最长连续超预算帧。

真机执行必须使用并行性能包 `com.doujin.audio.perf`，并在执行前获得目标设备授权。禁止卸载、覆盖或 `pm clear` 正式包。每个场景在相同设备、刷新率和数据上运行一轮预热与三轮采样：60 Hz 预算 16.67 ms，120 Hz 预算 8.33 ms，165 Hz 预算 6.06 ms。只有同一热点三轮中至少两轮超预算，或三轮回收后 RSS 单调增长超过 15%，才进入下一独立修复批次。

## 7. 未完成项

- 未执行授权真机的 profile APK 安装、Perfetto、gfxinfo、meminfo、heap 或 Simpleperf 采样。
- `core` 集成场景在 Windows test host 启动阶段长时间无输出后被终止；脚本已通过分析，但场景执行结果只接受 Android 性能包真机数据。
- 未形成可比较的 Before/After 实机数值，因此不能判断 UI/Raster P95、超预算帧比例、30% 改善目标或 128 MiB 备份 RSS 门槛是否达成。
- 图片、Blur、下载、设置、扫描、播放列表和原生主线程当前没有新的确定性源码缺陷；只有真机 trace 指向具体调用点后才修改。
- 建议下一步只做证据采集。若没有达到计划中的重复超预算或内存增长阈值，记录为已验证且不改代码。
