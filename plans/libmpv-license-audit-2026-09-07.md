# libmpv 供应链合规基线与构建设计（Step 1 审计）

日期：2026-09-07 ｜ 对应任务卡：plans/TASK-libmpv-supply-chain.md Step 1
范围：只读调查 + 本文档；不改任何代码。结论供 Step 2（构建链落地）直接消费。

## 0. 摘要

- 现有森林（IINA.app 借用，mpv 0.38.0 + FFmpeg 7.0.x）**含 11 个 GPL 档组件**，
  包括 libmpv 本体（默认 `gpl=true` 构建）与整套按 `--enable-gpl` 编出的 libav*——
  按 App Store 分发口径现状不可上架，A2 自建清洁链的必要性成立。
- mpv 0.41.0 上游 `meson.options` 实证：LGPL 模式准确选项为 **`-Dgpl=false`**；
  libmpv render API 所需 GL 开关为 `-Dgl=enabled -Dplain-gl=enabled`（+ macOS 的
  `gl-cocoa` / `videotoolbox-gl`）。
- FFmpeg 矩阵前提 `--disable-gpl --disable-version3 --disable-nonfree` 成立；
  因播放 IO 全走 mpv stream_cb（`covesmb://`），可加 `--disable-network`，
  整条 GnuTLS 依赖链（9 个 dylib）随之消失。
- MPVKit 五分钟复核：最新 release 仍为 1.0.0（2026-07-25），资产无
  libass/libplacebo/luajit 等依赖包——**维持放弃**（见 §4）。

风险标记口径：🔴 GPL 系（GPL 许可本体，或按 `--enable-gpl`/`gpl=true` 编出的
GPL 构建产物）｜🟡 需看构建 flag / 版本 / 分支选择（含 LGPL 系：动态链接 +
源码指认可合规，但有交付义务）｜🟢 MIT·BSD·ISC·MPL·zlib·CC0·WTFPL·Apache
等宽松族（保留版权行即可）。

## 1. 现有森林逐库清点

口径说明：任务卡记 "73 dylib/117MB"。实测 `Vendor/libmpv/` 共 73 个条目 =
**71 个实体 dylib + 1 个符号链接（`libmpv.dylib` → `libmpv.2.dylib`）+
`include/` 目录**；按 dylib 文件计为 72。下文表格覆盖全部 71 个实体，
统计按 71 计。链接关系用 `otool -L` 逐个核实（2026-09-07）。

### 1.1 mpv 本体

| dylib | 上游项目 | license | 风险 | 用途/被谁拉入 | A2 处置 |
|---|---|---|---|---|---|
| libmpv.2.dylib（+ libmpv.dylib 软链） | mpv 0.38.0（`strings` 实证 "mpv v0.38.0"） | 默认构建 = GPL-2.0+（含 LGPL-2.1+ 部分；brew formula 亦标 `all_of: [GPL-2.0-or-later, LGPL-2.1-or-later]`） | 🔴 | 播放引擎本体 | **重编**，`-Dgpl=false` 转 LGPL-2.1+ 构建 |

### 1.2 FFmpeg 系（libav*）

当前整套按 `--enable-gpl` 编出，证据：`libavfilter` 直接链接 `libpostproc` /
`librubberband` / `libvidstab`（`otool -L` 实证），而 postproc 仅在
`--enable-gpl` 下编译、libvidstab 官方要求 `--enable-gpl --enable-libvidstab`。
`libavcodec 61.3.100` 对应 FFmpeg 7.0.x。

