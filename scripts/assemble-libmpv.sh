#!/bin/sh
# Assemble Vendor/libmpv locally (the forest is git-ignored, 116MB).
#
#   dylibs:  copied from /Applications/IINA.app/Contents/Frameworks
#            (mpv 0.38.0, universal, already @rpath; libswift_Concurrency
#            excluded — it shadows the toolchain library at link time).
#   headers: mpv v0.41.0 client headers from GitHub (client API is stable;
#            this project only uses APIs present since 0.33).
#
# Override the source app with IINA_APP=/path/to/IINA.app.
# See plans/SPIKE-video-playback.md for why this source was chosen.
set -eu

cd "$(dirname "$0")/.."
DEST="Vendor/libmpv"
IINA_FW="${IINA_APP:-/Applications/IINA.app}/Contents/Frameworks"
MPV_HEADER_TAG="v0.41.0"

[ -d "$IINA_FW" ] || { echo "error: $IINA_FW not found (install IINA or set IINA_APP)"; exit 1; }

mkdir -p "$DEST"
for lib in "$IINA_FW"/*.dylib; do
  [ -L "$lib" ] && continue
  [ "$(basename "$lib")" = "libswift_Concurrency.dylib" ] && continue
  ditto "$lib" "$DEST/$(basename "$lib")"
done
ln -sf libmpv.2.dylib "$DEST/libmpv.dylib"

if [ ! -d "$DEST/include/mpv" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://github.com/mpv-player/mpv/archive/refs/tags/$MPV_HEADER_TAG.tar.gz" \
    | tar -xz -C "$tmp" "mpv-${MPV_HEADER_TAG#v}/include/mpv"
  mkdir -p "$DEST/include"
  ditto "$tmp/mpv-${MPV_HEADER_TAG#v}/include/mpv" "$DEST/include/mpv"
fi

echo "assembled $DEST: $(ls "$DEST"/*.dylib | wc -l | tr -d ' ') dylibs + include/mpv"
