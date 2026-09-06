# TASK: 播放器控制条布局重构（IINA 居中窄胶囊）

日期：2026-09-07 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：plans/UI-AUDIT-2026-09-05.md §2.7（V9 胶囊结构参考值）+ plans/archive/TASK-media-chrome.md
Out of Scope 外挂候选；令牌图纸 design/DESIGN-TOKENS.md §6.5；布局参照
~/ui-refs/iina/01-player.png（仓库外，不入库）

## 目标复述

控制条从全宽单排长条（左右 inset 16 撑满窗口）重构为 IINA 式底部居中窄胶囊：
内容自适应宽度、双排结构——上排音量组 + transport + 工具钮，下排进度条 +
两端时间码。纯布局重构，不动任何元素的视觉配方（底板 surfaceOverlay /
圆角 large / 字号令牌均已拍板）与播放逻辑。

## 决策记录（已拍板 2026-09-07）

- 结构：**双排合一胶囊**（IINA 同款）；否决「单排窄胶囊 + 进度条独立细条」。
- 时间码：**拆两端**——下排左 = 当前时间、右 = 总时长；废除右侧合并文本
  「0:45 / 0:45」。
- 窄窗口降级：**设播放器窗口 minSize**（宽 520pt 起，执行时以胶囊自然宽度 +
  左右余量校准为准），不在胶囊内部压缩音量条。
- 工具钮：speed（1x）/ 播放模式 / 播放列表三钮归**上排右侧**（IINA 位）。
- Up Next 保持右下角，`bottom: -76` 魔数改为锚定胶囊顶 + 12 间距。

## Out of Scope

- 胶囊内元素的底板/圆角/字号/间距令牌本身（沿用 §6.5 已拍板配方）。
- codec chips、中央状态层、弹层内容、Up Next 内容与逻辑；阅读器。
- 播放/进度/音量逻辑与 ViewModel 状态机（仅时间码拆分加一个格式化读数）。

## Step 列表与 DoD

### Step 1 胶囊双排重排 + 窗口 minSize
- `Cove/Features/Player/Views/PlayerWindowController.swift`：胶囊改双排——
  上排：音量 icon+slider+定宽读数 ｜ prev/play/next ｜ 1x/模式/播放列表；
  下排：当前时间（左）+ 进度条（中，保持 flexible）+ 总时长（右）；
  胶囊 shrink-wrap 内容、水平居中、bottom 16；窗口 minSize 落地。
- 时间码拆分：VM 已有 `currentTime`/`duration` 分字段
  （`PlayerViewModel.swift:49-50`），拆出 elapsed/total 两个格式化读数
  （复用现有 formatter）；时间位不再承担状态文案（P6 Step 4 已由中央
  状态层接管）。
- DoD：build 零警告、test 全绿；前后截图三态（常宽 / 拉窄至 minSize /
  全屏），前图 plans/UI-AUDIT-2026-09-05/crop-controls-capsule.png +
  图 11；真机验收：拖进度、调音量、快捷键（space/方向键）回归。

### Step 2 Up Next 锚定适配
- Up Next overlay 的 bottom 由魔数 -76 改为锚定胶囊顶 + 12；复核 codec
  chips（左上，预期不动）与中央状态层几何。
- DoD：Up Next 出现不压胶囊（前图 plans/UI-AUDIT-2026-09-05/crop-upnext.png）；
  全屏下胶囊与 Up Next 位置回归；build 零警告、test 全绿；真机验收。

## 风险与回滚点

- 双排后胶囊变高（约 64–72pt），注意与中央状态层/居中标题的纵向关系；
  全屏下显隐动画保持现状。
- minSize 与窗口 frame 记忆：若恢复了小于 minSize 的历史尺寸，需 clamp
  （AppKit 通常自动处理，执行时实测）。
- 每 Step 单 commit 可 revert；Step 2 依赖 Step 1 的胶囊几何。

## 验证

- 每 Step 前后截图对照；真机验收逐 Step。
- 人工检查点（用户）：胶囊在亮画面上可读不刺眼、双排信息不拥挤、拉窗到
  minSize 无截断、Up Next 不与胶囊重叠。
