#!/usr/bin/env bash
# build-libmpv.sh — reproducible, LGPL-clean libmpv forest for Cove.
#
# Task: plans/TASK-libmpv-supply-chain.md Step 2 (build chain landing).
# Flag matrix: plans/libmpv-license-audit-2026-09-07.md §2 (deviations are
# logged to the build report by the selfcheck phase).
#
# Output forest: Vendor/libmpv-self/  (NEVER touches Vendor/libmpv).
# Work dir:      build/libmpv-self/   (build/ is git-ignored; safe to wipe).
#
# Environment notes (per task card):
#   - This Mac runs macOS 27 pre-release; brew is only borrowed for build
#     tools (meson/ninja/pkgconf/nasm) and needs HOMEBREW_FAKE_MACOS=26.0 +
#     HOMEBREW_NO_AUTO_UPDATE=1.
#   - The session proxy is broken; every network command must run with proxy
#     vars stripped. This script unsets them process-wide at startup, which
#     is equivalent to prefixing each command with
#     `env -u https_proxy -u http_proxy -u all_proxy` (verified 2026-09-07).
#   - GitHub direct is slow-but-working (~400KB/s codeload); jsdelivr CDN and
#     downloads.videolan.org are fast; ffmpeg.org / freedesktop.org www /
#     savannah are unreachable. gitlab.freedesktop.org works for
#     fontconfig/uchardet archives.
#
# Architecture: arm64 only (decision 2026-09-07). Universal switch: ARCHS
# below is a single-arch list on purpose; a universal build means running
# every library once per arch with -arch slices and lipo-merging the dylibs
# before the bundle phase. Left as future work, off by default.
#
# Resume: each library has a build dir + a done marker under
#   build/libmpv-self/{src,build,done,logs}. Re-running skips completed
#   steps. To force a rebuild: rm build/libmpv-self/done/<lib>.done
#   (plus bundle/mpv markers downstream). `./scripts/build-libmpv.sh clean`
#   wipes the whole work dir; `distclean` also wipes Vendor/libmpv-self.
#
# Usage: scripts/build-libmpv.sh [phase ...]
#   (no args = all)  phases: tools fetch dav1d freetype fribidi harfbuzz
#   unibreak fontconfig lcms2 uchardet zimg libass libplacebo ffmpeg mpv
#   bundle probe selfcheck | clean distclean

set -euo pipefail

# --- environment ------------------------------------------------------------

unset https_proxy http_proxy all_proxy HTTPS_PROXY HTTP_PROXY ALL_PROXY \
      ftp_proxy FTP_PROXY no_proxy NO_PROXY || true
export HOMEBREW_FAKE_MACOS=26.0 HOMEBREW_NO_AUTO_UPDATE=1
export MACOSX_DEPLOYMENT_TARGET=15.0   # matches project.yml deploymentTarget
export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/libmpv-self"
TARBALLS="$WORK/tarballs"
SRC="$WORK/src"
BLD="$WORK/build"
DONE="$WORK/done"
LOGS="$WORK/logs"
DEPS="$WORK/deps"
OUT="$ROOT/Vendor/libmpv-self"
PROBE_BIN="$WORK/libmpv-gl-probe"

ARCHS=("arm64")   # universal: ("arm64" "x86_64") + lipo merge (see header)
JOBS="$(sysctl -n hw.ncpu)"

# Build-time pkg-config isolation: ONLY our prefix is visible. This is the
# hard guarantee that no Homebrew library leaks into the forest.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
unset PKG_CONFIG_PATH || true

# --- pins (every source pinned to an exact tag) -------------------------------

FFMPEG_TAG="n7.1.5"          # FFmpeg 7.1.x line, newest patch (jsdelivr 2026-09-07)
MPV_TAG="v0.41.0"            # task card pin
PLACEBO_TAG="v7.349.0"       # audit §2.3: same generation as current forest
LIBASS_TAG="0.17.3"          # audit §2.3 suggestion
DAV1D_VER="1.5.4"            # newest 1.5.x (downloads.videolan.org listing)
FREETYPE_TAG="VER-2-13-3"    # 2.13.3
FRIBIDI_TAG="v1.0.16"
HARFBUZZ_TAG="12.1.0"
FONTCONFIG_VER="2.16.2"
LCMS2_TAG="lcms2.17"
ZIMG_TAG="release-3.0.6"     # 3.0.x has no graphengine submodule (.gitmodules 实证)
UCHARDET_VER="0.0.8"
LIBUNIBREAK_TAG="libunibreak_6_1"

