---
task: /Users/boyang/code/Cove/plans/TASK-home-page-title.md
status: done
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：主页增加「继续观看」页面标题

先读任务契约 `/Users/boyang/code/Cove/plans/TASK-home-page-title.md`（背景/拆解/DoD 以它为准），并遵守 `/Users/boyang/code/Cove/AGENTS.md` 的硬性规矩（纯 AppKit 禁 SwiftUI、布局统一 SnapKit DSL、注释英文 UI 文案中文、严格并发零警告等）。

## 目标

一句话：主页（首页目的地）顶部常驻「继续观看」标题，有记录 / 无记录空态 / 无服务器空态三态均可见。成功标准：下方 DoD 全过，`make build` 绿、`make test` 无回归。

## 涉及文件（绝对路径）

- /Users/boyang/code/Cove/Cove/Features/Servers/Views/HomeViewController.swift
- /Users/boyang/code/Cove/Cove/SharedUI/CoveStyle.swift
- /Users/boyang/code/Cove/design/DESIGN-TOKENS.md
- /Users/boyang/code/Cove/Tests/CoveTests/HomeDestinationTests.swift

禁止碰：`project.yml`、`plans/TASK-empty-states.md`、`prompts/TASK-empty-states.prompt.md`、`prompts/TASK-pin-capsule-leak.prompt.md` 及其对应 TASK 文件与源码（另一个并行任务的地盘：`ServerListViewModel.swift`、`LibraryCoordinator.swift`、`SidebarBottomBar.swift`、`ViewModelTests.swift`）。

## 验收标准（DoD）

1. `CoveStyle` 增加 `pageTitleFont`：先查 `/Users/boyang/code/Cove/design/DESIGN-TOKENS.md` 字体表，有约定按约定；无约定用 `NSFont.systemFont(ofSize: 22, weight: .bold)`，并在该文档字体表补对应一行（保持文档既有格式）。
2. `HomeViewController` 顶部加标题 label「继续观看」：`pageTitleFont`、`.labelColor`、左对齐，leading/top 用 `CoveStyle.space20`；`scrollView` 顶部改接到标题 label 下方（间距取 token 小值，网格自身 sectionInset 不动）。
3. 空态 `placeholderView` 约束：leading/trailing/bottom 贴 root、top 贴标题 label 底（原为四边贴 root），空态下标题仍可见。
4. `Tests/CoveTests/HomeDestinationTests.swift` 增补用例：主页视图层级含「继续观看」文本；若现有基建无法实例化该 VC，在报告中说明原因。
5. 在 /Users/boyang/code/Cove 下 `make build` 通过、`make test` 无回归（零并发警告）。
6. 不执行任何 git add / commit / push。

## 上游任务产出

无。

## 执行提示

- 工作目录 `/Users/boyang/code/Cove`；开工前 `git status --short` 确认只有 empty-states 两个既有未提交文件，不要动它们。
- 关键代码锚点：`HomeViewController.loadView()` 内 scrollView 约束（`make.edges.equalToSuperview()`）与 `render(_:)` 内 placeholderView 约束；`CoveStyle.swift` 约 196-211 行的 Fonts 区。
- 可能有另一个 agent 在同一工作树并行改别的文件并跑构建：若 xcodebuild 报 build-dir 锁 / DB 占用类错误，属瞬时竞争，等 60 秒有界重试（≤3 次）；不要因此改任何配置。
- 已知排障注记：`make test` 若在 App target 步报 CodeSign 失败（CoveTests.xctest 未签名），先增量重跑一次，仍失败再 `make clean` 后重跑；这是 DerivedData 一次性腐坏，不是代码或签名配置问题——不得为此改 `project.yml`。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）

1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式

停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
