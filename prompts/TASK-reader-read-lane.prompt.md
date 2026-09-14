---
task: /Users/boyang/code/Cove/plans/TASK-reader-read-lane.md
status: done
from: Planner
to: Executor
created: 2026-09-14
---

# 任务：Reader read lane（翻页"停在上一张图"根治：车道分离 + 取消不白读 + 加载指示）

## 目标
消除目录模式阅读器翻页长时间停在上一张图的问题：缩略图读挪出交互车道（根治）、
被取消的读取字节必落 original pool（止血）、翻页加载加 pill 指示（感知）。
成功标准 = TASK 文件（/Users/boyang/code/Cove/plans/TASK-reader-read-lane.md）
DoD 四条 + `make test` 全绿 + `make build` 零警告。TASK「Decisions」五条全部
照做，不得擅自变更。

## 现状锚点（均已由 Planner 实证）
- 车道盒 /Users/boyang/code/Cove/Cove/Services/Infrastructure/SMBSessionService.swift：
  `private final class SMBReadRouter: Sendable`（约 58 行，Mutex 包
  `(any ContentSource)?`，update/read/read-range/list 四方法）；主盒
  `readRouter`（约 115 行）；`makeFileReader()`（约 306 行）即闭包捕获
  readRouter 的范式；预热源安装点 `self.preheatSource = preheat`（约 378 行，
  startPreheatConnection 内）、拆除点 `tearDownPreheatConnection()`（约 386
  行，`preheatSource = nil` + `guard let old` 早退——update(nil) 要放在早退前）。
- 缩略图注入三处 /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift：
  约 424 / 556 / 820 行，均为
  `ThumbnailService(readFile: makeFileReader(), cache: cache, sourceID: sourceID)`，
  改传 `sessionService.makePreheatLaneFileReader()`（556 行为 vault 路径，预热
  车道恒 nil 自动回退，行为不变——同一 API 三处通换，不做条件区分）。
- B1 /Users/boyang/code/Cove/Cove/Services/Media/ReaderContent.swift：
  `static func originalBytes(...)` 顺序为 查池 → checkCancellation →
  `try await fileReader` → checkCancellation → `try? cache.store` → return；
  把 store 挪到第二个 checkCancellation 之前（读完必落池），注释同步。
- B2 VM /Users/boyang/code/Cove/Cove/Features/Reader/ViewModels/ReaderViewModel.swift：
  State 结构（约 14 行）增 `isLoading: Bool`；`loadCurrentPage()`（约 200 行）
  置 true；`applyLoadedPage`/`applyFailure`（约 222/238 行）置 false；state
  计算属性同步。**该文件已有未提交的空态卡改动（retry() 等），在其上叠加，
  严禁回退。**
- B2 View /Users/boyang/code/Cove/Cove/Features/Reader/Views/PagedReaderWindowController.swift：
  pageChromePill 内现有 progressLabel + autoAdvanceButton（装配约 175-200 行）；
  small NSProgressIndicator（.small、spinning）入 pill，render(_:)（约 270 行）
  按 `state.isLoading && state.image != nil` 控制 isHidden 与 start/stopAnimation。
  **该文件同样有空态卡未提交改动（renderStateOverlay 等），严禁回退。**
- 测试落点：
  - 车道回退：SMBReadRouter 降 internal（@testable 可见）+ read(at:fallback:)
    类方法后直测两态；假 ContentSource 最小桩（read 返回固定 Data 即可）写在
    测试文件内。无既有落点则新建 /Users/boyang/code/Cove/Tests/CoveTests/ReadRouterLaneTests.swift（
    仅此一个允许新建的文件；Swift Testing 风格，@Suite/@Test/#expect）。
  - B1 取消仍写池：/Users/boyang/code/Cove/Tests/CoveTests/PdfReaderTests.swift
    （makeTestCache()/makeItem 现成，闩锁 fileReader + 取消 + 断言池内有字节）。
  - B2 三态：/Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift
    ReaderViewModelTests suite 内（DelayedReaderLoader/FlakyReaderLoader/waitUntil
    均现成；**空态卡刚在此 suite 加了 retry 用例，追加不改动既有用例**）。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Services/Infrastructure/SMBSessionService.swift
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
- /Users/boyang/code/Cove/Cove/Services/Media/ReaderContent.swift
- /Users/boyang/code/Cove/Cove/Features/Reader/ViewModels/ReaderViewModel.swift
- /Users/boyang/code/Cove/Cove/Features/Reader/Views/PagedReaderWindowController.swift
- /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift
- /Users/boyang/code/Cove/Tests/CoveTests/PdfReaderTests.swift
- 允许新建：/Users/boyang/code/Cove/Tests/CoveTests/ReadRouterLaneTests.swift（仅此一个）
- 不新建其他文件，无需 make generate；DESIGN-TOKENS.md 不动。

## 验收标准（DoD）
见 TASK 文件 DoD 四条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性规矩：
禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency 零新警告（10）、
SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、测试优先 Swift Testing（15）。

## 上游任务产出
- 空态卡（2026-09-14，未提交在工作树）：PagedReaderWC renderStateOverlay /
  ReaderViewModel.retry() / 相关测试——本卡在其上叠加，不是回退对象。
- 预热火道机制：SMBSessionService 双连接注释（约 94 行）+ PreheatService
  （Cove/Services/Preheat/PreheatService.swift）——本卡不动它们。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git status --short` 确认在
  /Users/boyang/code/Cove 且看到工作树未提交改动；**禁止任何 git 写操作**
  （add/commit/checkout/restore/stash 一律不准）。
- 工作树既有未提交改动是上游任务产出，动同文件时叠加不搅动。
- 注释英文、UI 文案中文；pill spinner 无文案。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、
自测命令与结果（make test 计数 + make build 警告扫描）、已知风险 / 卡点描述。