CCLD="https://codeload.github.com"
FFMPEG_URLS=("$CCLD/FFmpeg/FFmpeg/tar.gz/refs/tags/$FFMPEG_TAG")
MPV_URLS=("$CCLD/mpv-player/mpv/tar.gz/refs/tags/$MPV_TAG")
PLACEBO_URLS=("$CCLD/haasn/libplacebo/tar.gz/refs/tags/$PLACEBO_TAG")
LIBASS_URLS=("$CCLD/libass/libass/tar.gz/refs/tags/$LIBASS_TAG")
DAV1D_URLS=(
  "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VER/dav1d-$DAV1D_VER.tar.xz"
  "$CCLD/videolan/dav1d/tar.gz/refs/tags/$DAV1D_VER"
)
FREETYPE_URLS=("$CCLD/freetype/freetype/tar.gz/refs/tags/$FREETYPE_TAG")
FRIBIDI_URLS=("$CCLD/fribidi/fribidi/tar.gz/refs/tags/$FRIBIDI_TAG")
HARFBUZZ_URLS=("$CCLD/harfbuzz/harfbuzz/tar.gz/refs/tags/$HARFBUZZ_TAG")
FONTCONFIG_URLS=("https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/$FONTCONFIG_VER/fontconfig-$FONTCONFIG_VER.tar.gz")
LCMS2_URLS=("$CCLD/mm2/Little-CMS/tar.gz/refs/tags/$LCMS2_TAG")
ZIMG_URLS=("$CCLD/sekrit-twc/zimg/tar.gz/refs/tags/$ZIMG_TAG")
UCHARDET_URLS=(
  "https://gitlab.freedesktop.org/uchardet/uchardet/-/archive/$UCHARDET_VER/uchardet-$UCHARDET_VER.tar.gz"
  "https://gitlab.freedesktop.org/uchardet/uchardet/-/archive/v$UCHARDET_VER/uchardet-v$UCHARDET_VER.tar.gz"
  "$CCLD/BYVoid/uchardet/tar.gz/refs/tags/v$UCHARDET_VER"
)
LIBUNIBREAK_URLS=("$CCLD/adah1972/libunibreak/tar.gz/refs/tags/$LIBUNIBREAK_TAG")

# libplacebo submodule pins (gitlink SHAs at v7.349.0, via GitHub API
# 2026-09-07; codeload tarballs do not include submodule contents).
# Vulkan-Headers is still required with -Dvulkan=disabled: src/vulkan/stubs.c
# includes libplacebo/vulkan.h -> <vulkan/vulkan.h> (build-time only, no
# Vulkan runtime dependency enters the forest). jinja/markupsafe are glad2's
# code generator deps; fast_float is used by shader parsing.
GLAD_SHA="d08b1aa01f8fe57498f04d47b5fa8c48725be877"
JINJA_SHA="b08cd4bc64bb980df86ed2876978ae5735572280"
MARKUPSAFE_SHA="c0254f0cfe51720ecc9e72e8896022af29af5b44"
FASTFLOAT_SHA="2b2395f9ac836ffca6404424bcc252bff7aa80e4"
VKHEADERS_SHA="d732b2de303ce505169011d438178191136bfb00"
GLAD_URLS=("$CCLD/Dav1dde/glad/tar.gz/$GLAD_SHA")
JINJA_URLS=("$CCLD/pallets/jinja/tar.gz/$JINJA_SHA")
MARKUPSAFE_URLS=("$CCLD/pallets/markupsafe/tar.gz/$MARKUPSAFE_SHA")
FASTFLOAT_URLS=("$CCLD/fastfloat/fast_float/tar.gz/$FASTFLOAT_SHA")
VKHEADERS_URLS=("$CCLD/KhronosGroup/Vulkan-Headers/tar.gz/$VKHEADERS_SHA")

# --- helpers ------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR (%s):\033[0m %s\nsee %s\n' "${CURRENT_STEP:-?}" "$*" "${LOGS}/${CURRENT_STEP:-build}.log" >&2; exit 1; }

is_done() { [[ -f "$DONE/$1.done" ]]; }
mark_done() { date -u +%FT%TZ > "$DONE/$1.done"; }

