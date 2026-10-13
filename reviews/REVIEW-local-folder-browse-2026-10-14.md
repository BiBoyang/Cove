# REVIEW-local-folder-browse（2026-10-14）

## 结论：Approved

## 证据核对
| 项 | 状态 | 证据 |
|---|---|---|
| TASK 哈希派发后零改动 | Done | `70caebe0…ce06` 与派发记录一致 |
| status 过程记录在位 | Done | 3 行 append-only（step 0/1-3/4） |
| 改动范围 = 计划清单 | Done | `git status`：3 个修改 + 1 个新测试文件，全部在清单内 |
| Executor 自报 make test exit=0 | Done | 上报 412 tests / 66 suites TEST SUCCEEDED |
| Reviewer 独立复跑 | Done | 2026-10-14 03:31 `-only-testing:CoveTests/LocalFolderBrowseTests` 5/5 passed |
| 旧标识符零残留 | Done | `rg browsingVault` 仅命中新注释中的一处历史引用 |

## DoD 逐项
1. 三态泛化 + 分支迁移 — Done：`enum BrowseContext { remote, vault, local(folderID) }`；下载守卫 `== .remote`、删除确认 `== .vault`、`bypassOriginalPool != .remote`、pin capsule 仅 `.vault`、preheat 每次导航对非 remote 置 unavailable——diff 逐处核实。
2. `.local` 右键菜单为空 + 测试钉死 — Done（`localContextIsReadOnly`，含 stray intent 三路兜底验证：下载状态 nil / pin store 空 / 磁盘文件仍在）。
3. generation 守卫 + 书签失败降级 — Done（`openLocalFolder` 守卫链与 openVault 同构；失效走 onMessageError 中文引导文案）。
4. 进度落 store（local:// 键）— Done（`localProgressKey` 测试实证 `local://<id>|/a.mp4` 读写）。
5. make generate && make test — Done。

## Findings
- [Minor] `openLocalFolder` 中 `localFolderStore.load()` 与 `resolve(id:)` 各读一次 UserDefaults（resolve 内部又 load 一次）——≤16 条目，开销可忽略，仅记录。
- [观察] `HomeViewModel.parse` 的 `local://` 缺口系计划阶段判断失误，Executor 按硬停止纪律未越权修改，已按计划修订流程增补 TASK-local-folder-home（批次 4）收口。此点记为计划层教训：方案断言「免费获得」前需核实消费端过滤逻辑。

## 测试意见
5 项测试覆盖成功打开/失效降级/generation 守卫/只读不可达/进度键，隔离 suite + 真实 security-scoped bookmark，质量好。

## 残余风险
- local:// 记录在批次 4 落地前不上首页（已被新任务覆盖，非回归）。
- `SidebarDestination.localFolder` 暂无底部栏高亮渲染（批次 3 职责），仅影响视觉反馈。

## 变更摘要
LibraryCoordinator +134/-29、BrowserViewController +9/-2、ServerListViewModel +4、新增 LocalFolderBrowseTests（5 测试）；无数据迁移。
