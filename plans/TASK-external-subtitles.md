# TASK: External subtitles (1.0 batch 2, card 1)

- Status: landed 2026-09-12（make test 283 全绿、构建零警告；Review Approved；真机七步验收六项过：自动挂载/弹层标识/切集/置灰/vault/temp 清理；GBK 编码渲染为空观察项不阻塞，已登 BACKLOG 远期）
- Created: 2026-09-12
- Roadmap: plans/ROADMAP-1.0.md A2；姊妹项 plans/archive/TASK-subtitle-track-picker.md（内嵌轨开关）

## Goal
打开/切集视频时自动发现同目录同名外挂字幕（srt/ass），mpv sub-add
挂载并默认选中；外挂轨出现在既有字幕弹层（带「外挂」标识），可手
动切换/关闭。一处实现覆盖 SMB 与 vault 两态。

## 范围核实（2026-09-12 代码实证）
- sub-auto 在 covesmb:// 自定义协议下不工作（无文件系统兄弟文件访
  问，2026-09-08 卡实证）；stream_cb scheme 每 mpv handle 只绑一个
  cookie，一协议服务多文件不可行 → 外挂只能显式 sub-add。
- 加载通道现成：VideoStreamBridge.RangedReader（(path, range) async
  throws -> Data，read EOF 截断），SMB/vault 两态经 readRouter 统一
  路由——vault 视频播放今天就走它，无需本地路径特判。
- 字幕弹层零改动可收录外挂轨：track-list NODE 观察 + SubtitleTrack
  纯值解析（MPVPlayerCore.swift）已驱动弹层；mpv 对外挂轨标
  external=true、title=文件名。
- 目录清单快照：LibraryCoordinator.openPlayer 时
  browserViewModel.state.items 是全量 siblings（playlist 只含视频，
  发现需要含文本文件的全量清单）；playlist 切集共享同一目录。

## Decisions（Plan Card 拍板，Executor 照做）
1. **加载路径 = temp-file + sub-add**：provider 对每个匹配项经
   RangedReader 单次 read(0..<32MB cap) 拉全量字节，写
   NSTemporaryDirectory()/CoveSubtitles/<session-uuid>/<文件名>，
   command(["sub-add", tempPath])。32MB 上限防御（SRT/ASS 实际远小
   于此；超限截断记 warn，不阻断播放）。
2. **发现规则（纯函数 SubtitleDiscovery，可测）**：视频名去扩展名
   得 base；匹配 base + 可选语言后缀 + .srt/.ass（扩展名大小写不
   敏感）；同目录不递归；排序 = base.ext 精确匹配优先，其余按名称
   自然序。输入 = 目录全量 ContentItem，输出 = 匹配项列表。
3. **挂载时机**：loadfile 命令后立即 sub-add（mpv 命令按序处理，
   与 autoload.lua 类惯例一致）；Executor 小步验证，若绑定不可靠
   回退首个 file-loaded 事件后挂载（上报中说明选择）。
4. **默认行为 = 外挂优先**：sub-add 默认 flags=select，新挂外挂轨
   即显示——与 SenPlayer/IINA 惯例一致；内嵌 default 轨被顶属预期
   （用户放外挂通常要用它）。用户切轨/关闭为当次会话行为，切集后
   按新文件重新发现（与现状切集重置同语义）。
5. **弹层标识**：MPVTrackEntry/SubtitleTrack 增 external 标记，
   displayName 对外挂轨加「外挂」后缀（配方/弹层组件不动）；
   track-list node walk 多读一个 external 布尔。
6. **失败静默**：任一匹配项拉取/写盘/sub-add 失败仅记日志，播放
   不受影响（字幕是增强不是阻塞）；全部失败 = 与无字幕现状一致。
7. **临时文件生命周期**：每 player session 一个子目录，session
   替换（open/moveTo）与窗口关闭时清理上一 session 目录；
   NSTemporaryDirectory 系统兜底。
8. **siblings 快照**：openPlayer 时捕获一次全量清单传入播放器
   会话；浏览器中途导航不影响播放中会话的发现。
9. **编码**：交给 mpv 自动检测（uchardet），不预设 sub-codepage；
   GBK SRT 真机观察。

## Out of scope
手动浏览挂字幕（无 NAS 文件选择器，1.x 再说）；sub-auto/协议方案；
字幕样式定制；secondary-sid 双字幕；编码手动指定；递归子目录字幕
（subs/ 子目录扫描亦不做）。

## Steps
1. 纯值层：SubtitleDiscovery + SubtitleTrack/MPVTrackEntry external
   标记 + 弹层标签后缀 + 测试。
2. 加载层：ExternalSubtitleLoader（bytes→temp 生命周期）+ Core
   addExternalSubtitle + PlayerCoordinator 接线（open/moveTo/关闭
   三处生命周期）+ LibraryCoordinator provider 注入。
3. 验证：make generate && make test 全绿 + 真机验收清单。

## DoD
1. Discovery 纯函数测试：精确匹配/语言后缀/扩展名大小写/多匹配
   排序/非字幕与目录排除/无匹配恒空。
2. SubtitleTrack.parse 既有测试不回归 + external 标记新用例。
3. `make generate && make test` 全绿。
4. 真机：同名 srt 目录打开视频 → 外挂自动显示；弹层外挂轨带
   「外挂」后缀且可切内嵌/关闭；切集换文件重新发现不串轨；
   无字幕目录行为与现状一致；GBK SRT 无乱码（观察项）；vault
   下载目录同样生效。

## Risks
- sub-add 时机（loadfile 后立即 vs file-loaded）→ 小步验证，回退
  事件驱动（PROMPT 注明）。
- temp 目录泄漏 → session 级清理 + 系统兜底。
- 外挂 select 与内嵌 default 冲突 → 拍板为外挂优先（Decision 4）。
- GBK/ANSI 乱码 → mpv 自动检测，真机观察，不预设 codepage。
