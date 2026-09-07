# TASK: spacing/尺寸令牌族（U1）

日期：2026-09-07 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：plans/UI-AUDIT-2026-09-05.md §2.9 U1（中）+ design/DESIGN-TOKENS.md §3
雏形 + 2026-09-07 全仓散点实证清点（explore agent，结论见下）

## 目标复述

给间距与组件尺寸建立令牌族并全量迁移散点：CoveStyle 新增 spacing 族 +
组件尺寸族，DESIGN-TOKENS.md §3 升格为正式刻度 + 角色表 + 豁免清单。
**全卡承诺零视觉变化：一切迁移都是同值替换（数字 → 同值令牌）。**

## 实态核查结论（2026-09-07 实证）

- 文档侧：DESIGN-TOKENS.md §3 已登记 4pt 刻度（4/8/12/16/20/24/32）+ 6 个
  角色（inset-content 20 / inset-card 16 / gap-compact 8 / row-list 56 /
  badge-tile 40 / row-sidebar 32），全部 [现状] 散点登记。
- 代码侧：CoveStyle.swift 有 6 族令牌（圆角/媒体色/调色板/overlay 按钮/
  动效/符号尺寸/字体），spacing/size 为零；头注释自述只管 "corner radii,
  fonts, and colors" 需同步扩写。
- 散点规模：offset/inset 97 处 + 显式尺寸 30 处 + 行高/卡片/stack 间距约
  20 处，分布 13 个文件（PWC/BVC/SLC/SGC/ASC/PRWC/CRV/SPVC + SharedUI）。
- 网格吻合度：offset 64/97 已在 4pt 网格；离网格 33 处中 31 处集中在
  6/10/14 三值（播放器按钮链 6、进度条两侧 10、popover inset 14，均为
  实测调校的高密度区）。组件尺寸（28/32/40/44/52/56/68）全在网格上但
  超出现刻度上限 32。

## 决策记录（已拍板 2026-09-07）

- 刻度形状：**收编 2pt 子档**，spacing 刻度 = 4/6/8/10/12/14/16/20/24/32
  （离网格率 34% → ~6%，不动实测高密度区的视觉）。
- 令牌结构：**分两族**——spacing 用数值档（`space4…space32`），组件尺寸
  用语义角色名（`rowList = 56`、`controlTransport = 28` 等，与字令牌
  角色制一致：改定义一处全仓生效）。
- 迁移范围：**全量同值迁移**，Step 2（网格内）/ Step 3（收编值 + 例外
  登记）分批。

## 令牌设计要点

- spacing 族：`space4/6/8/10/12/14/16/20/24/32`，调用点直接写档位。
  §3 既有语义角色（inset-content/card、gap-compact）转为文档用法约定
  （"内容边距用 16 档"），不在代码里再叠一层别名。
- 组件尺寸族：角色名按散点实况逐个登记。锚定角色：rowList 56 /
  rowSidebar 32 / badgeTile 40（§3 已有）+ controlTransport 28 /
  capsulePlayer 68 / chipCodec 20 / controlPill 26 / circleNav 44 /
  barBrowserToolbar 52 / sliderVolume 64 / tablePreheatFolder 150 等。
  执行授权：一值一角色、同值同义合并、撞名时新义升格新角色；Review
  Gate 逐个把关命名。
- 豁免清单（§3 登记，不进令牌）：PillButton 内部 padding/最小高（组件
  封装）、popover 高度公式常数（26n+54 / 32n+62，行高部分可引角色值）、
  红绿灯避让 90、微调 2/3/7（单点）、upperRowCenterY/lowerRowCenterY
  （68 高的几何分解，已有局部常量）、volumeReadoutWidth（字体实测值）、
  阴影参数（另立 shadow 配方候选，本卡不动）、窗口/分栏尺寸（窗口配置）、
  像素域常量（thumbnailPixelSize 等 Services 层）。

## Out of Scope

- 任何视觉/行为变化（发现需要变值才能入令牌的地方 → 停下升级，不吸附）。
- shadow 配方令牌化（仅登记候选）；新组件/新界面。
- Services/Frameworks 层常量。

## Step 列表与 DoD

### Step 1 令牌定义
- `Cove/SharedUI/CoveStyle.swift`：新增 spacing 族 + 组件尺寸族（锚定角色），
  头注释扩写；`design/DESIGN-TOKENS.md` §3 升格（刻度表 + 用法约定 +
  组件尺寸角色表 + 豁免清单）。
- 不改任何调用点。
- DoD：make build 零警告、make test 全绿；diff 仅限两文件；用户验收清单
  写"无人工项"（纯定义，无视觉变化）。

### Step 2 网格内迁移
- offset/inset 64 处网格内值 + 网格上尺寸 + stack/grid spacing 同值换令牌。
- DoD：build 零警告、test 全绿；**diff 逐 hunk 只允许"数字 → 同值令牌"**；
  截图抽查三态（播放器胶囊 / 弹层 / 设置页，先动鼠标激活控件再截）；
  用户验收清单按 §5.2 必填。

### Step 3 收编值迁移 + 例外登记
- 6/10/14 共 31 处换令牌；剩余例外（豁免清单）在 §3 逐条登记。
- DoD 同 Step 2。

## 风险与回滚点

- 大 diff 机械替换的正确性：靠"数值零变化"逐 hunk 核对 + Review Gate
  复跑 build/test；任何一处需要变值 → 硬停止上报。
- 同值异义撞名（如 14 既是 popover inset 又是卡片 interitem 间距）：
  spacing 族数值档天然免疫（空间距不问语义）；组件尺寸族撞名必须升格。
- 每 Step 单 commit 可 revert；Step 2/3 顺序执行（同文件防冲突）。

## 验证

- 每 Step：build 零警告 + test 全绿 + diff 数值零变化核对。
- Step 2/3：截图抽查（常宽窗口三界面），真机验收逐 Step；
  提审附用户验收清单（§5.2 必填），Step 以用户验收通过为闭环。
