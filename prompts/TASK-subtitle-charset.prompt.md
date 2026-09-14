---
task: /Users/boyang/code/Cove/plans/TASK-subtitle-charset.md
status: dispatched
from: Planner
to: Executor
created: 2026-09-14
---

# 任务：外挂字幕 GBK/BIG5 渲染为空 —— Step 1 诊断 spike

先读任务契约 `/Users/boyang/code/Cove/plans/TASK-subtitle-charset.md`
（背景/已实证事实/假设集/实验矩阵/DoD/硬停止以它为准），并遵守
`/Users/boyang/code/Cove/AGENTS.md` 硬性规矩。

## 本轮范围（只诊断，不修复）

- 写 spike：新文件只许落在 `/Users/boyang/code/Cove/build/spike-subtitle/`
  （git 未跟踪区），dlopen 驱动 `/Users/boyang/code/Cove/Vendor/libmpv/`
  里的自构建 libmpv；参照
  `/Users/boyang/code/Cove/build/spike-screenshot/screenshot_raw_spike.c`
  的 dlopen/编译/用法注释模式。
- 夹具只许落在 `/tmp/`：`iconv` 合成 GBK/BIG5 字幕变体，
  `say`+`afconvert` 合成 wav 媒体（字幕解码与视频无关）。
- 跑任务卡里的实验矩阵 1–6 + verbose 日志（7）+ 参照系对比（8，
  若本机有 brew mpv 或 IINA）。
- **git 跟踪文件零改动**。完工时 `git status` 必须干净。

## 回报要求

按任务卡 DoD 给：矩阵观测表（如实，空就是空）、verbose 日志关键行、
复现确认、H1–H4 钉死了哪个、推荐修复路线（A/B/C 或新路线）+ 理由。
命中任何硬停止条件立即停手回报，不许带病前进，不许顺手修。

## 环境提示

- 编译 spike 用 `cc`，include 路径 `Vendor/libmpv/include`，dlopen
  运行时解析 dylib 路径（截图 spike 同款做法，直接抄）。
- mpv C API：`mpv_observe_property` 观察 `sub-text`
  （MPV_FORMAT_STRING）；`mpv_command` 发 `sub-add`；选项用
  `mpv_set_option_string`（init 前）。
