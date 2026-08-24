# TASK: 连续纵向条带阅读器（continuous strip reader）

日期：2026-08-24 ｜ 协作模式（主会话规划/Review，另一会话实现）｜ 回滚锚点：v0.5.0

## 目标复述

阅读器新增连续纵向条带模式：页面按视口宽度纵向排列连续滚动（webtoon/SenPlayer 式），与现有单页模式可在阅读器内切换。默认 CBZ 漫画=条带，目录照片=单页。

## 上次的死因 → 这次的结构性对策（本任务的第一公民）

| 上次症状 | 根因 | 这次的硬规则 |
|---|---|---|
| 前几张加载失败 | 打开竞态，加载任务无身份约束 | slot 创建时钉死 pageIndex，**永不换内容复用**；异步结果落地前校验 `slot.pageIndex == result.index`，不符即弃 |
| 滑动时图片错位（挤压） | slot 复用 + 高度重排无锚定 | 可见窗口外的 slot view **销毁**（不是复用）；高度从估计值→真实值变化时做**视口锚定重排**（当前可见页视觉位置不动） |

## 决策记录（已拍板）

- **入口**：阅读器内工具栏加模式切换按钮（单页 ⇄ 条带），不是另开阅读器。切换保留当前页。
- **默认模式**：CBZ → 条带；目录照片 → 单页（维持 A1 默认）。模式偏好不持久化（v1 每次按默认，切换仅当次有效）。
- **虚拟化**：只保留可见区域 ± 3 屏的 slot view；滚动接近边界时按 index 创建新 slot，远处的销毁。
- **高度策略**：未解码时用估计高（视口宽 × 4:3）；解码拿到真实宽高比后**锚定重排**（见下），不预探全量尺寸。
- **锚定重排**：某个 slot 高度变化时，调整其上方所有 slot 的累计偏移，使当前第一可见 slot 的 contentOffset 视觉不变；批量在 layout pass 里一次完成，避免逐帧抖动。
- **加载调度**：进入可见区即加载；向前 1 屏预解码（复用 CBZ 预解码/目录预取既有管线）。现有 `ReaderImageLoader` 与 display/original 双池不变——条带只是新的消费方式。
- **内存**：slot 销毁时释放其 CGImage（磁盘 display 池兜底回看）；不持有全量解码图。
- **单页模式**：行为零变化（A1 的所有测试必须原样通过）。

## Out of Scope

缩放、双页模式、跳页滑条、模式偏好持久化、横向条带。

## 现状摘要

- `PagedReaderWindowController`（单页）+ `ReaderViewModel`（页码/加载/陈旧守卫）+ `ReaderImageLoader`（display→original→网络）+ CBZ 预解码/目录预取均已就位。
- `ReaderContent.pages` 提供页序；`ReaderViewModel.onPageChanged` 缝可用于条带的"当前页"跟踪（页码显示/进度）。
- 旧的 `plans/TASK-reader-fit-screen.md` 是 A1 之前针对旧连续阅读器的任务单，其 slot/retention/anchor 思路可参考但实现全新。

## Step 列表与 DoD

### Step 1：条带逻辑层（slot 拓扑 + 虚拟化 + 锚定重排，纯逻辑无 UI）

- 逻辑层 `StripLayoutModel`（slot 管理器，无 AppKit 渲染依赖可测）：index→slot 映射、±3 屏窗口计算、估计高、高度更新后的锚定 offset 调整。
- DoD：逻辑层测试——slot 身份稳定（异步结果不错位）、高度更新锚定正确（可见页不跳）、窗口滚动创建/销毁正确；`make test` 全绿。

### Step 2：接入阅读器 + 加载调度 + 模式切换

- `ContinuousReaderView`（NSScrollView 文档视图）：按逻辑层窗口创建/销毁 slot view（窗外销毁、不复用），滚动监听驱动，异步结果落地前校验 `slot.pageIndex`；条带容器接入阅读器窗口（与单页共存切换），加载调度（可见即载 + 向前 1 屏），模式切换按钮，CBZ 默认条带。
- DoD：单页回归零变化；`make generate && make build` 零警告；人工检查点（用户）：CBZ 百页连滚无错位/无闪退/内存稳定、快速滚动无陈旧错位、模式切换保留当前页、单页模式行为不变。

## 风险与回滚点

- 锚定重排的边界（首屏高度未定时的初始锚定、窗口 resize）——逻辑层测试必须覆盖。
- 大 CBZ（几百页）的滚动性能：虚拟化是唯一的防线，不做全量 slot。
- 回滚：锚点 v0.5.0；两 Step 独立 commit 可单独 revert；单页模式全程不受影响。

## Review 交接

按 WORKFLOW.md §5.2 Review Package，每 Step 单独提审。
