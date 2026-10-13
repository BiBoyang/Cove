# TASK-local-folder-store：本地文件夹持久化层

## 目标
为「本地文件夹」功能提供持久化与书签解析层：用户通过 NSOpenPanel 选中的本地目录，以 security-scoped bookmark 存入 UserDefaults，重启后可恢复访问；失效书签可分类、可提示重选。

## 背景与决策
- 方案 A（Owner 已拍板）：本地文件夹作为一等来源，可添加多个、持久化，入口在侧边栏。
- 沙盒硬约束：App 只有 `com.apple.security.files.user-selected.read-write`，任意本地目录的持久访问必须走 security-scoped bookmark（VaultService.resolveRoot 已有同款验证过的模式，照抄语义）。
- 纯显示数据（目录名 + bookmark Data），无凭据，UserDefaults 是合规归宿（AGENTS.md 规矩 5）。
- 本层不含任何 UI 与 coordinator 逻辑，纯 Services/Settings 层。

## In Scope
- 新建 `/Users/boyang/code/Cove/Cove/Services/Settings/LocalFolderStore.swift`：
  - `LocalFolders` 纯值层（仿 `VaultPins` 纪律）：有序条目 `[{id, name, bookmark(base64)}]`，plist round-trip，malformed 行丢弃，去重（同一 resolved 路径不允许重复添加），容量上限 `maxCount = 16`。
  - `LocalFolderStatus: Equatable, Sendable`：`ready` / `bookmarkInvalid`，配纯分类函数（仿 `VaultRootStatus.classify`），bookmark 存在但解析失败 ≠ 无 bookmark。
  - `LocalFolderStore`（@MainActor 或线程安全语义与 VaultPinStore 对齐）：UserDefaults 读写壳 + `resolve(id:) -> (url: URL?, status: LocalFolderStatus)`，解析成功时 `startAccessingSecurityScopedResource()`（进程生命周期内持有，与 vault 同款注释语义），stale 书签记 notice 日志。
  - 条目 `id` 用 UUID 字符串，作为后续 `LocalFileSource(sourceID: "local://<id>")` 的稳定标识——这是进度记录/缓存键的锚点，生成后不变。
- 新建 `/Users/boyang/code/Cove/Tests/CoveTests/LocalFolderStoreTests.swift`（Swift Testing）。

## Out of Scope
- 侧边栏 UI、NSOpenPanel、coordinator 打开流程（后续 TASK）。
-  Bookmark 的「重新选择」交互（只提供 status 分类与 replace 接口）。

## DoD
1. plist round-trip 测试通过（含 nil/空字段、malformed 行丢弃）。
2. 重复添加同一书签被拒绝；超过 maxCount 被拒绝。
3. `classify` 纯函数覆盖三种输入：无 bookmark / 解析成功 / 解析失败。
4. 代码注释与标识符英文；无 AppKit/SnapKit 依赖；零并发警告。
5. `make generate && make test` 通过。

## 验证命令
- `cd /Users/boyang/code/Cove && make generate && make test`

## 回滚
删除两个新文件即可，无既有文件改动。
