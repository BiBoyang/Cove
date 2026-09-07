# TASK: share 卡片升级信息卡片

日期：2026-09-08 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：design/DESIGN-TOKENS.md §6.7（share 卡片配方）+ :185 待定拍板项

## 目标复述

share 网格卡片从"图标 + 名称"入口卡升级为信息卡片：加 share 备注
（comment，有则显示）与「最近打开」相对时间（本地记录）。视觉配方沿用
既有令牌（surface/hover-fill/描边三族已拍板），不新设计视觉语言。

## 决策记录（已拍板 2026-09-08）

- 升级方向：**A 信息卡片**（否决 B 维持极简）。
- **Step 0 spike 结论**（已执行，证据：SourceKit `SMBServer.swift:5`/:47-69）：
  SMB share 枚举（SRVSC NetShareEnum）只有 name + comment 两字段——
  类型标签无区分度（全是 disk share）、服务器侧无时间源。
- 降级方向拍板：**A1+A2 叠加**——comment 有则显示；相对时间由 App 本地
  记录"最近打开"时间戳（自控数据源，首次无记录不显示该行）。

## Step 列表与 DoD

### ~~Step 0 spike：元数据来源确认~~（已完成）
结论见上：comment 有源（可选值）；相对时间走本地记录。

### Step 1 数据供给 + 卡片布局
- 本地记录：打开 share 成功时记录时间戳（键 = 服务器+share 标识），
  持久化走 Services/Settings 既有模式（UserDefaults 只存展示级数据，
  非凭据——符合 AGENTS.md 规矩 5）。相对时间显示用
  RelativeDateTimeFormatter（跟随系统语言）。
- 卡片布局：名称行下加元信息区——comment 行（caption 档，有才显示）+
  最近打开行（caption 档，有才显示）；均无则与现状一致。卡片尺寸如需
  调整，按"一值一角色"在组件尺寸族登记新角色。
- 行数上限三行（名称 + 两元信息行），溢出中间截断。
- DoD：build 零警告、make test 全绿（基线 217 + 新增单测：时间戳记录/
  读取/重置逻辑可纯值测）；前后截图对照（前图
  plans/UI-AUDIT-2026-09-05/25-sharegrid.png）；真机验收清单（说人话）：
  有备注 share 显示备注行、打开过的 share 显示"几分钟前"级相对时间、
  从未打开的 share 无第二行、卡片不拥挤、hover/选中观感不回归。

## 风险与回滚点

- 时间戳记录点：只在打开成功（连接建立）后记，失败不写；服务器被删/
  改名时陈旧条目惰性清理或忽略即可（展示层读不到就不显示）。
- 本地记录不含敏感信息（share 名 + 时间戳），符合 UserDefaults 口径。
- 单 commit 可 revert。
