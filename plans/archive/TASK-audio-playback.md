# TASK: Audio playback (1.0 batch 2, card 3)

- Status: landed 2026-09-13（make test 315 全绿、构建零警告；Review Approved；含 Fix 1：FFmpeg 矩阵补五个音频 demuxer + 森林重建 selfcheck 4/4 + 约束用例；真机 mp3/flac 实播通过）
- Created: 2026-09-13
- Roadmap: plans/ROADMAP-1.0.md A1

## Goal
分类表新增 audio 类型（mp3/flac/aac/m4a/wav/ogg/opus/wma），浏览器
双击音频走既有 libmpv 桥播放：控制条（进度/音量/倍速/播放模式/
Up Next/断点续播）全部免费继承；无视频轨时窗口显示极简静态壳
（music.note + 文件名）而非裸黑窗。SMB 与 vault 一视同仁。

## 范围核实（2026-09-13 代码实证）
- 分类表 ContentItem.FileType（SourceKit 公共表）无 audio，音频扩展
  全落 .other → 双击走 onUnsupportedFile。
- 播放链路 type-agnostic：VideoStreamBridge + MPVPlayerCore loadfile
  不区分流类型，mpv 原生播音频-only；播放模式/Up Next/倍速/断点
  续播（progressKey 机制）零改动继承。
- 无视频轨判定缝：track-list（MPVTrackEntry type=video 计数）或
  PlayerViewModel.videoInfo==nil（load 后），Executor 二选一并上报。
- 队列：浏览器 playlist 现仅 videoItems；音频需 audioItems 同类派生。
- 与「继续观看」卡的整合点：音频断点续播免费（同 progressKey），
  音频条目随后会进最近播放卡片——本卡负责让 openPlayer 按
  fileType 路由队列（video/audio），使深链对音频条目天然可用。

## Decisions（Plan Card 拍板，Executor 照做）
1. **分类表**：FileType 增 .audio；扩展名 = mp3/flac/aac/m4a/wav/
   ogg/opus/wma（大小写不敏感）；aiff/alac 不收（macOS 场景非主流
   NAS 音频，后续可补）。ContentItemTests 分类用例随改。
2. **行呈现**：徽标 symbol = music.note，tint 走新令牌
   badgeTintAudio（建议 systemPink，Owner 可改）；DESIGN-TOKENS.md
   §1 同步登记（令牌纪律）。副标题规则与视频一致（只显大小）。
3. **打开路由**：handleDoubleClick .audio → onOpenAudio 闭包；
   LibraryCoordinator.openPlayer(at:) 改为按 fileType 路由播放队列
   （video→videoItems、audio→audioItems），同一 PlayerCoordinator
   会话体系——这让继续观看深链对音频条目天然可用（整合点）。
   混合目录不混排：开什么类型排什么队列。
4. **静态壳**：无视频轨时（audio-only session）播放器窗口显示
   居中 music.note（hero 尺寸，text-tertiary）+ 文件名（title 字
   号），替代裸黑视频面；codec chips 无视频轨时整组隐藏（不显示
   音频 codec，1.0 壳从简）。控制条全功能保留。
5. **断点续播/最近播放**：progressKey 机制原样启用（音频断点免费）；
   「已看至」语义对音频即「已听至」，文案不特判。
6. **外挂字幕发现对音频不启用**（歌词/.lrc 不做）；若同目录恰好
   有同名 srt 被挂上属无害行为，不处理。
7. README 提交阶段补音频播放说明。

## Out of scope
音频专属 UI（封面图/频谱/迷你播放器）；.lrc 歌词；aiff/alac/dsd；
音频 metadata 展示（标题/艺术家标签）；混排队列；音频 codec chips。

## Steps
1. 分类与呈现：FileType.audio + 分类表 + 徽标令牌（CoveStyle +
   DESIGN-TOKENS §1）+ SourceKit/App 测试。
2. 播放路由：audioItems + onOpenAudio + openPlayer kind 路由 +
   静态壳（无视频轨判定缝）+ chips 隐藏 + 测试。
3. 验证：make generate（如需）&& make test 全绿 + 真机验收清单。

## DoD
1. 分类测试：八个扩展名→.audio、大小写、非音频不受影响；
   tint/symbol 映射用例不回归 + audio 新用例。
2. VM/解析测试：audioItems 派生；无视频轨判定用例。
3. `make test` 全绿。
4. 真机：双击 mp3/flac 各一 → 静态壳显示并播放、进度/音量/倍速
   可用；中途关窗再开 → 断点续播；播完自动 Up Next 切下一音频；
   vault 同样生效。

## Risks
- 无视频轨判定缝不可靠（mpv 事件时序）→ Executor 两条候选缝
  已给，选一个并在上报说明；都不稳则硬停止。
- 音频进最近播放卡片后的深链——本卡 openPlayer kind 路由覆盖
  （Decision 3），无需 continue-watching 卡返工。
- 倍速/播放模式对音频语义（1.5x 听歌怪）→ 不特判，控制条全量
  保留（拍板）。
- 令牌新增需文档同步（badgeTintAudio 入 §1），漏登即 DoD 不过。

## Fix 1（2026-09-13，Owner 真机首验即中：音频 demuxer 缺席）

Owner 双击 mp3 即「播放失败 / 播放中断」。根因（Planner 实证）：
scripts/build-libmpv.sh 的 FFMPEG_FLAGS demuxer 行只有视频容器+字幕
（mov,matroska,avi,asf,flv,mpegts,mpegps,mpegvideo,rm,srt,ass,webvtt），
独立音频 demuxer 全体缺席——decoder/parser 链齐（mp3/flac/opus/
vorbis/aac/mpegaudio parser 均在），故 m4a（mov）/wma（asf）碰巧可
播，mp3/flac/ogg/opus/wav/aac 容器进不去。

### Fix decisions（Owner 已拍板 o）
1. demuxer 行追加 `mp3,flac,ogg,wav,aac`（caf 不收；全 LGPL 域内，
   GPL 指纹与闭包自检照跑）。
2. 本地重建森林：scripts/build-libmpv.sh 全量（CI 缓存 key=脚本
   hash 自动失效重建，release.yml 不动）；重建后 make build 重嵌
   dylibs。
3. 约束级回归：AudioPlaybackTests 增补「demuxer 矩阵含音频容器」
   文本断言（#file 定位 repo 根读脚本，防未来再被裁回退）。
4. 验证：make test 全绿 + 真机五步清单（F 目录 mp3/flac 双格式）
   重验。
