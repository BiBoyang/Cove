---
task: /Users/boyang/code/Cove/plans/TASK-external-subtitles.md
status: done（2026-09-12 助手自助真机验收通过：外挂自动挂载/弹层标识/切集重发现/置灰/temp 清理全过；GBK 编码渲染为空观察项已登 BACKLOG 远期）
from: Planner
to: Executor
created: 2026-09-12
---

# 任务：External subtitles（外挂字幕，1.0 批 2 首卡）

## 目标
打开/切集视频自动发现同目录同名外挂字幕（srt/ass），temp-file +
sub-add 挂载并默认选中，弹层带「外挂」标识可切换/关闭。成功标准 =
TASK 文件（/Users/boyang/code/Cove/plans/TASK-external-subtitles.md）
DoD 四条 + `make generate && make test` 全绿。TASK「Decisions」九条
全部照做，不得擅自变更。

## 现状锚点（均已核实）
- 字幕纯值层 /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift：
  SubtitleTrack（约 66 行）/ MPVTrackEntry（约 81 行）/ parse（约 98
  行）/ displayName（约 117 行）——MPVTrackEntry 增 external: Bool，
  track-list node walk（observeProperties 解析处）多读一个 external
  布尔；displayName 对外挂轨加「外挂」后缀；command(_:)（约 308 行）
  是 sub-add 的既有出口；setSubtitle(trackID:)（约 288 行）范式可仿。
- 加载通道 /Users/boyang/code/Cove/Cove/Services/Media/VideoStreamBridge.swift：
  RangedReader 类型别名（约 50 行）= @Sendable (String,
  Range<Int64>) async throws -> Data；协议承诺 range 超 EOF 截断，
  单次 read(0..<32MB) 即全量。
- 播放器编排 /Users/boyang/code/Cove/Cove/Features/Player/Coordination/PlayerCoordinator.swift：
  open(items:selectedPath:sourceID:reader:)（约 46 行起）与
  buildSession(item:)（moveTo 约 123-136 行经它换 session）——
  外挂发现+挂载挂 buildSession 之后（loadfile 发出后立即 sub-add，
  小步验证；不可靠则回退首个 file-loaded 事件，上报说明）；
  session 替换/窗口关闭（onClose 约 67 行）是 temp 目录清理点。
- 上层接线 /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift：
  openPlayer(at:)（约 863 行）——browserViewModel.state.items 即
  全量 siblings 快照源；makeRangedFileReader() 经
  SMBSessionService.readRouter 统一路由 SMB/vault 两态（无需本地
  路径特判）。
- 弹层组件 /Users/boyang/code/Cove/Cove/Features/Player/Views/PlayerWindowController.swift
  OptionListPopoverController（约 1095 行）——标签来自
  SubtitleTrack.displayName，组件本身不动。
- 测试范式 /Users/boyang/code/Cove/Tests/CoveTests/SubtitleTrackTests.swift：
  parse/displayName 纯值用例所在，不回归 + external 新用例。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Services/Media/ExternalSubtitleLoader.swift
  （新建：SubtitleDiscovery 纯函数 + bytes→temp loader，reader 注入；
  session 临时目录创建/清理）
- /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift
  （改：addExternalSubtitle(path:) 薄封装 + MPVTrackEntry/SubtitleTrack
  external 标记 + node walk 多读 external + displayName 后缀）
- /Users/boyang/code/Cove/Cove/Features/Player/Coordination/PlayerCoordinator.swift
  （改：buildSession 后外挂发现+挂载流程；session 替换/关闭清理）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
  （改：openPlayer 捕获 siblings 快照 + provider 接线）
- /Users/boyang/code/Cove/Tests/CoveTests/ExternalSubtitleTests.swift
  （新建：discovery 纯函数 + loader temp 生命周期用例）
- /Users/boyang/code/Cove/Tests/CoveTests/SubtitleTrackTests.swift
  （改：external 标记用例）
- 两个新文件跑 `make generate` 入库；README 由提交阶段同步。

## 验收标准（DoD）
见 TASK 文件 DoD 四条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性
规矩：禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency
零新警告（10）、SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、
测试 Tests/CoveTests 优先 Swift Testing（15）。

## 上游任务产出
- plans/archive/TASK-subtitle-track-picker.md（2026-09-08）：内嵌轨
  开关全链（track-list 观察/parse/弹层）——本卡直接长在其上；
  sub-auto 协议不可行结论即出自该卡，不要再试 sub-auto。
- 播放器状态 overlay / Up Next / 播放模式体系：不触碰。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- 外挂加载失败一律静默记日志（host/path 用 .private），永不阻塞
  播放、永不弹窗。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
