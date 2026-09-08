# Cove Backlog

索引-only：每条一行 + 状态。具体任务的拆解/DoD 见对应的 `plans/TASK-*.md`。

## 进行中 / 待验收

- [ ] UI 统一优化主线：选题池与证据见 plans/UI-AUDIT-2026-09-05.md（按 §4 性价比顺序推进），令牌图纸 design/DESIGN-TOKENS.md；P1–P6 + 设置迁移 + 胶囊重构 + audit 清扫 + spacing 令牌族全部落地，audit 散点清零（2026-09-07 真机通过）；候选下一张卡 = 新选题（用户点题）

## 下一波（候选，未排期）

（空）

## 上架前必须

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
- SF Symbols 一致性：symbolSmall/Medium/Large/Hero 四档尺寸令牌落地，音量图标随音量四档分档，权重约定入令牌文档 §4.5（见 plans/archive/TASK-symbol-consistency.md，2026-09-05 真机通过）
- 设置迁移进 App：独立窗口退役，设置成为侧栏目的地（本地仓库同区），四分区迁入主区滚动页、NSOpenPanel 改挂主窗口、Cmd+, 重定向（协作模式三步，见 plans/archive/TASK-settings-in-app.md，2026-09-05 真机通过）
- 阅读器自定义 X 关闭钮删除：与红绿灯重叠的冗余按钮，关闭收尾本就走 willCloseNotification（audit BUG-2，2026-09-05 真机通过）
- 克制的动效：motionFast 0.15s / motionMedium 0.25s 两档动效令牌、share 卡片 hover/选中 fill 过渡、占位视图淡入（见 plans/archive/TASK-restrained-motion.md，2026-09-07 真机通过）
- 媒体 chrome 整治：surfaceOverlay 不透明底板 / textOnMedia 三档 / readerBackground 令牌落地，条带 pill 可见性 + 单页 chrome pill 化，mpv 原生 OSD 根治 + codec chips 随控制条显隐，弹层暖黑化 + accent glyph 选中（废白 checkmark）+ Up Next pill 按钮，播放器中央加载/失败占位；验收修复音量读数定宽与 Up Next 立即播放接线（后者为功能首提交起的潜伏断线）（见 plans/archive/TASK-media-chrome.md，2026-09-07 真机通过）
- 播放器控制条布局重构：IINA 式底部居中双排窄胶囊（上排音量组 + transport + 工具钮，下排进度条 + 两端时间码）+ 窗口 minSize 520×320，Up Next bottom 魔数 -76 → 锚定胶囊顶 +12（见 plans/archive/TASK-player-controls-capsule.md，2026-09-07 真机通过）
- UI audit 残余清扫：vault 缩略图接通 ThumbnailService（BUG-5 判定漏接）、设置页五钮统一 PillButton 配方（E3）、U2/U3 复核销项 + U4 系统蓝拍板入 §6.8、vault 红线注释随缩略图缓存例外同步（见 plans/archive/TASK-ui-audit-sweep.md，2026-09-07 真机通过）
- spacing/尺寸令牌族：spacing 数值档 10 档（收编 2pt 子档 6/10/14）+ 组件尺寸角色族（行高/控件/胶囊等 19 角色），全仓 142 处散点同值迁移零视觉变化，豁免清单入 §3.4；audit U1 销项（见 plans/archive/TASK-spacing-tokens.md，2026-09-07 真机通过）
- 侧栏宽度漂移修复：根因=设置页 999 优先级等宽填充约束把 pane 宽度意见传导进 NSSplitView 分栏仲裁（压过侧栏 250 holding）；修复=填充目标改常量 560 + 侧栏 maximumThickness 320 兜底 + 约束图不变量测试（2026-09-07 真机通过，Codex 执行、助手 Review）
- ContinuousReader 测试 deflake：根因=测量落地后窗口扩容使轮询观察窗仅约一个 load 延迟（瞬态中间态被轮询错过）；修复=事件驱动等待 + 闩锁，断言零削弱（2026-09-08，外派 agent 执行、助手 Review）
- 开发期书签/Keychain 失效自愈：spike 推翻"签名变化后首会话必坏"——失效窗口实为身份过渡态启动（210+ 次正常启动全健康），纯路径兜底沙箱下 EPERM 实证不成立；修复=书签失效可观察化 + 设置页红字引导重选 + Keychain 读取错误三分支（-25300/-128/其他），测试证据闭环（含沙箱测试宿主真书签端到端），真机视觉抽查因 TCC 容器权限待补（见 plans/archive/TASK-dev-bookmark-resilience.md + plans/bookmark-failure-diagnosis-2026-09-08.md，2026-09-08）
- GitHub Release 分发管线（B1 CI 全托管）：tag v* 触发全自动——自建森林（缓存）→ arm64 archive → Developer ID 签名 → 双轮公证+staple → dmg → 自动 notes。落地后三轮实证修复：job env 误用 runner.temp 致 workflow 无效（rc1 空跑）、无头 runner GL 探针失败（rc2，CI 跳 probe/selfcheck 保指纹步）、universal 链接撞 arm64-only 森林（rc3，钉 ARCHS=arm64）、spctl 对裸 dmg 无评估上下文误报（rc4，Gatekeeper 预演移到 App）。v0.6.0-rc5 全绿，本机核验 dmg：Notarized Developer ID + staple + 版本注入全过（见 plans/archive/TASK-release-packaging.md，2026-09-08 真机验收通过）
- libmpv 供应链收敛：脱离 IINA 森林，scripts/build-libmpv.sh 自构建 LGPL 清洁链（mpv 0.41.0 `-Dgpl=false` + FFmpeg 7.1.5 解码裁剪+VideoToolbox，arm64；18 dylib/18MB vs 原 71/116MB），GPL 指纹与闭包自检入脚本、约束级回归测试入网、LICENSES/ 合规交付；embed 脚本修旧库残留（见 plans/archive/TASK-libmpv-supply-chain.md + plans/libmpv-license-audit-2026-09-07.md，2026-09-08 真机七项回归通过）
- 播放器字幕轨开关：胶囊字幕钮 + 内嵌轨弹层（关闭/各轨，当前项对勾），无轨置灰、切集重置；track-list NODE 观察 + 纯值解析单测（见 plans/archive/TASK-subtitle-track-picker.md，2026-09-08 真机通过）
- shadow 配方令牌化：阴影散点 5 处聚类收敛为两档——shadowTextOnMedia（黑 0.6/blur 3/(0,-1)，媒体文字可读性）与 shadowFloatingChrome（黑 0.35/blur 10/(0,-2)，胶囊/Up Next pill 浮层）；零视觉变化，入 §4.6（见 plans/archive/TASK-shadow-recipe.md，2026-09-08 验收通过）
- share 卡片升级信息卡片：名称 + 备注（comment，有则显示）+「最近打开」相对时间（本地 ShareOpenStore 记录，删服务器即清）；Step 0 spike 实证 SMB 枚举仅 name/comment 两字段后拍板 A1+A2 叠加；无元信息时与现状像素级一致（见 plans/archive/TASK-share-info-card.md，2026-09-08 真机通过）
