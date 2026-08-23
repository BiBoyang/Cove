# Cove Backlog

索引-only：每条一行 + 状态。具体任务的拆解/DoD 见对应的 `plans/TASK-*.md`。

## 进行中 / 待验收

- [ ] 真机验收残留：递归预热三态与自动取消、相邻页预取连翻
- [ ] UI 微调第一波（设计令牌 / 侧栏 / Share 卡片 / 阅读器按钮 / 路径合并）本地 commit 待推送

## 下一波（候选，未排期）

- [ ] 本地仓库 v1：右键"下载到本地仓库"（文件夹递归/单文件），LocalFileSource 虚拟 share，永不逐出；位置默认+可改（见 plans/TASK-vault.md）
- [ ] 连续纵向条带阅读器（用户已明确要做；等本地仓库轮次结束后开——相邻页预取 + CBZ 预解码已铺好地基）
- [ ] 工程债小包：spike 观测日志降级、libmpv 供应链收敛（上架前必须）、SPM .build 增量缓存问题根治
- [ ] 播放器悬浮控制条之外的 Step 3 剩余体验项（见 plans/TASK-video-playback.md §Step 3）
- [ ] 设置页搜索框启用（当前已移除占位）或另立全局搜索 feature

## 上架前必须

- [ ] libmpv 供应链收敛：brew 源码重编（-Dgl=enabled）或装配 MPVKit 静态依赖；IINA 森林的 GPL 合规审计（见 plans/SPIKE-video-playback.md §结论一）
- [ ] project.yml 填 DEVELOPMENT_TEAM + 替换占位 bundle id（AGENTS.md 已记）
- [ ] spike 观测日志降级（VideoStream 心跳 / Player 里程碑链，v1 稳定后降为 debug）

## 远期（North Star：Mac 上的 SenPlayer）

- [ ] PDF 阅读
- [ ] 连续纵向条带阅读器（A1 决策搁置，A2 稳定后再议）
- [ ] 目录模式 decode-ahead（相邻页预取的姊妹项）
- [ ] 播放器多窗口
- [ ] 本地仓库（vault）
- [ ] Preheat 解码挪出 actor（实测预热慢再做，见 PreheatScheduler.execute 注释）
- [ ] ErrorPresenter（alert 所有权扩张时，见 plans/ARCHITECTURE-AUDIT-2026-08-22.md）
- [ ] ContentItem/SMBShareInfo/ServerConfig 是否下沉共享领域包（同上，待 target 拆分时定）

## 已归档（近期完成）

- A1 单页阅读器 + 模块化架构（v0.2.0）
- A2 文件夹点击预热 + 递归预热（v0.3.0）
- 相邻页预取（目录模式）、CBZ 页预解码
- 视频播放 v1（libmpv + stream_cb，spike + 正式 Player）
