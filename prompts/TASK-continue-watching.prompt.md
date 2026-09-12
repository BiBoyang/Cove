---
task: /Users/boyang/code/Cove/plans/TASK-continue-watching.md
status: done（2026-09-13 Review Approved；真机验收过：启动落首页网格/深链续播/清理语义/高亮不变量）
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：Continue watching（idle 页最近播放，1.0 批 2 卡 2）

## 目标
idle 页展示「最近播放」卡片排（文件名+断点进度+上次观看），点击
自动 连接→share→目录→开视频 断点续播，SMB/vault 一视同仁。成功
标准 = TASK 文件（/Users/boyang/code/Cove/plans/TASK-continue-watching.md）
DoD 四条 + `make test` 全绿。TASK「Decisions」七条全部照做，不得
擅自变更。

## 现状锚点（均已核实）
- 存储 /Users/boyang/code/Cove/Cove/Services/Media/PlaybackProgressStore.swift：
  key="sourceID|path"、值 {position, lastWatched}（Double 字典）、
  LRU 200、UserDefaults「cove.playbackProgress.entries」；协议
  PlaybackProgressStoring 只三方法——allEntries 加在具体类（协议
  不动），duration 写入随 savePosition 扩参（调用点仅
  PlayerViewModel.persistProgress 一处，约 176 行）。
- 续播机制 /Users/boyang/code/Cove/Cove/Features/Player/ViewModels/PlayerViewModel.swift：
  attemptResumeIfReady（约 163 行）自动 seek——深链终点只是
  openPlayer，续播免费。
- 深链各段 /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift：
  openShare(:341)、navigateInto(:373)、openVault(initialPath:)(:465)、
  openPlayer(at:)(:863，guard 文件须 ∈ browserViewModel.videoItems)、
  navigationGeneration/activeTask 守卫（连接与导航都会代）、服务器
  配置经 sessionService.servers（ServerConfig.host 匹配 sourceID 的
  host 段）；alert 范式见 checkForUpdates 三态。
- idle 页 /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ShareGridViewModel.swift：
  showIdlePlaceholder（约 82 行）/ State.placeholder；VC 占位渲染
  /Users/boyang/code/Cove/Cove/Features/Servers/Views/ShareGridViewController.swift
  （约 80-115 行）——卡片排在占位页内组合呈现（有条目才显示）。
- 相对时间：share 卡片「最近打开」相对时间已有格式化帮手
  （ShareOpenStore 体系，Executor 自查复用，不新造）。
- 测试范式：PlaybackProgressStoreTests.swift 现有（LRU/读写），
  新用例入同文件；VM 用例入既有 Servers 相关测试文件或
  ViewModelTests.swift（Executor 就近，不新建测试文件之外的散件）。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Services/Media/PlaybackProgressStore.swift
  （改：duration 写入 + allEntries 只读 + 容忍旧格式）
- /Users/boyang/code/Cove/Cove/Features/Player/ViewModels/PlayerViewModel.swift
  （改：persistProgress 传 duration）
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/ShareGridViewModel.swift
  （改：recentWatches 状态 + RecentWatchEntry 纯函数解析——放此文
  件或同目录小文件，Executor 二选一并在上报说明）
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/ShareGridViewController.swift
  （改：idle 页卡片排组件 + onResumeWatch 转发）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
  （改：resumePlayback(entry:) 深链两路 + 失败清理 + 卡片刷新）
- /Users/boyang/code/Cove/Tests/CoveTests/PlaybackProgressStoreTests.swift
  （改：duration/旧格式/allEntries 用例）
- /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift 或就近
  Servers 测试文件（改：解析纯函数 + recentWatches 用例）
- 预期零新建源码文件则不跑 make generate；若确需新文件，先跑
  make generate 并在上报说明。README 由提交阶段同步。

## 验收标准（DoD）
见 TASK 文件 DoD 四条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性
规矩：禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency
零新警告（10）、SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、
测试 Tests/CoveTests 优先 Swift Testing（15）。

## 上游任务产出
- PlaybackProgressStore 记忆播放位置体系（v0.4.0 起在线）；
- 检查更新卡（32f825a 已入库）：协调器 alert/流程范式；
- 外挂字幕卡（8c4b3fd 已入库）：无依赖，仅批次顺序。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- 深链失败语义与手动连接一致（占位/alert 复用），不新增弹窗种类；
  条目清理只在「配置已删 / 文件不可达」两种确定失败时发生。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
