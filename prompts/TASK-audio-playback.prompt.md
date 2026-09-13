---
task: /Users/boyang/code/Cove/plans/TASK-audio-playback.md
status: done（2026-09-13 Review Approved；真机 Owner 验收通过，含 Fix 1 补链后 mp3/flac 实播）
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：Audio playback（音频播放，1.0 批 2 末卡）

## 目标
分类表加 audio 类型，双击音频走既有 libmpv 桥播放，控制条全量
继承，无视频轨时静态壳（music.note + 文件名）替代裸黑窗。成功
标准 = TASK 文件（/Users/boyang/code/Cove/plans/TASK-audio-playback.md）
DoD 四条 + `make test` 全绿。TASK「Decisions」七条全部照做，不得
擅自变更。

## 现状锚点（均已核实）
- 分类表 /Users/boyang/code/Cove/Frameworks/SourceKit/Sources/SourceKit/ContentItem.swift：
  FileType enum + init(classifying:)（约 47-82 行，公共表 ComicKit
  共用）；测试 /Users/boyang/code/Cove/Frameworks/SourceKit/Tests/SourceKitTests/ContentItemTests.swift。
- 行映射 /Users/boyang/code/Cove/Cove/Features/Browser/Views/BrowserViewController.swift：
  placeholderTint（约 543 行 static，@testable 可测）与
  placeholderSymbol（约 727 行 private static in cell）——tint 用例
  范式见 ViewModelTests 既有 badgeTints 用例；handleDoubleClick 路由
  （约 522-531 行）增 .audio → onOpenAudio。
- 队列派生 /Users/boyang/code/Cove/Cove/Features/Browser/ViewModels/BrowserViewModel.swift：
  imageItems/videoItems（73-77 行）同款加 audioItems。
- 打开链路 /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift：
  openPlayer(at:)（约 863 行）改按 fileType 路由队列；onOpenVideo
  闭包接线处（约 121 行）旁加 onOpenAudio。
- 播放器 /Users/boyang/code/Cove/Cove/Features/Player/ViewModels/PlayerViewModel.swift：
  videoInfo: VideoTrackInfo?（55 行）与 videoInfoChanged 事件
  （123 行）——无视频轨判定缝候选 A；候选 B = MPVPlayerCore 的
  track-list（MPVTrackEntry type=video 计数，parse 在
  /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift 内，
  SubtitleTrack.parse 同款纯函数区）。二选一，上报说明。
- 静态壳与 chips /Users/boyang/code/Cove/Cove/Features/Player/Views/PlayerWindowController.swift：
  renderCodecChips（约 738 行）无视频轨时整组隐藏；静态壳参照
  renderStateOverlay（约 697 行）的 overlay 挂载点（below
  controlsCapsule），用 .symbol("music.note") 风格的居中呈现
  （可复用 StatePlaceholderView 但不许显示 spinner）。
- 令牌 /Users/boyang/code/Cove/Cove/SharedUI/CoveStyle.swift badgeTint
  令牌族 + /Users/boyang/code/Cove/design/DESIGN-TOKENS.md §1 登记表
  （badge-tint-* 行末追加 badge-tint-audio）。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Frameworks/SourceKit/Sources/SourceKit/ContentItem.swift（改：.audio + 分类表）
- /Users/boyang/code/Cove/Frameworks/SourceKit/Tests/SourceKitTests/ContentItemTests.swift（改：分类用例）
- /Users/boyang/code/Cove/Cove/Features/Browser/Views/BrowserViewController.swift（改：tint/symbol 映射 + 路由 + 闭包）
- /Users/boyang/code/Cove/Cove/Features/Browser/ViewModels/BrowserViewModel.swift（改：audioItems）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift（改：openPlayer kind 路由 + onOpenAudio 接线）
- /Users/boyang/code/Cove/Cove/Features/Player/ViewModels/PlayerViewModel.swift（改：无视频轨状态派生，如选缝 A/B 对应处）
- /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift（改：仅当选缝 B 时——hasVideoTrack 纯函数区）
- /Users/boyang/code/Cove/Cove/Features/Player/Views/PlayerWindowController.swift（改：静态壳 + chips 隐藏）
- /Users/boyang/code/Cove/Cove/SharedUI/CoveStyle.swift（改：badgeTintAudio 令牌）
- /Users/boyang/code/Cove/design/DESIGN-TOKENS.md（改：§1 登记）
- 测试落点：App 侧新用例若需落 ViewModelTests.swift 或
  PlayerViewModelTests.swift 之外的文件，新建
  /Users/boyang/code/Cove/Tests/CoveTests/AudioPlaybackTests.swift
  并跑 make generate；零新建源码文件。
- README 由提交阶段同步。

## 验收标准（DoD）
见 TASK 文件 DoD 四条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性
规矩：禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency
零新警告（10）、SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、
测试 Tests/CoveTests 优先 Swift Testing（15）。

## 上游任务产出
- 视频播放全链（v0.4.0 起）+ 播放器传输包/字幕轨开关/外挂字幕
  （均已入库）：本卡全部长在其上，不重构任何播放既有语义。
- 继续观看卡（在途/已入库）：openPlayer kind 路由即两卡整合点
  （Decision 3），不许动其 recentWatches/深链代码本身。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- 若 ViewModelTests.swift 在本派工时仍被并行任务占用（开工 git
  status 可见 Others' in-flight 改动），App 侧全部新用例一律落
  AudioPlaybackTests.swift 新文件，不抢写。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
