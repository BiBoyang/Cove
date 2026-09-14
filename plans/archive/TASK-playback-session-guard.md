# TASK: Playback session guard（回首页/回网格不切在播流：延迟断开 + 三个随卡小修）

- Status: done（2026-09-15 收尾，Review Gate: Approved，真机验收 a/b/c 通过；
  d 证伪结果：倒计时时按空格无反应——倒计时不受空格干预，按既定节奏走完，
  记为已证伪观察项非缺陷；make test 372/57 全绿零警告）
- Created: 2026-09-15
- 触发：2026-09-14 GLM 代码审查报告，Planner Review Gate 7/7 证据链亲验成立；
  无头续播（TASK-player-ux-trio）让"停在首页看视频"成为常态，「首页」键设计上
  幂等可重复点，碰撞面被放大——Major，立即出卡

## 根因（2026-09-15 代码实证）

**Major：回首页/回 share 网格无条件切断在播流。**
`LibraryCoordinator.resetToHomeState()`（Cove/Application/Coordination/
LibraryCoordinator.swift:322-332，断开点在 :331）与 `backToShareGrid()`
（:482-497，断开点在 :496）末尾均无条件执行
`activeTask = Task { await sessionService.disconnect() }`：
readRouter.update(nil) 之后播放器下一次 read 必死。在播视频时侧栏点
「首页」（或浏览器内退回 share 网格）= 视频暴毙。

**Minor 1：reveal 复用会话丢缩略图。** `resumeWatch` 在 :887 无条件
`browserViewController.thumbnailProvider = nil`，但 :896-908 只在
`!reusingSession` 分支内重装 ThumbnailService——复用会话的无头续播落地后
浏览器缩略图全灭。

**Minor 2：信号量注册晚于派发。** `VideoStreamBridge.attemptRead`
（Cove/Services/Media/VideoStreamBridge.swift:256-272）先 `Task.detached`
派发读取，:272 才把 `parkedRead` 发布进 state——微秒级竞窗内
close/cancelInFlightReads 看不到这个 parked read，极端时序下 mpv 线程
骑满 30s readTimeout（直接抬高 mpv_terminate_destroy 的 join 延迟）。

**Minor 3：截帧超时后迟到回复泄漏。** `MPVPlayerCore.captureCurrentFrame`
超时路径只留 `capturedFrames[replyID] = nil` 占位，而 drainEvents 的
COMMAND_REPLY 分支（:763-776）无条件 `capturedFrames[replyID] = frame`
存原始 BGRA（1080p≈8MB / 4K≈33MB）；reply ID 只增不复用，迟到帧永久驻留。
触发罕见（超时才会放弃），但一次就是几十 MB。

## Decisions（Plan Card 拍板，Owner 已回 o 全按推荐，Executor 照做）

1. **主修复=延迟断开（不是跳过）**：
   - PlayerCoordinator 增 internal 只读 `hasActiveSession: Bool`
     （`windowController != nil`）与 `var onSessionClosed: (() -> Void)?`，
     在 `controller.onClose` 处理器内 `self.windowController = nil` 之后触发。
   - LibraryCoordinator 增 `private var pendingPlayerSessionDisconnect = false`；
     把 resetToHomeState/backToShareGrid 末尾的无条件断开抽成一个私有方法
     （如 `disconnectNowOrAfterPlayerClose()`）：`playerCoordinator.hasActiveSession`
     为真 → 置 pending 标志、本次不断开；为假 → 立即断开（原行为逐字保留）。
   - 在 playerCoordinator 回调装配处（LibraryCoordinator.swift:184-185 同款位置）
     接 `onSessionClosed`：pending 为真 → 清标志 + 补断
     （`activeTask = Task { await sessionService.disconnect() }`）。
   - **重连/复用必须清标志**：`sessionService.connect(to:share:)` 成功处
     （openShare 的 :424 附近与 resumeWatch 的 `!reusingSession` 分支）以及
     resumeWatch 的复用分支（复用的正是可能被挂起的同一会话）落地后清
     pending——挂起的补断只属于"离开时的那个会话"，新会话不该替它死。
     注释写明这条不变量。
   - 不变量保持：回首页=干净状态（导航/标题/缩略图注入照清），只是把
     "断会话"这一件事推迟到播放器关窗；关窗即回到完全干净。
   - 否决项"跳过即了事"不采用：预热会一直啃一个用户已离开的 share。
2. **Minor 1**：resumeWatch 的 ThumbnailService 安装（:902-908）挪出
   `if !reusingSession`，两个分支都装（复用分支 sourceID 现成）。约 3 行位移。
3. **Minor 2**：attemptRead 把 `state.withLock { $0.parkedRead = semaphore }`
   提到 `Task.detached` 之前——先发布再派发。安全性：先发布时若 close 抢先
   signal，wait 立即返回成功但 box.result 为 nil，落到既有
   `guard case .success` 的 else 返回 nil，无害。注释同步（发布必须先于派发，
   否则 close/cancel 可能错过唤醒）。
