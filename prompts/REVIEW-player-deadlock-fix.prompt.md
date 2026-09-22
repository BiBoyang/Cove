---
task: /Users/boyang/code/Cove/plans/archive/TASK-player-deadlock-fix.md
status: dispatched
from: Planner
to: Executor (glmflash)
created: 2026-09-20
---

# 任务：REVIEW player-deadlock-fix 未提交工作线（提交前独立复核）

## 目标
对工作区里**未提交**的 TASK-player-deadlock-fix 改动做一次独立 code
review，给出 commit-ready / needs-fix 裁定。背景：该线 2026-09-15 标记
done（Review Gate Approved 含 Amendment 1，真机验收 a-e 通过），但从未
提交，Owner 已忘记完成细节。Planner 已于 2026-09-20 做完机械验证：
构建零警告、全量测试 384/59 全绿（与任务卡声称精确一致）。**你的任务
是判断层复核，不是重跑测试。**

## 复核范围（git diff 未提交改动，绝对路径）
- /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift
  （+121，救援驱动核心：captureRescueBeatMillis/captureRescueMaxBeats、
  rescueTask、captureDidTimeOut、rescueStep/startCaptureRescue/
  waitForCaptureRescue/runCaptureRescue）
- /Users/boyang/code/Cove/Cove/Features/Player/ViewModels/PlayerViewModel.swift
  （+31：captureDidTimeOut 协议属性、persistProgressOnClose 改返 Bool）
- /Users/boyang/code/Cove/Cove/Features/Player/Views/PlayerWindowController.swift
  （**仅 install() 与 windowWillClose() 两个 hunk**；该文件其余已提交
  内容不属于本线，是 HEAD commit 3dc47e0 的标题截断修复，勿混入）
- /Users/boyang/code/Cove/Tests/CoveTests/VideoThumbnailTests.swift（+64）
- /Users/boyang/code/Cove/plans/BACKLOG.md（+1 归档行）

## 重点检查点
1. **救援驱动并发语义**：rescueTask 生命周期（泄漏 / 重复启动 / 取消
   竞态）；captureDidTimeOut 的读写线程域；waitForCaptureRescue 的
   等待者语义（多个等待者、无救援在跑时调用）。
2. **defer shutdown 路径**：install() 的 Task 捕获 outgoing 无 weak
   与 windowWillClose() 的 weak self 差异是否有意；onClose 延迟到救
   援完成后触发对 coordinator 释放 controller 的影响；~2s 上界
   （100ms×20 beats）的推导是否成立。
3. **范围对账**：diff 是否完整覆盖 BACKLOG 归档行声称的三件事（mpv
   命令全量异步化 + 截帧超时救援驱动 + 关窗/换集不在楔死态
   terminate），有无任务卡之外的夹带改动。
4. **测试对账**：三个新增测试（迟到回复落地即停 / 硬节拍上限 / 取消
   即停）是否对应真实失效路径，有无明显未覆盖的分支。
5. **时间戳对账**：工作区文件 mtime 应均 ≤2026-09-15；若发现之后的
   改动，说明存在 post-review 未审编辑，列为重点审查对象。

## 参考材料（绝对路径）
- 任务卡：/Users/boyang/code/Cove/plans/archive/TASK-player-deadlock-fix.md
- 死锁实证 sample：/Users/boyang/code/Cove/notes/review/hang-sample-2026-09-15.txt
- 对照已提交改动：git show 3dc47e0（不属本线）

## 硬停止条件（命中任一即停并上报）
1. 发现 blocker 级并发缺陷——停止，输出缺陷报告，**不修代码**；
2. 需要超出只读范围的动作（改代码、跑真机、起 App）——停止上报。

## 协作纪律
- 纯只读 review：禁止编辑文件、禁止任何 git 写操作；允许
  git diff / log / show 等只读命令。
- 开工先 `pwd && git rev-parse --show-toplevel && git status --short`
  确认在 /Users/boyang/code/Cove。
- 报告中文。

## 上报格式
- 裁定（commit-ready / needs-fix）+ 一句话理由；
- 发现列表：按 blocker / major / minor / nit 分级，每条带 文件:行号
  与证据；
- 范围对账结论：diff 与任务卡声称是否一致；
- 若 commit-ready：附建议的 commit message（遵循仓库 conventional
  风格，如 fix(player): ...）。
