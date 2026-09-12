---
task: /Users/boyang/code/Cove/plans/TASK-vault-pins.md
status: done
from: Planner
to: Executor
created: 2026-09-12
---

# 任务：Pin vault folders to the sidebar（本地仓库文件夹固定到侧栏）

## 目标
把 vault 内文件夹（≤8 个）固定为侧栏底栏快捷行（本地仓库行与
设置行之间），单击直达子目录；存 vault 相对路径 + 可选别名；失效
置灰不自动删。成功标准 = TASK 文件
（/Users/boyang/code/Cove/plans/TASK-vault-pins.md）的 DoD 五条 +
`make build` / `make test` 全绿。TASK 文件「Decisions」一节七条
全部照做，不得擅自变更。

## 现状锚点（卡 1 已入库，在其之上加）
- 底栏 /Users/boyang/code/Cove/Cove/Features/Servers/Views/SidebarBottomBar.swift：
  「1pt 分隔线 + 本地仓库行 + 设置行」自 sizing；行 =
  SidebarDestinationRowView（胶囊高亮 + NSClickGestureRecognizer
  单击 onTap；isAccessibilityElement button 角色范式可复用）。
- 侧栏 VM /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift：
  activeDestination + onXxxChange 回调模式。
- 浏览器右键 /Users/boyang/code/Cove/Cove/Features/Browser/Views/BrowserViewController.swift：
  ContextMenuIntent 纯枚举 + menuNeedsUpdate 重建；vault 模式现仅
  deleteFromVault 一项。
- ContentItem（Frameworks/SourceKit）：isDirectory + path（"/" 开头
  share 相对；vault 模式即 vault 相对路径，直接作存储值）。
- 存储范式 /Users/boyang/code/Cove/Cove/Services/Settings/ShareOpenStore.swift：
  纯值 + UserDefaults 壳（注入 suite/clock，隔离 suite 可测）。
- 协调器 /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift：
  openVault() 异步连本地源；下钻走 browserViewController.onOpenDirectory
  闭包；LibraryNavigationPath 管返回栈。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Services/Settings/VaultPinStore.swift（新建：
  VaultPins 纯值——有序 [{path, alias?}]、cap 8、add/remove/contains、
  setAlias（空串=清除）、plist 往返；+ UserDefaults 壳注入 suite）
- /Users/boyang/code/Cove/Cove/Services/Vault/VaultService.swift（改：
  pin 目标存在性——解析 vault 根 + 相对路径，FileManager 同步 stat）
- /Users/boyang/code/Cove/Cove/Features/Browser/Views/BrowserViewController.swift（改：
  ContextMenuIntent 对称 pin 分支——纯函数签名扩参传 pins 状态；
  未 pin 目录显「固定到侧栏」、已 pin 显「从侧栏移除」；动作闭包
  转发协调器，View 不碰存储）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/SidebarBottomBar.swift（改：
  本地仓库行与设置行之间插 pin 行区——setPins API；行=白色 folder
  图标 + 显示名（alias ?? 文件夹名）+ toolTip 完整路径；单击
  onOpenPin；右键菜单「设置别名…」「从侧栏移除」；置灰行不响应
  单击但保留右键；0 pin 时底栏外观与现状完全一致）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift（改：
  pins 状态 + 变更回调；无 AppKit 类型）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/ServerListViewController.swift（改：
  VM→bar 下行（订阅 onPinsChange → bottomBar.setPins）与 bar→协调器
  上行（onOpenPin/onSetAlias/onRemovePin 三闭包声明 + loadView 转发），
  仿现有 onOpenVault/onOpenSettings 范式——Executor 首轮上报指出此
  文件是 VM 与 bar 的唯一接线点，Planner 漏列，2026-09-12 补入）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift（改：
  持有 VaultPinStore；pin 增删/别名 → 持久化 + 推侧栏；
  openVaultFolder(relativePath:) 复用 openVault 后按路径下钻；
  启动/pin 变更/vault 根变更/进入本地仓库时刷存在性；「设置别名…」
  弹输入（NSAlert accessory 文本框即可，预填当前显示名，空串=恢复
  本名）；cap 满时点「固定到侧栏」弹 alert「最多固定 8 个文件夹」）
- /Users/boyang/code/Cove/Tests/CoveTests/VaultPinStoreTests.swift（新建：
  纯值 cap/dedupe/order/alias/plist 往返 + 隔离 suite 壳测试）
- /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift（改：VM pins
  用例 + contextMenuIntent 对称分支用例）
- 新文件跑 `make generate` 入库（project.yml 唯一事实来源，规矩 7）。

## 验收标准（DoD）
见 TASK 文件 DoD 五条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性
规矩：禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency
零新警告（10）、SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、
测试 Tests/CoveTests 优先 Swift Testing（15）。红线：任何代码路径
不得删除/移动/重命名用户磁盘文件。

## 上游任务产出
TASK-sidebar-bottom-bar（已归档入库）：底栏结构与单击/高亮体系。
不得改动已有两行（本地仓库/设置）与单高亮不变量
（syncBarHighlight：底栏胶囊只在表格无选中时显示）。pin 行只做
单击跳转，不设"当前 pin"高亮语义（不画胶囊）——若实现中发现必须
引入，请在上报中说明理由而不是擅自加。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- 服务器（SMB）文件夹固定明确 Out of Scope。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
