---
task: /Users/boyang/code/Cove/plans/TASK-subtitle-clearance.md
status: dispatched
from: Planner
to: Executor
created: 2026-09-14
---

# 任务：控制条可见时字幕自动抬升（sub-margin-y 路线）

先读任务契约 `/Users/boyang/code/Cove/plans/TASK-subtitle-clearance.md`
（背景/机制实证/Decisions/DoD/硬停止以它为准），并遵守
`/Users/boyang/code/Cove/AGENTS.md` 硬性规矩（纯 AppKit、MVVM 边界、
严格并发零警告、注释英文 UI 文案中文、ViewModel/Services 不出现
AppKit 类型）。

## 目标

一句话：控制胶囊可见时字幕自动抬到胶囊上方，隐藏时回落原底部位置。
成功标准：任务卡 DoD 全过，`make generate && make test` 全绿、
`make build` 零警告。

## 范围

只许动任务卡白名单内文件。sub-margin-y 基线必须先 get 后改
（禁写死 0）；胶囊高度由 View 层测量以 Double 喂 VM（VM 不写死
高度）；下发收敛单一 choke point + 同值去重。

## 环境

- `make test` / `make build` / `make generate` 需要在沙箱外跑
  （swift sandbox-exec 在沙箱内会挂），直接以提权方式执行。
- 新增测试文件后必须 `make generate` 再跑测试（CoveTests 走
  Xcode 工程，不是 SPM 目录扫描）。

## 回报

改动文件清单（绝对路径）、基线实测值、自测结果（test/build 数字）、
已知风险、是否命中硬停止。
