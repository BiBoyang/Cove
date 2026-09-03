# TASK: 阅读位置记忆（cbz / 图片目录）

日期：2026-09-04 ｜ 协作模式（助手规划/Review，其他 agent 实现）

## 目标复述

阅读器记住每个阅读对象最后看到的页码：重新打开时直接回到该页；看到最后一页
关闭则删除记录（下次从头开始）。语义对齐视频的 PlaybackProgressStore
（"看完即删"）。目录恢复的"定点看图"冲突用可撤销浮层兜底，且整体行为
可在设置里切换。

## 决策记录（已拍板）

- **新 store，不改播放器**：新建 `ReadingProgressStore`（+ 协议
  `ReadingProgressStoring`），克隆 PlaybackProgressStore 的
  UserDefaults-dict + lastWatched + LRU 200 模式，独立 key
  （`cove.readingProgress.entries`）。页码以 Double 存储（< 2^53 无精度问题）。
  不复用/泛用化播放器的 store：语义不同（秒 vs 页码），混库会让 LRU
  跨种类逐出；三行重复好过过早抽象。
- **记忆键**：漫画 = `sourceID|cbz路径`；目录 = `sourceID|目录路径`
  （目录路径 = 打开文件路径的父目录，POSIX 风格 `deletingLastPathComponent`）。
- **恢复语义（方案 C）**：默认恢复——`openComic` startIndex = 存储值 ?? 0；
  `openDirectory` startIndex = 存储值 ?? 点中文件下标。目录里点任何图都先
  回到记忆页，**若恢复页 ≠ 点中文件**，阅读器浮一个临时提示（约 4 秒自动
  消失，不阻断）："已回到第 N 页 · 返回选中的图"，点按钮跳回点中文件
  （单页走 `jumpToPage`，条带走 `scrollToPage`，均现成）。cbz 是单文件，
  恢复即唯一语义，不弹浮层。
- **设置开关**：设置页新增"阅读器打开时恢复上次位置"开关（默认开）；关闭
  则回到旧行为（目录开点中文件、漫画从 0）。SettingsService 加
  `cove.settings.readerResumeOnOpen`（Bool，register default true），
  经 `PreferencesSettingsManaging` 协议暴露给 PreferencesViewModel
  （现有 settings 注入/协议扩展是现成参照）。
- **写入时机**：只在阅读器窗口关闭时写（`readerWindowWillClose`），按当前
  模式取页码（strip → `stripViewModel.currentPage`，paged →
  `pagedViewModel.currentPageIndex`）；崩溃丢失当次进度，与视频一致。
  看到最后一页（`currentPage == pageCount - 1`）→ 删除记录而非保存。
- **模式切换不写**：切换本就保留当前页，关窗时统一写即可。
- **点"返回选中的图"不抹记忆**：跳回只是本次查看意图，关窗时按实际停留页
  照常写入。

## Out of Scope

- 阅读进度条/百分比展示、浏览器侧"继续阅读"入口列表、跨设备同步。
- 播放器 store 的泛化重构。

## 现状摘要

- `PlaybackProgressStore`（`Cove/Services/Media/PlaybackProgressStore.swift`）：
  协议 + 实现 75 行，测试在 `Tests/CoveTests/PlaybackProgressStoreTests.swift`，
  照抄结构即可。
- `ReaderCoordinator`（`Cove/Features/Reader/Coordination/ReaderCoordinator.swift`）：
  init 目前 `(cache:preheatService:settings:)`；`openComic`/`openDirectory` 的
  startIndex 在调 `presentContent` 前算出（测试 seam 可观测）；
  `readerWindowWillClose` 是现有收口点；`stripViewModel.currentPage` 与
  `pagedViewModel.currentPageIndex` 均可读；`PagedReaderWindowController` 同时
  宿主单页/条带两种 surface，浮层归它加。
- `SettingsService`：UserDefaults 薄封装；`PreferencesSettingsManaging` 协议 +
  `extension SettingsService`（`PreferencesViewModel.swift` 顶部）是偏好页加
  项的固定三步（settings 键 → 协议/扩展 → VM State/setter + WC 表单行）。
- 注意：`openComic` 目前 warm 从 0 起算（`upcomingWarmIndices(from: 0)`），
  恢复后应改为从恢复页起算；`openDirectory` 的 `prefetchFollowing(from:)`
  已用 startIndex 变量，自然正确。

## Step 列表与 DoD

