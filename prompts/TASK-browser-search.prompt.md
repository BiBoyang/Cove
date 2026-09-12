---
task: /Users/boyang/code/Cove/plans/TASK-browser-search.md
status: done
from: Planner
to: Executor
created: 2026-09-12
---

# 任务：Browser name filter（浏览器名称过滤，1.0 批 1 首卡）

## 目标
浏览器当前目录按名称过滤，纯本地、零网络；share 与 vault 同一管线
一处实现两处生效。成功标准 = TASK 文件
（/Users/boyang/code/Cove/plans/TASK-browser-search.md）的 DoD 五条 +
`make test` 全绿。TASK 文件「Decisions」九条全部照做，不得擅自变更。

## 现状锚点（v0.7.0 之上加，以下均已核实）
- VM /Users/boyang/code/Cove/Cove/Features/Browser/ViewModels/BrowserViewModel.swift：
  `State` memberwise 构造共 5 处（init / beginLoading / display /
  setDownload / setPreheat），全部要补 filterQuery 参数；`display`
  已调 `Self.visibleItems(from:)` 做噪声过滤+排序——filterItems 是
  其姊妹静态纯函数；`imageItems` / `videoItems` / `item(atPath:)`
  基于 `state.items`，本任务保持不动（播放列表不受过滤影响）。
- VC /Users/boyang/code/Cove/Cove/Features/Browser/Views/BrowserViewController.swift：
  表格读 `viewModel.state.items` 的位置共 5 处——numberOfRows、
  viewFor(row:)、handleDoubleClick、revealItem(atPath:)、
  menuNeedsUpdate（selectionOnRightClick 的 itemCount +
  contextMenuIntent 的 items 参数），全部改读 `state.displayedItems`。
  工具条布局：leading = back/preheat/preheatProgressLabel，居中 =
  locationLabel（中间截断 + 低 hugging/低压缩抵抗），trailing =
  downloadLabel(≤320 截断)/downloadCancelButton；工具条高
  CoveStyle.barBrowserToolbar(52)。占位逻辑在 renderPlaceholder：
  现仅 isLoading→加载态、canGoUp && items.isEmpty→空文件夹两分支，
  按 Decisions 8 扩无匹配分支（判定用 displayedItems 空 +
  state.items 非空 + query 非空）。
- 菜单 /Users/boyang/code/Cove/Cove/Application/AppDelegate.swift：
  installMainMenu() 手工构建，编辑菜单现有 撤销/重做/剪切/拷贝/
  粘贴/全选；「查找…」⌘F 加在编辑菜单尾部（分隔线后），
  target=nil（responder chain），action 指向 BrowserViewController
  新增的选择子（如 focusSearchField:），该选择子内
  `view.window?.makeFirstResponder(searchField)`。
- 空态组件 /Users/boyang/code/Cove/Cove/SharedUI/StatePlaceholderView.swift：
  init(style:title:message:actionTitle:)，无匹配用
  style: .symbol("magnifyingglass")，不需要 action 按钮。
- 测试范式 /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift：
  Swift Testing + @testable，现有 placeholderTint / contextMenuIntent /
  locationText / visibleItems 静态纯函数用例可直接仿写；ContentItem
  构造 helper 文件内已有。
- 设计令牌 /Users/boyang/code/Cove/Cove/SharedUI/CoveStyle.swift：
  计数标签用 captionFont + secondaryLabelColor；间距走 space* 档位；
  本任务不新增令牌。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Features/Browser/ViewModels/BrowserViewModel.swift
  （改：State.filterQuery + displayedItems 计算属性 + setFilter(_:) +
  静态 filterItems(_:query:) + beginLoading/display 清零）
- /Users/boyang/code/Cove/Cove/Features/Browser/Views/BrowserViewController.swift
  （改：工具条搜索框 + 计数标签；5 处 state.items → displayedItems；
  占位无匹配分支；⌘F action；Esc/回车焦点行为；VM→field 文本不同
  才写入）
- /Users/boyang/code/Cove/Cove/Application/AppDelegate.swift
  （改：编辑菜单加「查找…」⌘F，target=nil）
- /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift
  （改：filterItems 纯函数用例 + VM 行为用例，仿现有范式，不新建文件）
- 不新建任何源码文件，无需 make generate；README 由提交阶段同步，
  Executor 不动。

## 验收标准（DoD）
见 TASK 文件 DoD 五条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性
规矩：禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency
零新警告（10）、SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、
测试 Tests/CoveTests 优先 Swift Testing（15）。

## 上游任务产出
无（直接基于 v0.7.0 后的 main）。注意 BrowserViewController 内既有
纯函数范式（contextMenuIntent / placeholderTint / locationText 均为
static + @testable 可测）——filterItems 落 VM 侧，范式同。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- Esc/回车的焦点行为用 NSTextFieldDelegate 的
  control(_:textView:doCommandBy:)（cancelOperation: / insertNewline:）
  实现，别加全局事件监控。
- 验证 ⌘F 链路时先小步确认 target=nil 菜单项在浏览器在屏时自动
  可用、不在屏时置灰；若链路断，停手在上报中说明，不擅自加文件。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
