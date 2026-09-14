# TASK: Reader read lane（翻页"停在上一张图"根治：车道分离 + 取消不白读 + 加载指示）

- Status: done（2026-09-14 收尾，Review Gate: Approved，真机验收通过；make test 352/55 全绿零警告）
- Created: 2026-09-14
- 触发：2026-09-14 真机验收反馈——大图文件夹点开第 5 张→翻第 6 张长时间显示第 5 张的图，来回翻数轮才出真图

## 根因（2026-09-14 代码实证）

1. 车道混行（主因）：阅读器前台读（ReaderImageLoader→originalBytes→fileReader→
   SMBReadRouter）与浏览器缩略图读风暴（ThumbnailService，readGate 限 2 并发但总量
   不限）共用主连接 SMBSource（serial actor，FIFO）。打开大图文件夹立刻阅读时，
   翻页读排在缩略图风暴后面数秒。"有几次"=取决于点开时风暴排空进度。
2. 取消白读（放大器）：originalBytes 顺序为 读→查取消→写池；在途 load 被取消时
   actor 上的读跑完但写池被跳过，同一页可能完整下载多次全部丢弃。
3. 感知缺口：翻页保留旧图是既定设计，但旧图在屏时零加载指示，慢加载读起来像
   "图错了/卡死"。

## Decisions（Plan Card 拍板，Executor 照做）

1. **车道分离（根治）**：SMBSessionService 增 `preheatReadRouter`（SMBReadRouter
   同款 Mutex 盒），preheatSource 安装（startPreheatConnection 成功回调）与拆除
   （tearDownPreheatConnection）两处同步 update；新增
   `makePreheatLaneFileReader()`——预热车道在则走它，不在则回退主 readRouter
   （回退逻辑落进 SMBReadRouter 的一个可测方法，如 read(at:fallback:)）。
   LibraryCoordinator 三处 ThumbnailService 注入（约 424/556/820 行）改传
   `sessionService.makePreheatLaneFileReader()`。阅读器/播放器/目录列表仍走主车道，
   一律不动。设计说明：原草案"reader 读合流进 PreheatScheduler"降级为本车道方案——
   调度器是 fire-and-forget  actor，加可等待读取+插队+限速豁免的复杂度/风险远高于
   车道分离，而隔离效果等价（缩略图与预热同属后台展示池加热，同车道天然合理）。
2. **取消不白读**：ReaderContent.originalBytes 把 `try? cache.store` 挪到第二个
   `try Task.checkCancellation()` 之前——读完的字节必落 original pool，来回翻页
   不再重复下载同一页。注释同步。
3. **翻页加载指示**：ReaderViewModel.State 增 `isLoading`（loadCurrentPage 置
   true、applyLoadedPage/applyFailure 置 false）；PagedReaderWindowController 的
   pageChromePill 内嵌 small NSProgressIndicator，仅
   `isLoading && image != nil` 时显示并转动（首载/失败已有居中 overlay，不重复）。
4. **测试缝最小化**：SMBReadRouter 可由 private 降 internal（@testable 可见）以
   直测车道回退；不新增源码文件；测试允许新增一个文件（仅当车道测试无既有落点）。
5. 不动 PreheatScheduler / PreheatService / ThumbnailService.readGate；vault 行为
   不变（预热车道恒 nil → 恒回退主车道）。

## Out of scope
PreheatScheduler 可等待读取 API；vault 下载走主车道的残留混行（另立候选）；
条带模式加载指示（槽位页码即占位）；目录模式 display variant 预热；本次
真机观察项"缩略图全部挤预热车道后变慢"的调优。

## Steps
1. 车道：SMBSessionService（preheatReadRouter + makePreheatLaneFileReader）+
   LibraryCoordinator 三处注入 + 回退测试。
2. B1：ReaderContent.originalBytes 写池前移 + 取消仍写池测试。
3. B2：ReaderViewModel.isLoading + pill spinner + 三态测试。
4. 验证：make test 全绿 + make build 零警告。

## DoD
1. 三决策全部落地，改动不越白名单。
2. 新测试：车道回退两态（预热源在/不在）、取消仍写 original pool、isLoading
   三态（翻页置位/成功复位/失败复位）；`make test` 全绿。
3. `make build` 零警告（strict concurrency 硬规矩）。
4. 零行为回归：vault 缩略图与阅读不变、预热管道语义不变、既有测试不回归。

## Risks
- 缩略图全部挤预热车道后与预热批量互相排队 → 缩略图变慢是可接受 trade-off
  （后台装饰性读取让路交互读取），注释写明，列真机观察项。
- 预热连接建立窗口期仍回退主车道（残留风暴窗口，可接受，注释写明）。
- 工作树已有未提交的空态卡改动（ReaderViewModel/PagedReaderWC/ViewModelTests
  等）——本卡在其上叠加，严禁回退或搅动那些改动。