| dylib | 上游项目 | license | 风险 | A2 处置 |
|---|---|---|---|---|
| libavcodec.61 | FFmpeg 7.0.x | 源码主体 LGPL-2.1+；**当前二进制为 GPL 构建** | 🔴 | 重编，`--disable-gpl` 后转 LGPL |
| libavformat.61 | 同上 | 同上 | 🔴 | 同上 |
| libavfilter.10 | 同上 | 同上 | 🔴 | 同上（且大幅裁剪 filter 集） |
| libavutil.59 | 同上 | 同上 | 🔴 | 同上 |
| libswscale.8 | 同上 | 同上 | 🔴 | 同上 |
| libswresample.5 | 同上 | 同上 | 🔴 | 同上 |
| libavdevice.61 | 同上 | 同上（且是 X11/xcb 链的拉入者：x11grab） | 🔴 | **`--disable-avdevice` 整库砍掉** |
| libpostproc.58 | FFmpeg postproc（MPlayer 衍生） | GPL-2.0+ 本体 | 🔴 | 砍掉（`--disable-gpl` 下本就不会编出，显式 `--disable-postproc` 兜底） |

### 1.3 脚本引擎（mpv 内嵌）

| dylib | 上游项目 | license | 风险 | A2 处置 |
|---|---|---|---|---|
| libluajit-5.1.2 | LuaJIT 2.1 | MIT | 🟢 | 见 §2.3 决策点：`-Dlua=disabled` 可砍；保留亦无合规负担 |
| libmujs | MuJS | ISC（mujs.com 实证） | 🟢 | 砍：`-Djavascript=disabled`（Cove 不用 JS 脚本） |
| libuchardet | uchardet | MPL-1.1 OR GPL-2.0+ OR LGPL-2.1+ 三选一（formulae.brew.sh 实证），选 MPL/LGPL 分支 | 🟢 | 保留：`-Duchardet=enabled`（外挂字幕编码探测） |

### 1.4 字幕与文字 shaping（libass 链）

| dylib | 上游项目 | license | 风险 | A2 处置 |
|---|---|---|---|---|
| libass.9 | libass | ISC | 🟢 | 保留（mpv 0.41 硬要求 ≥0.12.2） |
| libfreetype.6 | FreeType | FTL（BSD 式）OR GPL-2.0 双许可，选 FTL | 🟢 | 保留（libass/fontconfig 依赖） |
| libfribidi.0 | FriBidi | LGPL-2.1+ | 🟡 | 保留（libass 依赖；动态链接即合规） |
| libharfbuzz.0 | HarfBuzz | MIT | 🟢 | 保留，构建 `-Dglib=disabled` 砍掉 glib/pcre2/intl |
| libgraphite2.3 | SIL Graphite2 | LGPL-2.1+ OR MPL OR GPL-2.0 多选一，选 MPL/LGPL | 🟡 | 可砍：harfbuzz `-Dgraphite2=disabled`（中文/拉丁字幕用不到 Graphite shaping） |
| libunibreak.6 | libunibreak | zlib（formulae.brew.sh 实证） | 🟢 | 保留（libass 换行算法） |
| libfontconfig.1 | fontconfig | MIT 式 | 🟢 | 保留（字幕字体匹配）；构建禁 NLS 砍 intl |

### 1.5 渲染与图形（libplacebo 链 + 图像 codec）

| dylib | 上游项目 | license | 风险 | A2 处置 |
|---|---|---|---|---|
| libplacebo.338（7.349.x） | libplacebo | LGPL-2.1+ | 🟡 | 保留（mpv 0.41 硬要求 ≥6.338.2）；构建 `-Dvulkan=disabled -Dopengl=enabled -Dshaderc=disabled -Dglslang=disabled` |
| libshaderc_shared.1 | shaderc | Apache-2.0 | 🟢 | 砍（仅 Vulkan 路径用） |
| libvulkan.1 | Vulkan-Loader | Apache-2.0 | 🟢 | 砍（Cove 只用 OpenGL render API；`vo=libmpv` 无 Vulkan 变体，SPIKE 结论一） |
| liblcms2.2 | Little CMS 2 | MIT | 🟢 | 保留（ICC 色彩管理，mpv/placebo 可选；体积小） |
| libjpeg.8 | libjpeg-turbo | BSD-3 + IJG + zlib | 🟢 | 保留（mpv 截图 jpeg writer；可评 `-Djpeg=disabled` 再砍，非必需） |
| libpng16.16 | libpng | libpng 许可（zlib 式） | 🟢 | 随 freetype 拉入；freetype 可禁 PNG 则砍（png 仅用于彩色字体位图），默认保留 |
| libzimg.2 | z.img | WTFPL（formulae.brew.sh 实证） | 🟢 | 保留：`-Dzimg=enabled`（mpv 高质量缩放） |
| libjxl.0.10 / libjxl_cms / libjxl_threads | libjxl | BSD-3 | 🟢 | 砍（avcodec 的 JPEG-XL wrapper 所拉；格式清单无 JXL 视频） |
| libhwy.1 | Highway | Apache-2.0 | 🟢 | 砍（随 jxl 消失） |
| libbrotlicommon/dec/enc | Brotli | MIT | 🟢 | 砍（随 jxl 消失） |
| libwebp.7 / libwebpmux.3 / libsharpyuv.0 | libwebp | BSD-3 | 🟢 | 砍（avcodec webp wrapper；不在格式清单） |

