# TASK: SF Symbols 一致性（尺寸/权重令牌 + 音量图标随音量变化）

日期：2026-09-05 ｜ 直接开干模式（助手实现，用户验收）
上游：plans/UI-AUDIT-2026-09-05.md §2.3 B8、§2.7 V3/V8、§1 T3；令牌图纸 design/DESIGN-TOKENS.md §4（选题池 P4）

## 目标复述

SF Symbols 的尺寸与权重全部散点硬编码：全 App 现有 10/11/12/13/14/15/16/18/36pt
九个尺寸、regular/medium/semibold/light 四种权重各自为政；音量图标恒
`speaker.wave.2.fill` 不随音量变化。本任务建立符号令牌与权重约定，并让
音量图标跟随音量档位。

## 决策记录（待拍板见文末）

- **尺寸令牌**（`CoveStyle`，纯正名，尽量不动现视觉）：
  `symbolSmall = 12`（tag/小控件）、`symbolMedium = 14`（工具栏/控制族）、
  `symbolLarge = 18`（列表行 badge）、`symbolHero = 36`（卡片/占位）。
  现有 11pt（侧栏 + 钮、播放器一处）升入 symbolSmall。
- **权重约定文档化**（不改视觉）：工具控件 = semibold（PillButton/
  FrostedCircleButton 现状即此）、内容 glyph = regular/medium（行 badge、
  侧栏行现状即此）——写入令牌文档 §4 后新增小节，杜绝将来再散。
- **音量图标随音量**：`speaker.slash.fill`（0）/ `speaker.wave.1.fill`
  （1–33）/ `speaker.wave.2.fill`（34–66）/ `speaker.wave.3.fill`（67–100），
  系统惯例分档；逻辑抽静态函数 `volumeSymbolName(for:)` 补行为测试。
- 行 badge 18 regular 与 share 卡片/占位 36 正名入令牌（数值不动）。

## Out of Scope

- 播放器/阅读器 chrome 结构与 pill 底板（P6 任务）。
- 图标内容本身的换形（如播放列表当前行 speaker 图标样式）。
- 阅读器剩余 chrome 符号统一（归 P6 一并处理）。

## 现状摘要

- 播放器：音量 14 medium（`PlayerWindowController.swift:199` 附近）、
  transport 15 semibold（:337/:531）、其余 11/12/14 semibold 混用。
- 浏览器行 badge 18 regular（`BrowserViewController.swift:572`）；侧栏行
  14 regular、+ 钮 11 medium；share 卡片 36 regular；占位 36 light。
- 令牌文档 §4 选题池已把本任务列为 P4。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. CoveStyle 四档尺寸令牌 + 权重约定注释；令牌文档新增符号小节。
2. 全量替换散点（11→12、transport 15 处理按拍板、其余正名）。
3. 音量图标分档 + `volumeSymbolName(for:)` 静态函数。
4. DoD：
   - `make generate && make build` 零警告；`make test` 全绿；
   - **前后截图对比**：播放器音量图标在 0 / 50 / 100 三档的图标形态
     （前：恒 wave.2，见 crop-controls-capsule）；播放器控制族符号区；
   - grep 复核：`pointSize: (10|11|12|13|14|15|16|18)` 裸写仅余有注释例外；
   - `volumeSymbolName` 行为测试（0/1/33/34/66/67/100 边界）；
   - 令牌文档符号小节 [已拍板]（随本卡）；
   - 真机验收前不合并。

## 风险与回滚点

- 纯展示层；transport 15→14（若采纳）对播放键视觉有 1pt 变化，真机看图
  不满意可回退该单项。
- 回滚：单 commit revert。

## 需要拍板的决策点

1. 播放器 transport（播放/上一首/下一首，现 15sb）：收敛进 symbolMedium 14
   （推荐：与同排按钮统一，1pt 差异肉眼难辨）还是保留 15 作 transport
   特例档？
2. hero 36 的 weight：占位 light 与卡片 regular 保持两档（推荐：语义不同，
   占位求轻、卡片求形）还是统一 light？

## 验证

- 音量分档：播放器拖音量条看图标形态变化（0/50/100 三点截图）。
- 人工检查点（用户）：控制族符号视觉重量是否一致、行 badge 无变化。
