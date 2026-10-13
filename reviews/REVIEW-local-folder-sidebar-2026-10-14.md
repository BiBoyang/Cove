# REVIEW-local-folder-sidebar（2026-10-14）

## 结论：Approved

## 证据核对
| 项 | 状态 | 证据 |
|---|---|---|
| TASK 哈希派发后零改动 | Done | `5dc05c53…5373` 与修订记录一致；PROMPT 哈希变化仅为状态头翻转（Owner 维护字段，豁免） |
| status 过程记录在位 | Done | 3 行 append-only（step 0/1/2） |
| 改动范围 = 计划清单 | Done | 5 文件全部在清单内（ViewModelTests.swift 属「Tests/CoveTests 扩展」条款） |
| Executor 自报 make test exit=0 | Done | 上报 418 tests / 67 suites TEST SUCCEEDED |
| Reviewer 独立复跑 | Done | 2026-10-14 03:49 定向 4 个 suite（LocalFolderSidebar / ServerViewModel / HomeDestination / SplitViewSidebarDrift）TEST SUCCEEDED |
| 真机验收 | Owner 提审即视为通过 | 5 项验收清单由 Owner 提审动作确认（证据未逐条回传，记录于此） |

## DoD 逐项
1. 添加→出现→打开；重启可恢复 — Done（书签持久化链路 = 批次 1 已审层 + `addingRefreshesAndOpens` 测试；真机项 Owner 已验）
2. 移除确认 + 不碰磁盘 — Done（`confirmRemoveLocalFolder` 弹窗文案明示；`removingBrowsedFolder` 测试钉死不切走、文件仍在）
3. 失效灰显 + 重新选择恢复 — Done（`isAvailable` 行模型 + `menuNeedsUpdate` 条件项 + `repickSwapsBookmark` 测试）
4. 零条目只占 header + 无布局串扰 — Done（`rowCount` 恒含本地 header；`rowsMapAcrossBothSections` 测试）
5. 同路径去重收口 — Done（`addLocalFolder` 按 resolved `standardizedFileURL.path` 比对，提示「该文件夹已添加。」，`addingSamePathTwice` 测试）
6. make generate && make test — Done

## 规约抽查
- NSOpenPanel/bookmark 创建全部在 View 层回调，coordinator 只收纯值 — 合规（规矩 12/16）
- UI 文案中文、标识符英文 — 合规
- SnapKit 仅在 View/cell — 合规（两个新 fileprivate cell 均在 VC 文件内）
- `LocalFolderRow` 纯值无 AppKit — 合规（规矩 16）

## Findings
- [Minor] `SectionHeaderCellView.configure` 每次 `configure` 重建 add 按钮的 SF Symbol 图像——cell 复用频率低，开销可忽略，仅记录。
- [Minor] 右键菜单从静态项改为 `menuNeedsUpdate` 动态重建，空白处右键不再弹全灰菜单——Executor 已声明，属行为改善，接受。
- [观察] 失效条目参与去重比对时无法 resolve 路径按跳过处理——保留重选路径，语义自洽，接受。

## 测试意见
6 项新测试 + ViewModelTests 双区块适配；覆盖行布局/失效态/添加即开/去重拒绝/移除不碰磁盘/重选换书签。质量好。

## 残余风险
- 真机验收证据未逐条回传（Owner 提审即确认）；若后续发现验收项瑕疵，按新 bug 走入口 A。
- 首页「继续观看」对 local:// 的展示由批次 4（TASK-local-folder-home）收口。

## 变更摘要
ServerListViewModel +63、ServerListViewController +368/-115、LibraryCoordinator 接线 +144/-?（本步）、新增 LocalFolderSidebarTests（6 测试）、ViewModelTests 适配；无数据迁移。