### 1.6 音频/滤镜外部库

| dylib | 上游项目 | license | 风险 | A2 处置 |
|---|---|---|---|---|
| librubberband.2 | Rubber Band | **GPL-2.0-or-later**（formulae.brew.sh 实证；另有商业授权） | 🔴 | 砍：mpv `-Drubberband=disabled`，ffmpeg 不 enable（变速走 mpv 内建 scaletempo） |
| libvidstab.1.2 | vid.stab | **GPL-2.0+**（官方要求 ffmpeg `--enable-gpl --enable-libvidstab`） | 🔴 | 砍（防抖滤镜，Cove 不用） |
| libsamplerate.0 | libsamplerate (Secret Rabbit Code) | 0.2.2 起 BSD-2-Clause（repology 实证）；更早版本 GPL——版本敏感 | 🟡 | 砍（avfilter aresample 外部 wrapper，不 enable 即消失） |
| libsoxr.0 | libsoxr | LGPL-2.1+ | 🟡 | 砍（swresample soxr resampler，不 enable 即消失） |
| libspeex.1 | Speex | BSD-3 | 🟢 | 砍（ffmpeg 有原生 speex 解码；且 flv 里 speex 罕见，样片回归兜底） |
| libsnappy.1 | Snappy | BSD-3 | 🟢 | 砍（hap 解码用，不在格式清单） |
| libdav1d.7 | dav1d | BSD-2 | 🟢 | 保留：`--enable-libdav1d` 解 AV1（验收清单含 AV1 样片；原生 av1 解码器见 §4 开放问题） |

### 1.7 压缩/封装（libarchive 链）

| dylib | 上游项目 | license | 风险 | A2 处置 |
|---|---|---|---|---|
| libarchive.13 | libarchive | BSD-2 | 🟢 | 砍：mpv `-Dlibarchive=disabled`（压缩包内播放；Cove 的 CBZ 走 ComicKit） |
| liblzma.5 | XZ Utils | 公有领域 / 0BSD | 🟢 | 砍（archive + avcodec tiff 所拉；ffmpeg `--disable-lzma`） |
| liblz4.1 | LZ4 | BSD-2 | 🟢 | 砍（随 archive 消失） |
| libzstd.1 | Zstandard | BSD-3 OR GPL-2.0 双许可，选 BSD | 🟢 | 砍（随 archive 消失） |
| libb2.1 | libb2 (BLAKE2) | CC0-1.0（github.com/BLAKE2/libb2 实证） | 🟢 | 砍（随 archive 消失） |

### 1.8 网络与 TLS（GnuTLS 链 + ZeroMQ）

整条链只为 ffmpeg 网络协议（https/tls）与 zmq 协议服务。Cove 播放 IO 全走
mpv stream_cb（`covesmb://` 桥，见 SPIKE 结论二），ffmpeg `--disable-network`
后**整链 11 个 dylib 全部消失**。

