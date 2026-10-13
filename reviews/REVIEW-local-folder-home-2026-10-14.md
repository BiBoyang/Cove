# REVIEW-local-folder-home（2026-10-14）

## 结论：Approved

## 证据核对
| 项 | 状态 | 证据 |
|---|---|---|
| TASK 哈希派发后零改动 | Done | `f4f765ed…ad7b` 与记录一致；PROMPT 哈希变化仅为状态头翻转（豁免） |
| status 过程记录在位 | Done | 4 行 append-only（step 1-4） |
| 改动范围 = 计划清单 | Done | HomeViewModel / LibraryCoordinator / 新增 LocalFolderHomeTests / PlaybackProgressStoreTests 一行适配（属 Tests 扩展条款） |
| Executor 自报 make test exit=0 | Done | 上报两次全绿（425 tests / 68 suites） |
| Reviewer 独立复跑 | Done | 2026-10-14 04:59 定向 4 个 suite（LocalFolderHome / ContinueWatching / PlaybackProgressStore / HomeDestination）TEST SUCCEEDED |
| 真机验收 | Owner 提审即视为通过 | 3 项验收清单由 Owner 提审动作确认 |

## DoD 逐项
1. parse local:// + 副标题文件夹名 — Done（`parse(_:localFolderNames:)`，非法键 nil，未知 id 兜底「本地文件夹」，`locationText` 与 vault 同构）
2. resume 路由 + 终态失败 prune — Done（书签失效/文件消失两路 prune + alert；连接失败保留记录；generation 守卫静默取消）
3. reveal 路由 — Done（同一深链 + revealItem）
4. statFileFacts local 分支 — Done（resolve + LocalFileSource.metadata，失效降级 nil）
5. 测试覆盖 — Done（6 用例：parse 三态、resume/reveal prune、stat 命中/降级）
6. make test — Done

## Findings
- [Minor] `resumeLocalFolderPlayback` 先 resolve 预检、`openLocalFolder` 内部再 resolve 一次——双解析开销可忽略，仅记录。
- [观察] 接口差异微调（`openLocalFolder` 补 `initialPath:completion:`）符合 PROMPT「以实际代码为准微调」授权，默认参数保证既有三调用点零改动，diff 核实与 openVault 同构。
- [观察] resume 走导航式深链（非 headless）是 TASK 明确指定的路线，非偏差。

## 测试意见
覆盖 parse/路由/降级/prune 全链；`PlaybackProgressStoreTests` 的一行闭包化适配是签名变化的必然连带，合规。

## 残余风险
- 本地文件夹被移除后，其「继续观看」卡片以兜底名「本地文件夹」留存（设计语义：记录不静默消失），点击后走 prune 路径清除——自洽。
- 真机验收证据未逐条回传（Owner 提审即确认）。

## 变更摘要
HomeViewModel +51/-10、LibraryCoordinator resume/reveal/stat 三路 local 分支 + openLocalFolder 深链参数、新增 LocalFolderHomeTests（6 用例）、PlaybackProgressStoreTests 1 行适配；无数据迁移；`local://` 旧记录在旧版本 App 中被 parse 跳过，向前兼容。
