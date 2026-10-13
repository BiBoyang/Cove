# TASK-local-folder-browse：本地文件夹浏览管线接入

## 目标
Coordinator 能把一个已持久化的本地文件夹作为虚拟 share 打开：复用 `LocalFileSource` + `SMBSessionService.connectLocal` 的既有仓库管线，浏览/缩略图/看图/视频/PDF/CBZ 全通；本地文件夹为**只读**浏览，不沾染仓库语义。

## 背景与决策
- Owner 拍板：能力范围只读——无「下载到本地仓库」（无意义）、无删除（删用户本地文件风险大）、无 pin/预热（仓库专属）。
- Owner 拍板（采纳推荐）：本地视频播放进度计入首页「继续观看」——`PlaybackProgressStore` 按 `sourceID|path` 键控，给 `LocalFileSource(sourceID: "local://<folderID>")` 即可免费获得，无需改 store。
- 上游：TASK-local-folder-store 提供 `LocalFolderStore`（resolve/status）。

## In Scope
- `/Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift`：
  - `browsingVault: Bool` 泛化为三态浏览上下文（如 `enum BrowseContext { case remote, vault, local(folderID: String) }`），所有现有分支（下载入口、pin 刷新、删除确认、`bypassOriginalPool`、标题）逐个迁移；vault 语义只在 `.vault` 下生效，local 下下载/删除/pin 路径全部不可达。
  - 新增 `openLocalFolder(folderID:)`：resolve bookmark → 失败则错误提示（"打开本地文件夹失败"，附重新选择引导文案）→ 成功则 `connectLocal(LocalFileSource(root: url, sourceID: "local://\(folderID)"))` → 装缩略图 provider → `loadDirectory(at: "/")`。编排仿 `openVault`（generation 守卫、先清旧 provider 再连）。
  - 窗口标题 = 文件夹 displayName。
- `/Users/boyang/code/Cove/Cove/Features/Browser/Views/BrowserViewController.swift`：`BrowseMode` 加 `case local`；`contextMenuIntent` 对 `.local` 返回空数组（只读）。
- `/Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ServerListViewModel.swift`：`SidebarDestination` 加本地文件夹表达（如 `.localFolder(id: String)`），供高亮态使用；pin capsule 语义不变（非 vault 时清空，现有逻辑已覆盖）。
- 测试：`/Users/boyang/code/Cove/Tests/CoveTests/` 新增/扩展——`.local` 右键菜单为空；三态迁移后 vault 删除/下载路径在 `.local` 下不可达；openLocalFolder 的 generation 守卫与书签失败降级（仿现有 coordinator 测试的注入缝模式）。

## Out of Scope
- 侧边栏「本地文件夹」区块 UI 与 NSOpenPanel（TASK-local-folder-sidebar）。
- 本地文件夹的添加/移除/重选交互。

## DoD
1. 三态泛化编译期兜底（enum 无 Bool 残留）；既有 vault/remote 行为测试全绿无回归。
2. `.local` 模式右键菜单为空数组，有测试钉死。
3. 打开流程有 generation 守卫；书签失效走错误提示路径而非崩溃/空目录。
4. 本地视频播放进度能写入 PlaybackProgressStore（sourceID 含 `local://` 前缀，有测试或集成验证）。
5. `make generate && make test` 通过。

## 验证命令
- `cd /Users/boyang/code/Cove && make generate && make test`

## 回滚
git 还原改动的四个文件；无数据迁移。
