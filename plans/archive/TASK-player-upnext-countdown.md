# TASK: 播放器"即将播放"倒计时浮层（Up Next countdown）

日期：2026-08-27 ｜ 协作模式（助手规划/Review，用户实现）
状态：已完成并入库（`776a59f`，2026-09-04；真机验收用户已通过）

## 目标复述

同级视频连播目前播完即切（`PlayerCoordinator.advanceAfterEnded` 直接 `step`）。
升级为 Infuse 式：播完后浮层倒计时 5 秒（显示下一集文件名），期间可
"立即播放"或"取消"，超时自动切下一条；队列末尾不弹浮层，保持停在最后一帧
的现状行为。

## 决策记录（已拍板）

- **倒计时归 Coordinator，不归 ViewModel**：倒计时的存活区间正好跨在两个
  session 之间（旧片已 ended、新片未 install），而 VM 随 session 一起被
  `install` 换掉。窗口级 UI 会话状态属于 Coordinator 的窗口生命周期职责
  （AGENTS.md 规矩 12/13 的边界）：Coordinator 持有 `Timer` 与倒计时模型，
  `PlayerWindowController` 只加纯渲染 overlay + 回调转发。
- **时长 5 秒**，1 秒步进刷新文案。不做用户设置项（YAGNI， backlog 不加）。
- **位置右下角**，避开底部通栏控制条（bottom offset 叠在控制条上方），
  样式复用控制条语言：`NSVisualEffectView` `.hudWindow` 胶囊 +
  `CoveStyle.radiusLarge`。不显示缩略图（视频无缩略图管线，不为此新建）。
- **浮层显隐独立于控制条的闲置自动隐藏**：倒计时期间常显，结束即消失，
  不与 `controlsVisible` 联动（联动会把两套显隐状态机搅在一起）。
- **键盘**：倒计时期间 `esc = 取消`、`return = 立即播放`，优先级高于现有
  按键语义（esc 先取消浮层，再按一次才退全屏）。
- **取消语义**：取消 = 关浮层、停在最后一帧、不动播放队列索引。这与"手动
  step"严格区分——手动 prev/next 依然随时可用。

## Out of Scope

- 缩略图/海报预览、倒计时秒数的用户设置项、暂停倒计时（hover 暂停等）。
- 末集行为变更（保持停在最后一帧）。
- 控制条闲置隐藏逻辑、`PlayerPlaylist`、`MPVPlayerCore`、播放管线的任何改动。

## 现状摘要

- `PlayerCoordinator`（`Cove/Features/Player/Coordination/PlayerCoordinator.swift`）：
  `viewModel.onEnded` → `advanceAfterEnded()` → `canGoNext` 则 `step(by: 1)`。
  `step` 自带"新 session 构建失败则回滚索引"逻辑，直接复用。
- `PlayerWindowController`（`Cove/Features/Player/Views/PlayerWindowController.swift`）：
  控制条胶囊 + 标题 label 的装配/约束是现成参照；键盘经 `PlayerWindow.onKeyDown`
  → `handleKeyDown`（keyCode 53 = esc 已有分支）；`install` 换 session 的顺序
  约定（persist → 断事件 → shutdown → 装新）已注释写死，不要动。
- `CoveStyle.radiusLarge` 等设计令牌在 SharedUI，直接引用。

## Step 列表与 DoD

### Step 1：倒计时模型（纯逻辑，无 UI）

- 改动文件：
  - `Cove/Features/Player/Models/UpNextCountdown.swift`（新建）
  - `Tests/CoveTests/` 下新增对应测试文件
- 内容：值类型状态机。`init(totalSeconds: Int)`；`tick()` 返回剩余秒数，
  归零时进入 fired 态；`cancel()` 进入 cancelled 态；fired/cancelled 后
  `tick()` 不再产生任何输出（幂等）。不提供"恢复"语义。
- DoD：
  1. 测试覆盖：5→4→…→0 的 tick 序列、归零 fire、取消后 tick 幂等、
     fire 后 tick 幂等（取消与陈旧结果两条边界都要，AGENTS.md 规矩 15）。
  2. `make test` 全绿、`make build` 零警告（strict concurrency complete）。

### Step 2：浮层视图（View 层，纯渲染 + 回调）

- 改动文件：
  - `Cove/Features/Player/Views/PlayerWindowController.swift`
