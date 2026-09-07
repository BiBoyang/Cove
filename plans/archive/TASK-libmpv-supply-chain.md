# TASK: libmpv 供应链收敛（LGPL 清洁链）

日期：2026-09-07 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：plans/BACKLOG.md 上架前必须 + plans/archive/SPIKE-video-playback.md
（结论一获取方式、结论三渲染路径、2026-08-27 供应链调研追加）

## 目标复述

Vendor/libmpv 脱离 IINA 签名二进制供应链：换成可复现脚本自构建的
**LGPL 清洁** dylib 森林（App Store 兼容），并完成合规交付（license 文本
+ 源码指认）。现状：73 dylib/117MB 从 IINA.app 拷贝（mpv 0.38.0），构建期
ad-hoc 重签，装配脚本 scripts/assemble-libmpv.sh。

## 决策记录（已拍板 2026-09-07）

- 路线：**A2 自建清洁链**。A1（brew 源码重编但沿用 brew ffmpeg）被否决——
  brew ffmpeg 含 x264/x265（GPL-2.0+），GPL 组件与 App Store 分发条款冲突
  （VLC 2011 先例），Cove 开源与否不改变该结论。
- brew 官方 bottle 不可用（mpv 未编 OpenGL render 支持；libmpv render API
  仅 OpenGL）；MPVKit 为静态库且依赖链不随包，动手前最后复核一次。
- 播放工程只解码不编码：ffmpeg 不需要 x264/x265 等 GPL 编码器。
- 签名身份（DEVELOPMENT_TEAM / bundle id）用户有账号，不在本卡。

## Step 列表与 DoD

### Step 1 合规基线与构建设计（调研 + 文档，不动代码）
- 现有森林逐库清点：Vendor/libmpv 73 dylib → 上游项目 → license →
  GPL 风险标记（分组：mpv/ffmpeg 系、libass/libplacebo 系、杂项）。
- 目标 flag 矩阵：mpv meson 选项（LGPL 模式，以 mpv 0.41 上游
  meson_options 实证为准）、ffmpeg configure flags（--disable-gpl
  --disable-version3 + 解码域裁剪 + VideoToolbox 硬解保留）。
- 编解码/封装范围：以 App 实际打开的格式清单为准（读播放代码实证）。
- MPVKit 最新 release 五分钟复核（无完整依赖链则维持放弃，记录）。
- DoD：审计文档入库 plans/libmpv-license-audit-2026-09-07.md；
  flag 矩阵与编解码范围经 Review 通过。

### Step 2 构建链落地
- 新增 scripts/build-libmpv.sh：拉取 mpv/ffmpeg（及必要依赖）源码固定版本
  → 按 Step 1 矩阵构建 → dylibbundler 收森林 → @rpath 改写 → ad-hoc 签名。
  环境注记写入脚本注释：HOMEBREW_FAKE_MACOS=26.0 /
  HOMEBREW_NO_AUTO_UPDATE=1 / 代理断流时命令级剥离（env -u https_proxy …）。
- 产出到新目录（如 Vendor/libmpv-self/），**不替换在用森林**。
- DoD：脚本可复现跑通；森林 @rpath 闭包 + 签名自检通过；GL render
  可用性探针（spike 的 render 创建路径）通过；不破坏现有构建。

### Step 3 替换 + 回归 + 合规交付
- Vendor/libmpv 换自构建森林；assemble-libmpv.sh 标注退役（验收前保留作
  回滚路径）；播放回归真机验收（格式覆盖/字幕/seek/Up Next/全屏）。
- LICENSES/致谢入库（LGPL 义务：license 文本 + 上游源码指认 + 本仓构建
  脚本即对应源码）；AGENTS.md 规矩 8 与 README 的 Vendor 获取说明同步。
- DoD：build 零警告、test 全绿、真机验收清单全过、合规文件入库。

## 风险与回滚点

- macOS 27 预发布 SDK 编译风险集中在 Step 2（ffmpeg/mpv 源码兼容性）；
  命中硬停止即上报。
- mpv 0.38 → 0.41+ 行为差（option 默认值/render 参数），回归盯字幕与
  渲染；回滚 = 重跑 assemble-libmpv.sh 恢复 IINA 森林（Vendor 不入库）。
- 源码下载走网络；代理断流用命令级剥离兜底（2026-09-07 已实证）。
- 每 Step 单 commit 可 revert。

## 验证

- Step 1：审计文档 + Review。Step 2：脚本复跑 + 探针。
- Step 3：真机验收清单（说人话版）：播 H.264/HEVC/VP9/AV1 样片各一、
  内嵌/外挂字幕、拖进度条、Up Next 连播、全屏进出。
- 提审附用户验收清单（WORKFLOW.md §5.2），Step 以用户验收通过为闭环。
