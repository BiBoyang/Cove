# SPIKE: Headless video thumbnail（路线 B 前置：无窗截帧可行性验证）

- Status: done（2026-09-21 实证闭环：路径 A 通，B/C 不通，路线 B 立项闸门过；
  Executor: codex。首次派发（glmflash）未执行，报告与工件本次补齐）
- Created: 2026-09-15
- 触发：2026-09-14 session 遗留"视频缩略图路线 B（mpv 后台缩略图会话补浏览器
  未播视频行）"；Owner 2026-09-15 点题并拍板 spike 先行——headless 截帧
  不通则止损，不通则路线 B 不立项

## 要回答的问题

浏览器里未播视频目前恒 film 图标（BrowserViewController.swift:705 只对
.image 请求缩略图、:732 视频恒 film.fill）。路线 B 要用后台 mpv 会话给
这些视频截帧存池。写路径唯一未经验证的环节：**没有可见窗口时
screenshot-raw 能否出帧**。本 spike 回答三件事：

1. **可行性**：三条候选路径哪条能从本地视频文件截出有效 BGRA 帧
   （非全零、宽高符合预期、像素非纯色错误帧）：
   - 路径 A：MPVPlayerCore 原样用——它自建 videoLayer
     （MPVPlayerCore.swift:176），窗口侧仅挂载（PlayerWindowController
     .swift:184 VideoLayerHostView）；离屏=创建 core 后永不挂载，
     seek 到 5s 后调 captureCurrentFrame()（暂停态自驱
     drainRenderDispatch 的路径 :396-421 现成）。
   - 路径 B：mpv 选项 `vo=null` + screenshot-raw（预期不通，记录实证）。
   - 路径 C：mpv `vo=image` 或等价零窗口 VO + screenshot-raw（不通则记录）。
2. **成本**：单帧截取的耗时（建 core→seek→出帧全链路）与内存增量——
   决定主卡队列节奏（串行单飞是否够用）。
3. **主卡设计输入**：复用 MPVPlayerCore 原样 / 抽轻量 headless core /
   需对 MPVPlayerCore 做哪些最小改造。

## 边界与方法

- 测试材料：本地文件即可，不走 SMB——VideoStreamBridge 的 RangedReader
  是闭包，用 FileHandle/Data 直接喂
  /Users/boyang/Desktop/cove-test-materials/clip.mp4（现成）。
- 落点：允许新建一个 spike 文件（建议
  /Users/boyang/code/Cove/Tests/CoveTests/HeadlessCaptureSpikeTests.swift，
  本卡唯一允许新建的源码文件）；若测试 bundle 托不起 libmpv 运行时
  （dylib 森林拷贝/签名问题），改 scratch 可执行方案并在报告中记录。
- 若路径 A 需要对 MPVPlayerCore 做最小改动才能离屏（如可选不建
  renderer），允许临时改动但必须在报告中逐条说明——主卡再定正式形态。
- 环境依赖强的 spike 用例若不适合常驻 CI，标注 .disabled 或条件跳过，
  make test 必须保持全绿。
- **硬停止**：三条路径全不通 → 停止上报，路线 B 终止（不硬试第四条）。

## 产出

报告写入 /Users/boyang/code/Cove/plans/SPIKE-headless-video-thumbnail.md
（本文件即任务单，报告追加于下或直接改写 Status 区），内容按
SPIKE-video-playback 先例：结论先行 + 每路径实证记录 + 成本数据 +
主卡设计建议（读侧 provider、串行队列节奏、预热车道接线、取消语义）。

## DoD
1. 三路径均有实证记录（通/不通 + 证据）。
2. 可行路径给出：单帧耗时、内存增量、帧有效性核验方式。
3. 主卡设计建议一段（含"复用 vs 新建 core"的明确推荐与理由）。
4. `make test` 全绿（spike 用例按上文处理）；`make build` 零警告。
5. 无 git 写操作。

---

# SPIKE 报告（2026-09-21，Executor: codex）

## 结论先行

**路线 B 可行，闸门过。** 无可见窗口时能从本地视频截出有效 BGRA 帧，
可行配方 = 复用 MPVPlayerCore + 两个必要条件：
**hwdec=no（软解）× 预建 GL 上下文**，会话形状**一视频一核**。
素材 `/Users/boyang/cove-audit-media/纪录片/城市夜景.mp4`
（任务卡指定的 clip.mp4 实为 0 字节占位，已替换并在此报备）。

## 每路径实证记录

工件：`Tests/CoveTests/HeadlessCaptureSpikeTests.swift`（5 用例，
`make test` 全绿 389/60；日志行前缀 SPIKE-REPORT）。

| 路径 | 配置 | 结果 | 证据 |
|---|---|---|---|
| A1 对照 | 原样（hwdec=auto-safe，无 GL 上下文） | **不通** | frame=nil，250ms 超时；mpv 日志「Input image format videotoolbox not supported by libswscale」→「Error when converting image」 |
| A2 变量 1 | hwdec=no，无 GL 上下文 | **不通** | frame=nil，超时（captureDidTimeOut=true）；截图命令快速报错落地非楔死，shutdown 安全（0.9s 全程） |
| A3 变量 2 | hwdec=no + prepareHeadlessGLContext | **通** | 帧 1280x720 stride=5120 3,686,400 字节，与 videoInfo 一致，采样 4096 像素非全零非纯色；单次延迟 220–260ms 贴 250ms 上限有抖动，重试收敛 |
| B | 裸句柄 vo=null + screenshot-raw | **不通** | PLAYBACK_RESTART(event 21) 到达后命令悬挂：5s+ 无 COMMAND_REPLY（事件流水 6→8→17→21→0…） |
| C | 裸句柄 vo=image + screenshot-raw | **不通** | 同样悬挂无回复；vo-image-outdir 产物 0 个 |

