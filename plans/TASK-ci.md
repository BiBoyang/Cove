# TASK: CI 落地 + 禁 explicitly-built-modules

日期：2026-09-04 ｜ 协作模式（助手规划/Review，其他 agent 实现）｜ 参考：用户博文
《GitHub Actions 每日自动测试：从 schedule 踩坑到跑通》（biboyang.github.io）

## 目标复述

给 Cove 上 GitHub Actions：push/PR 跑全量测试；每日定时兜底（近 24h 无
commit 跳过）。顺手根治 Xcode 26 的 .pcm 增量腐坏（禁 explicitly built
modules）。

## 决策记录（已拍板）

- **触发模型照抄博文**：`push`/`pull_request`（main）+ `workflow_dispatch` +
  `schedule`（cron `0 18 * * *` = 北京 02:00）；schedule 由前置
  `check-changes` job（ubuntu-latest，github-script 查 24h 内 commit）门控，
  非 schedule 事件直接跑。
- **两个测试 job 分层**：
  - `framework-tests`（macos-latest）：8 个 Framework 包
    `swift test --scratch-path .build`（对齐 Makefile 共享 scratch），
    不需要 libmpv，快；
  - `app-tests`（macos-latest）：brew 装 xcodegen → 下载 IINA dmg
    （GitHub releases，钉版本号）→ hdiutil 挂载 →
    `IINA_APP=... scripts/assemble-libmpv.sh` → `make generate` →
    `make build` → xcodebuild 跑 CoveTests。这是唯一能验 App target 的路径。
- **博文踩坑对策全部内置**：显式选 Xcode（`/Applications/Xcode_*.app`
  从高到低探测）；测试输出 `tee` 落盘 + `if: always()` tail 末尾 200 行；
  日志 artifact 上传。
- **EBM 关闭**：`project.yml` 加 `CLANG_ENABLE_EXPLICIT_MODULES: NO` +
  `SWIFT_ENABLE_EXPLICIT_MODULES: NO`（2026-09-04 本地 .pcm 丢失致
  libsmb2 编译失败，clean 才恢复——禁掉 EBM 从根上消掉这类腐坏），
  改完 `make generate` 重建工程。
- 仓库公开 → macOS 分钟免费，但 schedule 无变更空跑仍要 check-changes 挡住。

## Out of Scope

- SwiftLint/swift-format 门禁、SMB 集成测试替身（明确缓做，BACKLOG 已记候选）。
- 发布/打包 CI（上架前的事）。

## 现状摘要

- 无 `.github/workflows`；`Makefile` 的 test 目标 = 8 包 swift test +
  xcodebuild CoveTests + smb-spike 编译检查，CI 拆成两个 job 复用同一批命令。
- `scripts/assemble-libmpv.sh` 支持 `IINA_APP` 覆盖——CI 注入 dmg 里的
  IINA.app 即可；IINA 在 GitHub releases 分发 dmg（iina/iina）。
- 博文已验证的模式直接复用，不重新发明。

## Step 列表与 DoD

### Step 1：EBM 关闭（小，先行）

- 改动：`project.yml` 两个 build setting + `make generate`。
- DoD：本地 `make generate && make build` 零警告、增量重建两次无 .pcm 类
  故障；`make test` 全绿。

### Step 2：CI workflow

- 改动：`.github/workflows/ci.yml`（新建，唯一新文件）。
- DoD：
  1. workflow_dispatch 手动触发全绿（framework-tests + app-tests 两 job）；
  2. push 到 main 触发全绿；
  3. schedule 空跑验证：无 24h 变更时 check-changes 输出 false、测试 job
     被跳过（可用临时分支或等自然周期验证，验证不了就在 Review Package
     里说明）；
  4. 失败路径演练：往测试里塞一个临时断言失败（本地验证 push 后 CI 红、
     日志 tail 可见失败点）→ 立即 revert。可选但推荐。

## 风险与回滚点

- **IINA 下载是外部依赖**：版本号钉死 + URL 失效时 CI 红（fail-loud，
  可接受）；备选是 Framework-only CI。
- **app-tests 时长**：IINA 下载 + 全量编译预计 10~15 分钟，schedule 每日
  一次可接受；push 频率高的话后续可加路径过滤。
- 回滚：删 workflow 文件 + revert project.yml 两行。

## 验证命令

```sh
make generate && make build  # EBM 关闭后零警告
make test                    # 全量回归
# CI 侧：workflow_dispatch 手动触发 → Actions 页全绿
```
