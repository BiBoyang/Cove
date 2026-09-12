---
task: /Users/boyang/code/Cove/plans/TASK-continue-watching.md
status: done（2026-09-13 Review Approved；真机验收过：启动落首页网格/深链续播/清理语义/高亮不变量）
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：Home destination（侧栏「首页」入口，continue-watching 卡增补）

## 目标
侧栏底栏加「首页」目的地行，任意页面一键回 idle 页（引导 + 最近
播放卡片排），补上 continue-watching 的入口窟窿。成功标准 = TASK
文件（/Users/boyang/code/Cove/plans/TASK-continue-watching.md）末尾
Amendment 节的 DoD 增补四条 + `make test` 全绿。Amendment 内容照做，
不擅自变更。

## 现状锚点（均已核实）
- 目的地枚举 /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift：
  `enum SidebarDestination { none, vault, settings }`（约 5 行）→ 增
  .home；setActiveDestination（约 78 行）现状。
- 底栏 /Users/boyang/code/Cove/Cove/Features/Servers/Views/SidebarBottomBar.swift：
  行序 separator → vaultRow → pinsArea → settingsRow（约 42-73 行
  布局）；SidebarDestinationRowView（166 行起，symbol/title/tint +
  onTap + setActive 胶囊，范式照抄）；syncRows（约 89 行）加
  homeRow.setActive(lastDestination == .home)；homeRow = house 图标
  +「首页」+ tint .labelColor（与设置行同中性，不用 accentGold），
  插 separator 与 vaultRow 之间，行高 CoveStyle.rowSidebar；新增
  onOpenHome 闭包（与 onOpenVault/onOpenSettings 同声明区）。
- 接线 /Users/boyang/code/Cove/Cove/Features/Servers/Views/ServerListViewController.swift：
  bottomBar.onOpenVault 转发范式处补 onOpenHome 转发到协调器。
- 重置编排 /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift：
  resetAfterRemovingCurrentServer（约 278-289 行）——openHome()
  全套复用其重置步骤 + serverListViewModel.setActiveDestination(.home)；
  公共重置体可提取私有方法两处调用，也可 openHome 内联同序步骤，
  Executor 二选一上报说明；onOpenHome 闭包接线进 wireCallbacks。
- 单高亮不变量：底栏胶囊只在表格无选中时显示（syncBarHighlight，
  ServerListViewController 内），新行参与同一机制，不许破坏。
- 测试落点：底栏/侧栏既有测试套件就近（自查）；**禁止**
  /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift（并行
  任务占用中）——若自然落点即该文件，改新建
  /Users/boyang/code/Cove/Tests/CoveTests/HomeDestinationTests.swift
  并跑 make generate。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift（改：.home 枚举）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/SidebarBottomBar.swift（改：homeRow 行 + onOpenHome + syncRows）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/ServerListViewController.swift（改：onOpenHome 转发接线）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift（改：openHome() + wireCallbacks 接线）
- 测试文件：就近套件或 HomeDestinationTests.swift（新建则 make generate）
- 不动 plans/、prompts/（Planner 自理）；README 提交阶段同步。

## 验收标准（DoD）
见 TASK 文件 Amendment 节 DoD 增补四条；另遵守
/Users/boyang/code/Cove/AGENTS.md 硬性规矩：禁 SwiftUI（4）、注释
英文/UI 中文（6）、strict concurrency 零新警告（10）、SnapKit 只在
Views（11）、VM 无 AppKit 类型（16）、测试优先 Swift Testing（15）。

## 上游任务产出
- continue-watching 主任务（同树未提交，Herschel 已完工）：最近播放
  卡片排即本入口的目的地内容，两批改动同卡一并提交，冲突零预期。
- 侧栏底栏 B-3 + pins（已归档）：行范式/高亮不变量/pinsArea 零高
  语义，不得回退任何一条。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove；工作树已有 continue-watching 主任务
  的未提交改动，属同一任务卡，不碰不重排。
- 禁止任何 git 写操作（add/commit/push/mv）。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