| dylib | 上游项目 | license | 风险 | A2 处置 |
|---|---|---|---|---|
| libgnutls.30 | GnuTLS | LGPL-2.1+ | 🟡 | 砍（`--disable-network`） |
| libnettle.8 / libhogweed.6 | Nettle | LGPL-3.0+ OR GPL-2.0+ 双许可 | 🟡 | 砍（随 gnutls） |
| libgmp.10 | GMP | LGPL-3.0+ OR GPL-2.0+ 双许可 | 🟡 | 砍（随 gnutls） |
| libtasn1.6 | libtasn1 | LGPL-2.1+ | 🟡 | 砍（随 gnutls） |
| libidn2.0 | libidn2 | GPL-2.0+ OR LGPL-3.0+ 双许可 | 🟡 | 砍（随 gnutls） |
| libunistring.5 | libunistring | GPL-2.0+ OR LGPL-3.0+ 双许可（gnu.org 实证） | 🟡 | 砍（随 gnutls） |
| libintl.8 | gettext runtime | LGPL-2.1+ | 🟡 | 砍（随 gnutls/glib/fontconfig-NLS；三处构建选项均可禁） |
| libp11-kit.0 | p11-kit | BSD-3 | 🟢 | 砍（随 gnutls） |
| libzmq.5 | ZeroMQ | MPL-2.0 | 🟢 | 砍（ffmpeg libzmq 协议，不 enable） |
| libsodium.26 | libsodium | ISC | 🟢 | 砍（随 zmq） |

### 1.9 杂项

| dylib | 上游项目 | license | 风险 | A2 处置 |
|---|---|---|---|---|
| libbluray.2 | libbluray | LGPL-2.1+ | 🟡 | 砍：mpv `-Dlibbluray=disabled`（蓝光目录播放；App 只开普通文件） |
| libglib-2.0.0 | GLib | LGPL-2.1+ | 🟡 | 砍（harfbuzz `-Dglib=disabled`） |
| libpcre2-8.0 | PCRE2 | BSD-3 | 🟢 | 砍（随 glib 消失） |

### 1.10 X11 系（7 个，avdevice 的 x11grab 拉入）

| dylib | license | 风险 | A2 处置 |
|---|---|---|---|
| libX11.6 / libXau.6 / libXdmcp.6 / libxcb.1 / libxcb-shape.0 / libxcb-shm.0 / libxcb-xfixes.0 | MIT/X11 | 🟢 | 砍：ffmpeg `--disable-avdevice --disable-xlib`，mpv `-Dx11=disabled`（macOS 上本就 auto 不到，显式禁防误检） |

### 1.11 GCC 运行时（2 个，libjxl 的 C++ 链拉入）

| dylib | license | 风险 | A2 处置 |
|---|---|---|---|
| libgcc_s.1.1 / libstdc++.6 | GPL-3.0+ **带 GCC Runtime Library Exception**（gnu.org/licenses/gcc-exception-3.1.html），二进制分发不被传染 | 🟡 | 随 jxl 链一起消失；A2 全部用 clang/libc++ 构建，**不得再引入 GCC 编译的 C++ 依赖**（注意 harfbuzz/libplacebo 等 C++ 工程统一 `clang++ -stdlib=libc++`） |

### 1.12 统计

| 风险档 | 数量（71 实体） | 明细 |
|---|---|---|
| 🔴 GPL 系 | **11** | libmpv.2 + libavcodec/avdevice/avfilter/avformat/avutil/swscale/swresample（7）+ libpostproc + librubberband + libvidstab |
| 🟡 需看 flag/版本 | **17** | fribidi、graphite2、placebo、samplerate、soxr、gnutls、nettle、hogweed、gmp、tasn1、idn2、unistring、intl、bluray、glib、gcc_s、stdc++ |
| 🟢 宽松族 | **43** | 其余全部 |

🔴 的 11 个中，8 个（libmpv + 7 个 libav*）是「源码 LGPL、构建变 GPL」，
A2 重编后即转 🟡（LGPL 合规档）；3 个（postproc/rubberband/vidstab）是 GPL
本体，只能砍掉。🟡 的 17 个里 14 个在 A2 矩阵中整链消失，剩下 fribidi /
graphite2(可砍) / libplacebo 三个 LGPL 按动态链接合规。

## 2. 目标 flag 矩阵（A2 清洁链设计）

### 2.0 App 侧实证输入（编解码范围的依据）

