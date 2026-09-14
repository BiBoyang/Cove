---
task: /Users/boyang/code/Cove/plans/TASK-empty-states.md
status: done
from: Planner
to: Executor
created: 2026-09-12
---

# 任务：Empty & loading states sweep（T1 空态/加载态清扫，1.0 批 1 卡 2）

## 目标
消灭阅读器（单页/条带）与 PDF 阅读器三处残余"裸"等待/失败表面，
全部套用 §6.1/§6.2 既有配方与 StatePlaceholderView。成功标准 =
TASK 文件（/Users/boyang/code/Cove/plans/TASK-empty-states.md）DoD
四条 + `make test` 全绿。TASK「Decisions」五条全部照做，不得擅自
变更；「范围核实」一节列出的已闭环项不得重复动工。

## 现状锚点（均已核实）
- 先例（照抄范式）/Users/boyang/code/Cove/Cove/Features/Player/Views/PlayerWindowController.swift
  renderStateOverlay（约 697 行起）：StatePlaceholderView 三元组
  （style/title/message/action）+ id 去重 + addSubview(positioned:.below
  relativeTo: chrome) + onAction 重试闭包。
- 单页 VM /Users/boyang/code/Cove/Cove/Features/Reader/ViewModels/ReaderViewModel.swift：
  State 含 image: CGImage? + errorMessage: String?；goToPage/
  loadCurrentPage 清 errorMessage；applyFailure（约 235 行）置
  currentImage=nil + errorMessage=「加载失败」；翻页保留旧图
  （loadCurrentPage 头注实证）。retry() 即重新发起当前页加载。
- 单页 WC /Users/boyang/code/Cove/Cove/Features/Reader/Views/PagedReaderWindowController.swift：
  render(state) 约 270-291 行，statusLabel 两处引用（render 内 +
  chrome 可见性路径约 489 行），随 overlay 取代一并移除；本 WC
  同时托管条带模式（ContinuousReaderView），overlay 必须是单页
  内容视图的子视图，模式切换随内容视图自然摘除。
- 条带 VM /Users/boyang/code/Cove/Cove/Features/Reader/ViewModels/ContinuousReaderViewModel.swift：
  回调族范式 onSlotImage/onSlotsChanged（58-86 行声明区）；
  applyLoadFailure（约 311 行）现仅记日志，注释明示「滚出滚回
  重试」；onSlotFailure 按同一 generation/slot 硬规则发布。
- 条带 View /Users/boyang/code/Cove/Cove/Features/Reader/Views/ContinuousReaderView.swift：
  StripSlotView（约 495 行起）= readerBackground 底 + 居中
  numberLabel（monospacedDigit 13 / textOnMedia3）；失败呈现替换
  numberLabel 内容区域，遵循同一居中布局。
- PDF VM /Users/boyang/code/Cove/Cove/Features/PdfReader/ViewModels/PdfReaderViewModel.swift：
  State 三分支 .loading/.ready/.failed；start() 幂等守卫
  loadTask==nil 且终态不清 loadTask（重试需最小改动此处）；
  waitForLoad 测试缝勿动；fail() 文案「PDF 加载失败，请关闭后
  重试。」随重试钮调整。
- PDF WC /Users/boyang/code/Cove/Cove/Features/PdfReader/Views/PdfReaderWindowController.swift：
  render(state)（约 112 行起）三分支只切 statusLabel 文字，换成
  StatePlaceholderView（statusLabel 可移除）。
- 组件 /Users/boyang/code/Cove/Cove/SharedUI/StatePlaceholderView.swift：
  init(style:title:message:actionTitle:) + onAction；空态/加载态
  配方见 /Users/boyang/code/Cove/design/DESIGN-TOKENS.md §6.1/§6.2。
- 测试落点（不新建文件）：/Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift
  （paged ReaderViewModel 用例所在）、ContinuousReaderViewModelTests.swift、
  PdfReaderTests.swift（fake loader/bytesProvider 先败后成范式
  文件内已有或易加）。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Features/Reader/ViewModels/ReaderViewModel.swift（改：retry()）
- /Users/boyang/code/Cove/Cove/Features/Reader/Views/PagedReaderWindowController.swift（改：overlay 取代 statusLabel）
- /Users/boyang/code/Cove/Cove/Features/Reader/ViewModels/ContinuousReaderViewModel.swift（改：onSlotFailure 发布）
- /Users/boyang/code/Cove/Cove/Features/Reader/Views/ContinuousReaderView.swift（改：StripSlotView 失败呈现 + 接线）
- /Users/boyang/code/Cove/Cove/Features/PdfReader/ViewModels/PdfReaderViewModel.swift（改：可重试 + 文案）
- /Users/boyang/code/Cove/Cove/Features/PdfReader/Views/PdfReaderWindowController.swift（改：StatePlaceholderView 替换 statusLabel）
- /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift（改：retry 用例）
- /Users/boyang/code/Cove/Tests/CoveTests/ContinuousReaderViewModelTests.swift（改：onSlotFailure 用例）
- /Users/boyang/code/Cove/Tests/CoveTests/PdfReaderTests.swift（改：重试用例）
- 不新建任何源码文件，无需 make generate；DESIGN-TOKENS.md 不动
  （Decision 4）。

## 验收标准（DoD）
见 TASK 文件 DoD 四条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性
规矩：禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency
零新警告（10）、SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、
测试 Tests/CoveTests 优先 Swift Testing（15）。

## 上游任务产出
- plans/archive/TASK-empty-loading-states.md（2026-09-05）：
  StatePlaceholderView 组件与 §6.1/§6.2 配方（已拍板）。
- 播放器状态 overlay（线上代码）：本卡的实现范式先例。
- 浏览器名称过滤（1d53f1a，已入库）：无直接依赖。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- 三处表面文案遵循「说明现状 + 给下一步」；中文 UI、英文注释。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
