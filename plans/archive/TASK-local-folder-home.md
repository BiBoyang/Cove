# TASK-local-folder-home：首页「继续观看」接入本地文件夹

## 目标
本地文件夹里看过的视频出现在首页「继续观看」：可点击续播（resume）、可「在浏览器中显示」（reveal），文件消失时条目按既有语义降级/清理。

## 背景
批次 2（TASK-local-folder-browse）Executor 上报确认：`PlaybackProgressStore` 已能写入 `local://<id>|<path>` 键，但 `HomeViewModel.parse` 对非 `vault://`/`smb://` 前缀返回 nil，且 `LibraryCoordinator.resumePlayback`/`revealWatchLocation`/`statFileFacts` 只有 vault/SMB 两路——计划阶段「免费获得」的判断不准确，本任务补缺口（计划修订，Owner 已知情）。

## In Scope
- `/Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/HomeViewModel.swift`：`RecentWatchSource` 加 `case localFolder(name: String)`（或等价表达）；`parse` 支持 `local://` 前缀（folderID 段非空校验，与 smb 段校验同纪律）；卡片副标题显示文件夹名。
- `/Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift`：
  - `resumePlayback` 加 `.localFolder` 路由：经 `openLocalFolder(folderID:)`（复用其 completion/深链语义，仿 `resumeVaultPlayback`）进入后播放目标文件；书签失效/文件消失的终态失败按既有语义 prune 记录。
  - `revealWatchLocation` 加 `.localFolder` 路由。
  - `statFileFacts`（首页缩略图/元信息）加 `local://` 分支：`LocalFolderStore.resolve` + `LocalFileSource.metadata`，仿 vault 分支。
- 测试：parse 的 local:// 分支（合法/缺 id/缺路径）；resume 路由的书签失效 prune；stat 分支。

## Out of Scope
- 侧边栏 UI（已在 TASK-local-folder-sidebar）。
- 本地文件夹条目的缩略图缓存策略调整（沿用现有缓存管线）。

## DoD
1. 本地视频播放 → 进度记录出现在首页「继续观看」，副标题为文件夹名。
2. 点击卡片续播到正确进度；reveal 跳转到该文件所在目录并选中。
3. 文件夹书签失效/文件删除后，卡片按既有语义处理（灰显或清理），不崩溃。
4. `make generate && make test` 通过，既有测试零回归。

## 用户验收清单
1. 前置：已添加含视频的本地文件夹。步骤：播放一段视频后关闭播放器，回首页。通过标准：该视频出现在「继续观看」，副标题显示文件夹名。回传：截图。
2. 前置：同上。步骤：点击该卡片。通过标准：进入播放并从上次的进度续播。回传：操作结果口述。
3. 前置：同上。步骤：右键/长按卡片选「在浏览器中显示」（或既有等价入口）。通过标准：跳到该本地文件夹内文件所在位置。回传：操作结果口述。

## 验证命令
- `cd /Users/boyang/code/Cove && make generate && make test`

## 回滚
git 还原改动文件；`local://` 进度记录残留在 store 中无害（parse 不认识即跳过，与现状一致）。
