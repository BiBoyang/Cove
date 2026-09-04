# TASK: 自动滚屏速度档位

日期：2026-09-05 ｜ 协作模式（助手规划/Review，其他 agent 实现）

## 目标复述

条带自动滚屏当前钉死 110 pt/s 单速（plans/archive/TASK-strip-autoscroll.md
留的后续口）。加三档：0.5x / 1x / 2x（55 / 110 / 220 pt/s），切换立即生效，
选择全局持久化。

## 决策记录（已拍板）

- **档位交互：右键循环**：播/停按钮保持单击切换；**右键该按钮**在
  0.5x → 1x → 2x 间循环，当前档位以小字贴在按钮旁（如 "1x"，沿用
  播放器倍速按钮的视觉语言）。不加 popover（scrubber 胶囊已够挤，
  右键是 macOS 惯例且零新 chrome）。
- **持久化**：`SettingsService` 加 `stripAutoScrollSpeedFactor`（Double，
  register default 1.0），读取在 strip VM 初始化/展示时，写入在每次
  循环切换时。设置页不加 UI（开关级别太低，YAGNI）。
- **生效语义**：切档立即作用于正在进行的滚屏（下一拍 dt × 新速度）；
  暂停中切档只改显示，起播时用新档。
- 速度常量仍归 View 层（对齐自动滚屏"纯视图动画"的原决策），
  `autoScrollSpeed = 110 × factor`。

## Out of Scope

- 自定义速度数值、按内容类型记忆、设置页 UI。
- 单页模式自动翻页（另一任务单 TASK-paged-slideshow.md）。

## 现状摘要

- `ContinuousReaderView.swift`：`Self.autoScrollSpeed = 110` 常量 +
  `autoScrollButton`（action = toggleAutoScroll）+ scrubber 胶囊约束布局
  现成；右键手势可用 `NSClickGestureRecognizer(buttonMask: 0x2)` 或子类
  NSButton override `rightMouseDown`（实现时选成本低的）。
- `SettingsService`：加键有 register(defaults:) 现成模式（Bool/Double
  都有先例）；VM/WC 持 settings 的注入路径参照 ReaderCoordinator 的
  settings 注入（AppDelegate 组装根已有实例）——实现时选最短接线：
  ContinuousReaderViewModel 或 ContinuousReaderView 接 settings。

## Step 列表与 DoD

### Step 1：三档循环 + 持久化

- 改动文件：
  - `Cove/Features/Reader/Views/ContinuousReaderView.swift`
  - `Cove/Services/Settings/SettingsService.swift`
  - 接线文件（AppDelegate/Coordinator，视接线选择而定）
  - `Tests/CoveTests/`（SettingsService 持久化用例）
- DoD：
  1. 测试：档位存取 round-trip、缺省 1.0、非法值（如 0/负）回退默认。
  2. `make build` 零警告、`make test` 全绿（CI 同步绿）。
  3. 人工检查点（真机）：
     a. 条带开滚屏，右键按钮切到 2x → 肉眼可辨加速，按钮旁显示 "2x"；
     b. 切到 0.5x → 减速；暂停再播放仍为新档；
     c. 重启 app 再开滚屏 → 档位保持。

## 风险与回滚点

- 右键在 NSButton 上的手势识别可能与系统菜单冲突——实现时若无响应
  换子类 NSButton override rightMouseDown。
- 回滚：单 Step revert 即恢复单速。

## 验证命令

```sh
make test
make generate && make build
```