格式清单（唯一定义点 `Frameworks/SourceKit/Sources/SourceKit/ContentItem.swift:62-78`，
视频分支 63-64 行）：

- 视频容器：**mp4, mkv, avi, mov, wmv, flv, webm, m4v, ts, m2ts, mpg, mpeg, 3gp, rmvb**
- 无 NSOpenPanel 类型过滤——视频只经 SMB 浏览器列表打开
  （`BrowserViewController.swift:423-424` → `LibraryCoordinator.swift:106`），
  即全部播放流量走 mpv stream_cb 桥（`covesmb://`），**ffmpeg 网络协议零需求**。
- `srt/ass` 被归为 text 类（74 行），App 无显式外挂字幕加载逻辑；mpv 默认
  `sub-auto` 对内嵌字幕轨有效——字幕域以内嵌轨 + libass 渲染为准。
- mpv 实际用到的特性（`Cove/Services/Media/MPVPlayerCore.swift` 实证）：
  libmpv client API、`vo=libmpv`（OpenGL render API）、`hwdec=auto-safe`
  （VideoToolbox 优先）、`vd-lavc-dr=no`、`cache=yes`、`osd-level=0`、
  `keep-open=yes`、`config=no`、volume/speed/seek 命令、stream_cb 协议。
  未用：cplayer CLI、任何 lua/JS 脚本、OSD 字体渲染、ytdl、压缩包/蓝光输入。

### 2.1 mpv（0.41.0，meson）

上游实证：mpv 0.41.0 的选项文件名已从 `meson_options.txt` 更名为
**`meson.options`**（126 行，2026-09-07 抓取核对），关键行：

- `option('gpl', type: 'boolean', value: true, ...)` → **`-Dgpl=false` 即
  LGPL-2.1+ 构建**，官方一等选项。
- `plain-gl`：描述原文 "OpenGL without platform-specific code (e.g. for
  libmpv)"——正是 render API 路径。
- 依赖下限（同 tag `meson.build:22-32`）：libavcodec ≥ 60.31.102（FFmpeg 6.1）、
  libavfilter ≥ 9.12.100、libavformat ≥ 60.16.100、libplacebo ≥ 6.338.2、
  libass ≥ 0.12.2。FFmpeg 7.1.x 满足。

建议矩阵：

```
-Dgpl=false                  # LGPL 构建（核心目标）
-Dcplayer=false -Dlibmpv=true
-Dgl=enabled -Dplain-gl=enabled
-Dcocoa=enabled -Dgl-cocoa=enabled -Dmacos-cocoa-cb=enabled
-Dvideotoolbox-gl=enabled    # VT 硬解帧 → GL 互操作，hwdec=auto-safe 依赖
-Dvideotoolbox-pl=auto
-Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled
-Dlibavdevice=disabled       # 连带 ffmpeg 侧 --disable-avdevice，砍 X11 链
-Dlibbluray=disabled -Dlibarchive=disabled -Ddvdnav=disabled -Dcdda=disabled -Ddvbin=disabled
-Djavascript=disabled        # 砍 mujs
-Drubberband=disabled        # GPL
-Dlua=disabled               # 决策点，见 §2.3
-Duchardet=enabled -Dzimg=enabled -Dlcms2=enabled -Diconv=enabled -Dzlib=enabled
-Dcplugins=disabled -Dmanpage-build=disabled -Dhtml-build=disabled
-Dbuild-date=false           # 可复现性
```

最小特性集核对（对 §2.0 逐条）：render API（plain-gl ✓）、VT 硬解
（videotoolbox-gl ✓）、cache/stream_cb/keep-open 等为 mpv 内建无选项 ✓、
字幕（libass 硬依赖保留 ✓）。

### 2.2 FFmpeg（建议 7.1.x；configure 草案）

前提（ffmpeg.org/legal.html 官方建议：不带 `--enable-gpl`/`--enable-nonfree`
编译 + 动态链接 + 随附源码）：

