# TASK: Sidebar bottom bar (vault + settings pinned) + single-click activation

- Status: Approved at Review Gate v2 (2026-09-12); code complete,
  awaiting Owner 真机验收 + commit
- Created: 2026-09-12
- Slug: sidebar-bottom-bar
- Depends on: TASK-settings-pane-anchor (inline, same batch)
- Feeds: TASK-vault-pins (pin rows slot into this bottom bar)

## Goal
Layout B-3 (decided 2026-09-12): the server list scrolls solo; 本地仓库
and 设置 leave the table and become a bottom bar pinned to the sidebar
bottom — immovable by server count, window resize, or fullscreen.
Activation goes single-click for the mouse; keyboard arrows select only,
Return activates.

## Current state
- `ServerListViewModel` (lines 9-12): `rowCount = servers.count + 4`;
  vault header/vault/settings rows are table rows, settings is last —
  every server pushes it down.
- `ServerListViewController`: the settings row already navigates on
  selection (System-Settings style, see `tableViewSelectionDidChange`);
  server and vault rows activate on double-click only.
- `LibraryCoordinator.openSettings()` selects the settings table row
  (`selectSettingsRow()`) then shows the pane.
- Sidebar root is an `NSVisualEffectView` (.sidebar material); scroll
  view is edge-to-edge inside it.

## Changes
1. `ServerListViewModel`: table = 服务器 group only —
   `rowCount = servers.count + 1`, group row 0; delete the vault /
   settings row math (`vaultHeaderRow`, `vaultRow`, `settingsRow`,
   `isVaultRow`, `isSettingsRow`). Add a `SidebarDestination` enum
   (`none`, `vault`, `settings`) + `activeDestination` state for the
   bottom bar highlight.
2. New view `SidebarBottomBar` in `Features/Servers/Views/` (feature-
   private, AGENTS.md rule 14): two rows visually matching today's
   cells (32pt rows, rounded-capsule highlight, `externaldrive.fill`
   tinted `CoveStyle.accentGold` for 本地仓库, `gearshape` for 设置),
   a 1pt top separator, fixed height. Reuse existing CoveStyle tokens;
   register any genuinely new value in `design/DESIGN-TOKENS.md`.
3. `ServerListViewController`: scroll view bottom anchors to the bar's
   top; bar buttons fire `onOpenVault` / `onOpenSettings` and render
   `activeDestination`. Table `selectionDidChange` connects a server
   only for mouse-originated selection changes (keyboard arrows select
   only); Return activates the selected server (minimal NSTableView
   subclass with an `onReturn` closure). Double-click keeps working.
4. `LibraryCoordinator`: `openSettings()` no longer selects a table
   row — it pushes `activeDestination = .settings` and shows the pane;
   every destination transition syncs the bar (connect → `.none`,
   openVault → `.vault`, showSettings → `.settings`). Connecting must
   be idempotent: clicking the already-connected server just re-shows
   the share grid (verify the existing guard; add one if missing).
5. Tests (`Tests/CoveTests/ViewModelTests.swift`): update the row-math
   cases (`vaultRows()` and friends) to the servers-only table; cover
   `activeDestination` transitions and any pure activation-decision
   function.

## DoD
1. `make build` and `make test` green; zero new warnings
   (SWIFT_STRICT_CONCURRENCY=complete, AGENTS.md rule 10).
2. 15+ servers: the bar never moves; the table scrolls independently.
3. Mouse single click: connects a server / opens vault / opens
   settings. Arrow keys: selection only. Return: activates.
4. ⌘, still opens settings; the bar highlight tracks the visible
   destination.
5. UI text in Chinese, code/comments in English (rule 6); no SwiftUI
   (rule 4); SnapKit only in Views (rule 11); ViewModel stays free of
   AppKit types (rule 16).

## 真机验收清单（用户）
- 前置条件：Debug 构建运行；NAS 可达。
- 操作步骤：
  1. 连续添加十余台服务器（可用重复/假配置）把侧栏撑出滚动条；
  2. 上下滚动服务器列表，看底部「本地仓库 / 设置」是否纹丝不动；
  3. 单击一台服务器 → 应直接连接进 share 网格；单击「本地仓库」→
     进本地仓库；单击「设置」→ 进设置页；
  4. 用方向键上下扫过服务器列表 → 只选中不连接；按回车 → 连接；
  5. ⌘, → 进设置页，且底栏「设置」行高亮；点别的目的地后高亮
     应跟着走；
  6. 全屏 / 拖窗口大小 → 底栏始终钉在侧栏底部。
- 通过标准：以上全部符合；底栏视觉（行高/胶囊/图标 tint）与
  改动前的行样式一致。
- 回传证据：长列表 + 底栏截图一张；设置页高亮态截图一张。
