# SPIKE: 视频播放 Step 1 — libmpv 集成验证报告

日期：2026-08-23 ｜ 对应任务单：plans/archive/TASK-video-playback.md ｜ Step 1（spike）

本报告回答任务单列出的三条关键点，作为 Step 2 的输入。

## 结论一：libmpv 获取方式 —— 路径 A 获取成功但功能受阻，转应急借用源（IINA 森林）

**最终采用：IINA.app 的 Frameworks 森林（mpv 0.38.0，通用二进制，GL 已启用）。**
换路原因（按任务单要求记录）：

1. 路径 A（brew）获取本身成功：`brew install mpv dylibbundler`，mpv 0.41.0_8，
   dylibbundler 闭包 48 dylib / 60MB，@rpath 改写与签名全部验证通过。
   **但** brew 版 mpv 的 `--gpu-api` 只有 vulkan（MoltenVK 路线），没编
   OpenGL render 支持——`mpv_render_context_create(OPENGL)` 必然失败
   （实测段错误，见结论三）。libmpv render API 只有 OpenGL 一种
   （`MPV_RENDER_API_TYPE_OPENGL`），无 Vulkan/Metal 变体，所以 brew 构建
   对本任务拍板的渲染路径不可用；要用 A 就得源码重编 mpv，超出 spike 范围。
2. 路径 B（MPVKit）核实后放弃：`libmpv-all.zip`（1.0.0，mpv 0.41.0）是
   **静态库**（libmpv.a 6MB），`nm` 确认不含 libass/libplacebo；其
   pkgconfig Requires 依赖 libass/libavcodec/libplacebo/luajit/uchardet/
   libbluray/vulkan 等一长串外部库，而该 release 资产里没有这些包，
   装配成本高且完整链不确定。
3. 应急借用源（任务单明列）：`/Applications/IINA.app/Contents/Frameworks/`
   —— 完整 @rpath 森林、GL 已编进（libmpv 链接 OpenGL.framework）、
   IINA 长期验证过的 macOS 生产配置。

Vendor 现状：

- `Vendor/libmpv/`：IINA 森林 73 个 dylib（117MB，universal arm64+x86_64），
  **剔除 `libswift_Concurrency.dylib`**——它会在链接期遮蔽工具链同名库导致
  Swift 符号缺失；运行期该库由 /usr/lib/swift 提供。
- 头文件用 brew mpv 0.41.0 的 `include/mpv`（libmpv client API 稳定，
  本工程只用到 0.33 之前就存在的 API：create/option/command/wait_event/
  stream_cb/render_*，0.38 ABI 全部覆盖）。
- `libmpv.dylib` 软链 → `libmpv.2.dylib` 供 `-lmpv`；森林内 @rpath 闭包
  完整性脚本验证通过；postBuild 拷贝 + 逐个 ad-hoc 重签不变。
- **环境坑（备查）**：本机 macOS 27 预发布版不被 brew 5.1.9（含最新 main）
  识别（SYMBOLS 最大 tahoe=26，install/--deps 抛 `:dunno`），且 brew.sh
  无条件用 sw_vers 覆盖 `HOMEBREW_MACOS_VERSION`；正解是
  `HOMEBREW_FAKE_MACOS=26.0`（os/mac.rb 的 full_version 优先读它）。
- **供应链注意**：Vendor 现为 IINA 签名二进制（构建时已被 postBuild 重签为
  ad-hoc）。正式版若要脱离 IINA 供应链，两条路：brew 源码重编
  （`-Dgl=enabled`）或装配齐 MPVKit 静态依赖。

## 结论二：同步桥线程模型 —— 按任务单规格落地，死锁论证成立

实现于 `Cove/Services/Media/VideoStreamBridge.swift`（线程模型、buffer 所有权、
已知开销均以英文注释写死在源码里）：

- mpv 在其 demuxer 线程上**串行**回调同一 stream 的 read/seek/size/close；
  桥不假设更多并发。
- `read_fn`：每开一个 stream 建 `StreamContext`（`Unmanaged.passRetained`
  cookie，close 时 release）。read 时快照位置、截到 EOF，起
  `ResultBox`（`@unchecked Sendable` 单写者）+ `DispatchSemaphore`，
  `Task.detached` 里 await 范围读闭包（经 `SMBReadRouter` 直接 hop 到
  `SMBSource` actor，不碰主 actor），写 box 后 signal；mpv 线程带 **30s
  超时** wait，唤醒后**自己**把 Data memcpy 进 mpv buffer 再返回字节数；
  超时/错误返回 -1，EOF 返回 0。
- 死锁论证：被阻塞的只有 mpv 自己的线程；async 工作调度到全局执行器，不依赖
  该线程；SMBSource actor 只被 await 从不被阻塞；主线程只发非阻塞 mpv 命令、
  经 wakeup callback（`DispatchQueue.main.async` + `MainActor.assumeIsolated`）
  收事件。
