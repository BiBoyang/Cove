# REVIEW-local-folder-store（2026-10-14）

## 结论：Approved

## 证据核对（信证据不信记忆）
| 项 | 状态 | 证据 |
|---|---|---|
| TASK 哈希派发后零改动 | Done | `f5b93b4c…ca383` 与派发记录一致 |
| status 过程记录在位 | Done | `prompts/TASK-local-folder-store.status.md` 3 行 append-only，覆盖 step 1-3 |
| 改动范围 = 计划清单 | Done | `git status`：仅 2 个新文件，零既有文件改动 |
| Executor 自报 make test exit=0 | Done | `/tmp/cove-make-test6.log` 尾部 `** TEST SUCCEEDED **`（407 tests / 65 suites） |
| Reviewer 独立复跑 | Done | 2026-10-14 03:12 实跑 `-only-testing` 三个新 suite：12 tests 全 passed |

## DoD 逐项
1. plist round-trip + malformed 丢弃 — Done（`plistRoundTrip` / `malformedPlist` 测试）
2. 去重 + maxCount=16 — Done（`dedupeAndEmptyInput` / `cap`）
3. classify 三态 — Done（`LocalFolderStatusTests.classify`）
4. 英文注释 / 无 AppKit / 零并发警告 — Done（通读确认；@MainActor 壳 + Sendable 纯值）
5. make generate && make test — Done（Executor 日志 + Reviewer 复跑）

## Findings
- [Minor] `LocalFolderStore.swift` `add(name:bookmark:)` — 去重判据是 bookmark Data 字节相等。security-scoped bookmark 在**不同** NSOpenPanel 会话为同一目录生成时不保证字节一致，故「同一文件夹被添加两次」在理论上可绕过本层去重。影响：侧边栏可能出现指向同一路径的两行（上限 16 兜底，无数据损坏）。建议：TASK-local-folder-sidebar 的添加流程里，在创建书签后 resolve 出 URL，与已存条目 resolve 后的 `standardizedFileURL.path` 比对再入 store；或在后续任务中显式记录为已知限制。不阻塞本层 Approved。
- [Minor] `resolve(id:)` 每次调用都 `load()` 全量读 UserDefaults——条目 ≤16，开销可忽略，仅记录。

## 测试意见
12 项测试覆盖价值层全部分支（含 replace 拒绝跨条目重复书签、未知 id no-op）、status 三态、壳层隔离 suite 持久化与真实 security-scoped bookmark round-trip。质量好，无补充要求。

## 残余风险
- 上述 Minor 去重代理判据（留给 TASK-3 收口）。
- stale 书签的重新落盘依赖调用方（TASK-3 的「重新选择…」路径），本层只记 notice——与 vault 语义一致，接受。

## 变更摘要
新建 `Cove/Services/Settings/LocalFolderStore.swift`（187 行）+ `Tests/CoveTests/LocalFolderStoreTests.swift`（206 行）；无既有文件改动；无数据迁移。
