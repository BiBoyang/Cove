# Cove Backlog

索引-only：每条一行 + 状态。具体任务的拆解/DoD 见对应的 `plans/TASK-*.md`。

## 进行中 / 待验收

- [ ] 阅读位置记忆（已实现待真机验收，见 plans/TASK-reader-position-memory.md）
- [ ] 条带自动滚屏（已实现待真机验收，见 plans/TASK-strip-autoscroll.md）

## 下一波（候选，未排期）

- [ ] 服务器远程地址（家里/远程切换）：Tailscale/WireGuard 远程访问的 Cove 侧方案（见 plans/TASK-remote-address.md；不急，待排期）
- [ ] 单页模式缩放：⌘ 档位放大 + 拖拽平移（见 plans/TASK-reader-paged-zoom.md，可派 agent）

## 上架前必须

- [ ] libmpv 供应链收敛：brew 源码重编（-Dgl=enabled）或装配 MPVKit 静态依赖；IINA 森林的 GPL 合规审计（见 plans/SPIKE-video-playback.md §结论一 + 2026-08-27 调研追加）
- [ ] project.yml 填 DEVELOPMENT_TEAM + 替换占位 bundle id（AGENTS.md 已记）

## 远期（North Star：Mac 上的一流 NAS 媒体中心）

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
- 视频播放 v1（libmpv + stream_cb，spike + 正式 Player）、悬浮控制条、记忆播放位置（v0.4.0）
- UI 微调第一波（设计令牌、侧栏、Share 卡片、阅读器控件、浏览器行重做、面包屑）
- PDF 阅读 v1（整包缓存 + PDFKit）、本地仓库 v1（LocalFileSource + 右键下载/删除 + 位置设置）（v0.5.0）
- 连续纵向条带阅读器 v1（CBZ 默认条带、模式切换保留当前页）
- 远程访问教程（README：Tailscale/WireGuard 组网后按 IP 直连）
- 工程债小包：spike 观测日志降级（warn+ 按 mpv 级别映射，里程碑链/心跳降 debug）、SPM 共享 scratch-path（make test 共享依赖只编一次，.build 总量 1.8GB→388MB）
- 真机验收收尾：递归预热三态与自动取消、相邻页预取连翻（2026-08-27 真机通过）
- App 图标与 logo：D1 层叠浪线方向，appiconset 全尺寸 + design/logo 矢量源
- 播放器传输包：Up Next 倒计时、五种播放模式、倍速（跨集记忆）、播放列表面板、mpv keep-open 停最后一帧（2026-09-04）
- 暖黑风格库界面：全局深色、暖黑调色板、行高收紧、金色 accent（2026-09-04）
- 条带阅读器打磨：模式偏好按内容类型持久化、条带缩放（⌘ 四档 + 倍数闪现 + 横向滚动）、跳页 scrubber（见 plans/archive/TASK-reader-strip-polish.md，2026-09-04）
