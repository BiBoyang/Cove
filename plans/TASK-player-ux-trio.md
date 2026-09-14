# TASK-player-ux-trio：播放体验意见三连（重播 / 续播队列 / 历史卡片路径）

状态：2026-09-14 派发 Executor。

## 背景（Owner 三条意见，Plan Card 已拍板）

1. **重播**：非循环模式播完停在末帧后，点播放按钮应从头重播（现在
   点了没反应）。
2. **续播队列**：从「继续观看」打开时，「下一个」会串到原文件夹——
   拍板选项 B：续播入口（SMB/vault 一律）= 单视频队列；浏览器直开
   保持文件夹队列（剧集连播刚需不变）。
3. **历史卡片路径**：展示原始路径 + 右键菜单「打开所在文件夹」。

## Planner 侦察已实证的事实（2026-09-14，读码）

- ① `replayFromStart()` 已存在（PlayerViewModel，seekTo(0)+unpause），
  目前只服务单曲循环；clean-EOF 信号已有（core eof-reached 上升沿 →
  VM hook → coordinator 自动切集）。播放按钮与空格都汇入
  `VM.togglePause()` 单点。
- ② 续播链路 `resumeSMBPlayback`/`resumeVaultPlayback`（
  LibraryCoordinator 851/880 行）→ `openPlayer(at:)`（1128 行）→
  队列 = 浏览器当前目录同类项。**置灰零改动**：`canGoPrevious/
  canGoNext` 由 playlist 推导（单元素队列恒 false）→
  `setTransportAvailability` 已绑定按钮 isEnabled（363-364/442-444
  行）。wrap 模式 count>1 规则对单队列同样 false，自洽。
- ③ `RecentWatchEntry` 数据全齐（source/sourceID/path/directoryPath/
  fileName/position）；卡片副标题现为「已看至 t · 相对时间」
  （`subtitleText(relativeTo:)`，纯函数可测）；`revealItem(atPath:)`
  已存在（BrowserViewController:356，09-05 揭示选中机制）；
  浏览器右键菜单有先例（selectionOnRightClick）。

## Steps 与 DoD

### Step 1：EOF 重播（PlayerViewModel + 测试）

- VM 跟踪「播完且无处可去」的停驻态（clean-EOF 置位；fileLoaded/
  seek 清除）。**仅当无 Up Next 自动跳转待执行时**，播放按钮/空格
  → `replayFromStart()`；否则维持原 togglePause。「是否有待跳转」
  是 coordinator 的知识（stepIndex 为空才停驻）——用最小接线把该
  语义喂给 VM（如 coordinator 在不跳转时 arm 一个标志），并在报告
  中说明选型。
- DoD：VM 单测（recorder 断言调用序列）：① EOF 停驻+无跳转 →
  [seekTo(0), togglePause]；② 非 EOF → [togglePause] 不回归；
  ③ 有跳转待执行时不重播；④ fileLoaded/seek 后标志清除。

### Step 2：续播入口单视频队列（LibraryCoordinator + 测试）

- `openPlayer(at:)` 增队列模式（文件夹=默认 / 单视频），续播两处
  调用点传单视频；siblings（字幕发现）不受影响照旧传全量。队列
  分支逻辑提成纯函数（队列选型可单测）。
- DoD：纯函数单测（video/audio/未知类型 × 两种模式）；续播入口
  单元素队列 → `setTransportAvailability(false,false)` 经既有推导
  自然成立（补一条 playlist 单元素用例如缺）；浏览器直开队列
  不回归。

### Step 3：历史卡片路径 + 打开所在文件夹（Home 三件套 + LibraryCoordinator + 测试）

- 展示：副标题行追加目录路径（中间截断）：SMB「已看至 t · 相对 ·
  /share/dir/sub」、vault「… · 本地仓库/dir/sub」；tooltip 全路径。
  路径字符串生成走纯函数（entry → locationText，可测）。
- 右键菜单（历史卡片）：首项 = 路径（disabled，可截断）+「打开
  所在文件夹」。
- 打开行为（复用续播既有机制，不改其语义）：
  - SMB：未连接先走续播同款连接链；成功 → 浏览器导航到
    directoryPath + `revealItem(atPath: entry.path)`；文件/文件夹
    已消失 → 复用确定失败清理（移除记录 + alert）；网络/鉴权失败
    → 瞬态失败范式（记录保留 + 占位/alert，与续播一致）。
  - vault：`openVault(initialPath: directoryPath)` 完成回调里
    `revealItem(atPath: entry.path)`；消失同样走确定失败清理。
- DoD：locationText 纯函数单测（SMB/vault/深层截断）；菜单内容
  与行为接线在报告中说明验证方式（视图层难测部分允许真机兜底，
  但纯值部分必须有测试）。

## 通用 DoD

- `make generate && make test` 全绿；`make build` 零警告。
- 注释英文 / UI 文案中文 / 严格并发零新警告 / VM 与 Services 不出现
  AppKit 类型（CGImage 可以）/ SnapKit 只在 View。

## 真机验收清单（Owner，DoD 闭环条件）

前置：`open ~/Library/Developer/Xcode/DerivedData/Cove-hfgxekzokxofimdxyhyhfpqzxeit/Build/Products/Debug/Cove.app`
（或自行 make build 后开 app）。

1. 重播：播任意视频（顺序模式），拖到最后 10 秒等它播完停在末帧
   → 点播放按钮（或按空格）→ 预期：从头重播。
2. 续播队列：首页「继续观看」卡片开一个视频 → 控制条「上一个/
   下一个」**置灰**；再从 SMB 浏览器某文件夹（≥2 个视频）直开一个
   → 两按钮可用、能连播。
3. 路径展示：首页继续观看卡片副标题看到路径（截断形态）；鼠标
   悬停卡片 → tooltip 显示全路径。
4. 打开所在文件夹：右键一张 SMB 历史卡片 → 菜单含路径与「打开
   所在文件夹」→ 点击 → 浏览器落到对应文件夹且该视频被选中揭示；
   vault 卡片同样过一遍。
5. 回归：正常播放/暂停/切集/Up Next 倒计时（多视频文件夹顺序
   播放到一集结束）行为不变。

回传：逐项一句"正常/异常"+ 异常现象描述。

## 硬停止（命中即停手上报）

1. 复用链（续播连接/失败清理/revealItem/setTransportAvailability）
   语义需要**改变**（而非复用）→ 停。
2. 需要动 ControlsCapsuleView 内部或胶囊布局 → 停。
3. 白名单外任何文件 → 停。
4. ① 的「无待跳转」接线需要把 Up Next 倒计时逻辑大改 → 停（报
   Planner 重议最小方案）。

## 白名单（绝对路径）

- /Users/boyang/code/Cove/Cove/Features/Player/ViewModels/PlayerViewModel.swift
- /Users/boyang/code/Cove/Cove/Features/Player/Coordination/PlayerCoordinator.swift
- PlayerPlaylist 所在文件（Cove/Features/Player/ 下，语义白名单）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
- /Users/boyang/code/Cove/Cove/Features/Servers/ViewModels/HomeViewModel.swift
- /Users/boyang/code/Cove/Cove/Features/Servers/Views/HomeViewController.swift
- 测试：Tests/CoveTests/ 下既有 player/home 测试文件
  （PlayerViewModelTests.swift、ContinueWatchingTests.swift、
  HomeDestinationTests.swift、PlayerPlaylistTests.swift 按语义归属）；
  确需新测试文件须报告说明并 `make generate`。
