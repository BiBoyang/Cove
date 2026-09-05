# TASK: 设置迁移进 App（独立窗口 → 侧栏目的地）

日期：2026-09-05 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）

## 目标复述

设置不再是独立窗口（520x712 PreferencesWindow），而是 App 主结构内的
一个目的地：侧栏新增「设置」行，选中后主区显示设置页。与 iOS 未来的
信息架构同构（iOS 无独立设置窗口概念；侧栏源 → 主区内容 与
UISplitViewController 直接映射）。现有四个分区（缓存/预热/阅读器/
本地仓库）功能全部保留。

## 决策记录（已拍板 2026-09-05）

- 方案 A：侧栏「设置」目的地（与"本地仓库"同区），弃工具栏齿轮/modal。
- 旧设置窗口（PreferencesWindowController）**完全删除**，不设过渡薄壳。
- Cmd+, 与菜单入口重定向为**聚焦侧栏设置目的地**。
- PreferencesViewModel / SettingsService / VaultService 逻辑一行不动
  （规矩 16 的跨端复用前提），本任务只动 AppKit 呈现层与路由。

## Out of Scope

- 设置项本身的增删与分组卡片美化（P7 另行）。
- iOS 端实现、设置搜索、其他快捷键体系。

## 现状摘要

- 侧栏固定行已有先例：`ServerListViewModel` 的 vault 行机制
  （isVaultRow/rowCount/server(atTableRow:)），设置行复用同模式。
- 主区路由：`LibraryCoordinator.onShowDetail` 在 share 网格/浏览器间
  切换；设置 pane 作为第三个可切换内容挂载。
- 设置内容：`PreferencesWindowController.buildContent()` 的 stack 布局
  （520pt 固定宽）需按主区宽度重排；`PreferencesViewModel` 的 State
  驱动可直接复用。
- vault 更改位置走 NSOpenPanel sheet，现挂设置窗口，迁后挂主窗口。
- Cmd+, 绑定在应用菜单层（Application/ 入口），需改路由。

## Step 列表与 DoD

每 Step 一个 commit，提审按 WORKFLOW §5.2 Review Package。

- **Step 1 侧栏目的地骨架**
  - ServerListViewModel 加设置固定行（本地仓库同区下方）；侧栏渲染与
    选中路由；新增 `SettingsPaneViewController` 空壳（先放
    StatePlaceholderView 占位），挂进主区切换。
  - DoD：`make generate && make build` 零警告；三个目的地（share 网格/
    浏览器/设置）互切正确；侧栏选中态正确；前后截图（侧栏新行 + 设置
    占位页）。
- **Step 2 设置内容迁入**
  - 四分区全部控件迁入设置页，复用 PreferencesViewModel；布局按主区
    宽度重排（最大宽度约束，左对齐）；NSOpenPanel 改挂主窗口。
  - DoD：各控件行为与原窗口一致——数字字段校验回退、预热文件夹增删、
    立即清理、vault 位置更改（panel 挂主窗口实测）；Prefs VM 既有测试
    全绿；前后截图（前 03/87 旧窗口 → 后主区设置页）。
- **Step 3 旧窗口退役 + 入口重定向**
  - 删除 PreferencesWindowController 及其引用；Cmd+,/菜单入口改为聚焦
    侧栏设置目的地。
  - DoD：`grep -r PreferencesWindowController Cove/` 零残留；Cmd+, 直达
    设置页；`make test` 全绿（204+）；无双入口。

## 风险与回滚点

- 设置页宽度重排是主要工作量（原 520pt 固定约束 → 弹性主区），注意
  stack 内表格/按钮行的宽度约束逐条核对。
- 侧栏行模型改动影响 isGroupRow/isVaultRow/server(atTableRow:) 的行号
  算术，ServerListViewModel 既有测试需同步更新。
- 回滚：单 commit revert。

## 建议验证命令

- `make generate && make build`、`make test`
- Step 3：`grep -rn PreferencesWindowController Cove/ || echo clean`

## 建议先做的 step

Step 1（骨架定稿后，Step 2 是机械平移）。
