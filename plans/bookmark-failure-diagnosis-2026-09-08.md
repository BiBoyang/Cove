# 诊断：开发期书签/Keychain 失效机制（Step 1 spike）

日期：2026-09-08 ｜ 环境：macOS 27.0 (26A5416b) / Xcode 26.6 (17F113) / HEAD 3d6ab0a
上游：plans/TASK-dev-bookmark-resilience.md（2026-09-05 实证存档：ad-hoc 重建后首个会话
Keychain `KeychainError error 0` + vault 书签解析失效，优雅重启自愈）

## 结论（三行版）

1. **书签与 Keychain 都不是"签名变化（cdhash）后首个会话必坏"**：同 identifier、同路径、同
   entitlement 的三轮签名切换 + 重签窗口 210+ 次启动全部健康——书签按**签名 identifier**
   绑定，Keychain 项在 cdhash 变化下仍可读。
2. **唯一实证失败发生在"身份过渡窗口内的测试基础设施启动"**：重建进行中由 testmanagerd
   （Xcode 测试发现）拉起的 App 进程命中书签解析失败（生产日志原文抓到）；Keychain 侧对
   **entitlement 内容/路径变化**敏感，触发 SecurityAgent 阻塞式弹窗（拒绝后 errSecUserCanceled
   -128）；9/5 存档的 error 0（查询成功但返回空项）属同一"身份过渡"症候群。
3. **纯路径兜底实证不成立**：沙箱下无书签授权时对容器外目录读/写一律 EPERM
   （NSCocoaErrorDomain 257/513，POSIX 1），Debug 与正式 entitlement 下均如此。

## 实证矩阵

探针：临时文件 `Cove/Application/SpikeProbe.swift`（TEMP-SPIKE，已移除），env `COVE_SPIKE`
触发（setup/probe/bmprobe/kcprobe/pathprobe/cleanup），直exec 启动抓 stderr + os_log 双通道。
测试状态：SPIKE 专用 Keychain 项（假密码）+ 指向 `/Users/Shared/cove-spike-vault` 的
security-scoped 书签（已由收尾清理）；另只读探测用户 2026-08-20 真实 Keychain 项作对照。

| # | 场景 | 书签解析 | Keychain 读取 |
|---|------|---------|--------------|
| 1 | 基线（同构建同会话） | OK | status=0 |
| 2 | 干净签名切换 P1→P2→P3→P4（仅 cdhash 变，3 轮首会话） | OK ×3 | status=0 ×3（含 8/20 旧项） |
| 3 | 重建进行中连发启动 141 次（直接 exec + `open -n` 混合） | 零失败 | 零失败 |
| 4 | 手动 `codesign --force` 重签瞬间连发启动 70 次 | 零失败 | 零失败 |
| 5 | **重建进行中 testmanagerd 测试宿主启动（pid 11922, 08:17:55）** | **失败**（生产日志原文） | 未走到 |
| 6 | 同路径手动重签、entitlement 换成正式三项 | OK | **-128（弹窗被拒）** |
| 7 | 同路径手动重签、entitlement 用回 Debug xcent | OK | status=0 |
| 8 | 拷贝到 /tmp 重签（路径+entitlement+cdhash 全变） | OK | **-128（SecurityAgent 弹窗要求登录钥匙串密码）** |
| 9 | 无授权直接 `bookmarkData(.withSecurityScope)` 创建书签 | 失败 NSCocoaErrorDomain:256 | — |
| 10 | 异 identifier ad-hoc 工具创建的书签 | 失败 NSCocoaErrorDomain:259 | — |
| 11 | 同 identifier（`com.biboyang.cove`）CLI 创建的书签 | OK（跨二进制！） | — |
| 12 | 纯路径访问容器外目录（无书签授权，Debug/正式 entitlement 各一轮） | — | list/read=257, write=513（POSIX EPERM） |

补充：同源连续两次 `make build` **cdhash 不变**（ad-hoc 签名确定性，P1 前后两次
38acb4c7…）——"重建改变签名"需要真实代码改动；9/5 的触发构建是正常开发迭代。

## 机制分析

**书签（security-scoped bookmark）**
- 绑定粒度是**签名 identifier**，不是 cdhash、不是路径、不是 entitlement（#5 之外的矩阵
  全部支持；#10/#11 交叉验证）。`URL(resolvingBookmarkData: .withSecurityScope)` 对异
  identifier 书签报 259（NSFileReadCorruptFileError），对无授权路径**创建**报 256
  （NSFileReadUnknownError）——沙箱下 App 无法自造容器外书签，授权只能来自 NSOpenPanel。
