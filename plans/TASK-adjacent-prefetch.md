# TASK: 相邻页预取（阅读时向前预热 2 张）

日期：2026-08-23 ｜ 协作模式（本会话规划/Review，另一会话实现）

## 目标复述

阅读器打开和每次翻页后，把当前页之后的最多 2 张图片的原始文件经 PreheatKit 调度器以 `.immediate` 优先级下载进 original 池，翻页命中本地缓存，消除阅读路径上的网络等待。

## 决策记录（已拍板）

- **触发点两个**：打开阅读器（`present` 时）+ 每次页码变化。理由：只翻页触发则"打开即翻"的第一翻必等网络；打开即预热的代价只是用户秒关时白下载 1–2 张，可忽略。
- **数量：向前 2 张**（不足 2 张到末尾即止）。1 张只够匀速阅读，2 张覆盖"快速连翻两页"的常见节奏；更多会挤占缓存且边际收益骤降。
- **优先级 `.immediate`**：比目录预热的 `.currentDirectory` 和设置页的 `.userFolder` 都高——用户正在看的东西永远排在后台任务前面，这是 Priority 枚举设计时的语义。
- **范围：仅目录模式的网络图片**。CBZ 的整包已在 original 池（打开时已缓存），页解码是本地 CPU 活，"预取"对 CBZ 是另一个机制（预解码入 display 池），本期不做。
- **取消语义**：翻页只新增提交不取消旧的（已下载的进缓存无害，LRU 兜底）；关闭阅读器 / 导航离开时不主动 `cancel(priority: .immediate)`——in-flight 一两个文件让它跑完，结果都是有效缓存。若实测发现与 reader 当前页加载抢带宽，再评估加取消。

## Out of Scope

- CBZ 页预解码（见决策记录）。
- 向后预取（往回翻的场景，命中率低）。
- 预取数量/开关的用户设置项。
- Reader 渲染结构、ReaderImageLoader 逻辑改动。

## 现状摘要

- 阅读管线缓存顺序：display 池 → original 池 → 网络（`ReaderImageLoader`）。预取只需把原始字节送进 original 池，Reader 自动获益。
- `ReaderCoordinator.present(content:startIndex:sourceID:)`（`Cove/Features/Reader/Coordination/ReaderCoordinator.swift`）是打开的唯一入口；页码变化在 `ReaderViewModel`（@MainActor）。
- `ReaderContent`（`Cove/Services/Media/ReaderContent.swift`）的页面模型携带构建 `ContentItem`/`CacheKey` 所需的全部元数据（path、fileSize、modified）。
- `PreheatScheduler`（PreheatKit）：`submit(_:priority:)` 自带队列内 + in-flight + 已缓存三重去重，重复提交同一页零成本。
- `PreheatService`（@MainActor，`Cove/Services/Preheat/PreheatService.swift`）持有 scheduler 与 connection；目录预热的提交/取消链路（`preheatDirectory`/`cancelDirectoryPreheat`）是现成的参照实现。
- 组装：`ReaderCoordinator` 由 `LibraryCoordinator` 构造（`LibraryCoordinator.swift`），后者持有注入的 `preheatService`。

## Step 列表与 DoD

### Step 1：能力层——PreheatService 相邻页提交 + ReaderContent 页元数据暴露

- 改动文件（预计，以实现时最小差集为准）：
  - `Cove/Services/Preheat/PreheatService.swift`
  - `Cove/Services/Media/ReaderContent.swift`（若页元数据不足以构造 ContentItem，补只读访问）
  - `Tests/CoveTests/PreheatServiceTests.swift`
- 内容：
  1. `PreheatService` 新增 `prefetchPages(_ items: [ContentItem])`：无 scheduler/连接/未启用时 no-op；否则 `scheduler.submit(items, priority: .immediate)`。不做状态记录（一次性提交，无生命周期）。
  2. 若 `ReaderContent` 的页元数据不足以在 App 层重建 `ContentItem`，加一个最小的只读暴露（不要为此引入新类型）。
- DoD：
  1. CoveTests 新增：fake source + `connectionReady` 后调用 `prefetchPages`，断言对应文件被实际读取进 original 池；无连接时 no-op。
  2. `make test` 全绿、`make build` 零警告。

### Step 2：接线——打开与翻页两个触发点

- 改动文件（预计）：
  - `Cove/Features/Reader/Coordination/ReaderCoordinator.swift`
  - `Cove/Features/Reader/ViewModels/ReaderViewModel.swift`（加页码变化回调）
  - `Cove/Application/Coordination/LibraryCoordinator.swift`（构造注入）
  - `Tests/CoveTests/ViewModelTests.swift`
- 内容：
  1. `ReaderCoordinator` 注入 `preheatService`（构造参数，LibraryCoordinator 传入）。
  2. `ReaderViewModel` 新增 `onPageChanged: ((Int) -> Void)?`（或等价闭包），页码落地后回调。
  3. `present(...)` 与 `onPageChanged` 回调里：取当前页之后最多 2 页的 ContentItem（仅目录模式），调 `prefetchPages`。
  4. VM 不该知道预热存在——回调是唯一的缝，闭包实现在 Coordinator。
- DoD：
  1. 测试：fake preheat 记录提交——打开时提交 startIndex+1/+2；翻到第 N 页提交 N+1/N+2；末尾不足 2 张时只提交存在的；CBZ 模式不提交。
  2. `make generate && make build` 零警告、`make test` 全绿。
  3. 人工检查点（用户）：打开一个**未预热**的文件夹里的图片，快速连翻 3–4 页，翻页无明显网络等待；看日志确认预取提交发生。

## 风险与回滚点

- 与目录预热并发时的带宽竞争：`.immediate` 优先级保证阅读预取插队；scheduler 的 `maxConcurrent=2` 意味着 in-flight 的目录预热任务不会被抢占式中断，最坏情况延迟一个 in-flight 任务的完成——可接受，实测有问题再评估。
- 去重是 scheduler 内建的，"打开 + 连翻"对同一页的重复提交零成本。
- 回滚：Step 2 单独 revert 即功能消失，Step 1 的 API 无害残留。

## 验证命令

```sh
make test                    # 全量回归
make generate && make build  # 零警告
```

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package：Step 编号、改动文件列表、关键 diff 摘要、自测命令与结果、已知风险。每个 Step 单独提审。
