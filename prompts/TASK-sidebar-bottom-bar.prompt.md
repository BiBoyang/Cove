---
task: /Users/boyang/code/Cove/plans/TASK-sidebar-bottom-bar.md
status: done
from: Planner
to: Executor
created: 2026-09-12
---

# 任务：Sidebar bottom bar (vault + settings pinned) + single-click activation

## 目标
把侧栏表格里的「本地仓库」「设置」两行撤出，做成钉在侧栏底部的
固定栏（不随服务器数量/窗口 resize/全屏移动），并把侧栏激活语义
改为鼠标单击。成功标准 = TASK 文件
（/Users/boyang/code/Cove/plans/TASK-sidebar-bottom-bar.md）里的
DoD 五条全部满足，`make build` 与 `make test` 全绿。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift（改）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/ServerListViewController.swift（改）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/SidebarBottomBar.swift（新建；名字可微调，留在同目录）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift（改：openSettings 不再选表行、目的地同步、连接幂等护栏）
- /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift（改：行数学用例更新 + activeDestination 用例）
- /Users/boyang/code/Cove/design/DESIGN-TOKENS.md（仅在引入新设计值时登记，能复用现有令牌就不动）

## 验收标准（DoD）
见 TASK 文件「DoD」一节，五条全满足；另需遵守
/Users/boyang/code/Cove/AGENTS.md 硬性规矩：禁 SwiftUI（4）、注释与
标识符英文 / UI 文案中文（6）、strict concurrency 零警告（10）、
SnapKit 只在 Views（11）、ViewModel 不含 AppKit 类型（16）、测试
放 Tests/CoveTests 优先 Swift Testing（15）。

## 上游任务产出
TASK-settings-pane-anchor（Planner 内联，同批次）：设置页 document
置顶约束 + 主窗口 contentMinSize 900x700 / 初始 1024x720，与本任务
无文件交集，可直接在其之上开发。

## 协作纪律
- 开工前先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove 工作树上（项目 AGENTS.md 要求）。
- 一次只推进本任务；未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
