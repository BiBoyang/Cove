# Third-party licenses — vendored libmpv forest

Cove's video player ships a self-built, LGPL-clean libmpv dylib forest
(`Vendor/libmpv/`, git-ignored). This directory holds the license text of
every upstream component whose code ships in that forest, plus the source
identification required by the LGPL components.

The forest is produced by `scripts/build-libmpv.sh` in this repository.
That script **is** the corresponding-source recipe: it pins every component
to an exact upstream tag/commit (see the `*_TAG` / `*_VER` / `*_SHA`
variables at the top of the script), fetches the pinned sources, builds
them with the recorded flag matrix, and rewires/signs the dylibs. Running
`./scripts/build-libmpv.sh` on a clean checkout reproduces the shipped
binaries from those exact sources. Background and audit:
`plans/libmpv-license-audit-2026-09-07.md`.

Compliance mechanics:

- All LGPL components are dynamically linked (separate `@rpath` dylibs
  embedded in `Cove.app/Contents/Frameworks`), never statically linked
  into the app binary. Users can replace any dylib and relaunch.
- mpv is built with `-Dgpl=false` (LGPL-2.1+ grant, see `mpv.Copyright`);
  FFmpeg is configured with `--disable-gpl --disable-version3
  --disable-nonfree` (fingerprint embedded in the libavutil binary and
  verified by the build script's selfcheck phase).
- No GPL-licensed component ships in the forest (no postproc, x264, x265,
  rubberband, vid.stab; see the audit doc §1 for the full accounting).

## Shipped components (dylibs in Vendor/libmpv/)

| Component | Version | License | License file(s) here | Shipped dylib | Upstream |
|---|---|---|---|---|---|
| mpv | 0.41.0 | LGPL-2.1+ (`-Dgpl=false` build) | `mpv.Copyright`, `mpv.LICENSE.LGPL` | libmpv.2.dylib | https://github.com/mpv-player/mpv |
| FFmpeg | n7.1.5 | LGPL-2.1+ (`--disable-gpl` build) | `ffmpeg.LICENSE.md`, `ffmpeg.COPYING.LGPLv2.1` | libavcodec.61 / libavformat.61 / libavfilter.10 / libavutil.59 / libswscale.8 / libswresample.5 | https://github.com/FFmpeg/FFmpeg |
| libplacebo | 7.349.0 | LGPL-2.1+ | `libplacebo.LICENSE` | libplacebo.349.dylib | https://github.com/haasn/libplacebo |
| libass | 0.17.3 | ISC | `libass.COPYING` | libass.9.dylib | https://github.com/libass/libass |
| FreeType | 2.13.3 | FTL (chosen branch of FTL/GPL-2.0 dual) | `freetype.LICENSE.TXT`, `freetype.FTL.TXT` | libfreetype.6.dylib | https://github.com/freetype/freetype |
| FriBidi | 1.0.16 | LGPL-2.1+ | `fribidi.COPYING` | libfribidi.0.dylib | https://github.com/fribidi/fribidi |
| HarfBuzz | 12.1.0 | MIT ("Old MIT") | `harfbuzz.COPYING` | libharfbuzz.0.dylib | https://github.com/harfbuzz/harfbuzz |
| fontconfig | 2.16.2 | MIT-style | `fontconfig.COPYING` | libfontconfig.1.dylib | https://gitlab.freedesktop.org/fontconfig/fontconfig |
| libunibreak | 6.1 | zlib | `libunibreak.LICENCE` | libunibreak.dylib | https://github.com/adah1972/libunibreak |
| Little CMS 2 | 2.17 | MIT | `lcms2.LICENSE` | liblcms2.2.dylib | https://github.com/mm2/Little-CMS |
| dav1d | 1.5.4 | BSD-2-Clause | `dav1d.COPYING` | libdav1d.7.dylib | https://code.videolan.org/videolan/dav1d |
| zimg | 3.0.6 | WTFPL-2.0 | `zimg.COPYING` | libzimg.2.dylib | https://github.com/sekrit-twc/zimg |
| uchardet | 0.0.8 | MPL-1.1 (chosen branch of MPL-1.1/GPL-2.0+/LGPL-2.1+ tri-license) | `uchardet.COPYING` | libuchardet.dylib | https://gitlab.freedesktop.org/uchardet/uchardet |

## Code statically embedded inside libplacebo.dylib

These ship as object code within libplacebo.349.dylib, so their licenses
are included too:

| Component | Pinned commit | License | License file(s) here | Upstream |
|---|---|---|---|---|
| glad (GL loader, generated code + generator) | d08b1aa0 | MIT | `glad.LICENSE` | https://github.com/Dav1dde/glad |
| fast_float (header-only float parsing) | 2b2395f9 | MIT (chosen branch of MIT/Apache-2.0/BSL-1.0 tri-license) | `fast_float.LICENSE-MIT` | https://github.com/fastfloat/fast_float |
| Vulkan-Headers (interface headers only; no Vulkan runtime ships — libplacebo is built `-Dvulkan=disabled`) | d732b2de | Apache-2.0 | `vulkan-headers.LICENSE.txt` | https://github.com/KhronosGroup/Vulkan-Headers |

## Build-time only (no code ships)

jinja (BSD-3) and markupsafe (BSD-3) run at build time as glad2's code
generator dependencies; meson / ninja / pkgconf / nasm / clang are build
tools borrowed from Homebrew/Xcode. None of their code is linked into the
shipped binaries.

## Rebuild / relink instructions (LGPL "corresponding source" pointer)

```sh
./scripts/build-libmpv.sh        # full chain: fetch → build → bundle → probe → selfcheck
```

The script's `selfcheck` phase re-verifies: no banned GPL fingerprints in
the closure, `--disable-gpl` present in libavutil, the OpenGL render probe
passes, and every dylib is ad-hoc signed. See the script header for
environment notes and resume/clean semantics.
