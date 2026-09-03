# TASK: A2 递归预热（预热按钮从单层升级为含子目录）

日期：2026-08-23 ｜ 协作模式（本会话规划/Review，另一会话实现）

## 目标复述

工具栏预热按钮从单层枚举（`FolderEnumerator.listImages`）升级为递归枚举（`FolderEnumerator.collectImages` BFS，含子目录），A2 已建立的进度语义（N/M 精确）与取消语义在递归下原样成立。

## 决策记录（已拍板）

- **两阶段（方案 A）**：先递归枚举完，再一次性入队。枚举期 UI 显示"预热中…"（`total=0` 分支已存在），枚举完 total 确定后走现有 N/M 进度。驳回流式边枚举边入队的理由：BFS 枚举是元数据 list（秒级到十几秒级），下载才是分钟级；流式要动 FolderEnumerator 接口 / PreheatService 状态 / Progress 模型 / VM 状态机四层，为枚举期反馈不值。若后续实测大目录枚举确实慢，流式作为增量演进，接口现在不定型。
- **上限沿用 `maxFiles=5000` / `maxDirectories=1000`**，不放宽。缓存容量才是真实约束，防爆阀不在没数据时调大。
- **撞顶可见性**：完成状态携带 `truncated` 标记，完成文案显示"预热完成（已达 5000 张上限）"。驳回"仅记日志"——静默截断会制造"全预热完了"的虚假信心；也驳回"加独立 UI 状态"——一个字段 + 一个文案分支即可。

## Out of Scope

- LRU pinning、相邻页自动预取、递归深度自定义、连续条带 Reader。
- 流式枚举入队（方案 B，仅作为未来增量演进的备案）。
- 上限值的调整。

## 现状摘要

- `PreheatService.preheatDirectory(path:)`（`Cove/Services/Preheat/PreheatService.swift`）当前调 `FolderEnumerator.listImages`（单层）；`collectImages`（BFS 递归，带 maxDirectories=1000 / maxFiles=5000 上限）现成且有测试，被 userFolder 预热使用。
- 取消链路已就位且有测试背书：枚举 task cancel + `PreheatScheduler.cancel(priority: .currentDirectory)` 定向清队列，不伤 userFolder。
- 进度链路：`directoryPreheatProgress()` 返回 `DirectoryPreheatProgress`（total/remaining/failed/throughput，`total=0` 表示枚举中），VM 轮询驱动按钮三态与进度标签。
- `BrowserViewModel.PreheatButtonState` 四态：unavailable / ready / preheating / finished(failed)。

## Step 列表与 DoD

### Step 1：能力层——切换递归枚举 + 撞顶标记

- 改动文件：
  - `Cove/Services/Preheat/PreheatService.swift`
  - `Tests/CoveTests/PreheatServiceTests.swift`
  - 可能涉及 `Frameworks/PreheatKit/Tests/PreheatKitTests/FolderEnumeratorTests.swift`（见下）
- 内容：
  1. `preheatDirectory` 内 `listImages` → `collectImages`（沿用 maxFiles/maxDirectories 上限）。
  2. 记录本次提交是否撞顶（`images.count == maxFiles` 判定），透传进 `DirectoryPreheatProgress`（加 `truncated: Bool` 字段，完成时 UI 用）。
  3. 顺手补 `collectImages` 取消行为单测（现有缺口）：BFS 中途 cancel，枚举停止、不再产出。
- DoD：
  1. `PreheatServiceTests` 新增：带子目录的 fake source，断言递归预热提交了子目录图片；撞顶时 `truncated == true`。
  2. `FolderEnumeratorTests` 新增取消用例。
  3. `make test` 全绿、`make build` 零警告（strict concurrency complete）。

### Step 2：UI——完成文案携带撞顶提示

- 改动文件：
  - `Cove/Features/Browser/ViewModels/BrowserViewModel.swift`
  - `Cove/Features/Browser/Views/BrowserViewController.swift`（如标签文案由 View 拼接）
  - `Tests/CoveTests/ViewModelTests.swift`
- 内容：
  1. `finished` 状态携带 `truncated`；完成文案分支："预热完成" / "预热完成（N 个失败）" / "预热完成（已达 5000 张上限）"（及其组合，取最简实现）。
  2. 按钮 tooltip/accessibilityDescription 更新为"预热此文件夹（含子文件夹）"。
- DoD：
  1. VM 状态机测试更新：finished 携带 truncated 的断言。
  2. `make generate && make build` 零警告、`make test` 全绿。
  3. 人工检查点：含子目录的文件夹点预热 → 进度总数含子目录图片；预热中再点 → 停止；预热中切目录/开阅读器 → 自动取消；撞顶场景（可用小上限临时验证）完成文案带"已达上限"。

## 风险与回滚点

- 行为变化即任务本身：预热范围单层→递归，量级可达数千张、分钟级下载；防爆由 maxFiles/maxDirectories 兜底。
- 取消响应粒度：`collectImages` 只在 BFS 循环边界（每目录一次）检查取消；单个 `source.list` 慢时取消延迟到该调用返回——userFolder 链路已接受此粒度，沿用。
- 枚举期无数字反馈是已接受的取舍（见决策记录）；实测若不可接受，升级为流式（方案 B）。
- 回滚：Step 1 单点改动，revert 即恢复单层；Step 2 独立可 revert。

## 验证命令

```sh
make test                    # Step 1/2 全量回归
make generate && make build  # Step 2，零警告
```

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package 格式，附：Step 编号、改动文件列表、关键 diff 摘要、自测命令与结果、已知风险。每个 Step 单独提审，不跨步混改。
