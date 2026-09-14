# TASK-subtitle-charset：外挂字幕非 UTF-8 编码（GBK/BIG5）渲染为空

状态：Step 1（诊断 spike）2026-09-14 完结——**当前工件不可复现**（见下文
「Step 1 结果」）；Step 2 改为路线 D：真机复测原始失败文件，待 Owner 验收。

## 现象

2026-09-12 外挂字幕真机验收观察项：GBK/BIG5 编码的 .srt/.ass 挂载与选中
正常（轨道出现在选择器、可选中），但播放画面无任何字幕。UTF-8 字幕
正常。参照系（brew mpv / IINA）同片是否正常——尚未对比，列入 spike。

## Planner 侦察已实证的事实（2026-09-14，读码）

- 字幕链路全程字节保真：远程字节 → `Data` → 原样写临时目录 →
  `sub-add <path>`（`Cove/Services/Media/ExternalSubtitleLoader.swift`，
  无任何转码）。App 侧无嫌疑，问题在 mpv 侧的编码探测/转换。
- 自构建森林理论上齐备：`scripts/build-libmpv.sh` 中 FFmpeg
  `--enable-demuxer=...,srt,ass,webvtt,...`、`--enable-decoder=subrip,ass,...`，
  mpv meson `-Duchardet=enabled -Diconv=enabled`（uchardet 为手编 +
  手写 .pc，见 `b_uchardet`）。即"裁剪掉探测链"的先验假设不成立，
  必须实证定位。
- App 未设置任何 `sub-codepage` 相关选项（`MPVPlayerCore` 仅
  config=no/vo=libmpv/hwdec/cache/osd-level/keep-open），日志订阅
  warn 级（诊断信息不可见）。

## 假设集（spike 用实验区分，不许凭读码拍板）

- H1 探测缺口：uchardet 在样本上探测失败/置信不足，mpv 按 UTF-8 解读
  → 非法序列被丢弃 → 空白。判据：显式 `sub-codepage=GB18030` 后字幕
  正确。
- H2 转换链断裂：显式 codepage 也无效 → iconv 链接/运行时有鬼
  （手编 uchardet 的 install_name、.pc、或 macOS 系统 libiconv 解析）。
- H3 构建实况与脚本声明不符：运行期 uchardet/iconv 实际未生效
  （verbose 日志与 H2 实验联合判据）。
- H4 其他（日志说话）。

## Step 1：诊断 spike（本轮派发范围，零仓库改动）

用 dlopen 模式（参照 `/Users/boyang/code/Cove/build/spike-screenshot/screenshot_raw_spike.c`
头部用法）写新 spike，直接驱动 `Vendor/libmpv` 里的自构建 libmpv，
**不许改任何 git 跟踪文件**。

### 夹具（自包含合成，不依赖用户片库）

- 字幕：手写一份含多条中文 cue 的 UTF-8 .srt（cue 落在 0.5s–8s），
  用 macOS 自带 `iconv` 转出 GBK、BIG5 两个变体；UTF-8 原件作对照组。
  另备一份"长文本增强版"GBK（更多行、更多汉字），检验 uchardet 的
  样本量敏感性。
- 媒体：音频即可（字幕解码与视频无关；`sub-text` 属性随播放时间更新）。
  macOS 自带 `say -o /tmp/t.aiff "..."` + `afconvert -f WAVE -d LEI16
  /tmp/t.aiff /tmp/t.wav`（wav demuxer/pcm 解码器在森林白名单内）。
  若 `say`/`afconvert` 不可用，再找替代，不许动仓库文件。

### 实验矩阵（每条记录：codepage 选项 × 字幕变体 → t≈2s 处 sub-text）

1. UTF-8 对照 × 默认选项 —— 基线，必须正确，否则 spike 本身坏了（硬停止）。
2. GBK × 默认 —— 预期复现：空/乱码。
3. BIG5 × 默认 —— 预期复现。
4. GBK × `sub-codepage=GB18030` —— 区分 H1/H2 的关键实验。
5. GBK × `sub-codepage=GBK`、BIG5 × `sub-codepage=BIG5` —— 窄化。
6. GBK 长文本版 × 默认 —— uchardet 样本量敏感性。
7. 一次 `mpv_request_log_messages(handle, "v")` 的 verbose 跑，导出含
   charset/uchardet/subrip/sub 的日志行，看 mpv 实际做了什么决定。