# fetch_tarball <name> <url...> — cached, retried, multi-mirror.
# Tarballs are stored under a canonical name ($name.tar): codeload URLs end
# in the bare tag with no extension and no repo name, so URL basenames are
# useless for lookup. bsdtar sniffs gzip/xz from content regardless.
fetch_tarball() {
  local name="$1"; shift
  local dest="$TARBALLS/$name.tar"
  mkdir -p "$TARBALLS"
  if [[ -s "$dest" ]]; then log "$name: tarball cached ($(du -h "$dest" | cut -f1))"; return 0; fi
  local url i
  for url in "$@"; do
    # The session network is intermittently flaky (SSL handshake timeouts
    # come and go in windows), so retry generously; cached tarballs make the
    # fetch phase itself resumable, this loop only needs to win once.
    for i in 1 2 3 4 5 6 7 8; do
      log "$name: fetch $url (attempt $i)"
      # abort stalled transfers (<1KB/s for 30s) so retries actually happen
      if curl -fSL --connect-timeout 25 --speed-limit 1024 --speed-time 30 \
              -o "$dest.part" "$url" 2>>"$LOGS/fetch.log" && [[ -s "$dest.part" ]]; then
        mv "$dest.part" "$dest"
        log "$name: fetched $(du -h "$dest" | cut -f1)"
        return 0
      fi
      rm -f "$dest.part"; sleep 3
    done
  done
  die "fetch" "$name: all mirrors exhausted"
}

