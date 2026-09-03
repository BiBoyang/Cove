# TASK: 视频播放 v1（libmpv + stream_cb 经自有 SMB 栈流式播放）

日期：2026-08-23 ｜ 协作模式（本会话规划/Review，另一会话实现）

## 目标复述

浏览器里双击视频文件，经 Cove 自己的 SMB 栈（`ContentSource.read(at:range:)` 范围读）流式播放，不落地整文件。v1 交付：能播、能暂停、能拖进度、能关。

## 决策记录（已拍板）

- **引擎：libmpv + `stream_cb.h` 自定义协议**。驳回 AVFoundation（格式只覆盖 MP4/MOV/M4V，分类表里的 mkv/avi/wmv/flv/rmvb 全是盲区，做出来是半个播放器）和 VLCKit（自带 SMB 会绕过整个 SourceKit 栈，自定义 access 比 stream_cb 笨拙，活跃度不如 mpv）。IINA 验证了 libmpv 在 macOS/AppKit 的可行性。
- **视频不进 CacheKit**：一部电影数 GB，进 20GB 图片缓存池会挤掉全部预热成果。v1 播放直连 `ContentSource` 范围读，缓冲靠 mpv 自带 cache。
- **AGENTS.md 第 8 条**：libmpv 作为新三方依赖，Step 1 落地时必须同步登记 AGENTS.md（用途：视频播放引擎）。
- **分期交付**：spike 先行——libmpv 集成是全项目迄今最大的不确定性，单独成步，不过不往下走。
- **Step 1 拍板（2026-08-23 补充）**：libmpv 获取走 A（`brew install mpv`，formula 已确认 `-Dlibmpv=true` + `meson install`，dylib 与 `include/mpv` 头文件齐备；dylibbundler 收集依赖闭包入 `Vendor/libmpv/`，改 `@rpath`，随包 ad-hoc 重签，**Vendor 入 git**）；A 受阻转 B（MPVKit 预编译 XCFramework，[mpvkit/MPVKit](https://github.com/mpvkit/MPVKit)），换路必须在提审时说明原因；应急源 `/Applications/IINA.app/Contents/Frameworks/`（全套 @rpath 布局）。
- **渲染路径拍板**：mpv render API（`MPV_RENDER_API_TYPE_OPENGL`）+ `CAOpenGLLayer` 背靠 NSView；GL deprecation 警告用带 `#pragma clang diagnostic ignored` 的薄 ObjC 文件吸收；`wid` 内嵌仅作兜底。
- **解码拍板**：`hwdec=auto-safe`——VideoToolbox 硬解优先，不支持的格式（wmv/flv/rmvb 等）由 mpv 自动回落 ffmpeg 软解，不为兼容性单独写分支。
- **NAS 实测归属**：Step 1 DoD 的 MP4/MKV 真实播放由用户人工执行；执行 agent 负责 `make build`/`make test` 通过并给出人工检查点清单。

## Out of Scope（v1）

- 记忆播放位置、倍速、字幕轨切换、音轨切换、画面比例、手势/快捷键、画中画。
- 视频缩略图、视频预热。
- 缓存优化（ CacheKit 接入评估留到 v1 实测有卡顿再议）。

## 现状摘要

- `ContentSource`（SourceKit）协议自带 `read(at:range:)` 范围读 + `metadata`——`stream_cb` 的 read/seek/size/close 回调可以一一映射。
- 浏览器双击路由已有 `onUnsupportedFile` 提示链路（`BrowserViewController` → `LibraryCoordinator` → 弹窗），`fileType == .video` 目前落入"不支持"——v1 把它改路由到播放器。
- 分类表 video 扩展名：mp4, mkv, avi, mov, wmv, flv, webm, m4v, ts, m2ts, mpg, mpeg, 3gp, rmvb。
- 工程约束：纯 AppKit、strict concurrency complete 零警告、注释英文/UI 中文、sandbox entitlements 存在（动态库加载要在 sandbox 下验证）。

## 已知技术关键点（spike 必须正面回答）

1. **libmpv 的获取与打包**：官方无 SPM 分发。候选：源码编译（可控但重）、社区 XCFramework（快但供应链要核实）、Homebrew dylib vendor 进包。spike 先选一条最短路跑通，记录选择理由。
2. **同步-异步阻抗**：`stream_cb` 的 read 是**同步阻塞** C 回调，`ContentSource` 是 async actor——桥接层需要在专用线程上同步等待异步读（semaphore/continuation 阻塞是标准做法），且不能死锁、不能堵主线程。这是本任务的技术核心。
3. **渲染接入**：mpv render API（OpenGL 在 macOS 已 deprecated 但可用；gpu-next/Metal 路径更新）。spike 选能跑通的最短路径，记录取舍。
4. **sandbox**：动态库加载与 mpv 的字体/缓存目录在沙盒下的行为要实测。

## Step 列表与 DoD

### Step 1（spike）：libmpv 集成验证

- 目标：最小播放器窗口，经 stream_cb → `ContentSource` 从真实 NAS 各播起一个 MP4 和一个 MKV，可播可停。
- 内容：libmpv 进工程（记录获取方式）；C 桥接层（stream_cb → ContentSource 的同步桥）；最小 NSWindow + 渲染视图；双击 video 临时接线（正式路由在 Step 2）。
- 允许 spike 代码粗糙，但桥接层的死锁/线程模型必须想清楚并写注释。
- DoD：
  1. MP4 和 MKV 各一个真实文件从 NAS 播起，画面正常、声音正常、可关闭；
  2. 拖动进度（mpv 内置 seek）不崩不死锁；
  3. AGENTS.md 登记 libmpv；`make build` 通过；
  4. spike 报告：三条关键点的结论（获取方式、同步桥模型、渲染路径），作为 Step 2 的输入。
- 若 spike 失败：停下来回 Plan，不硬闯。

### Step 2：播放器 UI + 正式接线

- 内容：`Features/Player/`（Coordinator + ViewModel + PlayerWindowController，沿用现有 Feature 模式）：播放/暂停、进度条（可拖）、音量、标题、关闭；`LibraryCoordinator` 把 `fileType == .video` 的双击从"不支持提示"改路由到 PlayerCoordinator；错误经现有 `onError` 链路上报。
- DoD：
  1. 播放控制全可用；打开第二个视频时前一个正确释放（mpv handle 销毁、桥接线程退出——资源有对应清理）；
  2. VM 层状态（播放中/暂停/缓冲中/错误）有测试；桥接层的读映射逻辑有测试（fake ContentSource）；
  3. `make generate && make build` 零警告、`make test` 全绿；
  4. 人工检查点（用户）：NAS 上 MP4/MKV 各播一部，拖进度、暂停恢复、关窗再开无异常。

### Step 3（可后置）：体验项

记忆播放位置（UserDefaults，按 sourceID+path）、空格暂停/方向键快进。做完 Step 2 后单独立任务单。

## 风险与回滚点

- **libmpv 打包是最大不确定性**：供应链（社区构建的可信度）、体积（dylib 几十 MB）、sandbox 兼容——Step 1 就是为此存在。
- **NAS 读模式**：mpv 的 readahead/cache 默认值对 SMB 延迟未必合适，卡顿时调 `cache`/`demuxer-readahead` 参数，不动自家代码。
- **回滚**：Step 1 spike 不进 main 以外无回滚负担；Step 2 接线 revert 即恢复"不支持提示"。

## 验证命令

```sh
make generate && make build   # 零警告
make test                     # 全量回归
```

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package。Step 1 的提审物额外包含 spike 报告（三条关键点结论）。
