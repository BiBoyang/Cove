---
task: /Users/boyang/code/Cove/plans/TASK-local-folder-sidebar.md
status: done
from: Planner
to: Executor
created: 2026-10-13
---

# 任务：侧边栏「本地文件夹」区块（功能端到端收口）

## 目标
侧边栏新增「本地文件夹」区块：NSOpenPanel 添加目录、点击打开、右键移除/重新选择、失效灰显。成功标准：DoD 全过、`make generate && make test` 通过、附用户验收清单所需的可操作构建。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift（修改）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/ServerListViewController.swift（修改；如需拆行视图可新增同目录文件并在上报中说明）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift（修改：接线）
- /Users/boyang/code/Cove/Tests/CoveTests/（新增或扩展测试文件）

## 验收标准（DoD）
1. 区块 = header（「本地文件夹」+ 右侧「+」按钮）+ 条目行，并入现有 rowCount 体系；零条目时只占 header 高度。
2. 「+」→ NSOpenPanel（canChooseDirectories、单选）→ 创建 security-scoped bookmark 入 `LocalFolderStore` → 立即打开（调上游 `openLocalFolder`）。bookmark 创建只允许出现在 View 层回调，ViewModel/Services 不碰 NSOpenPanel。
3. 右键菜单：「移除」（确认弹窗，只删条目不碰磁盘）；失效条目额外「重新选择…」（NSOpenPanel 重选并替换 bookmark）。失效行灰显，点击给错误提示。
4. 高亮态接入上游 `SidebarDestination.localFolder`；与服务器列表、pin capsule 布局无串扰。
5. UI 文案中文；布局 SnapKit；ViewModel 纯值无 AppKit（规矩 16）。
6. 添加去重收口：创建书签后 resolve URL，与已存条目 resolve 后的 standardizedFileURL.path 比对，同路径拒绝并提示「该文件夹已添加」。
7. 测试：ViewModel 行布局/失效状态；coordinator 接线（添加后刷新、移除正在浏览的条目不强制切走）；同路径去重。
8. `cd /Users/boyang/code/Cove && make generate && make test` 通过。

## 上游任务产出
- TASK-local-folder-store：`/Users/boyang/code/Cove/Cove/Services/Settings/LocalFolderStore.swift`
- TASK-local-folder-browse：`LibraryCoordinator.openLocalFolder(folderID:)`、`SidebarDestination.localFolder`
开工前先读这两处确认接口形状；不符以实际代码为准微调，差异在上报中说明。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/code/Cove/prompts/TASK-local-folder-sidebar.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，
并附 status 文件绝对路径（未写过程记录视为未完成）。