# extract_to <name> <abs-dest> — extract cached tarball to an explicit dir.
# Note: codeload tarballs pre-create submodule gitlinks as EMPTY dirs, so
# "already extracted" must mean non-empty, not just present.
extract_to() {
  local name="$1" dest="$2"
  if [[ -d "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then return 0; fi
  rm -rf "$dest"
  local tb tmp
  tb="$TARBALLS/$name.tar"
  [[ -s "$tb" ]] || die "extract" "$name: tarball not found at $tb (run fetch phase)"
  tmp="$(mktemp -d "$SRC/.x.XXXXXX")"
  tar -xf "$tb" -C "$tmp"
  local n; n="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [[ "$n" == "1" ]] || die "extract" "$name: tarball has $n top-level dirs"
  mkdir -p "$(dirname "$dest")"
  mv "$tmp"/*/ "$dest"
  rm -rf "$tmp"
}

# extract_src <name> — extracts cached tarball to $SRC/<name> (idempotent).
extract_src() {
  extract_to "$1" "$SRC/$1"
}

# meson_lib <name> <meson -D args...> — standard meson/ninja build+install.
meson_lib() {
  local name="$1"; shift
  rm -rf "$BLD/$name"
  meson setup "$BLD/$name" "$SRC/$name" \
    --prefix "$DEPS" --libdir lib --buildtype release \
    --default-library shared "$@" >>"$LOGS/$name.log" 2>&1 \
    || die "$name" "meson setup failed"
  ninja -C "$BLD/$name" >>"$LOGS/$name.log" 2>&1 || die "$name" "ninja failed"
  ninja -C "$BLD/$name" install >>"$LOGS/$name.log" 2>&1 || die "$name" "install failed"
}

# write_pc <name> <version> <libs> <cflags> [requires]
write_pc() {
  local name="$1" ver="$2" libs="$3" cflags="$4" requires="${5:-}"
  cat > "$DEPS/lib/pkgconfig/$name.pc" <<EOF
prefix=$DEPS
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: $name
Description: self-built $name (Cove libmpv clean chain)
Version: $ver
Requires: $requires
Libs: -L\${libdir} $libs
Cflags: $cflags
EOF
}

# step <name> <fn> — done-marker wrapper with per-step log context.
step() {
  local name="$1" fn="$2"
  CURRENT_STEP="$name"
  if is_done "$name"; then log "$name: done marker present, skipping"; return 0; fi
  mkdir -p "$BLD" "$LOGS" "$DONE"
  : > "$LOGS/$name.log"
  log "building $name"
  "$fn"
  mark_done "$name"
  log "$name: OK"
}

# --- phases -------------------------------------------------------------------

ph_tools() {
  local missing=()
  local t
  for t in meson ninja pkgconf nasm; do command -v "$t" >/dev/null || missing+=("$t"); done
  if ((${#missing[@]})); then
    die "tools" "missing build tools: ${missing[*]}
    install with: HOMEBREW_FAKE_MACOS=26.0 HOMEBREW_NO_AUTO_UPDATE=1 brew install ${missing[*]}"
  fi
  log "tools: meson $(meson --version), ninja $(ninja --version), pkgconf $(pkgconf --version), nasm $(nasm -v | awk '{print $3}')"
  log "sdk: $(xcrun --sdk macosx --show-sdk-version), clang: $(clang --version | head -1)"
}

ph_fetch() {
  mkdir -p "$LOGS" "$TARBALLS" "$SRC"
  : > "$LOGS/fetch.log"
  fetch_tarball dav1d "${DAV1D_URLS[@]}"
  fetch_tarball freetype "${FREETYPE_URLS[@]}"
  fetch_tarball fribidi "${FRIBIDI_URLS[@]}"
  fetch_tarball harfbuzz "${HARFBUZZ_URLS[@]}"
  fetch_tarball libunibreak "${LIBUNIBREAK_URLS[@]}"
  fetch_tarball fontconfig "${FONTCONFIG_URLS[@]}"
  fetch_tarball lcms2 "${LCMS2_URLS[@]}"
  fetch_tarball uchardet "${UCHARDET_URLS[@]}"
  fetch_tarball zimg "${ZIMG_URLS[@]}"
  fetch_tarball libass "${LIBASS_URLS[@]}"
  fetch_tarball libplacebo "${PLACEBO_URLS[@]}"
  fetch_tarball glad "${GLAD_URLS[@]}"
  fetch_tarball jinja "${JINJA_URLS[@]}"
  fetch_tarball markupsafe "${MARKUPSAFE_URLS[@]}"
  fetch_tarball fastfloat "${FASTFLOAT_URLS[@]}"
  fetch_tarball vkheaders "${VKHEADERS_URLS[@]}"
  fetch_tarball ffmpeg "${FFMPEG_URLS[@]}"
  fetch_tarball mpv "${MPV_URLS[@]}"
}

b_dav1d() {
  extract_src dav1d
  meson_lib dav1d \
    -Denable_asm=true -Denable_tools=false -Denable_examples=false \
    -Denable_tests=false -Dtestdata_tests=false -Denable_docs=false
}

b_freetype() {
  extract_src freetype
  meson_lib freetype \
    -Dzlib=system -Dbrotli=disabled -Dbzip2=disabled \
    -Dharfbuzz=disabled -Dpng=disabled -Dmmap=enabled -Dtests=disabled
}

b_fribidi() {
  extract_src fribidi
  meson_lib fribidi -Ddocs=false -Dbin=false -Dtests=false
}

b_harfbuzz() {
  extract_src harfbuzz
  meson_lib harfbuzz \
    -Dglib=disabled -Dgobject=disabled -Dgraphite=disabled -Dgraphite2=disabled \
    -Dicu=disabled -Dcairo=disabled -Dchafa=disabled -Dfontations=disabled \
    -Dharfrust=disabled -Dkbts=disabled -Dwasm=disabled \
    -Dfreetype=enabled -Dcoretext=enabled \
    -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled \
    -Dutilities=disabled -Dbenchmark=disabled
}

b_unibreak() {
  # libunibreak 6.1 ships autotools-only; hand-compile instead of borrowing
  # autoconf/automake from brew (keeps the borrowed-tool list at the four
  # sanctioned ones). Sources are plain C89, single dylib.
  extract_src libunibreak
  local s="$SRC/libunibreak"
  clang -dynamiclib -O2 -arch "${ARCHS[0]}" -std=c99 \
    -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$s/src" "$s"/src/*.c \
    -install_name "$DEPS/lib/libunibreak.dylib" \
    -o "$DEPS/lib/libunibreak.dylib" >>"$LOGS/unibreak.log" 2>&1 \
    || die "unibreak" "compile failed"
  cp "$s"/src/*.h "$DEPS/include/"
  write_pc libunibreak 6.1 "-lunibreak" "-I\${includedir}"
}

b_fontconfig() {
  extract_src fontconfig
  meson_lib fontconfig \
    -Dnls=disabled -Ddoc=disabled -Dtests=disabled -Dtools=disabled \
    -Dcache-build=disabled
}

b_lcms2() {
  extract_src lcms2
  # NOTE: fastfloat/threaded plugins are GPL-3.0 per lcms2's own
  # meson_options.txt — keep both false (audit-level compliance point).
  meson_lib lcms2 \
    -Dutils=false -Dfastfloat=false -Dthreaded=false \
    -Djpeg=disabled -Dtiff=disabled -Dtests=disabled
}

b_uchardet() {
  # uchardet is cmake-only upstream; hand-compile (C++, ~20 files) to keep
  # cmake off the borrowed-tool list.
  extract_src uchardet
  local s="$SRC/uchardet"
  clang++ -dynamiclib -O2 -arch "${ARCHS[0]}" -std=c++11 -stdlib=libc++ \
    -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$s/src" "$s"/src/*.cpp "$s"/src/LangModels/*.cpp \
    -install_name "$DEPS/lib/libuchardet.dylib" \
    -o "$DEPS/lib/libuchardet.dylib" >>"$LOGS/uchardet.log" 2>&1 \
    || die "uchardet" "compile failed"
  cp "$s/src/uchardet.h" "$DEPS/include/"
  write_pc uchardet "$UCHARDET_VER" "-luchardet" "-I\${includedir}"
}

b_zimg() {
  # zimg 3.0.x ships autotools-only; hand-compile like unibreak/uchardet.
  # release-3.0.x .gitmodules has only googletest (tests) — self-contained.
  # ZIMG_ARM mirrors what configure.ac defines on aarch64.
  extract_src zimg
  local s="$SRC/zimg"
  [[ -f "$s/src/zimg/api/zimg.h" ]] || die "zimg" "unexpected source layout (api/zimg.h missing)"
  # shellcheck disable=SC2086
  clang++ -dynamiclib -O2 -arch "${ARCHS[0]}" -std=c++17 -stdlib=libc++ \
    -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -DZIMG_ARM -I"$s/src" -I"$s/src/zimg" \
    $(find "$s/src/zimg" -name '*.cpp' | sort) \
    -install_name "$DEPS/lib/libzimg.2.dylib" \
    -o "$DEPS/lib/libzimg.2.dylib" >>"$LOGS/zimg.log" 2>&1 \
    || die "zimg" "compile failed"
  ln -sf libzimg.2.dylib "$DEPS/lib/libzimg.dylib"
  cp "$s/src/zimg/api/zimg.h" "$DEPS/include/"
  cp "$s/src/zimg/api/zimg++.hpp" "$DEPS/include/" 2>/dev/null || true
  write_pc zimg 3.0.6 "-lzimg" "-I\${includedir}"
}

b_libass() {
  extract_src libass
  meson_lib libass \
    -Dfontconfig=enabled -Dcoretext=enabled -Ddirectwrite=disabled \
    -Dlibunibreak=enabled -Dasm=enabled -Dtest=false -Dprofile=false
}

b_libplacebo() {
  extract_src libplacebo
  # submodules (pinned commits, see header pins): glad2 generator + its
  # python deps + fast_float. Vulkan-Headers intentionally skipped.
  extract_to glad "$SRC/libplacebo/3rdparty/glad"
  extract_to jinja "$SRC/libplacebo/3rdparty/jinja"
  extract_to markupsafe "$SRC/libplacebo/3rdparty/markupsafe"
  extract_to fastfloat "$SRC/libplacebo/3rdparty/fast_float"
  extract_to vkheaders "$SRC/libplacebo/3rdparty/Vulkan-Headers"
  meson_lib libplacebo \
    -Dvulkan=disabled -Dopengl=enabled -Dd3d11=disabled \
    -Dshaderc=disabled -Dglslang=disabled -Dlcms=enabled \
    -Ddemos=false -Dtests=false
}

# FFmpeg configure matrix — audit doc §2.2, plus operational fixes validated
# against n7.1.5's own configure --list-* (logged in the Step-2 report):
#   srt demuxer name (audit wrote "subrip"); flv1 -> flv, mov_text -> movtext
#   (actual component names); rv30/rv40 parsers do not exist upstream (rm
#   demuxer frames RealVideo internally); libdav1d wrapper decoder + av1
#   parser + *_at Audiotoolbox decoders must be explicit because
#   --disable-everything also gates external/hw components.
FFMPEG_FLAGS=(
  --disable-gpl --disable-version3 --disable-nonfree
  --enable-shared --disable-static --disable-programs --disable-doc
  --disable-debug
  --disable-avdevice --disable-postproc
  --disable-network
  --disable-encoders --disable-muxers
  --disable-everything
  # containers (audit §2.0 format list)
  --enable-demuxer=mov,matroska,avi,asf,flv,mpegts,mpegps,mpegvideo,rm,srt,ass,webvtt
  --enable-protocol=file
  # video decoders
  --enable-decoder=h264,hevc,vp8,vp9,mpeg4,msmpeg4v3,h263,flv
  --enable-decoder=mpeg1video,mpeg2video,vc1,wmv1,wmv2,wmv3,rv30,rv40,prores,mjpeg
  # audio decoders
  --enable-decoder=aac,ac3,eac3,dca,truehd,mlp,mp3,mp3float,opus,vorbis,flac,alac
  --enable-decoder=wmav1,wmav2,wmapro,cook,sipr
  --enable-decoder=pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_f32le,pcm_u8,pcm_alaw,pcm_mulaw
  --enable-decoder=adpcm_ms,adpcm_ima_wav
  # subtitles
  --enable-decoder=subrip,ass,movtext,webvtt,dvdsub,pgssub
  # external/hw decoders (must be explicit under --disable-everything)
  --enable-decoder=libdav1d
  --enable-decoder=aac_at,ac3_at,eac3_at,mp3_at
  # parsers (mpv demux path needs them; av1 added for the libdav1d route)
  --enable-parser=h264,hevc,mpeg4video,mpegvideo,vc1,mpegaudio,aac,ac3,dca,opus,vorbis,flac,cook,sipr,av1
  # minimal avfilter set (mpv af_lavfi/vf_lavfi bridge only)
  --enable-filter=format,aformat,scale,aresample,volume,fps,crop,rotate,transpose,trim,atrim,setpts,asetpts,yadif,null,anull,copy
  # hw accel (n7.1.5 --list-hwaccels intersection; no av1_videotoolbox in 7.1)
  --enable-videotoolbox
  --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,mpeg2_videotoolbox,mpeg4_videotoolbox,vp9_videotoolbox
  --enable-audiotoolbox
  --enable-zlib
  --enable-libdav1d
  --disable-bzlib --disable-lzma --disable-libxml2 --disable-xlib --disable-libxcb
  --disable-autodetect
)

b_ffmpeg() {
  extract_src ffmpeg
  local b="$BLD/ffmpeg"
  rm -rf "$b"; mkdir -p "$b"
  (cd "$b" && "$SRC/ffmpeg/configure" \
      --prefix="$DEPS" \
      --arch="${ARCHS[0]}" --cc=clang \
      --extra-cflags="-I$DEPS/include -O2 -arch ${ARCHS[0]}" \
      --extra-ldflags="-L$DEPS/lib -arch ${ARCHS[0]}" \
      "${FFMPEG_FLAGS[@]}" \
      >>"$LOGS/ffmpeg.log" 2>&1) || die "ffmpeg" "configure failed"
  make -C "$b" -j"$JOBS" >>"$LOGS/ffmpeg.log" 2>&1 || die "ffmpeg" "make failed"
  make -C "$b" install >>"$LOGS/ffmpeg.log" 2>&1 || die "ffmpeg" "install failed"
}

MPV_FLAGS=(
  -Dgpl=false                      # LGPL-2.1+ build — the whole point
  -Dcplayer=false -Dlibmpv=true
  -Dgl=enabled -Dplain-gl=enabled
  -Dcocoa=enabled -Dgl-cocoa=enabled -Dmacos-cocoa-cb=enabled
  -Dvideotoolbox-gl=enabled
  -Dvideotoolbox-pl=auto
  -Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled
  -Dlibavdevice=disabled
  -Dlibbluray=disabled -Dlibarchive=disabled -Ddvdnav=disabled -Dcdda=disabled -Ddvbin=disabled
  -Djavascript=disabled
  -Drubberband=disabled
  -Dlua=disabled                   # decided: no luajit (Cove uses no mpv scripts)
  -Duchardet=enabled -Dzimg=enabled -Dlcms2=enabled -Diconv=enabled -Dzlib=enabled
  -Djpeg=disabled                  # deviation: app never calls mpv screenshot; skips libjpeg-turbo
  -Dcplugins=disabled -Dmanpage-build=disabled -Dhtml-build=disabled
  -Dbuild-date=false
  -Dtests=false
)

b_mpv() {
  extract_src mpv
  meson_lib mpv "${MPV_FLAGS[@]}"
}

# --- bundle: closure collection + @rpath rewrite + ad-hoc signing ------------
# Explicit install_name_tool pass instead of dylibbundler: the forest is small
# and fully self-built, so a deterministic BFS beats dylibbundler 1.x's
# transitive quirks. Equivalent means, same result.

BANNED_PATTERN='postproc|rubberband|vidstab|x264|x265|gnutls'

ph_bundle() {
  [[ -f "$DEPS/lib/libmpv.2.dylib" ]] || die "bundle" "$DEPS/lib/libmpv.2.dylib missing (run mpv phase first)"
  rm -rf "$OUT"; mkdir -p "$OUT"

  # BFS over otool -L from libmpv, collecting deps that live in $DEPS.
  # NOTE: /bin/bash is 3.2 on macOS — no associative arrays; the forest is
  # tiny so a linear membership list is fine.
  # Dedupe key is the REFERENCED path (basename), never the realpath:
  # dependents record the soname symlink (e.g. libavcodec.61.dylib ->
  # libavcodec.61.19.101.dylib), so the forest must carry each dylib under
  # the basename its dependents actually reference. cp -L dereferences.
  local queue="$DEPS/lib/libmpv.2.dylib"   # newline-separated worklist
  local seen=""                             # newline-separated visited paths
  local leaks=""
  local f dep base
  while [[ -n "$queue" ]]; do
    f="${queue%%$'\n'*}"
    queue="${queue#*$'\n'}"; [[ "$queue" == "$f" ]] && queue=""
    case "$seen" in *"$(basename "$f")"*) continue ;; esac
    seen="${seen}$(basename "$f")"$'\t'"$f"$'\n'
    while read -r dep; do
      case "$dep" in
        /usr/lib/*|/System/*) ;;                                  # system: fine
        /opt/homebrew/*) leaks="${leaks}${f} -> ${dep}"$'\n' ;;    # brew leak: report
        "$DEPS"/*|@rpath/*|@loader_path/*)
          base="${dep##*/}"
          [[ -e "$DEPS/lib/$base" ]] && queue="${queue}${DEPS}/lib/${base}"$'\n' ;;
        *) warn "unhandled dep entry: $f -> $dep" ;;
      esac
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
  done
  [[ -z "$leaks" ]] || die "bundle" "homebrew libs leaked into closure:"$'\n'"$leaks"

  local src dst
  while IFS=$'\t' read -r base src; do
    [[ -n "$src" ]] || continue
    dst="$OUT/$base"
    cp "$src" "$dst"   # cp follows symlink sources: content lands under the referenced basename
    # rewrite own id + every dep pointing at our prefix; then @loader_path rpath
    install_name_tool -id "@rpath/$base" "$dst"
    while read -r dep; do
      case "$dep" in
        "$DEPS"/*|@rpath/*|@loader_path/*)
          install_name_tool -change "$dep" "@rpath/${dep##*/}" "$dst" 2>/dev/null || true ;;
      esac
    done < <(otool -L "$dst" | tail -n +2 | awk '{print $1}')
    while read -r rp; do
      [[ "$rp" == "$WORK"* ]] && install_name_tool -delete_rpath "$rp" "$dst" || true
    done < <(otool -l "$dst" | awk '/LC_RPATH/{getline; getline; print $2}')
    install_name_tool -add_rpath "@loader_path" "$dst" 2>/dev/null || true
    codesign --force --sign - "$dst"
  done < <(printf '%s' "$seen")

  ln -sf libmpv.2.dylib "$OUT/libmpv.dylib"
  mkdir -p "$OUT/include"
  rm -rf "$OUT/include/mpv"
  ditto "$DEPS/include/mpv" "$OUT/include/mpv"

  log "forest: $OUT"
  ls -lh "$OUT"/*.dylib | awk '{print "    " $9, $5}'
  log "total: $(du -sh "$OUT" | cut -f1)"
}

ph_probe() {
  log "compiling GL probe (scripts/libmpv-gl-probe.c)"
  clang -O2 -arch "${ARCHS[0]}" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$DEPS/include" \
    -framework CoreFoundation -framework OpenGL \
    "$ROOT/scripts/libmpv-gl-probe.c" -o "$PROBE_BIN" >>"$LOGS/probe.log" 2>&1 \
    || die "probe" "probe compile failed"
  "$PROBE_BIN" "$OUT/libmpv.2.dylib" >>"$LOGS/probe.log" 2>&1 \
    || die "probe" "GL probe failed — see log"
  grep -q PROBE_OK "$LOGS/probe.log" || die "probe" "PROBE_OK missing"
  log "GL probe: $(grep -E 'client api|render_context_create' "$LOGS/probe.log" | tr '\n' ' ')"
}

ph_selfcheck() {
  local fails=0
  log "selfcheck 1/4: closure cleanliness (otool -L)"
  local hits
  hits="$(for f in "$OUT"/*.dylib; do otool -L "$f"; done | grep -E "$BANNED_PATTERN" || true)"
  if [[ -n "$hits" ]]; then printf '%s\n' "$hits" >&2; warn "banned libs present"; fails=1
  else log "    no postproc/rubberband/vidstab/x264/x265/gnutls in closure"; fi
  hits="$(for f in "$OUT"/*.dylib; do otool -L "$f"; done | grep '/opt/homebrew' || true)"
  if [[ -n "$hits" ]]; then printf '%s\n' "$hits" >&2; warn "homebrew paths present"; fails=1; fi

  log "selfcheck 2/4: GPL fingerprint (strings libavutil)"
  local avutil; avutil="$(ls "$OUT"/libavutil.*.dylib | head -1)"
  if strings "$avutil" | grep -q -- "--enable-gpl"; then
    warn "--enable-gpl fingerprint FOUND in $avutil"; fails=1
  else log "    --enable-gpl: absent"; fi
  if strings "$avutil" | grep -q -- "--disable-gpl"; then
    log "    --disable-gpl: present"
  else warn "--disable-gpl fingerprint MISSING from $avutil"; fails=1; fi

  log "selfcheck 3/4: GL render probe"
  if [[ -x "$PROBE_BIN" ]] && "$PROBE_BIN" "$OUT/libmpv.2.dylib" | tee -a "$LOGS/probe.log" | grep -q PROBE_OK; then
    log "    mpv_render_context_create(OPENGL): OK"
  else warn "GL probe failed"; fails=1; fi

  log "selfcheck 4/4: signatures"
  local f bad=0
  for f in "$OUT"/*.dylib; do
    [[ -L "$f" ]] && continue
    codesign --verify "$f" 2>/dev/null || { warn "signature invalid: $f"; bad=1; }
  done
  [[ "$bad" == 0 ]] && log "    all dylibs ad-hoc signed" || fails=1

  [[ "$fails" == 0 ]] || die "selfcheck" "one or more checks failed"
  log "SELFCHECK PASS — forest ready at $OUT"
}

# --- driver -------------------------------------------------------------------

usage() { sed -n '2,40p' "$0"; exit "${1:-0}"; }

run_all() {
  step tools ph_tools
  # fetch needs no done marker: per-tarball cache IS the resume mechanism,
  # and the tarball set can grow between runs (e.g. submodule additions).
  CURRENT_STEP=fetch; ph_fetch
  step dav1d b_dav1d
  step freetype b_freetype
  step fribidi b_fribidi
  step harfbuzz b_harfbuzz
  step unibreak b_unibreak
  step fontconfig b_fontconfig
  step lcms2 b_lcms2
  step uchardet b_uchardet
  step zimg b_zimg
  step libass b_libass
  step libplacebo b_libplacebo
  step ffmpeg b_ffmpeg
  step mpv b_mpv
  step bundle ph_bundle
  step probe ph_probe
  step selfcheck ph_selfcheck
}

main() {
  mkdir -p "$WORK"
  if (($# == 0)); then run_all; return; fi
  local p
  for p in "$@"; do
    case "$p" in
      tools)      step tools ph_tools ;;
      fetch)      CURRENT_STEP=fetch; ph_fetch ;;
      dav1d)      step dav1d b_dav1d ;;
      freetype)   step freetype b_freetype ;;
      fribidi)    step fribidi b_fribidi ;;
      harfbuzz)   step harfbuzz b_harfbuzz ;;
      unibreak)   step unibreak b_unibreak ;;
      fontconfig) step fontconfig b_fontconfig ;;
      lcms2)      step lcms2 b_lcms2 ;;
      uchardet)   step uchardet b_uchardet ;;
      zimg)       step zimg b_zimg ;;
      libass)     step libass b_libass ;;
      libplacebo) step libplacebo b_libplacebo ;;
      ffmpeg)     step ffmpeg b_ffmpeg ;;
      mpv)        step mpv b_mpv ;;
      bundle)     rm -f "$DONE/bundle.done"; step bundle ph_bundle ;;
      probe)      rm -f "$DONE/probe.done"; step probe ph_probe ;;
      selfcheck)  rm -f "$DONE/selfcheck.done"; step selfcheck ph_selfcheck ;;
      clean)      rm -rf "$WORK"; log "work dir wiped: $WORK" ;;
      distclean)  rm -rf "$WORK" "$OUT"; log "wiped $WORK and $OUT" ;;
      *) usage 1 ;;
    esac
  done
}

main "$@"