4. **Minor 3**：MPVPlayerCore 增 `private var abandonedCaptureIDs = Set<UInt64>()`；
   超时路径 `abandonedCaptureIDs.insert(replyID)`（原 `capturedFrames[replyID] = nil`
   占位无人读取，可删）；drainEvents COMMAND_REPLY 分支存帧前先
   `if abandonedCaptureIDs.remove(replyID) != nil { break }`。
   ID 只增不复用 → 每个 ID 至多进一次出一次，集合天然有界。注释写明。
5. 倒计时中按空格的行为（mpv 是否暂停/跳过）代码推不出，**不进自动化测试**，
   列入真机验收清单由 Owner 按一次空格证伪。

## Out of scope
switchEndpoint（:364）与删除当前服务器路径的无条件断开（保持现状，另议）；
播放器多窗口；审查报告的 BACKLOG 三项（已登记 plans/BACKLOG.md：vault 下载
8MB 写盘占主线程 / 首页封面 stat 挤主车道 / 缓存驱逐节奏盲区）；"跳过"方案。

## Steps
1. 主修复：PlayerCoordinator（hasActiveSession + onSessionClosed）+
   LibraryCoordinator（pending 标志 + 抽方法 + 回调装配 + 三处清标志）。
2. Minor 1：resumeWatch 缩略图 provider 无条件安装。
3. Minor 2：attemptRead 发布/派发换位 + 注释。
4. Minor 3：abandonedCaptureIDs + drain 丢弃迟到帧。
5. 测试 + 验证：make test 全绿 + make build 零警告。

## 测试缝（建议，Executor 可取更小的等价缝但须满足 DoD 可断言性）
- 主修复：PlayerCoordinator.hasActiveSession 依赖真窗口不可测 → 允许
  LibraryCoordinator 增 internal 可注入缝（如
  `var playerHasActiveSession: () -> Bool`，默认
  `{ [playerCoordinator] in playerCoordinator.hasActiveSession }`）；
  断开可观测性允许 internal 缝（如 `var requestSessionDisconnect:
  () async -> Void`，默认走 sessionService.disconnect，测试替换计数）。
  断言：有在播→不立即断且 pending=true；触发 onSessionClosed→补断一次且
  pending=false；无在播→立即断（回归）；connect 成功/复用落地→pending 清零。
  落点：Tests/CoveTests/HomeDestinationTests.swift（makeCoordinator 缝现成）
  追加新 suite。
- Minor 1：复用会话 resume 后 `browserViewController.thumbnailProvider != nil`；
  落点优先 Tests/CoveTests/ContinueWatchingTests.swift（resume 缝现成则直接用）。
- Minor 2：微秒竞窗不可自动化，要求既有 VideoStreamBridgeTests 不回归 +
  diff 自证顺序；若既有已有"close 唤醒 parked read"用例，确认仍过即可。
- Minor 3：若 drain 触不到，允许把"回复该不该存"提成可测小方法
  （如 `shouldStoreCaptureReply(replyID:)`）直测放弃 ID 不存帧；
  落点 Tests/CoveTests/VideoThumbnailTests.swift。

## DoD
1. 四决策全部落地，改动不越白名单。
2. 新测试：主修复四断言 + Minor 1 provider 非 nil + Minor 3 放弃 ID 不存帧
   （缝可行时）；`make test` 全绿。
3. `make build` 零警告（strict concurrency 硬规矩）。
4. 零回归：无在播会话时回首页/回网格立即断开逐字不变；既有测试不回归。
5. 真机验收清单（交 Owner）：
   a. 在播视频时点侧栏「首页」→ 视频照播、首页照常加载；
   b. 关掉播放器窗口 → 会话断开（重进同一 share 需要重连，目录重新加载）；
   c. 在播时点「首页」→ 不关窗直接点「继续观看」复用会话 → 之后关窗
      不再误断当前会话；
   d. 下一集倒计时出现时按一次空格，观察并回传实际行为（证伪项）。

## Risks
- 挂起期间预热连接继续啃旧 share：已知且有意，关窗即止，注释写明。
- 关窗补断与后续 openHome 同主 actor 串行，无竞态；补断失败无重试
  （disconnect 幂等，下次连接自然覆盖）。
- 清标志遗漏=关窗误断新会话：三处清标志点已点名，测试 d 项兜底。

## 验收记录（2026-09-15，Owner 真机亲验）

- a 在播时点「首页」→ 视频照播、首页正常加载：通过
- b 关播放器窗 → 重进 share 需重新连接：通过
- c 复用会话（继续观看）后关窗 → 重进 share 秒开不误断：通过
- d 倒计时出现时按一次空格 → 无反应（证伪完成：空格不干预倒计时；
  非缺陷，若日后要"空格暂停倒计时"另立卡）
