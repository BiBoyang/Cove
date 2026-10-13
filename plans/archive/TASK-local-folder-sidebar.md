# TASK-local-folder-sidebar：侧边栏「本地文件夹」区块

## 目标
用户在侧边栏看到「本地文件夹」区块：可添加（NSOpenPanel 选目录）、点击打开浏览、右键移除、书签失效时灰显并提供「重新选择」。至此功能端到端可用。

## 背景与决策
- 上游：TASK-local-folder-store（持久化/解析）+ TASK-local-folder-browse（`openLocalFolder(folderID:)`、`SidebarDestination.localFolder`）。
- UI 规约：纯 AppKit + SnapKit（仅在 Features Views 层）；UI 文案中文；View 只转发意图，bookmark 创建在 View 的 NSOpenPanel 回调里完成（AppKit API 不出 View 层），store/coordinator 不碰 NSOpenPanel。
- 失效条目不自动删除（与 vault pin 同纪律）：灰显 + 右键「重新选择…」替换 bookmark。

## In Scope
- `/Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift`：本地文件夹行模型（id/name/status，纯值，规矩 16），行布局并入现有 rowCount 体系（新区块 header 行 + 条目行）。
- `/Users/boyang/code/Cove/Cove/Features/Servers/Views/ServerListViewController.swift`（及必要时拆出的行视图）：「本地文件夹」区块渲染、添加按钮（区块 header 右侧「+」）、点击行 → `onOpenLocalFolder` 回调、右键菜单（「移除」（确认弹窗）/失效条目额外「重新选择…」）、失效行灰显。
- 接线：`LibraryCoordinator` 把 store 变化 → ViewModel 更新、点击 → `openLocalFolder`、添加/移除/重选 → `LocalFolderStore` 写入。NSOpenPanel 的 `canChooseDirectories = true`、不允许多选；选中后创建 security-scoped bookmark 入 store，再直接打开。
- 测试：ViewModel 行布局/状态；coordinator 接线（添加后列表刷新、移除后若正在浏览该文件夹的处理——保持当前浏览但条目消失即可，不强制切走）。

## Out of Scope
- 拖拽排序、别名重命名、文件夹图标定制。
- 首页「继续观看」对 local:// 来源的展示与 resume/reveal 路由（TASK-local-folder-home，批次 2 发现计划缺口后增补）。
- 本地文件夹内容的删除/下载/pin（只读决策，永久不做本 TASK 内）。

## DoD
1. 添加 → 立即出现在列表并打开浏览；重启 App 后条目仍在且可直接打开（书签恢复）。
2. 移除有确认弹窗；移除不删除磁盘上任何文件。
3. 书签失效（文件夹被改名/移动）→ 行灰显，点击给错误提示，右键「重新选择…」恢复。
4. 区块在零条目时显示 header + 「+」即可，不占多余高度；与既有服务器列表/pin capsule 布局无串扰。
5. 添加流程收口批次 1 Review 的 Minor finding：创建书签后先 resolve 出 URL，与已存条目 resolve 后的 standardizedFileURL.path 比对，同路径拒绝添加并提示「该文件夹已添加」。
6. `make generate && make test` 通过。

## 用户验收清单（WORKFLOW.md §5.2 必填）
1. 前置：已构建 Debug 包并启动 App。步骤：侧边栏「本地文件夹」点「+」，选一个含视频/图片/CBZ 的本地目录。通过标准：目录立即打开，可浏览子目录，双击图片/视频/CBZ/PDF 均能正常阅读播放。回传：操作结果口述 + 截图。
2. 前置：同上。步骤：完全退出 App（⌘Q）后重新启动，点击该本地文件夹条目。通过标准：无需重新选择即可打开。回传：操作结果口述。
3. 前置：同上。步骤：在 Finder 里把该目录改名，回 App 点击条目。通过标准：条目灰显/提示失败，右键「重新选择…」选中新路径后恢复。回传：操作结果口述。
4. 前置：同上。步骤：右键条目选「移除」并确认；去 Finder 检查原目录。通过标准：条目消失，磁盘文件完好。回传：操作结果口述。
5. 前置：已添加某目录。步骤：再次点「+」选同一目录。通过标准：被拒绝并提示「该文件夹已添加」，列表不新增行。回传：操作结果口述。

## 验证命令
- `cd /Users/boyang/code/Cove && make generate && make test`

## 回滚
git 还原改动文件 + 删除本功能相关新文件；UserDefaults 中 `localFolders` 键残留无害（下次启动不再读取）。