关键机理（为什么是两个必要条件的乘积）：

1. **像素格式**：VideoToolbox 硬解帧是 videotoolbox 格式（CVPixelBuffer
   引用），screenshot-raw 的软转换走 swscale，不支持该格式。App 播放
   窗口内截帧不受影响——那时渲染派发有持续 GL 渲染穿插，mpv 走 GL
   辅助路径；headless 会话没有这个穿插，必须 hwdec=no 让帧落内存。
2. **GL 上下文**：截图任务排在 mpv 渲染上下文的派发队列上，唯一排水
   口是 `mpv_render_context_update`，且要求调用线程持有当前 GL 上下文。
   图层上下文是 CAOpenGLLayer 懒建的（copyCGL* 钩子只在真实绘制时
   触发），无窗口则永不建立——`drainRenderDispatch` 空转。预热一次
   即可（`prepareHeadlessGLContext`，生命周期与图层一致）。

## 成本数据（720p 素材，M 系本机）

- 建 core（mpv_create+init+render context）：≈3–10ms
- load→首帧配置+seek 就位：≈240–270ms
- 单帧 capture：≈220–260ms（内含 4ms 轮询节拍；首截含截图管线懒初始化
  ——swscale 上下文/FBO/读回），**紧贴 250ms 超时上限，单次成败有抖动**
  （09-21/22 五轮互有胜负）；超时后救援拍继续驱动派发队列，**第二次
  尝试暖态仅 ~120–130ms**（09-22 两轮实测 attempts=[#1 timeout 252ms,
  #2 ok 120–130ms]），间隔 350ms 重试即收敛（测试内最多 3 次）
- **单视频全链路 ≈0.5–1.5s**（含 1–3 次截帧尝试）；内存增量 7–38MB
  （含解码缓冲与 3.7MB 帧体，随会话 teardown 回收）
- 同核多帧未实证阻塞（成败同样服从上述抖动），但路线 B 本来一视频
  一文件，会话制是自然形状

## 主卡设计建议

1. **复用 MPVPlayerCore，不抽轻量 headless core**。mpv 选项矩阵、事件
   泵、VideoStreamBridge 全在现实现里，重写必漂移。需要的最小改造已
   以临时形态落地（正式形态主卡定夺）：
   - `MPVPlayerCore.init(bridge:extraOptions:)`（默认空字典，App 调用
     点不受影响；缩略图会话传 ["hwdec": "no"]）；
   - `-[MPVVideoLayer prepareHeadlessGLContext]`（MPVRenderShim +~15
     行，建会话时调一次）。
2. **会话形状：一视频一核，串行单飞**。节奏按 ~1.5s/视频上限排
   （含重试余量），适合闲时/预热车道跑；截帧要自带重试（250ms 上限对
   headless 偏紧，最多 3 次、间隔 350ms 让救援拍驱动派发），或主卡把
   captureCurrentFrame 的超时做成可配（headless 给到 1s）。同核多文件
   顺序截未实证阻塞，但会话制更干净：取消=shutdown，无跨文件状态。
3. **读侧 provider**：capture 成功 → `VideoThumbnailStore.cgImage` →
   JPEG 存 display 池 `vthumb320`（VideoThumbnailService 写侧与
   `cacheKey(sourceID:path:fileSize:modified:)` 公式现成，与播放窗
   截帧共用同一条目）；浏览器未播视频行查池，miss 保持 film 图标。
   注意 fileSize/mtime 齐备才能出 key——浏览器行 stat 已有该数据。
4. **接线**：走 PreheatScheduler 的车道模型派生缩略图会话（与主车道
   隔离 SMB 竞争）；可见区滚动取消 = `core.shutdown()`（渲染上下文先
   invalidate 的顺序现成；截帧超时楔死风险已由 2026-09-20 死锁修复
   的救援驱动覆盖）。
5. **测试资产驻留**：spike 用例即路线 B 的回归探针（素材缺失时
   自动跳过）；B/C 的不通断言被推翻时（libmpv 升级等）测试会红，
   提示重评更省的路径。

## DoD 对账

1. 三路径实证记录 ✓（上表，A 拆三个变量组）。
2. 可行路径成本 ✓（冷帧 220–250ms、全链路 ≈0.5s、内存 7–38MB、
   帧核验 = 几何/全零/纯色三检）。
3. 主卡设计建议 ✓（上文，明确推荐复用）。
4. `make test` 全绿（389/60，含本 spike 5 用例）；构建零警告 ✓。
5. 无 git 写操作 ✓（全部改动留工作区，commit 与否由 Owner 定）。

## 改动清单（2026-09-22 Owner 拍板转正）

- `Cove/Services/Media/MPVRenderShim.h/.m`：`prepareHeadlessGLContext`
  声明+实现（~15 行，缩略图会话建核后调一次）。
- `Cove/Services/Media/MPVPlayerCore.swift`：init 加 `extraOptions`
  默认参数（~8 行，PlayerCoordinator 原调用不受影响）。
- `Tests/CoveTests/HeadlessCaptureSpikeTests.swift`：新建（任务卡允许
  的唯一新文件；兼作路线 B 回归探针，素材缺失时自动跳过）。