- buffer 所有权：Task 只写 box，绝不碰 mpv buffer；memcpy 只发生在 mpv 线程
  wait 返回之后——超时/关闭都不会 use-after-free；超时的 Task 只是往无人读的
  box 写结果。
- `seek_fn`：Mutex 保护的绝对位置更新（mpv stream seek 恒为 SEEK_SET），无 IO；
  `size_fn` 返回 `ContentItem.size` 快照；`close_fn` 置 closed 即返回，不 join
  在途 Task。
- 已知开销：每次 `SMBSource.read` = stat + range read 两次 SMB 往返；卡顿先调
  mpv 的 cache/demuxer-readahead，不在桥层加缓存。
- **大文件实测与加固（用户反馈"小文件能播、大文件不行"后）**：
  - 本地吞吐 harness（194MB@34.5Mbps 本地文件 + 模拟 10ms/RT）：mpv 开了
    cache 后按 **~9MB 大块**读（21×9.2MB 读满全片），2 秒内灌完
    1GiB demuxer 缓存——桥吞吐量不是瓶颈，`stream-buffer-size` 对该块
    大小无影响。
  - 尺寸截断假设排除：`ContentItem.size` 全链路 Int64。
  - AMSMB2 审计：`contents(atPath:range:)` 内部按 `maxReadSize` 分块
    （libsmb2 对超 max_read_size 的**单个**请求会硬报错，分块后不会触发）。
  - 剩余最可能根因：真实路径每次桥读 = open + fstat + ~1MiB 分块 pread +
    close ≈ 一打 SMB 往返，长视频累计数千次操作，**任一瞬时错误此前都直接
    -1 杀死播放**（小文件读少暴露低）。修复：`read_fn` 失败/超时现在**最多
    重试 3 次**（每次仍受 30s 上限与 close 唤醒约束），且超时/错误/慢读
    （>5s）全部落 TraceKit（category `VideoStream`，只记 offset/字节数/
    错误描述 .private，不记路径）——用户复现时日志即证据。
- URI：`covesmb://` + percent-encoded path，`mpv_stream_cb_add_ro` 注册；
  `open_fn` 零 IO（只校验 scheme 前缀）。
- strict concurrency complete 下零警告；无 `nonisolated(unsafe)`；
  `StreamContext` 是可检查 `Sendable`（全部可变状态在 `Mutex` 里），仅
  `ResultBox` 按规格 `@unchecked Sendable`。
- **配套改动**：`SMBSessionService` 新增 `makeRangedFileReader()`（+
  `SMBReadRouter.read(at:range:)`），与既有 `makeFileReader()` 同模式——
  整文件读闭包无法满足 mpv 范围读，此文件经用户拍板加入允许清单。

## 结论三：渲染路径 —— render API + CAOpenGLLayer 跑通（含一个真实崩溃的根因与修复）

- 按拍板：`MPV_RENDER_API_TYPE_OPENGL` + CAOpenGLLayer 背靠 NSView；
  GL 符号解析走 `CFBundleGetFunctionPointerForName(com.apple.opengl)`，
  不直接链 deprecated 的 OpenGL.framework。
- **关键根因之二（第二次闪退 → 本地复现定位）**：用 render API 必须显式
  `vo=libmpv`（在 `mpv_initialize` 前设置）。不设的话 mpv 仍按默认
  `vo=gpu-next` 自建 Vulkan 输出，vo 线程在 libplacebo 初始化里空调用
  段错误（用户栈：`vo` 线程 `mpvk_init → mppl_log_create → 0x0`）。
  本地复现程序二分验证：不设 `vo=libmpv` 必崩（exit 139），设了则
  file-loaded → end-file 全程存活。**这是 Step 2 必须保留的选项。**
- **关键根因之一（首次闪退 → 最小复现定位）**：mpv 拿到的 GL 符号是
  libGL 跳板，经**当前 CGL 上下文**分发；`mpv_render_context_create/free`
  内部会调 `glGetString` 等入口，**没有 current context 就直接空指针
  段错误**（lldb 定格在 `libGL.dylib glGetString`）。修复：shim 里
  `coveWithCurrentGLContext` 助手——创建/释放 render context 时先造一个
  临时 CGL context 置为 current，完事还原（IINA 同款做法）。最小复现程序
  验证：修复前 `Segmentation fault: 11`，修复后
  `render_context_create: 0 (success)`。
- deprecation 警告全部收进薄 ObjC 文件 `Cove/Services/Media/MPVRenderShim.h/.m`
  （`#pragma clang diagnostic ignored -Wdeprecated-declarations`），Swift 侧只
  见 `MPVVideoLayer: CALayer` 与 block 回调。
