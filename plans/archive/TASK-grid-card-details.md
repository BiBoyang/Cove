# TASK: 缩略图/网格细节（卡片描边 + hover 令牌化 + 选中圆角正名 + 右键选中联动）

日期：2026-09-05 ｜ 直接开干模式（助手实现，用户验收）
上游：plans/UI-AUDIT-2026-09-05.md §2.2/§2.3/§3（G3/G4、B7、U2/U3、BUG-4）；令牌图纸 design/DESIGN-TOKENS.md §1/§4/§6.4

## 目标复述

网格与列表的"静态边界"和"交互反馈"收口：share 卡片 rest 态无边框
（`cardBorderColor` 全 App 零调用）、hover 配方散落各处、浏览器选中行圆角
8 落在令牌网格外、右键点哪行不选哪行（视觉焦点分裂）。本任务只做网格/
列表层的细节，不动缩略图管线（vault 缩略图是红线设计，已销案）。

## 决策记录（待拍板项见文末）

- **share 卡片启用描边**：rest 态带 `cardBorderColor`（labelColor 8%）细
  描边；hover = 现有填充浮起（描边保留）；选中 = 系统蓝填充（2026-09-05
  已拍板，不动）。落在 `ShareCardItem`/`RoundedFillView`。
- **hover 配方下沉令牌**：`CoveStyle` 新增 hover 填充令牌，`ShareCardItem`
  与 SharedUI 按钮族（PillButton/FrostedCircleButton 的重复硬编码配方，
  audit U3）统一引用；`RoundedFillView` 默认圆角 8 改回令牌网格内
  （radiusMedium 12，audit U2——调用方本就全覆盖，纯防呆）。
- **浏览器选中行圆角正名**：`RoundedSelectionRowView` 的散点 8 收敛为正式
  令牌（数值见拍板点 1）。
- **BUG-4 右键选中联动**：右键弹菜单前，若被点行未选中则先把选中移到该行
  （Finder 行为），再构建菜单。逻辑抽静态函数
  `selectionOnRightClick(clickedRow:current:count:)` 以便行为测试。

## Out of Scope

- 缩略图管线（thumb160 尺寸/裁剪）、share 卡片升级为信息卡片（类型标签
  + 相对时间，audit §6.4 待定项，另行立项）。
- 侧栏选中胶囊样式（系统 sourceList 原生，不动）。
- BUG-5 vault 缩略图（红线设计，已销案）。

## 现状摘要

- `CoveStyle.cardBorderColor`（`CoveStyle.swift:32`）定义后零调用；
  `RoundedFillView` 默认圆角 8 在网格（6/12/14）外。
- `ShareCardItem.updateHighlight()`：selected=selectedContentBackgroundColor、
  hover=quaternaryLabelColor、rest=clear（`ShareGridViewController.swift:205-213`）。
- `RoundedSelectionRowView.drawSelection`：圆角 8 硬编码
  （`BrowserViewController.swift:588` 附近）。
- 右键菜单：`menuNeedsUpdate` 只按 clickedRow 构建菜单，不动选中
  （audit BUG-4，证据 crop-context-menu.png）。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. `CoveStyle`：新增 hover 填充令牌 + 选中行圆角令牌（数值按拍板）；
   `RoundedFillView` 默认圆角归网格。
2. share 卡片：rest 描边 + hover/选中走令牌。
3. 浏览器：选中行圆角走令牌；`menuNeedsUpdate` 前接入右键选中联动。
4. SharedUI 按钮族 hover 配方统一引用新令牌。
5. DoD：
   - `make generate && make build` 零警告；`make test` 全绿；
   - **前后截图对比**：share 网格 rest（前 25）/ hover（前 25b）、浏览器
     右键行（前 crop-context-menu：右键行只出描边不移动选中 → 后：右键行
     直接成为蓝填充选中行）；
   - 行为测试：`selectionOnRightClick` 的边界（已选行不重复选、无效行不动、
     空选择直选）；
   - 令牌文档 §4 圆角、§6.4 卡片配方转 [已拍板]（随本卡），hover 色入 §1；
   - 真机验收前不合并。

## 风险与回滚点

- 纯展示层；`RoundedFillView` 默认值变化对现有调用方无影响（全覆盖）。
- 右键选中联动改变列表交互手感，需真机过一遍"右键不跳选中"的旧习惯
  （macOS Finder 标准即联动，预期无争议）。
- 回滚：单 commit revert。

## 需要拍板的决策点

1. 选中行圆角：**正名保留 8**（推荐：现视觉不变，令牌 `radiusRowSelection=8`
   升格为第四档）还是**收敛到 small=6**（网格更纯，视觉略变）？
2. hover 填充色：**登记现状 quaternaryLabelColor 为令牌**（推荐：系统语义
   色自适应外观，选中既然已拍板系统蓝，hover 同族一致）还是**自定义暖黑系
   hover**（更贴暖黑，但多一个自定义色值要长期维护）？

## 验证

- 现有素材即复现环境：share 网格（真 NAS 或假服务器失败态外的任意 share）、
  vault 列表行（右键场景）。
- 人工检查点（用户）：卡片描边在暖黑底上的分寸感、右键联动手感。
