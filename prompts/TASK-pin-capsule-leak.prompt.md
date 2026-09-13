---
task: /Users/boyang/code/Cove/plans/TASK-pin-capsule-leak.md
status: done
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：修复侧栏底栏 pin 高亮胶囊泄漏（双高亮）

先读任务契约 `/Users/boyang/code/Cove/plans/TASK-pin-capsule-leak.md`（背景/根因/拆解/DoD 以它为准），并遵守 `/Users/boyang/code/Cove/AGENTS.md` 的硬性规矩（纯 AppKit 禁 SwiftUI、SnapKit 只在 View 层、注释英文、严格并发零警告等）。

## 目标

一句话：任何非「本地仓库」目的地下底栏 pin 行不再显示高亮胶囊，底栏任意时刻至多一个高亮。成功标准：下方 DoD 全过，`make build` / `make test` 绿。

## 涉及文件（绝对路径）

- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/SidebarBottomBar.swift
- /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift

禁止碰：`project.yml`、`plans/TASK-empty-states.md`、`prompts/TASK-empty-states.prompt.md`、`prompts/TASK-home-page-title.prompt.md` 及其对应 TASK 文件与源码（另一个并行任务的地盘：`HomeViewController.swift`、`CoveStyle.swift`、`HomeDestinationTests.swift`、`design/DESIGN-TOKENS.md`）。

## 验收标准（DoD）

1. `ServerListViewModel.setActiveDestination`：destination != .vault 时清 `activePinPath`；vault 内行为不变。
2. `LibraryCoordinator.showSettings`：补 `browsingVault = false`。
3. `SidebarBottomBar.syncRows`：pin 行 active 条件加 `lastDestination == .vault`。
4. `Tests/CoveTests/ViewModelTests.swift` 增补 Swift Testing 用例：.vault→.settings/.home/.none 清 pin；vault 内 setActivePinPath 保持；`activePin(forPath:pinnedPaths:)` 嵌套匹配不回归。先读该文件既有写法，沿用同一套测试风格。
5. 在 /Users/boyang/code/Cove 下 `make build` 通过、`make test` 通过（零并发警告）。
6. 不执行任何 git add / commit / push。

## 上游任务产出

无。

## 执行提示

- 工作目录 `/Users/boyang/code/Cove`；开工前 `git status --short` 确认只有 empty-states 两个既有未提交文件，不要动它们。
- 关键代码锚点：`SidebarBottomBar.syncRows` 内 `for row in pinRows { row.setActive(row.pinPath == activePinPath) }`；`ServerListViewModel.setActiveDestination`；`LibraryCoordinator.showSettings`（约 906 行，`_ = beginNavigation()` 之后）。
- 可能有另一个 agent 在同一工作树并行改别的文件并跑构建：若 xcodebuild 报 build-dir 锁 / DB 占用类错误，属瞬时竞争，等 60 秒有界重试（≤3 次）；不要因此改任何配置。
- 已知排障注记：`make test` 若在 App target 步报 CodeSign 失败（CoveTests.xctest 未签名），先增量重跑一次，仍失败再 `make clean` 后重跑；这是 DerivedData 一次性腐坏，不是代码或签名配置问题——不得为此改 `project.yml`。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）

1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式

停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
