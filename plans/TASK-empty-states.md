# TASK: Empty & loading states sweep (T1 remainder, 1.0 batch 1)

- Status: done（2026-09-14 收尾，真机验收通过；make test 345/54 全绿零警告）
- Created: 2026-09-12
- Roadmap: plans/ROADMAP-1.0.md C7; evidence plans/UI-AUDIT-2026-09-05.md §T1

## Goal
消灭残余的"裸"等待/空态表面：每个等待有 spinner、每个空/失败面有
引导。配方现成（design/DESIGN-TOKENS.md §6.1/§6.2 + StatePlaceholderView
+ Player renderStateOverlay 先例），本卡只做应用不做发明。

## 范围核实（2026-09-12 代码实证，修正草案清单）
草案六项中四项经核实已由 2026-09-05 P1 卡
（plans/archive/TASK-empty-loading-states.md）闭环，移出本卡：
- ✗ share 网格加载静态文案 → 已是 spinner（ShareGridViewController
  .loading → StatePlaceholderView）
- ✗ 空文件夹零提示 → 已有「空文件夹」占位（Browser renderPlaceholder）
- ✗ 目录切换无加载态 → beginLoading 清列表 +「正在加载…」spinner
- ✗ 连接失败双提示 → 已收敛占位单点（LibraryCoordinator 注释实证：
  no modal alert on top of it）
- ✗（顺带核实）播放器加载/缓冲/失败 → 已有 renderStateOverlay
  （spinner + 失败占位带重试）

真实残余（本卡范围，三处）：
1. **单页阅读器**（audit P3）：首载 = 黑屏 + chrome 页码；失败 =
   黑屏 + 裸「加载失败」文字（statusLabel）。翻页保留旧图，黑屏只
   出现在首载与失败后（ReaderViewModel 实证）。
2. **条带阅读器**：失败槽位与加载中不可区分（都只剩页码，仅日志
   记 error）；重试机制已存在（滚出滚回自动重载，applyLoadFailure
   注释实证），但用户无从得知失败。
3. **PDF 阅读器**：加载 = 裸「加载中…」静态文字（违反 §6.2 禁止
   静态文案冒充加载）；失败 = 裸文字无图标无行动。

## Decisions（Plan Card 拍板，Executor 照做）
1. **单页阅读器**：仿 Player renderStateOverlay——surface 上叠
   StatePlaceholderView：加载（view 侧推导：image==nil 且
   errorMessage==nil）= .loading spinner +「加载中」+ 页标题；
   失败 = symbol exclamationmark.triangle +「加载失败」+ 说明 +
   「重试」按钮。ReaderViewModel 加 retry()（重试当前页，内部即
   重新发起当前页加载）。statusLabel 两处引用随 overlay 取代移除。
   翻页保留旧图时不出现 overlay（只在无图可显示时）。overlay 位于
   内容之上、chrome pill 之下（Player 先例）；切条带模式时随内容
   视图摘除。
2. **条带阅读器**：ContinuousReaderViewModel 新增
   onSlotFailure: ((Int) -> Void)? 发布槽位失败（applyLoadFailure
   中调用，沿用与 onSlotImage 相同的 generation/slot 硬规则）；
   StripSlotView 失败呈现 = 居中 ⚠ symbol（textOnMedia2 族）+
   caption「加载失败 · 第 N 页」+ toolTip 提示重试方式（滚动离开
   再返回自动重试）；失败呈现取代页码数字（不再同显）。不新增
   显式重试动作——槽位销毁重建（residency 重入）自然归零呈现并
   重试加载。
3. **PDF 阅读器**：statusLabel 换 StatePlaceholderView——.loading =
   spinner +「加载中」+ 文档标题；.failed = symbol +「加载失败」+
   message +「重试」按钮。PdfReaderViewModel 支持重试：终态后允许
   重新 start（最小改动——终态清 loadTask 或显式 retry()，不动
   加载中语义与 waitForLoad 测试缝）；失败文案「请关闭后重试」随
   重试钮落地调整（按钮本身即行动引导，message 保留原因描述）。
4. 不新增设计令牌（§6.1/§6.2 配方 + textOnMedia 族 + reader-bg
   现成），DESIGN-TOKENS.md 不动。
5. 阅读器/PDF chrome（页码 pill、窗口工具）在三态呈现期间保持
   可用（Player 先例：可以从死页翻走、正常关窗）。

## Out of scope
已闭环的库界面三态与播放器（见核实清单）；错误文案人性化 /
ErrorPresenter（BACKLOG 远期项）；骨架屏（明确不要，spinner 即可）；
阅读器预取/解码调优。

## Steps
1. 单页阅读器：VM retry() + WC overlay + 测试。
2. 条带：VM onSlotFailure + 槽位失败呈现 + 测试。
3. PDF：VM 可重试 + StatePlaceholderView 替换 statusLabel + 测试。
4. 验证：make test 全绿 + 真机验收清单（前后对比截图，audit 规矩）。

## DoD
1. 三处表面按 §6.1/§6.2 配方呈现，无新增临时占位组件（复用
   StatePlaceholderView / 既有令牌）。
2. 测试：ReaderViewModel.retry 清错重载；ContinuousReaderViewModel
   失败发布 onSlotFailure（generation/slot 守卫不破坏）；
   PdfReaderViewModel 失败后可重试成功；既有 PdfReaderTests /
   ContinuousReader 测试不回归。`make test` 全绿。
3. 真机前后对比截图：单页首载/失败、条带失败槽位、PDF 加载/失败
   （失败制造法：连上 SMB 后断网或停 SMB 服务，再翻页/滚动/开文档）。
4. 零行为回归：翻页保留旧图、条带滚出滚回重试、PDF 正常打开
   与现状一致。

## Risks
- 条带失败呈现与 residency 重建生命周期交互（槽位销毁=呈现归零、
  重建=重新加载）→ onSlotFailure 必须走与 onSlotImage 相同的
  generation/slot 守卫。
- PDF start() 重入改动碰 loadTask 生命周期与 waitForLoad 测试缝 →
  最小化：仅终态清 loadTask，不动加载中语义。
- 单页 overlay 与条带模式切换共存 → 模式切换路径必须随内容视图
  一并摘除 overlay。
- 加载态一闪而过（缓存命中）→ 可接受（2026-09-05 卡已拍板）。
