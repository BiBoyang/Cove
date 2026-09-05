# Cove 设计令牌（平台无关）

Cove 跨平台 UI 一致性的图纸：所有色值/字号/间距/圆角/动效/组件配方的**设计决策**
都登记在这里，按角色语义组织，不含平台代码。Mac 端 `Cove/SharedUI/CoveStyle.swift`
是代码侧单一事实来源；本文档是其平台无关投影。两者冲突时以本文档为准修代码。
未来 iPad 端（UIKit 手写）重写时，按本文档的角色映射到 UIColor/UIFont 即可。

每条决策的状态：[现状] 已在线上；[提议] 已给建议待拍板；[已拍板] 记拍板日期与
落地任务单号（plans/TASK-*.md）。

## 1. 色

| 角色 | 值 | 说明 | 状态 |
|------|----|------|------|
| surface-base | #2C2929 | 内容区底色（暖黑），列表/网格背后 | [现状] libraryBackground |
| surface-raised | #333131 | 抬升面：工具条、卡片 hover 填充 | [现状] libraryToolbarBackground |
| surface-overlay | #1E1C1C 不透明 | 媒体区 chrome 底板（阅读器 pill、播放器胶囊、codec chips、弹层内容底）。不透明暖黑：浅色内容上底板必须可见且深浅可控（透明材质正是现状病根，audit C1） | [已拍板] 2026-09-05 · TASK-media-chrome |
| accent | #E0C020 | 金色点缀：激活标记、品牌点缀。**glyph 级使用，不做大面积填充** | [现状] accentGold |
| selection | 系统蓝（macOS selectedContentBackgroundColor） | 选中填充。SenPlayer/IINA 均用系统色、品牌色只做点缀——与用户预期一致。维持系统蓝，金色不接管选中填充 | [已拍板] 2026-09-05 |
| text-primary | labelColor | 主文字 | [现状] |
| text-secondary | secondaryLabelColor | 副文字/元信息 | [现状] |
| text-tertiary | tertiaryLabelColor | 占位符、单色图标 | [现状] |
| text-on-media-1/2/3 | 白 1.0 / 0.7 / 0.5 | 媒体画面上的 overlay 文字三档，收敛原六档散点（0.35–1.0） | [已拍板] 2026-09-05 · TASK-media-chrome |
| reader-bg | #1A1818 | 阅读区画面背景（单页/条带/PDF），暖黑近黑、比 surface-overlay 深一级；替代纯黑 8 处 + #141414 slot 底 | [已拍板] 2026-09-05 · TASK-media-chrome |
| danger | systemRed | 破坏性操作按钮、错误提示 | [提议]（补 alert hasDestructiveAction 后生效） |
| card-border | labelColor 8% alpha | 卡片细描边，让圆角形状在深色底上可读 | [已拍板] 2026-09-05 · TASK-grid-card-details（share 卡片已启用） |
| hover-fill | quaternaryLabelColor | 内容表面 hover 反馈（卡片/网格项）；系统语义灰，与系统蓝选中同族 | [已拍板] 2026-09-05 · TASK-grid-card-details |

## 2. 字（刻度表）

| 角色 | 规格 | 用途 | 状态 |
|------|------|------|------|
| title | 14 medium | 行/卡片标题 | [现状] titleFont |
| body | 13 regular | 列表正文 | [现状] bodyFont |
| caption | 11 regular | 元信息（日期/大小） | [现状] captionFont |
| section-header | 11 semibold | 分区标题（侧栏组、设置分区） | [现状] sectionHeaderFont；设置窗口 13bold 偏离待回归（audit E1） |
| form-label | 12 regular | 表单标签、面包屑、位置文本 | [已拍板] 2026-09-05 · TASK-typography-scale |
| mono-digit | 12 medium 等宽数字 | 时间码、页码、倍速档 | [已拍板] 2026-09-05 · TASK-typography-scale（medium 与线上视觉一致） |
| overlay-flash | 15 semibold | 阅读器缩放倍数闪现（两文件复制已去重） | [已拍板] 2026-09-05 · TASK-typography-scale |
| —（已废除） | 9pt / 10pt | 条带速度档→mono-digit 12、「远程」tag→caption 11 | [已拍板] 2026-09-05 · TASK-typography-scale |

## 3. 间距与尺寸（4pt 网格）

刻度：4 / 8 / 12 / 16 / 20 / 24 / 32。所有 margin/padding 从刻度取值。

| 角色 | 值 | 用途 | 状态 |
|------|----|------|------|
| inset-content | 20 | 内容区四边 | [现状]（散点登记） |
| inset-card | 16 | 卡片/胶囊内边距 | [现状]（散点登记） |
| gap-compact | 8 | 组件内部元素间距 | [现状]（散点登记） |
| row-list | 56 | 浏览器行高 | [现状] |
| badge-tile | 40（圆角 small） | 行内图标瓷贴 | [现状] |
| row-sidebar | 32 | 侧栏行高 | [现状]（散点登记） |

## 4. 圆角

| 角色 | 值 | 用途 | 状态 |
|------|----|------|------|
| small | 6 | badge、chips、瓷贴 | [现状] radiusSmall |
| medium | 12 | 卡片、网格项 | [现状] radiusMedium |
| large | 14 | 浮层、胶囊控制条 | [现状] radiusLarge |
| row-selection | 8 | 列表行选中高亮圆角（散点正名升格） | [已拍板] 2026-09-05 · TASK-grid-card-details |

## 4.5 符号（SF Symbols）

