# TASK: UI audit 残余清扫包（vault 缩略图 + 设置按钮语言 + 令牌销项）

日期：2026-09-07 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：plans/UI-AUDIT-2026-09-05.md（BUG-5 / E3 / U2 / U3 / U4）+ 2026-09-07
规划期实态核查（结论见下，逐条有代码证据）

## 目标复述

UI audit 选题池 P1–P7 + 外挂胶囊卡全部落地后的残余清扫：一个功能缺口修复
（vault 缩略图接线）、一处按钮语言统一（设置页 E3）、三条令牌项销项/拍板
登记（U2/U3 已修复核实销项，U4 文档拍板）。除 Step 1 外不动逻辑。

## 实态核查结论（2026-09-07 规划期实证）

- BUG-5 仍开：`LibraryCoordinator.swift` `thumbnailProvider = nil` × 4
  （:246/:285/:385/:422），仅 :326 SMB 路径接 `ThumbnailService`（actor，
  init 吃 readFile 闭包 + cache + sourceID，vault 本地读取可适配）。
- E1/E2/E4/E5 已实质修复：P3 令牌落地（`SettingsPaneViewController.swift`
  全线 sectionHeaderFont/formLabelFont/captionFont）+ 设置迁入侧栏后 E5
  （520×680 不可 resize）前提消失。残余仅 E3：5 个 `.rounded` 标准件按钮
  （:102-119），App 内第三种按钮语言。
- U2 已修：`RoundedFillView` 默认圆角 = `CoveStyle.radiusMedium`
  （`SharedUI/RoundedFillView.swift:38`）。
- U3 已修：§6.8 覆盖层按钮配方令牌落地，`PillButton.secondary` 在用
  （`SharedUI/PillButton.swift:122,134`）。
- U4 仍开但方向已明：`PillButton.primary = controlAccentColor`（:113）与
  已拍板体系自洽（selection 蓝、进度条蓝、金只 glyph 级）→ 文档拍板销项，
  不改代码。

## 决策记录（已拍板 2026-09-07）

- BUG-5 判定为漏接非有意：**修**，vault 缩略图接通 ThumbnailService。
- 设置页按钮：次行动 4 个（立即清理 / 删除 / 更改… / 在 Finder 中打开）
  → PillButton secondary；主行动「添加」→ PillButton **primary 蓝**
  （与 Up Next「立即播放」同款，§6.8 配方）。
- U4 处置：`design/DESIGN-TOKENS.md` §6.8 补记 PillButton.primary 填充 =
  controlAccentColor 系统蓝 [已拍板]，audit 销项，代码不动。

## Out of Scope

- U1 spacing/尺寸令牌族（audit 仅存"中"级跨界面项，另立卡，不混入）。
- vault / 浏览器 / 设置页的其他功能与布局；令牌配方本身的新设计。
- ThumbnailService 内部管线（160px 降采样、CacheKit 双池）不改。

## Step 列表与 DoD

### Step 1 vault 缩略图接通（BUG-5）
- `Cove/Application/Coordination/LibraryCoordinator.swift`：vault 浏览 4 处
  `thumbnailProvider = nil` → 构造 vault 版 `ThumbnailService`（readFile
  走本地 vault 读取，sourceID 用 vault 语义，复用既有 cache）。
- DoD：build 零警告、make test 全绿；vault 网格图片出缩略图、非图片/解码
  失败回占位不崩（前图 plans/UI-AUDIT-2026-09-05/06-browser-gallery.png）；
  真机验收：vault 含图片文件夹出图、滚动流畅、远程 SMB 浏览缩略图不回归。

### Step 2 设置页按钮语言统一（E3）
- `Cove/Features/Preferences/Views/SettingsPaneViewController.swift:102-119`：
  5 个 `.rounded` 标准件 → PillButton（4 个 secondary +「添加」primary），
  点击行为不变。
- DoD：build 零警告、test 全绿；前后截图对照（旧设置窗图 03/18/19 仅作
  语言参考，实施前补拍侧栏设置页现状作前图）；真机验收：五钮点击路径全通
  （添加 / 删除 / 更改… / 立即清理 / 在 Finder 中打开）。

### Step 3 令牌文档销项（U2/U3/U4，纯文档）
- `design/DESIGN-TOKENS.md` §6.8：补记 PillButton.primary = controlAccentColor
  系统蓝 [已拍板 2026-09-07]；U2/U3 复核结论登记销项。
- `plans/UI-AUDIT-2026-09-05.md`：BUG-5 / E3 / U2 / U3 / U4 标记处置结果。
- DoD：纯文档，无代码改动；与代码现状逐字核对（信证据不信记忆）。

## 风险与回滚点

- Step 1 是唯一逻辑改动：vault 混入非图像/大图时，ThumbnailService 的
  undecodable 回退路径必须保住占位行为（实施时先读
  `Services/Media/ThumbnailService.swift` 的 LoadError 路径确认）；本地大图
  decode 耗时为观察项。
- Step 2 纯视觉替换：PillButton 固有高度 26pt 与表单行高的纵向对齐需截图
  核对；长文案（「在 Finder 中打开」）在 capsule 内边距下的宽度变化。
- 每 Step 单 commit 可 revert；三个 Step 互不依赖，顺序可按实施手感调整。

## 验证

- 每 Step 前后截图对照；真机验收逐 Step；提审附「用户验收清单」
  （WORKFLOW.md §5.2 必填字段），Step 以用户验收通过为闭环。
- 人工检查点（用户）：vault 缩略图与远程浏览观感一致、设置页按钮语言统一
  顺眼、PillButton 在表单行里不拥挤。
