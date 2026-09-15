# TASK: Up-next space pause（倒计时期间空格=暂停/继续）

- Status: done（2026-09-15 收尾，Review Gate: Approved，真机验收通过；
  make test 381/58 全绿零警告）
- Created: 2026-09-15
- 触发：TASK-playback-session-guard 真机 d 项证伪——倒计时出现时按空格无反应。
  根因实证：空格并未被吞——handleKeyDown 的 isUpNextShown 分支只特判
  Esc/Return，空格落到了通用分支的 togglePause()，但 EOF keep-open 已停在
  最后一帧，对已结束的流切暂停=视觉零变化。用户直觉是"等等，先别跳"。

## 根因（2026-09-15 代码实证）

PlayerWindowController.handleKeyDown（Cove/Features/Player/Views/
PlayerWindowController.swift:912-947）：`isUpNextShown` 时 case 53(Esc)→
取消、case 36(Return)→立即播，default 落到外层 switch，case 49(空格)→
`viewModel.togglePause()`——对已 EOF 的流无可见效果。倒计时本身
（UpNextCountdown 模型 + coordinator 的 1s Timer）没有暂停概念：
模型 Phase 只有 counting/fired/cancelled（Models/UpNextCountdown.swift），
注释明示"There is no resume semantics by design"。

## Decisions（Owner 已回 o 拍板选 A，Executor 照做）

1. **空格=暂停/继续倒计时**（方案 A；否决 B=与 Esc 冗余、C=不做）：
   - 模型：Phase 增 `paused`；`togglePause()` 双向切换
     counting↔paused；`tick()` 保持只在 counting 生效（paused 返回 nil）；
     `cancel()` 允许从 paused 取消（倒计时暂停时按 Esc/点取消照样收）；
     fired/cancelled 吸收态不变。既有注释（no resume semantics）更新。
   - Coordinator（PlayerCoordinator）：增 `toggleUpNextPause()`——
     暂停=tearDownUpNextTimer() + 模型切 paused + overlay 显示暂停态；
     继续=模型切 counting + 按剩余秒数重建 1s Timer + overlay 恢复读秒。
     `upNextCountdown` 保持非 nil（fire/cancel 现有路径不动——Return/
     立即播/ Esc 在暂停态下语义不变）。回调装配处（:127-128 同款位置）接
     `controller.onUpNextTogglePause`。
   - View：handleKeyDown 的 `isUpNextShown` 分支增
     `case 49: onUpNextTogglePause?(); return true`；文件头键盘说明注释
     （:21-24）同步。UpNextOverlayView 增暂停态展示——`update(seconds:)`
     之外加 `setPaused(_:)`：暂停时倒计时标签显示「已暂停 · 空格继续」
     （UI 文案中文），恢复时回到「N 秒后播放」；controller 侧加
     `setUpNextPaused(_:)` 透传。
2. 不改 Esc/Return/取消按钮/立即播按钮的任何既有语义；暂停只是冻结
   Timer，不动队列位置、不动 playMode 重读逻辑（fire 时仍现读 mode）。

## Out of scope
倒计时 UI  redesign；空格在普通播放中的行为（不动）；长按/其他键位。

## Steps
1. 模型：Phase.paused + togglePause + 测试先行。
2. Coordinator：toggleUpNextPause + 回调接线。
3. View：case 49 + setPaused 展示 + 注释同步。
4. 验证：make test 全绿 + make build 零警告。

## DoD
1. 决策全部落地，改动不越白名单。
2. 新测试：toggle 双向切换、paused 下 tick 不递减、paused 下 cancel 生效、
   fired/cancelled 吸收态不回归（UpNextCountdownTests 追加）；
   `make test` 全绿。
3. `make build` 零警告（strict concurrency 硬规矩）。
4. 零回归：Esc 取消 / Return 立即播 / 按钮行为不变；既有测试不回归。
5. 真机验收（交 Owner）：播完一集倒计时出现 → 按空格 → 读秒冻结且显示
   「已暂停 · 空格继续」→ 再按空格 → 继续倒数到 0 自动播下一集；
   暂停中按 Esc 仍取消、按 Return 仍立即播。

## Risks
- 暂停时 Timer 已销毁，模型 paused 吸收 tick——双保险，无幽灵 fire。
- 暂停中切 playMode：fire 时现读 mode 的既有逻辑覆盖，行为一致。
- 暂停中关窗：windowWillClose 走 cancelUpNextCountdown 现有路径，
  cancel 从 paused 生效已在模型层覆盖。

## 验收记录（2026-09-15，Owner 真机亲验）

- 倒计时出现按空格 → 读秒冻结、胶囊显示「已暂停 · 空格继续」：通过
- 再按空格 → 从冻结值继续倒数到 0 自动播下一集：通过
- 暂停中 Esc 仍取消 / Return 仍立即播：通过
