---
task: /Users/boyang/code/Cove/plans/TASK-check-for-updates.md
status: done（2026-09-12 真机 Owner 验收通过，任务卡已归档）
from: Planner
to: Executor
created: 2026-09-12
---

# 任务：Check for updates（检查更新，1.0 批 1 末卡）

## 目标
「检查更新…」（app 菜单 + 设置页）查 GitHub Releases 最新稳定 tag，
与运行中版本比较，三态中文 alert（已最新/有新版跳 release 页/失败
信息性提示）。成功标准 = TASK 文件
（/Users/boyang/code/Cove/plans/TASK-check-for-updates.md）DoD 四条 +
`make generate && make test` 全绿。TASK「Decisions」七条全部照做，
不得擅自变更。

## 现状锚点（均已核实）
- 版本号：/Users/boyang/code/Cove/project.yml 第 78-79 行
  MARKETING_VERSION 0.7.0 / CURRENT_PROJECT_VERSION 5；运行时读
  Bundle.main.infoDictionary（CFBundleShortVersionString /
  CFBundleVersion），release 构建 CI 注入、读包值永远正确。
- 沙箱：/Users/boyang/code/Cove/Cove/Resources/Cove.entitlements
  已含 com.apple.security.network.client=true，HTTPS egress 无碍。
- 菜单：/Users/boyang/code/Cove/Cove/Application/AppDelegate.swift
  installMainMenu()（约 69 行起），app menu 现仅 设置…(⌘,)/退出；
  「检查更新…」插「设置…」与分隔线之间，target=self、action 指向
  新增 @objc 方法，内部转发 coordinator。
- 流程落点：/Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
  ——alert sheet 范式见约 240 行（删服务器确认，beginSheetModal(for:
  window)）与约 597 行（设置别名，accessoryView 输入框）；
  openSettings 内 mainWindowController?.showWindow(nil) 保窗口范式
  同用于检查更新入口。
- 设置页：/Users/boyang/code/Cove/Cove/Features/Preferences/Views/SettingsPaneViewController.swift
  ——手工 stack 分区（makeHeader/makeRow/makeAuxLabel 帮手约 167-203
  行用法区、237 行 sectionHeaderFont）；尾部加「关于与更新」区：
  版本行 + 「检查更新…」按钮（PillButton）+ aux 隐私说明；按钮经
  onCheckForUpdates 闭包转发（同 pane 既有意图转发范式），coordinator
  组装时接线。
- 测试缝范式：PdfReaderViewModel 的 bytesProvider 注入
  （() async throws -> Data）——UpdateService 以同款注入 fetcher，
  单测零真实网络。
- NSWorkspace 打开 URL 先例：SettingsPaneViewController.swift:345。

## 涉及文件（绝对路径）
- /Users/boyang/code/Cove/Cove/Services/Infrastructure/UpdateService.swift
  （新建：fetchLatestRelease 网络封装 + SemanticVersion/JSON 解析/
  compare 纯函数；fetcher 注入测试缝）
- /Users/boyang/code/Cove/Cove/Application/AppDelegate.swift（改：菜单项）
- /Users/boyang/code/Cove/Cove/Application/Coordination/LibraryCoordinator.swift
  （改：checkForUpdates 流程 + 三态 alert + 设置页闭包接线）
- /Users/boyang/code/Cove/Cove/Features/Preferences/Views/SettingsPaneViewController.swift
  （改：「关于与更新」分区 + 按钮转发；版本号 VC 直读 Bundle）
- /Users/boyang/code/Cove/Tests/CoveTests/UpdateServiceTests.swift
  （新建：纯函数三件套测试，零网络）
- 两个新文件跑 `make generate` 入库（project.yml 唯一事实来源，
  glob 自动收 sources）；README 由提交阶段同步，Executor 不动。

## 验收标准（DoD）
见 TASK 文件 DoD 四条；另遵守 /Users/boyang/code/Cove/AGENTS.md 硬性
规矩：禁 SwiftUI（4）、注释英文/UI 中文（6）、strict concurrency
零新警告（10）、SnapKit 只在 Views（11）、VM 无 AppKit 类型（16）、
测试 Tests/CoveTests 优先 Swift Testing（15）。GitHub API 请求必须
带 User-Agent 头（无 UA 必 403）。

## 上游任务产出
无（1.0 批 1 末卡，独立）；仅沿用既有 alert/隐私/测试缝范式。

## 协作纪律
- 开工先跑 `pwd && git rev-parse --show-toplevel && git log --oneline -1`
  确认在 /Users/boyang/code/Cove。
- 失败态永不成崩溃路径：所有网络/解析异常收敛为信息性 alert。
- 单测禁止真实网络请求（fetcher 注入全覆盖）。
- 未声明的文件改动需在提审时主动说明原因。

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、
关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述。
