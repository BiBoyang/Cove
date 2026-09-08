# TASK: 开发期书签/Keychain 失效自愈

日期：2026-09-08 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：plans/BACKLOG.md 下一波观察项（2026-09-05 实证存档）——ad-hoc 重建
改变签名后首个会话 Keychain 读取（KeychainError error 0）与 vault
security-scoped bookmark 解析失效，优雅重启自愈。

## 目标复述

开发期 `make build` 重签后，首个会话不再静默失效：失效可检测、有兜底
行为、有明确的恢复路径。正式签名上架后此问题不存在，本卡只服务开发期
体验。

## 实态核查（2026-09-08）

- 书签链路：`SettingsService.vaultRootBookmark`（UserDefaults 存 Data）→
  `VaultService.resolveRoot`（`Cove/Services/Vault/VaultService.swift:80-97`）
  解析失败仅记日志并回落默认根目录。
- Keychain 链路：KeychainKit 薄封装，首会话读取抛 `error 0`。
- 沙箱约束：entitlement 仅 `files.user-selected.read-write`——纯路径兜底
  **拿不到**容器外访问权，"降级为纯路径存储直接读"大概率不成立，
  Step 1 须实证。

## Step 列表与 DoD

### Step 1 spike：确诊失效机制
- 复现脚本化：连续两次 `make build`（签名变化）→ 启动 App 观测首会话：
  哪个 API 先死、确切错误码（bookmark resolve 的 NSError domain/code、
  Keychain 的 errSec 值）；"重启自愈"的兑现路径是什么。
- 实证沙箱下纯路径兜底是否有访问权（大概率没有，拿到证据）。
- DoD：一页结论（机制 + 错误码 + 可行修复面），附日志证据；
  不写修复代码。

### Step 2 修复
- 按 spike 结论落地，候选方向（以证据为准）：
  a. 书签失效检测 → 设置页 vault 行显示"需要重新选择位置"引导，用户点
     「更改…」重选即重建书签（最可能形态）；
  b. 若纯路径实证可用 → 静默降级 + 下次启动重建书签。
- Keychain error 0 同理：检测后给可恢复行为（重试/重新输入引导），
  不许静默失败。
- DoD：build 零警告、make test 全绿（失效检测与降级逻辑单测）；
  真机验收：双次构建后首会话 vault 有明确恢复路径，不再静默回落默认根。

## 风险与回滚点

- 这是开发期-only 问题，修复复杂度不许外溢到正式签名路径——若 spike
  证明修复成本高，可拍板降级为"文档化已知行为"。
- 每 Step 单 commit 可 revert。

## 验证

- Step 1：诊断日志证据。Step 2：单测 + 真机验收清单（说人话）。
- 提审附用户验收清单（§5.2），Step 以用户验收通过为闭环。
