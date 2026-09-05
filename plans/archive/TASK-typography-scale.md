# TASK: 排版层级（字号刻度收敛 + 设置窗口标题回归令牌）

日期：2026-09-05 ｜ 直接开干模式（助手实现，用户验收）
上游：plans/UI-AUDIT-2026-09-05.md §1 T5 + §2.4/§2.5/§2.8（E1/E2/E4、P5/P6、C3/C4、S4）；令牌图纸 design/DESIGN-TOKENS.md §2

## 目标复述

CoveStyle 只有 4 档字体（14m/13/11/11sb），实际散点 9/10/12/15pt 各自
ad-hoc：9pt 是全 App 最小字（条带速度档）、12pt 一族无令牌（面包屑、
等宽页码、时间码、表单标签）、15pt 缩放闪现两个文件复制粘贴、设置窗口
分区标题 13pt bold 偏离 11sb 令牌、「远程」tag 10pt。本任务把字号收敛
进刻度表，只动字体与对齐，不动布局结构。

## 决策记录（令牌图纸 §2 转拍板）

- **新增令牌**（CoveStyle，与令牌文档 §2 一致）：
  - `formLabelFont` = 12 regular：表单标签、面包屑/位置文本、辅助文案。
  - `monoDigitFont` = 12 regular 等宽数字（`NSFont.monospacedDigitSystemFont`）：
    时间码、页码。
  - `overlayFlashFont` = 15 semibold：阅读器缩放倍数闪现。
- **废除越刻度**：9pt（`ContinuousReaderView.swift:146` 速度档）与 10pt
  （`ServerListViewController.swift:263`「远程」tag）升入 `captionFont` 11。
- **去重**：缩放闪现 15pt semibold（`PagedReaderView.swift:170` /
  `ContinuousReaderView.swift:172` 复制粘贴）统一改引 `overlayFlashFont`。
- **设置窗口回归令牌**：四个分区标题 13pt bold（`PreferencesWindowController
  .swift:194-197` 附近）改回 `sectionHeaderFont`（11 semibold）；表单标签
  12pt 改引 `formLabelFont`；辅助文案 12pt 主色与 11pt secondary 并存
  （E2）统一为 `captionFont` + secondaryLabelColor；checkbox 标签与相邻
  字段字号对齐（E4）。

## Out of Scope

- 设置窗口结构改造（分组卡片/左栏，P7 另行）。
- 行高/间距随字号变化的联动调整（如有明显错位再单点修，不全局重排）。
- 播放器/阅读器 overlay 白色透明度层级（P6 chrome 任务）。

## 现状摘要

- `CoveStyle` 字体四档（`CoveStyle.swift:20-26`）；12pt 散点见 audit T5。
- 设置窗口 520x712，分区标题肉眼可见偏重（前图 03）。
- 条带阅读器速度档 9pt 视网膜外难读（前图 08/crop-strip-pill）。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. CoveStyle 三档新字体令牌；令牌文档 §2 同步转 [已拍板]。
2. 废除 9/10pt、去重 15pt、面包屑/页码/时间码接入新令牌。
3. 设置窗口：分区标题回归 11sb、表单标签/辅助文案/checkbox 对齐。
4. DoD：
   - `make generate && make build` 零警告；`make test` 全绿；
   - **前后截图对比**：设置窗口（前 03）、条带速度档（前 crop-strip-pill）、
     浏览器面包屑（前 05）——字号变化以肉眼可辨为准；
   - 全仓库 grep 复核：无残留 9/10pt、无 15pt 复制残留、无 12pt 裸写
     （`systemFont(ofSize: 9|10|12|15` 只允许出现在令牌定义与个别有注释
     的例外）；
   - 真机验收前不合并。

## 风险与回滚点

- 纯字号/颜色替换，风险低；注意 11sb 分区标题在设置窗口可能显小——
  这是令牌原设计意图，真机看图后不满意可在验收时回退该单项。
- 回滚：单 commit revert。

## 需要拍板的决策点

1. 缩放闪现：纳入 `overlayFlashFont` 15sb 独立档（推荐，令牌文档 §2 已列）
   还是并入 title 14m（少一档，但闪现与标题语义不同）？
2. Prefs 表单标签：统一 `formLabelFont` 12（推荐，与令牌文档一致）还是
   统一 body 13（更大更齐，但偏离既有刻度设计）？

## 验证

- grep 刻度复核 + 三场景截图对比。
- 人工检查点（用户）：设置窗口整体轻重感、条带速度档可读性。
