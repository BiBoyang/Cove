# TASK: 播放器悬浮控制条（毛玻璃胶囊 + 闲置自动隐藏）

日期：2026-08-23 ｜ 协作模式（主会话规划/Review，另一会话实现）

## 目标复述

把播放器的通栏底部控制条改为悬浮毛玻璃胶囊；隐藏窗口标题栏，文件名改为角落浮层小字；播放中闲置自动隐藏控件与光标。播放功能（播放/暂停、进度、音量）零变化。

## 决策记录（已拍板）

- **胶囊**：`NSVisualEffectView`（`.hudWindow` / `.withinWindow`），圆角 `CoveStyle.radiusLarge`(14)，距窗口左/右/下各 16pt，高 48，轻微投影；浮在视频层上，不再贴窗口底边。
- **标题栏**：窗口改 `.fullSizeContentView` + 透明标题栏 + 隐藏标题（阅读器同款）；文件名改为左上角浮层小字（白色 80%、12pt、带阴影保证在亮画面上可读），leading 留 ~72pt 避开红绿灯。红绿灯保留。
- **按钮**：胶囊内控件改无边框白色符号按钮（播放/暂停、音量图标 + 音量滑条、进度滑条、时间文字保留）；胶囊已提供材质，按钮不再自带底色。
- **自动隐藏**：仅 `playing` 状态闲置 ~2.5s 隐藏（胶囊 + 浮层标题 + 光标）；`paused/buffering/error` 不隐藏；scrub 中不隐藏；光标悬在胶囊上不隐藏；任何鼠标移动立即恢复。逻辑在 VM（idle 间隔可注入，Task-based 计时），View 只转发鼠标活动事件。
- 保持单窗口策略与 teardown 硬约束（invalidate → cancelInFlightReads → terminate → detach）不动。

## Out of Scope

倍速/字幕/音轨切换、全屏模式、多窗口、手势、控制条内新增按钮。

## 现状摘要

- `Cove/Features/Player/Views/PlayerWindowController.swift`：控制条是贴底通栏 `NSVisualEffectView`（underWindowBackground，高 44）；窗口带标准标题栏显示完整文件名；键盘控制（空格/方向键/Esc）保留不动。
- `PlayerViewModel`：状态机（loading/playing/paused/buffering/error）+ scrub 抑制已就绪，自动隐藏只需消费现有状态 + 新增 idle 计时。
- `CoveStyle`（SharedUI）：radiusLarge 可用；浮层控件无需新组件（FrostedCircleButton 是给黑底阅读器的，胶囊内按钮用无边框符号即可）。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. 胶囊化控制条（材质/圆角/留白/投影）+ 按钮重样式。
2. 窗口标题栏隐藏 + 左上角浮层标题。
3. VM 自动隐藏状态机（idle 可注入）+ View 鼠标活动转发 + 光标隐藏。
4. DoD：
   - VM 测试：playing 闲置超时→隐藏；paused 不隐藏；scrub 中不隐藏；鼠标活动→恢复并重置计时；
   - `make generate && make build` 零警告、`make test` 全绿；
   - 提审附 Review Package。

## 风险与回滚点

- 光标隐藏是体验敏感点：仅在 playing 且光标不在胶囊上时藏；任何鼠标移动恢复。
- 浮层标题在亮画面上可读性：白字 + 阴影兜底，截图验收核。
- 回滚：单 commit revert。

## 验证

- 主会话无头验收：驱动真实播放窗口（NAS 视频），截图核胶囊布局/浮层标题/自动隐藏前后两态。
- 人工检查点（用户）：播放中闲置隐藏→动鼠标恢复；暂停时不隐藏；拖进度时控件稳定；音量/进度功能回归。

## Review 交接

按 WORKFLOW.md §5.2 Review Package：改动文件列表、关键 diff 摘要、自测命令与结果、已知风险。
