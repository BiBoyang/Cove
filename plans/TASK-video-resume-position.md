# TASK: 视频记忆播放位置（resume position）

日期：2026-08-24 ｜ 协作模式（主会话规划/Review，另一会话实现）

## 目标复述

视频看到一半关掉，下次打开自动从上次位置继续；看完的（>95%）从头播。按 `sourceID + path` 记忆。

## 决策记录（已拍板）

- **存储**：新增 `PlaybackProgressStore`（`Cove/Services/` 下，UserDefaults 字典承载，key = `sourceID|path`，value = 秒数 Double）。不碰 Keychain（非凭据），不进 CacheKit。
- **容量**：LRU 上限 200 条，写入超限时删最旧（UserDefaults 里附一个 recency 记录或用 (position, lastWatched) 元组排序淘汰，取实现最简的）。
- **写入时机**：播放中每 ~5s 节流一次 + 暂停时 + 关窗（teardown）时。VM 已有 time-pos 流，节流即可。
- **恢复判定**：`5s < position < duration × 0.95` → file-loaded 后 seek 恢复；`≤5s` 视为未开始，`≥95%` 视为看完——**看完的记录删除**，重看从头播。
- **接线**：store 由 AppDelegate（composition root）创建，经 PlayerCoordinator 注入 PlayerViewModel；VM 经协议（如 `PlaybackProgressStoring`）持有，测试用内存实现。
- **UI**：静默恢复，不加提示条。
- duration 未到时（MPV_FORMAT_NONE）不写不读，等 duration 可用再判定。

## Out of Scope

播放列表、连续播放、跨设备同步、恢复提示 UI、倍速/字幕。

## 现状摘要

- `PlayerViewModel`（`Cove/Features/Player/ViewModels/`）：已有 time-pos/duration/pause/end-file 事件归约，`seekTo(seconds:)` 现成；状态机含 loading/playing/paused/buffering/error。
- `PlayerCoordinator` 组装 core+VM+窗口；`MPVPlayerCore` 观察 time-pos/duration 并抛 `PlayerCoreEvent`。
- 注入先例：`SettingsService`/`CacheStore` 均从 AppDelegate 构造链路注入。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. `PlaybackProgressStore`（UserDefaults 承载 + LRU 200 + 删看完记录）。
2. VM 接线：恢复判定（file-loaded + duration 可用后一次）、节流写入（播放中 ~5s / 暂停 / 关窗）、看完清除。
3. DoD：
   - 测试：store 读写/淘汰/截尾删除；VM 恢复判定三态（<5s 不恢复、中间恢复并 seekTo 一次、≥95% 删记录且不恢复）；关窗写入。
   - `make generate && make build` 零警告、`make test` 全绿。
   - 提审附 Review Package。

## 风险与回滚点

- duration 晚到或缺失（流式场景）：只有拿到正 duration 才做恢复/看完判定，宁缺毋滥。
- 频繁 seek 场景（用户拖进度中）不写库，避免把中间态当进度。
- 回滚：单 commit revert。

## 验证

- 主会话 review + 测试核验。
- 人工检查点（用户）：① 看一半关窗重开 → 从上次位置续播；② 拖到结尾关窗重开 → 从头播；③ 只看了几秒关窗重开 → 从头播。

## Review 交接

按 WORKFLOW.md §5.2 Review Package。
