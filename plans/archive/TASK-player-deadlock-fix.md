# TASK: Player deadlock fix（截帧楔死四环死锁：命令异步化 + 超时救援驱动）

- Status: done（2026-09-15 收尾，Review Gate: Approved 含 Amendment 1，
  真机验收 a-e 通过；make test 384/59 全绿零警告）
- Created: 2026-09-15
- 触发：2026-09-15 11:05 真机卡死，sample 实证四环死锁
  （notes/review/hang-sample-2026-09-15.txt）——09-14 "GL context 理论竞争
  窗口"观察项实爆

## 根因（sample 实证，2026-09-15）

死锁四环（notes/review/hang-sample-2026-09-15.txt）：
1. 主线程：方向键 seek → MPVPlayerCore.command（:726 mpv_command）→
   run_client_command → mp_dispatch_lock 条件等待——等 mpv core 的
   dispatch 锁；
2. mpv core 线程：run_playloop 内正在执行 cmd_screenshot_raw →
   screenshot_get → vo_control → mp_dispatch_run——等 VO 线程；
3. mpv vo 线程：control → mp_dispatch_run——等主线程驱动 GL 渲染
   （libmpv render API 的渲染派发由主线程 drainRenderDispatch 驱动）；
4. 主线程已被 1 堵死 → VO 的渲染请求永远无人服务 → 永久死锁。

触发链：暂停/周期 persist → PlayerViewModel.captureThumbnail（:291-300）
→ captureCurrentFrame（MPVPlayerCore.swift:382-421）发 screenshot-raw →
暂停态图层不重绘，VO 等主线程渲染 → 250ms 超时主线程放弃返回
（abandonedCaptureIDs 只修了迟到回复的内存面，mpv core 仍卡在截图
命令里）→ 用户按键 → 同步 mpv_command 撞上被占锁 → 全灭。

实证名实不符：command(_:)（:718-731）注释自称 "Non-blocking"，
mpv_command 在 core 卡顿时实为同步阻塞。

## Decisions（Owner 2026-09-15 拍板①+②全做，Executor 照做）

1. **命令异步化（拆主线程引信）**：command(_:) 改 mpv_command_async
   （Vendor/libmpv/include/mpv/client.h:991 现成），fire-and-forget——
   现有 11 个调用点（:310/:314/:319/:324/:334/:339/:348/:350/:374/:385）
   本就"失败只记日志"语义，异步化语义不变；mpv 命令队列保序。
   错误观测：async 的 COMMAND_REPLY 带 error 字段，在 drainEvents 的
   COMMAND_REPLY 分支补日志（captureReplyBase 以下的 userdata 即命令
   错误回复）。修正 :718 的 "Non-blocking" 注释名实问题。
   硬性要求 R1：主线程任何路径不再同步阻塞等 mpv。
2. **超时救援驱动（解 wedge 本身）**：captureCurrentFrame 超时后不得
   放任 VO 渲染请求悬挂——启动有界救援：主 actor 异步循环（约 100ms
   一拍，硬上限约 2s）驱 videoLayer.drainRenderDispatch() + drainEvents()，
   迟到回复落地（abandonedCaptureIDs 中该 ID 被 drain 消费）或到上限即停。
   硬性要求 R2：mpv core 不得因截帧永久楔死。
3. **关窗路径防 join 楔死（②的必然延伸）**：persistProgressOnClose 的
   同步截帧若超时，core.shutdown() 必须推迟到救援完成之后——
   mpv_terminate_destroy join 楔死线程会复刻同款死锁。
   允许的形态：captureCurrentFrame 报告是否超时（返回二元信息或新增
   只读属性），PlayerViewModel 透传，PlayerWindowController.windowWillClose
   在超时情形改为 Task { await 救援完成; core.shutdown() }；
   关窗语义（onClose 回调、进度落盘）不得改变。
   硬性要求 R3：关窗不得在楔死状态 terminate。
4. 测试缝：救援循环的"驱动一拍 + 停止判定"抽成可注桩方法（如
   rescueStep/abandoned 集合判定注入），直测两态（回复落地即停、
   硬上限即停）；命令异步化无直测，靠既有 381 用例全量回归。

## Out of scope
渲染架构大改（GL 挪线程）；screenshot 换 vo=image 等路径（路线 B spike
的事，独立）；Reader/Preheat 侧架构。

## Steps
1. command 异步化 + COMMAND_REPLY 错误日志 + 注释修正。
2. 救援驱动（超时触发、有界、落地即停）。
3. 关窗路径：超时则救援后 shutdown。
4. 测试 + 验证：make test 全绿 + make build 零警告。

## DoD
1. R1/R2/R3 三硬性要求全部落地，改动不越白名单。
2. 新测试：救援两态（落地即停/上限即停）；`make test` 全绿。
3. `make build` 零警告（strict concurrency 硬规矩）。
4. 零回归：seek/暂停/音量/倍速/字幕/sub-margin 行为不变；既有测试不回归。
5. 真机验收（交 Owner）：
   a. 暂停视频数秒（触发 persist 截帧）→ 立即连按方向键/空格 → 不卡死；
   b. 暂停放置 1 分钟 → 再操作 → 不卡死；
   c. 暂停态直接关窗 → 不挂、进度与封面照常落盘；
   d. 正常播放回归：起播/seek/音量/下一集倒计时（含空格暂停）正常。

## Risks
- 命令异步化后错误只能经 COMMAND_REPLY 观测：日志已覆盖，无 UI 语义变化。
- 救援期间用户关窗：救援循环须判 isShutdown 即停，不得驱动已拆的
  render context（R3 的 Task 编排要守住这个顺序）。
- 上限 2s 仍未落地（极端）：放弃并记日志，core 可能仍楔——但 R1 保住
  主线程，关窗走 R3 上限后照常 terminate（join 风险留在日志观察项）。

## Amendment 1（2026-09-15，Planner 复核追加，Owner 授权 subagent 自调度）

- 触发：Executor 上报标记 install()（PlayerWindowController.swift:485-489）
  残留同款楔形——persistProgressOnClose → shutdown 同步串联，暂停中手动切
  下一集即可复刻死锁。Planner 亲验属实。
- 处置：install 头部接 persist 返回值，超时则旧 core 的 shutdown 推迟到
  救援完成（Task { await outgoing.waitForCaptureRescue(); outgoing.shutdown() }），
  新 session 立即上马；非超时路径逐字不变。R3 不变量「不在楔死态
  terminate」从关窗扩到换集，两处全覆盖。
- 验证：make test 384/59 全绿（Amendment 前后两轮亲跑）+ make build 零警告。
- 真机验收追加 e 项：暂停中手动点「下一个」切集 → 不挂、新集正常起播。

## 验收记录（2026-09-15，Owner 真机亲验）

- a 暂停后快速连按方向键/空格 → 不卡死（原死锁触发链）：通过
- b 暂停放置 1 分钟后再操作 → 不卡死：通过
- c 暂停态直接关窗 → 正常关闭、进度落盘：通过
- d 正常播放回归（起播/seek/音量/倒计时空格暂停）：通过
- e 暂停中手动切下一集（Amendment 1 覆盖路径）→ 不挂、新集起播：通过
