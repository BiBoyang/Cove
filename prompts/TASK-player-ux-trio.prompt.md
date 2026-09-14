---
task: /Users/boyang/code/Cove/plans/TASK-player-ux-trio.md
status: done
from: Planner
to: Executor
created: 2026-09-14
---

# 任务：播放体验意见三连（EOF 重播 / 续播单视频队列 / 历史卡片路径+打开文件夹）

先读任务契约 `/Users/boyang/code/Cove/plans/TASK-player-ux-trio.md`
（背景/已实证事实/Steps/DoD/硬停止/白名单以它为准），并遵守
`/Users/boyang/code/Cove/AGENTS.md` 硬性规矩（纯 AppKit、MVVM 边界、
严格并发零警告、注释英文 UI 文案中文、VM/Services 不出现 AppKit
类型——CGImage 可以、SnapKit 只在 View）。

## 目标

三个 Step 全部落地且各自 DoD 过：`make generate && make test` 全绿、
`make build` 零警告。Step 间独立可验，建议按 1→2→3 顺序小步提交
工作区（但**零 git 写操作**，成果留在工作树由 Planner 统一处理）。

## 环境

- `make test` / `make build` / `make generate` 需要提权执行（沙箱内
  swift sandbox-exec 会挂），不要 workaround。
- 新增测试文件后必须 `make generate` 再跑测试（CoveTests 走 Xcode
  工程，不是 SPM 目录扫描）。

## 回报

按 Step 分组：改动文件清单（绝对路径）、关键 diff 摘要、「无待跳转」
接线选型说明（Step 1）、自测结果（test 数字 / build 警告数）、
已知风险、是否命中硬停止。
