# TASK: 空态与加载态体系（库界面先行）

日期：2026-09-05 ｜ 直接开干模式（助手实现，用户验收）
上游：plans/UI-AUDIT-2026-09-05.md §1 T1 + §4 P1；令牌图纸 design/DESIGN-TOKENS.md §6.1/§6.2

## 目标复述

库界面（侧栏 / share 网格 / 文件浏览器）的"空、加载中、失败"三态目前没有
设计：空文件夹整面裸底、share 加载只有静态图标+一行字、连接失败时占位
「双击重试」与 modal alert 双重提示、零服务器无引导。本任务建立统一的
StatePlaceholder 组件族并接入上述场景。阅读器/播放器的加载与失败态不在
本次范围（归后续 chrome 任务）。

## 决策记录（依据令牌文档 §6.1/§6.2，借 SenPlayer 空态模式）

- **新组件 `StatePlaceholderView` 入 SharedUI**（满足"至少两个 Feature 复用"
  门槛：ShareGrid + Browser + 侧栏三处）：居中大号 SF Symbol
  （text-tertiary）+ 标题（titleFont）+ 一行说明（captionFont，
  secondaryLabelColor）+ 可选行动按钮（PillButton）。Mac 端用符号单色，
  不引入插画资源（够用即可）。
- **加载态** = NSProgressIndicator（系统 spinner）+ 一行说明；禁止静态图标
  冒充加载中。目录切换先出加载态，不留旧内容残留。
- **失败态收敛为单点**：占位区显示失败图标 + 人性化一行 + 「重试」按钮；
  modal alert 不再与占位同时出现（alert 保留给真正需要打断的场景，本任务
  内连接失败不再弹）。错误文案人性化（消灭 `POSIXErrorCode(rawValue:)`
  裸串）不在本卡——归 BACKLOG 的 ErrorPresenter 远期项。
- **零服务器空态带引导**：占位 + 「添加服务器」主按钮，点击等同于侧栏 +
  按钮（打开添加 sheet）。
- 空态/加载态各场景文案见实现时定稿（中文，遵循"说明现状 + 给下一步"）。

## Out of Scope

- 阅读器/播放器加载态与 chrome（P6 任务）。
- 错误文案人性化与 ErrorPresenter（BACKLOG 远期项）。
- 目录切换的乐观缓存（显示旧内容直到新内容到达，属另一策略，不引入）。

## 现状摘要

- `ShareGridViewModel.swift:22` showLoading 仅静态图标+文字；失败时
  showPlaceholder + LibraryCoordinator 弹 alert（双重提示）。
- `BrowserViewController` 无空态/加载态渲染路径；`render()` 只画 items。
- 侧栏零服务器时主区占位「双击左侧服务器以连接」（ShareGrid 占位复用）。
- SharedUI 现有 PillButton/FrostedCircleButton/RoundedFillView 可复用。

## Step 列表与 DoD

建议单 Step 交付（一个 commit）：

1. SharedUI 新增 `StatePlaceholderView`（icon + title + message + 可选按钮）。
2. 接入 share 网格：加载（spinner）、失败（占位+重试，去掉同出 alert）、
   空 share 列表（占位）。
3. 接入浏览器：空文件夹占位、目录切换加载态（替换旧内容残留）。
4. 接入零服务器引导（占位 + 添加服务器按钮）。
5. DoD：
   - `make generate && make build` 零警告；`make test` 全绿；
   - **前后截图对比**四场景：share 加载中、连接失败、空文件夹、零服务器
     （前图均在 plans/UI-AUDIT-2026-09-05/：21/22/16/01）；
   - 组件/状态逻辑按 AGENTS.md 15 补行为测试（VM 状态→占位内容映射；
     View 层外观不截图断言）；
   - 令牌文档 §6.1/§6.2 状态从 [提议] 转 [已拍板]（随本卡）；
   - 真机验收前不合并。

## 风险与回滚点

- ShareGrid/Browser 的状态流都在 VM→View 单向链路上，组件是纯展示层，
  风险低；注意加载态与 drill-down 滚动复位（刚修）互不干扰——目录切换
  加载态的呈现不得绕开 render() 的滚动复位分支。
- 回滚：单 commit revert。

## 需要拍板的决策点

1. 失败态「不再同时弹 alert」——同意收敛为占位+重试单点？
2. 零服务器引导按钮：同意占位页直接放「添加服务器」主按钮？
3. 加载态是否需要骨架屏（推荐不要，spinner 即可）？

## 验证

- 复现环境现成：vault 夹具（空文件夹/深层测试）+ 假服务器连失败（15s
  超时，验收时计入等待成本）+ 真 NAS。
- 人工检查点（用户）：断网/错地址场景的失败态观感、加载态闪烁频率
  （本地列表快，加载态可能一闪而过——可接受）。
