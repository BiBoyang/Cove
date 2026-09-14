# TASK: 视频缩略图（第一步：播放截帧 → 观看历史卡片封面）

- 状态：done（2026-09-14 收尾，Review Gate: Approved，真机验收通过）
- PROMPT：`/Users/boyang/code/Cove/prompts/TASK-video-thumbnails.prompt.md`

## 背景 / 现状

- 观看历史卡片（`RecentWatchCardItem`）只有静态 film 符号；浏览器/本地仓库视频行只有染色符号 badge（2026-09-13 用户验收反馈）。
- 已有图片缩略图管线：`ThumbnailService`（`Cove/Services/Media/ThumbnailService.swift`）→ CacheKit display 池 `thumb160` variant，浏览器图片行复用驱动加载。
- 视频侧资产：`VideoStreamBridge`（covesmb:// ranged read 桥）、`MPVPlayerCore`（@MainActor，有 seek，无现成截帧 API）。FFmpeg 自建链 `--disable-encoders` → `screenshot-to-file` 不可用，须走 `screenshot-raw`（client API 返 raw BGRA，不经 encoder）自包 CGImage。
- 历史决策：视频缩略图自 TASK-video-playback v1 起显式推迟；视频字节不进 CacheKit（只让产物 JPEG 进 display 池）；DESIGN-TOKENS §6.3 已预留缩略图行样式。
- 路线取舍（调查结论）：C（播放时顺手截帧，读路径只查缓存）先行——历史卡片 100% 覆盖、零额外 SMB 流量、SMB/vault 通吃、"封面=最后看到的一帧"与「已看至」语义一致；B（mpv 后台缩略图会话补浏览器未播视频行）留作后续卡；A（系统 API 仅 vault）跳过。

## 目标

观看历史卡片显示真实视频封面（= 该视频最后一次观看处的帧）；未覆盖场景保持 film 图标，不主动后台生成。SMB 与 vault 来源通吃。

## 拆解（Steps）

1. **Spike 验证（先行，不过则硬停止）**：确认本仓 libmpv 构建支持 `screenshot-raw` 命令返回 raw 帧（SMB 桥流 + vault 本地各验一次），`vd-lavc-dr=no` 下画面正确。
2. **记录扩展**：`PlaybackProgressStore` 的记录增加可选 `fileSize` / `modifiedDate`（Codable 向后兼容，旧记录缺字段可解析）；播放器在写进度时带上（播放器打开自 ContentItem，字段现成）。
3. **截帧写入**：播放器在进度持久化点与关闭时 `screenshot-raw` 当前帧 → BGRA raw 包 `CGImage`（仅 CoreGraphics，无新框架）→ `cropCenterSquare` → JPEG 入 CacheKit display 池，key = `CacheKey.sourceFile(sourceID:path:size:modified:variant:"vthumb320")`（320px，卡片 160pt@2x 用满，后续浏览器行可降采样复用）。
4. **读取接线**：`RecentWatchEntry` 带上 size/mtime；主页卡片注入只读 provider（查 display 池，命中淡入、未命中保持 film 图标，绝不主动生成）；旧记录缺字段时异步 `metadata(at:)` stat 补齐再算 key（有界，≤10 卡片）。
5. **测试**（Tests/CoveTests）：记录扩展迁移（旧 JSON 可解析）、写读 key 一致性（播放器写入 key == 卡片读取 key）、BGRA→CGImage 打包（合成 buffer）、卡片无图回退图标。

## DoD

1. 截帧链路 SMB / vault 各至少一条真路径验证通过（spike 记录入报告）。
2. 视频字节不进 CacheKit（只产物 JPEG 进 display 池）；不引入新框架/新三方依赖。
3. 旧观看记录无 size/mtime 时不崩、有回退；未播视频保持图标。
4. 新增测试通过；`make build` / `make test` 全绿；零并发警告；注释英文、UI 文案中文。
5. 改动仅限 PROMPT 白名单文件；无 git add / commit / push。
6. MVVM/并发规矩不破：MPVPlayerCore 的 MainActor 假设与编码/缓存的 detachment 显式区分。

## 风险与回滚

- 首要风险：`screenshot-raw` 在裁剪 FFmpeg 链或 hwdec 下不可用 → Step 1 spike 先行验证，失败即硬停止上报，路线退回 Planner 重议（备选：软解开关微调或改走路线 B 会话）。
- moov-at-end MP4 与本任务无关（不主动 demux，只截当前帧）。
- 性能：截帧发生在播放会话内已解码帧，成本 O(1)；读路径纯查盘。
- 回滚：写入路径可独立摘除（记录扩展字段保留无害），读路径摘除即回图标。
- 后续卡（不在本任务）：路线 B——mpv 后台缩略图会话补浏览器/本地仓库未播视频行，本卡验收后另行规划。

## Amendment 1（2026-09-13）：补截帧写入链路（范围扩大）

- 触发：第一轮 Executor（外部 glm5.3 会话）交付白名单内全部工作（spike 双路径实证 `screenshot-raw` 可用、写读两侧服务与测试落地、333 tests 全绿），在截帧接线处命中硬停止条件 2——mpv render context 指针只存在于 `MPVRenderShim.m`，不在原白名单。
- Planner 证据制复核通过（亲审 shim/服务 diff + 亲跑 make test）：机制分析属实——`screenshot-raw` 派发到 render context dispatch 队列，`mpv_render_context_update()` 是唯一排空点；现状 shim 设 ADVANCED_CONTROL=1 却从不调 update（契约缺口，顺带应修）。
- 范围扩大（新增白名单）：`MPVRenderShim.h/.m`（renderInCGLContext 补 update 排空 + MPVVideoLayer 增 drainRenderDispatch）、`MPVPlayerCore.swift`（captureCurrentFrame）、`PlayerViewModel.swift`（persist 点接线）、`VideoThumbnailService.swift`（BGRA 打包改行拷贝防 CG bytesPerRow 对齐垫）、相关测试文件。
- 续跑 PROMPT：`/Users/boyang/code/Cove/prompts/TASK-video-thumbnails-wiring.prompt.md`（status: dispatched）。
- 验收增量：播放中 persist 点与关窗各截帧成功；渲染画面无回归；BGRA 非对齐 stride 行拷贝测试。

### Amendment 1 闭环（2026-09-13，Review Gate: Approved）

- 续跑 done：shim 排空（renderInCGLContext 补 update + drainRenderDispatch 双层）、`captureCurrentFrame()`（独立 reply ID 空间 0xC0FFEE 起 + isCapturingFrame 防嵌套 wait_event + 250ms 有界轮询自驱排空）、VM 接线（persist 点 Task 延迟一拍出 drain 栈、关窗同步截帧先于 teardown、音频会话跳过）、BGRA 逐行拷贝加固、node→frame 纯函数解析，新增 7 用例。
- 白名单扩展追认：`LibraryCoordinator.swift` init 传 `thumbnailWriter: VideoThumbnailWriter(cache: cache)`（4 行）——续跑 PROMPT 本要求"writer 注入走 coordinator 既有组装范式"，而组合根就是 LibraryCoordinator（PdfReaderCoordinator(cache:) 先例），且该文件本就在本任务第一轮白名单内。Planner 予以追认。
- Planner 独立复核：diff 全审 + `make test` 亲跑 340 tests/54 suites 全绿 + spike 二进制亲跑 file 模式 SCREENSHOT_RAW_OK（像素图案校验通过、暂停态截帧可用）。
- 待办：真机用户验收（播放画面照常、卡片出封面、暂停+拖拽 resize 无花屏）→ 验收后随收尾提交并在 BACKLOG 登记。
