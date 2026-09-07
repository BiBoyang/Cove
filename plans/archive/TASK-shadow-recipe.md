# TASK: shadow 配方令牌化

日期：2026-09-08 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：design/DESIGN-TOKENS.md §3.4 豁免清单登记的 shadow 配方候选 +
2026-09-07 全仓散点清点（explore agent 实证）

## 目标复述

阴影参数（offset / blur / opacity / color）从手写散点收敛为 CoveStyle
配方令牌并在令牌文档登记。**零视觉变化承诺**：同 spacing 卡纪律，参数
聚类只合并同值项，异值分立档位，diff 逐 hunk 参数零变化核对。

## 实态核查结论

- 手写 5 处：`PlayerWindowController.swift:487 / :924 / :988`、
  `PagedReaderWindowController.swift:188-189`、`ContinuousReaderView.swift:178-179`
  （胶囊 / Up Next pill / 弹层 / 阅读器 chrome 阴影）。
- 令牌文档 §3.4 已登记"另立 shadow 配方候选"。

## Step 列表与 DoD

### Step 1（单 Step 小卡）
- 执行 agent 先聚类：5 处参数逐处抄录比对，同值一族、异值分立；
  在 `CoveStyle` 加 shadow 配方（形态：按用途角色的方法或结构体常量组，
  命名与既有令牌风格一致）；DESIGN-TOKENS.md 新增 shadow 小节登记档位。
- 调用点同值替换。
- DoD：build 零警告、make test 全绿；diff 参数零变化核对表；截图抽查
  （播放器胶囊 / Up Next pill / 弹层 / 阅读器 chrome 的阴影观感不变，
  先动鼠标激活控件再截）；用户验收清单按 §5.2。

## 风险与回滚点

- 若 5 处参数互不相同：不许硬并，登记为多档配方；宁可多档不视觉漂移。
- 单 commit 可 revert。