8. 参照系（若本机存在）：`command -v mpv` 或 `/Applications/IINA.app`
   跑默认行对比；不存在则记"缺参照"，不阻塞。

### DoD（Step 1）

- [ ] 实验矩阵 1–6 全部跑出，`sub-text` 观测值如实记录（空就是空，
      不许脑补）。
- [ ] verbose 日志段落入报告。
- [ ] 报告给出：复现确认（是/否）、H1–H4 哪个被证据钉死、推荐修复
      路线（下方 A/B/C 或新路线）及理由。
- [ ] 仓库零改动：`git status` 干净（spike 文件与夹具全部在
      `build/spike-subtitle/` 与 `/tmp/`，均不被跟踪）。

### 硬停止（命中即停手回报，不许越界修）

1. UTF-8 对照组都拿不到正确 `sub-text`（spike 方法学错了）。
2. 证据指向必须改 `scripts/build-libmpv.sh` 重建森林（路线 C——
      影响发布供应链，需 Owner 拍板）。
3. 需要改任何 git 跟踪文件才能完成诊断。

## Step 1 结果（2026-09-14，Executor spike + Planner 独立复跑互证）

矩阵 6 行 + 补充 6 组（ass/CRLF/App 选项仿真/长文本/参照系 brew mpv）
全部正确：默认选项下 uchardet 探测 GB18030/BIG5 成功、iconv 转换正常、
`sub-text` 输出正确中文。H1/H2/H3 全部证伪。Planner 亲跑 GBK×默认行
复核：`libuchardet detected charset as GB18030` + `sub-text` hex 解码
为正确 UTF-8 中文，与 Executor 报告一致。

结论：09-12 验收观察为真（TASK-external-subtitles 卡原始记录），但失败
现场（当时的 Vendor/libmpv 二进制 + App 构建）已被 09-13 重建替换，
不可复得；build-libmpv.sh 09-08→09-13 唯一 diff 为音频 demuxer 白名单，
字幕链脚本逐字未动。残余嫌疑按优先级：① 原始失败文件本身的字节形态
（BOM/UTF-16/混合编码/截断——合成夹具覆盖不到）；② 渲染层
（vo=libmpv，嫌疑弱——UTF-8 同机渲染正常）。

## Step 2：路线 D——真机复测（优先，零代码）

用当前 main + 当前森林跑「用户验收清单」。通过 → 按环境漂移闭卡，
残余风险（原始文件形态未知）登记 BACKLOG；复现 → 取原始失败字幕文件
做字节级分析（hexdump 头部 + spike 直接喂该文件），再定 A/B/C。

### 历史候选路线（复现后选用，非承诺）

候选路线（预判，非承诺）：

- **路线 A（mpv 选项级）**：在 `MPVPlayerCore` 初始化选项或 sub-add
  路径补 `sub-codepage` 策略（如 GB18030 兜底回退）。最小改动，但
  依赖 mpv 行为细节，需 spike 证据支撑。
- **路线 B（App 侧转码）**：`ExternalSubtitleLoader` staging 时把字幕
  统一转 UTF-8（`NSString` 编码探测 API 对 GBK/BIG5 有成熟支持）。
  确定性强、可纯单测（不碰 mpv）、与 mpv 内部行为解耦。改动面：
  loader + 新测试文件（`make generate` 进工程）。
- **路线 C（森林重建）**：修 build-libmpv.sh 的 iconv/uchardet 链。
  最重，涉及发布供应链，Owner 门控。

## 用户验收清单（Step 2 落地后执行，先登记）

- 前置：片库里有当初发现问题的 GBK/BIG5 字幕影片。
- 步骤：双击播放该片 → 控制条字幕菜单选中该字幕 → 播到有台词处；
  再播一个 UTF-8 字幕的片做回归。
- 通过标准：GBK/BIG5 字幕正确显示中文（不空白、不乱码）；UTF-8
  字幕表现与修复前一致。
- 回传证据：一句"GBK 字幕显示正常/异常"+ 异常时的现象描述。

## 越界处理

白名单外任何改动冲动（含 project.yml、build-libmpv.sh、其他特性
文件）一律硬停止上报 Planner，由 Planner 决定是否 Amendment。
