---
task: /Users/boyang/code/Cove/plans/TASK-video-thumbnails.md
status: dispatched
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：视频缩略图（播放截帧 → 观看历史卡片封面）

先读任务契约 `/Users/boyang/code/Cove/plans/TASK-video-thumbnails.md`（背景/路线取舍/拆解/DoD 以它为准），并遵守 `/Users/boyang/code/Cove/AGENTS.md` 硬性规矩（纯 AppKit、MVVM 边界、严格并发零警告、注释英文 UI 文案中文、ViewModel/Services 不出现 AppKit 类型——CGImage 可以）。

## 目标

一句话：观看历史卡片显示真实视频封面（最后一次观看处的帧），SMB/vault 通吃，未覆盖场景保持 film 图标。成功标准：下方 DoD 全过，`make build` / `make test` 绿。

## 涉及文件（绝对路径）

- /Users/boyang/code/Cove/Cove/Services/Media/PlaybackProgressStore.swift
- /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift
- /Users/boyang/code/Cove/Cove/Features/Player/Coordination/PlayerCoordinator.swift
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/HomeViewModel.swift
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/HomeViewController.swift
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
- /Users/boyang/code/Cove/Tests/CoveTests/PlaybackProgressStoreTests.swift
- /Users/boyang/code/Cove/Tests/CoveTests/ContinueWatchingTests.swift
- /Users/boyang/code/Cove/Tests/CoveTests/HomeDestinationTests.swift

允许新增至多 1 个服务文件（如 `Cove/Services/Media/VideoThumbnailCapture.swift`，若截帧/JPEG 入池逻辑不宜塞进既有文件）与 1 个对应测试文件；新增文件须在报告说明，且不需要动 project.yml（xcodegen 目录 glob——若实际需改则硬停止上报）。

禁止碰：`project.yml`、`plans/TASK-empty-states.md`、`prompts/TASK-empty-states.prompt.md`、`plans/TASK-video-thumbnails.md` 之外的 plans/prompts 文件；播放控制 UI、浏览器行（路线 B 地盘）。

## 验收标准（DoD）

1. Spike 先行：`screenshot-raw` 在本仓 libmpv 构建上对 SMB 桥流与 vault 本地各验证一次（附验证方式与结果）；不可用即硬停止。
2. 进度记录扩展可选 `fileSize`/`modifiedDate`，旧 JSON 向后兼容可解析；播放器写进度时带上。
3. 进度持久化点与播放器关闭时截帧 → BGRA→CGImage（仅 CoreGraphics）→ `cropCenterSquare`（ImagePipeline 既有）→ JPEG 入 display 池，variant `vthumb320`；视频字节不进 CacheKit。
4. `RecentWatchEntry` 带 size/mtime；主页卡片只读 provider 查 display 池，命中淡入、未命中保持图标；旧记录缺字段时异步 stat 补齐（≤10 卡片有界）。
5. 测试：记录迁移、写读 key 一致、BGRA→CGImage 合成 buffer、无图回退；`make build` / `make test` 全绿零并发警告。
6. 不执行任何 git add / commit / push。

## 上游任务产出

无（但依赖既有事实：CacheKit 双池与 `CacheKey.sourceFile` 五元组、`ImagePipeline.cropCenterSquare`/`encodeJPEG`、`ThumbnailProviding` 注入范式、`VideoStreamBridge`/`makeRangedFileReader`、`LocalFileSource.metadata(at:)` 均已在仓）。

## 执行提示

- 工作目录 `/Users/boyang/code/Cove`；开工前 `git status --short`（empty-states 两个既有未提交文件勿动）。
- 关键锚点：`ThumbnailService.swift`（variant 约定与 readGate/failed/inFlight 范式，头部注释 :18-20）、`MPVPlayerCore.swift:297-301`（seek 族）、`PlayerCoordinator.buildSession`（:262，progressKey 形态）、`LibraryCoordinator.swift:241-243`（视频字节不进 CacheKit 决策注释）、`HomeViewController.swift:258`（卡片 configure）。
- 播放器侧全是 @MainActor 假设；JPEG 编码/缓存写入学 ThumbnailService 下主线程（Task.detached utility）。
- `make test` 若遇 App target CodeSign 失败：增量重跑 → 仍失败 `make clean`（DerivedData 一次性腐坏，AGENTS.md 排障注记），不得改 project.yml。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）

1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件（含 project.yml）；
3. 测试/构建失败原因超出本任务描述范围；
4. Spike 证实 `screenshot-raw` 不可用。

## 上报格式

停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、spike 验证记录、自测命令与结果、已知风险 / 卡点描述。
