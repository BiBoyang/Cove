# TASK: 克制的动效（时长/曲线令牌 + hover 过渡 + 占位淡入）

日期：2026-09-05 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）

## 目标复述

全 App 目前只有缩略图淡入一处动效（0.15s，`BrowserRowCellView.showThumbnail`）。
在"只为状态反馈服务、不做装饰性动效"的原则下补齐交互动效最低集：
卡片 hover/选中过渡与占位视图淡入，并沉淀时长/曲线令牌（令牌图纸
design/DESIGN-TOKENS.md §5）。纯增量，不改任何布局与逻辑。

## 决策记录（已拍板 2026-09-05）

- 动效令牌两档：`motionFast = 0.15s ease-out`（现状缩略图淡入正名）、
  `motionMedium = 0.25s ease-out`（新增预留，未来面板/弹层用；本卡不用）。
- 覆盖点仅两处（克制）：share 卡片 hover/选中 fill 过渡、
  StatePlaceholderView 出现淡入；列表行选中**不做**过渡（Finder 亦无）。
- 弹层/NSPopover 动画不动（系统自带）；播放器/阅读器 chrome 显隐已有
  fade，本卡只复核不改动。

## Out of Scope

- 装饰性动效、页面转场、弹簧曲线。
- P6 媒体 chrome 的全部内容（下一卡）。

## 现状摘要

- 唯一动效点：`BrowserViewController.swift` showThumbnail 的
  `NSAnimationContext` 0.15s fade-in。
- ShareCardItem 的 fill 切换（`updateHighlight`）瞬时跳变；
  RoundedFillView 在 `updateLayer` 重解析 fill（hover/appearance 变化时）。
- StatePlaceholderView 由 render 直接增删，无过渡。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. CoveStyle 新增 `motionFast` / `motionMedium`（含 ease-out 曲线约定注释）；
   令牌文档 §5 两档转 [已拍板]。
2. ShareCardItem 的 fill 过渡：hover/选中变化时以 `NSAnimationContext`
   fast 档过渡 fillColor（注意 RoundedFillView 的 updateLayer 重解析——
   走 `animator()` 路径；若与 layer 重解析冲突，退化为 alpha 过渡并在
   提审时说明）。
3. StatePlaceholderView 出现时 fade-in（fast 档，alpha 0→1）。
4. DoD：
   - `make generate && make build` 零警告；`make test` 全绿；
   - **前后录屏对比**两段：卡片 hover 过渡、占位淡入（QuickTime 录制，
     存 sessions/assets/，不入库）；
   - 动效不改变任何状态语义（hover/选中/占位的最终态与现状逐帧一致）；
   - 真机手感验收前不合并。

## 风险与回滚点

- RoundedFillView 的 `updateLayer` 每次重解析背景色，可能与
  `animator()` 驱动的 layer 动画互相覆盖——按上文退化预案处理。
- 动画一律短于 0.2s，无性能风险；不引入新依赖。
- 回滚：单 commit revert。

## 验证

- 录屏两段 + 真机手感（hover 跟手不拖沓、占位不闪变）。
- 人工检查点（用户）：动效"存在感低"为达标——能感到顺，说不出动。
