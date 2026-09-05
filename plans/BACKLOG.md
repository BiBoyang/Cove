# Cove Backlog

索引-only：每条一行 + 状态。具体任务的拆解/DoD 见对应的 `plans/TASK-*.md`。

## 进行中 / 待验收

- [ ] UI 统一优化主线：选题池与证据见 plans/UI-AUDIT-2026-09-05.md（按 §4 性价比顺序推进），令牌图纸 design/DESIGN-TOKENS.md；下一张卡 = SF Symbols 一致性

## 下一波（候选，未排期）

- [ ] flaky 观察：ContinuousReaderViewModelTests "measurements land as one anchored batch" 高负载下偶发超时（CI 任务实测复跑即过），若 CI 上再红优先治理
- [ ] 开发期观察（2026-09-05 实证存档）：ad-hoc 重建（make build）改变签名后，**首个会话**内 Keychain 密码读取（`KeychainKit.KeychainError error 0`）与 vault security-scoped bookmark 创建/解析失效（os_log: `Vault bookmark failed to resolve; falling back to the default root`），优雅重启 App 后自愈。仅影响开发期体验（正式签名上架后不存在）；若频繁干扰再立项，方向：书签创建失败时降级为纯路径存储 + 下次启动重新授权

## 上架前必须

- [ ] libmpv 供应链收敛：brew 源码重编（-Dgl=enabled）或装配 MPVKit 静态依赖；IINA 森林的 GPL 合规审计（见 plans/archive/SPIKE-video-playback.md §结论一 + 2026-08-27 调研追加）
- [ ] project.yml 填 DEVELOPMENT_TEAM + 替换占位 bundle id（AGENTS.md 已记）

## 远期（North Star：Mac 上的一流 NAS 媒体中心）

- [ ] iPad 端扩展（优先 iPad）：UIKit 手写（全平台禁用 SwiftUI，沿用 SnapKit
  DSL 与 MVVM/Coordinator 范式），Frameworks/Services/ViewModel 整体复用（前提见
  AGENTS.md 规矩 16），视频播放最后攻（待 libmpv 供应链收敛）。跨端 UI 一致性靠
  共享设计规范而非代码：后续 Mac 端 UI 优化任务须把色值/字号/间距/圆角等设计决策
  沉淀为平台无关的设计令牌文档，作为 iOS 重写的图纸
- [ ] 目录模式 decode-ahead（相邻页预取的姊妹项）
- [ ] 播放器多窗口
- [ ] Preheat 解码挪出 actor（实测预热慢再做，见 PreheatScheduler.execute 注释）
- [ ] ErrorPresenter（alert 所有权扩张时，见 plans/archive/ARCHITECTURE-AUDIT-2026-08-22.md）
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
- 阅读位置记忆：cbz/目录记住最后页码、看完即删、可撤销浮层 + 设置开关（见 plans/archive/TASK-reader-position-memory.md，2026-09-04 真机通过）
- 条带自动滚屏：110 pt/s 匀速、手动重定位不中断、缩放/到底/切模式停止（见 plans/archive/TASK-strip-autoscroll.md，2026-09-04 真机通过）
- 滚屏速度三档 0.5x/1x/2x（右键循环 + SettingsService 持久化）+ 单页自动翻页 slideshow（5s 固定、手动接管即停、末页即停）（见 plans/archive/TASK-autoscroll-speed-gears.md、plans/archive/TASK-paged-slideshow.md，2026-09-05 真机通过）
- 目录浏览滚动修复：切目录回顶、返回上级揭示并选中来源文件夹（2026-09-05 真机通过）
- 单页模式缩放：⌘ 四档 + 拖拽平移 + 翻页/resize 重置（见 plans/archive/TASK-reader-paged-zoom.md，2026-09-04 真机通过）
- CI 落地：push/PR/每日 02:00 门控全量测试（framework + app 双 job，含失败演练实证）；根治 .pcm 增量腐坏（禁 explicitly-built-modules）（见 plans/archive/TASK-ci.md，2026-09-05）
- 服务器远程地址：remoteHost 双地址 + 右键切换 + 失败引导 + 生效地址持久化（见 plans/archive/TASK-remote-address.md，2026-09-04 热点实测机制五项 + Tailscale 子网路由端到端联通全过）
- SMB 连接/枚举显式超时 15s 快速失败 + 摘除 ETIMEDOUT 透明重试（见 plans/archive/TASK-smb-timeout.md，2026-09-05 smb-spike 黑洞实测 15.1s/15.0s 达标）
- CBZ 行 badge 修复：符号名 books.closed.fill（不存在）→ book.closed.fill（见 plans/archive/TASK-fix-cbz-badge-symbol.md，2026-09-05 真机通过）
- 浏览器 drill-down 首帧滚动错乱（沉底/空白）修复：reloadData 后强制布局再复位（见 plans/archive/TASK-browser-scroll-reset.md，2026-09-05 真机通过）
- UI 现状盘点 2026-09-05：plans/UI-AUDIT-2026-09-05.md + 29 张证据截图；平台无关设计令牌图纸 design/DESIGN-TOKENS.md 建立（四项决策已拍板）
- 空态与加载态体系（库界面）：StatePlaceholderView 组件 + share 网格加载 spinner/失败占位+重试（不再与 alert 双重提示）/零服务器引导 + 浏览器空文件夹与目录加载态（见 plans/archive/TASK-empty-loading-states.md，2026-09-05 真机通过）
- 网格细节：share 卡片 cardBorderColor rest 描边、hover-fill/radiusRowSelection/overlay 按钮配方三族令牌落地、浏览器右键选中联动（见 plans/archive/TASK-grid-card-details.md，2026-09-05 真机通过）
- 排版层级：form-label/mono-digit/overlay-flash 三档字体令牌落地，9/10pt 越刻度废除、15pt 闪现去重、设置窗口分区标题回归 11sb（见 plans/archive/TASK-typography-scale.md，2026-09-05 真机通过）
- 阅读器自定义 X 关闭钮删除：与红绿灯重叠的冗余按钮，关闭收尾本就走 willCloseNotification（audit BUG-2，2026-09-05 真机通过）