```
--disable-gpl --disable-version3 --disable-nonfree
--enable-shared --disable-static --disable-programs --disable-doc
--disable-debug
--disable-avdevice --disable-postproc
--disable-network                 # 播放 IO 全走 stream_cb；砍掉 GnuTLS 整链需求
--disable-encoders --disable-muxers
--disable-everything              # 白名单起点，下面逐项 enable
# 容器（对 §2.0 格式表逐项映射）
--enable-demuxer=mov              # mp4/m4v/mov/3gp
--enable-demuxer=matroska         # mkv/webm
--enable-demuxer=avi
--enable-demuxer=asf              # wmv
--enable-demuxer=flv
--enable-demuxer=mpegts           # ts/m2ts
--enable-demuxer=mpegps,mpegvideo # mpg/mpeg（ps 封装 + 裸流）
--enable-demuxer=rm               # rmvb
--enable-demuxer=subrip,ass,webvtt  # 外挂字幕兜底（极小）
--enable-protocol=file            # 本地/vault 文件兜底；无网络协议
# 视频解码
--enable-decoder=h264,hevc,vp8,vp9
--enable-decoder=mpeg4,msmpeg4v3,h263,flv1
--enable-decoder=mpeg1video,mpeg2video
--enable-decoder=vc1,wmv1,wmv2,wmv3
--enable-decoder=rv30,rv40
--enable-decoder=prores,mjpeg
# 音频解码
--enable-decoder=aac,ac3,eac3,dca,truehd,mlp
--enable-decoder=mp3,mp3float,opus,vorbis,flac,alac
--enable-decoder=wmav1,wmav2,wmapro,cook,sipr
--enable-decoder=pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_f32le,pcm_u8,pcm_alaw,pcm_mulaw
--enable-decoder=adpcm_ms,adpcm_ima_wav
# 字幕轨
--enable-decoder=subrip,ass,mov_text,webvtt,dvdsub,pgssub
# 同名 parser 随解码器 enable（mpv demux 路径需要）
--enable-parser=h264,hevc,mpeg4video,mpegvideo,vc1,mpegaudio,aac,ac3,dca,opus,vorbis,flac,cook,rv30,rv40
# avfilter 最小集（mpv af_lavfi/vf_lavfi 桥接兜底；Cove 不主动用 lavfi filter）
--enable-filter=format,aformat,scale,aresample,volume,fps,crop,rotate,transpose,trim,atrim,setpts,asetpts,yadif,null,anull,copy
# 硬解与系统库
--enable-videotoolbox
--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,mpeg2_videotoolbox,mpeg4_videotoolbox
#   vp9_videotoolbox / av1_videotoolbox 视所选版本 configure --list-hwaccels 核对后追加
--enable-audiotoolbox             # 系统框架，零三方分发货；AAC/AC3 兜底
--enable-zlib
--enable-libdav1d                 # AV1（BSD-2；验收清单含 AV1 样片）
--disable-bzlib --disable-lzma --disable-libxml2 --disable-xlib --disable-libxcb
```

裁掉清单（对照 §1）：不 enable 任何外部 codec wrapper（speex/snappy/soxr/
samplerate/webp/jxl/lzma/zmq/bluray…），不编 postproc/rubberband/vidstab。
**bsf 不主动裁剪**（体积极小，且个别 demux→decode 边界依赖；Step 2 若实测
无引用再 `--disable-bsfs`）。

### 2.3 其余依赖（保留项的构建注记）

