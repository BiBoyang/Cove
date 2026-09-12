# TASK: Continue watching (最近播放, 1.0 batch 2, card 2)

- Status: landed 2026-09-13（make test 310 全绿、构建零警告；Review Approved；含 Amendment 1 首页入口与 Amendment 2 首页=最近播放页；真机验收：启动落首页、网格/进度条降级、深链续播、清理语义、高亮不变量全过）
- Created: 2026-09-13
- Roadmap: plans/ROADMAP-1.0.md A4

## Goal
idle 页（未连接服务器的主页）展示「最近播放」卡片排：文件名 + 断点
进度 + 上次观看时间；点击卡片自动完成 连接→进 share→进目录→开视频
全链，断点续播（续播由既有 progressKey 机制免费获得）。SMB 与
vault 条目一视同仁。

## 范围核实（2026-09-13 代码实证）
- 数据现成：PlaybackProgressStore（UserDefaults，key="sourceID|path"，
  值 {position, lastWatched}，LRU 200）——只缺 duration（卡片进度条
  需要）；PlayerViewModel.persistProgress 已知 duration，写入即得。
- 续播免费：progressKey = sourceID|path，PlayerViewModel 加载后自动
  seek（≤5s 忽略、≥95% 删记录）。深链只需走到 openPlayer。
- 深链各段现成：connect（服务器配置 host 匹配）→ openShare(:341) →
  navigateInto(:373) → openPlayer(:863，guard 要求文件在
  videoItems)；vault 路 openVault(initialPath:)(:465)。
- idle 页现状：ShareGridViewModel.showIdlePlaceholder 纯占位
  （双击左侧服务器以连接），StatePlaceholderView 整页，无内容区。
- 卡片无海报图：视频无缩略图管线，用徽标图标+文字（不造缩略图）。

## Decisions（Plan Card 拍板，Executor 照做）
1. **数据扩展（容忍旧格式）**：PlaybackProgressStore 写入时增存
   duration（persistProgress 传入）；读取容忍旧条目无 duration
   （卡片降级为无进度条，只显时间码）。allEntries 只读 API 供最近
   列表（协议不动，具体类加方法）。
2. **条目模型（纯函数可测）**：RecentWatchEntry 解析
   key="sourceID|path"（sourceID 无 |，按首个 | 切分；smb:// 与
   vault:// 判别 isVault）+ fileName/directoryPath 提取 + 畸形 key
   跳过；列表 = lastWatched 降序、cap 10。
3. **UI 形态**：idle 页 = 既有占位引导 + 其下横向卡片排（有条目才
   显示）；卡片 = film 徽标 + 文件名（至多两行截断）+ 迷你进度条
   （有 duration 时）+ 「已看至 h:mm:ss · N天前」说明行。Feature 私
   有组件（不进 SharedUI，单 Feature 使用）。点击经
   onResumeWatch(entry) 闭包转发协调器。卡片排也出现在 share 网格
   已连接页？——不出现，只 idle 页（1.0 收敛；分享页已有 share 卡
   信息层级）。
4. **深链流程（协调器）**：resumePlayback(entry:)——SMB：按
   sourceID host 匹配服务器配置（已连同一服务器则复用）→ connect
   → openShare → navigateInto(directoryPath) → openPlayer(path)；
   vault：openVault(initialPath: directoryPath) → openPlayer(path)。
   全链复用既有导航代（navigationGeneration）守卫：用户在链路中途
   的任何导航取消后续步骤。服务器配置已删 → 提示并清理条目；文件
   已删/改名（navigate 或 openPlayer guard 失败）→ alert「无法打
   开，可能已移动或删除」+ 清理条目 + 卡片排刷新。
5. **隐私与开关**：观看历史首页可见——与 Infuse/SenPlayer 一致；
   1.0 不做隐藏开关与历史清除 UI（条目本身随 95% 看完/LRU 自然消
   减），有需求再立卡。
6. **只视频**：PlaybackProgressStore 只覆盖视频；漫画/阅读续看是
   ReadingProgressStore 的另一套，不进本卡（1.x 候选）。
7. README 提交阶段补最近播放说明。

## Out of scope
漫画/目录阅读续看（ReadingProgressStore 体系）；海报缩略图；隐藏
开关/历史清除 UI；跨设备同步；share 网格已连接页的最近区。

## Steps
1. 数据层：store duration 扩展 + allEntries + RecentWatchEntry 解析
   + 测试。
2. UI：ShareGridViewModel recentWatches + idle 页卡片排 + 点击转发
   + VM 测试。
3. 深链：coordinator resumePlayback 两路 + 失败清理 + 卡片刷新。
4. 验证：make test 全绿 + 真机验收清单。