- 实证失败（#5）的进程由 testmanagerd 以独立 daemon 容器/persona 拉起，且正值包内
  重签窗口：secinitd 对该 pid 报 "Unable to obtain persona info"，书签解析随即失败。
  即失效窗口 = **身份/上下文处于过渡态的启动**（测试基础设施 + 重建中包重写叠加），
  而非"新签名的首个正常会话"。

**Keychain（generic password，无 access group）**
- cdhash 变化（同路径同 entitlement）不影响读取（#2/#7）；**entitlement 内容变化**（#6）
  或**路径+cdhash 整体迁移**（#8）会使项 ACL 不再信任调用方 → SecurityAgent 弹窗（要求
  输入登录钥匙串密码，按钮 始终允许/拒绝/允许）→ 拒绝/无法交互时返回 **errSecUserCanceled
  -128**。
- 9/5 存档的 `KeychainError error 0` = `unexpectedData`（SecItemCopyMatching 返回
  errSecSuccess 但结果为空项），今日未复现；结合 #5，定位为同一"身份过渡窗口"内 securityd
  的异常应答形态。存档中"书签创建失效"亦与 #9 一致——无 NSOpenPanel 授权时创建永远失败，
  与签名无关。
- `make test` 日志里的 "Keychain 中找不到该服务器的密码"×3 是**测试桩常态**（测试用假
  UUID 无对应 Keychain 项），与本问题无关，勿误判。

**自愈兑现路径**
- 无持久损坏态：过渡窗口结束（构建完成/正常路径启动）后下一次启动全部恢复健康。
  "优雅重启自愈"即此——与退出方式无关（没有需要清理的状态），正常启动本身即修复。

**纯路径兜底（任务卡 Step 1 问题 2）**
- 一句话结论：**不成立**——沙箱下未获授权时容器外目录连读都是 EPERM。
- 值得记录：Xcode 26 给 Debug 构建签名注入了
  `temporary-exception.files.absolute-path.read-only: [/]`，但 macOS 27 沙箱**不兑现**
  该例外（#12 Debug 轮读仍 257/EPERM）。不要依赖它。

## 修复面评估（Step 2 候选）

- **a. 检测 + 设置页引导重选（推荐）**：`resolveRoot` 把"有书签但解析失败"从吞错改为可观察
  状态，设置页 vault 行显示「需要重新选择位置」，用户点「更改…」走 NSOpenPanel 重建书签。
  恢复路径与根因解耦（无论触发因是什么都有效），成本最低，覆盖书签侧全部症候。
  Keychain 侧同理把错误细分：-25300（无项，现有文案）/ -128（弹窗被拒，引导重试或重新
  输入）/ 其他（提示重启自愈）——不许再静默失败。
- **b. 静默降级纯路径**：实证排除（#12）。
- **c. 其他**：i) 重启自动重试——无持久态可修，重启即愈，等于现状，无增量价值；
  ii) 按任务卡回退条款降级为"文档化已知行为"——本文档即该产物；iii) 正式签名
  （Developer ID + Team ID）后 identifier 有强背书，此类窗口显著收窄，修复不许外溢到
  正式路径。

## 复现工具（一次性，/tmp/cove-spike/，重启即失）

- `session.sh <label> <mode> [app]`：单会话探针（env 注入 + 自终止）。
- `race.sh <秒>`：构建窗口连发启动（直接 exec 与 `open -n` 交替）。
- `bmmake.swift`：CLI 创建 security-scoped 书签（`codesign -s - -i com.biboyang.cove`
  变体验证 identifier 绑定）。
- `shipresign.sh`：拷贝包以正式 entitlement 重签（隔离 entitlement/路径变量）。
- 探针源码为 TEMP 插桩，验收前已移除（见下）。

## 收尾状态

- TEMP 插桩（SpikeProbe.swift + AppDelegate 一行挂钩）已移除；SPIKE Keychain 项、
  vault 书签、`/Users/Shared/cove-spike-vault` 均已清理；8/20 真实 Keychain 项未动
  （弹窗一律点的「拒绝」，ACL 未变）。
- 仓库另有并行的发布打包改动（release.yml 等 4 文件，他人 staged）——非本 spike 产物。
