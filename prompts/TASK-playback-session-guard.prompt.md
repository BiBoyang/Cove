---
task: /Users/boyang/code/Cove/plans/TASK-playback-session-guard.md
status: done
from: Planner
to: Executor (glmflash)
created: 2026-09-15
---

# 任务：Playback session guard（回首页/回网格不切在播流：延迟断开 + 三个随卡小修）

## 目标
在播视频时点侧栏「首页」或浏览器内退回 share 网格不再杀死播放：两处复位
把断会话推迟到播放器关窗（pending 标志 + 关窗补断），保住"回首页=干净状态"
不变量。随卡修三个 Minor：reveal 复用会话丢缩略图、信号量注册晚于派发、
截帧超时后迟到回复泄漏。
成功标准 = TASK 文件（/Users/boyang/code/Cove/plans/TASK-playback-session-guard.md）
DoD 五条 + `make test` 全绿 + `make build` 零警告。TASK「Decisions」五条全部
照做，不得擅自变更。

## 现状锚点（均已由 Planner 实证）
- 主修复 /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift：
  `resetToHomeState()`（:322-332）与 `backToShareGrid()`（:482-497）末尾均无条件
  `activeTask = Task { await sessionService.disconnect() }`（:331 / :496）——
  抽成私有方法按 Decisions 1 改造。playerCoordinator 回调装配处在 :184-185
  （onError/onMessageError 同款位置接 onSessionClosed）。connect 成功清标志点：
  openShare 的 :424 附近、resumeWatch 的 `!reusingSession` 分支（:896-908 内）
  与复用分支（:895 `reusingSession` 判定处起）。
- PlayerCoordinator /Users/boyang/code/Cove/Cove/Features/Player/Coordination/PlayerCoordinator.swift：
  `private var windowController: PlayerWindowController?`（:24）；
  `controller.onClose` 处理器（:93-101）内 `self.windowController = nil`（:100）
  之后触发新增的 onSessionClosed。
- Minor 1：resumeWatch 在 :887 无条件 `thumbnailProvider = nil`，:896-908 只在
  `!reusingSession` 分支内重装——把 :902-908 的 ThumbnailService 安装挪出分支，
  两路都装。
- Minor 2 /Users/boyang/code/Cove/Cove/Services/Media/VideoStreamBridge.swift：
  `attemptRead`（:250 起）先 `Task.detached`（:256-268）后
  `state.withLock { $0.parkedRead = semaphore }`（:272）——两行换位，先发布再派发，
  注释同步。
- Minor 3 /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift：
  超时路径 `capturedFrames[replyID] = nil`（:419）；drainEvents 的
  COMMAND_REPLY 分支（:763-776）无条件存帧——按 Decisions 4 加
  abandonedCaptureIDs 集合丢弃迟到帧。
- 测试落点：
  - 主修复：/Users/boyang/code/Cove/Tests/CoveTests/HomeDestinationTests.swift
    追加新 suite（OpenHomeResetTests 的 makeCoordinator 缝现成，照搬）。
    PlayerCoordinator 真窗口不可测，允许按 TASK「测试缝」给 LibraryCoordinator
    加 internal 可注入缝（playerHasActiveSession / requestSessionDisconnect）。
  - Minor 1：/Users/boyang/code/Cove/Tests/CoveTests/ContinueWatchingTests.swift
    追加（resume 复用分支后断言 thumbnailProvider 非 nil；缝不现成则改落
    HomeDestinationTests 并在提审时说明）。
  - Minor 3：/Users/boyang/code/Cove/Tests/CoveTests/VideoThumbnailTests.swift
    追加；drain 触不到允许提可测小方法（shouldStoreCaptureReply(replyID:)）。
  - Minor 2 不加新测试（竞窗不可自动化），确认既有 VideoStreamBridgeTests 不回归。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
- /Users/boyang/code/Cove/Cove/Features/Player/Coordination/PlayerCoordinator.swift
- /Users/boyang/code/Cove/Cove/Services/Media/VideoStreamBridge.swift
- /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift
- /Users/boyang/code/Cove/Tests/CoveTests/HomeDestinationTests.swift
- /Users/boyang/code/Cove/Tests/CoveTests/ContinueWatchingTests.swift
- /Users/boyang/code/Cove/Tests/CoveTests/VideoThumbnailTests.swift
- 不新建文件，无需 make generate；DESIGN-TOKENS.md 不动。

## 验收标准（DoD）
见 TASK 文件 DoD 五条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性规矩：
禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency 零新警告（10）、
SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、测试优先 Swift Testing（15）。

## 上游任务产出
- 无头续播（TASK-player-ux-trio，已归档）：resumeWatch 复用会话分支——本卡
  Minor 1 的所在；续播落地后"停在首页看视频"成为常态，正是本卡 Major 的
  碰撞面来源。
- 截帧封面（TASK-video-thumbnails，已归档）：captureCurrentFrame 超时路径——
  本卡 Minor 3 的所在。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git status --short` 确认在
  /Users/boyang/code/Cove；**禁止任何 git 写操作**
  （add/commit/checkout/restore/stash 一律不准）。
- 工作树若有既有未提交改动（本卡 plans/prompts 文件除外），叠加不搅动。
- 注释英文、UI 文案中文；本卡无新 UI 文案。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、
自测命令与结果（make test 计数 + make build 警告扫描）、已知风险 / 卡点描述。