| 角色 | 值 | 用途 | 状态 |
|------|----|------|------|
| symbol-small | 12 | 小控件、tag、紧凑按钮 | [已拍板] 2026-09-05 · TASK-symbol-consistency |
| symbol-medium | 14 | 工具栏与 transport 控制族 | [已拍板] 2026-09-05 · TASK-symbol-consistency |
| symbol-large | 18 | 列表行 badge | [已拍板] 2026-09-05 · TASK-symbol-consistency |
| symbol-hero | 36 | 卡片、空态占位 | [已拍板] 2026-09-05 · TASK-symbol-consistency（占位 light、卡片 regular，两档并存） |

**权重约定**：工具控件一律 semibold；内容 glyph（行 badge、侧栏行图标）
用 regular/medium。语义图标跟随状态（如音量图标按 0/1-33/34-66/67-100
分四档，2026-09-05 · TASK-symbol-consistency）。

## 5. 动效（克制）

| 角色 | 值 | 用途 | 状态 |
|------|----|------|------|
| fast | 0.15s ease-out | 缩略图淡入、share 卡片 hover/选中 fill 过渡、占位淡入 | [已拍板] 2026-09-05 · TASK-restrained-motion |
| medium | 0.25s ease-out | 面板/弹层出现（预留，暂无调用点） | [已拍板] 2026-09-05 · TASK-restrained-motion（预留） |

原则：只为状态反馈服务（出现/消失/hover/选中），不做装饰性动效；一律
ease-out（起速快、缓收尾，反馈跟手不漂浮）。列表行选中不做过渡（Finder
亦无）；弹层/NSPopover 用系统自带动画；媒体 chrome 显隐 fade 属 P6 范畴
（现状 0.2/0.3s 散点，届时归位）。

## 6. 组件配方（跨平台要同一效果；平台实现细节另注）

### 6.1 空态（Empty State）
[已拍板] 2026-09-05 · TASK-empty-loading-states（借 SenPlayer 主界面/空 share）
居中插画或大图标（text-tertiary）+ 标题（title）+ 一行说明（caption，
text-secondary）+ 必要时主行动按钮。**禁止裸底零提示**（Cove 现状：空文件夹
整面无内容）。Mac 端插画可用 SF Symbols 大号单色代替，够用即可。

### 6.2 加载态（Loading）
[已拍板] 2026-09-05 · TASK-empty-loading-states
spinner（平台原生指示器）+ 一行说明（caption）。**禁止静态图标冒充加载中**
（Cove 现状：share 网格加载只有静态图标 + 文字，audit G1）。目录切换先出
加载态，不留旧内容残留。

### 6.3 列表行（List Row）
[提议，借 SenPlayer 浏览行 03/06/09]
瓷贴（badge-tile，secondarySystemFill 底）+ 主行 title + 副行 caption
（text-secondary）。缩略图行 = 圆角（small）缩略图 + 可选角标（如「NEW」）。
长名尾部截断。

### 6.4 卡片（Card）
[已拍板] 2026-09-05 · TASK-grid-card-details（借 SenPlayer 服务器卡片 02）
rest 态带 card-border 描边；hover = hover-fill 填充 + 描边；选中 =
selection 填充。卡片可承载元信息（类型标签 + 相对时间）；share 卡片是否
升级为信息卡片 [待定拍板]（后续任务立项时再定）。

### 6.8 覆盖层按钮配方（Overlay Buttons）
[已拍板] 2026-09-05 · TASK-grid-card-details（供 P6 媒体 chrome 复用）
浮于媒体/深色表面上的按钮统一配方：填充 = 黑 0.35（rest）/ 黑 0.55（hover），
描边 = 白 0.18 发丝线。Mac 端实现：`CoveStyle.overlayButtonFill /
overlayButtonFillHover / overlayButtonBorder`，PillButton.secondary 与
FrostedCircleButton 共用。

### 6.5 播放器 chrome
[提议，借 IINA OSC 01/02 + SenPlayer 控制条 11]
- 悬浮胶囊（圆角 large，底板 surface-overlay），底部居中，空闲自动隐藏。
- 控制族：播放三键 + 音量 + 进度条 + 时间码（mono-digit）。
- 当前播放项标记：glyph（▶/speaker）+ accent 色；其余弹层当前项统一为
  accent 色 glyph，**废除白色 checkmark**（收编两套现状）。[已拍板] 2026-09-05。
- codec 信息 chips（HW/编码/分辨率/码率）：**采纳** [已拍板] 2026-09-05——
  播放时画面左上角瓷贴显示，在 chrome 任务（P6）落地，同时根治 mpv 原生
  OSD 泄漏（audit BUG-3）。
- 进度条/音量条：**保留系统蓝** [已拍板] 2026-09-05（IINA/SenPlayer 均蓝，
  播放器语境属主流）；轨道/填充精细化在 P6 做。

### 6.6 阅读器 chrome
- pill 底板必须有可见底色（surface-overlay），禁止在浅色内容上裸浮
  （audit C1）。[已拍板] 2026-09-05 · TASK-media-chrome
- 关闭钮避开窗口红绿灯安全区（audit BUG-2）。
- 单页与条带统一 chrome 语言（同一 pill 族）。[已拍板] 2026-09-05 ·
  TASK-media-chrome（单页页码+play 钮收进同底板同配方的 chrome pill）

### 6.7 设置窗口
结构 [已拍板] 2026-09-05：维持单窗口，分组卡片分区（不引入 tab/左栏）；
分区标题回归 section-header（11 semibold，audit E1）。

## 7. 变更纪律

- 每个 UI 任务交付时：新决策入本文档（状态→[已拍板] + 任务单号），代码侧
  CoveStyle 同步增量；不改文档直接改代码视为越权。
- Mac 端 AppKit 特有实现（HUD 材质、vibrancy、NSTableRowView 选中绘制等）
  记入对应任务的 TASK 卡，不进本文档。
