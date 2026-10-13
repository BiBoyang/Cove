---
task: /Users/boyang/code/Cove/plans/TASK-local-folder-home.md
status: done
from: Planner
to: Executor
created: 2026-10-14
---

# 任务：首页「继续观看」接入本地文件夹（local:// 来源）

## 目标
`local://` 进度记录可解析、可展示、可续播、可 reveal。成功标准：DoD 全过、`make generate && make test` 通过、既有测试零回归。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/HomeViewModel.swift（修改：RecentWatchSource 加 local 表达 + parse 支持 local://）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift（修改：resume/reveal/statFileFacts 三路 local 分支）
- /Users/boyang/code/Cove/Tests/CoveTests/（新增或扩展测试文件）

## 验收标准（DoD）
1. `HomeViewModel.parse` 支持 `local://<folderID>`：folderID 非空校验，非法键返回 nil；卡片副标题为文件夹 displayName（经 LocalFolderStore 查询，查不到时用兜底文案）。
2. `resumePlayback` 加 local 路由：经 `openLocalFolder(folderID:)` 深链进入并续播；书签失效/文件消失的终态失败 prune 记录（仿 `resumeVaultPlayback`）。
3. `revealWatchLocation` 加 local 路由。
4. `statFileFacts` 加 `local://` 分支（LocalFolderStore.resolve + LocalFileSource.metadata，仿 vault 分支）。
5. 测试覆盖：parse local:// 合法/非法键；resume 书签失效 prune；stat 分支。
6. `cd /Users/boyang/code/Cove && make generate && make test` 通过，既有测试零回归。

## 上游任务产出
- TASK-local-folder-store：`/Users/boyang/code/Cove/Cove/Services/Settings/LocalFolderStore.swift`（`resolve(id:) -> (url:, status:)`、`load()`）
- TASK-local-folder-browse：`LibraryCoordinator.openLocalFolder(folderID:)`（internal，含 completion 深链语义）
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
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/code/Cove/prompts/TASK-local-folder-home.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，
并附 status 文件绝对路径（未写过程记录视为未完成）。