- 内容：
  1. 新增私有 overlay 视图（参照 `ControlsCapsuleView` 的阴影/材质做法）：
     下一集文件名（截断）+ "N 秒后播放" + 两个按钮（立即播放 / 取消，
     中文文案）。约束：trailing -16、bottom 叠在控制条上方（-76 起调，
     视觉对准入座后可在 review 里微调）。
  2. WC 暴露三个方法：`showUpNext(title:seconds:)` /
     `updateUpNext(seconds:)` / `hideUpNext()`，以及两个回调
     `onUpNextPlayNow` / `onUpNextCancel`。View 内部不持定时器、不做决策。
  3. `handleKeyDown`：浮层显示期间 keyCode 53（esc）→ `onUpNextCancel`，
     keyCode 36（return）→ `onUpNextPlayNow`，均消费事件；浮层隐藏时走
     现有语义不变。
- DoD：
  1. `make generate && make build` 零警告；布局全部 SnapKit（规矩 11）。
  2. View 只渲染和转发，不含状态/定时器（review 时核对规矩 12）。
  3. 人工检查点可暂缺（Step 3 接线后统一验）。

### Step 3：Coordinator 接线（定时器 + 取消路径）

- 改动文件：
  - `Cove/Features/Player/Coordination/PlayerCoordinator.swift`
- 内容：
  1. `advanceAfterEnded()` 改名/改为：`canGoNext` → 启动倒计时并
     `showUpNext`；`!canGoNext` → 什么都不做（现状行为）。
  2. 定时器（主 actor `Timer`，1s）驱动模型 `tick()`：剩余秒数
     `updateUpNext`，fire → `hideUpNext` + `step(by: 1)`。
  3. 取消路径全部收口：`onUpNextCancel` → 取消 + `hideUpNext`；
     手动 `step`（prev/next 按钮）时若倒计时存活 → 先取消再 step；
     `windowWillClose`/`onClose` → 取消（timer 闭包一律 weak self）。
  4. `open(...)` 新会话打开时也取消存活倒计时（防御：播完瞬间用户从
     浏览器又点开别的片）。
- DoD：
  1. `make test` 全绿、`make build` 零警告。
  2. 人工检查点（真机）：
     a. 播一个短视频到结尾 → 浮层出现、读秒、自动切下一条；
     b. 再播到结尾点"取消" → 停在最后一帧，不切换；
     c. 倒计时中点"立即播放" → 立即切；
     d. 倒计时中点上一集/下一集按钮 → 浮层消失，正常切换不串台；
     e. 倒计时中关窗 → 无崩溃无残留；
     f. 播到队列末集结尾 → 无浮层，停在最后一帧；
     g. esc 取消浮层、return 立即播放，各验一次。

## 风险与回滚点

- **session 交换竞态**：fire 与手动 step 同拍到达时，模型 fired/cancelled
  幂等态保证只切一次；`install` 前不需要额外守卫，但 review 时要核对
  `step` 内未残留定时器引用。
- **esc 语义变化**：倒计时期间 esc 的第一跳从"退全屏"变成"取消浮层"——
  这是有意的优先级重排，已在决策记录写明；review 时确认全屏 + 倒计时
  叠加场景（先取消浮层，再按退全屏）。
- 回滚：Step 3 单独 revert 即恢复"播完立即切"；Step 1/2 为无害残留。

## 验证命令

```sh
make test                    # 全量回归（含新模型用例）
make generate && make build  # 零警告
```

## 实际落地范围（超出原计划，2026-09-04 追记）

最终实现随倒计时一起入库的还有一组播放器传输能力，均经 review +
`make build` 零警告 / `make test` 全绿 + 用户真机验收：

- **播放模式**：单视频 / 单视频循环 / 列表 / 列表循环 / 随机
  （`PlayMode`）；`PlayerPlaylist` 从 advance/back 重写为
  `autoAdvanceIndex(mode:)` / `stepIndex(delta:mode:)` 纯函数 + 测试重写。
  列表类模式播完走倒计时；单循环原地 replay 不弹浮层；单视频停在
  最后一帧。倒计时期间切模式在 fire 时重新读取（即时生效）。
- **倍速**：胶囊 "1x" 按钮 + popover（0.5/0.75/1/1.25/1.5/2），
  Coordinator 记住选择并应用到后续 session。
- **播放列表面板**：胶囊播放列表按钮弹出队列（NSTableView，当前行
  金色 + 扬声器），点行跳转；队列移动时旧面板自动关闭防陈旧高亮。
- **mpv keep-open**：`keep-open=yes` 让 EOF 停在最后一帧且不卸载文件
  （取消倒计时后拖回进度条可用）；clean EOF 信号改为 `eof-reached`
  属性上升沿（END_FILE 在 keep-open 下不再为 clean EOF 触发），
  END_FILE 分支留防御且不会双发。
- 顺带修复：音量滑条跟随键盘调节（render 统一回写）；标题从左上角
  改为顶部居中（中间截断）。

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package：Step 编号、改动文件列表、关键 diff
摘要、自测命令与结果、已知风险。每个 Step 单独提审，不跨步混改。
