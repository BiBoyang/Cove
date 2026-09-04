# TASK: SMB 连接/枚举显式超时（~15s）

日期：2026-09-05 ｜ 协作模式（助手规划/Review，其他 agent 实现）

## 目标复述

连不可达/黑洞地址时，SMB 连接与共享枚举现在按 AMSMB2 默认 60s 才报错
（SourceKit 从未设置过 `timeout` 属性），失败引导 alert 出现太慢——
远程地址功能的配套缺口，普通 LAN 连错地址同样受益。目标：连接与共享
枚举 15s 左右快速失败，读取路径行为不变。

## 决策记录（建议拍板项，实现前确认）

- **超时值 15s**：backlog 原定 ~15s。定义常量
  `SMBTimeout.connect: TimeInterval = 15`（SourceKit 内部，SMBSource 与
  SMBServer 共用）。
- **作用范围：只给连接期与共享枚举提速**。`timeout` 是 client 级属性
  （AMSMB2.swift:43），设在 SMBSource 的 client 上会同时裹住后续
  read。因此 SMBSource.connect 的做法是：新建 client 后设
  `timeout = SMBTimeout.connect`，`connectShare` **成功后调回 60**
  （读路径维持现状：单页图 range read 通常秒级，但慢链路大文件不应被
  15s 误杀；视频流另有 VideoStreamBridge 30s 硬超时兜底）。
  SMBServer 的 client 每次新建、只用于枚举，直接设 15s 即可。
- **超时错误不再透明重试**：把 `.ETIMEDOUT` 移出
  `TransientRetry.retryable`（TransientRetry.swift:14）。否则黑洞地址
  的最坏耗时是 2×15s+0.5s ≈ 30s，与"失败引导要快"相悖。其余
  EIO/ECONNRESET/EHOSTUNREACH 等保留（它们本身失败很快，重试有价值
  ——进程启动初期 EIO 抖动是真机观测过的）。注释同步改写。
- **DNS 盲区不治理**（本任务 Out of Scope）：libsmb2 的
  `getaddrinfo` 是阻塞同步调用（socket.c:1229），在 poll 超时循环之
  外——主机名解析卡死不受 timeout 保护。远程地址功能是 IP 直连，不
  受影响；主机名场景的异步 DNS 化是另一个任务。

## Out of Scope

- 目录 list / metadata / read 的超时调整（连接成功后即调回 60s）。
- DNS 解析超时（见上）。
- UI 文案/引导改动（RemoteEndpointHint 已存在，错误冒泡链不动）。

## 现状摘要

- AMSMB2 4.0.3 有公开 `timeout` 属性（默认 60，connect 也走
  `wait_for_reply` 的 poll 超时，Context.swift:364-384）——本任务是
  纯接线，不改依赖、不引入新 API。
- 接线点仅两处：`SMBSource.connect`（SMBSource.swift:40-46，
  TransientRetry.run 内每次新建 client）与 `SMBServer.listShares`
  （SMBServer.swift:54-59）。
- 单测可测点：`TransientRetry`（现有 TransientRetryTests 注入
  POSIXError 测重试语义，更新 ETIMEDOUT 用例即可）。SMBSource 的
  AMSMB2 client 无注入 seam，超时接线本身不硬造单测。
- 验证工具现成：smb-spike 默认模式走 SMBSource 真实 connect 路径且
  内建 connect 计时（SMBSpike.swift:85-95），`--shares` 走 SMBServer。

## Step 列表与 DoD

### Step 1：超时接线 + 重试语义调整（单 Step，全量 <30 行）

- 改动文件：
  - `Frameworks/SourceKit/Sources/SourceKit/SMBSource.swift`（常量 +
    connect 期设 15s、成功后调回 60）
  - `Frameworks/SourceKit/Sources/SourceKit/SMBServer.swift`（枚举 client 设 15s）
  - `Frameworks/SourceKit/Sources/SourceKit/TransientRetry.swift`（移除
    .ETIMEDOUT + 注释改写）
  - `Frameworks/SourceKit/Tests/SourceKitTests/TransientRetryTests.swift`
    （ETIMEDOUT 用例改为"不重试"）
- DoD：
  1. `make test` 全绿（含更新后的 TransientRetry 用例）。
  2. smb-spike 连黑洞地址（内网无主机 IP，如 192.168.x.254）实测：
     默认模式 connect 在 ~15s 报超时错误（改造前对照为 ~60s）；`--shares`
     同样 ~15s。
  3. 真机：服务器右键切到一个不可达地址（或配错远程地址）→ 双击连接，
     失败引导 alert ~15s 内出现；正常 NAS 连接/读图/播视频无回归。

## 风险与回滚点

- **15s 对慢链路是否够**：Tailscale 跨网首连（NAT 打洞冷启动）个别
  场景可能 >15s——真机检查点 3 覆盖；若误杀真实场景，调常量即可。
- **调回 60 的时机**：connectShare 成功后才调回，失败路径不重试不
  遗留状态（每次尝试都是新 client）。
- 回滚：单 Step revert 即恢复 60s 默认 + 超时重试。

## 验证命令

```sh
make test
# 黑洞地址实测（替换为内网无主机 IP；密码参数仅开发期探针用途）
.build/debug/smb-spike <blackhole-ip> <share> <user> <password>
.build/debug/smb-spike <blackhole-ip> <share> <user> <password> --shares
```
