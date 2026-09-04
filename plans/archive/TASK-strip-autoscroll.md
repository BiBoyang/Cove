# TASK: 条带自动滚屏（auto-scroll）

日期：2026-09-04 ｜ 协作模式（助手规划/Review，其他 agent 实现）

## 目标复述

条带模式下可开启自动匀速下滑阅读：播放/暂停切换，滚到文档末尾自停，
用户手动滚动（滚轮/触控板）即暂停让位。纯视图层动画，不动加载/虚拟化
管线。

## 决策记录（已拍板）

- **驱动在 View 层**：自动滚屏是滚动动画，归属视图会话（对齐 AGENTS.md
  规矩 12 的 cell 复用例外精神）；`ContinuousReaderViewModel`、
  `StripLayoutModel` 零改动——slot 同步、currentPage、warm window 全部
  经现有 `updateScrollOffset` 上报链自然工作。
- **帧驱动用 `NSView.displayLink(target:selector:)`**（macOS 14+ 现成
  API，vsync 对齐、窗口不可见自动停），不用 Timer/CVDisplayLink。
  **教训（2026-09-04 真机修复）**：该工厂返回的 CADisplayLink 不会被
  调度——必须显式 `link.add(to: .main, forMode:)` 才点火（探针实证：
  未调度 0 tick，显式 add 后正常）。用 `.common` 让菜单/事件跟踪期间
  不断流。
- **单速 v1**：固定速度 110 pt/s（约一屏 10 秒），不做档位、不做设置项
  （YAGNI）；实测不合适再调常量或加档。
- **交互**：scrubber 胶囊左侧加播放/暂停按钮（`play.fill`/`pause.fill`），
  键盘 Space = 切换（条带模式下 Space 目前无占用）。**停止条件（2026-09-04
  行为翻转后）**：再按一次（显式切换）、到底自停、切回单页、关窗、缩放键
  （缩放重排布局，继续滚会抢滚动位置）。**手动重定位不中断**：滚轮/触控板
  滑动、方向键/PageUp/PageDown、拖 scrubber 都只是改位置，滚屏从新位置
  继续（初版"手动即暂停"经真机反馈推翻——滑动回看时不希望被打断）。
- **手动滚动检测**：子类化 NSScrollView（如 `StripScrollView`）override
  `scrollWheel(with:)`——程序滚动走 `contentView.scroll(to:)` 不经过
  该方法，天然区分用户手势与自动驱动，无需标志位。

## Out of Scope

- 速度档位/用户设置项、渐加速（ramp）、单页模式自动翻页、横向回正。
- 阅读位置记忆（另一任务单 TASK-reader-position-memory.md）。

## 现状摘要

- `ContinuousReaderView`（`Cove/Features/Reader/Views/ContinuousReaderView.swift`）：
  scrollView/documentView/slot frame 布局现成；`scroll(to:)` 内部钳制
  `[0, contentHeight - viewport]`；底部 scrubber 胶囊是按钮落点参照。
- 键盘路由：条带模式键经 `PagedReaderWindowController.handleKey` →
  `stripView.handleKey`（keyCode 49 Space 当前 default 落 return false，
  空闲可用）。
- 缩放（⌘=/⌘−/⌘0）会锚定重排布局：自动滚屏中收到 zoom 先暂停。

## Step 列表与 DoD

### Step 1：自动滚屏驱动 + 控件

- 改动文件：
  - `Cove/Features/Reader/Views/ContinuousReaderView.swift`
  - `Cove/Features/Reader/Views/PagedReaderWindowController.swift`（Space 路由注释更新）
- 内容：
  1. `StripScrollView: NSScrollView` 子类，`scrollWheel(with:)` 里
     `onUserScroll?()` 后 super；view 借此暂停自动滚屏。
  2. View 持 displayLink（懒建）、`isAutoScrolling` 状态、每帧
     `offset += 110 × dt` 走现有 `scroll(to:)`；到底自停并复位按钮图标。
  3. scrubber 胶囊加播/停按钮（HUD 风格对齐现有 chrome）；Space 切换；
     zoom 键 / showPaged 切换 / 关窗均先停。
- DoD：
  1. `make build` 零警告（strict concurrency：displayLink 回调主线程，
     无需跨 actor）。
  2. 本步无单测（视图层动画，无跨 actor 状态）；逻辑集中在 view 内，
     review 核对规矩 12 边界。
  3. 人工检查点（真机）：
     a. 条带模式开自动滚屏 → 匀速下滑、页码跟随、图像正常加载；
     b. 滚轮/触控板任一手动滚动 → 自动暂停，按钮回到播放态；
     c. 滚到底 → 自停；再按播放（已在底）→ 无反应或回顶（实现时选定
        并在提审说明）；
     d. 自动滚屏中 ⌘= 缩放 → 暂停且位置不跳；切单页再切回 → 不残留
        自动滚动；
     e. 长漫画连滚 3 分钟：内存无异常增长（slot 虚拟化正常销毁）。

## 风险与回滚点

- **displayLink 与窗口生命周期**：关窗/切模式必须 stop 并置 nil，防悬挂
  回调；review 时核对所有退出路径。
- **手动滚动让位的判定**：只能拦滚轮手势；键盘方向键滚动（现有 ↑/↓）
  也应暂停——`handleKey` 里滚动键分支先停自动再滚。
- 回滚：单 Step 整体 revert；不触 VM/管线，风险面最小。

## 验证命令

```sh
make generate && make build  # 零警告
make test                    # 全量回归（应无新增失败）
```

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package：Step 编号、改动文件列表、关键 diff
摘要、自测命令与结果、已知风险（含"滚到底再按播放"的行为选定说明）。
