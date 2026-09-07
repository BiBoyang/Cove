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

## 3. 间距与尺寸

spacing 刻度 + 组件尺寸角色两族分立：间距走数值档（空间距不问语义，
调用点直接写档位），组件尺寸走语义角色（改定义一处全仓生效）。
[已拍板] 2026-09-07 · TASK-spacing-tokens

### 3.1 spacing 刻度

| 档族 | 值 | 代码令牌 | 说明 | 状态 |
|------|----|---------|------|------|
| 主网格（4pt） | 4 / 8 / 12 / 16 / 20 / 24 / 32 | CoveStyle.space4…space32 | 所有 margin/padding/gap 默认从主网格取值 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| 子档（2pt） | 6 / 10 / 14 | CoveStyle.space6 / space10 / space14 | 实测调校的高密度区专用（播放器按钮链 6、进度条两侧 10、弹层 inset 14）；收编后散点离网格率 34% → ~6%，视觉不动 | [已拍板] 2026-09-07 · TASK-spacing-tokens（收编 2pt 子档） |

### 3.2 用法约定（文档级，不叠代码别名）

原 [现状] 散点登记的语义角色转为用法约定：约定指向档位，代码侧不再
另立语义别名。[已拍板] 2026-09-07 · TASK-spacing-tokens

| 约定 | 指向档位 | 用途 |
|------|---------|------|
| inset-content | 20（space20） | 内容区四边 |
| inset-card | 16（space16） | 卡片/胶囊内边距 |
| gap-compact | 8（space8） | 组件内部元素间距 |

### 3.3 组件尺寸角色（与 CoveStyle 一一对应）

一值一角色、同值同义合并、撞名新义升格（同值异义分立角色，各自独立
演化）。[已拍板] 2026-09-07 · TASK-spacing-tokens

| 角色 | 代码（CoveStyle） | 值 | 用途 | 状态 |
|------|------------------|----|------|------|
| control-pill | controlPill | 26 | 胶囊（pill）控件标准高；PillButton 最小高实现该标准（组件封装豁免，见 §3.4） | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| row-list | rowList | 56 | 浏览器行高（40 瓷贴 + 上下各 8 呼吸位） | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| row-sidebar | rowSidebar | 32 | 侧栏行高 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| row-sidebar-group | rowSidebarGroup | 20 | 侧栏组标题行高；与 chip-codec 同值异义，分立角色 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| badge-tile | badgeTile | 40（圆角 small） | 行内图标瓷贴 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| bar-browser-toolbar | barBrowserToolbar | 52 | 浏览器内容区上方工具条高 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| capsule-player | capsulePlayer | 68 | 播放器控制胶囊高（上排控件链 + 下排进度条） | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| control-transport | controlTransport | 28 | 水平控件条（播放胶囊/浏览器工具条）上的 28pt 方形操作钮 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| chip-codec | chipCodec | 20 | codec 信息瓷贴高（HW/编码/分辨率/码率） | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| slider-volume | sliderVolume | 64 | 播放器音量滑条宽 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| pill-reader-chrome | pillReaderChrome | 32 | 阅读器 chrome pill 高（scrubber/页码/续读提示三处同高）；与 row-sidebar 同值异义，分立角色 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| control-pill-accessory | controlPillAccessory | 24 | 阅读器 pill 内嵌附件钮（自动滚动/自动翻页） | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| circle-nav | circleNav | 44 | 阅读器翻页导航圆钮（上一页/下一页） | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| slider-scrubber | sliderScrubber | 220 | 条带阅读器 scrubber 滑条宽（scrubber pill 内） | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| field-numeric | fieldNumeric | 64 | 设置页数值输入框宽（容量/TTL/限速三处共用）；与 slider-volume 同值异义，分立角色 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| table-preheat-folder | tablePreheatFolder | 150 | 设置页预热文件夹表高 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| row-playlist | rowPlaylist | 32 | 播放器播放队列弹层行高（32n+62 公式的行高项引用本角色）；与 row-sidebar 同值异义，分立角色 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| circle-mode | circleMode | 32 | 阅读器模式切换圆钮（单页/条带），circle-nav 44 的同族小号；与 row-sidebar 同值异义，分立角色 | [已拍板] 2026-09-07 · TASK-spacing-tokens |
| control-bar-accessory | controlBarAccessory | 20 | 水平控件条上的迷你附件钮（浏览器工具条下载取消钮），刻意小于 control-pill 26 标准；与 chip-codec 同值异义，分立角色 | [已拍板] 2026-09-07 · TASK-spacing-tokens |

### 3.4 豁免清单（登记，不进令牌）

[已拍板] 2026-09-07 · TASK-spacing-tokens（逐条登记，括号内为实证位置）

- PillButton 内部 padding/最小高 26：组件封装（SharedUI/PillButton.swift:70）。
  最小高即 control-pill 标准的实现，不反向引用令牌。
