# TASK: Review followups（审查三项：vault 写盘下主线程 + 封面 stat 走预热车道 + 缓存周期清扫）

- Status: done（2026-09-15 收尾，Review Gate: Approved；make test 377/58 全绿零警告；
  真机两项为观察项不阻塞——GB 级下载流畅度 / 起播期 legacy 封面加载，日常留意）
- Created: 2026-09-15
- 触发：2026-09-14 GLM 审查报告三条 BACKLOG 登记项（plans/BACKLOG.md），
  Owner 点题三项全做并拍板：并一卡、②选预热车道、③选周期清扫

## 根因（2026-09-15 代码实证）

1. **vault 下载写盘占主线程**：VaultService 整类 @MainActor
   （Cove/Services/Vault/VaultService.swift:36），downloadOne（:260-309）
   每 8MB 分块 FileHandle.write（:286）+ createDirectory/setAttributes/
   moveItem 全在主线程；GB 级仓库=数百次主线程同步写盘，UI 可感卡顿。
   分块写盘本身是既定的正确设计（内存 O(chunk)），问题纯在线程归属。
2. **首页封面 stat 挤主车道**：新播放记录自带 fileSize/modifiedDate，stat
   只为 legacy 记录回填（Cove/Services/Media/VideoThumbnailService.swift:188-216）；
   SMB 分支用 sessionService.makeLister() 走主 readRouter
   （LibraryCoordinator.statFileFacts，:1119），与起播 mpv 读串行 FIFO 竞争。
3. **缓存驱逐节奏盲区**：CacheStore.store 不查容量（CacheStore.swift:82，
   "写廉价"既定设计）；evictIfNeeded 触发点仅 CacheService init、设置变更、
   PreheatScheduler 批次后三处。关预热/纯 vault 会话（vault 缩略图也过缓存池）
   → 缓存超预算涨到下次启动。

## Decisions（Owner 已回 o 全按推荐，Executor 照做）

1. **vault 写盘下主线程**：`downloadOne` 与 `isUnchanged` 改
   `nonisolated static`（root 作参数）；`localURL` 增 static 版
   （root 参数化），实例版委托之、其他调用点不动；`download` 保持
   @MainActor，开头取一次 `let root = rootURL`，循环内
   `try await Self.downloadOne(root: ...)`——每次 await 整文件拷贝跳下
   主线程（FileHandle 写 + FileManager 操作全部随之下线）。进度回调本是
   @MainActor 闭包，不动。原子性（temp+rename）、跳过判定、mtime 盖戳
   逐字保留。
2. **封面 stat 走预热车道**：SMBReadRouter 增 `list(at:fallback:)`
   （与 :77 read(at:fallback:) 同范式）；SMBSessionService 增
   `makePreheatLaneLister()`（与 :338 makePreheatLaneFileReader 同范式，
   预热车道在走它、不在回退主 readRouter）；statFileFacts 的 SMB 分支
   换用它。否决项"砍 legacy stat"不采用（老记录封面永久降级）。
3. **缓存周期清扫**：CacheService 增周期清扫——utility 优先级重复 Task，
   默认间隔 15 分钟，[weak self]，复用既有 sweepInBackground()；
   init 增 internal 可注入间隔参数（默认 15min）供测试加速；为实现可测
   允许 init 增 internal 可注入 rootDirectory（默认 Self.rootDirectory）。
   既有三处触发点保留。否决项：写路径触发（布线多收益等价）、store 内
   查容量（违反 CacheStore "写廉价" 既定设计）。
4. 提交纪律：落地后由 Planner 按「一个逻辑改动一个 commit」打 3 个 fix
   commit + 1 docs commit（Executor 不做任何 git 写操作）。

## Out of scope
vault 下载并发化（保持串行，另议）；legacy stat 的彻底移除（随时间自然
消亡）；CacheStore 写路径内驱逐；预热/阅读器既有调用点的车道再分配。

## Steps
1. VaultService：downloadOne/isUnchanged/localURL static 化 + download 接 root。
2. SMBReadRouter.list(at:fallback:) + makePreheatLaneLister + statFileFacts 换道。
3. CacheService 周期清扫 + 双注入缝。
4. 测试 + 验证：make test 全绿 + make build 零警告。

## 测试落点
- 决策 1：Tests/CoveTests/VaultServiceTests.swift 追加——下载的 read 闭包内
  记录 Thread.isMainThread，断言为 false（下载链路整体不在主线程）；
  既有下载用例（递归/跳过/重下）全部不回归。
- 决策 2：Tests/CoveTests/ReadRouterLaneTests.swift 追加——list 车道两态
  （预热源在/不在，FakeLaneSource.list 返回可辨识条目）。
- 决策 3：允许新建 Tests/CoveTests/CacheServiceTests.swift（本卡唯一允许
  新建的文件）——注入临时 rootDirectory + 毫秒级间隔，塞超预算后断言
  周期清扫把用量拉回预算内；Swift Testing 风格。

## DoD
1. 三决策全部落地，改动不越白名单。
2. 新测试三条（off-main 断言 / list 车道两态 / 周期清扫回预算）；
   `make test` 全绿。
3. `make build` 零警告（strict concurrency 硬规矩）。
4. 零回归：vault 下载原子性/跳过/mtime 行为不变；既有测试不回归。
5. 真机观察项（交 Owner）：a. GB 级 vault 文件夹下载期间滚动/点击流畅；
   b. 起播阶段回首页 legacy 封面加载不卡顿（观察即可，难复现不阻塞）。

## Risks
- nonisolated static 化后 downloadOne 与 main-actor 状态彻底脱钩：root 参数
  化已覆盖唯一依赖，progress 回调自带 @MainActor 跳回——无共享可变状态风险。
- 周期清扫与设置变更清扫并发：evictIfNeeded 幂等，CacheStore 自带锁，无害。
- list 回退窗口（预热连接建立前）stat 仍走主车道：与 read-lane 卡同款已知
  残留，注释写明。

## 验收记录（2026-09-15）

- Review Gate Approved（Planner 亲审全量 diff + 亲跑 377/58 全绿 + 构建零警告）。
- 两处提审偏离追认：sanitize 加 nonisolated（@MainActor 类 static 继承隔离的
  编译器强制机械后果）；CacheServiceTests 用 store.setPolicy 缩预算（settings
  ≥1GB 钳制）+ init 默认参数显式 CacheService. 前缀（covariant Self 限制）。
- 真机观察项（不阻塞）：GB 级 vault 文件夹下载期间 UI 流畅度；起播阶段
  回首页 legacy 封面加载。
