---
task: /Users/boyang/code/Cove/plans/TASK-local-folder-store.md
status: done
from: Planner
to: Executor
created: 2026-10-13
---

# 任务：本地文件夹持久化层（LocalFolderStore）

## 目标
新建 Services/Settings 层的本地文件夹持久化与 security-scoped bookmark 解析层（纯值 + UserDefaults 壳），单测覆盖。成功标准：DoD 全过、`make generate && make test` 通过。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Services/Settings/LocalFolderStore.swift（新建）
- /Users/boyang/code/Cove/Tests/CoveTests/LocalFolderStoreTests.swift（新建，Swift Testing）

## 验收标准（DoD）
1. `LocalFolders` 纯值层：有序条目 [{id(UUID 字符串), name, bookmark(base64)}]，plist round-trip，malformed 行丢弃，同路径去重，`maxCount = 16`。
2. `LocalFolderStatus`：`ready` / `bookmarkInvalid`，配纯分类函数（仿 `/Users/boyang/code/Cove/Cove/Services/Vault/VaultService.swift` 的 `VaultRootStatus.classify`）。
3. `LocalFolderStore`：UserDefaults 读写壳 + `resolve(id:)`，解析成功 `startAccessingSecurityScopedResource()`（进程生命周期持有），stale 记 notice 日志；线程语义对齐 `/Users/boyang/code/Cove/Cove/Services/Settings/VaultPinStore.swift`。
4. 单测覆盖：round-trip、malformed 丢弃、去重、上限、classify 三态。
5. 代码注释与标识符英文；无 AppKit/SnapKit；`SWIFT_STRICT_CONCURRENCY` 零警告。
6. `cd /Users/boyang/code/Cove && make generate && make test` 通过。

## 上游任务产出
无（第一批）。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/code/Cove/prompts/TASK-local-folder-store.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，
并附 status 文件绝对路径（未写过程记录视为未完成）。
