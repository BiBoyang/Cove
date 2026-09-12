# TASK: Check for updates (1.0 batch 1)

- Status: landed 2026-09-12（make generate && make test 267 全绿、构建零警告；真机 Owner 验收通过）
- Created: 2026-09-12
- Roadmap: plans/ROADMAP-1.0.md B6

## Goal
「检查更新…」入口（app 菜单 + 设置页）→ 查 GitHub Releases 最新
tag → 与运行中的 MARKETING_VERSION 比较 → alert 三态：已是最新 /
有新版（跳 release 页）/ 失败（信息性提示，永不成崩溃路径）。

## 范围核实（2026-09-12 代码实证）
- 版本号：project.yml MARKETING_VERSION 0.7.0 / CURRENT_PROJECT_VERSION 5；
  运行时读 Bundle.main（release 构建 CI 命令行注入，读包值永远正确）。
- 出站网络：sandbox entitlements 已含 network.client，HTTPS egress 无碍。
- 设置页：SettingsPaneViewController 手工 stack 分区（缓存/预热/阅读器/
  本地仓库），makeHeader/makeRow/makeAuxLabel 帮手现成，尾部加
  「关于与更新」区零障碍。
- alert 呈现先例：LibraryCoordinator 已有 beginSheetModal(for: window)
  范式（删服务器确认、设置别名弹窗）。
- API：GET api.github.com/repos/BiBoyang/Cove/releases/latest（公开、
  无 auth、无用户数据）；/releases/latest 本身不含 prerelease/draft。

## Decisions（Plan Card 拍板，Executor 照做）
1. **零新依赖**：URLSession GET 一次；服务落 Services/Infrastructure/
   UpdateService.swift（新文件，跑 make generate 入库）。网络细节
   （URL、Accept/User-Agent 头——GitHub API 无 UA 必 403）封装在
   服务内；VC/菜单不碰网络（规矩 3 精神延伸到 HTTPS）。
2. **纯函数可测三件套**：SemanticVersion（v 前缀容忍、三段数字
   比较、非数字段容错）+ release JSON 解析（tag_name/html_url，
   Codable）+ compare 三态。网络层以注入 fetcher（() async throws
   -> Data）为测试缝，单测零真实网络。
3. **流程归属**：LibraryCoordinator.checkForUpdates() 持有
   UpdateService、跑查询、在主窗口 sheet alert（先 showWindow 保
   窗口在）；AppDelegate 菜单项与设置页按钮都转发到这一入口，
   alert 流程单点不复制。
4. **入口两处**：app 菜单「检查更新…」置「设置…」之下（无快捷键）；
   设置页尾部「关于与更新」区 = 版本行（「版本 0.7.0 (5)」，VC 直读
   Bundle 常量不进 VM——非会话状态）+「检查更新…」按钮 + aux 说明
   「通过 GitHub Releases 检查，不含任何用户数据」。
5. **三态 alert 文案中文**：已是最新（当前已是最新版本 (0.7.0)）/
   有新版（发现新版本 vX.Y.Z，按钮 前往下载/取消，前往 =
   NSWorkspace open html_url）/ 失败（无法检查更新，请检查网络
   连接后重试——信息性、无重试按钮、无崩溃路径；rate limit 归入
   失败态）。
6. **不做静默定期检查**（拍板）：manual-only 满足 1.0 更新通道
   语义，零后台网络/状态成本；自动检查与 Sparkle 2 升级留 1.x。
7. README 提交阶段补：更新检查功能 + 隐私说明（查询仅含仓库
   公开 API，无用户数据）。

## Out of scope
Sparkle/自动下载/自动安装；后台定期检查；release notes 内嵌展示；
prerelease 通道（/releases/latest 语义即稳定版）。

## Steps
1. UpdateService + 纯函数三件套 + 单测（零网络）。
2. 接线：菜单项 + coordinator 流程 + 设置页分区 + 三态 alert。
3. 验证：make generate && make test 全绿 + 真机验收清单。

## DoD
1. SemanticVersion 比较测试覆盖：相等/更旧/更新/v 前缀/异常串；
   JSON 解析测试：正常/缺字段/坏数据。
2. 菜单项与设置页按钮均接同一入口；三态 alert 文案中文。
3. `make generate && make test` 全绿。
4. 真机：菜单点「检查更新…」→「已是最新」alert（0.7.0 vs 当时
   latest）；断网再点 → 失败信息 alert 且不崩；设置页分区显示
   版本号且按钮同效。（「有新版」态由纯函数测试 + alert 代码路径
   覆盖，真机不强求——制造真新版成本高于收益。）

## Risks
- GitHub API 无 User-Agent 头必 403 → 锚点写死。
- 无 auth rate limit 60/h → 手动检查远低于限；失败态文案兜底。
- alert 在无窗场景 → showWindow(nil) 先行（openSettings 同范式）。
- 新文件需 make generate 重新生成工程（project.yml 唯一事实来源，
  glob 自动收 sources）。
