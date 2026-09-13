# TASK: 修复侧栏底栏 pin 高亮胶囊泄漏（双高亮）

- 状态：done（2026-09-13 执行完毕，Review Gate: Approved）
- PROMPT：`/Users/boyang/code/Cove/prompts/TASK-pin-capsule-leak.prompt.md`

## 背景 / 现状

- 侧栏底栏（`SidebarBottomBar`）固定行：首页 / 本地仓库 / pin 行 / 设置，设计目标是单高亮（single-highlight invariant）。
- pin 胶囊由 `ServerListViewModel.activePinPath` 驱动，仅在 `loadDirectory`（vault 内设值 / 非 vault 清空）与 `refreshPins` 中更新。
- 离开 vault 的路径（`showHomePage` / `showSettings` / `backToShareGrid` / `enumerateShares`）只改 `activeDestination`，从不清 `activePinPath` → pin 行与「设置」或「首页」同时高亮；`backToShareGrid` 后浏览服务器共享列表时 pin 残留高亮。
- 附加洞：`showSettings` 不重置 `browsingVault`，在设置页内触发 `refreshPins`（pin 增删 / vault 根目录变更）会把 pin 重新点亮。
- 复现路径：pin 一个 vault 文件夹 → 点 pin 进入（pin 行亮）→ 点「设置」或「首页」→ 底栏两个胶囊同时亮。

## 目标

任何非「本地仓库」目的地（首页 / 设置 / 服务器页面）下，底栏 pin 行不得显示高亮胶囊；底栏任意时刻至多一个高亮。vault 内部导航的 pin 跟随行为保持不变。

## 拆解（Steps）

1. `ServerListViewModel.setActiveDestination`：destination != .vault 时同时清 `activePinPath`（状态层主修复，纯 Swift 可单测）。
2. `LibraryCoordinator.showSettings`：补 `browsingVault = false`（离开 vault 语义，与 `resetToHomeState` / `backToShareGrid` / `enumerateShares` 对齐），堵住 refreshPins 在设置页重新点亮 pin 的洞。
3. `SidebarBottomBar.syncRows`：pin 行 active 条件加 `lastDestination == .vault`（渲染层不变量兜底，使「一个底栏至多一个胶囊」无条件成立）。
4. `Tests/CoveTests/ViewModelTests.swift` 增补用例（Swift Testing）：.vault→.settings / .home / .none 均清 pin；vault 内 `setActivePinPath` 保持；`activePin(forPath:pinnedPaths:)` 嵌套匹配行为不回归。

## DoD

1. 上述 4 步全部落地，边界输入有处理（pin 为 nil / pins 为空列表均正常）。
2. 改动范围仅限声明文件，无无关修改；不碰 `project.yml`、不重新生成工程（无新文件）。
3. 新增/更新测试通过；`make build` 与 `make test` 通过。
4. 零并发警告（`SWIFT_STRICT_CONCURRENCY: complete`）；注释英文、UI 文案中文。
5. 无 git add / commit / push（提交归 Owner）。
6. 验证可复现：报告附自测命令与结果。

## 风险与回滚

- 已排查：`activePinPath` 的唯一消费者是底栏渲染（`ServerListViewController.syncBarHighlight`），无其他路径依赖「非 vault 目的地下保留 pin」，主修复安全。
- 顺序依赖不可破坏：`openVault` 先 `setActiveDestination(.vault)` 后由 `loadDirectory` 设 pin；vault 内 `refreshPins` 行为不变。
- 回滚：三处源码改动各自独立，逐文件 revert 即可。
