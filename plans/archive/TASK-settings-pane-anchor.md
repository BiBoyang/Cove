# TASK: Settings pane top-anchoring + main window minimum size

- Status: inline by Planner, landed 2026-09-12 (make build/test green);
  awaiting Owner 真机验收 + commit
- Created: 2026-09-12
- Slug: settings-pane-anchor

## Goal
Fix the settings pane clustering at the bottom-left in fullscreen/tall
windows, and give the main window a minimum size so the pane is fully
visible at the window floor.

## Root cause
`SettingsPaneViewController.loadView`: the scroll view's document view
(`content`) only gets a width constraint; its height is driven by the
form stack. A non-flipped document shorter than the clip view is pinned
to the **bottom** of the visible area — hence the bottom-left cluster
once the window gets tall.

## Changes
1. `/Users/boyang/code/Cove/Cove/Features/Preferences/Views/SettingsPaneViewController.swift`
   — add `height >= scrollView.contentView` to the document view so it
   fills short viewports and the stack's top offset anchors the form.
2. `/Users/boyang/code/Cove/Cove/Application/Coordination/MainWindowController.swift`
   — `window.contentMinSize = 900x700`; raise initial content size
   960x600 -> 1024x720 (initial must not violate the floor). The 700
   height floor = current settings pane fitting height (~660 content +
   title bar), frozen on purpose: future pane growth scrolls inside the
   pane, it never raises this floor (decided 2026-09-12).

## DoD
1. `make build` green, zero new warnings.
2. Fullscreen / tall window: form anchors to the top.
3. At min size (900x700): all four sections (缓存/预热/阅读器/本地仓库)
   visible without scrolling; the window refuses to shrink further.
4. Normal window heights: pixel-identical to before.
5. Scope: exactly the two files above.

## 真机验收清单
- 前置条件：Debug 构建运行，打开 设置（⌘,）。
- 操作步骤：进入全屏（或把窗口拉高）看表单位置；再把窗口缩到最小。
- 通过标准：全屏下表单靠上不再沉底；最小窗口下四个区完整可见、
  窗口无法继续缩小。
- 回传证据：全屏设置页截图 + 最小窗口设置页截图。