- `mpv_render_context_set_update_callback` → `dispatch_async` 主队列 →
  标脏重绘；layer `asynchronous = YES`；advanced control 开启并
  `mpv_render_context_report_swap`。
- **关键根因之三（黑屏有声 → 本地像素级复现定位）**：现代 macOS 上
  CAOpenGLLayer 的 drawable **不是 FBO 0**。此前向 FBO 0 渲染，mpv 的
  每次 render 都伴随 `GL_INVALID_FRAMEBUFFER_OPERATION`（glErr=0x506），
  画面恒黑而音频正常——与用户实测完全一致。本地验证程序用
  `glReadPixels` 回读 drawable 中心像素：修复前恒为 (0,0,0)。修复（对照
  IINA `ViewLayer.swift` 同款做法）：
  1. 渲染前用 `glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING)` 取真实 FBO
     （实测在 1/2/3/9… 间轮换，mpv render 结束后会解绑回 0）、
     `glGetIntegerv(GL_VIEWPORT)` 取真实尺寸，填进 `mpv_opengl_fbo`；
  2. `MPVVideoLayer` override `copyCGLPixelFormatForDisplayMask:` /
     `copyCGLContextForPixelFormat:`，把像素格式钉死为 3.2 Core +
     Accelerated + DoubleBuffer + BackingStore + AllowOfflineRenderers
     （与 shim 临时上下文共用同一属性表，mpv 探测与实绘同一 GL 人格）；
     **注意 CGL 对象不是 CFType，copy 语义下直接返回缓存对象即可，
     `CFRetain` 会在 `objc_retain` 里崩**（已踩过）；
  3. render 前 `glClear(GL_COLOR_BUFFER_BIT)` 保证未画区域恒黑。
  修复后回读中心像素 = (220,221,0)（测试视频内容），渲染真实落屏。
- **关键根因之四（关闭再开主线程卡顿 → harness 实测）**：
  `mpv_terminate_destroy` 会 join mpv 的 demuxer 线程；若该线程正 parked
  在桥的 `read_fn` 信号量里（NAS 卡顿时最长 30s），主线程就被拖死。
  用户"第二三个窗口无声"与此同源（关旧窗时主线程被 join 拖住）。
  修复：`StreamContext` 在 `Mutex` 里发布在途 `parkedRead` 信号量，
  `close()` 置 closed 并 signal 早醒（早醒后检查 closed 返回 -1，不
  memcpy）；桥新增 `cancelInFlightReads()`，`MPVPlayerCore.shutdown()`
  在 terminate **之前**调用。Swift harness（本地文件 + 人为 5s 慢读）
  实测：不 cancel terminate 延迟 4.83s，cancel 后 0.00s。
- **关键根因之五（关窗后 EXC_BREAKPOINT → 代码审计定位）**：用户实测"播放
  正常、关窗即崩"，栈定格在 `xzone_malloc` freelist 校验（无辜现场，说明
  堆在更早被破坏）。审计发现渲染 update 回调的 UAF 竞态：旧实现把
  `(__bridge void *)self`（MPVGLRenderer）当 cookie，回调在 mpv 线程上经
  它读 `updateHandler`；关窗时主线程 invalidate→free→`renderer = nil`→
  dealloc，而已在飞的回调照读已释放的 renderer——野指针读污染 malloc
  freelist，下一次无关分配（NSUserDefaults 字符串）时被 xzone 逮住，与
  用户栈完全吻合。修复：cookie 改为 **retained 的 MPVRenderUpdateBox**
  （只装 block），`CFBridgingRetain` 注册、`mpv_render_context_free`
  返回后才 `CFRelease`——mpv 只保证"free 之后无回调"，在飞回调因此总能
  看到活对象。
  - 配套更正：CAOpenGLLayer 的两个 copy override 改为真 copy 语义
    （`CGLRetainPixelFormat/CGLRetainContext` 出 +1，dealloc 只释放自有
    缓存引用）。备注：本地回读实验显示 CA 实际不释放拿到的对象（旧写法
    在迷你程序里也没崩，仅泄漏）；CGL 对象不是 CFType，`CFRetain` 会在
    `objc_retain` 崩——三种 retain 语义全部实测过。
- 生命周期硬约束已按文档实现：先 `mpv_render_context_free`（带临时 GL
  上下文），再 `cancelInFlightReads()`，再 `mpv_terminate_destroy`，
  最后桥 `detach()` 释放注册 cookie。
