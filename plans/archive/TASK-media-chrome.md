# TASK: 媒体 chrome 整治（令牌底座 / OSD 根治 + codec chips / 弹层与选中统一 / 播放器状态）

日期：2026-09-05 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：plans/UI-AUDIT-2026-09-05.md §1 T3 + §2.4-2.7（P2/C1/V2/V4/V5/V7）+ §3 BUG-3；令牌图纸 design/DESIGN-TOKENS.md §6.5/§6.6

## 目标复述

阅读器/播放器的悬浮控件成体系整治：pill 底板在浅色内容上不可见、
单页裸字 vs 条带 pill 两套 chrome 语言、白色透明度六档散点、弹层冷灰
入侵暖黑、mpv 原生 OSD 时间码泄漏画面左上、Up Next 裸文本按钮、播放器
加载/缓冲/失败无状态呈现。四个 Step 各自独立交付，每步一个 commit。

## 决策记录（已拍板 2026-09-05）

- `surfaceOverlay` = **#1E1C1C 不透明**（暖黑深化色；否决透明材质——
  深浅不可控正是现状病根）。
- 弹层（倍速/模式/播放列表）**暖黑化**，弃 darkAqua。
- codec chips **仅控制条可见时显示**（非常驻，画面保持干净）。
- 单页阅读器 chrome **统一进 pill 族**（与条带同一种语言）。
- 进度条/音量条保留系统蓝（2026-09-05 前已拍板，不在本卡）。
- 控制条布局不重构成 IINA 居中窄胶囊（另行立项候选）。

## Out of Scope

- 播放器控制条布局重构；进度/音量条颜色。
- 阅读器/播放器之外的界面。

## Step 列表与 DoD

### Step 1 令牌底座 + pill 可见性 + 单页 pill 化
- CoveStyle 新增 `surfaceOverlay`（#1E1C1C）、`textOnMedia1/2/3`
  （白 1.0 / 0.7 / 0.5，收敛现状六档 0.35–1.0）、`readerBackground`
  （替换阅读区 8 处纯黑 NSColor.black 与 `ContinuousReaderView.swift:507`
  的 #141414，值用暖黑系近黑并注释与纯黑的差异）。
- 条带 pill 底板接入 surfaceOverlay（浅色内容上可见）；单页裸字页码 +
  play 钮收进同一 pill 族（与条带同底板同配方）。
- DoD：build 零警告、test 全绿；**前后截图**：条带 pill（前
  plans/UI-AUDIT-2026-09-05/crop-strip-pill.png）、单页 chrome（前
  crop-paged-chrome.png）；令牌文档 §1 三个令牌转 [已拍板]；真机验收。

### Step 2 OSD 根治 + codec chips
- 查明并关闭 mpv 原生 OSD 泄漏（osd-level/osd-bar 或桥接层配置），画面
  左上不再出现橙色时间码。
- 左上角 codec chips：HW / 编码 / 分辨率 / 码率四枚（圆角 small +
  CoveStyle overlay 配方），**仅控制条可见时显示**（跟随
  controlsVisible 生命周期）。
- DoD：播放页左上无泄漏（前 plans/UI-AUDIT-2026-09-05/crop-mpv-osd.png）；
  控制条出现时 chips 内容正确、隐藏时消失；前后截图；真机验收。

### Step 3 弹层暖黑化 + 选中统一 + Up Next
- 倍速/播放模式/播放列表弹层 darkAqua → surfaceOverlay 系（箭头与内容
  同色温）。
- 当前项标记统一为 accent 色 glyph（播放列表金 speaker 同款语义），
  **废除白色 checkmark**。
- Up Next「立即播放/取消」裸文本 → PillButton（primary/secondary）。
- DoD：三张弹层 + Up Next 前后截图（前 crop-speed-popover /
  crop-playlist-popover / crop-mode-popover / crop-upnext.png）；真机验收。

### Step 4 播放器状态呈现
- 加载/缓冲/失败：中央 spinner（复用 StatePlaceholderView .loading 族）
  与失败占位（图标 + 一行 + 重试），替换"仅时间位换字"。
- DoD：假地址/断网实测（15s 超时计入验收成本）；前后截图；真机验收。

## 风险与回滚点

- Step 2 的 mpv OSD 配置与桥接层相互影响需实测（可能不止一处开关）。
- Step 1 底板色值真机可能要微调一轮（#1E1C1C 在亮漫画页上的对比）。
- 每 Step 单 commit 可 revert；Step 间无依赖顺序要求（除 Step 3 依赖
  Step 1 的 surfaceOverlay 令牌）。

## 验证

- 每 Step 前后截图对照 audit 前图；真机验收逐 Step。
- 人工检查点（用户）：pill 在亮页上可读不刺眼、chips 不喧宾夺主、
  弹层与底色色温一致。