## DoD
1. 解析纯函数测试：smb/vault key 判别、fileName/directoryPath、
   畸形 key 跳过、排序 cap、duration 新旧格式往返与容错。
2. VM 测试：recentWatches 状态流（有条目/空条目）。
3. `make test` 全绿。
4. 真机：视频看至中途关窗 → idle 页出现卡片（进度条+时间码+相对
   时间）→ 点卡自动连接+导航+断点续播（SMB、vault 各验一次）；
   删掉源文件后点卡 → 提示+清理。

## Risks
- 深链与导航 generation 守卫交互 → 复用既有模式，用户中途导航
  必须能取消链路（测试覆盖取消语义）。
- 连接流程用户可见（loading/failure 占位）→ 深链失败语义与手动
  连接一致，不新增弹窗种类。
- 旧条目无 duration → 卡片降级（拍板 Decision 1）。
- 首页暴露观看历史 → 拍板 Decision 5（无开关）。

## Amendment（2026-09-13，Owner 真机反馈立项）
最近播放挂在 idle 页，而回 idle 页的用户路径不存在（全仓唯一路径 =
「删除当前服务器」resetAfterRemovingCurrentServer）——入口窟窿，
Owner 真机实证「启动可见、连上后无法进入」。拍板方案 A：侧栏底栏
加「首页」目的地行，任意页面一键回 idle 页。本增补随本卡一并提交。
- SidebarDestination 增 .home；底栏首行「首页」（house 图标，位于
  本地仓库之上）→ ServerListViewController.onOpenHome →
  coordinator.openHome()。
- openHome 编排复用 resetAfterRemovingCurrentServer 的全套（清
  currentServer/currentShare/browsingVault/navigationPath + idle 占位
  + disconnect 会话）+ setActiveDestination(.home)。
- 单高亮不变量延伸至首页行；重复点击幂等。
- DoD 增补：任意页面（share 网格/浏览器/vault/设置）一键回 idle
  页且最近播放在场；高亮不变量不破；断开语义与删服务器重置一致；
  测试覆盖 destination 高亮与 openHome 重置编排。

## Amendment 2（2026-09-13，Owner 真机反馈二次立项：首页=最近播放页）

Owner 实证：卡片一多，贴底横排又挤又占垂直空间，「首页」不该是
idle 页附属 strip，而应是独立页面（与本地仓库同级目的地）。
拍板重设计，并入本卡一并提交（strip 随之下线）。

### Decisions（Amendment 2，Executor 照做）
1. **首页 = 独立 pane**：新增 HomeViewModel + HomeViewController
   （Servers feature 组，与 ShareGrid/设置页同级），纵向网格
   （NSCollectionView flow layout，镜像 share 网格 160x130 卡片起步），
   底部 strip 全量移除；RecentWatchStripView 废弃，RecentWatchCardView
   改造为 RecentWatchCardItem（NSCollectionViewItem，仿 ShareCardItem
   的 RoundedFillView/border/hover 配方 + 进度条 + 说明行）。
2. **空态两级**：零服务器 = 「还没有添加服务器」+ 添加按钮（现成
   语义平移）；有服务器无记录 = 「还没有播放记录」，说明「双击左侧
   服务器以连接，看过的视频会出现在这里」。原 idle 占位页退役，
   share 网格只在已连接时出现。
3. **路由**：启动即落首页（start 不再走 idle 占位）；openHome()/
   删当前服务器 同指首页；「首页在屏 = 首页胶囊亮」结构不变量原样
   保持（setActiveDestination(.home) 随首页路由）。
4. **容量**：recentList cap 由 10 放宽到 30（首页传参；深链/清理
   刷新语义平移——refresh 从 ShareGridViewModel 移 HomeViewModel）。
5. **手势**：网格内**双击**续播（与 share 网格手势一致，防误触；
   strip 时代的单击随 strip 一并退役）。
6. **模型归属**：RecentWatchEntry/RecentWatchSource 随 HomeViewModel
   搬迁（解析/recentList/subtitleText 原样平移，协调器深链不受影响
   ——同模块）。
7. README 提交阶段按「首页页面」形态同步。

### DoD（Amendment 2 增补）
1. VM：HomeViewModel 空/非空状态流 + 清理后 refresh 即时反映 +
   cap 30 截断 + 两级空态判定。
2. 网格：卡片含进度条/时间码/相对时间；空态两级文案正确；
   ShareGrid 回退纯占位无 strip 残留。
3. `make generate && make test` 全绿（含平移后的
   ContinueWatching/HomeDestination 套件）。
4. 真机：启动见首页网格；双击卡片断点续播；切别的目的地再回首
   页内容在场；看完/删文件后回首页卡片状态正确。