- **关键根因之六（大文件黑屏无声 → 本地全链路复现定位）**：用户实测"小的能播、
  4.9GB mpeg4 文件黑屏"。排查排除链：URI 编码（同名文件本地 probe 正常）、
  文件尺寸截断（全链路 Int64 + 浏览器显示 4.91GB 正确）、SMB 吞吐
  （smb-spike 实测 24MB/s ≈ 195Mbps，远超该文件 8Mbps 需求）、桥读模式
  （app 同款 cache 参数 harness 下 demux/读全程正常）。最终用完整渲染管线
  迷你程序复现：**file-loaded 后 vo/libmpv 永不 reconfig**——verbose 日志
  显示软解 mpeg4 走 vd_lavc **DR（direct rendering）**，分配 host-cached DR
  图像后 VO reconfig 卡死；h264 走 VideoToolbox 不经过 DR 所以正常。
  修复：`vd-lavc-dr=no`（MPVPlayerCore）。验证：修复后 video-reconfig →
  playback-restart → 中心像素非黑；h264 硬解路径回归无损。代价仅软解每帧
  一次 memcpy。**Step 2 注意：若未来升级 mpv 版本，可复测是否还需此开关。**
- **配套构建修复**：CoveTests 补 `CODE_SIGN_STYLE: Automatic` +
  `DEVELOPMENT_TEAM: ""`——测试包此前不跑 CodeSign phase，app 签名时拒绝
  PlugIns 里的未签名 xctest（此前偶过是因为 DerivedData 里残留了 Xcode GUI
  签过的旧包）。
- **spike 观测设施（保留到 Step 2 再决定去留）**：VideoStream 日志（open/
  seek/首读/每 128 读心跳/超时/失败/慢读>5s）与 Player 启动里程碑链
  （loadfile→file loaded→reconfig→playback restart）——本轮定位全靠它们。
- 未启用 `wid` 兜底。

## sandbox 实测记录

- **dylib 加载（已验证）**：`make test` 的 app 测试以 Cove.app 为 host 真实启动
  了主进程，`Cove.debug.dylib` 经 `@rpath/libmpv.2.dylib` 加载了 Vendor 森林
  （58 个 Frameworks 项全部 ad-hoc 签名验证通过），全程无加载失败——
  `** TEST SUCCEEDED **`。app 带 sandbox entitlement（app-sandbox +
  network.client，本次未改 entitlements）。
- **mpv 字体/缓存目录**：`config=no` 已让 mpv 不读用户配置；libass/fontconfig
  在沙盒内的字体扫描与缓存写入行为需人工播放时观察（mpv 日志已接到
  TraceKit，warn 级以上可见）。
- **sandbox denial**：需人工跑 app 时用
  `log stream --predicate 'process == "Cove"' --level debug` 或过滤
  sandboxd 观察；spike 预期 libass 字体缓存写 `~/.cache` 会被拒并回落
  （可接受，不为此开 entitlement）。

## Step 2 输入摘要

1. 桥（VideoStreamBridge）与渲染 shim 可直接复用，不粗糙；Step 2 只需在其上
   做正式 PlayerCoordinator/ViewModel/控制条。
2. 正式路由：把 `LibraryCoordinator.openSpikePlayer` 换成 PlayerCoordinator
   组装；`BrowserViewController.onOpenVideo` 闭包保持。
3. FBO 发现与 pixel format override 已是 IINA 同款实现，**不要回退成 FBO 0**；
   resize/Retina 迁移下的画面表现仍待人工确认。
4. teardown 顺序（invalidate → cancelInFlightReads → terminate → detach）是
   硬性约定，Step 2 换正式窗口控制器时必须原样保留。
4. 体积与供应链预算：Vendor 现为 IINA 森林 117MB（universal）。正式发布前
   建议二选一收敛：brew 源码重编 mpv（`-Dgl=enabled`，可控且新版）或装配
   MPVKit 静态依赖；两者都比"借用 IINA"更适合上架。

## 供应链收敛调研（2026-08-27 追加）

工程债小包期间对两条收敛路线做了现状核实，结论：**维持 IINA 森林，收敛仍排在上架前**。

- **brew 路线未被环境封死**：`HOMEBREW_FAKE_MACOS=26.0`（结论一环境坑节的正解）
  实测可用，`brew install --dry-run mpv` 正常返回。此前一次 dry-run 挂起是
  brew auto-update 走 GitHub 遇网络故障，加 `HOMEBREW_NO_AUTO_UPDATE=1` 即避开，
  与 `:dunno` 识别 bug 无关。真正的剩余工作是源码重编（`-Dgl=enabled`）——
  brew formula 无 options，需要本地改 formula 或手写 meson 构建链，工作量未变。
- **MPVKit 无进展**：最新 release 仍为 1.0.0（2026-07-25），即结论一核实过的
  同一批资产（libmpv.a 静态库、外部依赖链不随包），放弃理由不变。
- 切换 Vendor 后的回归成本（格式覆盖、字幕、seek、渲染）仍在，因此收敛动作
  本身不塞进日常工程债，保持"上架前必须"档位。
