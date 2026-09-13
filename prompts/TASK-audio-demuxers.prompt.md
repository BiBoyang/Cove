---
task: /Users/boyang/code/Cove/plans/TASK-audio-playback.md
status: done（2026-09-13 森林重建 selfcheck 4/4 + 引擎探针七文件全通；真机 Owner 复验通过）
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：Audio demuxer 补链（音频播放 Fix 1，根因已实证）

## 目标
修复独立音频文件播放失败：FFmpeg 构建矩阵补音频 demuxer
（mp3,flac,ogg,wav,aac），本地重建森林，加约束级回归防回退。成功
标准 = TASK 文件（/Users/boyang/code/Cove/plans/TASK-audio-playback.md）
Fix 1 节四条 + 重建后 `make test` 全绿 + 真机 mp3/flac 可播。

## 根因（已实证，勿再排查方向）
/Users/boyang/code/Cove/scripts/build-libmpv.sh 的 FFMPEG_FLAGS
`--enable-demuxer=` 行只有视频容器+字幕，独立音频 demuxer 缺席；
decoder/parser 链已齐（mp3/mp3float/flac/opus/vorbis decoder 与
mpegaudio/aac/flac/opus/vorbis parser 均在矩阵内，无需动）。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/scripts/build-libmpv.sh（改：demuxer 行追加
  `mp3,flac,ogg,wav,aac`，注释同步一句；其余 flag 一律不动）
- /Users/boyang/code/Cove/Tests/CoveTests/AudioPlaybackTests.swift
  （改：增补约束用例——以 #file 定位仓库根，读 scripts/build-libmpv.sh
  文本，断言 demuxer 行含 mp3/flac/ogg/wav/aac；防再被裁回退）
- 不碰其他任何文件；plans/、prompts/ 不动。

## 执行步骤
1. 改脚本 demuxer 行。
2. 全量重建森林：`cd /Users/boyang/code/Cove && ./scripts/build-libmpv.sh`
   （约一二十分钟；结尾 selfcheck 四项——闭包洁净/GPL 指纹/GL 探针/
   签名——必须全过；森林在 gitignored Vendor/，不入库）。
3. `make build`（postBuild 重嵌 dylibs 进 App）。
4. 补约束用例后 `make test` 全绿（含 SourceKit 包）。

## 验收标准（DoD）
1. demuxer 行含且仅含新增五个音频 demuxer，其余 flag 零变化
   （git diff 单行级）。
2. 森林重建 selfcheck 四项全过，构建日志存底。
3. 约束用例通过且全量 `make test` 全绿、构建零警告。
4. 真机复核（Owner 或助手代办）：F 目录
   （/Users/boyang/Desktop/agents/字幕夹具/F/）Track01.mp3 与
   Track03.flac 双击可播、静态壳正常。
5. 遵守 /Users/boyang/code/Cove/AGENTS.md 硬性规矩。

## 上游任务产出
- TASK-audio-playback 主实现（同树未提交）：分类/路由/壳——本修复
  是其运行前提，同卡一并提交。
- libmpv 供应链卡（已归档）：构建矩阵与 selfcheck 机制来源。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- 禁止任何 git 写操作（add/commit/push/mv）。
- 重建森林是长任务，耐心等它结束，不要中途改脚本二次开工；若
  selfcheck 挂，带日志上报，不硬试。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 构建/测试失败原因超出本任务描述范围（含 selfcheck 非预期失败）。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果（含 selfcheck 四项与 make test）、
已知风险 / 卡点描述。
