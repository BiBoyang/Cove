---
task: /Users/boyang/code/Cove/plans/SPIKE-headless-video-thumbnail.md
status: dispatched
from: Planner
to: Executor (glmflash)
created: 2026-09-15
---

# 任务：SPIKE Headless video thumbnail（无窗截帧可行性验证，路线 B 前置）

## 目标
验证没有可见窗口时 mpv screenshot-raw 能否截出有效帧，为浏览器未播视频
封面（路线 B）主卡提供可行性结论与设计输入。成功标准 = TASK 文件
（/Users/boyang/code/Cove/plans/SPIKE-headless-video-thumbnail.md）DoD 五条。
**这是验证性 spike，不是功能卡**——产出是报告与实证，不追求可上线形态。
动手前先通读 TASK 文件全文。

## 现状锚点（均已由 Planner 实证）
- /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift：
  自建 `videoLayer = MPVVideoLayer()`（:176）；init(:239) 建桥与 renderer
  （:294-301）；captureCurrentFrame()（:382-421）暂停态自驱
  drainRenderDispatch——离屏候选路径 A 的全部现成件。
- /Users/boyang/code/Cove/Cove/Features/Player/Views/PlayerWindowController.swift：
  窗口侧仅经 VideoLayerHostView（:184）挂载 layer——离屏=不挂载。
- 测试材料：/Users/boyang/Desktop/cove-test-materials/clip.mp4（本地，
  RangedReader 闭包直接 FileHandle/Data 喂，不走 SMB）。
- 报告格式先例：/Users/boyang/code/Cove/plans/archive/SPIKE-video-playback.md
  （结论先行 + 每路径实证 + 换路原因记录）。

## 涉及文件（绝对路径）
- 允许新建：/Users/boyang/code/Cove/Tests/CoveTests/HeadlessCaptureSpikeTests.swift
  （本卡唯一允许新建的源码文件；新建后跑 `make generate`）
- 报告：/Users/boyang/code/Cove/plans/SPIKE-headless-video-thumbnail.md（改写）
- MPVPlayerCore.swift 仅在路径 A 必须时允许最小临时改动，报告中逐条说明。
- 不动其他文件。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 三条候选路径（离屏不挂载 / vo=null / vo=image）全不通——路线 B 终止；
2. 测试 bundle 托不起 libmpv 且 scratch 方案也失败；
3. 需要改动上述清单之外的文件（MPVPlayerCore 最小改动除外，须报告说明）。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git status --short` 确认在
  /Users/boyang/code/Cove；**禁止任何 git 写操作**。
- 工作树若有既有未提交改动（plans/prompts 除外），叠加不搅动。
- 注释英文；报告中文。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、三路径结论摘要、成本数据、
主卡设计建议、已改动/新建文件列表、自测命令与结果、已知风险。
