# TASK: A2 文件夹级点击预热

日期：2026-08-22 ｜ 方案已获用户批准，分 2 个独立 commit 顺序执行

## 目标复述

浏览器工具栏加"预热此文件夹"按钮：点击后当前文件夹（**只当前层，不递归**）的图片经 PreheatKit 调度器下载进 CacheKit original 池（优先级 `.currentDirectory`），进度可见（N/M + 吞吐），预热中再点按钮取消；翻页加载走原有 display→original→网络顺序，自动获益，**Reader 渲染结构一行不改**。

## Out of Scope

- 递归预热（留待单层稳定后再议）。
- LRU pinning / 缓存策略改动（CacheKit、ReaderImageLoader 一律不碰）。
- 设置页 userFolder 预热逻辑改动（A1 行为保持）。
- Reader 渲染结构改动。

## 现状摘要

- `PreheatScheduler`（`Frameworks/PreheatKit/Sources/PreheatKit/PreheatScheduler.swift`）：`public actor`，三档优先级 `immediate(0) < currentDirectory < userFolder`，队列按优先级 FIFO + 去重索引（`queueIndex` / `inFlightKeys`）。公开 API 有 `submit(_:priority:)`、`pause/resume/cancelAll`、`setRateLimit`、各计数与吞吐；**没有按优先级的定向取消**。
- `FolderEnumerator.collectImages` 是 BFS **递归**枚举；本功能要单层枚举，新增独立入口，不给 `collectImages` 加开关参数。
- `PreheatService`（`Cove/Services/Preheat/PreheatService.swift`）：`@MainActor`，持有 `scheduler` 与 `connection`，settings/cacheStore 构造注入；scheduler 不可从外部注入，但 `connectionReady(source:share:)` 接受任意 `ContentSource`，测试可用 fake source + 真实 scheduler 驱动。
- `LibraryCoordinator`：`preheatService` 已注入；`beginNavigation()` 是导航/取消统一钩子；当前路径由 `LibraryNavigationPath.currentPath` 提供。
- `BrowserViewController`：工具栏已有 backButton/pathLabel/titleLabel/searchField，回调闭包风格。

## Step 列表与 DoD

### Commit 1：任务文档 + PreheatService 目录预热能力（无 UI）

- 改动文件：
  - `plans/TASK-a2-folder-preheat.md`（本文档）
  - `Frameworks/PreheatKit/Sources/PreheatKit/PreheatScheduler.swift`
  - `Frameworks/PreheatKit/Sources/PreheatKit/FolderEnumerator.swift`
  - `Frameworks/PreheatKit/Tests/PreheatKitTests/{PreheatSchedulerTests,FolderEnumeratorTests}.swift`
  - `Cove/Services/Preheat/PreheatService.swift`
  - `Tests/CoveTests/PreheatServiceTests.swift`（新增）
- 内容：
  1. `PreheatScheduler` 新增 `cancel(priority:)`：从队列移除该优先级的待执行 job，维护 `queueIndex` 一致性；in-flight 不管（跑完进缓存无害）。**不用 `cancelAll` 充当目录取消**（会误伤 userFolder 队列）。配套新增 `pendingCount(priority:)`，供测试与 UI 进度使用。
  2. `FolderEnumerator` 新增 `listImages(source:directory:)`：单层 `source.list` + `.image` 过滤 + `isNoise` 噪音过滤。
  3. `PreheatService` 新增 `preheatDirectory(path:)` / `cancelDirectoryPreheat()` / `isDirectoryPreheatActive` / `directoryPreheatProgress()`（async 快照：total/remaining/failed/吞吐）；记录进行中的目录预热状态（路径 + 枚举 task + total + failed 基线）；无 scheduler/连接时安全 no-op；`teardown()` 连带取消目录预热。
- DoD：
  1. PreheatKit 新增单测全绿：定向取消后该优先级 pending 清零、其他优先级不受影响、取消后可重新入队；单层枚举不递归、噪音过滤、不可读目录抛错。
  2. CoveTests 新增测试全绿：目录预热以 `.currentDirectory` 优先级插队（userFolder 排队任务之后、pending userFolder 任务之前执行）；取消只清目录队列、userFolder 不受影响；无连接时 no-op。
  3. `make generate && make build` 零警告、`make test` 全绿。
- commit message：`feat: add single-directory preheat capability to PreheatService`

### Commit 2：浏览器工具栏入口 + 进度/取消

- 改动文件：
  - `Cove/Features/Browser/Views/BrowserViewController.swift`
  - `Cove/Features/Browser/ViewModels/BrowserViewModel.swift`
  - `Cove/Application/Coordination/LibraryCoordinator.swift`
  - `Tests/CoveTests/ViewModelTests.swift`（追加 VM 状态机测试）
- 内容：
  1. `BrowserViewController`：工具栏 backButton 旁加预热按钮（SF Symbol `arrow.down.circle`，accessibilityDescription "预热此文件夹"）+ 进度小标签；新增回调 `onPreheatTapped`；按钮三态由 VM 驱动（可预热 / 预热中 N/M+吞吐 / 完成（N 失败））。
  2. `BrowserViewModel`：预热状态机 + 主 actor 轮询 task（0.5s，轮询注入的 `preheatProgressProvider` 闭包）；`display()` 时复位为可预热并停止轮询；provider 返回 nil（服务侧已取消）自动回 ready。
  3. `LibraryCoordinator`：`onPreheatTapped` → 预热中则 `cancelDirectoryPreheat()`，否则 `preheatDirectory(path: navigationPath.currentPath)`；`beginNavigation()` 加 `preheatService.cancelDirectoryPreheat()`（切目录/换 share/打开阅读器自动取消）；组装时注入 progressProvider。
  4. 无连接（未进入浏览器目录）时按钮禁用。
- DoD：
  1. CoveTests VM 状态机测试全绿：开始→预热中→进度推进→完成；预热中取消→回 ready。
  2. `make generate && make build` 零警告、`make test` 全绿。
- commit message：`feat: add preheat-this-folder button to the browser toolbar`

## 风险与回滚点

- **进度计数语义**：remaining 只统计 `.currentDirectory` 队列中的等待项，in-flight（≤2）不计；failed 用提交时全局 failed 基线做差值，userFolder 并发失败会轻微污染。可接受；若需精确，后续给 scheduler 加 per-priority 完成计数。
- **打开阅读器会取消目录预热**（`beginNavigation` 统一钩子使然）；阅读器打开本身会走 immediate 预热，影响可接受。若实测体感差，回退为只在切目录/换 share 时取消。
- **优先级插队**：目录预热 `.currentDirectory` 会排在已排队的 userFolder 任务之前——这是设计意图（用户当前看的优先）。
- 两个 commit 相互独立，Commit 2 可单独 revert（Commit 1 是纯能力，无 UI 入口）。

## 验证命令

```sh
swift test --package-path Frameworks/PreheatKit   # Commit 1 框架层
make generate && make build                       # 零警告
make test                                         # 全量回归（含 CoveTests）
```

人工验证点：浏览器工具栏出现预热按钮；点击后进度推进（N/M + 吞吐）；再点取消；切目录/换 share 后预热自动取消、按钮复位；完成显示失败数；翻页打开已预热图片明显变快。
