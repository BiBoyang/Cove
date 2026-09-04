# TASK: 服务器远程地址（家里/远程切换）

日期：2026-08-24 ｜ 2026-09-04 排期启动 ｜ 协作模式（主会话规划/Review，另一会话实现）

## 目标复述

每台服务器可配置两个地址：LAN 地址（现有 host 字段）+ 可选远程地址（Tailscale/WireGuard/公网 IP）。界面上提供"家里/远程"快速切换；连接失败时给出"试试切到远程地址"的提示。VPN 本身由系统 VPN 应用管理（见 README 远程访问一节），Cove 不做 VPN。

## 背景与定位

- 起因：朋友想要"在外连家里 NAS"。结论：不做应用内嵌 VPN（NetworkExtension 重工程）也不驱动系统 Tailscale CLI（沙盒子进程继承沙盒、够不到 tailscaled socket），改为在 Cove 域内解决"从哪连"。
- 性质：ServerConfig 数据模型 + 添加/编辑服务器表单 + 侧栏交互 + 连接失败引导。中等体量，动持久化模型（老配置要兼容）。

## 决策记录（已拍板）

- **数据模型**：`ServerConfig` 增加 `remoteHost: String?`（nil = 未配置远程地址）。老配置（无该字段）反序列化时默认为 nil，无需迁移。
- **切换语义**：侧栏服务器行显示当前生效地址的标记（家/远程）；切换 = 修改该行生效地址并断开当前会话（切换即重连到新地址）。生效地址持久化（记住每台服务器最后用的地址）。
- **失败引导**：连接失败 alert 在该服务器配了远程地址且当前未用它时，附一句"可以试试切换到远程地址"。
- **表单**：添加服务器 sheet 增加"远程地址（可选）"输入行；编辑已有服务器可补/改远程地址（编辑入口是新增能力，v1 可以用"删除重加"替代——实现时评估编辑成本，若表单复用容易就做编辑）。
- **范围**：只做地址切换，不做 VPN 状态检测（不判断是否处于 tailnet）、不做自动切换（不根据网络环境自动选地址，v1 手动）。

## Out of Scope

应用内嵌 VPN、VPN 状态检测、自动地址选择、多地址（>2）、按域名解析策略。

## 现状摘要（2026-09-04 排期时核实）

- `Cove/Services/Infrastructure/ServerConfig.swift`：`ServerConfig` 是
  Codable 结构体，自定义 decoder 里已有 `decodeIfPresent ?? 默认` 的兼容
  先例（`displayName` 字段），`remoteHost` 照此办理即可；`ServerStore`
  是 UserDefaults + JSON 数组。
- 侧栏右键菜单已有：`ServerListViewController.swift` 里 `tableView.menu`
  + `validateMenuItem`（删除服务器项），切换动作加在这里成本最低。
- 连接失败链路：`LibraryCoordinator` 的 `onError`（"获取共享列表失败"
  约 L215 一带）是失败引导的挂点；alert 展示在更上层（MainWindowController
  链路），引导文案需要随错误上下文带上"该服务器有远程地址且未在用"的
  判断——实现时在 LibraryCoordinator 组装文案，不动 alert 展示层。
- 会话切换：`SMBSessionService`（同目录）管理连接会话；切换地址 = 断开
  当前会话 + 用新地址重连枚举 shares。

## Step 列表与 DoD

### Step 1：数据模型 + 表单

- ServerConfig 加 remoteHost + 生效地址字段（含向后兼容）；添加服务器表单加远程地址行（可选编辑入口视成本）。
- DoD：模型序列化兼容测试（老 JSON 解码=nil）；表单校验测试；`make test` 全绿。

### Step 2：切换交互 + 失败引导

- 侧栏切换动作（右键菜单项，与"删除服务器"并列）、切换即重连、失败 alert 引导文案。
- DoD：切换断开旧会话并枚举新地址（测试钉断线/重连调用）；失败引导只在配了远程地址且当前未用它时出现；`make build` 零警告。
- 真机检查点：
  a. 同一服务器配 LAN + Tailscale 两地址，家里连 LAN → 切远程 → 断开重连出 shares；
  b. 配了远程地址的服务器用错地址连接失败 → alert 带引导文案；未配远程地址的不带；
  c. 重启 app → 生效地址记住（最后用的地址）。

## 风险与回滚点

- 持久化模型变更：老配置必须无损（反序列化测试钉死）。
- 切换中断线重连的错误路径：复用现有 onError 链路，不新增弹窗类型。
- 回滚：两 Step 独立 commit。

## 验证命令

```sh
make test                    # 全量回归（含新用例）
make generate && make build  # 零警告
```

## Review 交接

按 WORKFLOW.md §5.2 Review Package，每 Step 单独提审。

## 部署备注（2026-09-04 真机验收后记）

- 验收环境：Mac（热点）→ Tailscale → 家中 Mac mini 子网路由 → NAS。
  联想个人云装不了 Tailscale，子网路由是标准解法。
- **坑：子网路由与本地网段冲突**。Mac mini 通告 `192.168.1.0/24`，但
  热点/家里网络本身握有 192.168.x.x 的路由，Tailscale 为避免打断本地
  网络不装这条子网路由。临时解法：本机手动加 /32 主机路由进 utun
  （重启即失效）；正规修法：子网路由端只通告 NAS 的 /32（如
  `--advertise-routes=192.168.1.10/32`）。
- 中继路径延迟高（1.8~4.8s，NAT 双方无直连时走 DERP）；浏览/漫画可用，
  视频靠 mpv 缓存。
- 本机 Tailscale 为源码编译的临时形态（/tmp/tailscale-bin + launchd
  plist 指向 /tmp，重启即失效）；长期使用应装官方 GUI 版。
