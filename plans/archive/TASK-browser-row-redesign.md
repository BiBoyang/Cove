# TASK: 浏览器列表行重做（大圆角缩略图 + 主副双行）

日期：2026-08-23 ｜ 协作模式（主会话规划/Review，另一会话实现）

## 目标复述

把 `BrowserRowCellView` 从"密排文字 + 小缩略图"升级为宽松行：48pt 圆角缩略图 + 主副双行文字，行高约 64pt。纯显示层改造。

## 决策记录（已拍板）

- **缩略图源不动**：继续用 `thumb160`（方形中裁，ThumbnailService 现有管线），仅显示层加大到 48pt 并切圆角（`CoveStyle.radiusSmall`）。不做 16:9 裁剪（要动管线，不值）。
- **行高**：28 → 64pt（缩略图 48 + 上下各 8 留白）。
- **文字结构**：主行 = 文件名（`CoveStyle.titleFont`）；副行 = 元信息（`CoveStyle.captionFont`，secondaryLabelColor）——文件为"大小 · 修改日期"（如 `14.5 MB · 2025/11/18`），目录为"文件夹"。**右侧大小栏删除**（并入副行）。
- **占位图**：现行绿色 photo 图标换单色低饱和（`photo` symbol + tertiaryLabelColor），目录用 `folder.fill`。
- **复用纪律**：cell 复用即取消缩略图任务的现有约定（AGENTS.md 第 12 条例外条款）必须原样保持；行变高后确认复用/取消路径不回归。
- **DateFormatter/ByteCountFormatter 用共享实例**（每行 new 一个 formatter 是列表性能的经典坑）。

## Out of Scope

- 缩略图管线（thumb160 尺寸/裁剪策略）、排序、数据层。
- 列表/网格切换视图（候选 feature，另行立项）。
- 浏览器工具栏（上一步刚改完面包屑）。

## 现状摘要

- `Cove/Features/Browser/Views/BrowserViewController.swift`：`BrowserRowCellView` 现为小缩略图 + 单行文件名 + 右侧大小；行高在 `heightOfRow`；缩略图经 `thumbnailProvider` 注入、cell 内 task 自管理（行复用即取消）。
- VM 的 `visibleItems` 已过滤噪音并排好序，View 只消费；本次不动 VM。
- 设计令牌在 `Cove/SharedUI/CoveStyle.swift`（radiusSmall=6、titleFont、captionFont）。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. 重做 `BrowserRowCellView` 布局：48pt 圆角缩略图（或目录图标）居左，主副双行居中靠左，行高 64。
2. 副行内容：文件="大小 · 日期"（共享 formatter），目录="文件夹"；长文件名尾部截断。
3. 占位图单色化；缩略图 task 的复用取消纪律保持。
4. DoD：
   - `make generate && make build` 零警告（strict concurrency）；
   - `make test` 全绿（不新增测试义务——纯 View 层；若动了 VM 才补）；
   - 提审附 Review Package + 自查说明（四类行：目录/图片/CBZ/视频）。

## 风险与回滚点

- 行变高可能影响 `heightOfRow` 与复用假设——检查 `tableView(_:heightOfRow:)` 与 estimatedHeight 类设置。
- 回滚：单 commit revert。

## 验证

- 主会话收到提审后做无头验收：驱动真实 NAS 连接进目录，截图核布局 + AX 抽查行 frame。
- 人工检查点（用户）：日常浏览手感、缩略图淡入、快速滚动无错位。

## Review 交接

按 WORKFLOW.md §5.2 Review Package：改动文件列表、关键 diff 摘要、自测命令与结果、已知风险。
