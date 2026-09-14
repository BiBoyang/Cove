---
task: /Users/boyang/code/Cove/plans/TASK-video-thumbnails.md
status: done
from: Planner
to: Executor
created: 2026-09-13
---

# 任务：视频缩略图 · 续跑（截帧写入链路与接线）

这是**同一任务的第二轮**（Amendment 1，范围已经 Planner 扩大）。先读任务契约 `/Users/boyang/code/Cove/plans/TASK-video-thumbnails.md`（含 Amendment 1）与 `/Users/boyang/code/Cove/AGENTS.md` 硬性规矩。

## 工作树基线（重要）

第一轮交付**已在未提交工作树中**，禁止 `git checkout / revert / clean` 任何既有改动，在其上续写：

- 已就位：`Cove/Services/Media/VideoThumbnailService.swift`（BGRAVideoFrame / VideoThumbnailStore / Writer / Reader）、`PlaybackProgressStore` 可选 fileSize/modified 字段 + `setFileFacts`、PlayerCoordinator 标注接线、主页卡片封面井与 RecentWatchThumbnailReader 注入、`Tests/CoveTests/VideoThumbnailTests.swift` 等测试，333 tests 全绿。
- 未就位（本轮目标）：从 mpv 取帧并交给 Writer。
- 勿动：`plans/TASK-empty-states.md`、`prompts/TASK-empty-states.prompt.md`（其他任务的在途改动）。

## 目标

一句话：播放中进度持久化点与关窗时各截当前帧，经 `VideoThumbnailWriter` 入 display 池，主页卡片出现真实封面。成功标准：下方 DoD 全过，`make build` / `make test` 绿。

## 涉及文件（绝对路径）

- /Users/boyang/code/Cove/Cove/Services/Media/MPVRenderShim.h
- /Users/boyang/code/Cove/Cove/Services/Media/MPVRenderShim.m
- /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift
- /Users/boyang/code/Cove/Cove/Services/Media/VideoThumbnailService.swift
- /Users/boyang/code/Cove/Cove/Features/Player/ViewModels/PlayerViewModel.swift
- /Users/boyang/code/Cove/Cove/Features/Player/Coordination/PlayerCoordinator.swift（仅当接线确需）
- /Users/boyang/code/Cove/Tests/CoveTests/PlayerViewModelTests.swift
- /Users/boyang/code/Cove/Tests/CoveTests/VideoThumbnailTests.swift

禁止碰：`project.yml`、`PlayerWindowController.swift`（persistProgressOnClose 已在 VM 内，无需动窗口层）、`plans/TASK-empty-states.md`、`prompts/TASK-empty-states.prompt.md`、其他 plans/prompts 文件。

## 验收标准（DoD）

1. `MPVRenderShim.m`：`renderInCGLContext` 在 `CGLSetCurrentContext` 之后调 `mpv_render_context_update(_renderContext)`——修 ADVANCED_CONTROL=1 的契约缺口，播放中的截帧回复随层重绘自然排空；不得改变现有渲染行为（忽略返回 flags，照原样渲染）。`MPVVideoLayer` 增 `drainRenderDispatch`（置自身 CGL context 为当前 → renderer update → 恢复原 context），`.h` 同步声明（含 renderer 侧所需的小方法）。
2. `MPVPlayerCore.swift`：`captureCurrentFrame() -> BGRAVideoFrame?`——`mpv_command_node_async` 发 `screenshot-raw`（参数须为字符串 `"video"`/`"bgra"`，OPT_CHOICE 不收 int）；**暂停态无重绘，轮询必须自驱 drainRenderDispatch** + 复用现有 `drainEvents` 消费 MPV_EVENT_COMMAND_REPLY；node 内存在下次 wait_event 即失效，须当场拷贝出 width/height/stride/byte-array；有界轮询（建议 ≤250ms 超时返回 nil，降级为无封面，永不阻塞主线程或终止流程）。
3. `PlayerViewModel.swift`：在 `persistProgress(_:)` 与 `persistProgressOnClose()` 落库点触发截帧（position>0 时），帧连同该条目的 sourceID/path/fileSize/modified 交给 `VideoThumbnailWriter.store`；关窗顺序须保证截帧发生在 render context/handle 拆除之前（与进度落库同点即可）。writer 注入走 coordinator 既有组装范式，测试假桩天然跳过。
4. 加固（Planner 复核 Minor）：`VideoThumbnailStore.cgImage(from:)` 改**逐行拷贝**并尊重 `context.bytesPerRow`（CGContext 可能把请求 bytesPerRow 向上对齐垫，flat memcpy 在非对齐 stride 下会花图）；补一个非 16 字节对齐 stride 的合成 buffer 测试。
5. 截帧回复的 node→BGRAVideoFrame 解析提成纯函数并配单测（合成 node 结构）。
6. `make build` 零警告、`make test` 全绿（含既有 333 测试无回归）。
7. 不执行任何 git add / commit / push。

## 上游任务产出

第一轮：spike 双路径实证（`build/spike-screenshot/`，可复用：A 阶段复刻"只 render 不 update"证实回复挂起，B 阶段补 update 后成功）、写读两侧服务与测试（见工作树基线）。机制备忘：`screenshot-raw` → VOCTRL_SCREENSHOT → vo_libmpv.control() 派发到 render context dispatch 队列并挂起 core 线程，`mpv_render_context_update()` 是唯一排空点且需调用线程持有当前 GL context。

## 执行提示

- 工作目录 `/Users/boyang/code/Cove`；开工 `git status --short` 应与基线一致（8 改 + 2 新增 + empty-states 两个 + 本任务 plans/prompts）。
- 锚点：`MPVRenderShim.m:132-171`（renderInCGLContext）、`:198-264`（MPVVideoLayer/_context）、`MPVPlayerCore.swift:554`（drainEvents）、`PlayerViewModel.swift:182-194`（persist 点）、`VideoThumbnailService.swift:56-78`（打包函数）。
- 真机/spike 验证渲染无回归：补 update 后播放画面必须照常（spike 二进制可复跑；app 侧留日志或断点证据）。
- `make test` 若遇 App target CodeSign 失败：增量重跑 → 仍失败 `make clean`（DerivedData 一次性腐坏，AGENTS.md 排障注记），不得改 project.yml。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）

1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件（含 project.yml、PlayerWindowController.swift）；
3. 测试/构建失败原因超出本任务描述范围；
4. 补 update 后播放渲染出现回归且 3 次内修不回。

## 上报格式

停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、截帧验证证据（播放中 persist 点 / 关窗各一条）、自测命令与结果、已知风险 / 卡点描述。
