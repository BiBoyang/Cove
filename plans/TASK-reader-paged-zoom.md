# TASK: 单页模式缩放（paged zoom）

日期：2026-09-04 ｜ 协作模式（助手规划/Review，其他 agent 实现）

## 目标复述

单页（paged）阅读模式当前只能整页适配窗口，看不了局部细节。补缩放：
与条带模式同一套 ⌘=/⌘−/⌘0 档位交互，放大后鼠标拖拽平移，翻页/切模式
重置回适配。

## 决策记录（已拍板）

- **布局级缩放（非渲染级 magnification）**：缩放 = 图像 frame 按适配尺寸
  × 档位重算，钳制在容器内；不引入 NSScrollView 承载（渲染级放大必糊，
  且要重构现有 chrome 布局）。与条带 zoom 同哲学。
- **档位**：100%（适配）/ 150% / 200% / 300%，⌘= 进、⌘− 退、⌘0 回适配。
  百分比是相对"适配窗口"的倍数，不是图像原始像素。
- **平移**：仅拖拽（mouseDragged 系列，根视图拦截）；边界钳制——图像
  边缘不拖过窗口边缘（放大时图像总覆盖窗口，不露底）。不做键盘平移、
  不做惯性。
- **重置时机**：翻页（goPrevious/goNext/jumpToPage）、窗口 resize、切到
  条带，都回到 100% 适配。缩放会话级，不持久化。
- **反馈**：缩放变化时窗口中央闪现当前百分比（对齐条带的 zoom flash 做法，
  可复用同样的 generation 防叠淡出模式）。
- **键盘路由**：`PagedReaderWindowController.handleKey` 目前在 paged 模式
  把 Cmd 组合一律放行菜单；=/- /0 不在菜单里，paged 模式拦 ⌘=/⌘−/⌘0
  安全（条带已有同款拦截块，照抄结构）。

## Out of Scope

- 触控板捏合、双击智能缩放、旋转、缩放持久化/设置项。
- 条带模式的任何改动（已有自己的布局级 zoom）。

## 现状摘要

- `PagedReaderWindowController`（`Cove/Features/Reader/Views/
  PagedReaderWindowController.swift`）：imageView 当前纯约束布局
  （居中 + ≤superview，compression resistance 压低的理由见原注释）。
  chrome（前后按钮/退出/模式/页码）浮在 imageView 之上，不在缩放体系内。
- 图像显示尺寸上限 = 显示池按屏幕像素宽解码：300% 档在最坏情况略糊，
  与条带 zoom 同一已知限制，接受。
- 条带 zoom flash 的实现（`ContinuousReaderView.flashZoomLabel`）是文案/
  淡出/防叠的现成参照。

## Step 列表与 DoD

### Step 1：缩放 + 平移 + 键盘 + 提示

- 改动文件：
  - `Cove/Features/Reader/Views/PagedReaderWindowController.swift`
  - 若抽钳制/几何纯函数：`Tests/CoveTests/` 下新增对应测试文件
- 内容：
  1. imageView 布局改为"容器裁剪 + frame 驱动"：100% 时 frame = 适配
     窗口的居中 rect（行为与现状逐点一致，含 compression-resistance
     注释指向的问题不回退）；>100% 时 frame = 适配 rect × 档位 + pan。
     resize/全屏切换重算（原约束路径的免处理优势要保住——frame 驱动
     意味着 override layout 重算，属本 Step 主要工作量）。
  2. 拖拽平移 + 边界钳制；翻页/切模式/resize 重置。
  3. ⌘=/⌘−/⌘0 拦截（paged 模式块，先于 Cmd 放行 guard）。
  4. 中央百分比闪现（仿条带）。
- DoD：
  1. 几何/钳制若抽纯函数则补单测；`make build` 零警告、`make test` 全绿。
  2. 人工检查点（真机）：
     a. ⌘= 逐级放大、中央闪现 150%/200%/300%，图像变宽且不糊于条带同级；
     b. 放大后拖拽平移，边缘钳制不露黑底；⌘0 回适配居中；
     c. 放大状态翻页 → 新页回 100% 适配；
     d. 放大状态 resize/全屏切换 → 不卡死不错位，回适配或保持合理；
     e. 横竖图各验一种（横图适配语义不同）。

## 风险与回滚点

- **约束 → frame 驱动的回退风险**：原约束布局是为了 fullscreen/resize
  免处理（注释写死）。实现时优先"100% 仍走约束、>100% 切 frame"的混合
  方案不可行（两套机制交接易闪烁）则整体 frame 驱动 + layout 重算，
  提审时说明选型。
- 回滚：单 Step 整体 revert 即恢复纯适配。

## 验证命令

```sh
make test                    # 全量回归
make generate && make build  # 零警告
```

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package：Step 编号、改动文件列表、关键 diff
摘要、自测命令与结果、已知风险（含布局选型说明）。