- 弹层高度公式常数：倍速/模式弹层 n×control-pill+54、播放队列弹层
  n×row-playlist+62（PlayerWindowController.swift:1146 / :1256）。
  公式的常数项（+54/+62）与 n 倍结构豁免；行高项已引角色值——26 =
  control-pill（选项行与胶囊控件同高同族），32 = row-playlist（Step 3 定夺：
  与 row-sidebar 同值异义，另立角色）。
- 红绿灯避让：播放器胶囊左右安全距 90（PlayerWindowController.swift:296-297）；
  codec chips 顶部下沉 40（同文件 :181，让开红绿灯安全区，刻度无 40 档）。
- 微调 2/3/7：单点调校（如 ContinuousReaderView.swift:198、
  PlayerWindowController.swift:294 / :1035、BrowserViewController.swift:628
  选中圆角矩形的 dy:2——同处 dx:12 已收编 space12）。
- 速度钮宽 38（PlayerWindowController.swift:347）：内容驱动实测值
  （mono-digit 最宽档 "1.25x"），与 volumeReadoutWidth 同类，不立角色。
- glyph 承载框（符号档 §4.5 外的不可见布局盒，随宿主行高/胶囊调校，不立
  角色）：播放胶囊音量图标框 16（PlayerWindowController.swift:317）、侧栏
  组加号钮 16（ServerListViewController.swift:235）、侧栏行图标框 18
  （ServerListViewController.swift:299）。播放队列行 glyph 框 14 落在刻度
  上，走 space14 数值档（PlayerWindowController.swift:1309），不在此列。
- StatePlaceholderView 组件封装内部几何（同 PillButton 一类）：
  占位图标框 48 / spinner 框 32 / 内容宽上限 360 / 行动按钮前间距 18
  （StatePlaceholderView.swift:66 / :73-81）。
- upperRowCenterY / lowerRowCenterY（-9 / 13）：68 胶囊高的几何分解，
  已有局部常量（PlayerWindowController.swift:515-516）。
- volumeReadoutWidth：音量百分比读数宽度，字体实测值
  （PlayerWindowController.swift:506）。
- 阴影参数（shadowOffset 0/-1、0/-2 等）：另立 shadow 配方候选，本卡不动。
- 窗口/分栏尺寸：窗口 contentRect / minSize / sheet 尺寸等窗口配置。
- 像素域常量：thumbnailPixelSize 等 Services 层常量。

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
| fast | 0.15s ease-out | 缩略图淡入、share 卡片 hover/选中 fill 过渡、占位淡入、缩放倍数闪现（淡入） | [已拍板] 2026-09-05 · TASK-restrained-motion |
| medium | 0.25s ease-out | 媒体 chrome 显隐（播放器胶囊/codec chips/Up Next、阅读器 resume hint）、缩放倍数闪现淡出 | [已拍板] 2026-09-05 · TASK-restrained-motion；调用点归位 TASK-media-chrome |

原则：只为状态反馈服务（出现/消失/hover/选中），不做装饰性动效；一律
ease-out（起速快、缓收尾，反馈跟手不漂浮）。列表行选中不做过渡（Finder
亦无）；弹层/NSPopover 用系统自带动画。媒体 chrome 显隐 fade 已随
TASK-media-chrome 归位两档令牌（原 0.1/0.15/0.2/0.3s 散点）。

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

PillButton.primary 填充 = controlAccentColor 系统蓝（hover 提亮 15% 白）：
主行动按钮沿用系统语义色，与 selection / 进度条蓝同族，accent 金仍只做
glyph 级点缀。[已拍板] 2026-09-07 · TASK-ui-audit-sweep（audit U4 销项）

### 6.5 播放器 chrome
[提议，借 IINA OSC 01/02 + SenPlayer 控制条 11]
- 悬浮胶囊（圆角 large，底板 surface-overlay），底部居中，空闲自动隐藏。
  [已拍板] 2026-09-05 · TASK-media-chrome（胶囊与 Up Next pill 均已换
  surfaceOverlay 不透明底板）
- 控制族：播放三键 + 音量 + 进度条 + 时间码（mono-digit）。
- 弹层（倍速/模式/播放列表）底板 surfaceOverlay，与 darkAqua 箭头同色温；
  Up Next 行动按钮 = PillButton primary/secondary。[已拍板] 2026-09-05 ·
  TASK-media-chrome
- 当前播放项标记：glyph（▶/speaker）+ accent 色；其余弹层当前项统一为
  accent 色 glyph，**废除白色 checkmark**（收编两套现状）。[已拍板]
  2026-09-05 · 落地 TASK-media-chrome。
- codec 信息 chips（HW/编码/分辨率/码率）：**采纳** [已拍板] 2026-09-05——
  画面左上角瓷贴显示（surfaceOverlay 底、圆角 small），**仅控制条可见时
  显示**（跟随 controlsVisible 生命周期）；mpv 原生 OSD 已关（osd-level=0，
  audit BUG-3）。落地：TASK-media-chrome。
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
