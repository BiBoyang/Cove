# TASK: 条带阅读器打磨（模式持久化 / 缩放 / 跳页条）

日期：2026-09-04 ｜ 方案已确认（用户"可以"+ 四个决策点按默认）

## 目标复述

条带（连续纵向）阅读器补三件体验缺口：阅读模式偏好持久化、条带内缩放、
底部跳页 scrubber。不碰核心加载/虚拟化管线。后续候选：条带自动滚屏
（已记 BACKLOG，本次不做）。

## 决策记录（已拍板）

- **模式偏好按内容类型分别记忆**：漫画 / 目录各一个 UserDefaults 键；
  无记录时维持现有默认（漫画条带、目录单页）。切换模式时写回当前类型。
- **缩放为布局级**（非渲染级 magnification）：VM 持 zoom 系数，布局宽
  = 视口宽 × zoom，复用 `StripLayoutModel.updateViewportWidth` 的锚定
  重排；档位 100/125/150/200%，快捷键 ⌘+ / ⌘− / ⌘0（仅条带模式拦截，
  其余 Cmd 组合照旧放行菜单）。zoom > 100% 开横向滚动（overlay scroller）。
  不做触控板捏合。
- **缩放会话级**，每次打开回 100%，不设用户设置项。
- **缩放不进单页模式**：单页是整页适配窗口，缩放=平移裁剪属另一套机制，
  Out of Scope。
- **跳页条只做条带模式**：进度 label 升级为 slider + 页码；拖动中只更新
  文案，松手才跳页（跳页 = 滚到该页页首，滚动上报链自然更新 currentPage）。
  单页模式维持前后翻页，不加 scrubber。

## 已知限制

- 显示池解码上限是屏幕像素宽：zoom 200% 且窗口接近全屏时，放大区域可能
  超出解码分辨率而略糊。v1 接受，不为此改解码管线。

## 现状摘要

- `StripLayoutModel`：纯布局数学，viewportWidth × aspect 定页高，
  `updateViewportWidth` 锚定重排现成——zoom 不动它，VM 传换算后宽度。
- `ContinuousReaderViewModel`：slot 生命周期 + generation 校验；zoom 状态、
  `scrollToPage` 都加在这里。
- `ContinuousReaderView`：frame 布局（非约束）；documentView 宽目前 = 视口
  宽，zoom 后 = 有效宽；`handleKey` 已消费方向键。
- `PagedReaderWindowController.handleKey`：Cmd 组合键目前直接 return false
  放行；缩放键要在该 guard 之前、且仅 strip 模式拦截。
- `SettingsService`：UserDefaults 薄封装，register(defaults:) 模式现成；
  为守依赖方向（Features → Services），Settings 只存取 raw String，
  ReaderMode 映射归 Coordinator。
- `ReaderCoordinator`：init 加 `settings: SettingsService`；AppDelegate 已有
  settingsService 实例可传；`directoryPrefetchItems == nil` 即漫画模式的
  现有判型方式，持久化写回沿用。

## Step 列表与 DoD

### Step 1：模式偏好持久化

- 改动：`ReaderMode.swift`（raw String）、`SettingsService.swift`（两键 +
  raw 存取）、`ReaderCoordinator.swift`（打开读偏好 / 切换写回）、
  `AppDelegate.swift`（注入 settings）、`Tests/CoveTests/ViewModelTests.swift`
  （ReaderCoordinatorTests 用例）。
- DoD：
  1. 测试：偏好缺失 → 默认（漫画 strip / 目录 paged）；有偏好 → 覆盖默认；
     Settings raw 存取 round-trip。
  2. `make test` 全绿、`make build` 零警告。

### Step 2：条带缩放

- 改动：`ContinuousReaderViewModel.swift`（zoomSteps/zoomIn/zoomOut/resetZoom +
  有效宽度换算）、`ContinuousReaderView.swift`（documentView/slot 宽改用有效宽、
  横向 scroller 开关、zoom 转发方法）、`PagedReaderWindowController.swift`
  （⌘ 键路由）、`Tests/CoveTests/ContinuousReaderViewModelTests.swift`。
- DoD：
  1. 测试：zoom 改变有效布局宽度；缩放时锚点页视觉位置保持；reset 回 100%。
  2. `make build` 零警告、`make test` 全绿。
  3. 真机：缩放中滚动不跳、200% 横向拖动正常、resize 后 zoom 保持。

### Step 3：跳页 scrubber

- 改动：`ContinuousReaderViewModel.swift`（State 加 currentPage/pageCount +
  `scrollToPage` + onScrollTo 回调）、`ContinuousReaderView.swift`
  （slider + 拖动中文案、松手提交、非拖动时跟随 currentPage）。
- DoD：
  1. 测试：scrollToPage 落点 yOffset 正确、越界钳制、松手后 currentPage 随
     滚动上报更新。
  2. 真机：拖到第 N 页落点正确；拖动过程不触发大规模加载。

## 风险与回滚点

- zoom > 100% 开横向滚动后 documentView 宽度语义变化（视口宽 → 有效宽）：
  slot x=0 左对齐，Step 2 第一验证点。
- 锚定重排在"非整数倍缩放 + 测量中页面"叠加下的视觉稳定性，真机快滚时盯。
- 三项互相独立，分别 revert 即可；Step 1/3 是无害残留级。

## 验证命令

```sh
make test                    # 全量回归（含新用例）
make generate && make build  # 零警告
```

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package：Step 编号、改动文件列表、关键 diff
摘要、自测命令与结果、已知风险。每个 Step 单独提审，不跨步混改。