| 依赖 | license | 保留 | 构建注记 |
|---|---|---|---|
| libass ≥0.12.2（建议 0.17.3） | ISC | 是 | meson；依赖 freetype/fribidi/harfbuzz/unibreak，fontconfig 可选 |
| libplacebo ≥6.338.2（建议与现森林同代 7.349.x 或 brew 7.360.1） | LGPL-2.1+ | 是 | `-Dvulkan=disabled -Dopengl=enabled -Dshaderc=disabled -Dglslang=disabled -Dlcms=enabled -Ddemos=false -Dtests=false`；注意 fast_float 以 meson wrap 拉取，需联网或预置 |
| freetype | FTL | 是 | `-Dpng=disabled` 可砍 libpng（彩色字体位图才用；默认保留也无妨） |
| fribidi | LGPL-2.1+ | 是 | meson，零依赖 |
| harfbuzz | MIT | 是 | `-Dglib=disabled -Dgraphite2=disabled`（砍 glib/pcre2/intl/graphite2 四个） |
| fontconfig | MIT 式 | 是 | 禁 NLS（`--disable-nls` / meson 等价）砍 intl |
| libunibreak | zlib | 是 | autotools，零依赖 |
| lcms2 | MIT | 是 | 零依赖 |
| dav1d | BSD-2 | 是 | meson + nasm（x86_64 汇编需 nasm；arm64 用 gas） |
| zimg | WTFPL | 是 | C++ 工程，必须 clang++/libc++（勿引入 GCC 运行时） |
| uchardet | MPL/LGPL 选分支 | 是 | cmake，零依赖 |
| libjpeg-turbo | BSD-3/IJG | 可留可砍 | mpv `-Djpeg=disabled` 则不需要 |
| luajit | MIT | **决策点** | `-Dlua=disabled` 则砍。Cove 不用任何 mpv 脚本（osc/console/ytdl/auto-profiles 均无需求）；建议禁用，回归盯 mpv 启动 warning 与 `--profile` 行为。保守项：保留亦无合规负担 |
| libpng | libpng 许可 | 随 freetype 选项 | 见上 |

**架构决策点**：现森林 universal（arm64+x86_64）。双架构 = 全图编两遍 +
lipo；arm64-only 构建时间减半、体积更小，但放弃 Intel Mac。需用户拍板
（README 环境要求随之更新）。

**预估目标森林**：libmpv + 6 个 libav* + placebo + ass + freetype + fribidi +
harfbuzz + unibreak + fontconfig + dav1d + zimg + lcms2 + uchardet（+jpeg/png
/luajit 视决策）≈ **19~21 个 dylib**（现 71），粗估 30–50MB（universal）
或 15–25MB（arm64-only）（现 116MB）。

## 3. MPVKit 五分钟复核（2026-09-07）

`GET https://api.github.com/repos/mpvkit/MPVKit/releases/latest` 返回：
最新 release 仍为 **1.0.0（published 2026-07-25）**，资产清单仅 FFmpeg\* /
libmpv\* / Libavcodec…Libswscale 的 xcframework 与静态包，**无 Libass、
libplacebo、luajit、uchardet、libbluray 任何依赖链资产**——与 SPIKE 结论一
及 2026-08-27 追加核实的同一批资产，放弃理由不变。**结论：维持放弃 A2
以外路线，MPVKit 不可用。**

## 4. 风险与开放问题（Step 2 预告）

1. **macOS 27 预发布 SDK**：ffmpeg 7.1.x / mpv 0.41.0 源码对预发布 clang/SDK
   的兼容性未验证；brew 只借构建工具（meson/ninja/pkgconf/nasm）也需
   `HOMEBREW_FAKE_MACOS=26.0` + `HOMEBREW_NO_AUTO_UPDATE=1`（SPIKE 已实证）。
   命中编译错误先升级对应小版本再降级排查，不要为单个错误改业务代码。
2. **编译耗时**：全图约 10–12 个源码工程 × 2 架构；ffmpeg 裁剪后单次约
   数分钟，luajit/placebo/harfbuzz 都不慢，全链 arm64+x86_64 预估 30–60
   分钟量级。脚本必须支持断点续跑（每库 build/ 目录保留 + 完成标记）。
3. **brew 依赖借用边界**：只借构建工具；库依赖全部源码 pin 版本（任务卡
   "可复现" 要求）。若临时借用 brew bottle 加速排障，产物不得进最终森林
   （bottle 版本漂移 + glib 链回流风险）。
4. **mpv 0.38→0.41 行为差**：`vd-lavc-dr=no` 是否仍需（SPIKE 根因六注明
   升级后复测）、option 默认值漂移、deprecation warning。回归盯字幕与渲染。
