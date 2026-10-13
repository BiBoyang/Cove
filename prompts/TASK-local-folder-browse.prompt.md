---
task: /Users/boyang/code/Cove/plans/TASK-local-folder-browse.md
status: done
from: Planner
to: Executor
created: 2026-10-13
---

# 任务：本地文件夹浏览管线接入（coordinator 三态泛化 + openLocalFolder）

## 目标
把 `browsingVault: Bool` 泛化为三态浏览上下文，新增 `openLocalFolder(folderID:)` 复用 LocalFileSource 管线；`.local` 浏览模式只读。成功标准：DoD 全过、既有测试零回归、`make generate && make test` 通过。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift（修改）
- /Users/boyang/code/Cove/Cove/Features/Browser/Views/BrowserViewController.swift（修改：`BrowseMode` 加 `.local`，`contextMenuIntent` 返回空）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift（修改：`SidebarDestination` 加本地文件夹表达）
- /Users/boyang/code/Cove/Tests/CoveTests/（新增或扩展测试文件）

## 验收标准（DoD）
1. 三态 enum（remote/vault/local(folderID)）替换 Bool；下载、pin 刷新、删除确认、`bypassOriginalPool`、标题等所有现有分支逐个迁移，vault 语义只在 `.vault` 生效。
2. `openLocalFolder(folderID:)`：用上游 `LocalFolderStore.resolve` 取 URL，失败走错误提示；成功 `connectLocal(LocalFileSource(root:, sourceID: "local://\(folderID)"))`，编排仿 `openVault`（generation 守卫、先清旧 thumbnail provider）。窗口标题 = 文件夹 displayName。
3. `.local` 右键菜单为空数组，测试钉死；`.local` 下下载/删除/pin 路径不可达，测试钉死。
4. 播放进度经 `sourceID|path` 键自然落入 PlaybackProgressStore（`local://` 前缀），有测试或集成验证。
5. `cd /Users/boyang/code/Cove && make generate && make test` 通过，既有测试零回归。

## 上游任务产出
TASK-local-folder-store 提供 `/Users/boyang/code/Cove/Cove/Services/Settings/LocalFolderStore.swift`（`resolve(id:)` 返回 `(url:, status:)`）。开工前先读该文件确认接口形状；若接口与本描述不符，以实际代码为准微调，差异在上报中说明。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/code/Cove/prompts/TASK-local-folder-browse.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，
并附 status 文件绝对路径（未写过程记录视为未完成）。