### Step 1：ReadingProgressStore（纯存储，无 UI）

- 改动文件：
  - `Cove/Services/Media/ReadingProgressStore.swift`（新建）
  - `Tests/CoveTests/ReadingProgressStoreTests.swift`（新建）
- 内容：协议 `ReadingProgressStoring`（`page(forKey:) -> Int?` /
  `savePage(_:forKey:)` / `removePage(forKey:)`）+ UserDefaults 实现，
  LRU 容量 200、时钟注入（全部对齐 PlaybackProgressStore 形状）。
- DoD：
  1. 测试覆盖：round-trip、不存在返回 nil、LRU 逐出最旧、removePage 幂等。
  2. `make test` 全绿、`make build` 零警告。

### Step 2：Coordinator 读写 + 设置开关

- 改动文件：
  - `Cove/Features/Reader/Coordination/ReaderCoordinator.swift`
  - `Cove/Services/Settings/SettingsService.swift`（新键 + register default）
  - `Cove/Features/Preferences/ViewModels/PreferencesViewModel.swift`（协议 +
    State + setter）
  - `Cove/Features/Preferences/Views/PreferencesWindowController.swift`（开关行）
  - `Cove/Application/AppDelegate.swift`（创建 store + 注入）
  - `Tests/CoveTests/ViewModelTests.swift`（ReaderCoordinatorTests 用例）
- 内容：
  1. init 增加 `readingProgress: ReadingProgressStoring?`（可选，测试传内存
     recorder；参照播放器 progressStore 的可选注入）。
  2. 打开恢复（设置开）：`openComic` startIndex = 存储值（钳到页数内）?? 0；
     `openDirectory` startIndex = 存储值（钳到 items 内）?? 点中文件下标；
     设置关 → 旧行为。openComic 的 warm 起点同步改为恢复页。
  3. 关窗写入：`readerWindowWillClose` 按当前模式取页码 + 键，最后一页 →
     `removePage`，否则 `savePage`。写入逻辑抽成内部可测函数。
- DoD：
  1. 测试（presentContent seam 观测 startIndex）：comic 有记录恢复 / 无记录
     从 0 / 越界钳制；directory 有记录恢复覆盖点中文件 / 无记录照旧 /
     设置关闭时不恢复；关窗写入函数：末页删除 / 非末页保存。
  2. `make test` 全绿、`make build` 零警告；设置页开关真机点一次确认持久化。

### Step 3：可撤销浮层（方案 C 的反悔路径）

- 改动文件：
  - `Cove/Features/Reader/Views/PagedReaderWindowController.swift`
  - `Cove/Features/Reader/Coordination/ReaderCoordinator.swift`
- 内容：
  1. WC 加私有 resume HUD（HUD 材质胶囊，样式对齐阅读器现有 chrome）：
     "已回到第 N 页" + "返回选中的图"按钮；约 4 秒自动淡出；任何翻页/
     滚动也提前消隐。`showResumeHint(page:onReturn:)` 接口，纯渲染。
  2. Coordinator：目录模式且恢复页 ≠ 点中下标时调 `showResumeHint`；
     onReturn 按当前模式跳回（strip → `stripViewModel.scrollToPage`，
     paged → `pagedViewModel.jumpToPage`）。cbz 不弹。
- DoD：
  1. `make build` 零警告、`make test` 全绿。
  2. 人工检查点（真机）：
     a. 目录看到第 8 页关闭 → 点该目录另一张图 → 回到第 8 页并浮提示，
        点"返回选中的图"跳回点中文件；
     b. 不点按钮 → 约 4 秒提示自行消失，不残留；
     c. cbz 恢复时不弹提示；
     d. 设置里关闭恢复 → 点哪张开哪张（旧行为），重开设置仍保持关闭。

## 风险与回滚点

- **浮层与条带滚动的叠加**：HUD 是窗口级浮层，不进 scrollView 文档流；
  条带滚动时消隐逻辑挂在现有 currentPage 变化回调上即可。
- **记录越界**：目录内容变化后存储页码可能越界——钳制处理，不做失效检测。
- 回滚：Step 3 revert 回到"恢复不可撤销"；Step 2 revert 回到无记忆；
  Step 1 为无害残留。

## 验证命令

```sh
make test                    # 全量回归（含新用例）
make generate && make build  # 零警告
```

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package：Step 编号、改动文件列表、关键 diff
摘要、自测命令与结果、已知风险。每个 Step 单独提审，不跨步混改。