5. **GL render 探针**：libplacebo OpenGL-only 构建 + mpv 0.41 下，SPIKE
   三件套（`vo=libmpv`、临时 CGL context、FBO 动态发现）须原样复验；
   `mpv_render_context_create(OPENGL)` 通过是 Step 2 DoD。
6. **GPL 污染自检**（建议写进 build 脚本收尾）：`otool -L` 闭包内不得出现
   postproc/rubberband/vidstab/x264/x265；`strings libavutil*.dylib | grep
   -- "--enable-gpl"` 必须为空（FFmpeg 把 configure 行编进二进制，可直接
   指纹验证 `--disable-gpl --disable-version3` 在列）。
7. **源码下载网络**：代理断流用命令级剥离（`env -u https_proxy …`，
   2026-09-07 实证对 GitHub 直连超时、jsdelivr 可用）。freedesktop/savannah
   系 tarball（fontconfig/freetype 等）可用 GitHub mirror 或软件自有镜像，
   Step 2 实测后把可用 URL 固化进脚本。
8. **开放问题（需拍板）**：
   a. 目标架构 universal vs arm64-only（§2.3）；
   b. FFmpeg 版本 pin：7.1.x（保守，与现森林同 ABI 代际）vs 8.x/9.x（跟
      brew 最新）；
   c. `-Dlua=disabled` 砍 luajit vs 保守保留；
   d. AV1 用 libdav1d（IINA 实证路线）vs FFmpeg 原生 av1 解码器（省一个
      依赖，需所选版本核对可用性）；
   e. LGPL 交付形态（Step 3 细化）：LICENSES/ 文本 + 上游源码指认 + 本仓
      build 脚本即"对应源码"是否满足复核口径。

## 5. 引用来源

- mpv 0.41.0 `meson.options`（选项名/默认值实证）：
  https://github.com/mpv-player/mpv/blob/v0.41.0/meson.options
  （实际抓取：https://cdn.jsdelivr.net/gh/mpv-player/mpv@0.41.0/meson.options ；
  注意 0.41 已更名，旧名 meson_options.txt 404）
- mpv 0.41.0 `meson.build`（依赖版本下限）：
  https://cdn.jsdelivr.net/gh/mpv-player/mpv@0.41.0/meson.build
- brew mpv formula（license 字段 `all_of: [GPL-2.0-or-later, LGPL-2.1-or-later]`、
  brew 构建参数）：
  https://github.com/Homebrew/homebrew-core/blob/master/Formula/m/mpv.rb
  （本地缓存核对：`~/Library/Caches/Homebrew/downloads/…--mpv.rb`）
- FFmpeg 官方合规建议：https://ffmpeg.org/legal.html
- MPVKit releases：https://api.github.com/repos/mpvkit/MPVKit/releases/latest
- rubberband GPL-2.0-or-later：https://formulae.brew.sh/formula/rubberband
- vid.stab 要求 `--enable-gpl`：https://github.com/georgmartius/vid.stab
- libunibreak zlib：https://formulae.brew.sh/formula/libunibreak
- uchardet 三选一许可：https://formulae.brew.sh/formula/uchardet
- zimg WTFPL：https://formulae.brew.sh/formula/zimg
- libb2 CC0-1.0：https://github.com/BLAKE2/libb2
- libsamplerate 0.2.2 起 BSD-2：https://repology.org/project/libsamplerate/packages
- mujs ISC：https://mujs.com/
- libunistring GPL-2+/LGPL-3+ 双许可：https://www.gnu.org/software/libunistring/
- GCC Runtime Library Exception：https://www.gnu.org/licenses/gcc-exception-3.1.html
- 仓内实证：`Vendor/libmpv/`（otool -L 全量，2026-09-07）、
  `Frameworks/SourceKit/Sources/SourceKit/ContentItem.swift:62-78`、
  `Cove/Services/Media/MPVPlayerCore.swift`、
  `Cove/Features/Browser/Views/BrowserViewController.swift:420-428`、
  `Cove/Application/Coordination/LibraryCoordinator.swift:106`、
  `scripts/assemble-libmpv.sh`、
  `plans/archive/SPIKE-video-playback.md`（结论一/三、2026-08-27 追加）
