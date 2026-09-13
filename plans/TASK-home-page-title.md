# TASK: 主页增加「继续观看」页面标题

- 状态：done（2026-09-13 执行完毕，Review Gate: Approved）
- PROMPT：`/Users/boyang/code/Cove/prompts/TASK-home-page-title.prompt.md`

## 背景 / 现状

- 主页（`HomeViewController`）= 继续观看卡片网格 + 两级空态（无服务器 / 无观看记录），整页没有任何标题文字；窗口标题在主页为 "Cove" 且 titlebar 隐藏。
- 侧边栏入口名为「首页」，页面内容实为观看历史/继续观看，名字与内容对不上（2026-09-13 用户验收反馈：「观看历史没有在主页上标识出来」）。

## 目标

主页顶部常驻「继续观看」标题：有记录、无记录空态、无服务器空态三种状态下均可见；样式与 `design/DESIGN-TOKENS.md` / `CoveStyle` token 体系一致。

## 拆解（Steps）

1. `CoveStyle` 增加 `pageTitleFont` token：先查 `/Users/boyang/code/Cove/design/DESIGN-TOKENS.md` 字体表，有约定按约定；无约定则用 `NSFont.systemFont(ofSize: 22, weight: .bold)`，并在该文档字体表补对应一行（保持文档既有格式）。
2. `HomeViewController` 顶部加标题 label：「继续观看」、`pageTitleFont`、`.labelColor`、左对齐，leading/top 用 `CoveStyle.space20`；`scrollView` 顶部改接到标题 label 下方（间距 token 内取小值）。
3. 空态 `placeholderView` 约束由四边贴 root 改为：leading/trailing/bottom 贴 root、top 贴标题 label 底——空态下标题仍可见。
4. `Tests/CoveTests/HomeDestinationTests.swift` 增补用例：主页视图层级中含「继续观看」文本（若现有测试基建支持实例化该 VC；不支持则在报告中说明原因，靠人工验收兜底）。

## DoD

1. 标题在三态（有记录 / 无记录 / 无服务器）常驻，不错位、不截断、不挤压卡片网格。
2. 改动范围仅限声明文件；纯 AppKit + SnapKit；无新文件（标题直接建在 HomeViewController 内）。
3. `make build` 通过；`make test` 无回归（至少 HomeDestinationTests 相关）。
4. 零并发警告；注释英文、UI 文案中文。
5. 无 git add / commit / push（提交归 Owner）。
6. 验证可复现：报告附自测命令与结果。

## 风险与回滚

- 文案拍板：首选「继续观看」（与 `plans/archive/TASK-continue-watching.md` 命名一致）；备选「观看历史」，Owner review 时可一句话更换（单行改动）。
- 风险低：单 VC + 单 token 的纯增量改动；回滚直接 revert。
