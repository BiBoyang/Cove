---
task: /Users/boyang/code/Cove/plans/TASK-continue-watching.md
status: done（2026-09-13 Review Approved；真机验收过：启动落首页网格/深链续播/清理语义/高亮不变量）
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：Home recent-watches page（首页=最近播放页，continue-watching 卡 Amendment 2）

## 目标
把「首页」从 idle 页附属 strip 升格为独立的最近播放页面：纵向网
格 + 两级空态，启动即落首页。成功标准 = TASK 文件
（/Users/boyang/code/Cove/plans/TASK-continue-watching.md）Amendment 2
节的 DoD 四条 + `make generate && make test` 全绿。Amendment 2 的
Decisions 七条全部照做，不得擅自变更。

## 现状锚点（均已核实；工作树含 continue-watching 主任务 + 首页入口
增补的未提交改动，是你的作业基线，不碰不重排）
- 网格范式 /Users/boyang/code/Cove/Cove/Features/Servers/Views/ShareGridViewController.swift：
  loadView 的 NSCollectionView flow layout（160x130、spacing/sectionInset
  全走 CoveStyle 令牌，约 42-52 行）、register/dataSource/双击手势
  recognizer 范式（约 53-64 行）；ShareCardItem（约 165 行起：
  RoundedFillView + borderColor + hover/selection updateHighlight）。
- 待改造组件：同文件底部的 RecentWatchStripView/RecentWatchCardView
  （约 283-450 行）——strip 容器废弃删除，卡片视图改造为
  RecentWatchCardItem 迁入新 HomeViewController 文件。
- 待回退管道 /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ShareGridViewModel.swift：
  recentWatches 状态、showingIdlePage、refreshRecentWatches、
  showPlaceholder 的 recentWatches 参数——全部移除回退纯占位；
  RecentWatchEntry/RecentWatchSource/parse/recentList/subtitleText
  搬去新 HomeViewModel.swift（本文件清空相关业务但保持既有占位
  功能零回归）。
- 路由 /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift：
  start()（约 103 行）现走 showIdlePlaceholderForCurrentServerList；
  openHome()（约 296 行）现走 resetToIdleState；二者改路由到新
  首页 pane（homeViewModel.refresh() + onShowDetail(homeVC)），
  setActiveDestination(.home) 结构置位随首页路由保持；
  resetAfterRemovingCurrentServer 的落点同步改；resumePlayback 深链
  与 removeRecentWatch 的 refresh 调用改指 HomeViewModel；
  showIdlePlaceholderForCurrentServerList 视新结构收敛或删除（首页
  空态两级吸收其职能），上报说明取舍。
- 测试平移：/Users/boyang/code/Cove/Tests/CoveTests/ContinueWatchingTests.swift
  （idle-strip 用例改指 HomeViewModel/首页 pane）、
  /Users/boyang/code/Cove/Tests/CoveTests/HomeDestinationTests.swift
  （断言里的「idle 占位 + 最近播放排在场」改指首页 pane 与其空态）。
- 协调器持有的子控制器声明区（LibraryCoordinator 头部）与
  wireCallbacks() 接线范式照抄。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/HomeViewModel.swift（新建：
  recentWatches 状态 + refresh + 两级空态判定 + RecentWatchEntry 系
  列搬迁；注入 recentWatchRecords 测试缝同范式）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/HomeViewController.swift（新建：
  纵向网格 + 空态占位 + RecentWatchCardItem + onResumeWatch 转发）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ShareGridViewModel.swift（改：
  strip 管道回退，占位功能零回归）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/ShareGridViewController.swift（改：
  strip 组件与渲染分支删除）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift（改：
  start/openHome/删服务器路由 + 首页装配与接线 + refresh 改指）
- /Users/boyang/code/Cove/Tests/CoveTests/ContinueWatchingTests.swift（改：用例平移）
- /Users/boyang/code/Cove/Tests/CoveTests/HomeDestinationTests.swift（改：断言平移）
- 两个新文件跑 `make generate` 入库；**禁止** 
  /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift（并行
  任务占用中）；README 提交阶段同步。

## 验收标准（DoD）
见 TASK 文件 Amendment 2 节 DoD 四条；另遵守
/Users/boyang/code/Cove/AGENTS.md 硬性规矩：禁 SwiftUI（4）、注释
英文/UI 中文（6）、strict concurrency 零新警告（10）、SnapKit 只在
Views（11）、VM 无 AppKit 类型（16）、测试优先 Swift Testing（15）。

## 上游任务产出
- continue-watching 主任务（同树未提交）：RecentWatchEntry 解析/
  深链/存储 duration 体系——模型搬迁不伤语义。
- 首页入口增补（同树未提交）：SidebarDestination.home + openHome +
  结构高亮——路由改向首页 pane 后语义保持。
- ShareGrid 卡片体系（线上）：网格/卡片/hover 配方镜像源。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- 禁止任何 git 写操作（add/commit/push/mv）；不动 plans/、prompts/。
- 未声明的文件改动需在提审时主动说明原因。
- make test 若 App target 步报 CodeSign 失败或 DerivedData 异常：
  先增量重跑一次，仍失败再 make clean（AGENTS.md 排障注记），
  不改 project.yml。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
