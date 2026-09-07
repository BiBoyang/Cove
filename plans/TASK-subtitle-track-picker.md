# TASK: 播放器字幕轨开关（内嵌轨选择 + 关闭）

日期：2026-09-08 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：plans/BACKLOG.md 下一波「播放器字幕轨开关 UI」+ libmpv 供应链验收
实证（2026-09-08 双森林探针：mpv 默认 sid=auto 只选中 default 标记轨，
非 default 轨无任何入口）

## 目标复述

播放器胶囊加字幕入口：工具位加字幕钮，弹层列出当前文件的内嵌字幕轨
（语言 / 标题 / 编码）+「关闭字幕」，选中即切 mpv sid。无轨时钮置灰。
初始行为保持现状（default 标记轨自动选中）。

## 实态核查结论（2026-09-08 读码实证）

- `MPVPlayerCore.swift`：公共面无字幕接口；私有 `command()`（:308）与
  属性读取器（:232-245）可扩；`observeProperties`（:204）用固定 enum
  注册，轨道变化通知需新增观察项或在 load 完成后拉取。
- 弹层组件 `OptionListPopoverController`（`PlayerWindowController.swift:1095`）
  已泛化（header/options/onSelect），倍速/模式弹层在用；选中项 accent
  glyph 配方已拍板（DESIGN-TOKENS.md §6.5），直接复用。
- 胶囊工具位现为上排右侧 speed/模式/播放列表三钮（spacing 令牌已就位）。

## 决策记录（已拍板 2026-09-08）

- 外挂字幕**排除**，另立 spike 候选：`sub-auto` 在 covesmb:// 自定义协议
  下不工作（无文件系统兄弟文件访问），`sub-add` 走自定义协议的可行性
  未验证。srt/ass 在浏览器被归 text 类，无加载逻辑。
- 字幕样式定制不做；mpv OSD 保持关闭（osd-level=0 现状不动）。

## Step 列表与 DoD

### Step 1 Core 面（MPVPlayerCore）
- 新增：字幕轨读取（track-list 遍历 type=sub：id/title/lang/codec 生成
  行标签）、`setSubtitle(trackID)` / 关闭（sid=no）；load 完成后向
  ViewModel 推送轨道列表（沿用既有 wakeup/main-actor 并发纪律）。
- 轨道模型解析逻辑抽为纯值函数，可单测。
- DoD：build 零警告、make test 全绿（基线 209 + 新增解析单测）；不改 UI。

### Step 2 UI 接线
- PlayerViewModel：subtitleTracks 状态 + 当前选中（切集重置）。
- 胶囊字幕钮（captions.bubble，symbolMedium 令牌）+ 弹层接线
  （选项 = 关闭字幕 + 各轨，当前项 accent glyph；无轨置灰）。
- DoD：build 零警告、test 全绿；真机验收清单（说人话）：
  多轨样片切换/关闭/默认轨自动选中原样/无轨片源钮置灰/切集后轨道重置。
  验收样片由助手用 brew ffmpeg 预造（vault 内：default 轨、双轨各一）。

## 风险与回滚点

- 轨道读取时机：load 完成事件前 track-list 不可靠——在 file-loaded 后
  拉取，切换文件时重置。
- 并发纪律：mpv 属性读取走既有 wakeup → main actor 模型，不新开线程路径。
- 每 Step 单 commit 可 revert；UI 无轨置灰逻辑与速度钮 enabled 状态
  管理同模式。

## 验证

- Step 1 单测 + build/test；Step 2 真机验收。
- 提审附用户验收清单（§5.2），Step 以用户验收通过为闭环。
