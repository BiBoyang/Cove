# TASK: 单页模式自动翻页（slideshow）

日期：2026-09-05 ｜ 协作模式（助手规划/Review，其他 agent 实现）

## 目标复述

单页（paged）阅读模式加"屏幕保护式"自动翻页：开启后每隔固定间隔自动
翻到下一页，任何手动翻页意图即暂停接管，翻到末页自停。jpg 目录漫画
场景的主力体验。

## 决策记录（已拍板）

- **间隔固定 5 秒 v1**，不做档位/设置项（YAGNI；不够用时后续再开）。
- **状态归 ViewModel**：`ReaderViewModel` 持 `isAutoAdvancing` 与 Timer
  （UI 会话状态与任务生命周期归 VM，AGENTS.md 规矩 12）；tick 到点走
  现有 `goNext()`，页切换的全部既有逻辑（预取/加载/状态发布）零改动。
  Timer 用 target/selector 或直接 `Timer.scheduledTimer(withTimeInterval:repeats:block)`
  ——注意 @MainActor 与 @Sendable 闭包冲突（PlayerCoordinator 的
  target/selector 先例可抄）。
- **手动接管即暂停**：`goPrevious()`/`goNext()`/`jumpToPage()` 被用户
  触发（按钮/键盘）时先停自动再执行——自动翻页期间用户按方向键的
  意图是"自己翻"，不是"双倍速度"。与条带滚屏的"重定位不中断"不同：
  翻页是整页跳变，继续自动会顶掉用户正在看的页（两场景语义差异已在
  评审时对齐）。
- **末页自停**：tick 时已在末页（canGoNext == false）→ 停止并复位
  状态；用户再按播放 = 从头来？**不**，末页按播放无动作（对齐条带
  滚屏"到底按播放无反应"决策）。
- **切换入口**：Space（paged 模式 keyCode 49 当前空闲）+
  页码 label 旁加播/停小按钮（HUD 圆形小按钮，参照 FrostedCircleButton）。
  自动翻页期间按钮显示暂停态，页码 label 可加"自动"小标记（可选，
  实现时成本>5 行就不做）。
- **生命周期收口**：切条带、关窗、teardown 必停 Timer（weak/关闭路径
  全部核对）。

## Out of Scope

- 间隔档位/用户设置、横屏横翻以外的形式、循环播放（末页回卷）。
- 条带滚屏速度档位（另一任务单 TASK-autoscroll-speed-gears.md）。

## 现状摘要

- `ReaderViewModel`（`Cove/Features/Reader/ViewModels/ReaderViewModel.swift`）：
  goNext/goPrevious/jumpToPage + State 发布链现成；测试在
  `Tests/CoveTests/ViewModelTests.swift`（RecordingLoader + 直接调方法，
  不等真实时间）。
- `PagedReaderWindowController`：键盘路由 handleKey（Space 空闲）、
  FrostedCircleButton 控件库、progressLabel 布局现成。
- 可测试性设计：tick 逻辑抽成 VM 内部方法（如 `autoAdvanceTick()`），
  单测直接调它断言 goNext/自停/接管语义，不依赖 Timer 真跑。

## Step 列表与 DoD

### Step 1：VM 自动翻页状态机 + WC 入口

- 改动文件：
  - `Cove/Features/Reader/ViewModels/ReaderViewModel.swift`
  - `Cove/Features/Reader/Views/PagedReaderWindowController.swift`
  - `Tests/CoveTests/ViewModelTests.swift`（或独立新文件）
- DoD：
  1. 测试：tick → goNext；末页 tick → 自停且不再翻；手动 goPrevious/
     goNext/jumpToPage → 自动态解除；teardown → 无残留调用。
  2. `make build` 零警告、`make test` 全绿（CI 同步绿）。
  3. 人工检查点（真机）：
     a. 单页模式 Space → 每 5 秒自动翻页，按钮变暂停态；
     b. 自动中按 ←/→ → 自动停、页码按手动走；
     c. 翻到末页 → 自停；再按 Space 无反应；
     d. 切条带再切回 → 无残留自动翻页。

## 风险与回滚点

- **Timer 与 VM 生命周期**：teardown 必须先 invalidate；review 核对
  每条退出路径（关窗/切模式/replace session）。
- 回滚：单 Step revert 即恢复手动翻页。

## 验证命令

```sh
make test
make generate && make build
```
