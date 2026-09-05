# TASK: 修复 CBZ 行 badge 空白（SF Symbols 名打错）

日期：2026-09-05 ｜ 直接开干模式（助手实现，用户验收）

## 目标复述

文件浏览器里 CBZ 行的类型 badge 恒为空白方块。根因：占位符号名写成了
`books.closed.fill`（复数），该名字在 SF Symbols 里不存在，
`NSImage(systemSymbolName:)` 返回 nil。改为单数 `book.closed.fill`。
审计证据：plans/UI-AUDIT-2026-09-05.md BUG-1 + crop-cbz-badge.png。

## 决策记录（已拍板）

- 一行修复：`Cove/Features/Browser/Views/BrowserViewController.swift:572`
  `books.closed.fill` → `book.closed.fill`。
- 已在 macOS 27.0 实机验证：`book.closed.fill` / `book.closed` 可解析，
  `books.closed(.fill)` 返回 nil。同文件其余符号名（folder.fill / film.fill /
  photo / doc.richtext.fill / doc.text.fill / doc.fill）均实测 OK，不动。
- 不引入新设计令牌（纯 bug 修复，无新设计决策）。

## Out of Scope

- vault 缩略图不加载（BUG-5，待用户确认意图后另行立项）。
- SF Symbols 权重/尺寸一致性（audit P4 主题任务）。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. 改 `BrowserViewController.swift:572` 的符号名。
2. DoD：
   - `make generate && make build` 零警告；
   - `make test` 全绿（纯字符串常量，不新增测试义务）；
   - **前后截图对比**：vault 根目录 CBZ 行 badge（前：空白方块
     plans/UI-AUDIT-2026-09-05/crop-cbz-badge.png；后：`book.closed.fill`
     图标渲染），截图附提交说明；
   - 真机验收（用户肉眼确认 CBZ 行图标）前不合并。

## 风险与回滚点

- 无已知风险（字符串常量替换）。回滚：单 commit revert。

## 验证

- 助手驱动 Debug 构建：开 App → 本地仓库根目录 → 截 CBZ 行对比图。
- 人工检查点（用户）：肉眼确认 badge 图标与其他文件类型视觉权重协调。
